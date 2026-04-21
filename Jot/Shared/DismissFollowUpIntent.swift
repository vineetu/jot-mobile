import AppIntents
import Foundation

/// Live Activity / in-app dismiss action for the post-dictation follow-up window.
///
/// This closes the 30-second follow-up affordance without touching any stored
/// transcript state or the already-finished clipboard handoff.
struct DismissFollowUpIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Dismiss Jot Follow-Up Window"

    static let description = IntentDescription(
        """
        Close Jot's active follow-up window without changing the transcript \
        that was already captured.
        """,
        categoryName: "Dictation"
    )

    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Dismiss Jot Follow-Up Window")
    }

    init() {}

#if JOT_APP_HOST

    @MainActor
    func perform() async throws -> some IntentResult {
        await DictationActivityCoordinator.shared.dismissFollowUpWindow()
        return .result()
    }

#else

    func perform() async throws -> some IntentResult {
        return .result()
    }

#endif
}
