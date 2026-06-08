import os
import SwiftUI
import WatchKit

private let viewLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "RecordingView")

/// Modal sheet over `RootView`. Drives a `WatchRecorder` session that
/// captures AAC 16kHz mono audio. No Cancel — once recording starts, the
/// only exit is Stop (or the 15-min cap auto-save). This is intentional:
/// silent data loss from accidental Cancel taps is worse than the rare
/// "I changed my mind" case.
///
/// Uses `WKExtendedRuntimeSession(sessionType: .audioRecording)` to keep
/// `AVAudioRecorder` running while the wrist is lowered. Without this
/// the watch app suspends within ~3 minutes and recording silently dies.
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
    @State private var amplitudeBars: [Float] = Array(repeating: 0.1, count: 10)
    @State private var showingCapWarning: Bool = false
    @State private var showingCapAlert: Bool = false
    @State private var timerTask: Task<Void, Never>?
    @State private var amplitudeTask: Task<Void, Never>?
    @State private var saving: Bool = false
    /// Surfaced via alert if `stopAndSave` throws. Previously this was a
    /// silent `try?`, which made the "nothing happens after I record"
    /// failure mode invisible — the recording would dismiss with no
    /// signal that the audio file failed to save or that enqueue
    /// dropped it. Now the user sees the actual error string.
    @State private var saveError: String?

    /// Recording cap: 15 minutes. At 14:30 we warn with a haptic +
    /// banner; at 15:00 we auto-save. Matches what Parakeet handles
    /// comfortably and is far enough above typical "thought" capture.
    private let capSeconds: Int = 15 * 60
    private let warnAtSeconds: Int = 14 * 60 + 30

    /// `true` when motion-based animations should freeze. Combined
    /// signal: AOD via `isLuminanceReduced`, or accessibility setting.
    private var staticVisuals: Bool { isLuminanceReduced || reduceMotion }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            // Dot + timer row. Fully static — no halo, no pulse, no
            // opacity animation. Earlier iterations had a blurred halo
            // + scale pulse + opacity blink which together read as a
            // bouncing red bloom on the small watch screen. The static
            // red dot + monospaced timer + waveform are enough cue
            // that recording is live; the animation was visual noise.
            HStack(spacing: 8) {
                Circle()
                    .fill(JotDesignWatchSafe.jotRecordingDot)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("Recording")

                Text(timerString)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                    .accessibilityValue("\(elapsedSeconds) seconds elapsed")

                if staticVisuals {
                    Text("REC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(JotDesignWatchSafe.jotRecord)
                }
            }

            // Waveform — hidden under AOD or Reduce Motion (no value
            // when it can't animate).
            if !staticVisuals {
                HStack(spacing: 3) {
                    ForEach(0..<amplitudeBars.count, id: \.self) { i in
                        Capsule()
                            .fill(JotDesignWatchSafe.jotAccent)
                            .frame(width: 3, height: CGFloat(8 + amplitudeBars[i] * 32))
                    }
                }
                .frame(height: 40)
                .accessibilityHidden(true)
            }

            if showingCapWarning {
                Text("Reaching 15 min — tap Stop to save or keep recording")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotRecord)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            Spacer(minLength: 0)

            Button {
                stopAndSave()
            } label: {
                HStack(spacing: 6) {
                    if saving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    // Brand blue gradient — matches the mic button on
                    // RootView so the start/stop pair reads as one CTA
                    // family. Was jotRecord (red) which over-indexed on
                    // "alarm/stop" semantics; the red dot already carries
                    // that signal.
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                JotDesignWatchSafe.jotBlueTop,
                                JotDesignWatchSafe.jotBlueBottom
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Saves the recording and queues it for sync to iPhone.")
        }
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

    // MARK: - Lifecycle

    private func startRecording() {
        do {
            try recorder.start()
            startTimer()
            startAmplitudePoll()
        } catch {
            // If the recorder fails to start (e.g., permission denied,
            // hardware unavailable), dismiss immediately. Production
            // code surfaces the error via DiagnosticsLog; for v1 we
            // just bail.
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
                // Kick off the file transfer.
                WatchConnectivityClient.shared.transferQueuedFiles()
                viewLog.info("stopAndSave() — enqueued + transferQueuedFiles called")
            } catch {
                viewLog.error("stopAndSave() — FAILED: \(error.localizedDescription, privacy: .public)")
                capturedError = error.localizedDescription
            }
            await MainActor.run {
                if let capturedError {
                    // Surface the error to the user instead of dismissing
                    // silently. Without this the failure is invisible.
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
        recorder.cancelIfActive()
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
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                let normalized = recorder.normalizedAveragePower()
                await MainActor.run {
                    amplitudeBars = amplitudeBars.dropFirst() + [normalized]
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
