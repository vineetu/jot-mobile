@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import UIKit
import os.log

/// Process-wide owner of the FluidAudio `StreamingEouAsrManager` (Parakeet
/// EOU 120M @ 320ms) used to drive the live partial-transcript preview
/// during recording. Mirrors the singleton + warm-up + memory-warning shape
/// of `TranscriptionService.shared`.
///
/// ## Two callers
///
/// 1. `JotApp` — eager warm-up alongside the batch model on first scene
///    activation, gated on (a) setup completed and (b) models on disk
///    (per Guideline 4.2.3(ii) — no silent first-run downloads).
/// 2. `RecordingService.start()` / `stop()` — per-recording session
///    management. `start()` calls `beginSession(presenter:)` to mint a
///    fresh streaming engine + session UUID; `stop()` calls
///    `endSession(engine:)` to fully release CoreML weights per the
///    lifecycle policy below.
///
/// ## Lifecycle policy (per team-lead Rule 3 + spec §2.1 budget)
///
/// **Cleanup-on-every-stop, lazy-load-on-every-start.** On stop the
/// FluidAudio manager is fully released via `cleanup()` (per
/// `StreamingEouAsrManager.swift:428-440` — every CoreML reference + cache
/// nil-ed). On next `RecordingService.start()` a fresh manager is
/// instantiated and loaded from disk-cached weights (~200-500ms). Trade-off
/// accepted: that ~200-500ms hits the cold-start path of the next recording.
/// Without it, the ~66 MB EOU working memory would stay resident through
/// the prior pipeline's BATCH inference (~800 MB peak), pushing the in-app
/// peak from ~950 MB to ~1020 MB — over the 8GB iPhone 17 base's safe
/// margin per spec §2.1.
///
/// Spec §2.1 recommends `streamingManager.cleanup()` on stop by name and
/// quotes the budget math: *"If we explicitly free EOU before batch
/// inference (via `streamingManager.cleanup()` on stop): ~800 MB Parakeet
/// peak + ~150 MB other = ~950 MB."* Adjudicated by team-lead (Rule 3).
///
/// **Memory warning** (`UIApplication.didReceiveMemoryWarningNotification`):
/// no service-level manager exists between sessions, so the hook is mostly
/// a no-op (cancels in-flight prepareTask, clears session UUID). Mid-session
/// manager eviction is the recorder's responsibility — it owns the engine
/// reference for the active session.
///
/// **`warmUp()` is `ensureWeightsOnDisk` — NOT load-into-RAM.** It downloads
/// the EOU 320ms weights to FluidAudio's cache directory if absent.
/// `modelState` transitions: `.notLoaded → .downloading(0..1) → .ready`
/// where `.ready` means "weights cached on disk", NOT "manager loaded
/// into ANE."
///
/// ## warmUp() vs beginSession() vs endSession()
///
/// - `warmUp()` (called by `JotApp.task` + `SetupWizardView`): downloads
///   weights to disk if absent. Disk-only; no ANE load. Idempotent +
///   coalescing.
/// - `beginSession(presenter:)` (called by `RecordingService.start()`):
///   instantiates a NEW `StreamingEouAsrManager`, calls `loadModels()`
///   (~200-500ms ANE load from disk-cached weights), constructs an engine
///   actor, registers the partial callback. Returns engine + queue.
/// - `endSession(engine:)` (called by `RecordingService.stop()` AFTER the
///   drain task ends and `engine.finish()` runs): calls `engine.cleanup()`
///   which calls `manager.cleanup()` — full release. Recorder drops the
///   engine reference. Next session re-instantiates from scratch.
///
/// ## Why per-session UUID lives here, not on `RecordingService`
///
/// `RecordingService.currentSessionID` is the dictation pipeline UUID
/// shared cross-process with the keyboard via `PendingPasteSession.id`
/// (auto-paste-v7 territory). The streaming session UUID is a separate
/// concept — it gates partial-transcript callbacks against late MainActor-
/// queued tasks per the prototype rounds-3-4 fix. The two never need to
/// be equal; conflating them would couple unrelated invariants.
@MainActor
@Observable
final class StreamingTranscriptionService {
    enum ModelState: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    /// Process-wide singleton.
    @MainActor static let shared = StreamingTranscriptionService()

    private(set) var modelState: ModelState = .notLoaded

