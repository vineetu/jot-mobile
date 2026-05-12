//
//  RecordingHeroView.swift
//  Jot
//
//  Phase 3 of the UX overhaul — full-screen recording hero surface.
//  See: Jot/tmp/ux-overhaul-plan.md §5.2 (Mockup 08).
//
//  Reached two ways:
//  - **Manual entry** via the Dictate FAB on the editorial home: this view
//    auto-starts a recording on appear and runs the same stop-and-transcribe
//    pipeline as the prior in-app recorder.
//  - **Auto-nav entry** from `ContentView` when the URL-scheme handler
//    (`jot://dictate?session=…` from the keyboard) has already kicked
//    `RecordingService.start()` before this view exists. `ContentView`
//    observes `recordingService.isRecording` / `isPipelineInFlight` and
//    programmatically pushes the hero so the home surface never shows
//    no-indication while a recording is hot. In that case
//    `beginRecordingFlow` ADOPTS the in-flight session (no second `start()`,
//    no start haptic) — `startedAt` is read off
//    `DictationActivityCoordinator.shared.recordingStartedAt`.
//
//  On stop or cancel, pops back to the home stack.
//
//  ## Why `showRecordingHero` is a `@Binding`, not `@Environment(\.dismiss)`
//
//  `@Environment(\.dismiss)` is documented for *modal* dismissal. When this
//  view is pushed onto a `NavigationStack` via
//  `.navigationDestination(isPresented:)`, the destination's lifecycle is
//  driven entirely by that binding — `dismiss()` from a nested view doesn't
//  reliably pop it. On every exit path (stop success, cancel, error,
//  stale-mount auto-pop) we flip `showRecordingHero = false` ourselves;
//  `dismiss()` is kept only as belt-and-suspenders for legacy modal contexts.
//
//  ## `HeroIntent` and the stale-presentation pop
//
//  The view supports two lifecycles, picked by the caller via the `intent`
//  parameter:
//   - `.startRecording` (FAB): no recording is expected to be running.
//     Call `recordingService.start()`; on race (somehow already running),
//     adopt.
//   - `.adoptInFlight` (URL-bounce auto-nav, scene re-activation,
//     ContentView.onAppear with a hot mic): a recording is expected to be
//     running. Adopt it. If nothing is in flight, the presentation is
//     STALE (e.g. user backgrounded mid-recording, Live Activity stopped
//     the recording, app re-entered with `showRecordingHero == true`
//     leftover) — pop back to home immediately instead of calling
//     `start()`. Calling `start()` on the stale path would silently
//     create a recording the user never asked for.
//
//  ## What it shows
//  - Top: glass back chevron, pulsing red dot + timer (mono), 3-dots more.
//  - Center: serif italic streaming partial (Fraunces 19pt), trailing-fade
//    mask, jot-red caret.
//  - Bottom: 40-bar amplitude waveform + cancel-X (small glass) + 88pt
//    glass-red stop button with 8pt outer glow ring + wand (small glass).
//
//  ## Backend invariants
//  Nothing in this file mutates services. `RecordingService.start()`,
//  `RecordingService.forceStop()`, `DictationActivityCoordinator`,
//  `DictationPipeline.completeEndOfRecording`, and `StreamingPartial`
//  are read/called exactly as `ContentView` already does. The cancel-X
//  uses `forceStop()` — which already discards captured samples without
//  invoking the publish pipeline — so no new "discard" entry point is
//  needed on `RecordingService`.
//

import SwiftUI
import UIKit
import os.log

private let recordingHeroLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "recording-hero"
)

/// Internal phase machine, scoped to this view. Mirrors the `RecordingPhase`
/// in `ContentView` but kept local because the hero surface drives the
/// auto-start / auto-pop lifecycle, which the home surface does not.
private enum HeroPhase: Equatable {
    case starting        // pre-`start()` race window
    case recording
    case transcribing
    case finished        // pipeline complete, ready to dismiss
    case cancelled       // user cancelled, ready to dismiss
}

