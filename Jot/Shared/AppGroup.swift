import Foundation

/// Shared identifier and helpers for cross-target communication between the
/// Jot app, its keyboard extension, and its Live Activity widget.
///
/// Every target in `project.yml` must list this group under
/// `com.apple.security.application-groups`.
enum AppGroup {
    static let identifier = "group.com.jot.mobile.shared"

    /// `UserDefaults` is documented as thread-safe but does not conform to
    /// `Sendable`, so Swift 6 strict concurrency flags it in a `static let`.
    /// `nonisolated(unsafe)` is the right escape hatch here: the keyboard
    /// extension reads this off-MainActor (`viewWillAppear`, `textDidChange`)
    /// and the app reads it from MainActor — a `@MainActor` isolation would
    /// force the keyboard to hop just to resolve a clipboard handoff.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: identifier) else {
            fatalError("App Group \(identifier) is not configured. Check entitlements.")
        }
        return defaults
    }()

    enum Keys {
        // Single JSON-encoded FreshDictation payload. Consolidated from the old
        // two-key pair so the keyboard extension can't observe a torn write
        // (new timestamp + stale preview, or vice versa).
        static let lastDictation = "jot.lastDictation"

        // User-configurable cleanup behavior, shared between main app and keyboard.
        static let cleanupEnabled = "jot.cleanup.enabled"
        static let cleanupInstructions = "jot.cleanup.instructions"
        static let keyboardAutoPasteEnabled = "jot.keyboard.autoPaste"
    }
}
