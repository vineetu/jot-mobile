//
//  TryInAppStep.swift
//  Jot
//
//  Phase 6 — wizard panel W5.
//  Real in-app dictation test. Uses the production `RecordingService.shared`
//  + `TranscriptionService.shared.transcribe(samples:)` pair so the path
//  the user exercises here is the same path they'll use after setup.
//
//  ## Why not the full DictationPipeline
//
//  The hero recording flow goes through `controller.stopAndTranscribe()` +
//  `DictationPipeline.completeEndOfRecording`, which (correctly) writes the
//  resulting transcript to SwiftData and publishes a `FreshDictation`
//  payload to the App Group. The wizard MUST NOT pollute the user's
//  transcript history with the test recording (the user hasn't even
//  finished onboarding yet), so W5 calls
//  `TranscriptionService.shared.transcribe(samples:)` directly instead.
//
//  That direct call still runs the canonical inference path via
//  `runInference` and applies the vocab rescore (gated on
//  `VocabularyStore.isEnabled`) — the W5 transcript is the same text the
//  hero path would produce, minus the SwiftData write and the keyboard's
//  auto-paste publish. No risk of streaming partial text leaking into the
//  final transcript: the W5 stop path assigns `transcript` strictly from
//  `transcriptionService.transcribe(samples:)`, not from
//  `streamingPartial.streamingText`.
//
//  ## Pipeline-phase publish on stop
//
//  `RecordingService.stop()` advances the pipeline phase to `.transcribing`
//  on its way out, and `markPipelineFinished()` clears the in-process
//  flag — but it does NOT touch the App Group projection or post the
//  Darwin notification the keyboard observes. Without an explicit
//  `publishPipelinePhase(.idle)` afterward, the keyboard reads a stale
//  `.transcribing` projection until the 30s stale-deadline fires, so W6's
//  test field would see a stuck coral "Working" pill on the keyboard's
//  speak button. We publish `.idle` here so the projection clears in
//  lock-step with the wizard's local phase transition.
//
//  ## Post-recording CTA pattern
//
//  Per Apple HIG, post-confirmation panels should have ONE primary CTA
//  plus at most one secondary affordance. The earlier shape had THREE
//  competing actions in the `.done` phase ("Sounds right? Yes / Trouble?"
//  pills inside a glass card, plus a separate coral "Try again" CTA),
//  which forced the user to parse three labels before continuing.
//
//  The new pattern uses the buttons AS the question: "Sounds good"
//  (primary, advances) + "Try again" (secondary text, resets to idle).
//  The transcript card carries meaning; the buttons carry action.
//

@preconcurrency import AVFAudio
import SwiftUI
import UIKit
import os.log

private let tryInAppLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "setup-wizard.W5"
)

