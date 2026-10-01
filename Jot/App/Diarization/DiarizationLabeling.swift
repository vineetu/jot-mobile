import Foundation

/// Turns the diarizer's exclusive speech runs into the persisted speaker turns.
/// The run geometry — solo gate, phantom fold, merge/coalesce, gap fill,
/// short-run fold — is `DiarizationProjection.speakerRuns`, shared verbatim with
/// Jot for Mac; this type owns what only the iPhone does with the runs:
/// anonymous "Speaker N" labels and the proportional text split.
///
/// No owner recognition: Nemotron 3 has no voice fingerprint, so every speaker
/// is anonymous, numbered by first appearance (stable across re-runs on the
/// same recording). Jot for Mac made the same call.
enum DiarizationLabeling {

    /// The persisted rows for a recording, or `nil` when it is a single speaker
    /// (the solo gate said so, or folding left one voice) — the caller then
    /// stores nothing and shows "Single speaker". The shared builder behind both
    /// the manual "Detect speakers" action (TranscriptDetailView) and the
    /// share-import auto-diarize (PendingShareDrainer), so they can't drift.
    static func persistedRows(
        runs: [DiarSegment],
        duration: Double,
        transcriptText: String
    ) -> [PersistedSpeakerRow]? {
        guard let turns = DiarizationProjection.speakerRuns(from: runs, duration: duration) else { return nil }
        var order: [String] = []
        for turn in turns where !order.contains(turn.speakerId) { order.append(turn.speakerId) }
        let rows: [PersistedSpeakerRow] = distributeText(transcriptText, turns: turns).compactMap { turn, text in
            // Drop empty turns (a span whose proportional share rounded to zero
            // words) — they rendered as bare "Speaker 2:" lines.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let number = (order.firstIndex(of: turn.speakerId) ?? 0) + 1
            return PersistedSpeakerRow(
                label: "Speaker \(number)",
                start: Float(turn.start),
                end: Float(turn.end),
                text: trimmed
            )
        }
        // Folding empty turns can leave one voice; that's a single speaker.
        guard Set(rows.map(\.label)).count > 1 else { return nil }
        return rows
    }

    /// Proportional-by-time text split across the turns (the Mac design's
    /// fallback for engines without per-word speaker timing: "accurate to
    /// within one word at each boundary"). The turns are gap-free over the
    /// recording, so each gets the share of words matching its share of time.
    static func distributeText(
        _ text: String, turns: [DiarSegment]
    ) -> [(turn: DiarSegment, text: String)] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, !turns.isEmpty else { return [] }
        let total = turns.reduce(0.0) { $0 + max(0, $1.duration) }
        guard total > 0 else { return [] }

        var result: [(DiarSegment, String)] = []
        var wordIndex = 0
        for (i, turn) in turns.enumerated() {
            let isLast = i == turns.count - 1
            let share = max(0, turn.duration) / total
            let count = isLast ? words.count - wordIndex : Int((share * Double(words.count)).rounded())
            let end = min(words.count, wordIndex + max(0, count))
            let slice = wordIndex < end ? words[wordIndex..<end].joined(separator: " ") : ""
            result.append((turn, slice))
            wordIndex = end
        }
        return result
    }
}
