import Foundation
import SwiftData

/// **CURRENT schema** as of the Ask RAG redesign (Phase 1).
///
/// V6 → V7 is purely additive — ONE new `@Model` entity alongside the
/// existing ones: `TranscriptChunk`. This is the chunk-level substrate for
/// the new retrieval pipeline (`docs/plans/ask-retrieval-architecture.md`):
/// each transcript is split into ~256-token chunks, each chunk carries its
/// own embedding + denormalized filter metadata.
///
/// **`TranscriptEmbedding` is retained but DEPRECATED in V7.** It is the old
/// per-whole-transcript MiniLM vector store. The new pipeline does not read
/// or write it; it will be dropped in a later `.custom` migration once the
/// chunk pipeline is fully cut over (one independently device-testable
/// migration at a time — see the design doc §4). Keeping it here makes
/// V6 → V7 a safe `.lightweight` additive step that cannot touch the user's
/// `Transcript` rows.
///
/// `Transcript`, `TranscriptEmbedding`, and `TranscriptCategory` are
/// IDENTICAL to `JotSchemaV6`.
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field,
/// copy to `JotSchemaV8.swift`, add the field there, and append a
/// `MigrationStage` in `JotMigrationPlan.stages` from V7 → V8.
/// `scripts/check-schema-frozen.sh` enforces this mechanically.
enum JotSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            JotSchemaV7.Transcript.self,
            JotSchemaV7.TranscriptEmbedding.self,
            JotSchemaV7.TranscriptCategory.self,
            JotSchemaV7.TranscriptChunk.self
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

    /// **DEPRECATED in V7** — old per-whole-transcript MiniLM-L6-v2 384-d
    /// embedding. Not read or written by the chunk pipeline; retained so
    /// V6 → V7 stays a safe additive `.lightweight` step. Dropped in a
    /// future `.custom` migration once the chunk cutover is verified.
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

    /// Substrate for the transcript classifier. Multiple rows per
    /// `transcriptID` are valid by design (different `classifierVersion`s).
    /// `CategoryStore.upsert` enforces one row per
    /// (`transcriptID`, `classifierVersion`).
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

    /// One chunk of a `Transcript` for the RAG retrieval pipeline (V7+).
    ///
    /// A transcript is split into ~256-token windows (`TranscriptChunker`);
    /// each window gets its own embedding so a specific idea inside a long
    /// recording is retrievable (vs. the old blurry whole-transcript vector).
    ///
    /// Storage: `vectorData` packs N IEEE-754 little-endian float32s (256 for
    /// EmbeddingGemma; whatever the active model emits). `modelVersion` is the
    /// discriminator (e.g. `"embeddinggemma-300m-256"` or, during the interim
    /// MiniLM-chunked phase, `"minilm-l6-chunked"`). A model swap writes rows
    /// under a new `modelVersion`; readers filter by the current version.
    ///
    /// Logical (not `@Relationship`) join to `Transcript.id` via
    /// `transcriptID`, same rationale as the old `TranscriptEmbedding`:
    /// chunks are re-buildable independent of `Transcript` lifecycle.
    ///
    /// `createdAt` / `durationSeconds` / `source` are **denormalized copies**
    /// of the parent transcript's fields, stamped at index time so the
    /// retrieval pre-filter (date / type / duration) can scope the chunk pool
    /// in a single fetch without a per-chunk `Transcript` join.
    @Model
    final class TranscriptChunk {
        var id: UUID
        var transcriptID: UUID
        var chunkIndex: Int
        var text: String
        var vectorData: Data
        var charStart: Int
        var charEnd: Int
        var modelVersion: String
        var embeddedAt: Date

        // Denormalized parent-transcript filter metadata (see doc above).
        var createdAt: Date
        var durationSeconds: Double?
        var source: String?

        init(
            id: UUID = UUID(),
            transcriptID: UUID,
            chunkIndex: Int,
            text: String,
            vectorData: Data,
            charStart: Int,
            charEnd: Int,
            modelVersion: String,
            embeddedAt: Date = Date(),
            createdAt: Date,
            durationSeconds: Double? = nil,
            source: String? = nil
        ) {
            self.id = id
            self.transcriptID = transcriptID
            self.chunkIndex = chunkIndex
            self.text = text
            self.vectorData = vectorData
            self.charStart = charStart
            self.charEnd = charEnd
            self.modelVersion = modelVersion
            self.embeddedAt = embeddedAt
            self.createdAt = createdAt
            self.durationSeconds = durationSeconds
            self.source = source
        }
    }
}
