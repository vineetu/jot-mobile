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
typealias Transcript = JotSchemaV1.Transcript

extension Transcript {
    /// Preferred surface text: AI Rewrite cleanup if present, else the raw
    /// transcript. The always-on regex filler-word sweep is baked into
    /// `text` at publish time by `FillerWordCleaner`, so there is no
    /// separate stored field for lexical cleanup.
    var displayText: String { cleanedText ?? text }

    /// `true` when this transcript was produced by a chained follow-up
    /// command. The Ledger row uses this to swap its eyebrow layout.
    var isDerived: Bool { derivedFromID != nil }

    /// `true` when this transcript has been explicitly replaced by a later
    /// command-result. See `supersededAt` doc for semantics + why this is
    /// a separate flag from "has a child via `derivedFromID`".
    var isSuperseded: Bool { supersededAt != nil }
}
