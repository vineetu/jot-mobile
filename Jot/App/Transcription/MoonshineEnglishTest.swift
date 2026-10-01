import Foundation
import MoonshineVoice
import OSLog

/// TEMPORARY owner test (2026-09-27): run English dictation's FINAL transcript
/// through Moonshine v2 — the largest English model, Medium Streaming (245M,
/// MIT) — instead of Parakeet, to judge Moonshine before the Arabic/Vietnamese
/// plan (`docs/plans/moonshine-languages-plan.md`). Behind a hidden Settings
/// switch (5-tap Version). The live text while recording still comes from
/// Parakeet; only the text that is saved and pasted is Moonshine's.
///
/// While the model is downloading or loading, dictation uses the normal
/// engine and Diagnostics says so ("Moonshine not ready"). Remove this file,
/// the switch, and the package when the test ends.
@MainActor
@Observable
final class MoonshineEnglishTest {
    static let shared = MoonshineEnglishTest()

    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private var transcriber: TranscriberBox?
    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "MoonshineTest")

    static var isEnabled: Bool {
        AppGroup.defaults.bool(forKey: AppGroup.Keys.moonshineEnglishTest)
    }

    /// Download (first time) and load the English Medium Streaming model.
    func prepareIfNeeded() {
        switch state {
        case .ready, .downloading, .loading: return
        case .idle, .failed: break
        }
        state = .downloading(0)
        Task { @MainActor in
            do {
                let loaded = try await Transcriber.load(
                    language: "en",
                    modelArch: .mediumStreaming,
                    onProgress: { progress in
                        let fraction = progress.bytesTotal > 0
                            ? Double(progress.bytesDownloaded) / Double(progress.bytesTotal) : 0
                        let overall = (Double(progress.fileIndex) + fraction) / Double(max(progress.totalFiles, 1))
                        Task { @MainActor in
                            if case .downloading = MoonshineEnglishTest.shared.state {
                                MoonshineEnglishTest.shared.state = overall >= 0.999 ? .loading : .downloading(overall)
                            }
                        }
                    }
                )
                transcriber = TranscriberBox(transcriber: loaded)
                state = .ready
                log.info("Moonshine English (medium streaming) ready")
                DiagnosticsLog.record(source: "main-app", category: .modelLoad,
                                      message: "Moonshine v2 English (medium streaming) ready")
            } catch {
                state = .failed(error.localizedDescription)
                DiagnosticsLog.record(source: "main-app", category: .modelLoad,
                                      message: "Moonshine v2 English failed to load",
                                      metadata: ["error": error.localizedDescription])
            }
        }
    }

    /// The Moonshine transcript of `samples` (16 kHz mono), or nil when the
    /// model isn't ready yet (the caller then uses the normal engine).
    func transcribeIfReady(_ samples: [Float]) async -> String? {
        guard let transcriber else {
            DiagnosticsLog.record(source: "main-app", category: .modelLoad,
                                  message: "Moonshine not ready — used the normal English engine",
                                  metadata: ["state": "\(state)"])
            prepareIfNeeded()
            return nil
        }
        let started = Date()
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try transcriber.transcribe(samples)
            }.value
            DiagnosticsLog.record(source: "main-app", category: .modelLoad,
                                  message: "Moonshine v2 transcribed English dictation",
                                  metadata: ["ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
                                             "audioS": String(format: "%.1f", Double(samples.count) / 16_000),
                                             "chars": "\(text.count)"])
            return text
        } catch {
            DiagnosticsLog.record(source: "main-app", category: .modelLoad,
                                  message: "Moonshine v2 transcription failed — used the normal English engine",
                                  metadata: ["error": error.localizedDescription])
            return nil
        }
    }
}

/// `Transcriber` is a non-Sendable class; each dictation's stop-pass hands it
/// to one detached task and awaits it, and stop-passes are serialized by
/// `TranscriptionService`, so it is never used concurrently.
private final class TranscriberBox: @unchecked Sendable {
    let transcriber: Transcriber
    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func transcribe(_ samples: [Float]) throws -> String {
        let transcript = try transcriber.transcribeWithoutStreaming(audioData: samples, sampleRate: 16_000)
        return transcript.lines.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
