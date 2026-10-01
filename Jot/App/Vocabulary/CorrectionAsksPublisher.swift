import Foundation
import JotVocabCore

/// **Publishes the keyboard's correction asks after a saved dictation.**
/// Reads the just-committed provenance, runs the shared decision core
/// (`JotVocabCore.AskPolicy` — ≤3 proposals, only those worth asking:
/// applied corrections, mappings part-way to automatic, or the one-shot
/// merge-teach lane; closest-to-automatic first), attaches a short spoken-
/// context snippet per ask, and hands them to `CorrectionBridge` for the
/// keyboard to read. Asks decay to zero as the system learns.
///
/// This type is now the app-side PLUMBING shell (design §1: decide in core,
/// spend in plumbing). The decision logic lives in `AskPolicy`; what stays
/// here is everything that touches a process boundary — slicing context
/// snippets out of `publishedText`, serializing into `CorrectionBridge.Ask`,
/// and *spending* the merge-teach one-shot (`CorrectionStore.noteMergeAsked`)
/// after publish.
///
/// **F3 (2026-08-30):** it is also where an ask's paste edit is PROVEN. Only
/// this side holds the exact text the keyboard will paste, so only this side can
/// decide whether the owner's pick is honorable there. Each paste-gating ask
/// carries a validated `baseEdit` (and `altEdit`) descriptor; an ask whose edit
/// cannot be resolved — or whose span collides with another ask's — is dropped
/// or narrowed rather than offered. See §F3 of
/// docs/plans/vocab-hold-deck-reliability.md.
enum CorrectionAsksPublisher {
    static let contextWindow = 24

