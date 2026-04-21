import Foundation
import SwiftData

/// SwiftData bridge for the keyboard history mirror.
///
/// ## Why this lives in `Shared/` and not `App/`
///
/// keyboard-engineer-2's original plan placed this extension in an
/// `App/`-only file, reasoning that the keyboard target "never imports
/// SwiftData, never touches a `@Model` type." That reasoning assumed
/// `Transcript` lived in `App/Models/`. When `Transcript` moved to
/// `Shared/` to unblock the cross-target build (SourceKit wasn't lying —
/// `TranscriptStore` in `Shared/` really couldn't see a type that only
/// compiled into the main target), the compile-time isolation evaporated:
/// the keyboard target now compiles `Transcript` + `SwiftData` as a
/// transitive dep either way.
///
/// The architectural invariant that matters — *the keyboard process must
/// never open a `ModelContainer` or construct a `ModelContext`* — is
/// preserved by runtime behavior, not source-file location. The keyboard
/// only ever calls `TranscriptHistoryMirror.load()` (pure JSON, zero
/// SwiftData). `refresh(from:)` is called exclusively from the main-app
/// pipeline (`TranscriptStore.append` and `JotApp.body.task`), never from
/// keyboard code paths.
///
/// Placing the bridge here keeps the call site in `TranscriptStore.append`
/// simple — no conditional compilation, no weak-linked protocol, no
/// "call this from every caller instead of the insert path." The
/// keyboard target will compile this file and silently never invoke it.
///
/// ## What it does
///
/// Queries the shared SwiftData store for the most recent
/// `TranscriptHistoryMirror.maxEntries` rows, projects each to a
/// `TranscriptHistoryMirror.Entry` (the flat Codable type the keyboard
/// reads), and writes the array atomically to the App Group JSON mirror.
///
/// Called in two places:
///
/// - `TranscriptStore.append(...)` — after each successful insert, so the
///   next keyboard presentation sees the new row.
/// - `JotApp.body.task` — once on cold launch, so a fresh install or
///   post-reinstall keyboard sees pre-existing history without waiting
///   for the next dictation.
///
/// Failures are swallowed by `write(_:)` — the mirror is a convenience
/// projection, never a correctness dependency. A missing or stale mirror
/// degrades to "keyboard shows older snapshot" rather than breaking the
/// successful SwiftData insert.
extension TranscriptHistoryMirror {
    /// Fetch the most recent `maxEntries` transcripts and overwrite the
    /// App Group JSON mirror.
    ///
    /// `@MainActor` because `ModelContext` is not `Sendable` and all Jot's
    /// write paths already run on the main actor — keeping this isolation
    /// aligned means no actor hop is needed when called from
    /// `TranscriptStore.append`.
    ///
    /// - Parameter context: a `ModelContext` bound to
    ///   `JotModelContainer.shared`. Callers from `TranscriptStore.append`
    ///   pass their insert-time context (it already sees the pending
    ///   save); cold-launch bootstrap passes a fresh one.
    @MainActor
    static func refresh(from context: ModelContext) {
        // Filter superseded rows at the fetch step. Keyboard's 20-row budget
        // is precious — giving slots to rows the main-app Ledger explicitly
        // dims + labels SUPERSEDED halves the useful list after a few
        // follow-up chains. Keyboard is an "insert something useful fast"
        // surface; stale ≠ useful.
        //
        // Keeping the `Entry` schema lean (no `supersededAt` projection)
        // means no JSON bloat for a field the keyboard has no UI to render
        // anyway — there's no real estate for a SUPERSEDED chip next to the
        // `#NNNN` ledger-index chip on a keyboard row.
        //
        // Cross-file ordering contract with
        // `Jot/App/Intents/DictationPipeline.swift`:
        // `completeEndOfRecording`'s `.command` branch calls
        // `TranscriptStore.markSuperseded(parent)` *before*
        // `TranscriptStore.append(child, derivedFrom: parent.id, ...)`.
        // By the time this `refresh` fires from the child's post-save
        // hook, the parent is already flagged and this predicate filters
        // it out atomically with the child's insert becoming visible.
        //
        // Failure mode if that ordering is flipped: the parent row leaks
        // into the keyboard's 20-row budget until the next write-triggered
        // refresh — which could be minutes away, or never for the final
        // dictation of a session. The pipeline file documents the two
        // rollback-safe alternatives that would let the order flip (extra
        // refresh call after `markSuperseded`, or marking inside the
        // mirror writer) — read there before changing either side.
        var descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate<Transcript> { $0.supersededAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = maxEntries
        guard let rows = try? context.fetch(descriptor) else { return }

        let entries = rows.map { row in
            Entry(
                id: row.id,
                // `displayText` prefers cleaned over raw — matches what
                // the main-app Ledger shows, keyboard parity on the
                // text the user actually sees.
                text: row.displayText,
                createdAt: row.createdAt,
                ledgerIndex: row.ledgerIndex
            )
        }
        write(entries)
    }
}
