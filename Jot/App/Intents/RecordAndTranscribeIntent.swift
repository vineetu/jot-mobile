import AppIntents
import Foundation

/// The registered Action Button / Spotlight / Siri entry point for Jot
/// dictation. Toggle: press to start recording; press again to stop,
/// transcribe, and copy to clipboard.
///
/// ## Foreground-bounce, scene-active-gated start (GitHub issue #3 fix)
///
/// This intent **brings Jot to the foreground** to record. There is no headless
/// path: iOS forbids starting microphone capture from a process it doesn't treat
/// as foreground. Launched cold from Spotlight/Action Button/Siri with no
/// foreground, `AVAudioEngine.start()` is refused by CoreAudio → the historical
/// "Audio engine failed to start" banner (issue #3). Apple DTS prescribes
/// foregrounding (forums/thread/756507).
///
/// Two pieces make this reliable:
/// 1. **`supportedModes = .foreground(.immediate)`** — the iOS 26 replacement
///    for the deprecated `openAppWhenRun = true`. Brings the app forward.
/// 2. **The mic-start is DEFERRED to scene-`.active`, not started inline in
///    `perform()`.** iOS runs the intent in the background and creates the
///    foreground *during* `perform()` (Apple DTS, forums/thread/769924), so an
///    inline `start()` races the transition and can still fail intermittently.
///    Instead the START leg sets `DictationIntentBridge.pendingForegroundStart`
///    + posts `jotDictateFromShortcut`; `JotApp` begins recording via
///    `triggerAutoStart` once the scene is confirmed `.active` — the same
///    proven, scene-gated path the keyboard's `jot://dictate` bounce uses.
///
/// ## NOT `AudioRecordingIntent` (and why re-adding it would NOT fix #3)
///
/// This conforms to plain `AppIntent`. `AudioRecordingIntent` does **not** grant
/// cold-background mic start: it requires a live Live Activity for the whole
/// recording (that subsystem was removed from Jot), and even fully built only
/// buys *pause/resume of a foreground-started session* — never a cold start from
/// Spotlight (Apple DTS forums/thread/815725; see
/// `docs/carplay/issue-3-mic-rootcause.md`). The foreground bounce is the
/// supported fix.
///
/// `DictateIntent` is the dormant fallback (identical shape, `isDiscoverable =
/// false`); if this ever fails to bind, flip the registration. Both route
/// through the same `DictationIntentBridge` controller, so toggle behaves
/// sensibly even if both are bound.
///
/// `parameterSummary` is present (even with no parameters) and `@MainActor` is
/// method-level, not struct-level — both required for reliable Action Button
/// binding on iOS 26 (see `DictateIntent` doc for the binding saga).
struct RecordAndTranscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Jot down a note"

    static let description = IntentDescription(
        """
        Record with the microphone, transcribe on-device with Parakeet, \
        and copy the transcript to the clipboard. Press again to stop.
        """,
        categoryName: "Dictation"
    )

    /// Foreground to record (iOS 26 replacement for deprecated
    /// `openAppWhenRun = true`). The actual mic-start is deferred to
    /// scene-`.active` — see struct doc + `perform()`.
    static var supportedModes: IntentModes { .foreground(.immediate) }

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
        Summary("Jot down a note")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = DictationIntentBridge.shared.controller

        switch controller.currentPhase {
        case .idle:
            // Do NOT start the mic inline (issue #3): iOS creates the foreground
            // DURING perform(), so an inline start races the transition and can
            // fail with CoreAudio "engine failed to start." Request a
            // foreground-gated start instead — `JotApp` begins recording via
            // `triggerAutoStart` once the scene is confirmed `.active`, the same
            // proven path the keyboard's `jot://dictate` bounce uses.
            DictationIntentBridge.shared.pendingForegroundStart = true
            NotificationCenter.default.post(name: .jotDictateFromShortcut, object: nil)
        case .recording:
            // Stop needs no foreground — the engine is already up. Safe inline.
            try await endDictation(using: controller)
        case .transcribing, .processing, .cleaning:
            return .result()
        }

        return .result()
    }

    // MARK: - Toggle legs

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
            controller: controller,
            retainSamples: result.samples
        )
    }
}
