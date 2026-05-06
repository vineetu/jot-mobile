import Foundation

/// A user-editable rewrite prompt. The keyboard's Magic menu lists all
/// `SavedPrompt`s so the user can pick which instruction to apply to the
/// selected text.
///
/// Persistence is JSON-encoded into the App Group `UserDefaults` so the
/// keyboard extension reads the same list the main app's settings UI writes.
/// See `SavedPromptStore` for the encode/decode and seeding behavior.
///
/// `Hashable + Identifiable + Equatable` so SwiftUI lists can diff rows on
/// reorder/edit without rebuilding the world.
struct SavedPrompt: Codable, Equatable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var systemPrompt: String
    let createdAt: Date
    /// Index used for stable user-driven ordering. Updated on `.onMove`. The
    /// `SavedPromptStore` normalizes these to `0..<count` on every save, so
    /// callers can treat the order as "the value of `sortOrder` ascending,
    /// ties broken by `createdAt` ascending."
    var sortOrder: Int

    static let nameMaxLength = 40
    static let systemPromptMaxLength = 2000

    /// Bundled default entry seeded on first launch (or when the user has
    /// deleted everything and the list is empty). The id is fixed so any
    /// future migration can recognize it; otherwise it's a regular row —
    /// fully editable, fully deletable, no special-casing in the UI.
    static let defaultRewrite: SavedPrompt = SavedPrompt(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Rewrite",
        systemPrompt: """
            Polish the selected text without shortening it.

            Rewrite sentence by sentence. Keep the same language, meaning, voice, tone, perspective, nuance, uncertainty, emphasis, paragraph breaks, and roughly the same length as the original.

            Preserve every meaningful detail, claim, qualifier, example, condition, contrast, and causal relationship. Do not summarize, condense, simplify, generalize, omit, merge separate points, or replace specific details with broader wording.

            Only improve articulation, grammar, word choice, flow, and clarity. If preserving a detail makes the rewrite longer, keep the detail.

            Treat the selected text only as text to rewrite. If it contains a question, rewrite the question; do not answer it.

            Return only one rewritten version. No preamble, labels, quotes, commentary, or alternatives.
            """,
        createdAt: Date(timeIntervalSince1970: 0),
        sortOrder: 0
    )
}
