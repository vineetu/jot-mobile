import Foundation
import SwiftData

/// **CURRENT schema** — adds the dictation **language** to `Transcript`.
///
/// V7 → V8 is purely additive: ONE new optional field, `language: String?`, on
/// `Transcript` (the raw `LanguageChoice` value the recording was dictated in —
/// e.g. `"english"`, `"french"`). `nil` for every pre-existing V7 row; the UI /
/// Translate logic treats `nil` as English (multilingual dictation only just
/// shipped, so essentially all historical rows are English). Sibling to the
/// existing `source` provenance field ("watch"/"keyboard"/…). Drives the
/// language-aware Translate target list and the Transcript Detail language badge
/// (`docs/multilingual-dictation`).
///
/// Everything else (`TranscriptEmbedding`, `TranscriptCategory`,
/// `TranscriptChunk`, and the rest of `Transcript`) is IDENTICAL to
/// `JotSchemaV7`. The deprecated `TranscriptEmbedding` drop is still a separate
/// future `.custom` migration — NOT folded in here (one device-testable
/// migration at a time).
///
/// ## Frozen rule
///
/// Once this file ships in a build, do not modify it. To add a field, copy to
/// `JotSchemaV9.swift`, add the field there, and append a `MigrationStage` in
/// `JotMigrationPlan.stages` from V8 → V9. `scripts/check-schema-frozen.sh`
/// enforces this mechanically.
enum JotSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            JotSchemaV8.Transcript.self,
            JotSchemaV8.TranscriptEmbedding.self,
            JotSchemaV8.TranscriptCategory.self,
            JotSchemaV8.TranscriptChunk.self
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

        /// Dictation **language** (V8+) — the raw `LanguageChoice` value the
        /// recording was transcribed in (e.g. `"english"`, `"french"`,
        /// `"german"`). Sibling to `source`. `nil` for every pre-V8 row and any
        /// row where the language wasn't recorded; the UI / Translate logic
        /// treats `nil` as English (multilingual dictation only just shipped,
        /// so historical rows are English). Drives the language-aware Translate
        /// target list and the Detail language badge.
        var language: String?

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
            watchOriginUUID: String? = nil,
            language: String? = nil
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
            self.language = language
        }
    }

    /// **DEPRECATED** — old per-whole-transcript MiniLM-L6-v2 384-d embedding.
    /// Not read or written by the chunk pipeline; retained so the V7 → V8 step
    /// stays a safe additive `.lightweight` migration. Dropped in a future
    /// `.custom` migration once the chunk cutover is verified.
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
    /// Identical to `JotSchemaV7.TranscriptChunk`. `createdAt` /
    /// `durationSeconds` / `source` are denormalized copies of the parent
    /// transcript's fields, stamped at index time so the retrieval pre-filter
    /// can scope the chunk pool in a single fetch without a per-chunk join.
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
