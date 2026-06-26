import AVFoundation
import SwiftUI
import os.log

/// Sheet for the hidden TTS Lab: record a short voice sample, name it, and
/// create a cloned voice via `TTSService.cloneVoice(sampleURL:name:)`.
///
/// ## Why a fresh `AVAudioRecorder` (not `RecordingService`)
///
/// Cloning needs a plain audio file, not the dictation pipeline. Routing
/// through `RecordingService` would entangle this with warm-hold, the
/// transcription pipeline, and the recording-hero — none of which apply here.
/// We take a short-lived `.record` session, write a 24 kHz mono WAV to `tmp/`,
/// and hand that URL to PocketTTS. The sample is deleted after cloning (or on
/// dismiss) so the user's voice recording never lingers — consistent with
/// Jot's "only feedback leaves the device" posture (nothing here leaves at all).
///
/// PocketTTS's cloner accepts WAV at any sample rate; we record 24 kHz mono to
/// match its synthesis rate and keep the file tiny.
struct VoiceCloneRecorderView: View {
    @Environment(\.dismiss) private var dismiss

    /// A phonetically rich passage — covers a broad spread of vowels and
    /// consonants in ~3 sentences so the clone captures the user's timbre well.
    private static let sampleScript = """
    The quick brown fox jumps over the lazy dog while five wizards box. \
    Sphinx of black quartz, judge my vow — and bright vixens jump for joy. \
    Pack my red box with a dozen quality jugs, then speak clearly and naturally.
    """

    @State private var recorder: SampleRecorder = SampleRecorder()
    @State private var voiceName: String = ""
    @State private var elapsed: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var errorMessage: String?

    @State private var ttsService = TTSService.shared

    /// Minimum usable sample length — too short and the clone is mushy.
    private let minSeconds: TimeInterval = 8
    /// Hard cap; the Record control auto-stops here.
    private let maxSeconds: TimeInterval = 30

    private var isCloning: Bool {
        switch ttsService.cloneState {
        case .idle, .failed: return false
        case .preparingModel, .cloning: return true
        }
    }

    private var hasUsableTake: Bool {
        recorder.lastRecordingURL != nil && elapsed >= minSeconds
    }

