import Foundation

/// Cross-process persistence for the user's `[SavedPrompt]`. Backed by the
/// App Group `UserDefaults` (key: `AppGroup.Keys.savedPrompts`) so the
/// keyboard extension reads the same list the main app's settings UI writes.
///
/// The list is small (typically 1–10 entries) so every mutation rewrites the
/// full array. JSON-encoded for forward-compatibility with future fields —
/// `UserDefaults` plist arrays of dictionaries would have been smaller but
/// would force us to hand-roll migration on schema bumps.
///
/// Sort contract: `all()` returns rows sorted by `sortOrder` ascending, with
/// ties broken by `createdAt` ascending (the seeded default has the lowest
/// `createdAt` so it sits at the top until the user reorders).
enum SavedPromptStore {

    /// Read the full list, sorted by `(sortOrder, createdAt)`. Returns an
    /// empty array if the AppGroup key is absent or the JSON fails to
    /// decode (e.g. forward-incompatible payload from a newer build).
    /// Callers that want the seeded default should call `seedIfNeeded()`
    /// first — `all()` does NOT auto-seed, so cross-process readers
    /// (keyboard extension) get a clean empty-list signal when the user
    /// genuinely has no prompts.
    static func all() -> [SavedPrompt] {
        guard let data = AppGroup.savedPromptsJSON else { return [] }
        do {
            let decoded = try JSONDecoder().decode([SavedPrompt].self, from: data)
            return decoded.sorted(by: orderingComparator)
        } catch {
            // Forward-incompatible or corrupted payload. Return empty so
            // the caller can decide whether to re-seed or surface an error.
            return []
        }
    }

    /// Replace the persisted list. Indices in `sortOrder` are normalized to
    /// `0..<count` (preserving the caller's relative order) so reorders
    /// don't accumulate gaps or duplicates over time.
    static func save(_ prompts: [SavedPrompt]) {
        let sorted = prompts.sorted(by: orderingComparator)
        let normalized: [SavedPrompt] = sorted.enumerated().map { index, prompt in
            var copy = prompt
            copy.sortOrder = index
            return copy
        }
        do {
            let data = try JSONEncoder().encode(normalized)
            AppGroup.savedPromptsJSON = data
        } catch {
            // Encoding a `[SavedPrompt]` cannot fail in practice (all fields
            // are Codable primitives). Swallow defensively rather than
            // crash a settings save on a release build.
        }
    }

    /// If the persisted list is empty (or absent), seed it with the bundled
    /// `SavedPrompt.defaultRewrite` entry. No-op when at least one row is
    /// present — the seeded default is ordinary data, not a sticky baseline,
    /// so users who delete it never see it come back.
    static func seedIfNeeded() {
        guard all().isEmpty else { return }
        save([SavedPrompt.defaultRewrite])
    }

    /// Append a new prompt. Caller supplies the `SavedPrompt` (id, createdAt,
    /// trimmed name/systemPrompt). `sortOrder` is overridden to "after the
    /// current last row" so new entries land at the bottom of the list.
    static func add(_ prompt: SavedPrompt) {
        var current = all()
        var copy = prompt
        copy.sortOrder = current.count
        current.append(copy)
        save(current)
    }

    /// Replace the row matching `prompt.id`. No-op when the id is unknown
    /// (defensive — a concurrent delete on the keyboard side could win the
    /// race; we don't resurrect deleted rows).
    static func update(_ prompt: SavedPrompt) {
        var current = all()
        guard let index = current.firstIndex(where: { $0.id == prompt.id }) else { return }
        // Preserve the existing sortOrder so an edit doesn't yank the row
        // out of its position. The full re-save will normalize indices.
        var copy = prompt
        copy.sortOrder = current[index].sortOrder
        current[index] = copy
        save(current)
    }

    /// Remove the row with the given id. No-op when the id is unknown.
    static func delete(id: UUID) {
        var current = all()
        current.removeAll { $0.id == id }
        save(current)
    }

    /// Apply a SwiftUI `.onMove` reorder. `source` and `destination` follow
    /// the `IndexSet` / `Int` semantics of `Array.move(fromOffsets:toOffset:)`.
    /// Indices are renumbered on save.
    static func reorder(source: IndexSet, destination: Int) {
        var current = all()
        current.move(fromOffsets: source, toOffset: destination)
        save(current)
    }

    // MARK: - Internals

    private static func orderingComparator(_ lhs: SavedPrompt, _ rhs: SavedPrompt) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.createdAt < rhs.createdAt
    }
}