struct TryInAppStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: TestPhase = .idle
    @State private var transcript: String = ""
    @State private var errorMessage: String?
    @State private var startInFlight: Bool = false
    @State private var lastObservedPermission: AVAudioApplication.recordPermission =
        AVAudioApplication.shared.recordPermission
    /// When the failure cause is "mic permission denied", we surface an
    /// "Open Settings" affordance below the error copy. Flag separates
    /// that branch from generic failures (model load, transcription
    /// throw) where Settings would be irrelevant.
    @State private var failureIsMicPermissionDenied: Bool = false
    /// Distinguishes preflight failures (mic denied, model not on disk,
    /// model in .failed state) from post-recording failures (transcribe
    /// threw, empty transcript). The transcript card's "No words
    /// detected. Try again." copy is appropriate only when the user
    /// actually recorded; preflight failures should fall back to the
    /// idle prompt so the card doesn't claim the user spoke when they
    /// didn't. Set true the moment we transition into `.recording`.
    @State private var didAttemptRecording: Bool = false
    /// Set true the moment the step disappears. Used by the async
    /// `start()` / `stop()` continuations to detect the case where the
    /// view was dismissed during the await window — in that case the
    /// `.onDisappear` teardown saw `isRecording=false` and no-op'd, so
    /// the continuation itself must force-stop to honor the wizard
    /// contract (no recording survives W5 dismissal).
    @State private var stepDismissed: Bool = false

    private enum TestPhase: Equatable {
        case idle           // pre-first-recording
        case recording
        case transcribing
        case done
        case failed
    }

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 4), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 14) {
                Spacer(minLength: 20)

                WizardItalicTitle(text: "Try it once", size: 30)
                WizardBody(text: "Say something. We'll show your words as they appear.")

                transcriptCard
                    .padding(.top, 14)

                // Educational footnote: explains the two-model split so
                // the user understands why the live preview reads
                // differently from the final transcript (no punctuation
                // live, and the final pass can recover words the live
                // model missed). Hidden in `.failed` so the error
                // message keeps focus; hidden in `.done` so it doesn't
                // compete with the confirmed result.
                if showTwoModelFootnote {
                    Text("Live preview is fast and rough — no punctuation yet. When you stop, Parakeet makes a more accurate final pass with punctuation and casing.")
                        .font(.footnote)
                        .foregroundStyle(Color.jotMute)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .transition(.opacity)
                }

                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.jotWarningInk)
                            .multilineTextAlignment(.center)
                        // Phase 4: mic-denied is the only failure where
                        // a Settings deep-link is actionable from inside
                        // the wizard — model-load and generic failures
                        // are recovered by tapping "Try again" instead.
                        if failureIsMicPermissionDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.jotAccent)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Spacer(minLength: 12)
            }
        } footer: {
            // Two-CTA pattern in `.done` / `.failed`: primary = "Sounds
            // good" (advance) or "Try again" (retry), secondary text =
            // the quieter alternative. In `.idle` / `.recording` /
            // `.transcribing`, only the primary is shown — there is no
            // secondary affordance during the active recording flow.
            WizardPrimaryButton(
                title: primaryTitle,
                leadingSystemImage: primaryGlyph,
                isDisabled: phase == .transcribing,
                action: primaryAction
            )
            secondaryButton
        }
        .onAppear {
            ensureSpeechModelWarming()
        }
        .onDisappear {
            // Wizard contract: a recording started inside W5 must not
            // survive past W5. If the user navigates away (back chevron,
            // edge-swipe, advance-via-failed-skip, or any other path)
            // with a recording still in flight, force-stop it here.
            // The home view's hero is already gated by
            // `isWizardPresented` while the wizard is up, so no zombie
            // hero accumulates — this disappear-hook is the in-wizard
            // guarantee that the recording itself doesn't outlive W5.
            //
            // `stepDismissed` flips before the synchronous check so the
            // async continuations in `startRecording` / `stopRecording`
            // can detect "I returned after the view was already gone"
            // and force-stop themselves — the synchronous check below
            // misses a recording whose `start()` is still in its await
            // window (`isRecording`/`isPipelineInFlight` haven't flipped
            // yet).
            stepDismissed = true
            if recordingService.isRecording || recordingService.isPipelineInFlight {
                tryInAppLog.notice("W5 disappearing while recording in flight — force-stopping (wizard contract)")
                recordingService.forceStop()
                recordingService.markPipelineFinished()
                recordingService.publishPipelinePhase(.idle)
                streamingPartial.reset()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshMicPermissionAfterSettings()
            // Memory pressure during keyboard-install backgrounding can
            // evict the Parakeet manager between W3 (keyboard install)
            // and W5. Re-warm on return-from-Settings so the user finds
            // the model ready by the time they tap Start.
            ensureSpeechModelWarming()
        }
        .onChange(of: phase) { _, newPhase in
            if case .failed = newPhase, let errorMessage {
                // Delay so VoiceOver focus settles on the newly-appeared
                // error view before the announcement fires — without
                // this, focus shift swallows the announcement.
                let message = errorMessage
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
        }
    }

    // MARK: - Transcript card

    @ViewBuilder
    private var transcriptCard: some View {
        // Recording phase reads the live streaming partial so the user sees
        // their words land word-by-word — matches the promise on the W5
        // panel ("we'll show your words as they appear"). When the streaming
        // pipeline hasn't published anything yet (first few hundred ms of a
        // session, or model not warm), fall back to "Listening…" so the
        // card never reads blank.
        let idlePrompt = "Tap the mic below and read this aloud — \"Testing Jot — looks like it's working.\""
        let displayText: String = {
            switch phase {
            case .idle: return idlePrompt
            case .recording:
                let live = streamingPartial.streamingText
                return live.isEmpty ? "Listening…" : live
            case .transcribing: return "Transcribing…"
            case .done: return transcript.isEmpty ? "No words detected. Try again." : transcript
            case .failed:
                // Preflight failures (mic denied, model not on disk,
                // model load failed) lock phase = .failed before any
                // recording happened — surfacing "No words detected"
                // would imply the user spoke when they didn't. Fall
                // back to the idle prompt; the errorMessage block below
                // already explains what's wrong.
                if !didAttemptRecording { return idlePrompt }
                return transcript.isEmpty ? "No words detected. Try again." : transcript
            }
        }()

        // While streaming, render in Fraunces italic to match the hero
        // surface's editorial treatment of partials. Idle / transcribing /
        // done states keep the system body font so the card reads as a
        // standard wizard instruction.
        let isStreaming = phase == .recording && !streamingPartial.streamingText.isEmpty
        let textFont: Font = isStreaming
            ? .custom(JotType.frauncesItalicText, size: 15)
            : .system(size: 15, weight: .regular)

        GlassCard(tier: .regular, padding: 16) {
            HStack(alignment: .top) {
                Text(displayText)
                    .font(textFont)
                    .foregroundStyle(phase == .idle ? Color.jotMute : Color.jotInk)
                    .lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if phase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
            }
            .frame(minHeight: 78, alignment: .topLeading)
        }
    }

    // MARK: - Primary CTA

    /// Show the "Live preview vs. Parakeet finalize" footnote on every
    /// state where the comparison is meaningful. `.done` keeps it
    /// because that's exactly when the user can see the difference
    /// between the live partial they read and the punctuated final
    /// transcript that landed. `.failed` hides it so the error message
    /// owns the screen.
    private var showTwoModelFootnote: Bool {
        switch phase {
        case .idle, .recording, .transcribing, .done: return true
        case .failed: return false
        }
    }

    private var primaryTitle: String {
        switch phase {
        case .idle: return "Start dictating"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing…"
        // Primary is the affirmative "this is right, continue" action in
        // `.done`; in `.failed` the primary is "Try again" because there
        // is nothing to confirm.
        case .done: return "Sounds good"
        case .failed: return "Try again"
        }
    }

    private var primaryGlyph: String? {
        switch phase {
        case .recording: return "stop.fill"
        case .transcribing: return nil
        case .done: return "checkmark"
        case .failed: return "arrow.clockwise"
        case .idle: return "mic.fill"
        }
    }

    private var primaryAction: () -> Void {
        switch phase {
        case .idle: return startRecording
        case .recording: return stopRecording
        case .transcribing: return {}
        case .done: return onAdvance
        case .failed: return startRecording
        }
    }

    /// Secondary text-style button shown only in `.done` / `.failed` so
    /// the active recording flow stays single-CTA. In `.done` it offers
    /// "Try again" as the quieter alternative to confirming; in `.failed`
    /// it offers "Skip this step" so a user with a broken mic can still
    /// progress through setup.
    @ViewBuilder
    private var secondaryButton: some View {
        switch phase {
        case .done:
            WizardSecondaryTextButton(title: "Try again") {
                transcript = ""
                errorMessage = nil
                failureIsMicPermissionDenied = false
                phase = .idle
            }
        case .failed:
            WizardSecondaryTextButton(title: "Skip this step", action: onAdvance)
        case .idle, .recording, .transcribing:
            EmptyView()
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard !startInFlight else { return }
        startInFlight = true
        errorMessage = nil
        transcript = ""
        failureIsMicPermissionDenied = false
        didAttemptRecording = false

        // Phase 4: attribute mic permission denial explicitly so the user
        // gets an actionable error instead of a generic "Something went
        // wrong" when they revoke mic access between W2 and W5.
        let currentPermission = AVAudioApplication.shared.recordPermission
        lastObservedPermission = currentPermission
        if currentPermission == .denied {
            failureIsMicPermissionDenied = true
            errorMessage = "Microphone permission is required. Open Settings to enable."
            phase = .failed
            startInFlight = false
            return
        }

        // Refuse to start if a pipeline is in flight from elsewhere — the
        // wizard normally sits behind a `fullScreenCover` so this is rare,
        // but it's the safest guard.
        guard !recordingService.isRecording, !recordingService.isPipelineInFlight else {
            errorMessage = genericRecordingErrorMessage
            phase = .failed
            startInFlight = false
            return
        }

        // The model is bundled, but a memory warning during keyboard-
        // install backgrounding can evict the loaded Parakeet manager
        // between W3 (keyboard install) and W5 and flip `modelState`
        // back to `.notLoaded`. Two graceful recoveries:
        //   - `.notLoaded` / `.downloading` / `.loading`: kick warm-up.
        //     `transcribe(samples:)` will await readiness internally via
        //     `ensurePreparing().value`, so the user simply waits a bit
        //     longer after Stop rather than dead-ending here.
        //   - `.failed`: explicit retry — call warmUp() to rebuild the
        //     prepare task and proceed. Recording still works; transcribe
        //     will throw .loadFailed if the underlying issue persists,
        //     which we already attribute via `transcriptionErrorMessage`.
        //
        // The default Parakeet TDT-CTC 110M ships in the IPA, so this
        // branch is unreachable on the default variant. It only fires
        // when the user opted into the Parakeet 0.6B v2 variant in
        // Settings without finishing its download. Surface a clear
        // error pointing the user at Settings rather than triggering a
        // silent first-launch download (Guideline 4.2.3(ii)).
        if !TranscriptionService.modelsExistOnDiskForSelectedVariant() {
            errorMessage = "Speech model isn't downloaded yet. Open Settings → Speech model and tap Download."
            phase = .failed
            startInFlight = false
            return
        }
        switch transcriptionService.modelState {
        case .ready:
            // Happy path — nothing to do.
            break
        case .notLoaded, .loading, .downloading:
            // Auto-recoverable: kick warmUp so it's loading concurrently.
            // `transcribe(samples:)` will await `ensurePreparing().value`
            // internally after stop, so the user simply waits a beat
            // longer in `.transcribing` instead of dead-ending here.
            transcriptionService.warmUp()
        case .failed(let reason):
            // A genuinely-failed prior load (download error, weights
            // corrupted). Recording-then-transcribing would just hit the
            // same load failure with a generic message; surface the
            // specific reason at start time and let the user retry.
            errorMessage = "Speech model failed to load. \(reason)"
            phase = .failed
            startInFlight = false
            // Kick warmUp so a follow-up "Try again" tap can succeed
            // without an extra wizard backtrack.
            transcriptionService.warmUp()
            return
        }

        phase = .recording

        Task { @MainActor in
            defer { startInFlight = false }
            do {
                // Adopt a fresh session so we don't collide with any prior
                // pendingPasteSession the keyboard may have written.
                recordingService.adoptSession(UUID())
                tryInAppLog.notice("RECORDING START FROM: TryInAppStep.startRecording (W5 Start dictating tap)")
                try await recordingService.start()
                // Dismiss-during-start race: if the view disappeared
                // while `start()` was awaiting, the synchronous
                // `.onDisappear` teardown ran before the mic was hot
                // and no-op'd. The recording now lives outside the
                // wizard — reap it here to honor the wizard contract.
                if stepDismissed {
                    tryInAppLog.notice("W5 start() completed after dismiss — force-stopping (wizard contract)")
                    recordingService.forceStop()
                    recordingService.markPipelineFinished()
                    recordingService.publishPipelinePhase(.idle)
                    streamingPartial.reset()
                    return
                }
                // Mark recording attempted only after engine start
                // actually succeeds. If `start()` throws (audio session
                // contention, engine failure), the user never recorded —
                // the post-recording "No words detected" copy would lie.
                didAttemptRecording = true
            } catch {
                tryInAppLog.error("W5 start failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = genericRecordingErrorMessage
                phase = .failed
            }
        }
    }

    private func stopRecording() {
        phase = .transcribing
        Task { @MainActor in
            do {
                let samples = try await recordingService.stop()
                let result = try await transcriptionService.transcribe(samples: samples)
                transcript = result
                // Clear the pipeline-phase projection that `stop()` advanced
                // to `.transcribing`. `markPipelineFinished()` only clears
                // the in-process `isPipelineInFlight` flag — it does NOT
                // touch the App Group projection or post `pipelinePhaseChanged`.
                // Without `publishPipelinePhase(.idle)` here, the keyboard
                // would read a stale `.transcribing` projection (Bug 6:
                // W6's test field shows a stuck "Working" pill on the
                // keyboard's speak button) until the 30s stale-deadline.
                recordingService.markPipelineFinished()
                recordingService.publishPipelinePhase(.idle)
                // Clear the streaming preview text so a subsequent "Try
                // again" tap starts with a blank card instead of leaking
                // the prior session's partial through to the next idle
                // phase.
                streamingPartial.reset()
                phase = .done
            } catch {
                tryInAppLog.error("W5 stop/transcribe failed: \(error.localizedDescription, privacy: .public)")
                recordingService.markPipelineFinished()
                recordingService.publishPipelinePhase(.failed, failureReason: "wizard-w6-transcribe-throw")
                streamingPartial.reset()
                errorMessage = transcriptionErrorMessage(for: error)
                phase = .failed
            }
        }
    }

    private var genericRecordingErrorMessage: String {
        "Couldn't finish that recording. Try again."
    }

    private func transcriptionErrorMessage(for error: Error) -> String {
        guard let transcriptionError = error as? TranscriptionService.TranscriptionError else {
            return genericRecordingErrorMessage
        }

        switch transcriptionError {
        case .audioTooShort:
            return "Recording was too short. Try speaking for at least a second."
        case .loadFailed(let reason):
            // Surface the wrapped reason — without it the user gets a
            // generic message after a long wait, which loses signal
            // about what to actually try next (re-download vs. retry
            // vs. check disk space).
            return "Speech model failed to load. \(reason)"
        case .busy, .inferenceFailed, .audioFileUnreadable, .audioFileConversionFailed:
            return genericRecordingErrorMessage
        }
    }

    /// Pre-warm the Parakeet manager so the model is loading concurrently
    /// while the user reads the screen. No-op if `.ready` (manager is
    /// already cached) or if the prepare task is already in flight
    /// (`.loading` / `.downloading`). Guards against the 4.2.3(ii)
    /// silent-download path by refusing to warm when weights aren't on
    /// disk — that branch surfaces an explicit error in `startRecording`.
    private func ensureSpeechModelWarming() {
        guard TranscriptionService.modelsExistOnDiskForSelectedVariant() else { return }
        switch transcriptionService.modelState {
        case .ready, .loading, .downloading:
            return
        case .notLoaded, .failed:
            transcriptionService.warmUp()
        }
    }

    private func refreshMicPermissionAfterSettings() {
        let currentPermission = AVAudioApplication.shared.recordPermission
        defer { lastObservedPermission = currentPermission }

        guard lastObservedPermission == .denied,
              currentPermission == .granted,
              failureIsMicPermissionDenied
        else { return }

        failureIsMicPermissionDenied = false
        errorMessage = nil
        startInFlight = false
        if phase == .failed {
            phase = .idle
        }
    }
}
