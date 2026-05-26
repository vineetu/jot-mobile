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
typealias Transcript = JotSchemaV4.Transcript

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
