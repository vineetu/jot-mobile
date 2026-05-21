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
//    no start haptic) — the timer reads `recordingService.currentRecordingStartedAt`
//    directly, the same observable the keyboard's strip-timer renders from.
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
//    mask.
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
    @Environment(StreamingTranscriptionService.self) private var streamingService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Owned by the parent (`ContentView`). Flipping this to `false` is what
    /// actually pops the nav destination; `dismiss()` alone is unreliable
    /// for `.navigationDestination(isPresented:)`. See the file docblock.
    @Binding var showRecordingHero: Bool
    /// Fired when the user backgrounds the hero with the visible back
    /// chevron, the iOS swipe-back gesture, or any other non-cancel/non-stop
    /// disappearance while the recording is still live. The back chevron
    /// calls `backTapped()`; the swipe-back gesture remains a parallel path.
    /// The parent uses this signal to mark the hero as "user-dismissed" so
    /// its auto-push observers (`onAppear`, `onChange` of `isRecording`)
    /// don't immediately slam us back here. The recording itself is NOT
    /// stopped — `cancelTapped` (the top header pill) is the only path that
    /// actually cancels. The flag is cleared automatically when the recording
    /// ends or the user re-enters via the home-surface return pill.
    var onBackgrounded: (() -> Void)?
    /// What this presentation is for — fresh FAB tap vs. adoption of an
    /// already-running session. Set by the caller before flipping the
    /// `showRecordingHero` binding; consumed once on `.onAppear` via
    /// `beginRecordingFlow`.
    let intent: HeroIntent

    @State private var phase: HeroPhase = .starting
    // Anchor for the elapsed-time display is sourced from
    // `recordingService.currentRecordingStartedAt` — the same observable the
    // keyboard's strip timer reads. A local snapshot here would go stale
    // across warm-hold/warm-resume cycles while the view stayed mounted,
    // making the hero show a longer elapsed than the keyboard.
    @State private var elapsed: TimeInterval = 0
    @State private var bars: [CGFloat] = Array(repeating: 0.18, count: 40)
    @State private var timerTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var stopTask: Task<Void, Never>?
    @State private var errorMessage: String?
    /// Latched by the swipe-back / `backTapped()` path so the `.onDisappear` safety-net cancel
    /// doesn't fire when the user is INTENTIONALLY backgrounding the hero
    /// (recording must keep running). `cancelTapped()` and `stopTapped()`
    /// have already cleaned up by the time the view disappears via those
    /// paths, so they don't need the latch. Default `false` so the safety
    /// net stays armed for system-back gestures, scene transitions, etc.
    @State private var dismissingViaBack: Bool = false

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
            WallpaperBackground(tintOverlay: WallpaperBackground.recordingTint())

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                streamingTextArea
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)

                Spacer(minLength: 24)

                stopButton
                    .padding(.bottom, 36)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // See TranscriptDetailView for rationale — re-apply AFTER hiding
        // chrome so the swipe-back gesture isn't disabled by iOS.
        .enableInteractivePopGesture()
        .onAppear {
            startHaptic.prepare()
            stopHaptic.prepare()
            cancelHaptic.prepare()
            successHaptic.prepare()
            beginRecordingFlow()
            beginTimerLoop()
            // Move VoiceOver focus to the live transcript card instead of
            // the default first-focusable back chevron, so an auto-pushed hero
            // immediately announces the active recording.
            recordingStatusFocused = true
        }
        .onDisappear {
            timerTask?.cancel()
            // Intentional backgrounding via the visible back chevron calls
            // `backTapped()`, which sets `dismissingViaBack = true` before
            // this fires; keep the recording running and bail out before the
            // safety-net cancel.
            // (`cancelTapped` and `stopTapped` already cleaned up state
            // themselves and don't need this guard.)
            guard !dismissingViaBack else { return }
            // The iOS swipe-back gesture (`.enableInteractivePopGesture()`)
            // still backgrounds the hero through this safety net. When we
            // disappear while the recording is still alive and the user did
            // NOT explicitly cancel/stop, treat the pop as a backgrounding
            // intent rather than a cancel: hold the recording, fire
            // `onBackgrounded` so the parent stops auto-pushing us back, and
            // latch the flag so the home surface's return-pill flow takes
            // over.
            if (phase == .recording || phase == .starting)
                && recordingService.isRecording {
                onBackgrounded?()
                dismissingViaBack = true
                return
            }
            // Defensive: if we somehow disappear mid-flight but the mic
            // is no longer live (race with external shutdown), reset
            // streaming state so the next hero starts blank.
            if phase == .recording || phase == .starting {
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

    private var backButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
                .frame(width: 36, height: 36)
                .background {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                        Circle()
                            .fill(Color.white.opacity(0.55))
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to Recents. Recording continues in the background.")
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            backButton

            Spacer(minLength: 0)

            Button(action: cancelTapped) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotPageInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.55))
                        }
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Cancel recording")
        }
        .frame(minHeight: 44)
    }

    // MARK: - Streaming text

    /// Vertical-line cap for the streaming text block before scrolling kicks in.
    /// ~14 lines of Fraunces 19pt editorial italic at ~28pt computed line height.
    /// Below this many lines the block is rendered as a plain centered Text and
    /// grows in both directions around the "Listening…" anchor; above it the
    /// block freezes at this height and scrolls internally with a top fade.
    private static let streamingMaxBlockHeight: CGFloat = 14 * 28

    @ViewBuilder
    private var streamingTextArea: some View {
        let text = streamingPartial.streamingText
        let isLoadingModel = streamingService.sessionLoadState == .loading
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if text.isEmpty {
                    if isLoadingModel {
                        loadingPlaceholder
                    } else {
                        Text("Listening…")
                            .font(.system(size: 26, weight: .regular, design: .serif).italic())
                            .lineSpacing(8.3)
                            .tracking(-0.4)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                } else {
                    StreamingDictationText(
                        text: text,
                        maxBlockHeight: Self.streamingMaxBlockHeight,
                        reduceMotion: reduceMotion
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            WaveformBars(values: bars, reduceMotion: reduceMotion)
                .frame(height: 36)
                .padding(.top, 18)
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.jotPageInk.opacity(0.30), radius: 20, x: 0, y: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            text.isEmpty
                ? (isLoadingModel
                    ? "Recording in progress. Loading \(SpeechModelVariant.current().displayName)."
                    : "Recording in progress. Listening.")
                : "Recording in progress. \(text)"
        )
        .accessibilityFocused($recordingStatusFocused)
    }

    /// "Loading [variant]…" placeholder rendered in the streaming card
    /// while `streamingService.sessionLoadState == .loading` — i.e. the
    /// per-session ANE load of the streaming graph is in flight. Once
    /// the model lands and either the first partial arrives or
    /// `sessionLoadState` flips to `.ready`, this gives way to the
    /// usual "Listening…" / live transcript pair.
    ///
    /// Visual contract: identical typography to the "Listening…"
    /// placeholder (26pt serif italic, `jotPageInkSecondary`) so the
    /// swap reads as a copy change rather than a layout shift. A small
    /// monochrome `ProgressView` sits inline to the left so users know
    /// the placeholder is active work, not idle silence. Light/dark
    /// adapt through `jotPageInkSecondary`.
    @ViewBuilder
    private var loadingPlaceholder: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.jotPageInkSecondary)
                .accessibilityHidden(true)

            Text("Loading \(SpeechModelVariant.current().displayName)…")
                .font(.system(size: 26, weight: .regular, design: .serif).italic())
                .lineSpacing(8.3)
                .tracking(-0.4)
                .foregroundStyle(Color.jotPageInkSecondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    // MARK: - Bottom controls

    private var stopButton: some View {
        Button(action: stopTapped) {
            HStack(spacing: 14) {
                if phase == .transcribing {
                    ProgressView()
                        .tint(Color.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 20, height: 20)

                    Text(timeString)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                }
            }
            .frame(height: 64)
            .padding(.horizontal, 24)
            .background(
                LinearGradient(
                    colors: [
                        Color.jotBlueTop,
                        Color.jotBlueBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            }
            // Stacked blue shadows — tight contact shadow + a soft ambient
            // bloom at a larger radius — so the button's blue bleeds into
            // the surrounding wallpaper the way a macOS Sequoia / iOS 26
            // glass control glows. Three layers (tight, mid, soft) give the
            // bloom a natural falloff without needing a separate radial halo
            // view behind the button.
            .shadow(color: Color.jotBlueTop.opacity(0.45), radius: 16, x: 0, y: 8)
            .shadow(color: Color.jotBlueTop.opacity(0.28), radius: 48, x: 0, y: 18)
            .shadow(color: Color.jotBlueTop.opacity(0.14), radius: 96, x: 0, y: 28)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
                recordingHeroLog.notice("RECORDING START FROM: RecordingHeroView.startNewRecording (FAB tap)")
                try await recordingService.start()
                await MainActor.run {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
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
    /// `.alreadyRunning`. Skip the start haptic (the recording was already
    /// going from the user's POV) and jump straight to `.recording` so the
    /// timer + waveform start ticking — the timer reads its anchor off
    /// `recordingService.currentRecordingStartedAt` directly, so no local
    /// snapshot is needed here.
    private func adoptInFlightRecording() {
        elapsed = 0
        phase = .recording
    }

    private func stopTapped() {
        guard phase == .recording else { return }
        let recordingStartedAt = recordingService.currentRecordingStartedAt ?? Date()
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

    /// Back chevron — drops the user back to home WITHOUT cancelling the
    /// recording. The mic, transcription pipeline, and Live Activity all keep
    /// running. The parent ContentView observes `onBackgrounded` to mark the
    /// hero as user-dismissed so its `isRecording` auto-push observers don't
    /// immediately push us back. The user returns either via the home-surface
    /// recording indicator (which clears the dismissal flag) or naturally
    /// when the recording ends and the dismissal flag is reset.
    private func backTapped() {
        onBackgrounded?()
        // Latch BEFORE flipping the binding so the `.onDisappear` safety-net
        // sees it and skips the cancel-on-disappear branch.
        dismissingViaBack = true
        // Flip the binding (pops the nav destination) and call `dismiss()` as
        // a fallback for any modal-context callers. No `forceStop`, no haptic,
        // no state mutation — the recording stays live behind us.
        showRecordingHero = false
        dismiss()
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
                if phase == .recording,
                   let started = recordingService.currentRecordingStartedAt {
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

/// 40-bar amplitude waveform with a blue gradient. Newest sample is at
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
                                    Color.jotBlueTop,
                                    Color.jotBlueBottom
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

/// Bottom-anchored streaming text block with two render modes:
///
/// 1. **Under-cap (natural growth).** While the text's natural rendered height
///    is below `maxBlockHeight`, the inner `ScrollView` is frame-locked to the
///    measured text height. The outer `streamingTextArea` then has two
///    `Spacer`s above and below it that expand evenly, keeping the block
///    vertically centered. Each new word makes the measured height grow → the
///    block expands in both directions out of the "Listening…" anchor. The
///    fade mask is suppressed here so there is no fade-out at the top of the
///    growing text — the user sees a clean centered block.
///
/// 2. **At-or-over cap (scroll mode).** Once the measured text height reaches
///    `maxBlockHeight` (~14-15 lines), the inner ScrollView freezes at that
///    height, the top fade mask switches on, and `scrollTo` keeps the newest
///    line pinned to the bottom edge. Older lines slide up under the top fade.
///    The bottom edge stays sharp; no bottom fade.
///
/// Measurement is done with a hidden `GeometryReader` background on the text,
/// reporting its size through `StreamingTextHeightKey`. Because the text uses
/// `.fixedSize(horizontal: false, vertical: true)` it reports its natural
/// rendered height regardless of the surrounding ScrollView.
private struct StreamingDictationText: View {
    let text: String
    let maxBlockHeight: CGFloat
    let reduceMotion: Bool

    /// Last measured natural height of the text. Seeded with a single-line
    /// estimate so the first render doesn't briefly collapse the ScrollView
    /// to 0pt before the GeometryReader reports back.
    @State private var measuredTextHeight: CGFloat = 28

    var body: some View {
        let clamped = min(measuredTextHeight, maxBlockHeight)
        let isOverflowing = measuredTextHeight > maxBlockHeight

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Single bare Text node — no sibling cursor, no
                    // `.animation(...)` modifier. A sibling view with
                    // `.repeatForever` inside the same HStack as the
                    // frequently-changing Text causes SwiftUI to animate
                    // the text-content diff itself, smearing characters as
                    // partials arrive — so the streaming text is rendered
                    // standalone here with no trailing caret.
                    Text(text)
                        .foregroundColor(Color.jotPageInk)
                        .font(.system(size: 26, weight: .regular, design: .serif).italic())
                        .tracking(-0.4)
                        .lineSpacing(8.3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: StreamingTextHeightKey.self,
                                        value: geo.size.height
                                    )
                            }
                        )
                    Color.clear
                        .frame(height: 1)
                        .id("streamingBottom")
                }
            }
            // Lock the ScrollView's outer height to min(measured, cap).
            // Under-cap: ScrollView is exactly the text's height ⇒ no scroll
            // possible, no clipping, content fully visible. At-or-over cap:
            // ScrollView is frozen at the cap and internal scrolling shows
            // the newest content while older content slides up.
            .frame(height: max(1, clamped))
            // Top fade is only meaningful in scroll mode; under cap the
            // `.black` mask is a no-op pass-through so the centered, growing
            // text doesn't have any phantom fade across the top.
            .mask(
                Group {
                    if isOverflowing {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.0), location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        Color.black
                    }
                }
            )
            .onChange(of: text, initial: false) { _, _ in
                // Only scroll when we're actually in scroll mode. Under cap
                // the ScrollView's frame already equals the text height, so
                // calling scrollTo would nudge the content up by 1pt (the
                // sentinel height) — a visible drift the user shouldn't see.
                //
                // The withAnimation here animates the SCROLL only (it wraps
                // `proxy.scrollTo`). It does NOT attach an `.animation`
                // modifier to the Text — that distinction is what keeps
                // the streaming text from inheriting an animation
                // transaction. Same shape as the keyboard's working
                // `StreamingPane.onChange(of: partialText)` handler.
                guard isOverflowing else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("streamingBottom", anchor: .bottom)
                }
            }
        }
        .onPreferenceChange(StreamingTextHeightKey.self) { newHeight in
            measuredTextHeight = newHeight
        }
    }
}

/// Carries the natural rendered height of the streaming text out of the
/// hidden GeometryReader so the parent can decide whether to scroll.
private struct StreamingTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
