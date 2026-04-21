import AppIntents
import Foundation

/// The stop-gesture intent fired by the Live Activity stop `Button(intent:)`.
///
/// ## What this is
///
/// A `LiveActivityIntent` invoked by the stop button rendered inside
/// `JotLiveActivity`'s `.recording` phase. Conforming to `LiveActivityIntent`
/// is what lets ActivityKit render a `Button(intent:)` whose tap is routed
/// back into Jot: iOS 18+ promotes execution to the owning main-app process
/// and activates audio-session/mic-session on its behalf without foregrounding.
/// The recording therefore terminates via the exact same `DictationController`
/// pipeline that a second Action Button press would have driven.
///
/// ## Why this lives in `Jot/Shared/`
///
/// `Button(intent:)` compiles into the widget extension (the `.recording`
/// case of `ExpandedBottom` in `JotLiveActivity`), which means the widget
/// target must see the `StopDictationIntent` type. But iOS promotes
/// `LiveActivityIntent`-conforming intents into the main-app process at
/// runtime, so the *body* of `perform()` needs to reference the main-app's
/// `DictationController` / `DictationIntentBridge` /
/// `DictationActivityCoordinator` / `ClipboardHandoff` / `TranscriptStore` —
/// none of which are visible inside the widget extension's compilation context.
///
/// The solve is XCodeGen's `SWIFT_ACTIVE_COMPILATION_CONDITIONS: JOT_APP_HOST`
/// flag on the Jot main-app target only. The widget extension compiles this
/// file without the flag, so the `#else` branch supplies a trivial stub that
/// conforms to `AppIntent` but does nothing. That branch is unreachable at
/// runtime because `LiveActivityIntent` promotion lands the actual `perform()`
/// call in the main-app process, which compiles the `#if JOT_APP_HOST` branch
/// with real work.
///
/// ## Idempotency
///
/// The user can legitimately tap the stop button twice (e.g. a jumpy finger,
/// or the button rendering briefly after the pipeline has auto-transitioned
/// into transcription). `perform()` inspects `currentPhase` and no-ops when
/// the controller has already left the recording phase, so a second tap
/// never double-dispatches `stopAndTranscribe()`.
///
/// ## Belt-and-suspenders alongside the Action Button path
///
/// This intent does not replace the "press the Action Button again to stop"
/// toggle leg inside `RecordAndTranscribeIntent`/`DictateIntent` — both
/// surfaces can terminate a recording. They go through the same helper
/// (`stopAndTranscribe()` → cleanup → `ClipboardHandoff.publish` →
/// `TranscriptStore.append` → `finish`), so the observable outcome is
/// identical regardless of which surface the user tapped.
struct StopDictationIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Jot Dictation"

    static let description = IntentDescription(
        """
        Stop the in-flight Jot dictation, transcribe the recording, \
        and copy the transcript to the clipboard.
        """,
        categoryName: "Dictation"
    )

    /// No foreground bounce. `LiveActivityIntent` protocol promotion gives
    /// us main-app-process execution without needing `openAppWhenRun = true`.
    static let openAppWhenRun: Bool = false

    /// Belt-and-suspenders: advertise to every system surface. Interactive
    /// Live Activity buttons work regardless of discoverability, but pinning
    /// `true` keeps Shortcuts/Siri surfaces consistent with the other Jot
    /// intents in case a user happens on this one directly.
    static let isDiscoverable: Bool = true

    /// Even parameterless intents declare a summary on iOS 26 — see the
    /// equivalent note on `DictateIntent`. Its absence surfaces a generic
    /// "Something went wrong" error during the Shortcuts daemon's binding
    /// commit step.
    static var parameterSummary: some ParameterSummary {
        Summary("Stop Jot Dictation")
    }

    init() {}

#if JOT_APP_HOST

    @MainActor
    func perform() async throws -> some IntentResult {
        // Controller is always non-nil now — bridge lazy-owns it. See
        // `DictationIntentBridge` (in `DictateIntent.swift`) for the v9 shape
        // migration: dropped the register/await dance that was producing
        // `DictationIntentBridge timeout error 1` on every Action Button
        // press of the v2 build.
        //
        // The "nothing to stop" case — stop button tapped when no recording
        // is in flight — is still handled correctly below by the
        // `.idle` branch of the `currentPhase` switch. That's both the
        // idempotency guard AND the "no work to do" short-circuit, so
        // collapsing the two guards into one case-split actually reads
        // cleaner than the previous optional-unwrap + switch pair.
        let controller = DictationIntentBridge.shared.controller

        // Idempotency guard. If another surface (Action Button re-press, or
        // a rapid double-tap on the Live Activity button) already moved us
        // out of `.recording`, a second stop tap must no-op. Running
        // `stopAndTranscribe()` again would either re-emit the transcript
        // (double-append to the ledger, duplicated clipboard write) or
        // throw because the mic is no longer open. The `.idle` case also
        // covers "stop button tapped when no recording ever started."
        switch controller.currentPhase {
        case .recording:
            break
        case .idle, .transcribing, .processing, .cleaning:
            return .result()
        }

        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt ?? Date()

        await DictationActivityCoordinator.shared.update(phase: .transcribing)

        let transcript = try await controller.stopAndTranscribe()

        // Delegate to the shared pipeline — same tail as
        // `RecordAndTranscribeIntent.endDictation` and
        // `DictateIntent.endDictation`. The Live Activity stop button must
        // produce exactly the outcome the Action Button re-press would have
        // produced (clipboard contents, ledger rows, chained-follow-up
        // classification) — that's what keeps the "two ways to stop, same
        // outcome" user-facing invariant honest.
        try await DictationPipeline.completeEndOfRecording(
            transcript: transcript,
            startedAt: startedAt,
            controller: controller
        )

        return .result()
    }

#else

    /// Widget-extension compilation stub. `LiveActivityIntent` promotion
    /// routes actual execution into the main-app process (see struct doc),
    /// so this branch is never hit at runtime. It exists purely to satisfy
    /// the `AppIntent.perform()` protocol requirement for the widget's
    /// `Button(intent:)` construction.
    func perform() async throws -> some IntentResult {
        return .result()
    }

#endif
}
