import FoundationModels
import Foundation

/// Which engine performs rewrites in the Transcript Detail view (features.md §6.3 / §7.10):
///
/// - `.appleIntelligence` — the device's built-in **Writing Tools** (system Apple Intelligence).
///   No download, no Jot prompts; tapping Rewrite shows the `AppleIntelligenceRewriteGuide`.
/// - `.jotAI` — Jot's own on-device model (Qwen 3.5 4B). Uses the user's saved prompts; tapping
///   Rewrite opens the `RewritePickerSheet` (downloading first if needed).
///
/// Persisted in App Group defaults so the choice survives launches. The default — when the user
/// hasn't chosen yet — is **Apple Intelligence if the device has it**, else Jot's AI (so older
/// devices without Apple Intelligence fall back to the downloadable model).
///
/// This is a separate axis from `LLMProvider` (which only selects the Jot-AI *backend*); Apple
/// Intelligence is not an `LLMClient` — it's the system Writing Tools path.
enum RewriteMode: String, CaseIterable, Sendable {
    case appleIntelligence
    case jotAI

    /// Is the on-device Apple Intelligence model available on this device right now?
    @MainActor
    static var appleIntelligenceAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The active mode: the user's saved choice, or — if none — Apple Intelligence when available.
    @MainActor
    static var current: RewriteMode {
        if let raw = AppGroup.defaults.string(forKey: AppGroup.Keys.rewriteMode),
           let mode = RewriteMode(rawValue: raw) {
            // A saved "appleIntelligence" choice on a device that lost availability falls back.
            if mode == .appleIntelligence, !appleIntelligenceAvailable { return .jotAI }
            return mode
        }
        return appleIntelligenceAvailable ? .appleIntelligence : .jotAI
    }

    /// Persist a user-initiated engine choice.
    static func set(_ mode: RewriteMode) {
        AppGroup.defaults.set(mode.rawValue, forKey: AppGroup.Keys.rewriteMode)
    }
}
