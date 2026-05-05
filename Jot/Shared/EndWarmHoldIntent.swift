import AppIntents
import Foundation

/// Cut C "Stop holding" affordance fired by the Live Activity / Dynamic Island
/// expanded button while the activity is in `.warmHold(expiresAt:)`.
///
/// Ends the warm-hold window immediately: `RecordingService.endWarmHold(reason:)`
/// stops the paused engine, deactivates the audio session, drops the orange
/// recording indicator, and clears the cached engine/converter so the next
/// `start()` takes the cold path.
///
/// ## Why a separate intent
///
/// `DismissFollowUpIntent` cancels a 30-second follow-up window; that's a
/// chained-follow-up classifier concern, not a recording-engine concern.
/// Warm-hold is the recording-engine concern. The two windows can coexist
/// (post-publish you may briefly be both in `.followUp` AND warm-held), so
/// they need independent dismiss intents — wiring "Stop holding" through
/// `DismissFollowUpIntent` would clear the wrong state and leave the engine
/// paused with its session still active.
///
/// ## Why this lives in `Jot/Shared/`
///
/// `Button(intent:)` compiles into the widget extension. Same XCodeGen
/// `JOT_APP_HOST` compilation-condition pattern as `StopDictationIntent` and
/// the others — see that file's struct doc for the full rationale. The
/// widget-side `#else` branch is a no-op stub; the real `perform()` runs in
/// the main-app process via `LiveActivityIntent` promotion.
struct EndWarmHoldIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Holding Jot Mic Warm"

    static let description = IntentDescription(
        """
        End Jot's warm-hold window early. The microphone indicator turns off \
        and the next dictation pays the normal cold-start latency.
        """,
        categoryName: "Dictation"
    )

    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Stop Holding Jot Mic Warm")
    }

    init() {}

#if JOT_APP_HOST

    @MainActor
    func perform() async throws -> some IntentResult {
        // Idempotent: `endWarmHold` no-ops if not currently warm. A user who
        // taps "Stop holding" twice (or whose tap arrives after the warm
        // timer already fired) just gets two no-ops.
        RecordingService.shared.endWarmHold(reason: "user pressed Stop holding")
        return .result()
    }

#else

    func perform() async throws -> some IntentResult {
        return .result()
    }

#endif
}
