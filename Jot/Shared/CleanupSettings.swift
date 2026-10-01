import Foundation

/// User-facing **Automatic cleanup** configuration (features.md §7.14),
/// persisted in the App Group so the keyboard extension can read the same
/// settings as the main app.
///
/// When `enabled`, every fresh dictation is run through one of the user's
/// saved prompts on Apple Foundation Models (`RewriteClient`) right after
/// transcription. `pasteCleanedText` decides what the keyboard pastes:
/// - `true`  — the pipeline waits for the cleanup and pastes the cleaned text
///             (the user sees a short "Cleaning up…" state).
/// - `false` — the raw transcript pastes immediately and the cleaned text
///             lands in the note's Rewrite tab a few seconds later.
///
/// The prompt is referenced by its saved-prompt id so edits to the prompt
/// propagate; the resolved instruction text is also mirrored into
/// `cleanupInstructions` for readers that only need the text.
struct CleanupSettings {
    var enabled: Bool
    /// Which saved prompt cleans dictations. `nil` ⇒ the built-in Cleanup
    /// prompt (`SavedPrompt.defaultArticulate`).
    var promptID: UUID?
    var pasteCleanedText: Bool
    /// The instruction text to run — resolved from `promptID` at load time.
    var instructions: String
    /// Display name of the prompt that will run (the note's attribution line
    /// and the hero's "Cleaning up with …" line show it).
    var promptName: String

    /// Legacy fallback used only when no saved prompt can be resolved at all.
    static let defaultInstructions = """
        Rewrite the following transcription as a natural, casual message suitable for sending to a friend. \
        Remove filler words (um, uh, like, yeah yeah yeah), false starts, and mid-sentence corrections. \
        Preserve the intent and tone. Do not add information that wasn't in the original. \
        Output only the rewritten text with no preamble or quotes.
        """

    static func load() -> CleanupSettings {
        let defaults = AppGroup.defaults
        let enabled = defaults.object(forKey: AppGroup.Keys.cleanupEnabled) as? Bool ?? false
        let promptID = defaults.string(forKey: AppGroup.Keys.cleanupPromptID).flatMap(UUID.init(uuidString:))
        let pasteCleaned = defaults.object(forKey: AppGroup.Keys.cleanupPasteCleaned) as? Bool ?? true
        return CleanupSettings(
            enabled: enabled,
            promptID: promptID,
            pasteCleanedText: pasteCleaned,
            instructions: resolveInstructions(promptID: promptID),
            promptName: resolvedPrompt(promptID: promptID)?.name ?? "Cleanup"
        )
    }

    /// The prompt that will run: the chosen saved prompt if it still exists,
    /// else the built-in Cleanup prompt, else the legacy text.
    static func resolvedPrompt(promptID: UUID?) -> SavedPrompt? {
        let prompts = SavedPromptStore.all()
        if let promptID, let chosen = prompts.first(where: { $0.id == promptID }) {
            return chosen
        }
        return prompts.first(where: { $0.defaultKind == .articulate }) ?? SavedPrompt.defaultArticulate
    }

    private static func resolveInstructions(promptID: UUID?) -> String {
        resolvedPrompt(promptID: promptID)?.systemPrompt ?? defaultInstructions
    }

    func save() {
        let defaults = AppGroup.defaults
        defaults.set(enabled, forKey: AppGroup.Keys.cleanupEnabled)
        if let promptID {
            defaults.set(promptID.uuidString, forKey: AppGroup.Keys.cleanupPromptID)
        } else {
            defaults.removeObject(forKey: AppGroup.Keys.cleanupPromptID)
        }
        defaults.set(pasteCleanedText, forKey: AppGroup.Keys.cleanupPasteCleaned)
        defaults.set(Self.resolveInstructions(promptID: promptID), forKey: AppGroup.Keys.cleanupInstructions)
    }
}
