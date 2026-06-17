//
//  SetupWizardView.swift
//  Jot
//
//  Phase 6 of the UX overhaul — 7-panel setup wizard reskin (W1–W7).
//  The in-app try-it (formerly W5) was dropped so the keyboard try-it
//  is the only try-it step — users dictate from the real keyboard
//  instead of practicing in the wizard first.
//
//  Step state machine: a 7-case enum covers the seven core visual
//  surfaces (W1–W7). The old W3 "Download speech model" panel was
//  retired earlier (Parakeet ships bundled in the IPA, App Review
//  4.2.3(ii)). The optional AI-offer follow-on step was also dropped —
//  AI rewrite is now set up from Settings, not onboarding — so W7
//  ("You're ready") is terminal. Each case maps to a small per-step
//  view file under `Steps/`. Shared chrome (wallpaper, progress dots,
//  close X, primary CTA pill, home indicator) lives in
//  `Components/WizardChrome.swift`.
//
//  Backend wiring is preserved end-to-end:
//    - W2 mic permission → `AVAudioApplication.requestRecordPermission`
//    - W3 keyboard setup → Settings deep-link + scene-active detection
//                          via `UITextInputMode.activeInputModes`. Full
//                          Access is a manual user attestation (iOS does
//                          not expose its state to the main app).
//    - W5 keyboard test  → polls `ClipboardHandoff.readFresh()` for a
//                          fresh handoff newer than W5 entry.
//    - W6 warm hold      → writes `AppGroup.warmHoldEnabled`.
//
//  Setup completion is gated by `SetupCompletion.markCompleted()`, which
//  is unchanged from before — its persistence key remains the source of
//  truth for "should the wizard re-present on next launch?".
//

import SwiftUI
import os.log

private let wizardLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "setup-wizard"
)

struct SetupWizardView: View {
    let onComplete: () -> Void

    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(RecordingService.self) private var recordingService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: SetupStep = .welcome
    /// Backwards-navigation history. Each forward `advance(to:)` pushes the
    /// CURRENT step onto this stack before mutating `step`; `goBack()`
    /// pops the top of the stack. Going back never undoes permission
    /// grants or AppGroup writes — the underlying services preserve their
    /// state and the previous step's view just re-renders from observed
    /// state.
    @State private var history: [SetupStep] = []
    /// Darwin observer for `keyboardDictateTapped` — posted by the
    /// keyboard extension when the user taps the Dictate pill AND the
    /// host app is Jot itself (W5 case, formerly W6 before the in-app
    /// try step was dropped). On W5 this STARTS A RECORDING in the main
    /// app (the keyboard extension cannot capture audio itself); off-W5
    /// it's ignored (the user is mid-flow on another step). Auto-advance
    /// to W6 happens via `TryKeyboardStep`'s existing polling on
    /// `ClipboardHandoff.readFresh()` — the user taps Stop in the
    /// keyboard's pill, transcription completes, the paste lands in the
    /// wizard's TextField, and the polling sees the fresh handoff and
    /// calls onAdvance to W6.
    /// Receiving the notification at all implies the keyboard has Full
    /// Access (without it the keyboard can't read the App Group
    /// foreground-heartbeat slot used for host detection), so the no-FA
    /// branch is handled keyboard-side by the existing `openHostSettings()`
    /// fallback.
    @State private var dictateTapObserver: CrossProcessNotification.Observer?
    @State private var micAutoAdvanceConsumed = false

    var body: some View {
        Group {
            switch step {
            case .welcome:
                // Welcome has no previous step — pass nil so the back
                // chevron + edge-swipe don't render here.
                WelcomeStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .microphone) }
                )

