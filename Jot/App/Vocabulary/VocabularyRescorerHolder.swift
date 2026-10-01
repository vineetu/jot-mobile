import FluidAudio
import Foundation
import JotVocabCore
import os.log

// NOTE on the `TokenTiming` clash: both FluidAudio and JotVocabCore export a
// top-level `TokenTiming`, and the module name `FluidAudio` is itself shadowed
// by a same-named type — so `FluidAudio.TokenTiming` won't resolve and a bare
// `TokenTiming` is ambiguous once both are imported. FluidAudio's is reached via
// the `FluidAudioTokenTiming` alias (see FluidAudioTokenTiming.swift, a
// FluidAudio-only file); the package's is written `JotVocabCore.TokenTiming`.
// Every other package reference here is fully `JotVocabCore.`-qualified for
// clarity.

/// Owns the FluidAudio vocabulary-boosting stack. Separate from
/// `VocabularyStore` (which owns the user's list + the file on disk)
/// because the rescorer carries live CoreML resources that only need to
/// exist while transcription actually uses them.
///
/// Ported from `jot/Sources/Vocabulary/VocabularyRescorerHolder.swift`.
/// Differences from desktop:
///   - `os_log` subsystem matches the mobile target.
///   - Public API is unchanged so the integration into `TranscriptionService`
///     reads identical to the desktop's `Transcriber.swift:117`.
///
/// Lifecycle:
/// - `prepare(vocabularyFileURL:)` loads the CTC 110M bundle (downloading
///   if needed — caller MUST ensure user consent first), tokenizes the
///   user's vocab via FluidAudio's CtcTokenizer, builds the
///   `CtcKeywordSpotter` + `VocabularyRescorer` pair.
/// - `rebuildVocabulary(from:)` reuses the already-loaded `CtcModels` +
///   tokenizer and just re-tokenizes the updated term list. Cheap.
/// - `unload()` drops the in-memory state — used when the user turns
///   vocabulary boosting off in Settings.
///
/// Actor-isolated. `TranscriptionService` calls in from MainActor;
/// `VocabularyStore.save()` posts an async rebuild after each write.
public actor VocabularyRescorerHolder {
    public static let shared = VocabularyRescorerHolder()

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "VocabularyRescorer"
    )
    private let cache: CtcModelCache

    private var models: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?
    private var tokenizer: CtcTokenizer?
    private var isPreparing: Bool = false

    /// Monotonic token incremented on every `prepare` / `rebuildVocabulary`
    /// entry. Each async rebuild captures its own token and, before
    /// publishing its result to `self`, confirms its token is still the
    /// latest. Protects against actor reentrancy: two rapid saves from
    /// `VocabularyStore.save()` can each start a rebuild that suspends
    /// at the tokenizer load / rescorer build points; without this
    /// guard the older one could land after the newer and overwrite
    /// `self.vocabulary` with stale data.
    private var generation: UInt64 = 0

    /// Monotonic token for `prepare(...)` supersession, separate from
    /// `generation` (which arbitrates `rebuildVocabulary`). Bumped on every
    /// `prepare` entry AND on every `unload`. A suspended prepare re-checks
    /// this after each `await`; if a later prepare or an `unload` bumped it,
    /// the suspended prepare aborts without stamping stale/half-built state.
    /// Kept distinct from `generation` so `rebuildVocabulary`'s own
    /// generation bump (called at the tail of `prepare`) doesn't falsely
    /// look like a supersession of the prepare.
    private var prepareGeneration: UInt64 = 0

    public init(cache: CtcModelCache = .shared) {
        self.cache = cache
    }

    /// True when the spotter + rescorer + a non-empty vocabulary are all
    /// live in memory — the precondition for `rescore(...)` to actually
    /// change the transcript.
    public var isReady: Bool {
        spotter != nil && rescorer != nil && (vocabulary?.terms.isEmpty == false)
    }

    /// True when a `prepare()` call is currently executing. Caller (e.g.
    /// the Vocabulary pane's Download button) reads this to show a
    /// spinner.
    public var preparing: Bool { isPreparing }

    /// Waits up to `timeoutSeconds` for `isReady`. The vocab CTC model loads
    /// DEFERRED (after Parakeet, to avoid cold-start ANE-compiler contention), so a
    /// dictation that stops before that load finished would otherwise fall back to
    /// the raw transcript. The dictation's rescore awaits this so the FIRST cold
    /// dictation still gets custom-vocabulary biasing. Returns immediately when
    /// already ready (the warm/common case → zero cost), and bails fast (after a
    /// ~1s grace for a just-kicked prepare) if nothing is loading — so it never
    /// burns the full timeout when vocab is disabled or the bundle is absent.
    public func awaitReady(timeoutSeconds: Double) async -> Bool {
        if isReady { return true }
        let maxPolls = max(1, Int(timeoutSeconds * 20)) // 50 ms per poll
        var polls = 0
        while polls < maxPolls {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if isReady { return true }
            // ~1s grace lets a prepare kicked at the same instant set `isPreparing`;
            // after that, no prepare in flight means it will never become ready.
            if polls > 20 && !isPreparing { return false }
            polls += 1
        }
        return isReady
    }

    /// Drop every FluidAudio handle. Subsequent `rescore(...)` calls
    /// become no-ops until `prepare(...)` is called again.
    ///
    /// Bumping `prepareGeneration` here is load-bearing for the toggle
    /// race: any `prepare(...)` currently suspended at a model/tokenizer
    /// `await` captured an OLDER `prepareGeneration`, so when it resumes it
    /// sees `ownPrepare != prepareGeneration` and aborts WITHOUT stamping
    /// its half-built handles back over this unload. That is what stops a
    /// fast vocab off→on→off toggle from leaving a wedged, half-loaded
    /// rescorer. (`generation` is bumped too, which makes any in-flight
    /// `rebuildVocabulary` discard its result for the same reason.)
    public func unload() {
        models = nil
        spotter = nil
        rescorer = nil
        vocabulary = nil
        tokenizer = nil
        generation &+= 1
        prepareGeneration &+= 1
        isPreparing = false
        log.info("vocabulary rescorer unloaded")
    }

    /// Load the CTC 110M bundle (downloading on first use), tokenize the
    /// user's list, construct the rescorer. Idempotent — if models are
    /// already loaded, this path only re-tokenizes the term list via
    /// `rebuildVocabulary(from:)`.
    public func prepare(vocabularyFileURL: URL) async throws {
        // Toggle-race safety. Each prepare captures its own generation at
        // entry. `unload()` (vocab toggled OFF) and `rebuildVocabulary`
        // (vocab list saved) both bump `generation`. After every `await`
        // resume point below we re-check `ownGeneration == generation`; if
        // an `unload()` interleaved while we were suspended on a model /
        // tokenizer load, we abort WITHOUT stamping our half-built handles
        // over the unload. This is what prevents a fast off→on→off toggle
        // from leaving the rescorer wedged in a half-loaded state.
        //
        // We deliberately do NOT early-return on `isPreparing` anymore: the
        // old `guard !isPreparing { return }` let a later prepare exit
        // immediately while an earlier one got superseded — leaving NO
        // rescorer. `CtcModelCache.ensureLoaded()` already coalesces the
        // actual model load, so a redundant concurrent prepare is cheap and
        // the generation check arbitrates who wins.
        prepareGeneration &+= 1
        let ownPrepare = prepareGeneration
        isPreparing = true
        defer {
            // Only clear the in-flight flag if we are still the latest
            // prepare — a newer prepare/unload owns the flag otherwise.
            if ownPrepare == prepareGeneration { isPreparing = false }
        }

        if models == nil {
            log.info("loading CTC 110M bundle (downloading if needed)")
            do {
                let loaded = try await cache.ensureLoaded()
                guard ownPrepare == prepareGeneration else {
                    log.info("prepare \(ownPrepare) superseded during bundle load; aborting")
                    return
                }
                models = loaded
                spotter = CtcKeywordSpotter(models: loaded)
            } catch {
                // Nuke the cache on load failure so the next retry starts
                // from a known-empty state instead of sticking on a
                // partial bundle forever.
                cache.removeCache()
                log.error("CTC bundle load failed — cache cleared: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        if tokenizer == nil {
            do {
                let loadedTokenizer = try await CtcTokenizer.load(from: cache.directory)
                guard ownPrepare == prepareGeneration else {
                    log.info("prepare \(ownPrepare) superseded during tokenizer load; aborting")
                    return
                }
                tokenizer = loadedTokenizer
            } catch {
                log.error("CTC tokenizer load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        // Final supersession check before the (cheap) rescorer build. If an
        // unload landed while we loaded models/tokenizer, bail now rather
        // than rebuild on top of a stale unload.
        guard ownPrepare == prepareGeneration else {
            log.info("prepare \(ownPrepare) superseded before rebuild; aborting")
            return
        }
        try await rebuildVocabulary(from: vocabularyFileURL)
    }

    /// Re-tokenize the user's vocab list against the already-warm CTC
    /// tokenizer. Call this when `VocabularyStore` writes a new term /
    /// alias set. Assumes `prepare(...)` has already run once — if not,
    /// throws so the caller knows to prepare first.
    public func rebuildVocabulary(from url: URL) async throws {
        guard let spotter, let tokenizer else {
            throw VocabularyRescorerError.notPrepared
        }

        generation &+= 1
        let ownGeneration = generation

        let baseVocab: CustomVocabularyContext
        do {
            baseVocab = try CustomVocabularyContext.loadFromSimpleFormat(from: url)
        } catch {
            log.error("vocabulary file parse failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let tokenized = baseVocab.terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: term.weight,
                aliases: Self.enrichedAliases(text: term.text, aliases: term.aliases),
                tokenIds: nil,
                ctcTokenIds: ids
            )
        }
        let droppedCount = baseVocab.terms.count - tokenized.count
        if droppedCount > 0 {
            log.warning("dropped \(droppedCount) term(s) that tokenized to empty — likely out-of-vocab characters")
        }

        let vocab = CustomVocabularyContext(terms: tokenized)
        let rescorer: VocabularyRescorer
        do {
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocab,
                config: .default,
                ctcModelDirectory: cache.directory
            )
        } catch {
            log.error("rescorer build failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // Reentrancy check: during `await VocabularyRescorer.create(...)`
        // another rebuild may have started. If so, our results are
        // stale — drop them rather than clobber the newer state.
        guard ownGeneration == generation else {
            log.info("rebuild \(ownGeneration) superseded by \(self.generation); discarding")
            return
        }

        self.vocabulary = vocab
        self.rescorer = rescorer
        log.info("vocabulary loaded: \(vocab.terms.count) term(s) active")
    }

    /// **Merged-word fix.** ASR can collapse a spoken multi-word term into ONE
    /// word ("Ramaa Nathan" heard as "Ramanathan"). FluidAudio's matcher only
    /// compares multi-word term forms against multi-word ASR spans, so without
    /// help the term never even competes for the merged word — and a shorter
    /// term ("Ramaa") wins it by default. Feeding the space-stripped form as an
    /// extra alias gives the matcher a single-word form ("RamaaNathan" →
    /// normalized "ramaanathan") that scores ~0.9 against any merged rendering.
    /// Injected at FEED time only — the user's vocabulary.txt is never rewritten.
    static func enrichedAliases(text: String, aliases: [String]?) -> [String]? {
        var out = aliases ?? []

        // §7 CASING — applies to EVERY term, single-word included. "OKTA",
        // "AWS", "NVIDIA" are single words and are precisely the cases that
        // scored 0%. This MUST run before the multi-word guard below, which
        // used to return early and skip single-word terms entirely.
        for surface in [text] + (aliases ?? []) {
            for variant in Self.casingSurfaces(for: surface) {
                // EXACT (ordinal) dedup — deliberately NOT the case-insensitive
                // compare used for the merged form below. A case-insensitive
                // check would collapse the very variants being added here and
                // silently restore the 0%-recall bug.
                if !out.contains(variant) { out.append(variant) }
            }
        }

        let words = text.split(separator: " ")
        guard words.count > 1 else { return out.isEmpty ? nil : out }
        let merged = words.joined()
        let mergedLower = merged.lowercased()
        if !out.contains(where: { $0.lowercased() == mergedLower }) {
            out.append(merged)
        }
        // Lowercase merged form too, for the same reason as above: the model
        // renders most words lowercase mid-sentence.
        if !out.contains(mergedLower) { out.append(mergedLower) }
        return out.isEmpty ? nil : out
    }

    /// **§7 — extra CASING forms to search for a given surface.**
    ///
    /// The CTC scorer is a punctuation-and-capitalisation checkpoint, so token
    /// ids differ by casing. VERIFIED against our OWN bundled vocab
    /// (`parakeet-ctc-110m`: 1024 tokens, 94 of them uppercase, plus sentence
    /// punctuation — so it is the same class of model Windows measured):
    ///
    ///     "OKTA" → ▁O K T A        "Okta" → ▁O k t a        "okta" → ▁o k t a
    ///     "AWS"  → ▁A W S          "NVIDIA" → ▁N V I D I A
    ///
    /// Three different id sequences for one word. The bare-uppercase letters do
    /// exist in the vocab, but a P&C model renders letters lowercase mid-word
    /// and will essentially never EMIT that run — so a term typed ALL CAPS is
    /// searched for as a sequence the model never produces. Recall is ~0, with
    /// no error and a UI badge still calling the term valid. Windows measured
    /// as-emitted 100%, all-lowercase 97%, **Title Case 68%, ALL CAPS 0%** —
    /// counter-intuitively lowercase is nearly harmless, and the killers are
    /// exactly the initialisms a vocabulary feature exists for.
    ///
    /// So: search several forms, let the best-scoring occurrence win, and report
    /// the user's own spelling. As-typed is always searched (it is the term
    /// itself), so nothing can regress. Casing is NEVER normalized at input —
    /// the term's spelling is what gets pasted into the user's text — which is
    /// why these are injected as FEED-TIME aliases and `vocabulary.txt` is left
    /// alone.
    ///
    /// Kept to ≤2 extra forms per surface (well inside the ~5-form / 12-query
    /// per-term budget Windows used; their cost was 20.5 → 73.7 ms of DP on 200
    /// terms). Note the model-free corrector is unaffected either way — it
    /// matches on case-insensitive skeletons, so it already rescues these terms.
    static func casingSurfaces(for text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        let lower = text.lowercased()
        if lower != text { out.append(lower) }
        let title = text.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
        if title != text, title != lower { out.append(title) }
        return out
    }

    /// Run the rescorer over a TDT-produced transcript. Returns the
    /// rescored text on success, `nil` if the rescorer is not ready
    /// (e.g. master toggle is off, vocab empty, models not downloaded).
    ///
    /// Caller MUST treat `nil` and any thrown error the same: fall back
    /// to the raw TDT transcript. This function is a best-effort boost,
    /// never a correctness gate.
    ///
    /// This is a thin convenience wrapper over the split `spot(...)` +
    /// `merge(...)` pair below — it runs the expensive CTC pass and the
    /// cheap merge back-to-back (the original serial order). Callers that
    /// want to overlap the CTC pass with the TDT transcribe should call
    /// `spot(...)` concurrently with the transcribe and then `merge(...)`
    /// once both finish (see `TranscriptionService.runInference`). The
    /// output is byte-identical regardless of which path is taken.
    public func rescore(
        transcript: String,
        tokenTimings: [FluidAudioTokenTiming],
        audioSamples: [Float]
    ) async throws -> String? {
        let spotResult = try await spot(audioSamples: audioSamples)
        return await merge(
            transcript: transcript,
            tokenTimings: tokenTimings,
            spotResult: spotResult
        )
    }

    /// **Engine A/B Test Lab support (2026-07-05, temporary).** Same as
    /// `rescore(...)` but returns the per-correction `VocabularyGate.Proposal`
    /// list too. See `mergeWithProposals(...)`'s doc comment for the
    /// `recordProvenance` semantics.
    func rescoreWithProposals(
        transcript: String,
        tokenTimings: [FluidAudioTokenTiming],
        audioSamples: [Float],
        recordProvenance: Bool = true
    ) async throws -> (text: String, proposals: [JotVocabCore.VocabularyGate.Proposal])? {
        let spotResult = try await spot(audioSamples: audioSamples)
        return await mergeWithProposals(
            transcript: transcript,
            tokenTimings: tokenTimings,
            spotResult: spotResult,
            recordProvenance: recordProvenance
        )
    }

    /// The EXPENSIVE half of the rescore: the CTC keyword-spot pass
    /// (MelSpectrogram + AudioEncoder CoreML inference over the full
    /// audio buffer). Depends ONLY on the audio + the loaded vocabulary —
    /// NOT on the TDT transcript or its `tokenTimings` — so it is safe to
    /// dispatch concurrently with the TDT transcribe and join afterwards.
    ///
    /// Returns `nil` when the rescorer isn't ready (master toggle off,
    /// vocab empty, models not downloaded), exactly matching the old
    /// `rescore(...)` early-return contract. A `nil` here means "no
    /// rescore" — the caller's `merge(...)` will then return the raw
    /// transcript unchanged.
    ///
    /// The returned `SpotKeywordsResult` is `Sendable` (CTC log-probs +
    /// frame duration + detections), so it crosses the actor / task
    /// boundary back to the caller with no shared mutable state.
    public func spot(audioSamples: [Float]) async throws -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard let spotter, let vocabulary, rescorer != nil else {
            return nil
        }
        guard !vocabulary.terms.isEmpty else { return nil }

        return try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary,
            minScore: nil
        )
    }

    /// The CHEAP half of the rescore: merge the CTC spot result into the
    /// TDT transcript using the TDT `tokenTimings`, then run the same
    /// `VocabularyGate` + `CorrectionProvenance` bookkeeping the monolithic
    /// `rescore(...)` did. Pure CPU (~14–20 ms) apart from the awaited
    /// `CorrectionStore`/`CorrectionProvenance` actor hops, which are
    /// unchanged from before.
    ///
    /// `spotResult == nil` (rescorer not ready) → returns `nil`, i.e. the
    /// caller keeps the raw TDT transcript — byte-identical to the old
    /// "not ready" early return.
    public func merge(
        transcript: String,
        tokenTimings: [FluidAudioTokenTiming],
        spotResult: CtcKeywordSpotter.SpotKeywordsResult?
    ) async -> String? {
        (await mergeWithProposals(transcript: transcript, tokenTimings: tokenTimings, spotResult: spotResult))?.text
    }

    /// The CTC spotter's detections as `.acoustic` gate evidence — each term's
    /// real log-prob score and audio span, never a synthesized confidence or
    /// margin (jot-shared design R2). Aliases are the SAME enriched set the
    /// spotter matched on (user aliases + the merged form of a multi-word term),
    /// so the gate's plausibility guard measures against what was heard.
    /// Placement onto the transcript happens in `VocabularyPass` via the
    /// decoder's word timings; without them these are dropped, never placed by
    /// proportional position.
    func acousticDetections(
        from spotResult: CtcKeywordSpotter.SpotKeywordsResult
    ) -> [JotVocabCore.VocabularyGate.Detection] {
        guard let vocabulary else { return [] }
        var aliasMap: [String: [String]] = [:]
        for t in vocabulary.terms {
            aliasMap[t.text.lowercased(), default: []] += (t.aliases ?? [])
        }
        return spotResult.detections.map { d in
            JotVocabCore.VocabularyGate.Detection(
                term: d.term.text,
                aliases: aliasMap[d.term.text.lowercased()] ?? (d.term.aliases ?? []),
                evidence: .acoustic(score: d.score, confidence: nil),
                startTime: d.startTime,
                endTime: d.endTime)
        }
    }

    /// **Engine A/B Test Lab support (2026-07-05, temporary).** Same as
    /// `merge(...)` — identical behavior — but also returns the individual
    /// gate decisions (`VocabularyGate.Proposal`: original word → term,
    /// APPLY/BLOCK/OVERRIDE, confidence), which `merge(...)` computes
    /// internally but discards. Added so the A/B Lab can show WHERE each
    /// engine's vocab boost actually fired, not just the final before/after
    /// text. `merge(...)` is now a thin wrapper over this (`recordProvenance:
    /// true`) — behavior for every existing caller is unchanged.
    ///
    /// `recordProvenance: false` is for a SHADOW/comparison run (e.g. the
    /// background FluidAudio comparison kicked off alongside a real Apple-
    /// engine publish) that must NOT write to `CorrectionProvenance`'s
    /// single pending slot — that slot belongs to the dictation actually
    /// being published, and a concurrent shadow write would race it.
    func mergeWithProposals(
        transcript: String,
        tokenTimings: [FluidAudioTokenTiming],
        spotResult: CtcKeywordSpotter.SpotKeywordsResult?,
        recordProvenance: Bool = true
    ) async -> (text: String, proposals: [JotVocabCore.VocabularyGate.Proposal])? {
        // Re-fetch the live handles. The split lets `spot(...)` run while
        // TDT decodes; by the time we merge, `vocabulary`/`rescorer` are
        // the same handles the spot used (a vocab rebuild between spot and
        // merge is the identical race the monolithic version already had,
        // and the generation guard in `rebuildVocabulary` covers it).
        guard let spotResult, let vocabulary, let rescorer else {
            return nil
        }

        // (R2, 2026-07-12) Raise the candidate-match floor above FluidAudio's
        // default 0.50 (`ContextBiasingConstants.minSimilarityFloor`). At 0.50 a
        // heard word sharing only half its characters with a term qualifies as a
        // match — the weak-candidate source of "it proposed a word that doesn't
        // match". 0.60 culls the weakest matches upstream (precision over recall;
        // the owner prefers fewer, surer proposals). Verified good pairs stay
        // above the floor (cloud→claude ≈0.67, jamie→jamy ≈0.6–0.8). TUNABLE —
        // validate recall on-device; lower if real corrections start being missed.
        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
            minSimilarity: 0.60
        )

        // Visible in Help → Diagnostics ONLY when the spotter actually proposed
        // something — the per-session `proposals=0` case was pure noise (drops
        // the dominant per-dictation clutter). The APPLY/BLOCK/OVERRIDE decision
        // logs still record each real proposal.
        if !output.replacements.isEmpty {
            DiagnosticsLog.record(
                source: "main-app",
                category: .vocabularyGate,
                message: "rescore ran",
                metadata: [
                    "proposals": "\(output.replacements.count)",
                    "modified": "\(output.wasModified)",
                ]
            )
        }

        if output.wasModified {
            // v1a — the GATE: re-check every proposed replacement so a custom
            // term can never silently overwrite a confident, correct word.
            // v1b — pass the owner's confirmed-mapping snapshot so a verdict
            // ("when I say Jamie I mean Jamy") overrides the guard for that pair.
            // Snapshot fetched once here (off the gate's synchronous hot loop).
            // (docs/plans/adaptive-vocabulary-correction.md §3.2 / §0i / §0j)
            let overrides = await JotVocabCore.CorrectionStore.shared.snapshot()
            // Alias map for the gate's plausibility guard — a user alias
            // ("Vinny" for "Vineet") is the user vouching that the pair is
            // acoustically plausible, so the guard must measure against it.
            // Built from the ENRICHED terms, so the auto merged-form alias of
            // multi-word terms is included.
            var termAliases: [String: [String]] = [:]
            for t in vocabulary.terms {
                if let a = t.aliases, !a.isEmpty {
                    termAliases[t.text.lowercased(), default: []] += a
                }
            }
            // Seam 1: map FluidAudio's rescore output + token timings into the
            // package's engine-neutral value types so the gate never imports
            // FluidAudio (identical pattern to the JotTextPipeline TokenTiming
            // bridge in TranscriptionService).
            let neutralOutput = JotVocabCore.RescoreOutput(
                text: output.text,
                replacements: output.replacements.map {
                    JotVocabCore.RescoreProposal(
                        originalWord: $0.originalWord,
                        replacementWord: $0.replacementWord,
                        shouldReplace: $0.shouldReplace,
                        replacementScore: $0.replacementScore,
                        originalScore: $0.originalScore)
                },
                wasModified: output.wasModified)
            let gated = JotVocabCore.VocabularyGate.apply(
                originalTranscript: transcript,
                output: neutralOutput,
                tokenTimings: tokenTimings.map {
                    JotVocabCore.TokenTiming(token: $0.token, confidence: $0.confidence)
                },
                // Seam 2/3: the app's package-resource-backed common-words
                // provider (loud-fails a missing list) + the DiagnosticsLog sink.
                commonWords: AppVocabCore.commonWords,
                diagnostics: AppVocabCore.diagnostics,
                overrides: overrides,
                termAliases: termAliases,
                // The common-word guard needs the dictation language so it checks
                // the right list (an English list can't protect a Spanish word).
                commonWordsResource: LanguageChoice.current.commonWordsResource,
                // Full term list for extension-alternate detection (3-option
                // ask): "Claude" won the span but "Claude Code" also fits.
                allTerms: vocabulary.terms.map(\.text)
            )
            log.info(
                "rescored \(output.replacements.count) proposal(s) → applied \(gated.applied), blocked \(gated.blocked.count, privacy: .public)"
            )
            // v1b — stash the proposals so the pipeline can persist them against
            // the transcript id once it's minted (CorrectionProvenance.commit).
            // gated.text rides along as the anchor baseline: it's the ONLY text
            // the proposals' publishedStart offsets are valid for — downstream
            // transforms (segmenter/filler/number/cleanup) shift the text, and
            // the provenance reconcile absorbs that drift by diffing from here.
            if recordProvenance {
                await JotVocabCore.CorrectionProvenance.shared.record(gated.proposals, gatedText: gated.text)
            }
            return (gated.text, gated.proposals)
        }
        return (transcript, [])
    }
}

public enum VocabularyRescorerError: Error {
    /// `rebuildVocabulary(from:)` was called before the CTC models were
    /// loaded. Call `prepare(vocabularyFileURL:)` first.
    case notPrepared
}
