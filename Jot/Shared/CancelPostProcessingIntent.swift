import AppIntents
import Foundation

/// Live Activity / in-app cancel action for post-recording LLM work.
///
/// This only cancels the classifier / command-execution / cleanup task. The
/// shared pipeline handles the fallback semantics: publish the raw transcript
/// as fresh dictation and avoid superseding the prior row.
struct CancelPostProcessingIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Jot Post-Processing"

    static let description = IntentDescription(
        """
        Cancel Jot's in-flight post-recording processing and keep the raw \
        transcript as fresh dictation.
        """,
        categoryName: "Dictation"
    )

    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel Jot Post-Processing")
    }

    init() {}

#if JOT_APP_HOST

    @MainActor
    func perform() async throws -> some IntentResult {
        guard DictationPostProcessingCoordinator.shared.stage != .idle else {
            return .result()
        }

        DictationPostProcessingCoordinator.shared.cancel()
        return .result()
    }

#else

    func perform() async throws -> some IntentResult {
        return .result()
    }

#endif
}
