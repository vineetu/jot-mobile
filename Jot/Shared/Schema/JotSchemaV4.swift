import Foundation
import SwiftData

/// **CURRENT schema** as of the transcript-classifier feature (Jot 1.0.2 build 12+).
///
/// Adds ONE field over `JotSchemaV3`:
/// - `category: String?` — background classifier's tag for the transcript.
///   `nil` until classified (the default for fresh dictations and for
///   pre-V4 rows on first read). When set, one of `email | message |
///   note | code | general`. Written by `TranscriptClassifier` from a
///   `BGProcessingTask` triggered by the Lab toggle `jot.classifier.enabled`.
///
/// In v1, nothing surfaces `category` to the user. The field accumulates
/// a tagged corpus on-device for future personalization research (style
/// fine-tuning, context-aware rewrite prompts).
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field,
/// copy to `JotSchemaV5.swift`, add the field there, and append a
/// `MigrationStage` in `JotMigrationPlan.stages` from V4 → V5.
/// `scripts/check-schema-frozen.sh` enforces this mechanically.
enum JotSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] { [JotSchemaV4.Transcript.self] }

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

        /// Background classifier's category for this transcript. `nil` =
        /// not yet classified, OR the user toggled the classifier off
        /// before this row could be processed. Otherwise one of the
        /// canonical category strings: `"email"`, `"message"`, `"note"`,
        /// `"code"`, `"general"`.
        ///
        /// Written ONLY from `TranscriptClassifier` running inside a
        /// `BGProcessingTask`. Never re-classified after the user edits
        /// the transcript — v1 classifies once. (Future builds may
        /// add a re-classify-on-edit policy.)
        ///
        /// `nil` on every V3 row migrated to V4 (lightweight additive).
        /// The classifier picks up the backlog on its first BG task fire.
        var category: String?

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
            category: String? = nil
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
        }
    }
}
