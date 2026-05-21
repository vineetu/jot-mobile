@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import UIKit
import os.log

/// Process-wide owner of the FluidAudio `StreamingEouAsrManager`
/// (Parakeet EOU 120M @ 320ms) used to drive the live partial-
/// transcript preview during recording. Mirrors the singleton +
/// warm-up + memory-warning shape of `TranscriptionService.shared`.
///
/// ## Two callers
///
/// 1. `JotApp` — eager weights-on-disk check alongside the batch model on
///    first scene activation, gated on (a) setup completed and (b) models
///    on disk (per Guideline 4.2.3(ii) — no silent first-run downloads).
/// 2. `RecordingService.start()` / `stop()` — per-recording session
///    management. `start()` calls `beginSession(presenter:queue:)` to mint
///    a fresh streaming engine + session UUID; `stop()` calls
///    `endSession(engine:)` to fully release CoreML weights per the
///    lifecycle policy below.
///
/// ## Lifecycle policy (cleanup-on-every-stop)
///
/// **Cleanup-on-every-stop, lazy-load-on-every-start.** On stop the
/// FluidAudio manager is fully released via `cleanup()` (per
/// `StreamingEouAsrManager.swift:428-440` — every CoreML reference + cache
/// nil-ed). On next `RecordingService.start()` a fresh manager is
/// instantiated and loaded from disk-cached weights (~200-500ms). The
/// previous "keep-warm" lifecycle (cache the manager across stops) was
/// reverted earlier after on-device testing showed it regressed
/// reliability on the heavier streaming graph that has since been
/// retired. Per-session load is the reliable shape.
///
/// **Memory warning** (`UIApplication.didReceiveMemoryWarningNotification`):
/// no service-level manager exists between sessions, so the hook is mostly
/// a no-op (cancels in-flight prepareTask, clears session UUID). Mid-session
/// manager eviction is the recorder's responsibility — it owns the engine
/// reference for the active session.
///
/// **`warmUp()` is `ensureWeightsOnDisk` — NOT load-into-RAM.** The EOU
/// 320ms weights ship bundled inside the IPA, so `warmUp()` is a presence
/// check; the `.downloading` model state is no longer reachable from this
/// path. `modelState` transitions: `.notLoaded → .ready` once the
/// bundled resources resolve. `.ready` here means "weights cached on
/// disk", NOT "manager loaded into ANE."
///
/// ## warmUp() vs beginSession() vs endSession()
///
/// - `warmUp()` (called by `JotApp.task` + `SetupWizardView`): confirms
///   weights are visible on disk. Disk-only; no ANE load. Idempotent +
///   coalescing.
/// - `beginSession(presenter:queue:)` (called by `RecordingService.start()`):
///   instantiates a NEW `StreamingEouAsrManager`, calls `loadModels(from:)`
///   (~200-500ms ANE load from disk-cached weights), allocates a session
///   UUID, constructs an engine actor, registers the partial callback.
///   Returns the engine.
/// - `endSession(engine:)` (called by `RecordingService.stop()` AFTER the
///   drain task ends and `engine.finish()` runs): calls `engine.cleanup()`
///   which calls `manager.cleanup()` — full release. Recorder drops its
///   reference. Next session re-instantiates from scratch.
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

    /// In-session ANE load state for the streaming manager. Distinct from
    /// `modelState` (which tracks disk readiness): `sessionLoadState`
    /// tracks the per-`beginSession(...)` `loadModels(from:)` window.
    /// Goes `.idle → .loading` at the top of `beginSession`, `.loading
    /// → .ready` once `loadModels` returns, and back to `.idle` on
    /// `endSession` or any failure path. The Hero overlay and keyboard
    /// strip render their "Loading [variant]…" placeholder while this
    /// is `.loading`. Variant label is resolved at render time from
    /// `SpeechModelVariant.current()` — the variant cannot change mid-
    /// session, so a snapshot here would be redundant.
    enum SessionLoadState: Equatable, Sendable {
        case idle
        case loading
        case ready
    }

    /// Process-wide singleton.
    @MainActor static let shared = StreamingTranscriptionService()

    private(set) var modelState: ModelState = .notLoaded

    /// Per-session ANE-load state. See `SessionLoadState` doc above.
    /// Mirrored to AppGroup (`streamingLoadingVariantLabel`, holding
    /// the variant displayName while loading and empty otherwise) +
    /// posted via Darwin (`streamingLoadingChanged`) on every
    /// transition so the keyboard extension can render the same
    /// loading placeholder without linking `SpeechModelVariant`.
    private(set) var sessionLoadState: SessionLoadState = .idle {
        didSet {
            guard oldValue != sessionLoadState else { return }
            AppGroup.streamingLoadingVariantLabel = (sessionLoadState == .loading)
                ? SpeechModelVariant.current().displayName
                : ""
            CrossProcessNotification.post(name: CrossProcessNotification.streamingLoadingChanged)
        }
    }

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
    /// `StreamingEouAsrManager` here — per the lifecycle policy at the
    /// top of this file, a fresh manager is instantiated per
    /// `beginSession(...)` and fully released on `endSession(engine:)`.
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

    /// Confirm bundled EOU 320ms model weights are visible to FluidAudio.
    /// Does NOT load them into RAM — actual ANE load happens lazily on
    /// each `beginSession(...)` call per the lifecycle policy at the top
    /// of this file. Idempotent + coalescing.
    ///
    /// Transitions `modelState`: `.notLoaded → .ready` once the bundled
    /// resources resolve. `.ready` here means "weights present on disk",
    /// NOT "manager loaded into ANE".
    ///
    /// Pre-bundling this used to drive an HF download via
    /// `loadModelsFromHuggingFace`. Now that the EOU bundle ships in the
    /// IPA, `warmUp()` is effectively a presence check; the `.downloading`
    /// state is no longer reachable from this path.
    ///
    /// Call site:
    /// - `JotApp.task` (first scene activation), gated on setup completed.
    ///   No first-launch network activity (App Review 4.2.3(ii)).
    func warmUp() {
        log.info("Streaming warmUp requested — modelState=\(Self.describe(self.modelState), privacy: .public)")
        _ = ensurePreparing()
    }

    /// Called when the user flips Settings → Speech model variant.
    /// Re-primes `modelState` from the new variant's disk presence so
    /// the picker's status row updates immediately, and cancels any
    /// in-flight prepare task so the next `warmUp()` re-evaluates
    /// against the new variant.
    ///
    /// Cleanup-on-every-stop regime: no warm streaming manager exists
    /// between sessions, so there's nothing to evict at this boundary.
    /// The next `beginSession` will cold-load the new variant.
    func handleVariantChange() {
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1

        if Self.modelsExistOnDisk() {
            modelState = .ready
        } else {
            modelState = .notLoaded
        }
        log.info(
            "Streaming variant changed — variant=\(AppGroup.speechModelVariant, privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
    }

    /// Dev/QA path retained for symmetry with `TranscriptionService.purgeAndReload()`.
    /// The streaming EOU weights now ship inside the IPA — the bundle is
    /// read-only, so there's nothing to remove. We cancel any in-flight
    /// prepare task and re-prime `modelState` from the bundle's presence
    /// (effectively a no-op refresh).
    func purgeAndReload() async {
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1

        log.notice("purgeAndReload no-op — streaming weights are bundled and read-only")
        modelState = .notLoaded
        warmUp()
    }

    // MARK: - Per-session API for RecordingService

    /// Mint a fresh streaming session: instantiate a NEW
    /// `StreamingEouAsrManager`, load its weights from disk into ANE
    /// (~200-500ms), allocate a session UUID, construct the engine
    /// actor against the caller-supplied queue, register the partial
    /// callback. Returns the engine.
    ///
    /// Returns `nil` if weights aren't on disk or the load fails — caller
    /// (RecordingService) proceeds with batch-only, live preview stays
    /// empty for that session. Live preview is a UX nicety per spec §3.6;
    /// failing it must not interrupt the user's dictation.
    ///
    /// Per the lifecycle policy at the top of this file: a fresh manager
    /// is instantiated and loaded EVERY session. The prior session's
    /// manager has been fully released via `cleanup()` in `endSession(...)`.
    /// Transitions `sessionLoadState` `.idle → .loading → .ready` so
    /// the recording hero's overlay can render during the in-session load.
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
    ///    - `await engine.finish()`
    ///    - `await streamingService.endSession(engine:)`
    func beginSession(
        presenter: StreamingPartial,
        queue: StreamingBufferQueue
    ) async -> StreamingTranscriptionEngine? {
        guard let modelDir = Self.bundledStreamingDirectory(),
              Self.modelsExistOnDisk(at: modelDir) else {
            log.notice("beginSession skipped — bundled EOU weights not found in app bundle")
            sessionLoadState = .idle
            return nil
        }

        sessionLoadState = .loading

        // Construct the concrete EOU manager so we can call
        // `loadModels(from:)` directly against the bundled directory.
        // The protocol's parameterless `loadModels()` would route through
        // `loadModelsFromHuggingFace` and attempt a download into
        // Application Support — bypassing the bundle and re-introducing
        // the first-launch HF Hub dependency this whole change exists to
        // eliminate.
        let manager = StreamingEouAsrManager(
            configuration: MLModelConfiguration(),
            chunkSize: .ms320
        )

        do {
            // Bundle weights are present (gated above); this is the
            // ~200-500ms ANE load only — no download, no HF Hub touch.
            try await manager.loadModels(from: modelDir)
        } catch {
            log.error("beginSession loadModels failed — \(error.localizedDescription, privacy: .public)")
            sessionLoadState = .idle
            return nil
        }

        sessionLoadState = .ready

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
    /// 5. `await streamingService.endSession(engine:)`
    ///    ← THIS METHOD (calls `engine.cleanup()` for full release;
    ///    recorder drops its reference)
    func endSession(engine: StreamingTranscriptionEngine) async {
        // Cleanup-on-every-stop: fully release the manager's CoreML
        // graphs back to the system. Next session re-instantiates from
        // scratch.
        await engine.cleanup()
        currentStreamingSessionID = nil
        sessionLoadState = .idle
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

    /// `true` iff the bundled streaming weights are present on disk.
    /// The EOU 320ms model ships inside the IPA, so this is
    /// constant-true on healthy installs.
    static func modelsExistOnDisk() -> Bool {
        guard let dir = bundledStreamingDirectory() else { return false }
        return modelsExistOnDisk(at: dir)
    }

    /// Per-directory variant used by `beginSession`. Verifies every file
    /// in `ModelNames.ParakeetEOU.requiredModels` resolves under the
    /// supplied directory.
    static func modelsExistOnDisk(at directory: URL) -> Bool {
        let required = ModelNames.ParakeetEOU.requiredModels
        return required.allSatisfy { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    /// `<Bundle>/Models/Parakeet/parakeet-eou-streaming/320ms/` if present.
    /// Composed directly from `Bundle.main.bundleURL` — see the note on
    /// `TranscriptionService.bundledTdtCtc110mDirectory` for why we
    /// don't use `Bundle.main.url(forResource:...)`. FluidAudio's
    /// `StreamingEouAsrManager.loadModels(from:)` reads
    /// `streaming_encoder.mlmodelc`, `decoder.mlmodelc`,
    /// `joint_decision.mlmodelc`, and `vocab.json` relative to this URL.
    static func bundledStreamingDirectory() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("320ms", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        // EOU weights are bundled into the IPA under
        // `Resources/Models/Parakeet/parakeet-eou-streaming/320ms/`,
        // so the "ensure weights on disk" step collapses to a presence
        // check — no auto-download is attempted from this warm-up path.
        if Self.modelsExistOnDisk() {
            try checkPrepareGeneration(generation)
            modelState = .ready
            log.info("Streaming weights resolved — modelState=ready")
            return
        }

        // Defensive: bundle resources missing (stripped IPA / dev-build
        // misconfiguration). Surface as a failed state so Settings can
        // show a meaningful error instead of silently sitting on
        // `.notLoaded` forever.
        let summary = "Streaming model not found in app bundle. Reinstall Jot."
        modelState = .failed(summary)
        prepareTask = nil
        log.error("\(summary, privacy: .public)")
        throw NSError(
            domain: "com.vineetu.jot.mobile.Jot.streaming",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: summary]
        )
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
    /// In this service's lifecycle (cleanup-on-every-stop, see header
    /// doc), no manager is held between sessions — there's nothing to
    /// nuke at the service level. What we do:
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
        // Surface the memory-pressure event in the in-app diagnostics card
        // so a user reporting "the app crashed seconds after I tapped stop"
        // can correlate the crash with a jetSam precursor warning. The
        // log is App Group-shared so the keyboard surface that renders
        // diagnostics sees this entry on its next presentation.
        DiagnosticsLog.record(
            source: "main-app",
            category: .memoryWarning,
            message: "streaming service received memory warning",
            metadata: [
                "variant": "\(SpeechModelVariant.current().rawValue)",
                "hasSession": "\(currentStreamingSessionID != nil)",
            ]
        )
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