struct RecordingHeroView: View {
    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Owned by the parent (`ContentView`). Flipping this to `false` is what
    /// actually pops the nav destination; `dismiss()` alone is unreliable
    /// for `.navigationDestination(isPresented:)`. See the file docblock.
    @Binding var showRecordingHero: Bool
    /// What this presentation is for — fresh FAB tap vs. adoption of an
    /// already-running session. Set by the caller before flipping the
    /// `showRecordingHero` binding; consumed once on `.onAppear` via
    /// `beginRecordingFlow`.
    let intent: HeroIntent

    @State private var phase: HeroPhase = .starting
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var bars: [CGFloat] = Array(repeating: 0.18, count: 40)
    @State private var timerTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var stopTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var pulseOn: Bool = false

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var cancelHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @State private var successHaptic = UINotificationFeedbackGenerator()

    // Programmatic VoiceOver focus: when the hero is auto-pushed from the
    // URL-bounce path, default focus would land on the back chevron (the
    // first focusable element). Per HIG, focus should land on the most
    // meaningful starting element — the recording status (red dot + timer).
    @AccessibilityFocusState private var recordingStatusFocused: Bool

    var body: some View {
        ZStack {
            JotDesign.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.top, 8)

                Spacer(minLength: 12)

                streamingTextArea
                    .padding(.horizontal, 24)

                Spacer(minLength: 12)

                bottomControls
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            startHaptic.prepare()
            stopHaptic.prepare()
            cancelHaptic.prepare()
            successHaptic.prepare()
            beginRecordingFlow()
            beginTimerLoop()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOn = true
                }
            }
            // Move VoiceOver focus to the recording status (red dot + timer)
            // instead of the default first-focusable (back chevron), so an
            // auto-pushed hero immediately announces the active recording.
            recordingStatusFocused = true
        }
        .onDisappear {
            timerTask?.cancel()
            // If we're disappearing mid-recording (e.g. system back gesture
            // override despite hiding the bar), make sure we don't leave a
            // hot mic. Cancel is the safe default — the user navigated away
            // without explicitly stopping, so discard rather than publish a
            // partial dictation they didn't ask for.
            if phase == .recording || phase == .starting {
                recordingService.forceStop()
                streamingPartial.reset()
            }
        }
        // Catch the "user backgrounded mid-recording, recording was
        // terminated externally (Live Activity stop, system kill), user
        // returns" case. On `.active`, if we're presented but nothing is
        // running anywhere in the pipeline, pop back to home rather than
        // sitting on a hero with a Stop button that throws.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if showRecordingHero
                && !recordingService.isRecording
                && !recordingService.isPipelineInFlight
                && phase != .transcribing
                && phase != .finished
            {
                showRecordingHero = false
            }
        }
        .alert(
            "Recording error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {
                errorMessage = nil
                // Flip the binding (pops the nav destination) and call
                // `dismiss()` as a fallback for any modal-context callers.
                showRecordingHero = false
                dismiss()
            }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: "Back"
            ) {
                cancelTapped()
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.jotRecord)
                    .frame(width: 8, height: 8)
                    .opacity(pulseOn && phase == .recording ? 0.35 : 1.0)
                    .accessibilityHidden(true)

                Text(timeString)
                    .font(JotType.monoTimestamp)
                    .foregroundStyle(Color.jotInk)
                    .monospacedDigit()
                    .accessibilityLabel("Recording duration \(timeString)")
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($recordingStatusFocused)

            Spacer(minLength: 8)

            glassCircleButton(
                systemImage: "ellipsis",
                accessibilityLabel: "More options"
            ) {
                // No-op for v1. The mockup shows the affordance; downstream
                // surfaces (cancel-cleanup-rerun, save without paste, etc.)
                // aren't in scope for Phase 3.
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func glassCircleButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Streaming text

    @ViewBuilder
    private var streamingTextArea: some View {
        // Render the streaming partial in Fraunces italic. Trailing-word fade
        // is reproduced via an inline `.mask(LinearGradient)` on the right
        // edge of the text container; the caret is a small jot-red bar
        // baseline-aligned to the end of the line.
        let text = streamingPartial.streamingText
        VStack(alignment: .leading, spacing: 12) {
            if text.isEmpty {
                Text("Listening…")
                    .font(JotType.editorialItalic)
                    .foregroundStyle(Color.jotMute)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(text)
                        .font(JotType.editorialItalic)
                        .foregroundStyle(Color.jotInk)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.85),
                                    .init(color: .black.opacity(0.25), location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .accessibilityLabel(text)

                    if phase == .recording {
                        Rectangle()
                            .fill(Color.jotRecord)
                            .frame(width: 2, height: 22)
                            .opacity(pulseOn ? 0.35 : 1.0)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.15),
            value: streamingPartial.streamingText
        )
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 18) {
            WaveformBars(values: bars, reduceMotion: reduceMotion)
                .frame(height: 60)

            HStack(alignment: .center, spacing: 28) {
                glassCircleButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Cancel recording"
                ) {
                    cancelTapped()
                }

                stopButton

                glassCircleButton(
                    systemImage: "wand.and.stars",
                    accessibilityLabel: "Quick actions"
                ) {
                    // No-op in v1 — the wand is reserved for future post-stop
                    // rewrite invocation from the recording hero (the rewrite
                    // flow currently lives on the transcript-detail surface).
                }
            }
        }
    }

    private var stopButton: some View {
        Button(action: stopTapped) {
            ZStack {
                // Soft outer glow ring (~8pt) — masks behind Reduce Motion
                // since the pulsing makes it animate; keep the static halo
                // but skip the breathing.
                Circle()
                    .stroke(Color.jotRecord.opacity(0.30), lineWidth: 8)
                    .frame(width: 104, height: 104)
                    .blur(radius: 4)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotRecord,
                                Color.jotRecord.opacity(0.88)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: Color.jotRecord.opacity(0.40), radius: 14, x: 0, y: 6)

                if phase == .transcribing {
                    ProgressView()
                        .tint(Color.white)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing || phase == .starting)
        .accessibilityLabel(phase == .transcribing ? "Transcribing" : "Stop recording")
    }

    // MARK: - Recording flow

    /// Single entry point fired by `.onAppear`. Routes to the correct
    /// lifecycle based on `intent`. The three observable outcomes are:
    ///  1. Start a brand-new recording (FAB tap, no in-flight).
    ///  2. Adopt an already-running recording (auto-nav, mic is hot).
    ///  3. Pop back immediately (auto-nav, but nothing is running — stale
    ///     presentation, e.g. app re-entry after Live Activity stop).
    private func beginRecordingFlow() {
        switch intent {
        case .startRecording:
            // FAB. In the happy path nothing is running and we call
            // `start()`. The race-window check (`isRecording` already
            // true) is defensive — should be rare since the FAB lives on
            // home and home auto-pushes the hero on `isRecording=true`.
            if recordingService.isRecording {
                adoptInFlightRecording()
            } else {
                startNewRecording()
            }
        case .adoptInFlight:
            if recordingService.isRecording {
                adoptInFlightRecording()
            } else {
                // STALE presentation. The parent thinks we're recording,
                // but nothing is in flight. Don't `start()` (the user
                // didn't ask for that) — pop back to home. The
                // `.onChange(of: scenePhase)` and `onDisappear` paths
                // will handle teardown of any straggling pipeline state.
                recordingHeroLog.info("Stale hero presentation — popping (no recording, no pipeline)")
                showRecordingHero = false
            }
        }
    }

    /// FAB-fresh start. Owns the start haptic, coordinator handshake,
    /// and the `RecordingService.start()` call.
    private func startNewRecording() {
        startTask?.cancel()
        phase = .starting
        startTask = Task {
            let date = Date()
            await DictationActivityCoordinator.shared.start(startedAt: date)
            do {
                try await recordingService.start()
                await MainActor.run {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                    startedAt = date
                    elapsed = 0
                    phase = .recording
                }
            } catch {
                await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
                await MainActor.run {
                    recordingHeroLog.error(
                        "Recording start failed: \(error.localizedDescription, privacy: .public)"
                    )
                    errorMessage = "Could not start recording: \(error.localizedDescription)"
                    phase = .cancelled
                }
            }
        }
    }

    /// Auto-nav adoption. The URL handler (or some other caller) already
    /// kicked `recordingService.start()`; re-calling it would throw
    /// `.alreadyRunning`. Derive `startedAt` from the coordinator's
    /// authoritative timestamp, skip the start haptic (the recording was
    /// already going from the user's POV), and jump straight to `.recording`
    /// so the timer + waveform start ticking.
    private func adoptInFlightRecording() {
        startedAt = DictationActivityCoordinator.shared.recordingStartedAt ?? Date()
        elapsed = 0
        phase = .recording
    }

    private func stopTapped() {
        guard phase == .recording else { return }
        let recordingStartedAt = startedAt ?? Date()
        recordingService.markStopInFlight()
        stopHaptic.impactOccurred()
        stopHaptic.prepare()
        phase = .transcribing

        stopTask?.cancel()
        stopTask = Task {
            let controller = DictationIntentBridge.shared.controller
            do {
                let result = try await controller.stopAndTranscribe()
                let outcome = try await DictationPipeline.completeEndOfRecording(
                    transcript: result.transcript,
                    startedAt: recordingStartedAt,
                    stoppedAt: result.stoppedAt,
                    controller: controller
                )
                _ = outcome
                await MainActor.run {
                    successHaptic.notificationOccurred(.success)
                    successHaptic.prepare()
                    phase = .finished
                    streamingPartial.reset()
                    // Pop the nav destination — flipping the binding is
                    // what actually pops it; `dismiss()` is a fallback.
                    showRecordingHero = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    recordingService.markPipelineFinished()
                    recordingHeroLog.error(
                        "Dictation failed: \(error.localizedDescription, privacy: .public)"
                    )
                    errorMessage = "Dictation failed: \(error.localizedDescription)"
                    streamingPartial.reset()
                    phase = .cancelled
                }
            }
        }
    }

    private func cancelTapped() {
        cancelHaptic.impactOccurred()
        cancelHaptic.prepare()
        // `forceStop()` discards the captured samples and publishes a
        // `.failed` pipeline phase. That's exactly the cancel semantics
        // we want — no transcript appended, no clipboard publish, no
        // history-mirror refresh. The streaming presenter is cleared
        // here so the next hero surface starts blank.
        recordingService.forceStop()
        streamingPartial.reset()
        phase = .cancelled
        // Pop the nav destination — flipping the binding is what
        // actually pops it; `dismiss()` is a fallback.
        showRecordingHero = false
        dismiss()
    }

    // MARK: - Timer + amplitude

    private func beginTimerLoop() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            // ~10 Hz update for the elapsed timer + bar shift. Mirrors the
            // 0.08s tick used by `ContentView.startVUTimer` but expressed
            // as an async loop so we don't hold a Timer reference across
            // dismiss.
            while !Task.isCancelled {
                if phase == .recording, let started = startedAt {
                    elapsed = Date().timeIntervalSince(started)
                    var next = bars
                    next.removeFirst()
                    let amp = CGFloat(recordingService.currentAmplitude ?? 0.05)
                    next.append(max(0.08, min(1.0, amp)))
                    bars = next
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private var timeString: String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 40-bar amplitude waveform with a coral-red gradient. Newest sample is at
/// the right edge; bars age leftward.
private struct WaveformBars: View {
    let values: [CGFloat]
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, values.count)
            let totalGapWidth = CGFloat(count - 1) * 4
            let barWidth = max(2, (proxy.size.width - totalGapWidth) / CGFloat(count))
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.jotRecord,
                                    Color.jotAccent
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: barWidth,
                            height: barHeight(for: value, container: proxy.size.height)
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.09), value: values)
        .accessibilityHidden(true)
    }

    private func barHeight(for value: CGFloat, container: CGFloat) -> CGFloat {
        let clamped = max(0.05, min(1.0, value))
        let minH: CGFloat = 6
        let maxH = max(minH + 1, container)
        return minH + clamped * (maxH - minH)
    }
}
