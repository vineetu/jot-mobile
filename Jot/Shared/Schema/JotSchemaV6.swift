import Foundation
import SwiftData

/// **CURRENT schema** as of the MiniLM embedding foundation (Jot 1.0.3 build 47+).
///
/// V5 → V6 is purely additive — TWO new `@Model` entities alongside the
/// existing `Transcript`:
///
/// - `TranscriptEmbedding(transcriptID, vectorData, modelVersion, embeddedAt)`
///   — 384-d MiniLM-L6-v2 sentence embeddings, written inline at capture
///   time and backfilled by `EmbeddingBackfillTask`. Logical join to
///   `Transcript.id` (no SwiftData `@Relationship` so the table can be
///   re-populated independent of Transcript lifecycle).
///
/// - `TranscriptCategory(transcriptID, category, confidence, classifierVersion,
///   assignedAt)` — substrate for a future classifier (embedding-based,
///   re-introduced Qwen, or user-manual tags). **No writers in this PR.**
///   Multiple rows per transcript are valid by design (different
///   `classifierVersion`s can disagree; user-manual tag can coexist with
///   automated label).
///
/// `Transcript`'s shape is IDENTICAL to `JotSchemaV5.Transcript`. The
/// `category` field is retained but flagged DEAD-DATA — see the banner
/// above the declaration.
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field,
/// copy to `JotSchemaV7.swift`, add the field there, and append a
/// `MigrationStage` in `JotMigrationPlan.stages` from V6 → V7.
/// `scripts/check-schema-frozen.sh` enforces this mechanically.
enum JotSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            JotSchemaV6.Transcript.self,
            JotSchemaV6.TranscriptEmbedding.self,
            JotSchemaV6.TranscriptCategory.self
        ]
    }

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

        // DEAD-DATA — DO NOT READ OR WRITE.
        // From V6 onward, classification lives in `TranscriptCategory`.
        // This field is retained only because dropping it requires a
        // `.custom` migration that is out of scope for this PR. Values
        // that existed in V4/V5 (from prior Qwen classifier runs) are
        // preserved in place but ignored by every V6 code path. A future
        // classifier writes to `TranscriptCategory.classifierVersion`,
        // never here.
        var category: String? // legacy — DEAD-DATA, see banner above

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

    /// MiniLM-L6-v2 sentence embedding for one `Transcript`.
    ///
    /// Storage shape: 384 IEEE-754 little-endian floats packed into
    /// `vectorData` (1536 bytes per row). At 10k transcripts that's
    /// ~15 MB on disk; at 100k it's ~150 MB — see plan §Open question 3.
    ///
    /// Logical (not SwiftData `@Relationship`) join to `Transcript.id` via
    /// `transcriptID`. NOT `@Attribute(.unique)` in v1 because lightweight
    /// migration on a `.unique` constraint of a new-entity field is
    /// inconsistent across iOS versions; `EmbeddingStore.upsert` enforces
    /// one-row-per-(transcriptID, modelVersion) by fetch-then-insert/update.
    ///
    /// `modelVersion` is a string discriminator (e.g. `"minilm-l6-v2"`).
    /// A future encoder swap writes rows with a new `modelVersion` and the
    /// old rows stay in place — Garden / similarity reads filter by the
    /// current version, the BG sweep backfills the new version, the old
    /// rows can be reaped later. See plan §Storage architecture.
    @Model
    final class TranscriptEmbedding {
        var transcriptID: UUID
        var vectorData: Data
        var modelVersion: String
        var embeddedAt: Date

        init(
            transcriptID: UUID,
            vectorData: Data,
            modelVersion: String,
            embeddedAt: Date = Date()
        ) {
            self.transcriptID = transcriptID
            self.vectorData = vectorData
            self.modelVersion = modelVersion
            self.embeddedAt = embeddedAt
        }
    }

    /// Substrate for a future transcript classifier. **No writers in this PR.**
    ///
    /// Multiple rows per `transcriptID` are valid by design — they
    /// represent different classifier versions disagreeing, a user-manual
    /// tag coexisting with an automated label, or A/B comparison of two
    /// classifier schemes. `CategoryStore.upsert` enforces one row per
    /// (`transcriptID`, `classifierVersion`).
    ///
    /// `classifierVersion` is the discriminator (mirrors
    /// `TranscriptEmbedding.modelVersion`). Examples:
    /// - `"minilm-centroids-v1"` — embedding-based classifier (future)
    /// - `"qwen-3.5b-5class-v1"` — historical Qwen classifier (if ever
    ///   revived). Note: the legacy `Transcript.category` field is NOT
    ///   migrated into this table; those values stay on the Transcript
    ///   row as dead data.
    /// - `"user-manual"` — user-applied tag (future). `confidence` is `nil`.
    ///
    /// **Do NOT write to `Transcript.category` from new code.** That
    /// field is dead-data from V6 onward — see the banner on
    /// `JotSchemaV6.Transcript.category` and the docs in `CategoryStore`.
    @Model
    final class TranscriptCategory {
        var transcriptID: UUID
        var category: String
        var confidence: Float?
        var classifierVersion: String
        var assignedAt: Date

        init(
            transcriptID: UUID,
            category: String,
            confidence: Float? = nil,
            classifierVersion: String,
            assignedAt: Date = Date()
        ) {
            self.transcriptID = transcriptID
            self.category = category
            self.confidence = confidence
            self.classifierVersion = classifierVersion
            self.assignedAt = assignedAt
        }
    }
}
