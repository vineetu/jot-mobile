import FluidAudio
import Foundation
import os.log

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
        let words = text.split(separator: " ")
        guard words.count > 1 else { return aliases }
        let merged = words.joined()
        var out = aliases ?? []
        let mergedLower = merged.lowercased()
        if !out.contains(where: { $0.lowercased() == mergedLower }) {
            out.append(merged)
        }
        return out.isEmpty ? nil : out
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
        tokenTimings: [TokenTiming],
        audioSamples: [Float]
    ) async throws -> String? {
        let spotResult = try await spot(audioSamples: audioSamples)
        return await merge(
            transcript: transcript,
            tokenTimings: tokenTimings,
            spotResult: spotResult
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
        tokenTimings: [TokenTiming],
        spotResult: CtcKeywordSpotter.SpotKeywordsResult?
    ) async -> String? {
        // Re-fetch the live handles. The split lets `spot(...)` run while
        // TDT decodes; by the time we merge, `vocabulary`/`rescorer` are
        // the same handles the spot used (a vocab rebuild between spot and
        // merge is the identical race the monolithic version already had,
        // and the generation guard in `rebuildVocabulary` covers it).
        guard let spotResult, let vocabulary, let rescorer else {
            return nil
        }

        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration
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
            let overrides = await CorrectionStore.shared.snapshot()
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
            let gated = VocabularyGate.apply(
                originalTranscript: transcript,
                output: output,
                tokenTimings: tokenTimings,
                overrides: overrides,
                termAliases: termAliases
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
            await CorrectionProvenance.shared.record(gated.proposals, gatedText: gated.text)
            return gated.text
        }
        return transcript
    }
}

public enum VocabularyRescorerError: Error {
    /// `rebuildVocabulary(from:)` was called before the CTC models were
    /// loaded. Call `prepare(vocabularyFileURL:)` first.
    case notPrepared
}
