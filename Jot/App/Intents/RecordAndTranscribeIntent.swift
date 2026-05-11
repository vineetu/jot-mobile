import AppIntents
import Foundation

/// The iOS 18+ blessed Action Button entry point for Jot dictation.
///
/// ## What this is
///
/// A toggle intent — press-and-hold the Action Button to start recording;
/// press-and-hold again to stop, transcribe, and copy to clipboard. The app
/// stays backgrounded the entire time. The Dynamic Island / Live Activity is
/// the sole UI the user sees — no app bounce, no giant Shortcuts sheet.
///
/// ## Why this exists alongside `DictateIntent`
///
/// `DictateIntent` is the iOS 17 / pre-`AudioRecordingIntent`-era fallback:
/// it uses `openAppWhenRun = true` to foreground Jot because that was the
/// only way to reliably activate `AVAudioSession` from a Shortcuts-invoked
/// intent at the time. The tradeoff is a visible app bounce on every Action
/// Button press.
///
/// `RecordAndTranscribeIntent` is the iOS 18+ path. Conforming to
/// `AudioRecordingIntent` promotes execution into the main-app process and
/// authorises `AVAudioEngine` without foregrounding — see
/// `docs/research/action-button-interaction-palette.md` §3.A for the full
/// chain of evidence (WWDC25 session 251, Apple AppIntents docs, and Zach
/// Waugh's writeup on forcing AppIntents into the main-app process).
///
/// We deliberately keep `DictateIntent` registered as a *fallback* entry in
/// `JotAppShortcuts` in case this protocol conformance doesn't bind on a
/// particular iOS release. If Action Button binding of this intent fails on
/// device, users still have a working path via `DictateIntent`; we flip the
/// primary registration later with no app-update forced on the user.
///
/// ## Historical note — why AudioRecordingIntent was removed from DictateIntent
///
/// An earlier iteration of `DictateIntent` conformed to `AudioRecordingIntent`
/// and was reproducibly *listed* in Settings → Action Button → Shortcut → Jot
/// yet *un-selectable* when the user tapped to bind. That was on an early
/// iOS 26 release. The research doc §5 question 6 pins the likely cause to
/// Apple DevForums #760342 — a general `openAppWhenRun = false` regression
/// in iOS 18 betas that dropped `perform()` calls silently, with follow-on
/// weirdness in the Action Button binding UI. The bug has been reported
/// quiet on newer iOS 18.x / iOS 26.0 builds.
///
/// Retrying the protocol conformance on current iOS 26.2 is what this intent
/// is for. If on-device build verification reproduces the un-bindable
/// behaviour from the earlier iteration, we document the finding and keep
/// `DictateIntent` primary. Meanwhile, shipping alongside `DictateIntent`
/// (not replacing it) means the worst-case regression from this landing is
/// **zero** — the fallback is already on disk and users can pick it from the
/// Action Button picker.
///
/// ## Shape decisions
///
/// - **`static let openAppWhenRun: Bool = false`** — the whole point. No
///   app bounce on press. `AudioRecordingIntent` conformance is what makes
///   this correct: iOS 18+ grants main-app-process execution and audio-session
///   activation for the marker protocol, so no foregrounding is needed.
///
/// - **Conforms to `AppIntent` only.** Live Activity scaffolding has been
///   removed — see the Dynamic Island ghost-pill fix. We previously
///   conformed to `LiveActivityIntent` to allow a Live Activity to host
///   `Button(intent:)` entries targeting this family, but no shipping
///   surface consumes that and the conformance was holding open the
///   widgetkit scaffolding that produced stale ghost pills on devices
///   that had ever installed a pre-v0.5 build.
///
///   The note about `AudioRecordingIntent` from earlier iterations is
///   preserved historically: that conformance was tried for headless
///   audio-session activation, then dropped because the Action Button
///   binding UI filtered it out. Plain `AppIntent` is what binds today.
///
/// - **Method-level `@MainActor` on `perform()`, NOT struct-level.**
///   `TranscribeAudioFileIntent`'s doc captures the research finding that
///   struct-level `@MainActor` has historically produced un-bindable
///   intents on the Action Button picker. Method-level scope (as used by
///   `DictateIntent` today) is fine and is what we need because the
///   controller bridge is main-actor-isolated.
///
/// - **`parameterSummary` present even though there are no parameters.**
///   Same rationale as `DictateIntent` — iOS 26.2's Shortcuts daemon renders
///   the parameter summary during the binding commit step. Missing summary
///   surfaces a generic "Something went wrong" error when the user taps to
///   bind.
///
/// - **Toggle semantics via shared `DictationIntentBridge`.** Mirrors
///   `DictateIntent` exactly: first press starts, subsequent presses stop.
///   Both intents route through the same `DictationController`, so if a
///   recording is in-flight from either intent, pressing either one stops
///   it. A user who has both intents bound gets sensible cross-intent
///   toggle behaviour rather than two independent recorders.
///
/// ## Why `perform()` duplicates `DictateIntent`'s body
///
/// Line-for-line, `perform()` / `beginDictation` / `endDictation` are
/// functionally identical to `DictateIntent`. Factoring to a shared helper
/// is tempting — but the two intents may diverge once we see device
/// behaviour (this one may want a shorter cleanup timeout because the
/// no-foreground path has a tighter runtime budget under
/// `AudioRecordingIntent`; or a Live-Activity stop button may short-circuit
/// `endDictation` here only). Premature factoring against a divergence I
/// can't yet predict would lock in a shape that blocks those local changes.
/// If the two paths stay lock-step after binding + runtime verification,
/// consolidation is a clean follow-up.
struct RecordAndTranscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Jot Dictation"

    static let description = IntentDescription(
        """
        Record with the microphone, transcribe on-device with Parakeet, \
        and copy the transcript to the clipboard. Press again to stop.
        """,
        categoryName: "Dictation"
    )

    /// Load-bearing. See struct doc.
    static let openAppWhenRun: Bool = false

    /// Belt-and-suspenders: explicitly advertise to every system surface
    /// (Shortcuts library, Siri phrases, Action Button picker). Default is
    /// `true` upstream; we pin in case a future SDK default flip silently
    /// hides the intent.
    static let isDiscoverable: Bool = true

    /// Even a parameterless intent declares `parameterSummary` on iOS 26 —
    /// see `DictateIntent`'s doc for the rationale (iOS 26.2 Shortcuts
    /// binding daemon renders the summary during the commit step; its
    /// absence surfaces a generic "Something went wrong" error to the user).
    static var parameterSummary: some ParameterSummary {
        Summary("Start Jot Dictation")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Controller is always non-nil now — the bridge lazy-owns it. The
        // `openAppWhenRun = false` headless launch doesn't gate on any
        // App-layer register call anymore; see `DictationIntentBridge` doc
        // for the full v8 → v9 shape migration (removed the register/await
        // dance, added the lazy-singleton pattern). This is the change that
        // actually fixes the "DictationIntentBridge timeout error 1" the user
        // hit on every Action Button press of the v2 build.
        let controller = DictationIntentBridge.shared.controller

        switch controller.currentPhase {
        case .idle:
            try await beginDictation(using: controller)
        case .recording:
            try await endDictation(using: controller)
        case .transcribing, .processing, .cleaning:
            return .result()
        }

        return .result()
    }

    // MARK: - Toggle legs

    @MainActor
    private func beginDictation(using controller: any DictationController) async throws {
        let startedAt = Date()
        await DictationActivityCoordinator.shared.start(startedAt: startedAt)

        do {
            try await controller.startRecording(startedAt: startedAt)
        } catch {
            await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
            throw error
        }
    }

    @MainActor
    private func endDictation(using controller: any DictationController) async throws {
        // Capture `recordingStartedAt` BEFORE anything clears it — we need it
        // to compute the wall-clock duration `DictationPipeline` hands to
        // `TranscriptStore.append`. `perform()` is a fresh struct instance on
        // each press so there's no local state we could have stashed on start;
        // the coordinator singleton is the only place the timestamp lives.
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt ?? Date()

        await DictationActivityCoordinator.shared.update(phase: .transcribing)

        let result = try await controller.stopAndTranscribe()

        // Delegate to the shared pipeline: chained-follow-up classification,
        // fresh vs command branching, publish, append, and transition into
        // the shared follow-up window. See `DictationPipeline` for why the
        // three dictation entry-point intents share one tail.
        try await DictationPipeline.completeEndOfRecording(
            transcript: result.transcript,
            startedAt: startedAt,
            stoppedAt: result.stoppedAt,
            controller: controller
        )
    }
}