    private var canCreate: Bool {
        hasUsableTake
            && !voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCloning
            && !recorder.isRecording
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        scriptCard
                        recordControls
                        nameField
                        if let errorMessage {
                            errorCard(errorMessage)
                        }
                        if isCloning {
                            cloningStatus
                        }
                        createButton
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Clone my voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismissAndCleanup() }
                        .disabled(isCloning)
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
            recorder.cancelIfRecording()
            recorder.discardSample()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read the passage below aloud in your natural voice. We turn the recording into a voice you can use for read-aloud.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
            Text("Everything stays on your iPhone.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scriptCard: some View {
        LiquidGlassCard {
            Text(Self.sampleScript)
                .font(.system(size: 18, weight: .regular, design: .default))
                .lineSpacing(6)
                .foregroundStyle(Color.jotPageInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordControls: some View {
        VStack(spacing: 12) {
            Button {
                toggleRecording()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text(recorder.isRecording ? "Stop" : (hasUsableTake ? "Record again" : "Record"))
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    Capsule(style: .continuous)
                        .fill(recorder.isRecording ? Color(.systemRed) : Color.jotBlueTop)
                )
            }
            .buttonStyle(.plain)
            .disabled(isCloning)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record voice sample")

            Text(timerLabel)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.jotPageInkSecondary)
        }
    }

    private var timerLabel: String {
        if recorder.isRecording {
            return "Recording… \(Int(elapsed))s (aim for \(Int(minSeconds))–\(Int(maxSeconds))s)"
        }
        if recorder.lastRecordingURL != nil {
            if elapsed < minSeconds {
                return "Too short — record at least \(Int(minSeconds))s"
            }
            return "Recorded \(Int(elapsed))s · tap Create voice"
        }
        return "Tap Record and read the passage"
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.jotPageInkSecondary)
            TextField("My voice", text: $voiceName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.jotMuteWeak.opacity(0.5), lineWidth: 0.5)
                )
                .disabled(isCloning)
        }
    }

    private var cloningStatus: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(cloningStatusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.jotInk)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var cloningStatusText: String {
        switch ttsService.cloneState {
        case .preparingModel: return "Preparing the voice engine…"
        case .cloning: return "Creating your voice…"
        default: return "Working…"
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.jotWarning)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotWarning.opacity(0.10))
        )
    }

    private var createButton: some View {
        Button {
            createVoice()
        } label: {
            Text(isCloning ? "Creating…" : "Create voice")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.jotBlueTop)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
        .opacity(canCreate ? 1.0 : 0.5)
        .accessibilityLabel("Create voice")
    }

    // MARK: - Actions

    private func toggleRecording() {
        errorMessage = nil
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            elapsed = 0
            timerTask?.cancel()
            timerTask = Task {
                while !Task.isCancelled, recorder.isRecording {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    elapsed = recorder.currentTime
                    if elapsed >= maxSeconds {
                        stopRecording()
                        break
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't start recording. Check microphone access in Settings."
        }
    }

    private func stopRecording() {
        timerTask?.cancel()
        timerTask = nil
        elapsed = recorder.currentTime
        recorder.stop()
        DiagnosticsLog.record(
            source: "tts", category: .tts, message: "clone recording stopped",
            metadata: ["elapsedSec": "\(Int(elapsed))", "hasFile": "\(recorder.lastRecordingURL != nil)"]
        )
    }

    private func createVoice() {
        guard let url = recorder.lastRecordingURL else { return }
        errorMessage = nil
        let name = voiceName
        Task {
            do {
                try await ttsService.cloneVoice(sampleURL: url, name: name)
                DiagnosticsLog.record(source: "tts", category: .tts, message: "clone created", metadata: ["name": name])
                recorder.discardSample()
                dismiss()
            } catch {
                DiagnosticsLog.record(
                    source: "tts", category: .tts, message: "clone failed",
                    metadata: ["error": error.localizedDescription]
                )
                errorMessage = "Couldn't create the voice. Please try recording again."
            }
        }
    }

    private func dismissAndCleanup() {
        recorder.cancelIfRecording()
        recorder.discardSample()
        dismiss()
    }
}

/// Minimal `AVAudioRecorder` wrapper for a one-shot voice sample. Records 24 kHz
/// mono linear-PCM WAV into `tmp/`. Deliberately independent of
/// `RecordingService` (see `VoiceCloneRecorderView` doc comment).
@MainActor
@Observable
final class SampleRecorder: NSObject, AVAudioRecorderDelegate {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "tts-voice-clone"
    )

    private(set) var isRecording = false
    /// URL of the most recent completed take (nil until the first stop).
    private(set) var lastRecordingURL: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// Wall-clock anchor for the in-flight take; nil when not recording.
    @ObservationIgnored private var startedAt: Date?
    /// Duration (s) of the last completed take, captured at `stop()`.
    private(set) var lastTakeSeconds: TimeInterval = 0

    /// 24 kHz mono 16-bit PCM WAV — matches PocketTTS's synthesis rate and is a
    /// format its cloner reads directly.
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    func start() throws {
        guard !isRecording else { return }

        // This recorder uses its own `AVAudioRecorder` and bypasses
        // `RecordingService.start()`, so it must yield in-flight TTS read-aloud
        // itself — otherwise "play a voice → open clone sheet → record" hits the
        // same `.playback`-vs-`.record` collision. No-op when nothing is playing.
        AudioSessionArbiter.shared.yieldForRecording()

        // Stand warm-hold down FIRST, so the shared dictation engine isn't a
        // SECOND recorder contending with ours for the mic (the real cause of
        // the "30s captured as ~0s / too short" bug). Two independent adversarial
        // reviews confirmed this is the safe approach — never tee/reuse the LIVE
        // warm engine (five paths tear it down mid-take, truncating the take).
        // `releaseWarmHold()` is the SAME gentle exit Ask's sheet-close uses:
        // a no-op when not warm, and it synchronously frees the mic + restores
        // the session before we record. `RecordingService` itself is untouched.
        RecordingService.shared.releaseWarmHold()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        // Fresh temp file per take; the prior one (if any) is removed.
        discardSample()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-sample-\(UUID().uuidString).wav")

        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record() else {
            throw NSError(domain: "VoiceClone", code: 1)
        }
        self.recorder = recorder
        self.lastRecordingURL = url
        self.isRecording = true
        // Measure elapsed from the WALL CLOCK, not `AVAudioRecorder.currentTime`:
        // that property is unreliable on-device (can report ~0 while recording
        // fine), which falsely tripped the "record at least 8s" gate and threw
        // away good 30s takes. Wall clock can't misread.
        self.startedAt = Date()
    }

    /// Live elapsed time of the in-flight take from the wall clock (robust —
    /// `AVAudioRecorder.currentTime` can misread 0 on-device). After `stop()`,
    /// returns the captured duration of the last take.
    var currentTime: TimeInterval {
        if let startedAt { return Date().timeIntervalSince(startedAt) }
        return lastTakeSeconds
    }

    func stop() {
        if let startedAt { lastTakeSeconds = Date().timeIntervalSince(startedAt) }
        startedAt = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cancelIfRecording() {
        guard isRecording else { return }
        startedAt = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Delete the on-disk sample (after a successful clone, or on dismiss).
    func discardSample() {
        if let url = lastRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        lastRecordingURL = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // No-op: the user drives stop via `stopRecording()` (the recorder has no
        // duration cap). Logging here would need a hop off this nonisolated
        // delegate callback to reach the `@MainActor` logger — not worth it.
    }
}
