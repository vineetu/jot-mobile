import AppIntents
import Foundation

/// Cut C "Record again" affordance fired by the Live Activity / Dynamic
/// Island expanded button while the activity is in `.warmHold(expiresAt:)`.
///
/// Begins a fresh dictation session. When `RecordingService` is currently
/// in warm-hold, `start()` takes the warm-resume fast path: the paused
/// `AVAudioEngine` is resumed via `engine.start()` on the already-prepared
/// graph (~10–50ms) instead of the full cold-init (~200–400ms). The user's
/// next utterance lands in the new recording's tap-installed CaptureContext.
///
/// ## Why this lives in `Jot/Shared/`
///
/// Same XCodeGen `JOT_APP_HOST` compilation-condition pattern as
/// `StopDictationIntent` — the widget extension's `Button(intent:)`
/// construction needs to see this type, but the actual `perform()` runs in
/// the main-app process via `LiveActivityIntent` promotion. The
/// `App/Intents/RecordAndTranscribeIntent` does the same job but lives in
/// the App-only target so it can directly reference
/// `DictationActivityCoordinator` and `DictationIntentBridge` types that
/// don't exist in the widget's compilation context. This shim sits in
/// `Shared/` so the widget can construct it; the main-app body forwards to
/// the same controller bridge `RecordAndTranscribeIntent` uses.
///
/// ## Idempotency
///
/// The user can tap "Record again" while the controller is already recording
/// (extremely tight race) or while transcription is in flight. `perform()`
/// inspects `currentPhase` and no-ops on anything other than `.idle`, so a
/// second tap during the warm-resume itself is harmless.
struct RecordAgainFromWarmIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record Again with Jot"

    static let description = IntentDescription(
        """
        Start a new Jot dictation, resuming from the warm engine if available \
        for an instant restart.
        """,
        categoryName: "Dictation"
    )

    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Record Again with Jot")
    }

    init() {}

#if JOT_APP_HOST

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = DictationIntentBridge.shared.controller

        // Bounded wait for the controller to reach `.idle`. Two distinct
        // states reach this intent:
        //   1. Prior recording finished + pipeline finished. `currentPhase
        //      == .idle`. Engine is warm-paused. Proceed immediately.
        //   2. Prior recording finished, but its pipeline is still mid-
        //      transcribing / processing / cleaning. `currentPhase` is
        //      one of those non-idle phases. Engine is ALREADY warm-paused
        //      (RecordingService.stop() pauses on its way out, before the
        //      pipeline runs). We can't drive `currentPhase = .recording`
        //      while the prior pipeline's `defer { currentPhase = .idle }`
        //      is still pending — it would clobber our `.recording`
        //      assignment. So wait for the prior pipeline to finish
        //      (typical 3-10s; bounded at 12s as a safety net).
        //   3. Prior recording is still actively recording (`.recording`).
        //      The user double-tapped or the activity layer raced. Treat
        //      as a hard no-op — we don't want to stop a live capture.
        switch controller.currentPhase {
        case .recording:
            // Already recording — hard no-op; we don't want to stop a live
            // capture from a "Record again" press.
            return .result()
        case .idle:
            break
        case .transcribing, .processing, .cleaning:
            // Wait for the prior pipeline to drain. `DictationRuntimePhase`
            // doesn't conform to `Equatable`, so use `if case` pattern
            // matching for the loop condition.
            let waitStart = Date()
            let waitDeadline: TimeInterval = 12
            waitLoop: while true {
                if case .idle = controller.currentPhase {
                    break waitLoop
                }
                if case .recording = controller.currentPhase {
                    // A fresh recording started while we were waiting —
                    // bail rather than fight for control.
                    return .result()
                }
                if Date().timeIntervalSince(waitStart) > waitDeadline {
                    // Pipeline ran past the bound. Surface as silent no-op
                    // so the user can tap again rather than being blocked
                    // by a thrown error in a Live Activity button context.
                    return .result()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let startedAt = Date()

        // Activity-coordinator side: spin up the Live Activity for the new
        // recording. `start(startedAt:)` is idempotent (per
        // `DictationActivityCoordinator.start(...)` implementation): if a
        // warm-hold activity is currently showing, this overwrites it with
        // the fresh `.recording(startedAt:)` content. We deliberately do NOT
        // call `startForAudioRecordingIntent` (which can throw if Live
        // Activities are disabled) — the warm-hold UI is already running so
        // the user has Live Activities permission; if it somehow fails, fall
        // through silently the same way `RecordAndTranscribeIntent` does on
        // its own start path.
        await DictationActivityCoordinator.shared.start(startedAt: startedAt)

        do {
            try await controller.startRecording(startedAt: startedAt)
        } catch {
            // Match `RecordAndTranscribeIntent.beginDictation` failure shape.
            await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
            throw error
        }

        return .result()
    }

#else

    func perform() async throws -> some IntentResult {
        return .result()
    }

#endif
}
