//
//  TryInAppStep.swift
//  Jot
//
//  Phase 6 — wizard panel W7.
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
//  finished onboarding yet), so W7 calls
//  `TranscriptionService.shared.transcribe(samples:)` directly instead.
//
//  That direct call still runs the canonical inference path via
//  `runInference` and applies the vocab rescore (gated on
//  `VocabularyStore.isEnabled`) — the W7 transcript is the same text the
//  hero path would produce, minus the SwiftData write and the keyboard's
//  auto-paste publish. No risk of streaming partial text leaking into the
//  final transcript: the W7 stop path assigns `transcript` strictly from
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
//  `.transcribing` projection until the 30s stale-deadline fires, so W8's
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

import SwiftUI
import os.log

private let tryInAppLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "setup-wizard.W7"
)

struct TryInAppStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial

    @State private var phase: TestPhase = .idle
    @State private var transcript: String = ""
    @State private var errorMessage: String?

    private enum TestPhase: Equatable {
        case idle           // pre-first-recording
        case recording
        case transcribing
        case done
        case failed
    }

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 6), onClose: onClose)
        ) {
            VStack(spacing: 14) {
                Spacer(minLength: 20)

                WizardTitle(text: "Try it once", size: 28)
                WizardBody(text: "Say something. We'll show your words as they appear.")

                transcriptCard
                    .padding(.top, 14)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.jotWarningInk)
                        .multilineTextAlignment(.center)
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
    }

    // MARK: - Transcript card

    @ViewBuilder
    private var transcriptCard: some View {
        // Recording phase reads the live streaming partial so the user sees
        // their words land word-by-word — matches the promise on the W7
        // panel ("we'll show your words as they appear"). When the streaming
        // pipeline hasn't published anything yet (first few hundred ms of a
        // session, or model not warm), fall back to "Listening…" so the
        // card never reads blank.
        let displayText: String = {
            switch phase {
            case .idle: return "Tap the mic below and read this aloud — \"Testing Jot — looks like it's working.\""
            case .recording:
                let live = streamingPartial.streamingText
                return live.isEmpty ? "Listening…" : live
            case .transcribing: return "Transcribing…"
            case .done, .failed: return transcript.isEmpty ? "No words detected. Try again." : transcript
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
        errorMessage = nil
        transcript = ""

        // Refuse to start if a pipeline is in flight from elsewhere — the
        // wizard normally sits behind a `fullScreenCover` so this is rare,
        // but it's the safest guard.
        guard !recordingService.isRecording, !recordingService.isPipelineInFlight else {
            errorMessage = "A dictation is already in flight. Try again in a moment."
            return
        }

        guard case .ready = transcriptionService.modelState else {
            errorMessage = "Speech model isn't ready yet. Go back one step and finish the download."
            return
        }

        phase = .recording

        Task { @MainActor in
            do {
                // Adopt a fresh session so we don't collide with any prior
                // pendingPasteSession the keyboard may have written.
                recordingService.adoptSession(UUID())
                try await recordingService.start()
            } catch {
                tryInAppLog.error("W7 start failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
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
                // W8's test field shows a stuck "Working" pill on the
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
                tryInAppLog.error("W7 stop/transcribe failed: \(error.localizedDescription, privacy: .public)")
                recordingService.markPipelineFinished()
                recordingService.publishPipelinePhase(.failed, failureReason: "wizard-w7-transcribe-throw")
                streamingPartial.reset()
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
    }
}

