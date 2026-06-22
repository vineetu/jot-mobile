import os
import SwiftUI
import WatchKit

private let viewLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "RecordingView")

/// Modal sheet over `RootView`. Drives a `WatchRecorder` session that
/// captures AAC 16kHz mono audio. No Cancel — once recording starts, the
/// only exit is Stop (tap the coral hero) or the 15-min cap auto-save. This
/// is intentional: silent data loss from accidental Cancel taps is worse
/// than the rare "I changed my mind" case. (This is why the 2026 redesign
/// did NOT adopt the handoff's top-left ✕ — see `docs/watch-redesign/design.md`.)
///
/// ## 2026 redesign
///
/// The blue Stop pill + red-dot/timer row were replaced by a single coral
/// hero circle (`WatchHeroCircle`) with the running `mm:ss` timer **inside**
/// it — tapping the circle stops. A 21-bar coral waveform sits below, then a
/// quiet "Tap to stop" caption (the button itself carries no "Stop" word).
///
/// Uses `WKExtendedRuntimeSession(sessionType: .audioRecording)` to keep
/// `AVAudioRecorder` running while the wrist is lowered. Without this the
/// watch app suspends within ~3 minutes and recording silently dies.
struct RecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WatchSyncQueue.self) private var queue

    /// Use the shared singleton so the diagnostic state captured by the
    /// recorder (invalidation reason, finish flag, file size at stop) is
    /// visible to DiagnosticsView. Also avoids any SwiftUI @State
    /// recreation races since the singleton outlives the view.
    private var recorder: WatchRecorder { WatchRecorder.shared }
    @State private var elapsedSeconds: Int = 0
    @State private var amplitudeBars: [Float] = Array(repeating: 0, count: 21)
    /// Low-pass state for the level meter so bars glide instead of snapping.
    @State private var smoothedLevel: Float = 0
    @State private var showingCapWarning: Bool = false
    @State private var showingCapAlert: Bool = false
    @State private var timerTask: Task<Void, Never>?
    @State private var amplitudeTask: Task<Void, Never>?
    @State private var saving: Bool = false
    /// Surfaced via alert if `stopAndSave` throws. Previously this was a
    /// silent `try?`, which made the "nothing happens after I record"
    /// failure mode invisible.
    @State private var saveError: String?

    /// Recording cap: 15 minutes. At 14:30 we warn with a haptic +
    /// banner; at 15:00 we auto-save.
    private let capSeconds: Int = 15 * 60
    private let warnAtSeconds: Int = 14 * 60 + 30

    /// `true` when motion-based animations should freeze. Combined signal:
    /// AOD via `isLuminanceReduced`, or accessibility setting.
    private var staticVisuals: Bool { isLuminanceReduced || reduceMotion }

    var body: some View {
        let diameter = WatchMetrics.heroDiameter
        return VStack(spacing: 18) {
            Spacer(minLength: 0)

            // Coral hero — tap to stop. Timer lives INSIDE the circle; a
            // brief spinner replaces it while saving.
            Button {
                stopAndSave()
            } label: {
                WatchHeroCircle(
                    fill: JotDesignWatchSafe.watchRecordHero,
                    glow: JotDesignWatchSafe.watchRecordGlow,
                    diameter: diameter
                ) {
                    if saving {
                        ProgressView().tint(.white)
                    } else {
                        Text(timerString)
                            .font(.system(size: WatchMetrics.heroTimer, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                }
            }
            .buttonStyle(HeroPressStyle())
            .disabled(saving)
            .accessibilityLabel("Stop recording")
            .accessibilityValue("\(elapsedSeconds) seconds elapsed")
            .accessibilityHint("Saves the recording and queues it for sync to iPhone.")

            // Live level — coral bars below the circle. Hidden under AOD /
            // Reduce Motion (no value when it can't animate); a static "REC"
            // cue stands in.
            if staticVisuals {
                Text("REC")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(JotDesignWatchSafe.watchRecordWave)
                    .frame(height: 44)
            } else {
                waveform
            }

            if showingCapWarning {
                Text("Reaching 15 min — tap to stop, or keep recording")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotRecord)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            } else {
                Text("Tap to stop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .interactiveDismissDisabled(true)
        .onAppear { startRecording() }
        .onDisappear { cleanup() }
        .alert("Max length reached — saving", isPresented: $showingCapAlert) {
            Button("OK") {}
        }
        .alert(
            "Couldn't save recording",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil; dismiss() } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<amplitudeBars.count, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.5), JotDesignWatchSafe.watchRecordWave],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: CGFloat(6 + amplitudeBars[i] * 34))
            }
        }
        .frame(height: 44)
        .shadow(color: JotDesignWatchSafe.watchRecordWave.opacity(0.5), radius: 4)
        .accessibilityHidden(true)
    }

    // MARK: - Lifecycle

    private func startRecording() {
        do {
            try recorder.start()
            startTimer()
            startAmplitudePoll()
        } catch {
            dismiss()
        }
    }

    private func stopAndSave() {
        guard !saving else { return }
        saving = true
        WKInterfaceDevice.current().play(.success)
        viewLog.info("stopAndSave() — user tapped stop")
        Task {
            var capturedError: String?
            do {
                let file = try await recorder.stopAndSave()
                viewLog.info("stopAndSave() — recorder returned uuid=\(file.uuid, privacy: .public)")
                queue.enqueue(file)
                WatchConnectivityClient.shared.transferQueuedFiles()
                viewLog.info("stopAndSave() — enqueued + transferQueuedFiles called")
            } catch {
                viewLog.error("stopAndSave() — FAILED: \(error.localizedDescription, privacy: .public)")
                capturedError = error.localizedDescription
            }
            await MainActor.run {
                if let capturedError {
                    saveError = capturedError
                    saving = false
                } else {
                    dismiss()
                }
            }
        }
    }

    private func cleanup() {
        timerTask?.cancel()
        amplitudeTask?.cancel()

        // If we're tearing down while still actively recording, the user
        // dismissed the sheet via the system ✕ (on watchOS 26
        // `interactiveDismissDisabled` does NOT suppress that button — verified
        // on-sim). The standing invariant is "the only exit is Stop, never lose
        // audio," so treat that dismissal as Stop: SAVE the capture, don't
        // discard it. The normal Stop path has already set `saving`/cleared
        // `isRecording`, so this only fires for the ✕-while-recording case.
        // Capture the singletons directly (not via `self`) — the view is going
        // away — per the watch teardown rule.
        let recorder = WatchRecorder.shared
        guard recorder.isRecording, !saving else {
            recorder.cancelIfActive()  // genuine teardown with nothing in flight
            return
        }
        Task { @MainActor in
            do {
                let file = try await recorder.stopAndSave()
                WatchSyncQueue.shared.enqueue(file)
                WatchConnectivityClient.shared.transferQueuedFiles()
                viewLog.info("cleanup() — saved on sheet-dismiss uuid=\(file.uuid, privacy: .public)")
            } catch {
                viewLog.error("cleanup() — save-on-dismiss FAILED: \(error.localizedDescription, privacy: .public)")
                recorder.cancelIfActive()
            }
        }
    }

    private func startTimer() {
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    // Don't keep ticking once we've started saving — the
                    // cap-hit path sets `saving = true` and a stale tick
                    // could double-fire the cap action.
                    guard !saving else { return }
                    elapsedSeconds += 1
                    if elapsedSeconds == warnAtSeconds {
                        showingCapWarning = true
                        WKInterfaceDevice.current().play(.directionDown)
                    }
                    if elapsedSeconds >= capSeconds {
                        showingCapAlert = true
                        WKInterfaceDevice.current().play(.notification)
                        stopAndSave()
                    }
                }
            }
        }
    }

    private func startAmplitudePoll() {
        amplitudeTask = Task {
            while !Task.isCancelled {
                // 150ms — 50% slower than the old 100ms, so it reads calm.
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { break }
                let raw = recorder.normalizedAveragePower()
                await MainActor.run {
                    // Real-voice scrolling meter: NO random shimmer (the old
                    // distracting jitter) and NO baseline floor — so the bars
                    // trace what's actually said and sit ~flat in silence.
                    // Light low-pass keeps the glide smooth. Each tick pushes
                    // the newest level on the right and scrolls the rest left.
                    smoothedLevel = smoothedLevel * 0.5 + raw * 0.5
                    withAnimation(.easeOut(duration: 0.22)) {
                        amplitudeBars = Array(amplitudeBars.dropFirst()) + [smoothedLevel]
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var timerString: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
