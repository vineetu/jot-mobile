//
//  SetupWizardView.swift
//  Jot
//
//  Phase 6 of the UX overhaul — 12-panel setup wizard reskin.
//
//  Step state machine: a 12-case enum covers the W1–W12 visual surfaces.
//  Each case maps to a small per-step view file under `Steps/`. Shared
//  chrome (wallpaper, progress dots, close X, primary CTA pill, home
//  indicator) lives in `Components/WizardChrome.swift`.
//
//  Backend wiring is preserved end-to-end:
//    - W2 mic permission → `AVAudioApplication.requestRecordPermission`
//    - W3 speech model   → `TranscriptionService.warmUp()` +
//                          `StreamingTranscriptionService.warmUp()` +
//                          `CtcModelCache.shared.ensureLoaded()` under
//                          the existing `ModelDownloadGate` consent.
//    - W4 keyboard install → Settings deep-link + scene-active detection
//                            via `UITextInputMode.activeInputModes`.
//    - W5 Full Access   → Settings deep-link + manual "I've enabled it".
//                          Main-app process cannot read the keyboard's
//                          `hasFullAccess` directly.
//    - W7 in-app test   → real `RecordingService.shared.start/stop` +
//                          `TranscriptionService.shared.transcribe`.
//    - W8 keyboard test → polls `ClipboardHandoff.readFresh()` for a
//                          fresh handoff newer than W8 entry.
//    - W9 warm hold     → writes `AppGroup.warmHoldEnabled`.
//    - W11 vocab seed   → `VocabularyStore.shared.addBlankTerm()` +
//                          `.update(id:text:aliases:)`.
//    - W12 AI offer     → `LLMClientUIAdapter.warm()` against
//                          `LLMClientFactory.shared.client()`.
//
//  Setup completion is gated by `SetupCompletion.markCompleted()`, which
//  is unchanged from before — its persistence key remains the source of
//  truth for "should the wizard re-present on next launch?".
//

import SwiftUI

struct SetupWizardView: View {
    let onComplete: () -> Void

    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingTranscriptionService.self) private var streamingService
    @Environment(RecordingService.self) private var recordingService

    @State private var step: SetupStep = .welcome
    @State private var downloadGate = ModelDownloadGate()
    /// Darwin observer for `keyboardDictateTapped` — posted by the
    /// keyboard extension when the user taps the Dictate pill AND the
    /// host app is Jot itself (W8 case). On W8 this STARTS A RECORDING
    /// in the main app (the keyboard extension cannot capture audio
    /// itself); off-W8 it's ignored (the user is mid-flow on another
    /// step). Auto-advance to W9 happens via `TryKeyboardStep`'s
    /// existing polling on `ClipboardHandoff.readFresh()` — the user
    /// taps Stop in the keyboard's pill, transcription completes, the
    /// paste lands in the wizard's TextField, and the polling sees the
    /// fresh handoff and calls onAdvance to W9.
    /// Receiving the notification at all implies the keyboard has Full
    /// Access (without it the keyboard can't read the App Group
    /// foreground-heartbeat slot used for host detection), so the W5
    /// bounce-back path mentioned in the bug spec is not needed — the
    /// no-FA branch is handled keyboard-side by the existing
    /// `openHostSettings()` fallback.
    @State private var dictateTapObserver: CrossProcessNotification.Observer?

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .microphone) }
                )

            case .microphone:
                MicStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .speechModel) }
                )

            case .speechModel:
                SpeechModelStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .keyboardInstall) },
                    gate: downloadGate
                )

            case .keyboardInstall:
                KeyboardInstallStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .fullAccess) }
                )

            case .fullAccess:
                FullAccessStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .howItWorks) }
                )

            case .howItWorks:
                HowItWorksStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .tryInApp) }
                )

            case .tryInApp:
                TryInAppStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .tryKeyboard) }
                )

            case .tryKeyboard:
                TryKeyboardStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .warmHold) }
                )

            case .warmHold:
                WarmHoldStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .youreReady) }
                )

            case .youreReady:
                YoureReadyStep(
                    onClose: closeAndComplete,
                    onAdvanceToOptional: { advance(to: .vocabSeed) },
                    onSkipOptional: closeAndComplete
                )

            case .vocabSeed:
                VocabSeedStep(
                    onClose: closeAndComplete,
                    onAdvance: { advance(to: .aiOffer) },
                    onSkip: closeAndComplete
                )

            case .aiOffer:
                AIOfferStep(
                    onClose: closeAndComplete,
                    onComplete: closeAndComplete
                )
            }
        }
        .task {
            downloadGate.start()
        }
        .onAppear {
            // Install the keyboard-dictate-tapped observer on first
            // wizard appearance. The keyboard posts this Darwin
            // notification ONLY when the host app is Jot (heartbeat
            // freshness check) AND the user taps the Dictate pill —
            // which on the wizard W8 surface is exactly the gesture
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
        }
    }

    /// Handles the keyboard's `keyboardDictateTapped` notification.
    /// Tap on keyboard's Dictate triggers the main-app recording —
    /// the keyboard extension can't capture audio itself, so W8's
    /// end-to-end test (record → transcribe → paste lands in the
    /// wizard's TextField) requires the main app to drive the
    /// recording while the keyboard surfaces the Stop pill via its
    /// cross-process recording-state observer.
    ///
    /// Auto-advance to W9 happens via `TryKeyboardStep`'s existing
    /// polling on `ClipboardHandoff.readFresh()`, NOT here — once the
    /// user taps Stop in the keyboard, the transcription publishes a
    /// fresh handoff that the polling picks up.
    ///
    /// Off-W8 (welcome, fullAccess, etc.) we deliberately ignore the
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
                try await recordingService.start()
            } catch {
                // Expected on already-recording / pipeline-in-flight
                // contention; non-fatal — the existing in-flight
                // recording covers the user's intent.
            }
        }
    }

    private func advance(to next: SetupStep) {
        withAnimation(.easeInOut(duration: 0.22)) {
            step = next
        }
    }

    /// Marks the setup wizard complete and dismisses. The "X" close
    /// button and the "Maybe later"/"Skip" buttons on W10/W11/W12 all
    /// share this exit path.
    private func closeAndComplete() {
        SetupCompletion.markCompleted()
        onComplete()
    }
}

/// 12-case step machine — one case per W1..W12 visual surface. Cases are
/// ordered to mirror the visual W-number sequence exactly, which keeps the
/// progress-dot row in lockstep with the step transitions.
private enum SetupStep: Hashable {
    case welcome           // W1
    case microphone        // W2
    case speechModel       // W3
    case keyboardInstall   // W4
    case fullAccess        // W5
    case howItWorks        // W6
    case tryInApp          // W7
    case tryKeyboard       // W8
    case warmHold          // W9
    case youreReady        // W10
    case vocabSeed         // W11 (optional)
    case aiOffer           // W12 (optional)
}

#Preview {
    SetupWizardView {}
        .environment(TranscriptionService())
        .environment(StreamingTranscriptionService())
        .environment(RecordingService.shared)
}
