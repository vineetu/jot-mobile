import Foundation
import SwiftData

/// Top-level alias for the current `Transcript` `@Model` type.
///
/// Always points at the latest `VersionedSchema`'s `Transcript`. Bump
/// this when a new VN ships (and update `JotModelContainer.shared` to
/// match — see `JotMigrationPlan.swift` for the full recipe).
///
/// The stored properties + initializer live in
/// `Jot/Shared/Schema/JotSchemaV1.swift`. Computed properties live in
/// the extension below so they automatically apply to whichever VN is
/// current.
typealias Transcript = JotSchemaV9.Transcript

/// **DEPRECATED (V7).** Old per-whole-transcript MiniLM 384-d embedding row.
/// Retained through V7 so the V6→V7 migration stays additive; not read or
/// written by the chunk pipeline. Dropped in a future migration.
typealias TranscriptEmbedding = JotSchemaV9.TranscriptEmbedding

/// **DORMANT (V7).** Former on-device classifier output row. The
/// classifier/tagging feature was removed — nothing reads or writes this
/// table anymore. The entity is retained in the schema (same deprecation
/// pattern as `TranscriptEmbedding`) so the V6→V7 migration stays additive;
/// it carries no live data and may be dropped in a future migration.
typealias TranscriptCategory = JotSchemaV9.TranscriptCategory

/// **DORMANT.** Former chunk-level embedding row (V7+) for the EmbeddingGemma
/// Ask pipeline. Ask retrieval moved to Core Spotlight, so nothing reads or
/// writes this table any more; the entity stays in the frozen schema (same
/// pattern as `TranscriptEmbedding`) and may be dropped in a future migration.
typealias TranscriptChunk = JotSchemaV9.TranscriptChunk

extension Transcript {
    /// Preferred surface text. Priority:
    ///   1. `rewriteUserEdit` — the user's manual correction of the LLM
    ///      rewrite, if they edited it.
    ///   2. `cleanedText` — the LLM rewrite output, if cleanup ran.
    ///   3. `text` — the raw Parakeet transcript (with the always-on regex
    ///      filler sweep already baked in by the dictation pipeline).
    ///
    /// Read by Recents rows, the keyboard history mirror, share + copy
    /// affordances, and any other consumer that asks "what should the user
    /// see for this transcript."
    var displayText: String { rewriteUserEdit ?? cleanedText ?? text }

    /// `true` when this transcript was produced by a chained follow-up
    /// command. The Ledger row uses this to swap its eyebrow layout.
    var isDerived: Bool { derivedFromID != nil }

    /// `true` when this transcript has been explicitly replaced by a later
    /// command-result. See `supersededAt` doc for semantics + why this is
    /// a separate flag from "has a child via `derivedFromID`".
    var isSuperseded: Bool { supersededAt != nil }
}
