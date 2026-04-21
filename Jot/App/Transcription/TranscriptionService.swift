@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import UIKit
import os.log
import os.signpost

/// On-device transcription via FluidAudio's Parakeet TDT 0.6B v3 (Apple Neural Engine).
///
/// Two callers:
/// - `ContentView` (in-app record button) → `transcribe(samples: [Float])` after
///   `RecordingService` drains the tap buffer. Samples already arrive at 16 kHz
///   mono Float32, matching Parakeet's expected input exactly.
/// - `TranscribeAudioFileIntent` (Shortcuts entry point) → `transcribe(audioFileURL: URL)`
///   with whatever audio the Shortcut's prior action produced. We decode + resample
///   in-process and then fall into the same inference path.
///
/// Both paths share model loading + cache. Single-in-flight is enforced via
/// `isTranscribing`; `AsrManager` itself is an actor (per FluidAudio), so the
/// actor's mailbox is the underlying serialization primitive — our flag is a
/// short-circuit that produces a nicer error (`.busy`) instead of letting the
/// actor queue the call and return late.
///
/// See `docs/best-practices.md` §1 (concurrency) and §3 (FluidAudio specifics)
/// for the reasoning behind `@MainActor`, the `@unchecked Sendable` observer
/// pattern, and the Application Support cache location.
@MainActor
@Observable
final class TranscriptionService {
    enum ModelState: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    enum TranscriptionError: LocalizedError {
        case busy
        case audioTooShort
        case loadFailed(String)
        case inferenceFailed(String)
        case audioFileUnreadable(String)
        case audioFileConversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "A transcription is already in progress."
            case .audioTooShort: return "Recording is under one second — Parakeet needs at least 1 s of audio."
            case .loadFailed(let summary): return "Model load failed: \(summary)"
            case .inferenceFailed(let summary): return "Transcription failed: \(summary)"
            case .audioFileUnreadable(let summary): return "Could not read the audio file: \(summary)"
            case .audioFileConversionFailed(let summary): return "Could not decode the audio file to 16 kHz mono: \(summary)"
            }
        }
    }

    /// Process-wide singleton.
    ///
    /// ## Why a singleton
    ///
    /// Two callers enter this file from different layers:
    /// - `JotApp` → injected via `.environment(...)` into SwiftUI
    /// - `TranscribeAudioFileIntent.runTranscription` → headless AppIntent
    ///
    /// Before this was a singleton, each caller held its own
    /// `TranscriptionService` instance, and therefore its own `AsrManager`.
    /// A 10-second Parakeet cold-load on the first in-app record could NOT
    /// be amortized by the main-app instance when a subsequent Shortcut run
    /// arrived in the same process — the intent would fault a fresh
    /// instance and pay the load again.
    ///
    /// Singleton collapses this: one instance → one `AsrManager` → one
    /// warm window. Both callers observe the same `modelState`, so an
    /// eager `warmUp()` on app launch is visible to every subsequent
    /// inference call in the process.
    ///
    /// ## Lifetime
    ///
    /// The shared instance lives for the lifetime of the process.
    /// `AsrManager`'s CoreML handle is process-ephemeral — iOS terminates
    /// the process on jetsam / user swipe-close, and `handleMemoryWarning`
    /// proactively evicts `manager` on `UIApplication.didReceiveMemoryWarning`.
    /// So the guarantee is "warmed at the last eviction boundary," not
    /// "warmed once ever." Subsequent `warmUp()` / `transcribe(...)` calls
    /// re-load as needed.
    ///
    /// ## Testing / preview access
    ///
    /// `init()` stays `internal` so SwiftUI `#Preview` blocks and unit tests
    /// can construct fresh instances without contaminating the shared one.
    @MainActor static let shared = TranscriptionService()

    private(set) var modelState: ModelState = .notLoaded

    private let log = Logger(subsystem: "com.jot.mobile.Jot", category: "transcription")
    private let signposter = OSSignposter(subsystem: "com.jot.mobile.Jot", category: "transcription")

    private let version: AsrModelVersion = .v3
    private let repoFolderName = "parakeet-tdt-0.6b-v3-coreml"
    private var manager: AsrManager?
    private var prepareTask: Task<Void, Error>?

    private var isTranscribing: Bool = false

    // `deinit` is always nonisolated in Swift 6, so it can't touch
    // @MainActor state on this class. We exempt the observer token from
    // both observation tracking (nothing reads it from the UI) and actor
    // isolation. Invariant: written exactly once from `init` (MainActor),
    // read exactly once from `deinit`, never concurrently. The underlying
    // `NotificationCenter.removeObserver` is itself thread-safe.
    @ObservationIgnored
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    init() {
        subscribeMemoryWarnings()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Eagerly kick off Parakeet model download + load, without running
    /// inference. The public "please be ready" hook for any code path that
    /// wants to pay the ~10 s cold-load cost up front rather than at the
    /// first user-visible record button press.
    ///
    /// ## Call sites
    ///
    /// Expected callers (in order of priority):
    /// 1. App launch (`JotApp.body`'s `.task { }`, or an early `onAppear`).
    ///    First-record-is-slow is the user pain this method exists for.
    /// 2. Scene foregrounding — cheap because of the coalescing guarantee
    ///    below. Useful defense-in-depth after a memory-warning eviction.
    /// 3. A first-run wizard or onboarding completion step, if we ever add
    ///    one — gives the user a "warming up Jot…" moment with visible
    ///    download progress via `modelState`.
    ///
    /// Not for: the record-button action. That path already awaits
    /// `ensurePreparing()` inside `transcribe(samples:)` before inference
    /// begins.
    ///
    /// ## Contract
    ///
    /// - **Idempotent + coalescing.** Every call routes through
    ///   `ensurePreparing()`, which returns the single in-flight
    ///   `Task<Void, Error>` if one is active. `N` concurrent `warmUp()`
    ///   calls produce one load, not `N`. A call after load completion
    ///   short-circuits inside `loadOrFail()` (`manager != nil` early
    ///   return) and costs ~nanoseconds.
    ///
    /// - **Non-throwing.** Any load failure surfaces later through
    ///   `modelState == .failed(...)` (observable) or a thrown
    ///   `TranscriptionError.loadFailed` from `transcribe(...)`. Warm-up
    ///   callers don't need to reason about failure modes — their only
    ///   responsibility is "kick the tyres, move on."
    ///
    /// - **Fire-and-forget.** We intentionally drop the returned `Task`.
    ///   The download + load run concurrently with whatever the caller
    ///   does next. Nobody needs to `await` this; if they care about
    ///   readiness they should observe `modelState` instead.
    ///
    /// ## Eviction semantics
    ///
    /// `handleMemoryWarning` may evict `manager` + `prepareTask` under
    /// memory pressure. After eviction, `warmUp()`'s prior effect is
    /// nullified; the next call re-loads. That's intentional — we'd
    /// rather pay the re-load cost than risk jetsam mid-session.
    func warmUp() {
        log.info("Parakeet warmUp requested — modelState=\(Self.describe(self.modelState), privacy: .public)")
        _ = ensurePreparing()
    }

    // MARK: - Sample-based inference (in-app record flow)

    func transcribe(samples: [Float]) async throws -> String {
        try Self.guardAudioLength(sampleCount: samples.count)
        guard !isTranscribing else { throw TranscriptionError.busy }

        isTranscribing = true
        defer { isTranscribing = false }

        let audioDurationSeconds = Self.audioDurationSeconds(sampleCount: samples.count)
        let startedAt = Date()
        let interval = signposter.beginInterval("transcribe-samples")
        log.info(
            "Transcription begin — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public)"
        )

        do {
            let result = try await runInference(
                on: samples,
                label: "samples",
                audioDurationSeconds: audioDurationSeconds
            )
            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: startedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.info(
                "Transcription end — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) chars=\(result.count, privacy: .public)"
            )
            signposter.endInterval("transcribe-samples", interval)
            return result
        } catch {
            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: startedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.error(
                "Transcription failed — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            signposter.endInterval("transcribe-samples", interval)
            throw error
        }
    }

    // MARK: - File-based inference (Shortcuts entry point)

    /// Transcribe an audio file at `url`. Accepts any format `AVAudioFile` can
    /// decode — Shortcuts' built-in *Record Audio* action produces `.m4a`, but
    /// `.wav`, `.caf`, `.aiff`, and any Core Audio–supported format work.
    ///
    /// Flow: pre-flight model-on-disk check → decode → resample to 16 kHz mono
    /// Float32 → run Parakeet → return transcript. This is the entry point for
    /// `TranscribeAudioFileIntent`, which chains after a Shortcut's upstream
    /// file-producing action.
    ///
    /// Safe to call from non-MainActor contexts via standard `await`-hop
    /// semantics. `AsrManager` is an actor (FluidAudio), so the heavy inference
    /// does not block MainActor — MainActor is only held during the short
    /// synchronous file-decode pass.
    ///
    /// ### Observability
    ///
    /// Logs at each step via `os.log` subsystem `com.jot.mobile.Jot`, category
    /// `transcription`. Pull with `log show --predicate 'subsystem == "com.jot.mobile.Jot"'`
    /// or via Console.app to diagnose Shortcut-triggered failures where the
    /// bridged `NSError.code` loses the typed error's context.
    func transcribe(audioFileURL url: URL) async throws -> String {
        log.info(
            "transcribe(audioFileURL:) entry — path=\(url.lastPathComponent, privacy: .public) ext=\(url.pathExtension, privacy: .public) exists=\(FileManager.default.fileExists(atPath: url.path), privacy: .public)"
        )
        let transcriptionStartedAt = Date()

        // Pre-flight: the Parakeet model must already exist on disk. A headless
        // AppIntent run has a ~30 s total execution budget (research doc
        // `docs/research/shortcuts-transcribe-intent.md` §6 risk 2). The Parakeet
        // weights are ~1.25 GB — a cold download cannot complete inside that
        // budget on realistic cellular/Wi-Fi conditions. If the model isn't on
        // disk, fail fast with an actionable message instead of attempting a
        // download that will either exceed the budget (iOS kills the intent
        // process) or return an opaque network error.
        //
        // The main-app `transcribe(samples:)` path is NOT guarded this way
        // because in-app it's fine to run a progress-showing download on the
        // record-button press; `prepare()` in the intent would hit the same
        // wall. This guard exists specifically to produce a *user-actionable*
        // error on the Shortcut path.
        try ensureModelIsDownloadedOrThrow()

        guard !isTranscribing else { throw TranscriptionError.busy }

        let interval = signposter.beginInterval("transcribe-file")

        let decodeStartedAt = Date()
        let decodeInterval = signposter.beginInterval("transcribe-file-decode")
        var decodeIntervalEnded = false
        log.info("transcribe(audioFileURL:) — decode begin startedAt=\(Self.timestamp(decodeStartedAt), privacy: .public)")

        do {
            let samples = try Self.loadAndResample(
                url: url,
                targetSampleRate: Self.sampleRate,
                log: log
            )
            let decodeEndedAt = Date()
            let decodeElapsedMS = Self.elapsedMilliseconds(from: decodeStartedAt, to: decodeEndedAt)
            let audioDurationSeconds = Self.audioDurationSeconds(sampleCount: samples.count)
            signposter.endInterval("transcribe-file-decode", decodeInterval)
            decodeIntervalEnded = true
            log.info(
                "transcribe(audioFileURL:) — decode end startedAt=\(Self.timestamp(decodeStartedAt), privacy: .public) endedAt=\(Self.timestamp(decodeEndedAt), privacy: .public) elapsedMS=\(decodeElapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )
            log.info("transcribe(audioFileURL:) — decoded \(samples.count, privacy: .public) samples @ \(Int(Self.sampleRate), privacy: .public)Hz")

            try Self.guardAudioLength(sampleCount: samples.count)

            let transcribeStartedAt = Date()
            log.info(
                "Transcription begin — source=file startedAt=\(Self.timestamp(transcribeStartedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )

            isTranscribing = true
            defer { isTranscribing = false }

            log.info("transcribe(audioFileURL:) — running Parakeet inference")
            let result = try await runInference(
                on: samples,
                label: "file",
                audioDurationSeconds: audioDurationSeconds
            )
            log.info("transcribe(audioFileURL:) — inference returned \(result.count, privacy: .public) chars")

            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: transcribeStartedAt, to: endedAt)
            let totalElapsedMS = Self.elapsedMilliseconds(from: transcriptionStartedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            let totalRTF = Self.realTimeFactor(elapsedMS: totalElapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.info(
                "Transcription end — source=file startedAt=\(Self.timestamp(transcribeStartedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) totalElapsedMS=\(totalElapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) totalRtf=\(totalRTF, privacy: .public) chars=\(result.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )
            signposter.endInterval("transcribe-file", interval)
            return result
        } catch {
            let endedAt = Date()
            let totalElapsedMS = Self.elapsedMilliseconds(from: transcriptionStartedAt, to: endedAt)
            if !decodeIntervalEnded {
                signposter.endInterval("transcribe-file-decode", decodeInterval)
            }
            signposter.endInterval("transcribe-file", interval)
            log.error(
                "Transcription failed — source=file startedAt=\(Self.timestamp(transcriptionStartedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) totalElapsedMS=\(totalElapsedMS, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Pre-flight for the Shortcut path. Checks whether the Parakeet weights
    /// have been fetched to Application Support; if not, throws a friendly
    /// `.loadFailed` pointing the user at the one-time main-app download.
    ///
    /// Does NOT block on ongoing downloads — if `prepare()` is mid-flight when
    /// the Shortcut runs, the file almost certainly isn't present yet either,
    /// and waiting would just chew through the headless budget. Fail fast; let
    /// the user retry once the main-app download finishes.
    private func ensureModelIsDownloadedOrThrow() throws {
        let directory = Self.modelDirectory(repoFolder: repoFolderName)
        let exists = AsrModels.modelsExist(at: directory, version: version)
        log.info("ensureModelIsDownloadedOrThrow — directory=\(directory.path, privacy: .public) modelsExist=\(exists, privacy: .public)")
        if !exists {
            throw TranscriptionError.loadFailed(
                "The Parakeet speech-recognition model (~1.25 GB) hasn't been downloaded yet. Open Jot once and press Record to finish the one-time download, then re-run your Shortcut."
            )
        }
    }

    // MARK: - Inference core

    private static func guardAudioLength(sampleCount: Int) throws {
        guard Double(sampleCount) >= Self.sampleRate else {
            throw TranscriptionError.audioTooShort
        }
    }

    /// Shared tail: ensure model is loaded, then run `AsrManager.transcribe`.
    /// Callers own the `isTranscribing` flag and the signpost interval — this
    /// helper is the minimal inference body so it stays testable in isolation.
    private func runInference(on samples: [Float], label: String, audioDurationSeconds: Double) async throws -> String {
        let inferenceStartedAt = Date()
        let prepareStartedAt = Date()
        try await ensurePreparing().value
        let prepareEndedAt = Date()
        let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
        log.info(
            "Parakeet prepare wait end — source=\(label, privacy: .public) startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
        guard let manager else {
            throw TranscriptionError.loadFailed("Model manager unavailable after load.")
        }

        let inferenceInterval = signposter.beginInterval("transcribe-inference")
        log.info(
            "Parakeet inference begin — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public)"
        )
        do {
            let result = try await manager.transcribe(samples, source: .microphone)
            let inferenceEndedAt = Date()
            let wallClockMS = Self.elapsedMilliseconds(from: inferenceStartedAt, to: inferenceEndedAt)
            let wallClockRTF = Self.realTimeFactor(elapsedMS: wallClockMS, audioDurationSeconds: result.duration)
            let engineRTF = result.duration > 0 ? result.processingTime / result.duration : 0
            log.info(
                "Parakeet inference end — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) endedAt=\(Self.timestamp(inferenceEndedAt), privacy: .public) wallClockMS=\(wallClockMS, privacy: .public) processingMS=\(result.processingTime * 1_000, privacy: .public) audioDurationS=\(result.duration, privacy: .public) wallClockRtf=\(wallClockRTF, privacy: .public) engineRtf=\(engineRTF, privacy: .public) chars=\(result.text.count, privacy: .public)"
            )
            signposter.endInterval("transcribe-inference", inferenceInterval)
            return result.text
        } catch {
            let inferenceEndedAt = Date()
            let wallClockMS = Self.elapsedMilliseconds(from: inferenceStartedAt, to: inferenceEndedAt)
            let wallClockRTF = Self.realTimeFactor(elapsedMS: wallClockMS, audioDurationSeconds: audioDurationSeconds)
            log.error(
                "Parakeet inference failed — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) endedAt=\(Self.timestamp(inferenceEndedAt), privacy: .public) wallClockMS=\(wallClockMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) wallClockRtf=\(wallClockRTF, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            signposter.endInterval("transcribe-inference", inferenceInterval)
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }
    }

    // MARK: - Model lifecycle (best-practices §3.2, §3.3, §3.7)

    private func ensurePreparing() -> Task<Void, Error> {
        if let prepareTask {
            log.info("Parakeet prepare reuse — modelState=\(Self.describe(self.modelState), privacy: .public)")
            return prepareTask
        }

        let createdAt = Date()
        log.info(
            "Parakeet prepare task create — startedAt=\(Self.timestamp(createdAt), privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.loadOrFail()
        }
        prepareTask = task
        return task
    }

    private func loadOrFail() async throws {
        if manager != nil {
            modelState = .ready
            log.info("Parakeet load skip — manager already ready")
            return
        }

        let directory = Self.modelDirectory(repoFolder: repoFolderName)
        let modelsOnDisk = AsrModels.modelsExist(at: directory, version: version)
        let prepareStartedAt = Date()
        let prepareInterval = signposter.beginInterval("parakeet-prepare")
        log.info(
            "Parakeet prepare begin — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) modelsOnDisk=\(modelsOnDisk, privacy: .public) directory=\(directory.path, privacy: .public)"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            let summary = "Could not create model cache: \(error.localizedDescription)"
            modelState = .failed(summary)
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.error(
                "Parakeet prepare failed — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=false error=\(summary, privacy: .public)"
            )
            throw TranscriptionError.loadFailed(summary)
        }

        var downloadedThisCall = false
        if !modelsOnDisk {
            modelState = .downloading(0)
            downloadedThisCall = true
            let progress: DownloadUtils.ProgressHandler = { [weak self] snapshot in
                let fraction = max(0.0, min(1.0, snapshot.fractionCompleted))
                Task { @MainActor [weak self] in
                    if case .downloading = self?.modelState {
                        self?.modelState = .downloading(fraction)
                    }
                }
            }
            let downloadStartedAt = Date()
            let downloadInterval = signposter.beginInterval("parakeet-download")
            log.info(
                "Parakeet download begin — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) directory=\(directory.path, privacy: .public)"
            )
            do {
                _ = try await AsrModels.download(
                    to: directory,
                    force: false,
                    version: version,
                    progressHandler: progress
                )
                let downloadEndedAt = Date()
                let downloadElapsedMS = Self.elapsedMilliseconds(from: downloadStartedAt, to: downloadEndedAt)
                signposter.endInterval("parakeet-download", downloadInterval)
                log.info(
                    "Parakeet download end — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public) directory=\(directory.path, privacy: .public)"
                )
            } catch {
                let downloadEndedAt = Date()
                let downloadElapsedMS = Self.elapsedMilliseconds(from: downloadStartedAt, to: downloadEndedAt)
                signposter.endInterval("parakeet-download", downloadInterval)
                let summary = "Download failed: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: directory)
                modelState = .failed(summary)
                log.error(
                    "Parakeet download failed — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public) error=\(summary, privacy: .public)"
                )
                throw TranscriptionError.loadFailed(summary)
            }
        }

        modelState = .loading
        let loadStartedAt = Date()
        let loadInterval = signposter.beginInterval("parakeet-load")
        let loadSource = downloadedThisCall ? "download-then-load" : "load-from-disk"
        log.info(
            "Parakeet load begin — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) source=\(loadSource, privacy: .public) directory=\(directory.path, privacy: .public)"
        )
        do {
            let models = try await AsrModels.load(from: directory, version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            self.manager = manager
            modelState = .ready
            let loadEndedAt = Date()
            let loadElapsedMS = Self.elapsedMilliseconds(from: loadStartedAt, to: loadEndedAt)
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-load", loadInterval)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.info(
                "Parakeet load end — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public)"
            )
            log.info(
                "Parakeet prepare end — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
            )
        } catch {
            let summary = "Load failed: \(error.localizedDescription)"
            modelState = .failed(summary)
            let loadEndedAt = Date()
            let loadElapsedMS = Self.elapsedMilliseconds(from: loadStartedAt, to: loadEndedAt)
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-load", loadInterval)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.error(
                "Parakeet load failed — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public) error=\(summary, privacy: .public)"
            )
            log.error(
                "Parakeet prepare failed — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
            )
            throw TranscriptionError.loadFailed(summary)
        }
    }

    private static func modelDirectory(repoFolder: String) -> URL {
        let root: URL
        do {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            fatalError("Application Support is unavailable: \(error)")
        }
        return root
            .appendingPathComponent("Jot/Models/Parakeet", isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
    }

    // MARK: - Audio file decode + resample
    //
    // Runs synchronously on whatever context calls `transcribe(audioFileURL:)`.
    // Shortcut recordings are short (~30–60 s); decoding + 16 kHz resample is
    // well under 100 ms on recent silicon — cheaper than dispatching a detached
    // task and cheaper than the model inference itself. Kept static + pure so
    // it's trivially testable and has no implicit MainActor dependency.

    private static func loadAndResample(
        url: URL,
        targetSampleRate: Double,
        log: Logger
    ) throws -> [Float] {
        log.info("loadAndResample — opening AVAudioFile at \(url.lastPathComponent, privacy: .public)")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            let ext = url.pathExtension.isEmpty ? "(none)" : url.pathExtension
            let summary = "AVAudioFile(forReading:) failed for '\(url.lastPathComponent)' [.\(ext)]: \(error.localizedDescription)"
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileUnreadable(summary)
        }

        // `processingFormat` is always Float32, deinterleaved — the canonical
        // shape `AVAudioConverter` is designed to bridge to our 16 kHz mono
        // target. Source channel count can be anything; the converter handles
        // mixdown.
        let sourceFormat = file.processingFormat
        log.info(
            "loadAndResample — source format: \(Int(sourceFormat.sampleRate), privacy: .public)Hz / \(sourceFormat.channelCount, privacy: .public)ch / \(String(describing: sourceFormat.commonFormat), privacy: .public), fileLength=\(file.length, privacy: .public) frames"
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            let summary = "Could not construct 16 kHz mono Float32 target format."
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileConversionFailed(summary)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            let summary = "No converter available for source \(Int(sourceFormat.sampleRate))Hz/\(sourceFormat.channelCount)ch → 16kHz/1ch."
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileConversionFailed(summary)
        }

        let totalFrames = file.length
        let readCapacity: AVAudioFrameCount = 8192
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimatedOutCount = Int(Double(totalFrames) * ratio) + 1024

        var accumulated: [Float] = []
        accumulated.reserveCapacity(estimatedOutCount)

        while file.framePosition < totalFrames {
            let remaining = totalFrames - file.framePosition
            let thisRead = AVAudioFrameCount(min(Int64(readCapacity), remaining))

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: thisRead) else {
                throw TranscriptionError.audioFileConversionFailed("Could not allocate input buffer.")
            }

            do {
                try file.read(into: inputBuffer, frameCount: thisRead)
            } catch {
                throw TranscriptionError.audioFileConversionFailed("Read error: \(error.localizedDescription)")
            }

            let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw TranscriptionError.audioFileConversionFailed("Could not allocate output buffer.")
            }

            // One-shot input: feed `inputBuffer` on the first input-block call,
            // signal `.noDataNow` on the second so the converter drains its
            // internal ring. The input block is `@Sendable` — capturing a
            // mutable `var` or an `UnsafeMutablePointer<Bool>` both fail the
            // Swift 6 strict-concurrency Sendable check (the latter per
            // SE-0414: pointer values are deliberately non-Sendable so the
            // checker isn't trivially defeated). We use a reference-type
            // `@unchecked Sendable` latch guarded by an `NSLock` — same
            // pattern as `TapOnceGate` in `RecordingService.swift`. The lock
            // is defense-in-depth; in practice `convert` invokes the block
            // synchronously on this thread so there is no real contention.
            let gate = OneShotInputGate()
            var err: NSError?
            let status = converter.convert(to: outputBuffer, error: &err) { _, inputStatus in
                if gate.fireOnce() {
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                inputStatus.pointee = .noDataNow
                return nil
            }

            switch status {
            case .error:
                throw TranscriptionError.audioFileConversionFailed(err?.localizedDescription ?? "unknown converter error")
            case .haveData, .inputRanDry, .endOfStream:
                break
            @unknown default:
                break
            }

            guard let channelData = outputBuffer.floatChannelData else { continue }
            let frames = Int(outputBuffer.frameLength)
            guard frames > 0 else { continue }
            accumulated.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        log.info(
            "Decoded audio file — \(accumulated.count, privacy: .public) samples at \(Int(targetSampleRate))Hz from \(Int(sourceFormat.sampleRate))Hz/\(sourceFormat.channelCount)ch"
        )
        return accumulated
    }

    // MARK: - Memory pressure (best-practices §3.5)

    private func subscribeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    private func handleMemoryWarning() {
        guard !isTranscribing else {
            log.notice("Memory warning received mid-inference — deferring model eviction")
            return
        }
        guard manager != nil else { return }
        log.notice("Memory warning — evicting Parakeet (~1.25 GB) to avoid jetsam")
        manager = nil
        prepareTask = nil
        modelState = .notLoaded
    }

    // MARK: - Sample-rate constant
    //
    // 16 kHz mirrors `RecordingService.sampleRate`. Kept as a separate constant
    // so this file doesn't reach across the layer boundary for a trivial literal.

    private static let sampleRate: Double = 16_000

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) * 1_000
    }

    private static func audioDurationSeconds(sampleCount: Int) -> Double {
        Double(sampleCount) / sampleRate
    }

    private static func realTimeFactor(elapsedMS: Double, audioDurationSeconds: Double) -> Double {
        guard audioDurationSeconds > 0 else { return 0 }
        return (elapsedMS / 1_000) / audioDurationSeconds
    }

    private static func describe(_ state: ModelState) -> String {
        switch state {
        case .notLoaded:
            return "notLoaded"
        case .downloading(let progress):
            return "downloading(\(progress))"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed(let summary):
            return "failed(\(summary))"
        }
    }
}

// MARK: - Error bridging for Shortcuts / NSError consumers
//
// Shortcuts reports thrown intent errors by rendering the bridged NSError.
// Without explicit conformances, iOS displays a useless string like
// "Jot.TranscriptionService.TranscriptionError error 2" — the typed case
// information is lost.
//
// `CustomNSError` locks the error domain + numeric codes so external tooling
// (unified log predicates, screenshots, user-reported bug IDs) has a stable
// contract. Codes match Swift's default enum-ordinal bridging at the time of
// writing so historical "error N" reports stay interpretable.
//
// `CustomLocalizedStringResourceConvertible` is the AppIntents-era hook: when
// an intent throws, Shortcuts reads this resource instead of the bridged
// localizedDescription. `LocalizedError.errorDescription` also stays
// implemented as a fallback for non-AppIntents callers (e.g., main-app UI
// alerts surfacing a transcription failure).

extension TranscriptionService.TranscriptionError: CustomNSError {
    /// Public error domain. Treat as API — logs / screenshots / bug reports
    /// reference it. Renames require migration.
    public static var errorDomain: String { "Jot.TranscriptionService.TranscriptionError" }

    /// Stable numeric codes. Table is the public contract; do NOT renumber.
    /// - 0: `busy`
    /// - 1: `audioTooShort`
    /// - 2: `loadFailed`
    /// - 3: `inferenceFailed`
    /// - 4: `audioFileUnreadable`
    /// - 5: `audioFileConversionFailed`
    public var errorCode: Int {
        switch self {
        case .busy: return 0
        case .audioTooShort: return 1
        case .loadFailed: return 2
        case .inferenceFailed: return 3
        case .audioFileUnreadable: return 4
        case .audioFileConversionFailed: return 5
        }
    }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "Transcription error."]
    }
}

extension TranscriptionService.TranscriptionError: CustomLocalizedStringResourceConvertible {
    /// Rendered by Shortcuts / AppIntents surfaces when an intent's
    /// `perform()` throws. Keep strings user-facing and actionable — the
    /// recipient is someone looking at an opaque Shortcut failure banner.
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .busy:
            return "Jot is already transcribing. Wait for the current transcription to finish, then try again."
        case .audioTooShort:
            return "Recording is under one second. Parakeet needs at least 1 second of audio."
        case .loadFailed(let summary):
            return "Model not ready: \(summary)"
        case .inferenceFailed(let summary):
            return "Transcription failed: \(summary)"
        case .audioFileUnreadable(let summary):
            return "Could not read the audio file: \(summary)"
        case .audioFileConversionFailed(let summary):
            return "Could not decode the audio to 16 kHz mono: \(summary)"
        }
    }
}

/// Single-fire gate for `AVAudioConverter.convert`'s `@Sendable` input
/// block. Returns `true` on the first call, `false` on every subsequent
/// call — lets us hand the converter one buffer per `convert` invocation
/// without capturing a mutable `var` or a non-`Sendable` pointer (both of
/// which fail Swift 6 strict-concurrency Sendable checks).
///
/// `@unchecked Sendable` with `NSLock`: mirrors `TapOnceGate` in
/// `RecordingService.swift`. Kept file-private; hoisting to a shared
/// concurrency-helpers module is a follow-up cross-lane change.
private final class OneShotInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
