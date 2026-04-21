import Foundation

/// User-facing cleanup configuration, persisted in the App Group so the
/// keyboard extension (which may later do its own fallback cleanup) can read
/// the same settings as the main app.
struct CleanupSettings {
    var enabled: Bool
    var instructions: String

    static let defaultInstructions = """
        Rewrite the following transcription as a natural, casual message suitable for sending to a friend. \
        Remove filler words (um, uh, like, yeah yeah yeah), false starts, and mid-sentence corrections. \
        Preserve the intent and tone. Do not add information that wasn't in the original. \
        Output only the rewritten text with no preamble or quotes.
        """

    static func load() -> CleanupSettings {
        let defaults = AppGroup.defaults
        let enabled = defaults.object(forKey: AppGroup.Keys.cleanupEnabled) as? Bool ?? false
        let instructions = defaults.string(forKey: AppGroup.Keys.cleanupInstructions) ?? defaultInstructions
        return CleanupSettings(enabled: enabled, instructions: instructions)
    }

    func save() {
        let defaults = AppGroup.defaults
        defaults.set(enabled, forKey: AppGroup.Keys.cleanupEnabled)
        defaults.set(instructions, forKey: AppGroup.Keys.cleanupInstructions)
    }
}
