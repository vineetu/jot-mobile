import Foundation
import SwiftData

/// SwiftData-backed row for Jot's transcript history (the "ledger").
///
/// ## Why both `text` and `cleanedText`
///
/// The raw Parakeet transcript is the ground truth of what the user said; the
/// cleaned version is an LLM-rewritten variant that applies whatever cleanup
/// instructions the user configured. We keep both so:
///
/// - the UI can surface the cleaner version by default via `displayText`,
/// - the user can toggle cleanup off retroactively without losing data,
/// - future "revert to raw" or "re-clean with different prompt" features cost
///   zero migration.
///
/// ## Why `ledgerIndex`
///
/// The `#NNNN` chip in the instrument pill row is a stable identity for the
/// user — "the note from this morning was #0041". If we derived the number
/// from position in the query result, deleting an earlier entry would shift
/// every subsequent label. Persisting the index means deletes leave gaps
/// (expected and correct), not reshuffles.
///
/// ## Threading note
///
/// `@Model` classes are **not** `Sendable` and must be mutated/read on the
/// `ModelContext` that owns them. `TranscriptStore.append` and `ContentView`'s
/// `@Query`/`@Environment(\.modelContext)` both run on `@MainActor`, so we stay
/// single-threaded end-to-end. Keep it that way when adding writers.
@Model
final class Transcript {
    var id: UUID
    /// Raw transcript straight from Parakeet, before any LLM post-processing.
    var text: String
    /// Post-cleanup output, if cleanup was enabled and succeeded. `nil` means
    /// "no cleanup ran or it failed" — the UI falls back to `text`.
    ///
    /// This field is reserved for AI Rewrite / Apple Foundation Models cleanup
    /// output. Lightweight regex filler-word cleanup (um/uh) is applied on
    /// render in the Original tab and is NOT persisted here — see
    /// `FillerWordCleaner` for the always-on regex sweep that runs in the
    /// dictation pipeline before publish but is not stored separately.
    var cleanedText: String?
    var createdAt: Date
    /// Wall-clock seconds between record start and stop. Optional because
    /// Shortcuts-invoked file transcriptions don't have a recording phase.
    var durationSeconds: Double?
    /// Monotonically increasing ledger number assigned at append time via
    /// `TranscriptStore.nextLedgerIndex()`. Stable across deletes — see doc
    /// at top of type.
    var ledgerIndex: Int

    /// ID of the transcript this one was "derived from" — i.e. the prior
    /// entry the user issued a voice command against (e.g. "make this more
    /// casual"). `nil` for a fresh dictation with no parent.
    ///
    /// This is a soft reference (raw `UUID`, not a SwiftData `@Relationship`)
    /// because deleting a parent shouldn't cascade-delete its children: the
    /// child is a real piece of content the user might still want to keep,
    /// independently of whether the parent has been tidied away. When the
    /// parent is missing, the UI falls back to rendering the child as a
    /// top-level entry (see `ContentView.computeClusters`).
    var derivedFromID: UUID?

    /// The user's voice command that produced this transcript (e.g. "make
    /// this more casual"). `nil` for fresh dictation; populated only on
    /// chained follow-ups. Rendered inline in the follow-up's eyebrow in
    /// the Ledger log.
    var instruction: String?

    /// Timestamp at which this transcript was explicitly marked as replaced
    /// by a later command-result. Distinct from the implicit "has a child
    /// via `derivedFromID`" signal because:
    ///
    /// - supersession is a *display-state* flag set by the intent pipeline
    ///   at command-result time, not a derived-from-the-graph property,
    /// - an operator might want to mark a transcript superseded without
    ///   chaining (e.g., a manual "replace this with that" UX in a future
    ///   release), and
    /// - decoupling lets the Ledger dim superseded rows immediately without
    ///   waiting for a BFS over the full query result.
    ///
    /// The Ledger renders rows with `supersededAt != nil` at 0.55 opacity
    /// with a `SUPERSEDED` mono chip. `nil` is the default — the overwhelming
    /// majority of transcripts are never superseded.
    var supersededAt: Date?

    init(
        id: UUID = UUID(),
        text: String,
        cleanedText: String? = nil,
        createdAt: Date = Date(),
        durationSeconds: Double? = nil,
        ledgerIndex: Int,
        derivedFromID: UUID? = nil,
        instruction: String? = nil,
        supersededAt: Date? = nil
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
    }

    /// Preferred surface text: AI Rewrite cleanup if present, else the raw
    /// transcript. The always-on regex filler-word sweep is baked into `text`
    /// at publish time by `FillerWordCleaner`, so there is no separate
    /// stored field for lexical cleanup.
    var displayText: String { cleanedText ?? text }

    /// `true` when this transcript was produced by a chained follow-up
    /// command. The Ledger row uses this to swap its eyebrow layout.
    var isDerived: Bool { derivedFromID != nil }

    /// `true` when this transcript has been explicitly replaced by a later
    /// command-result. See `supersededAt` doc for semantics + why this is a
    /// separate flag from "has a child via `derivedFromID`".
    var isSuperseded: Bool { supersededAt != nil }
}
