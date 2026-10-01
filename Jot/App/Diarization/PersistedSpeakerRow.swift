import Foundation

/// One persisted speaker turn — the on-disk shape behind `Transcript.diarizationJSON`
/// (schema V9). A diarization result is stored as a JSON-encoded
/// `[PersistedSpeakerRow]` so it survives relaunch and lives exactly as long as
/// the transcript (see `docs/plans/speaker-notes-productization.md`).
///
/// The `label` is the RESOLVED display name frozen at diarization time
/// ("Speaker 2"; rows saved before the 2026-09-27 Nemotron 3 switch may say
/// "You" — the retired pyannote owner voiceprint). Stored rows are never
/// relabeled. `text` is the proportional-by-time
/// slice of the transcript assigned to this turn (`DiarizationLabeling.distributeText`),
/// so the whole result is invalidated (`updateDiarization(id:, nil)`) whenever the
/// underlying text changes — the stored slices can't be cheaply re-derived.
///
/// Purely a `Codable` value type — NOT a SwiftData `@Model`. It rides inside the
/// single `diarizationJSON` string field, so it needs no migration of its own.
struct PersistedSpeakerRow: Codable, Identifiable, Equatable {
    /// Stable per-row identity for `ForEach`. Not persisted — re-minted on each
    /// decode (the rows are always rendered as an ordered list, never addressed
    /// individually across launches).
    var id = UUID()

    /// Display label frozen at diarization time ("Speaker 2").
    let label: String
    /// Turn start, seconds from the recording's origin.
    let start: Float
    /// Turn end, seconds from the recording's origin.
    let end: Float
    /// Proportional-by-time slice of the transcript text for this turn.
    let text: String

    private enum CodingKeys: String, CodingKey {
        case label, start, end, text
    }

    init(label: String, start: Float, end: Float, text: String) {
        self.label = label
        self.start = start
        self.end = end
        self.text = text
    }

    /// Encode a diarization result to the `diarizationJSON` string. Returns `nil`
    /// on an empty result or an (unexpected) encode failure so callers store
    /// nothing rather than an empty array.
    static func encode(_ rows: [PersistedSpeakerRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode the `diarizationJSON` string back to rows. Returns `nil` for `nil`
    /// input or malformed JSON (defensive — a bad blob shouldn't crash a read).
    static func decode(_ json: String?) -> [PersistedSpeakerRow]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let rows = try? JSONDecoder().decode([PersistedSpeakerRow].self, from: data),
              !rows.isEmpty else { return nil }
        return rows
    }
}
