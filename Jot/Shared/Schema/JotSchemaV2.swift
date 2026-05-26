import Foundation
import SwiftData

/// **CURRENT schema** as of the editable-transcripts feature (Jot 1.0.2 build 9+).
///
/// Adds ONE field over `JotSchemaV1`:
/// - `rewriteUserEdit: String?` — the user's manual edit to the current
///   `cleanedText` (the LLM rewrite output). When non-nil, this is the
///   "after" half of a `(modelOutput, userEdit)` pair used as a future
///   fine-tuning training signal. `cleanedText` stays frozen as the "before".
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field, copy
/// to `JotSchemaV3.swift`, add the field there, and append a `MigrationStage`
/// in `JotMigrationPlan.stages` from V2 → V3. `scripts/check-schema-frozen.sh`
/// enforces this mechanically.
///
/// ## Why only one new field (not a separate `RewriteTrainingPair` table)
///
/// The simpler model — one pair per transcript, inline — matches the
/// user's stated intent: "last edit against the current cleanedText wins."
/// On re-Transform, `rewriteUserEdit` is cleared (a stale edit against a
/// fresh model output is meaningless). On Discard rewrite, both are
/// cleared. The fine-tuning pipeline reads `(cleanedText, rewriteUserEdit)`
/// for every transcript where both are non-nil.
enum JotSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] { [JotSchemaV2.Transcript.self] }

    @Model
    final class Transcript {
        var id: UUID
        /// Raw transcript straight from Parakeet, before any LLM
        /// post-processing.
        ///
        /// Mutable: the Transcript Detail's "Edit Original" affordance
        /// overwrites this in place. The pre-edit Parakeet output is NOT
        /// persisted anywhere — the user's correction becomes the new
        /// ground truth. This is intentional per the editable-transcripts
        /// plan (we don't gather speech-model training data here).
        var text: String
        /// Post-cleanup output, if cleanup was enabled and succeeded.
        /// `nil` means "no cleanup ran or it failed" — the UI falls back
        /// to `text`.
        ///
        /// This field is reserved for AI Rewrite / Apple Foundation
        /// Models cleanup output. Lightweight regex filler-word cleanup
        /// (um/uh) is applied on render in the Original tab and is NOT
        /// persisted here — see `FillerWordCleaner` for the always-on
        /// regex sweep that runs in the dictation pipeline before publish
        /// but is not stored separately.
        ///
        /// FROZEN as the "before" of a training pair while
        /// `rewriteUserEdit` is non-nil. Overwritten only by a fresh
        /// rewrite (Transform / Discard), and when it IS overwritten,
        /// `rewriteUserEdit` MUST be nilled in the same write.
        var cleanedText: String?
        var createdAt: Date
        /// Wall-clock seconds between record start and stop. Optional
        /// because Shortcuts-invoked file transcriptions don't have a
        /// recording phase.
        var durationSeconds: Double?
        /// Monotonically increasing ledger number assigned at append time
        /// via `TranscriptStore.nextLedgerIndex()`. Stable across deletes.
        var ledgerIndex: Int

        /// ID of the transcript this one was "derived from" — i.e. the
        /// prior entry the user issued a voice command against (e.g.
        /// "make this more casual"). `nil` for a fresh dictation with
        /// no parent.
        ///
        /// This is a soft reference (raw `UUID`, not a SwiftData
        /// `@Relationship`) because deleting a parent shouldn't
        /// cascade-delete its children: the child is a real piece of
        /// content the user might still want to keep, independently of
        /// whether the parent has been tidied away. When the parent is
        /// missing, the UI falls back to rendering the child as a
        /// top-level entry (see `ContentView.computeClusters`).
        var derivedFromID: UUID?

        /// The user's voice command that produced this transcript (e.g.
        /// "make this more casual"). `nil` for fresh dictation; populated
        /// only on chained follow-ups. Rendered inline in the follow-up's
        /// eyebrow in the Ledger log.
        var instruction: String?

        /// Timestamp at which this transcript was explicitly marked as
        /// replaced by a later command-result. Distinct from the implicit
        /// "has a child via `derivedFromID`" signal because:
        ///
        /// - supersession is a *display-state* flag set by the intent
        ///   pipeline at command-result time, not a derived-from-the-graph
        ///   property,
        /// - an operator might want to mark a transcript superseded
        ///   without chaining (e.g., a manual "replace this with that"
        ///   UX in a future release), and
        /// - decoupling lets the Ledger dim superseded rows immediately
        ///   without waiting for a BFS over the full query result.
        ///
        /// The Ledger renders rows with `supersededAt != nil` at 0.55
        /// opacity with a `SUPERSEDED` mono chip. `nil` is the default
        /// — the overwhelming majority of transcripts are never superseded.
        var supersededAt: Date?

        /// The user's manual edit to the current Rewrite. `nil` = no user
        /// edit; the model's `cleanedText` is canonical. Non-nil = user
        /// typed corrections.
        ///
        /// Persisted ALONGSIDE `cleanedText` (not replacing it). The pair
        /// `(cleanedText, rewriteUserEdit)` is the future-fine-tuning
        /// training signal: "model produced X, user corrected to Y."
        ///
        /// Reset (set to nil) whenever `cleanedText` is overwritten — a
        /// stale userEdit against a new model output is meaningless.
        /// Specifically:
        ///   - On re-Transform → set new cleanedText, nil out
        ///     `rewriteUserEdit`.
        ///   - On Discard rewrite → both nilled.
        ///
        /// `displayText` priority: `rewriteUserEdit ?? cleanedText ?? text`.
        ///
        /// `nil` on every V1 row migrated to V2 (lightweight additive).
        var rewriteUserEdit: String?

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
            rewriteUserEdit: String? = nil
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
        }
    }
}