    /// Stages the keyboard asks into the App Group and (when `signalReady`) posts
    /// `correctionAsksReady`. Returns whether any asks were published. For
    /// ask-before-paste the pipeline calls this with `signalReady: false` BEFORE the
    /// clipboard handoff (so the keyboard can read asks synchronously at flush), then
    /// posts the ready signal itself AFTER the handoff (never before the paste).
    @discardableResult
    static func publish(transcriptID: UUID, sessionID: UUID, publishedText: String,
                        signalReady: Bool = true) async -> Bool {
        // MAPPED read (ephemeral): record anchors are gate-output offsets, but
        // the context snippets below slice `publishedText`, which post-gate
        // transforms (segmenter/filler/number/cleanup) may have shifted — map
        // every anchor into publishedText exactly. Deliberately NOT the
        // persisting `reconciledPayload`: publishedText can be the AI-cleaned
        // text, and persisting that hop would strand anchors whose words the
        // cleanup rewrote away (the saved transcript still has them).
        let payload = await CorrectionProvenance.shared.mappedPayload(
            transcriptID: transcriptID, into: publishedText)
        let unresolved = payload.records.filter { payload.verdicts[$0.key] == nil }
        guard !unresolved.isEmpty else {
            CorrectionBridge.clearAsks()
            return false
        }

        // Shared decision core. `AskPolicy.select` derives the ask-ranking
        // `prior` from `overrides` itself (nothing learned auto-applies, so no
        // pair is excluded as "granted" any more), applies
        // the keyboard-suppression / merge-teach one-shot / mixed-payload rules,
        // ranks weakest evidence first (a spelling-only change before an
        // acoustic one), then closest-to-automatic, and caps at
        // `AskPolicy.maxAsks`. A KEPT record whose heard word is an everyday
        // word is never asked (the store would refuse to learn the answer); an
        // APPLIED one still is — that ask is the undo.
        // Pairs the owner has rejected (kept ≥ threshold) or "Stop asking"-ed
        // are keyboard-only suppression — the transcript review reads neither.
        let overrides = await CorrectionStore.shared.snapshot()
        let keyboardSuppressed = await CorrectionStore.shared.keyboardSuppressedPairs()
        let mergeAsked = await CorrectionStore.shared.mergeAskedPairs()
        let selections = AskPolicy.select(
            unresolved: unresolved,
            overrides: overrides,
            keyboardSuppressed: keyboardSuppressed,
            mergeAsked: mergeAsked,
            isCommonOriginal: AppVocabCore.isCommonOriginal)

        // ── F3: producer-side exact-edit validation ─────────────────────────
        // (docs/plans/vocab-hold-deck-reliability.md §F3.) Every PASTE-GATING
        // ask is resolved against `publishedText` — the exact, immutable string
        // the keyboard will paste — BEFORE it is offered, and the resolved span
        // rides along as a descriptor the keyboard can verify. Rules, all
        // fail-closed:
        //
        //  1. base span unresolvable → DROP THE ASK. Offering it would let the
        //     owner pick a word the keyboard cannot splice: the verdict still
        //     flips the saved transcript while the paste keeps the gate's word
        //     — the paste/transcript divergence this thread exists to kill.
        //  2. alternate span unresolvable → drop only the ALTERNATE (nil out
        //     `altTerm`/`altFind`, so the card renders its familiar 2 options).
        //  3. overlapping spans → deterministic precedence, below.
        //
        // Dropping (rather than re-marking an unhonorable ask `postPasteOnly`)
        // is deliberate. `postPasteOnly` is the TEACH-ONLY lane, and both
        // keyboard consumers read a blob as HOMOGENEOUS: the hold gate holds the
        // paste if ANY ask is unmarked (`JotKeyboardViewController` ask-before-
        // paste gate), while the post-paste teach strip requires EVERY ask to be
        // marked (`KeyboardStreamingHub.isPostPasteEligible`). Marking one ask of
        // a normal blob would therefore still hold the paste AND put the
        // unhonorable card in the hold deck — the exact divergence again, now on
        // the surface that is supposed to prevent it. AskPolicy establishes
        // homogeneity (a merge-teach ask is never mixed with a normal one);
        // dropping preserves it by construction, and the proposal stays
        // unresolved and reviewable on the transcript in Jot.
        //
        // Teach-only asks skip all of this: they never edit the paste, so there
        // is no span to honor and no interval to reserve.
        struct Candidate {
            let selection: AskPolicy.Selection
            let before: String
            let after: String
            let base: PasteEditResolver.Span
            var alt: PasteEditResolver.Span?
            /// Why this candidate's ALTERNATE was dropped, held until the base
            /// pass has decided the candidate survives at all. Logging it eagerly
            /// double-counted `dropped` for an ask that then lost its whole card
            /// to `base-overlap` — one removal, two log lines.
            var altDropReason: String?
        }
        var teachAsks: [CorrectionBridge.Ask] = []
        var candidates: [Candidate] = []
        var dropped: [(word: String, reason: String)] = []

        for selection in selections {
            let r = selection.record
            let (before, after) = context(of: r, in: publishedText)
            if selection.isMergeTeach {
                teachAsks.append(CorrectionBridge.Ask(
                    recordKey: r.key, original: r.originalWord, term: r.term,
                    outcome: r.outcome, contextBefore: before, contextAfter: after,
                    publishedStart: r.publishedStart, publishedLength: r.publishedLength,
                    altTerm: selection.altTerm, altFind: selection.altFind,
                    postPasteOnly: true))
                // Decide-in-core / spend-in-plumbing: AskPolicy MARKED this as
                // the one-shot merge-teach card; the app spends its single shot
                // here at PUBLISH time (adjudicated or not — bounded fatigue).
                await CorrectionStore.shared.noteMergeAsked(
                    originalWord: r.originalWord, term: r.term)
                continue
            }
            // The word standing in the published text right now (applied → term,
            // kept → original) is what EITHER direction of the flip replaces —
            // one span serves both the "original" and "term" picks.
            let inCore = PasteEditResolver.trimGatedWord(
                r.outcome == "applied" ? r.term : r.originalWord)
            guard let base = PasteEditResolver.resolve(
                needle: inCore, anchoredAt: r.publishedStart, in: publishedText,
                contextBefore: before, contextAfter: after)
            else {
                dropped.append((r.originalWord, "base-unresolvable"))
                continue
            }
            // 3-option ask: the selected alternate rides on the Selection
            // (`altTerm`/`altFind`) so we don't re-derive it — the keyboard card
            // caps at 3 buttons (original, term, one alternate). Its needle is
            // the alternate's `find` (winner + following words), so after-side
            // corroboration starts after the PRIMARY word inside that tail.
            var alt: PasteEditResolver.Span?
            var altDropReason: String?
            if selection.altTerm != nil, let altFind = selection.altFind {
                alt = PasteEditResolver.resolve(
                    needle: PasteEditResolver.trimGatedWord(altFind),
                    anchoredAt: r.publishedStart, in: publishedText,
                    contextBefore: before, contextAfter: after,
                    primaryLengthInNeedle: inCore.count)
                if alt == nil { altDropReason = "alt-unresolvable" }
            }
            candidates.append(Candidate(
                selection: selection, before: before, after: after, base: base, alt: alt,
                altDropReason: altDropReason))
        }

        // NON-OVERLAP, in AskPolicy's rank order (closest-to-automatic first).
        // Precedence: a BASE span is inviolable and wins outright — two asks
        // whose own words collide is pathological, so the lower-ranked one is
        // dropped. An ALTERNATE's span is the negotiable part: the gate's `find`
        // deliberately widens through the FOLLOWING words, so it can swallow the
        // next ask's word (review finding 8); when an alternate collides with any
        // interval already reserved by another ask we drop just that alternate
        // and keep the 2-option card.
        //
        // The BASE pass is order-independent in the sense that matters (no
        // alternate can take a base span away from an ask). The ALT pass is
        // order-DEPENDENT and deliberately so: a surviving alternate widens its
        // own reservation, so an earlier-ranked alternate can be the reason a
        // later one is dropped. That is deterministic, not arbitrary — the order
        // is AskPolicy's rank (closest-to-automatic first), so the alternate the
        // owner is most likely to want is the one that wins a collision.
        // `reserved[i]` always describes `kept[i]`.
        var reserved: [Range<Int>] = []
        var kept: [Candidate] = []
        for c in candidates {
            if reserved.contains(where: { PasteEditResolver.overlaps($0, c.base.range) }) {
                dropped.append((c.selection.record.originalWord, "base-overlap"))
                continue
            }
            reserved.append(c.base.range)
            kept.append(c)
        }
        for i in kept.indices {
            guard let alt = kept[i].alt else { continue }
            let collides = reserved.indices.contains {
                $0 != i && PasteEditResolver.overlaps(reserved[$0], alt.range)
            }
            if collides {
                kept[i].alt = nil
                kept[i].altDropReason = "alt-overlap"
            } else {
                // The alternate widens this ask's reservation, so a LATER
                // alternate can't reach into the span this one would replace.
                let lo = min(reserved[i].lowerBound, alt.start)
                let hi = max(reserved[i].upperBound, alt.end)
                reserved[i] = lo..<hi
            }
        }

        // AskPolicy emits homogeneous selections (all teach OR all paste-holding),
        // so exactly one of these two lists is ever non-empty; concatenating keeps
        // rank order either way.
        var asks: [CorrectionBridge.Ask] = teachAsks
        for c in kept {
            let r = c.selection.record
            // A dropped alternate is logged HERE — once, and only for a card
            // that actually shipped (an ask the base pass removed took its
            // alternate with it and must not be counted twice).
            if let reason = c.altDropReason { dropped.append((r.originalWord, reason)) }
            let baseEdit = CorrectionBridge.EditSpan(
                start: c.base.start, end: c.base.end, text: c.base.text)
            let altEdit = c.alt.map {
                CorrectionBridge.EditSpan(start: $0.start, end: $0.end, text: $0.text)
            }
            // Fail closed on a malformed descriptor. `PasteEditResolver` cannot
            // produce one (its spans are well-formed by construction), so this is
            // the assert that keeps it that way if either side ever changes:
            // shipping a degenerate span would hand the keyboard an unvalidated
            // insertion that overlap checking cannot see.
            guard baseEdit.isWellFormed, altEdit.map(\.isWellFormed) != false else {
                dropped.append((r.originalWord, "descriptor-malformed"))
                continue
            }
            asks.append(CorrectionBridge.Ask(
                recordKey: r.key, original: r.originalWord, term: r.term,
                outcome: r.outcome, contextBefore: c.before, contextAfter: c.after,
                publishedStart: r.publishedStart, publishedLength: r.publishedLength,
                altTerm: c.alt == nil ? nil : c.selection.altTerm,
                altFind: c.alt == nil ? nil : c.selection.altFind,
                postPasteOnly: nil,
                baseEdit: baseEdit,
                altEdit: altEdit))
        }
        for d in dropped {
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate,
                message: "keyboard ask edit not honorable: \(d.word)",
                metadata: ["reason": d.reason, "session": sessionID.uuidString])
        }
        guard !asks.isEmpty else {
            CorrectionBridge.clearAsks()
            return false
        }
        CorrectionBridge.publishAsks(
            CorrectionBridge.Asks(
                sessionID: sessionID, transcriptID: transcriptID, asks: Array(asks),
                // ALL unresolved proposals on the transcript (not just the ≤3
                // surfaced asks) — drives the keyboard "Done" stage's "N more
                // guesses are on the transcript in Jot." line.
                totalUnresolved: unresolved.count))
        // Signal the keyboard that the asks exist. For ask-before-paste the caller
        // stages with `signalReady: false` and posts this itself AFTER the handoff,
        // so the ready signal can never precede the paste it gates.
        if signalReady {
            CrossProcessNotification.post(name: CrossProcessNotification.correctionAsksReady)
        }
        DiagnosticsLog.record(
            source: "main-app", category: .vocabularyGate, message: "keyboard asks published",
            metadata: ["asks": "\(asks.count)", "unresolved": "\(unresolved.count)",
                       "session": sessionID.uuidString, "signalReady": "\(signalReady)",
                       // F3: how much validation removed, so a "why wasn't I
                       // asked?" report separates "nothing to ask" from "the
                       // edit couldn't be honored in the paste".
                       "dropped": "\(dropped.count)",
                       "descriptors": "\(asks.filter { $0.baseEdit != nil }.count)"])
        return true
    }

    /// ~`contextWindow` chars on each side of the published span (ellipsized).
    private static func context(of r: CorrectionProvenance.Record, in text: String) -> (String, String) {
        let chars = Array(text)
        let n = chars.count
        let start = max(0, min(r.publishedStart, n))
        let end = max(start, min(r.publishedStart + r.publishedLength, n))
        let beforeStart = max(0, start - contextWindow)
        let afterEnd = min(n, end + contextWindow)
        var before = String(chars[beforeStart..<start])
        var after = String(chars[end..<afterEnd])
        if beforeStart > 0 { before = "…" + before }
        if afterEnd < n { after += "…" }
        return (before, after)
    }
}
