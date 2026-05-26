import Foundation
import SwiftData

/// **CURRENT schema** as of the rewrite-feedback feature (Jot 1.0.2 build 11+).
///
/// Adds ONE field over `JotSchemaV2`:
/// - `rewriteUpvoted: Bool?` — explicit 👍 / 👎 rating the user gave the
///   current rewrite. `nil` = unrated (default), `true` = thumbs up,
///   `false` = thumbs down. The thumbs-down signal pairs with the
///   editable-transcripts `rewriteUserEdit` field — when the user marks
///   the rewrite as bad AND provides a correction via Edit, that pair is
///   the strongest possible training signal.
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field, copy
/// to `JotSchemaV4.swift`, add the field there, and append a `MigrationStage`
/// in `JotMigrationPlan.stages` from V3 → V4. `scripts/check-schema-frozen.sh`
/// enforces this mechanically.
///
/// ## Why a separate field instead of inferring from `rewriteUserEdit`
///
/// `rewriteUserEdit != nil` already implies the user disagreed with the
/// model. But a user who taps 👎 without bothering to type a correction
/// is ALSO valuable signal ("this was wrong but I didn't have time").
/// And a 👍 with no edit is meaningful too ("model nailed it"). Storing
/// the rating as an explicit field decouples it from the edit/correction
/// signal and captures both halves cleanly.
enum JotSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] { [JotSchemaV3.Transcript.self] }

    @Model
    final class Transcript {
        var id: UUID
        /// Raw transcript straight from Parakeet, before any LLM
        /// post-processing.
        ///
        /// Mutable: the Transcript Detail's "Edit Original" affordance
        /// overwrites this in place. The pre-edit Parakeet output is NOT
        /// persisted anywhere — the user's correction becomes the new
        /// ground truth.
        var text: String
        /// Post-cleanup output, if cleanup was enabled and succeeded.
        /// `nil` means "no cleanup ran or it failed" — the UI falls back
        /// to `text`.
        ///
        /// FROZEN as the "before" of a training pair while
        /// `rewriteUserEdit` is non-nil. Overwritten only by a fresh
        /// rewrite (Transform / Discard), and when it IS overwritten,
        /// both `rewriteUserEdit` AND `rewriteUpvoted` MUST be cleared
        /// in the same write — the rating was against the prior output.
        var cleanedText: String?
        var createdAt: Date
        var durationSeconds: Double?
        var ledgerIndex: Int

        var derivedFromID: UUID?

        var instruction: String?

        var supersededAt: Date?

        /// The user's manual edit to the current Rewrite. `nil` = no user
        /// edit; the model's `cleanedText` is canonical. Non-nil = user
        /// typed corrections.
        ///
        /// Persisted ALONGSIDE `cleanedText` (not replacing it). The pair
        /// `(cleanedText, rewriteUserEdit)` is the future-fine-tuning
        /// training signal: "model produced X, user corrected to Y."
        /// Reset to nil whenever `cleanedText` is overwritten (re-Transform,
        /// Discard rewrite).
        var rewriteUserEdit: String?

        /// User's explicit rating of the current Rewrite. `nil` =
        /// unrated, `true` = 👍, `false` = 👎. Decoupled from
        /// `rewriteUserEdit` so we capture pure-rating signal
        /// independently from edit/correction signal.
        ///
        /// Cleared (set to nil) whenever `cleanedText` is overwritten
        /// (re-Transform, Discard) — the rating was against the prior
        /// model output, not whatever just replaced it.
        ///
        /// `nil` on every V2 row migrated to V3 (lightweight additive).
        var rewriteUpvoted: Bool?

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
            rewriteUpvoted: Bool? = nil
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
        }
    }
}
