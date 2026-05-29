import Foundation
import SwiftData

/// **CURRENT schema** as of the Apple Watch dictation feature (Jot 1.0.4+).
///
/// Adds TWO fields over `JotSchemaV4`:
/// - `source: String?` — capture surface tag. Values: `"watch"`, `"app"`,
///   `"keyboard"`, `"shortcut"`, `"file"`. `nil` for pre-V5 records and
///   for fresh records where the writer didn't set it (UI treats `nil`
///   as equivalent to `"app"`). The watch app's list view shows a
///   watch glyph only on rows where `source == "watch"`; other sources
///   render without a glyph for v1.
/// - `watchOriginUUID: String?` — UUID stamped on watch-originated
///   recordings. Used phone-side to de-dup if the watch retransmits a
///   file before the phone's ack arrives. Phone keeps a Set<UUID> of
///   recently-received IDs (last 100, TTL 24h) AND does a SwiftData
///   lookup for safety: if a transcript with this `watchOriginUUID`
///   already exists, the duplicate is silently discarded. `nil` for
///   every non-watch-originated row.
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field,
/// copy to `JotSchemaV6.swift`, add the field there, and append a
/// `MigrationStage` in `JotMigrationPlan.stages` from V5 → V6.
/// `scripts/check-schema-frozen.sh` enforces this mechanically.
enum JotSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] { [JotSchemaV5.Transcript.self] }

    @Model
    final class Transcript {
        var id: UUID
        /// Raw transcript straight from Parakeet, before any LLM
        /// post-processing. Mutable via "Edit Original."
        var text: String
        /// Post-cleanup output, if cleanup was enabled and succeeded.
        /// FROZEN as the "before" of a training pair while
        /// `rewriteUserEdit` or `rewriteUpvoted` are non-nil.
        var cleanedText: String?
        var createdAt: Date
        var durationSeconds: Double?
        var ledgerIndex: Int

        var derivedFromID: UUID?

        var instruction: String?

        var supersededAt: Date?

        /// The user's manual edit to the current Rewrite (V2+).
        var rewriteUserEdit: String?

        /// User's 👍/👎 rating on the current Rewrite (V3+). `nil`
        /// unrated, `true` thumbs up, `false` thumbs down. Cleared
        /// alongside `rewriteUserEdit` whenever `cleanedText` changes.
        var rewriteUpvoted: Bool?

        /// Background classifier's category for this transcript (V4+).
        /// `nil` = not yet classified. Otherwise one of: `"email"`,
        /// `"message"`, `"note"`, `"code"`, `"general"`.
        var category: String?

        /// Capture surface tag (V5+). Documented values:
        /// - `"watch"` — recorded on Apple Watch
        /// - `"app"` — recorded in main iOS app (default for pre-V5 + nil)
        /// - `"keyboard"` — recorded via keyboard extension
        /// - `"shortcut"` — recorded via DictateIntent (Shortcuts / Action Button)
        /// - `"file"` — transcribed from audio file (TranscribeAudioFileIntent)
        ///
        /// `nil` for every V4 row migrated to V5 (lightweight additive).
        /// UI treats `nil` as `"app"` for display purposes.
        var source: String?

        /// UUID stamped on watch-originated recordings (V5+). Used by
        /// phone-side WCSession delegate to de-dup if the watch
        /// retransmits a file before its ack arrives. `nil` for every
        /// non-watch row.
        var watchOriginUUID: String?

        init(
            id: UUID = UUID(),
            text: String,
            cleanedText: String? = nil,
            createdAt: Date = Date(),
            durationSeconds: Double? = nil,
            ledgerIndex: Int,
            derivedFromID: UUID? = nil,
            instruction: String? = nil,
            supersededAt: Date? = nil,
            rewriteUserEdit: String? = nil,
            rewriteUpvoted: Bool? = nil,
            category: String? = nil,
            source: String? = nil,
            watchOriginUUID: String? = nil
        ) {
            self.id = id
            self.text = text
            self.cleanedText = cleanedText
            self.createdAt = createdAt
            self.durationSeconds = durationSeconds
            self.ledgerIndex = ledgerIndex
            self.derivedFromID = derivedFromID
            self.instruction = instruction
            self.supersededAt = supersededAt
            self.rewriteUserEdit = rewriteUserEdit
            self.rewriteUpvoted = rewriteUpvoted
            self.category = category
            self.source = source
            self.watchOriginUUID = watchOriginUUID
        }
    }
}
