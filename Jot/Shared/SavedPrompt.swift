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

    // MARK: - Built-in defaults

    /// Kind tag for the four bundled defaults seeded on first launch.
    /// Callers that need per-default UI (icon, tint, before/after samples)
    /// switch on this instead of duplicating id-comparison ladders.
    enum DefaultKind {
        case articulate
        case aiPrompt
        case actionItems
        case email
    }

    /// Resolve a prompt to one of the bundled `DefaultKind`s, or `nil` if
    /// it is a user-created prompt. Identity is keyed on the stable UUIDs
    /// below — once seeded, the user is free to rename or edit a default
    /// row's body, but the id stays stable so the UI keeps treating it as
    /// the right "kind."
    var defaultKind: DefaultKind? {
        switch self.id {
        case Self.defaultArticulate.id:  return .articulate
        case Self.defaultAIPrompt.id:    return .aiPrompt
        case Self.defaultActionItems.id: return .actionItems
        case Self.defaultEmail.id:       return .email
        default:                          return nil
        }
    }

    /// Articulate — Jot's #1 default. Rewrites the dictation for
    /// clarity: connects related ideas, removes repeated points, and
    /// preserves every distinct idea the speaker introduced. Drops the
    /// earlier voice-fidelity constraint (which capped how much the
    /// model could reorganize) in favor of idea-fidelity. The
    /// "do not invent" guardrail keeps Qwen from embellishing.
    ///
    /// Seed-only: this copy reaches fresh installs only. Existing
    /// users keep whatever Articulate prompt is already in their
    /// `SavedPromptStore` (`seedIfNeeded` short-circuits on a non-empty
    /// list). If you ever need a forced rollout, gate a migration on a
    /// `UserDefaults` bool and replace `SavedPrompt` rows whose
    /// `id == defaultArticulate.id` AND whose stored `systemPrompt`
    /// matches the previous canonical text.
    static let defaultArticulate: SavedPrompt = SavedPrompt(
        id: UUID(uuidString: "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1")!,
        // User-facing label is "Cleanup" (UX-overhaul round 2 WS-G): the
        // ActionBar's primary button is now "Articulate" and OPENS this
        // picker, whose primary/default row is this prompt — so the two
        // names can't collide. The stable id + `DefaultKind.articulate`
        // identity are unchanged; only the display string moves.
        name: "Cleanup",
        systemPrompt:
            "Rewrite this dictation for clarity. " +
            "Connect related ideas so they flow logically. " +
            "Group related ideas into paragraphs — new paragraph = a shift in topic or focus. " +
            "Cut repeated points — but keep every distinct idea the speaker mentioned. " +
            "Do not invent new ideas or details. " +
            "Fix obvious dictation errors. " +
            "Return only the rewrite.",
        createdAt: Date(timeIntervalSince1970: 0),
        sortOrder: 0
    )

    /// AI prompt — converts a rambling dictation into a clean,
    /// structured prompt the user can paste into Claude / ChatGPT /
    /// any other LLM. The shape (Context / Task / Requirements /
    /// Output) follows Anthropic's "be clear and direct" + long-
    /// context principles, mapped to markdown sections rather than
    /// XML tags so the output stays readable + editable for the
    /// user AND parseable for the receiving assistant. Cross-checked
    /// against Qwen 3's prompting guidance — Qwen's chat template
    /// handles wrapping internally, so XML inside user prompts
    /// would actually confuse it; markdown is the safer producer-
    /// side choice.
    static let defaultAIPrompt: SavedPrompt = SavedPrompt(
        id: UUID(uuidString: "B4B4B4B4-B4B4-B4B4-B4B4-B4B4B4B4B4B4")!,
        name: "AI prompt",
        systemPrompt:
            "Convert this dictation into a clear AI prompt the speaker can paste into Claude or another LLM. " +
            "Structure the output as: " +
            "**Context:** what the speaker is working on, has tried, or already knows. " +
            "**Task:** the specific ask in one clear sentence or short paragraph. " +
            "**Requirements:** any constraints, preferences, or limits they mentioned. " +
            "**Output:** desired response format, if specified. " +
            "Rules: " +
            "Preserve every concrete detail. Do not invent requirements they didn't state. " +
            "Omit any section with nothing to say — do not pad with filler. " +
            "Cut \"um\", \"uh\", restarts, \"you know\", \"like\". Direct written prose inside each section. " +
            "Put Context first, Task second — assistants work better when background is read before the ask. " +
            "Return only the structured prompt.",
        createdAt: Date(timeIntervalSince1970: 1),
        sortOrder: 1
    )

    /// Action Items — extract tasks/decisions/deadlines from a meeting or
    /// thought-dump dictation. Output is a clean one-line-per-item list.
    static let defaultActionItems: SavedPrompt = SavedPrompt(
        id: UUID(uuidString: "A2A2A2A2-A2A2-A2A2-A2A2-A2A2A2A2A2A2")!,
        name: "Action Items",
        systemPrompt:
            "Extract action items from this dictation. " +
            "List each as a one-line task with the responsible person if mentioned. " +
            "Include any deadlines. " +
            "Return only the list.",
        createdAt: Date(timeIntervalSince1970: 2),
        sortOrder: 2
    )

    /// Email — convert a dictation into a BLUF-style business email with
    /// a one-line subject. Keeps speaker voice. Returns the email body
    /// only (no commentary, no salutation choices for the user to pick).
    static let defaultEmail: SavedPrompt = SavedPrompt(
        id: UUID(uuidString: "E3E3E3E3-E3E3-E3E3-E3E3-E3E3E3E3E3E3")!,
        name: "Email",
        systemPrompt:
            "Convert this dictation into a business email. " +
            "Put the main point first (BLUF). " +
            "Add a one-line subject line. " +
            "Keep the speaker's voice. " +
            "Return only the email.",
        createdAt: Date(timeIntervalSince1970: 3),
        sortOrder: 3
    )

    /// All four bundled defaults in seed order. Used by
    /// `SavedPromptStore.seedIfNeeded` and by helpers that want to
    /// iterate the canonical built-ins.
    static let allDefaults: [SavedPrompt] = [
        .defaultArticulate,
        .defaultAIPrompt,
        .defaultActionItems,
        .defaultEmail
    ]
}
