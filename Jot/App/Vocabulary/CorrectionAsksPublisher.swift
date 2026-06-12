import Foundation

/// **Publishes the keyboard's correction asks after a saved dictation.**
/// Reads the just-committed provenance, applies the handoff's ask policy
/// (≤3 proposals, only those worth asking: a mapping already part-way to
/// automatic (`prior > 0`) OR a low-margin `unsure` call; closest-to-automatic
/// first), attaches a short spoken-context snippet per ask, and hands them to
/// `CorrectionBridge` for the keyboard to read. Asks decay to zero as the system
/// learns — confident one-off decisions are reviewable only on the transcript.
enum CorrectionAsksPublisher {
    static let maxAsks = 3
    static let contextWindow = 24

    static func publish(transcriptID: UUID, sessionID: UUID, publishedText: String) async {
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
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate, message: "keyboard asks: none",
                metadata: ["records": "\(payload.records.count)"])
            return
        }

        let overrides = await CorrectionStore.shared.snapshot()
        func prior(_ r: CorrectionProvenance.Record) -> Int {
            // Match the store's normalization exactly (lowercase + trim the same
            // punctuation set) so `prior` doesn't silently read 0 on a punctuated
            // original — which would drop its prior-desc ranking in the ask policy.
            let ow = Self.normalize(r.originalWord)
            let tm = r.term.lowercased()
            return overrides.first { $0.originalWord == ow && $0.term.lowercased() == tm }?.net ?? 0
        }

        // Worth asking on the keyboard: an APPLIED correction (the gate changed
        // your text — most worth a quick confirm), a mapping part-way to automatic
        // (prior > 0), or a low-confidence call (unsure). Confident KEPT blocks
        // (the gate correctly left the original) stay on the transcript only.
        // (Broader than the handoff's selectAsks, which deferred confident one-off
        // APPLYs to the transcript — but that left a fresh user seeing NO nudge.)
        let candidates: [CorrectionProvenance.Record] = unresolved.filter {
            $0.outcome == "applied" || prior($0) > 0 || $0.unsure
        }
        let ranked: [CorrectionProvenance.Record] = candidates.sorted { prior($0) > prior($1) }
        let selected: [CorrectionProvenance.Record] = Array(ranked.prefix(maxAsks))

        var asks: [CorrectionBridge.Ask] = []
        for r in selected {
            let (before, after) = context(of: r, in: publishedText)
            asks.append(CorrectionBridge.Ask(
                recordKey: r.key, original: r.originalWord, term: r.term,
                outcome: r.outcome, contextBefore: before, contextAfter: after))
        }
        guard !asks.isEmpty else {
            CorrectionBridge.clearAsks()
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate, message: "keyboard asks: none worth showing",
                metadata: ["unresolved": "\(unresolved.count)"])
            return
        }
        CorrectionBridge.publishAsks(
            CorrectionBridge.Asks(
                sessionID: sessionID, transcriptID: transcriptID, asks: Array(asks),
                // ALL unresolved proposals on the transcript (not just the ≤3
                // surfaced asks) — drives the keyboard "Done" stage's "N more
                // guesses are on the transcript in Jot." line.
                totalUnresolved: unresolved.count))
        // Signal the keyboard NOW that the asks exist (it can't reliably read them
        // at paste time — they're written after the ledger append). The keyboard
        // shows its nudge on this.
        CrossProcessNotification.post(name: CrossProcessNotification.correctionAsksReady)
        DiagnosticsLog.record(
            source: "main-app", category: .vocabularyGate, message: "keyboard asks published",
            metadata: ["asks": "\(asks.count)", "unresolved": "\(unresolved.count)",
                       "session": sessionID.uuidString])
    }

    /// Mirrors `CorrectionStore.normalize` so `prior` keys align.
    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'()"))
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