            case .microphone:
                MicStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    allowsAutoAdvance: !micAutoAdvanceConsumed,
                    onAdvance: { advance(to: .keyboardInstall) }
                )

            case .keyboardInstall:
                KeyboardInstallStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    onAdvance: { advance(to: .howItWorks) }
                )

            case .howItWorks:
                HowItWorksStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    onAdvance: { advance(to: .tryKeyboard) }
                )

            case .tryKeyboard:
                TryKeyboardStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    onAdvance: { advance(to: .warmHold) }
                )

            case .warmHold:
                WarmHoldStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    onAdvance: { advance(to: .youreReady) }
                )

            case .youreReady:
                YoureReadyStep(
                    onClose: closeAndComplete,
                    onBack: goBack,
                    onFinish: closeAndComplete
                )
            }
        }
        .onAppear {
            // Pre-warm the speech model the moment the wizard opens. The
            // launch-time warm in `JotApp` is gated on
            // `SetupCompletion.isCompleted`, which is FALSE throughout the
            // wizard — so without this the model would still be cold when the
            // user reaches W5 and taps Jot-down. Warming here means the model
            // is usually ready (or nearly so) by W5, so the one-time
            // "First-time setup" pane is short or skipped.
            //
            // SAME unified `warmIfNeeded()` the app-launch + scene triggers use
            // — no wizard-specific gate logic. This call site is KEPT (not folded
            // away) on purpose: SwiftUI `.task`/`onAppear` in `JotApp` do NOT
            // re-fire on a warm-process wizard RE-RUN from Settings, so this is
            // the only trigger that covers re-entering setup after the model was
            // evicted. Idempotent — coalesces with any launch/scene warm.
            transcriptionService.warmIfNeeded()

            // Install the keyboard-dictate-tapped observer on first
            // wizard appearance. The keyboard posts this Darwin
            // notification ONLY when the host app is Jot (heartbeat
            // freshness check) AND the user taps the Dictate pill —
            // which on the wizard W5 surface is exactly the gesture
            // we're verifying.
            //
            // Idempotent: re-installing replaces the previous observer
            // (the Observer's deinit removes itself from the Darwin
            // center), so flapping `onAppear` doesn't double-fire.
            dictateTapObserver = CrossProcessNotification.addObserver(
                name: CrossProcessNotification.keyboardDictateTapped
            ) {
                handleKeyboardDictateTapped()
            }
        }
        .onDisappear {
            // Tear down on wizard dismissal — once setup is complete,
            // the production keyboard surface drives the normal
            // `jot://dictate` URL bounce and the wizard observer
            // would be a no-op anyway. Letting the Observer linger
            // would also keep a stale Darwin registration alive for
            // the rest of the app's lifetime.
            dictateTapObserver = nil
            // Belt-and-braces: never leave the wizard-active koan gate set if
            // the wizard tears down from a non-W5 step (W5's own `.onDisappear`
            // clears it on a normal forward/back transition; this covers an
            // abrupt dismissal). See `AppGroup.wizardActive`.
            AppGroup.wizardActive = false
        }
    }

    /// Handles the keyboard's `keyboardDictateTapped` notification.
    /// Tap on keyboard's Dictate triggers the main-app recording —
    /// the keyboard extension can't capture audio itself, so W5's
    /// end-to-end test (record → transcribe → paste lands in the
    /// wizard's TextField) requires the main app to drive the
    /// recording while the keyboard surfaces the Stop pill via its
    /// cross-process recording-state observer.
    ///
    /// Auto-advance to W6 happens via `TryKeyboardStep`'s existing
    /// polling on `ClipboardHandoff.readFresh()`, NOT here — once the
    /// user taps Stop in the keyboard, the transcription publishes a
    /// fresh handoff that the polling picks up.
    ///
    /// Off-W5 (welcome, keyboard setup, etc.) we deliberately ignore the
    /// signal: the wizard is mid-flow on a different step and a
    /// silent recording-start would confuse the user.
    private func handleKeyboardDictateTapped() {
        guard step == .tryKeyboard else { return }
        // `start()` is async-throwing; wrap in a Task. If a recording
        // is already in flight (e.g. rapid double-tap of the keyboard
        // pill), `RecordingService.start()`'s internal guard throws —
        // log and ignore so we don't crash on the contention case.
        Task { @MainActor in
            do {
                wizardLog.notice("RECORDING START FROM: SetupWizardView.handleKeyboardDictateTapped (W5 keyboard mic)")
                // A normal capture must never inherit a stale inline-ownership
                // flag. `ownsActiveRecording` is set ONLY by Ask's
                // `InlineDictationSession`; a leaked `true` would make the
                // keyboard Stop bail out of `handleStopRequested` before
                // stopping the mic. Mirror `ContentView`'s in-Jot observer and
                // clear it defensively before starting. The wizard W5 field then
                // receives the in-process transient insert on stop.
                RecordingService.shared.ownsActiveRecording = false
                try await recordingService.start()
            } catch {
                // Expected on already-recording / pipeline-in-flight
                // contention; non-fatal — the existing in-flight
                // recording covers the user's intent.
            }
        }
    }

    private func advance(to next: SetupStep) {
        let previous = step
        if previous == .microphone {
            micAutoAdvanceConsumed = true
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            history.append(previous)
            step = next
        }
    }

    /// Pop one entry off the history stack. Wired into every step's back
    /// chevron + the left-edge drag gesture in `WizardPanel`. Guards
    /// against an empty history (Welcome) — if the stack is empty,
    /// `goBack` is a no-op so a misfire never crashes the wizard.
    private func goBack() {
        guard let previous = history.popLast() else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            step = previous
        }
    }

    /// Marks the setup wizard complete and dismisses. The "X" close
    /// button and the W7 "Start jotting." button share this exit path.
    private func closeAndComplete() {
        // Clear the koan gate unconditionally — the wizard is leaving, so the
        // one-time "First-time setup" line must never persist into the
        // keyboard / hero. (W5's own teardown also clears it; this covers
        // a close from any step.)
        AppGroup.wizardActive = false

        // Wizard contract: any recording the wizard started (W5 keyboard
        // handoff) is released before the wizard dismisses, so the user lands
        // on the home view clean — no listening indicator, no zombie hero.
        //
        // GENTLE release: leaving at the end is a legitimate stop, but per the
        // project rule we never `forceStop()`/`discard()` the mic — we use the
        // gentle `cancel()`, which discards the in-progress (Jot-internal,
        // never-saved) W5 audio AND honours Warm Hold. The dismissal proceeds
        // synchronously; the mic releases on the next MainActor turn.
        if recordingService.isRecording {
            wizardLog.notice("Wizard dismissing while recording — gently cancelling (wizard contract, honours warm-hold)")
            let service = recordingService
            Task { @MainActor in
                await service.cancel()
            }
        }
        // Stop already tapped but the W5 transcription pipeline is still running:
        // `cancel()` no-ops (no active capture slice to discard), so clear the
        // pipeline state decisively — without this the in-flight flag / missing
        // `.idle` would ride onto the home view until the pipeline self-finishes.
        // Restores the pre-gentle-stop contract for the pipeline-only path.
        if recordingService.isPipelineInFlight {
            recordingService.markPipelineFinished()
            recordingService.publishPipelinePhase(.idle)
        }
        SetupCompletion.markCompleted()
        onComplete()
    }
}

/// 7-case step machine — one case per core visual surface (W1–W7). Cases are
/// ordered to mirror the visual sequence exactly, which keeps the progress-dot
/// row in lockstep with the step transitions. The old W3 "Download speech
/// model" case is gone (Parakeet ships bundled in the IPA); the old W5 in-app
/// try-it case is also gone — users dictate from the real keyboard instead.
/// The optional AI-offer follow-on case is gone too — AI rewrite is now set up
/// from Settings, not onboarding — so W7 is terminal.
private enum SetupStep: Hashable {
    case welcome           // W1
    case microphone        // W2
    case keyboardInstall   // W3
    case howItWorks        // W4
    case tryKeyboard       // W5
    case warmHold          // W6
    case youreReady        // W7
}

#Preview {
    SetupWizardView {}
        .environment(TranscriptionService())
        .environment(RecordingService.shared)
}