    /// Active streaming session token. Minted by `beginSession(...)` per
    /// recording, cleared BEFORE `manager.finish()` per the prototype's
    /// session-token-clearing-before-finish ordering. Read by the partial-
    /// transcript callback registered on the FluidAudio manager — late
    /// callbacks compare against this and no-op if mismatched.
    private(set) var currentStreamingSessionID: UUID?

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "streaming-transcription"
    )

    /// In-flight `ensureWeightsOnDisk()` task, or nil if no warm-up is
    /// running. Coalescing: concurrent `warmUp()` calls share one task.
    /// Cleared on completion or cancellation. We do NOT cache a loaded
    /// `StreamingEouAsrManager` here — per the lifecycle policy at the top
    /// of this file (team-lead Rule 3), a fresh manager is instantiated
    /// per `beginSession(...)` and fully released on `endSession(engine:)`.
    private var prepareTask: Task<Void, Error>?
    private var prepareGeneration = 0

    /// `deinit` is always nonisolated in Swift 6, so it can't touch
    /// @MainActor state. Same exemption pattern as
    /// `TranscriptionService.memoryWarningObserver` — single-write from
    /// init (MainActor), single-read from deinit, never concurrent.
    /// `NotificationCenter.removeObserver` is itself thread-safe.
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

    // MARK: - Warm-up

    /// Ensure EOU 320ms model weights are present on disk. Does NOT load
    /// them into RAM — actual ANE load happens lazily on each
    /// `beginSession(...)` call per the lifecycle policy at the top of this
    /// file. Idempotent + coalescing.
    ///
    /// Transitions `modelState`: `.notLoaded → .downloading(0..1) → .ready`
    /// once weights are on disk. `.ready` here means "weights cached",
    /// NOT "manager loaded into ANE".
    ///
    /// Call sites:
    /// - `JotApp.task` (first scene activation), gated on setup completed
    ///   AND models on disk (no silent first-run download per Apple
    ///   Guideline 4.2.3(ii)).
    /// - `SetupWizardView.startModelDownload()` alongside
    ///   `transcriptionService.warmUp()`. Both downloads happen under the
    ///   single explicit-tap consent for the bundled ~948 MB.
    func warmUp() {
        log.info("Streaming warmUp requested — modelState=\(Self.describe(self.modelState), privacy: .public)")
        _ = ensurePreparing()
    }

    /// Discard cached weights and re-download. Dev/QA path; mirrors
    /// `TranscriptionService.purgeAndReload()`. Safe to call between
    /// recordings; if a session is in flight when this runs, the in-flight
    /// engine's manager is unaffected (it owns its own loaded MLModel
    /// references) but the next `beginSession(...)` will need to re-download.
    func purgeAndReload() async {
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1

        let modelDir = Self.modelDirectory()
        if FileManager.default.fileExists(atPath: modelDir.path) {
            do {
                try FileManager.default.removeItem(at: modelDir)
                log.notice("Removed streaming model cache at \(modelDir.path, privacy: .public)")
            } catch {
                let summary = "Could not remove streaming model cache: \(error.localizedDescription)"
                modelState = .failed(summary)
                log.error("\(summary, privacy: .public)")
                return
            }
        }

        modelState = .notLoaded
        warmUp()
    }

    /// Cancel any in-flight warm-up. Counterpart to
    /// `TranscriptionService.cancelBackgroundWarm()`.
    func cancelBackgroundWarm() {
        guard self.modelState != .ready else { return }
        log.notice(
            "Streaming warm cancellation requested — modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1
        modelState = .notLoaded
    }

    // MARK: - Per-session API for RecordingService

    /// Mint a fresh streaming session: instantiate a NEW
    /// `StreamingEouAsrManager`, load its weights from disk into ANE
    /// (~200-500ms), allocate a session UUID, construct the engine actor
    /// against the caller-supplied queue, register the partial-callback.
    /// Returns the engine.
    ///
    /// Returns `nil` if weights aren't on disk or the load fails — caller
    /// (RecordingService) proceeds with batch-only, live preview stays
    /// empty for that session. Live preview is a UX nicety per spec §3.6;
    /// failing it must not interrupt the user's dictation.
    ///
    /// Per the lifecycle policy at the top of this file (team-lead Rule 3):
    /// a fresh manager is instantiated and loaded EVERY session. The prior
    /// session's manager has been fully released via `cleanup()` in
    /// `endSession(...)`.
    ///
    /// **Queue ownership:** the caller (RecordingService) owns the queue
    /// because the audio-tap closure must capture it synchronously and push
    /// without crossing an actor boundary. The caller pre-allocates the
    /// queue, passes it to `installTap` BEFORE engine.start() so the tap's
    /// first callback already has a queue to push to, then passes the same
    /// queue to this method to construct the engine. Mirrors prototype
    /// `DualRecorder.swift:152-167` where `streamingQueue` is recorder-owned.
    ///
    /// Caller-side responsibilities:
    /// 1. Spawn `Task.detached(priority: .userInitiated)` running
    ///    `await engine.drain()`. NEVER call `drain()` from the audio
    ///    render thread.
    /// 2. From the audio tap, push `[Float]` chunks via `queue.push(_:)`.
    /// 3. On stop:
    ///    - `queue.endOfStream()` → `await drainTask.value`
    ///    - `streamingService.clearSessionTokenBeforeFinish(presenter:)`
    ///    - `await engine.finish()` (writes final via `applyFinalSnapshot`)
    ///    - `await streamingService.endSession(engine:)` (full cleanup;
    ///      recorder drops engine ref)
    func beginSession(
        presenter: StreamingPartial,
        queue: StreamingBufferQueue
    ) async -> StreamingTranscriptionEngine? {
        guard Self.modelsExistOnDisk() else {
            log.notice("beginSession skipped — EOU weights not on disk")
            return nil
        }

        let manager = StreamingModelVariant.parakeetEou320ms.createManager()

        do {
            // Disk weights are already cached (gated on the
            // modelsExistOnDisk check above), so `loadModels()` is the
            // ~200-500ms ANE load only — no download.
            try await manager.loadModels()
        } catch {
            log.error("beginSession loadModels failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let sessionID = presenter.beginSession()
        currentStreamingSessionID = sessionID

        let engine = StreamingTranscriptionEngine(
            manager: manager,
            queue: queue,
            presenter: presenter,
            sessionID: sessionID
        )
        await engine.installPartialCallback()

        log.info("Streaming session begun — sessionID=\(sessionID, privacy: .public)")
        return engine
    }

    /// Tear down the supplied engine's manager fully (CoreML refs nil-ed
    /// per `StreamingEouAsrManager.swift:428-440`) and clear the service's
    /// session UUID. Per-stop API; called by `RecordingService.stop()`
    /// AFTER the drain task has completed AND AFTER `engine.finish()` has
    /// applied the final streaming snapshot.
    ///
    /// Order recap (mirroring `DualRecorder.swift:271-291`):
    /// 1. `queue.endOfStream()` (recorder owns the queue)
    /// 2. `await drainTask.value`
    /// 3. `streamingService.clearSessionTokenBeforeFinish(presenter:)`
    /// 4. `await engine.finish()` (writes final via `applyFinalSnapshot`,
    ///    bypassing the cleared session-token guard)
    /// 5. `await streamingService.endSession(engine:)` ← THIS METHOD
    ///    (calls `engine.cleanup()` for full release; recorder drops
    ///    its reference)
    func endSession(engine: StreamingTranscriptionEngine) async {
        await engine.cleanup()
        currentStreamingSessionID = nil
        log.info("Streaming session ended — manager released")
    }

    /// Clears the active session token. Called by `RecordingService.stop()`
    /// BEFORE the engine's `finish()` runs, so any in-flight
    /// `processBufferedAudio` partial-callback emissions arrive after the
    /// token is cleared and no-op via the presenter's session guard.
    func clearSessionTokenBeforeFinish(presenter: StreamingPartial) {
        currentStreamingSessionID = nil
        presenter.clearSession()
    }

    // MARK: - Disk-existence check (for JotApp eager-warm gate)

    /// `true` iff the EOU 320ms model files are already present in
    /// FluidAudio's default cache directory. Mirrors the
    /// `AsrModels.modelsExist(at:version:)` check the batch path uses to
    /// avoid silent first-run downloads (App Review 4.2.3(ii)).
    static func modelsExistOnDisk() -> Bool {
        let modelDir = modelDirectory()
        let required = ModelNames.ParakeetEOU.requiredModels
        return required.allSatisfy { name in
            FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(name).path)
        }
    }

    /// Path to the EOU 320ms model directory.
    ///
    /// Matches `StreamingEouAsrManager.defaultCacheDirectory()` PLUS the
    /// `repo.folderName` append that `loadModels(to:...)` performs internally.
    /// FluidAudio's `defaultCacheDirectory()` already ends in
    /// `parakeet-eou-streaming/`, then `loadModels` appends `repo.folderName`
    /// which itself starts with `parakeet-eou-streaming/` — yielding a
    /// double-nested actual location of:
    ///
    ///     <AppSupport>/FluidAudio/Models/parakeet-eou-streaming/parakeet-eou-streaming/320ms/
    ///
    /// We previously used `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetEou320)`
    /// which produces only the single-nested form, so `modelsExistOnDisk()`
    /// always returned false even after a successful download — `beginSession`
    /// then short-circuited, the streaming preview never started, and the
    /// keyboard / in-app captions stayed empty.
    ///
    /// Verified against `StreamingEouAsrManager.swift:284-318` (FluidAudio
    /// 0.13.6).
    private static func modelDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return
            appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("320ms", isDirectory: true)
    }

    // MARK: - Prepare core (mirrors TranscriptionService shape)

    private func ensurePreparing() -> Task<Void, Error> {
        if let prepareTask {
            return prepareTask
        }
        let generation = prepareGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.loadOrFail(generation: generation)
        }
        prepareTask = task
        return task
    }

    private func loadOrFail(generation: Int) async throws {
        #if targetEnvironment(simulator)
        // Match the batch path's simulator behavior — skip the actual model
        // load on simulator builds. The streaming preview gracefully
        // degrades to empty text on simulator runs; integration tests of
        // the audio + drain pipeline are validated on-device.
        try checkPrepareGeneration(generation)
        modelState = .ready
        log.info("Streaming load bypassed on simulator")
        return
        #else
        if Self.modelsExistOnDisk() {
            modelState = .ready
            log.info("Streaming weights already on disk — modelState=ready")
            return
        }

        try checkPrepareGeneration(generation)

        modelState = .downloading(0)

        do {
            // Throwaway primer instance to drive the download via the
            // protocol's parameterless `loadModels()`. Downloads weights to
            // the default cache dir if absent, then loads them into ANE.
            // We discard the loaded manager immediately via `cleanup()` so
            // we don't carry ~66 MB of working memory between warmUp and
            // the first beginSession (per team-lead Rule 3 cleanup-on-stop
            // policy — no service-level warm manager).
            let primer = StreamingModelVariant.parakeetEou320ms.createManager()
            try await primer.loadModels()
            await primer.cleanup()

            try checkPrepareGeneration(generation)
            modelState = .ready
            log.info("Streaming weights ensured on disk")
        } catch is CancellationError {
            if prepareGeneration == generation {
                prepareTask = nil
                if !Self.modelsExistOnDisk() {
                    modelState = .notLoaded
                }
            }
            log.notice("Streaming load cancelled")
            throw CancellationError()
        } catch {
            guard prepareGeneration == generation, !Task.isCancelled else {
                if prepareGeneration == generation {
                    prepareTask = nil
                    if !Self.modelsExistOnDisk() {
                        modelState = .notLoaded
                    }
                }
                throw CancellationError()
            }
            let summary = "Streaming load failed: \(error.localizedDescription)"
            modelState = .failed(summary)
            prepareTask = nil
            log.error("\(summary, privacy: .public)")
            throw error
        }
        #endif
    }

    private func checkPrepareGeneration(_ generation: Int) throws {
        guard prepareGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    // MARK: - Memory pressure (per spec §3.6: evict streaming FIRST)

    private func subscribeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleMemoryWarning()
            }
        }
    }

    /// Memory-warning hook. Per spec §3.6: streaming model evicts FIRST,
    /// before the batch model.
    ///
    /// In this service's lifecycle (cleanup-on-every-stop per team-lead
    /// Rule 3, see header doc), no manager is held between sessions —
    /// there's nothing to nuke at the service level. What we do:
    /// 1. Cancel any in-flight `prepareTask` (download work).
    /// 2. Clear `currentStreamingSessionID` so any in-flight partial-
    ///    callback emissions from a session-in-progress arrive after the
    ///    token is cleared and no-op via the presenter's session guard.
    /// 3. Reset `modelState` to `.notLoaded` if disk weights have been
    ///    evicted by the system (rare — Application Support is sticky).
    ///
    /// Mid-session manager eviction is the recorder's responsibility — it
    /// owns the engine reference for the active session, and a memory
    /// warning that fires mid-session typically arrives moments before
    /// iOS interrupts the audio session anyway. The recorder's existing
    /// teardown path calls `endSession(engine:)` which calls
    /// `engine.cleanup()` → `manager.cleanup()`.
    private func handleMemoryWarning() async {
        log.notice("Memory warning — clearing streaming session token + cancelling prepare task")
        prepareTask?.cancel()
        prepareTask = nil
        currentStreamingSessionID = nil
        if !Self.modelsExistOnDisk() {
            modelState = .notLoaded
        }
    }

    // MARK: - Helpers

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
