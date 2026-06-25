@preconcurrency import AVFoundation
import Foundation
import os.log
import Synchronization

@MainActor
@Observable
final class RecordingService {
    enum RecordingError: LocalizedError {
        case alreadyRunning
        case notRunning
        case converterUnavailable
        case sessionConfiguration(Error)
        case engineStart(Error)
        /// Another app currently holds the mic (active phone call, Siri,
        /// another voice app). We use `.mixWithOthers` so `setActive(true)`
        /// + `engine.start()` both succeed in that state — but
        /// `inputNode.outputFormat(forBus: 0)` reports 0 channels / 0 Hz
        /// and the tap produces silence. Detected pre-tap so we can show
        /// the user a real banner instead of opening the hero with
        /// "Listening…" and capturing nothing.
        case micUnavailable
        /// TRANSIENT (warm-hold audio-yield harness, MF-1): the V1/V4 on-resume
        /// `setCategory` restore threw, so `startFromWarmHold` tore the engine
        /// down and signals `start()` to cold-start instead of resuming a
        /// mis-configured session. Internal control-flow only — never surfaced.
        case warmYieldRestoreFailed

        /// Single source of truth for user-facing copy. EVERY surface (hero
        /// alert, foreground auto-start alert, keyboard banner, Shortcuts /
        /// AppIntents) renders this — `errorDescription` and
        /// `localizedStringResource` both delegate here so the same failure
        /// never reads four different ways depending on where it shows.
        ///
        /// ## No raw CoreAudio text
        ///
        /// The associated `Error` values on `.sessionConfiguration` /
        /// `.engineStart` carry a raw CoreAudio `localizedDescription`
        /// ("The operation couldn't be completed. (com.apple.coreaudio…
        /// error 561145187.)") — historically interpolated straight into the
        /// user's face. We deliberately DROP it here; the diagnostic NSError
        /// domain/code is still logged at the throw site
        /// (`configureSession`'s `setActive` catch, `engine.start()`'s catch),
        /// which is where engineers look. The user gets a plain sentence.
        ///
        /// ## Why no heuristic
        ///
        /// The flagship case is "user is on a call (Teams/Zoom/FaceTime/phone),
        /// taps dictate, another app holds the mic." There is no iOS API to ask
        /// "is the mic free?" — the only signal is that *acquiring* it failed.
        /// So we don't guess (no `isOtherAudioPlaying` sniffing, no CoreAudio
        /// code allowlist): a start-time failure means we couldn't get the mic,
        /// and the overwhelmingly common reason is another app holding it, so we
        /// say that honestly instead of leaking the raw CoreAudio text. (The
        /// full fix also reorders to acquire-then-present so this message only
        /// ever appears when a start genuinely fails — see the mic-availability
        /// plan.)
        var userFacingMessage: String {
            switch self {
            case .micUnavailable:
                return Self.micBusyMessage
            case .sessionConfiguration, .engineStart:
                // Couldn't acquire the mic at start — most commonly another app
                // (a call) holds it. Honest message, never the raw CoreAudio
                // text, and no heuristic guess.
                return Self.micBusyMessage
            case .converterUnavailable:
                return "Couldn't start recording. Restart Jot and try again."
            case .alreadyRunning:
                return "Jot is already recording."
            case .notRunning:
                return "No recording is in progress."
            case .warmYieldRestoreFailed:
                // Never surfaced (internal control-flow only) — a sane string
                // exists only so the property is total.
                return "Couldn't start recording — try again."
            }
        }

        /// The flagship "another app holds the mic" copy. Owner-approved.
        static let micBusyMessage =
            "Microphone is busy — another app (like a call) is using it. Try again when it's free."

        var errorDescription: String? { userFacingMessage }
    }

    /// Process-wide singleton. Both the foreground scene (`JotApp.swift` →
    /// `ContentView`) and the headless intent surface (`DictationControllerImpl`
    /// in `DictateIntent.swift`) MUST read from this one instance.
    ///
    /// ## Why process-wide (not per-surface)
    ///
    /// `AVAudioSession` is a process-global singleton enforced by iOS — there
    /// is exactly one audio session per process, whatever Swift code thinks it
    /// owns. Having two `RecordingService` instances against one session
    /// produces a subtle but real bug: each instance stashes its own
    /// `priorCategory` / `priorMode` / `priorOptions` at `configureSession()`
    /// time for restore-on-stop. If both configure in sequence (e.g. user
    /// records in-app → backgrounds → fires Action Button), the second
    /// instance stashes the ALREADY-MODIFIED session state as its "prior"
    /// and its `restoreSession()` then restores to what the first instance
    /// set, not the true pre-Jot baseline. Session state leaks forward across
    /// dictations.
    ///
    /// Singleton consolidation makes the stash-and-restore pair read and
    /// write the same private slots across every recording call site, so the
    /// "prior" state captured at the start of a record is always the true
    /// baseline — no matter which surface triggered it.
    ///
    /// ## Why pinned `@MainActor`
    ///
    /// `RecordingService` is `@MainActor`-isolated (class-level). Swift 6
    /// strict concurrency requires the static property initializer to match
    /// the actor isolation of the constructed value; the `@MainActor` on
    /// the property itself provides that. Same shape as
    /// `TranscriptionService.shared` — keep them aligned so a future reader
    /// doesn't have to re-derive the reasoning.
    ///
    /// ## What this does NOT force
    ///
    /// Callers that deliberately want a disposable fresh instance (tests,
    /// future SwiftUI previews, one-off capture workflows) are still free to
    /// `RecordingService()`. The singleton is additive, not exclusive.
    @MainActor static let shared = RecordingService()

    private(set) var isRecording: Bool = false
    private(set) var isStopInFlight: Bool = false
    private(set) var isPipelineInFlight: Bool = false
    private(set) var isWarm: Bool = false
    private(set) var warmExpiresAt: Date?

    /// True while a recording is PAUSED (UX-overhaul round 2 §10). Observable
    /// so the hero/keyboard can render a Resume control and a frozen elapsed
    /// clock. Pause is a sub-state of an active recording: `isRecording` stays
    /// `true` the entire time we're paused. Set by `pauseRecording()`, cleared
    /// by `resumeRecording()` and by every terminal teardown path (stop /
    /// cancel / forceStop / internalStop / exitWarmHold).
    private(set) var isPaused: Bool = false

    /// True while an *inline* in-app surface (Ask, Edit, the keyboard-while-in-Jot
    /// receiver) owns the current recording — i.e. it is dictating into a field,
    /// not a targetless hero capture. The home view's hero-adoption guards check
    /// this so they don't snatch an inline recording into a full-screen hero
    /// while the inline surface is mid-teardown (the build-72 leak fix,
    /// generalized for WS-B). Set/cleared by `InlineDictationSession`.
    var ownsActiveRecording: Bool = false

    /// Single source of truth for cross-process pipeline phase. Reads as
    /// `.idle` when no pipeline activity is in flight; transitions through
    /// `.recording → .transcribing → .processing → .cleaning → .publishing`
    /// → `.idle` on success, or → `.failed` on irrecoverable pre-publish
    /// failure. `.failed` is reserved for cases where NO publish is possible
    /// (e.g. `RecordingService.stop` itself throws, or `TranscriptionService`
    /// throws); user cancellation publishes raw and goes to `.idle` (see
    /// `tmp/research-auto-paste-best-design.md` §4.6.B).
    ///
    /// Mutated only via `publishPipelinePhase(_:)` so the App Group projection,
    /// the Darwin notification, and the heartbeat task lifecycle stay in lock-
    /// step with the in-process value.
    private(set) var currentPipelinePhase: PipelinePhaseProjection.Phase = .idle

    /// UUID identifying the current dictation session. Set on transition
    /// AWAY from `.idle` (typically by `adoptSession(_:)` from the URL handler
    /// or recording-start coordinator). Cleared on transition TO `.idle` /
    /// `.failed`. The keyboard matches its `PendingPasteSession.id` against
    /// the published `FreshDictation.sessionID` to disambiguate which in-flight
    /// pipeline's transcript belongs to its tap.
    private(set) var currentSessionID: UUID?

    /// Snapshot of the recording's start time. Carried into the published
    /// `PipelinePhaseProjection.recordingStartedAt` so the keyboard's
    /// elapsed-time UI can render off the single phase projection — the
    /// keyboard's `isRecording` is derived from `phase == .recording`.
    private(set) var currentRecordingStartedAt: Date?

    /// Normalized RMS amplitude (0.0 – 1.0) updated at ~30 Hz while a recording
    /// is active; `nil` when idle. This is the contract the status-pill
    /// waveform reads via `@Environment(RecordingService.self)` so the viz
    /// reflects real mic input instead of a synthetic oscillator.
    ///
    /// Updated from the audio tap via a MainActor hop (`Task { @MainActor … }`);
    /// writes to this property always happen on the MainActor, so Observation's
    /// dirty-tracking stays consistent. Rate-limited upstream by
    /// `AmplitudeGate` — do **not** try to publish per-buffer.
    private(set) var currentAmplitude: Float? = nil

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "recording")

    private var engine: AVAudioEngine?
    private var capture: CaptureContext?
    private var isCapturingSlice: Bool = false
    private var isTapInstalled: Bool = false
    private let tapRouter = AudioTapRouter()
    private var warmCooldownTask: Task<Void, Never>?
    /// Repeating task that refreshes `AppGroup.warmHoldHeartbeat` every
    /// ~1s while warm-hold is active. The keyboard treats a stale
    /// heartbeat (>2.5s old) as proof the main app was jetsammed and
    /// falls back to the URL bounce instead of posting a Darwin
    /// notification to a dead listener.
    private var warmHeartbeatTask: Task<Void, Never>?
    private var pendingWarmHoldPublish: Bool = false
    // Array rather than Set because `NSObjectProtocol` isn't Hashable.
    // We only ever iterate to remove — semantics are identical.
    private var observers: [NSObjectProtocol] = []

    // Saved session state so we don't steal config from other apps on stop.
    private var priorCategory: AVAudioSession.Category?
    private var priorMode: AVAudioSession.Mode?
    private var priorOptions: AVAudioSession.CategoryOptions?

    // MARK: - Streaming preview (batch pseudo-streaming)
    //
    // Per-recording sample queue feeding the live partial-transcript preview.
    // Allocated in `start()`; the tap closure pushes audio into it and the
    // `PreviewScheduler` drains it. Torn down in
    // `stop()`/`internalStop()`/`forceStop()` via `tearDownStreamingSession()`.
    private var streamingQueue: StreamingBufferQueue?

    // Batch-only-streaming preview (docs/plans/batch-only-streaming.md).
    // Consumes the `streamingQueue` the tap pushes into. When
    // `AppGroup.liveTextSetting` resolves OFF, the scheduler doesn't start and
    // the queue is closed immediately (pushes drop; zero inference during
    // dictation capture).
    private var previewScheduler: PreviewScheduler?
    private var previewDrainTask: Task<Void, Never>?
    /// Polls the batch model's `modelState` while a batch streaming session is
    /// active so the keyboard's "Loading …" affordance can be cleared the
    /// moment the model is ready. See `beginBatchLoadLabelMirror()`.
    private var batchLoadLabelTask: Task<Void, Never>?

    // MARK: - Pause / Resume (UX-overhaul round 2 §10)
    //
    // Pause keeps the engine + tap running and gates the slice router
    // (`pauseSlice()` drops buffers without ending the slice); Resume re-arms
    // capture against the SAME `CaptureContext` so samples concatenate. The
    // following fields support the two derived behaviors §10 requires:
    // an elapsed clock that freezes during the pause gap (§10.4), and a live
    // streaming partial that persists across pause and appends on resume
    // (§10.5).

    /// Sum of completed active-capture spans, in seconds, for the current
    /// session. Updated on each `pauseRecording()` (we add the just-ended
    /// active span) so the displayed elapsed = `accumulatedActiveSeconds +
    /// (now − currentActiveSpanStartedAt)` while active, and exactly
    /// `accumulatedActiveSeconds` while paused (the clock freezes). Reset on
    /// every fresh `start()` / warm-resume and cleared on terminal teardown.
    private var accumulatedActiveSeconds: TimeInterval = 0

    /// Wall-clock anchor of the CURRENT active-capture span. While active this
    /// is the moment capture (re)started; while paused it is `nil`. The
    /// published `recordingStartedAt` is back-dated to
    /// `now − totalElapsed` so the keyboard's existing wall-clock elapsed
    /// renderer naturally shows accumulated-active time and freezes on pause
    /// (we re-publish a back-dated anchor on resume). See `pausedAwareStartedAt()`.
    private var currentActiveSpanStartedAt: Date?

    /// Committed streaming text captured at pause time (§10.5). On pause we
    /// tear down the current slice's streaming session and promote its preview
    /// to a final snapshot; that text is held here as a prefix. On resume a
    /// fresh streaming session feeds new partials that the presenter renders as
    /// `committedStreamingPrefix + newPartial`. Empty between sessions.
    private var committedStreamingPrefix: String = ""

    /// The async pause-teardown Task (streaming session teardown + committed-
    /// prefix snapshot). `resumeRecording()` MUST await this before it installs
    /// a fresh streaming queue and reads `committedStreamingPrefix`: a very fast
    /// pause→resume could otherwise (a) read an empty prefix before this Task
    /// sets it (the pre-pause text would be lost), and (b) have this Task's
    /// `tearDownStreamingSession()` nil `streamingQueue` AFTER resume installed
    /// its fresh queue, so the resumed tail never streams. Awaiting serializes
    /// both hazards. Cleared by every terminal teardown via `clearPauseState()`.
    private var pauseTeardownTask: Task<Void, Never>?

    /// Upper safety ceiling for a paused session (§10.3). Because Option A
    /// keeps the mic warm for the entire pause, a forgotten pause would hold
    /// the mic (and the orange indicator) indefinitely. This task arms at
    /// `pauseRecording()` and auto-finalizes the session via `internalStop`
    /// if Resume/Stop never arrives within `pauseSafetyCeiling`. Cancelled on
    /// resume / stop / any teardown.
    ///
    /// NOTE: the round-2 plan §10.3 says to "reuse the existing 15-min
    /// recording cap as the safety ceiling," but no such global recording cap
    /// exists in this file today (verified by grep). Rather than invent a
    /// whole-session cap out of scope, this implements the pause-specific
    /// ceiling the §10.3 hazard actually requires, sized to match the plan's
    /// stated 15-minute intent. If a global recording cap lands later, fold
    /// this into it.
    private var pauseSafetyTask: Task<Void, Never>?
    private static let pauseSafetyCeiling: TimeInterval = 15 * 60

    /// True wall-clock start of the current dictation session, captured once
    /// at recording start and NOT re-anchored on resume (unlike
    /// `currentRecordingStartedAt`, which is back-dated for the pause-aware
    /// display clock). Used by the warm-hold switching nudge (§4 / R16) to
    /// store the `(startedAt, stoppedAt)` ring-buffer pair — the streak math
    /// compares this session's start against the previous session's stop, so
    /// it must be the true wall-clock anchor, not the display-frozen value.
    private var nudgeSessionStartedAtValue: Date?

    /// Live partial-transcript presenter, injected by `JotApp` at app
    /// construction via `setStreamingPresenter(_:)`. Headless paths
    /// (Shortcuts intent, AppIntent surfaces) leave this nil — streaming
    /// preview is in-app only; failing it gracefully degrades to batch-only
    /// per spec §3.6 ("streaming is a UX nicety; failing it must not
    /// interrupt the user's dictation flow").
    private var streamingPresenter: StreamingPartial?

    /// Inject the live-preview presenter.
    ///
    /// **Lifetime contract:** caller (`JotApp`) MUST own the supplied
    /// `StreamingPartial` for the recorder's lifetime. The setter stores
    /// a strong reference; the presenter is `@MainActor @Observable final
    /// class`, which is reference-typed, so this is a shared-ref hold.
    /// Don't pass a per-scene presenter that can be deallocated under us
    /// — the recorder will dangle.
    ///
    /// **Idempotency:** intended to be called exactly once at app
    /// construction. Subsequent calls overwrite (rare; SwiftUI `#Preview`
    /// rebuilds may re-fire). A debug-only `assertionFailure` flags the
    /// double-call so we catch unexpected lifecycle changes during dev
    /// without crashing release builds.
    func setStreamingPresenter(_ presenter: StreamingPartial) {
        if streamingPresenter != nil {
            assertionFailure("setStreamingPresenter called more than once — verify JotApp lifecycle ownership")
        }
        self.streamingPresenter = presenter
    }

    /// Darwin observers for keyboard-initiated Pause/Resume (§10.2). The
    /// keyboard never runs the engine; it posts `pauseRequested` /
    /// `resumeRequested` and this single owner (the app's `RecordingService`)
    /// executes them. Held for the service's lifetime. Installed lazily on
    /// first `start()` (and idempotently re-checkable) so headless callers that
    /// never record don't pay for them — but also safe to install eagerly via
    /// `installCrossProcessPauseResumeObservers()`.
    private var pauseRequestObserver: CrossProcessNotification.Observer?
    private var resumeRequestObserver: CrossProcessNotification.Observer?

    init() {}

    /// Install the keyboard Pause/Resume Darwin observers (§10.2). Idempotent.
    /// The foreground app (`JotApp`) may call this at construction so the
    /// single-owner contract is established before the first keyboard tap; it
    /// is also called lazily from `start()` so any recording path is covered.
    func installCrossProcessPauseResumeObservers() {
        if pauseRequestObserver == nil {
            pauseRequestObserver = CrossProcessNotification.addObserver(
                name: CrossProcessNotification.pauseRequested
            ) { [weak self] in
                self?.pauseRecording()
            }
        }
        if resumeRequestObserver == nil {
            resumeRequestObserver = CrossProcessNotification.addObserver(
                name: CrossProcessNotification.resumeRequested
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.resumeRecording()
                    } catch {
                        self.log.error("Keyboard-initiated resume failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    // MARK: - Streaming session lifecycle (dual-model-streaming)
    //
    // Two helpers, both `private async` and called from `start()`/`stop()`/
    // teardown paths. The streaming session is bookended exactly once per
    // recording. Mirrors prototype `DualRecorder.swift:151-167` (kickoff)
    // and `:271-291` (teardown).

    /// Spins up the batch `PreviewScheduler` draining the caller-supplied
    /// queue, registers it, and spawns the drain task. Best-effort — returns
    /// silently if the caller has no presenter (headless paths) or live-text
    /// is disabled. The recorder's stop-pass batch path is unaffected.
    ///
    /// Caller MUST allocate `streamingQueue` BEFORE `installTap` so the
    /// tap closure has a queue to push into; this method consumes that
    /// pre-allocated queue.
    private func kickOffStreamingSession() async {
        guard let presenter = streamingPresenter else {
            // Close the queue so tap pushes drop instead of accumulating
            // unconsumed samples for the whole recording (~3.8 MB/min) —
            // pre-existing leak surfaced by review minor #4.
            streamingQueue?.endOfStream()
            log.notice("kickOffStreamingSession skipped — no streaming presenter (headless caller)")
            return
        }
        guard let queue = streamingQueue else {
            log.notice("kickOffStreamingSession skipped — queue not pre-allocated")
            return
        }
        // "Live text while dictating" OFF: start neither consumer and close
        // the queue so tap pushes drop (StreamingBufferQueue.push guards on
        // `ended`). Zero inference during capture; the batch stop-pass is
        // unaffected. (docs/plans/batch-only-streaming.md — streaming-off
        // is the safe baseline / degrade target.)
        //
        // Owned-input-capture EXEMPTION (plan F4): Ask + the voice-prompt
        // rewrite use the live preview AS their input mechanism — Ask's
        // question box reads `streamingText` and its auto-send latch needs a
        // non-empty question, so an off-switch / sub-6GB device would leave
        // those surfaces dead (empty box, no auto-send). Those callers claim
        // `ownsActiveRecording` BEFORE `start()` (InlineDictationSession,
        // RewritePickerSheet), so the flag is a reliable purpose signal here:
        // they always get the scheduler regardless of the toggle / gate.
        guard DeviceCapability.liveTextEnabled || ownsActiveRecording else {
            queue.endOfStream()
            log.notice("Live-text preview disabled — queue closed, no preview consumer")
            return
        }
        let sessionID = presenter.beginSession()
        let scheduler = PreviewScheduler(
            queue: queue,
            presenter: presenter,
            sessionID: sessionID
        )
        self.previewScheduler = scheduler
        self.previewDrainTask = Task.detached(priority: .userInitiated) {
            await scheduler.drain()
        }
        // Make sure the (possibly cold/evicted) batch model is loading, and
        // surface that to the keyboard's "Loading …" affordance — otherwise
        // a cold 600M load shows an empty "Listening…" on the strip with no
        // progress (the live preview can't produce text until the model is
        // ready). `warmUp()` is idempotent; the hero reads modelState
        // directly so it needs no mirror.
        TranscriptionService.shared.warmUp()
        beginBatchLoadLabelMirror()
        // [PREVIEW-DIAG] In-app log — correlate the session token + model
        // state with the scheduler's drain/tick + StreamingPartial's
        // PUBLISH/DROP entries (sid match proves the token lines up across a
        // stretch of dictations). Remove once diagnosed.
        DiagnosticsLog.record(
            source: "main-app", category: .streamingPartialReceived,
            message: "preview session start",
            metadata: [
                "sid": String(sessionID.uuidString.prefix(8)),
                "modelState": String(describing: TranscriptionService.shared.modelState),
                "liveText": "\(DeviceCapability.liveTextEnabled)",
            ]
        )
    }

    // MARK: - Batch model-load affordance for the keyboard

    /// Mirror the BATCH model's load state to the App Group so the keyboard
    /// strip can show the same "Loading [model]…" bar the hero shows.
    ///
    /// The hero observes `TranscriptionService.modelState` directly (same
    /// process); the keyboard extension can't — it only sees App Group keys.
    /// The EOU `StreamingTranscriptionService` already mirrors these keys from
    /// its `sessionLoadState`; the batch path did NOT, so a cold 600M load
    /// (which can run well past the first 15 s) left the keyboard showing a
    /// misleading empty "Listening…" with no text. This writes the SAME three
    /// keys + posts the SAME Darwin notification the EOU path uses, so the
    /// keyboard's existing loading observer renders identically. (We are
    /// 600M-only, so this cold window is always the slow one — the affordance
    /// matters on every cold/evicted load.)
    private func setBatchKeyboardLoadingLabel(_ loading: Bool) {
        AppGroup.streamingLoadingVariantLabel = loading
            ? ColdStartCopy.beginningLine()
            : ""
        if loading {
            AppGroup.streamingLoadStartedAt = Date()
            AppGroup.streamingLoadEstimateSeconds =
                ModelLoadTimekeeper.estimatedSeconds(variant: AppGroup.speechModelVariant)
        } else {
            AppGroup.streamingLoadStartedAt = nil
            AppGroup.streamingLoadEstimateSeconds = 0
        }
        CrossProcessNotification.post(name: CrossProcessNotification.streamingLoadingChanged)
    }

    /// Called when a batch streaming session starts: if the model isn't ready,
    /// show the keyboard loading label and poll until it is (then clear it).
    /// The keyboard's own render gate already supersedes the label the instant
    /// the first preview text arrives, so this is belt-and-suspenders for the
    /// model-ready-but-user-silent window.
    private func beginBatchLoadLabelMirror() {
        batchLoadLabelTask?.cancel()
        batchLoadLabelTask = nil
        guard TranscriptionService.shared.modelState != .ready else {
            setBatchKeyboardLoadingLabel(false)
            return
        }
        setBatchKeyboardLoadingLabel(true)
        batchLoadLabelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if TranscriptionService.shared.modelState == .ready { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self?.setBatchKeyboardLoadingLabel(false)
        }
    }

    /// Tears down the keyboard loading mirror (session ended). Clears the label
    /// synchronously so a later WARM session never inherits a stale "Loading".
    private func endBatchLoadLabelMirror() {
        batchLoadLabelTask?.cancel()
        batchLoadLabelTask = nil
        setBatchKeyboardLoadingLabel(false)
    }

    /// Tears down the streaming session per the prototype's stop ordering
    /// (`DualRecorder.swift:271-291`). Idempotent — no-op if no session is
    /// active or kickoff failed (queue + tap dropped silently).
    ///
    /// Order matters:
    /// 1. Push end-of-stream into the queue (signals drain to exit).
    /// 2. Await drain task — guarantees in-flight `appendAudio` /
    ///    `processBufferedAudio` calls complete before `finish()`.
    /// 3. Clear the streaming session UUID on the presenter + service —
    ///    BEFORE `finish()` per prototype rounds-3-4: a late callback
    ///    dispatched between drain exit and `finish()` would otherwise flip
    ///    `streamingIsVolatile` back to `true` after we've promoted to
    ///    `.primary`.
    /// 4. `engine.finish()` — applies the final snapshot via
    ///    `presenter.applyFinalSnapshot(_:)`, bypassing the cleared session
    ///    guard for the explicit promote-to-final write.
    /// 5. `service.endSession(engine:)` — calls `engine.cleanup()` for
    ///    full CoreML eviction.
    /// 6. Drop local refs.
    ///
    /// Always nils `streamingQueue` last so a no-engine, queue-only state
    /// (kickoff failed mid-recording) still cleans up properly.
    private func tearDownStreamingSession() async {
        // Always signal the queue (covers the kickoff-failed orphan case
        // where `streamingEngine == nil` but `streamingQueue != nil` —
        // tap closures may have pushed samples that nothing consumes).
        streamingQueue?.endOfStream()

        // Batch-preview teardown: drain returns on end-of-stream → clear the
        // session token → promote the assembled preview via `applyFinalSnapshot`
        // (bypasses the cleared-token guard by design) → the stop-pass batch
        // result replaces it.
        if let scheduler = previewScheduler {
            endBatchLoadLabelMirror()
            await previewDrainTask?.value
            previewDrainTask = nil
            // Quiesce BEFORE reading assembledText: an in-flight tick
            // survives drain's return (it runs as its own task); without
            // this fence the snapshot races the tick's commit and can drop
            // the last window's words across a pause (review M1). Also
            // disables rescheduling so no zombie inference starts while
            // the saving stop-pass runs.
            await scheduler.quiesce()
            if let presenter = streamingPresenter {
                presenter.clearSession()
                let assembled = await scheduler.assembledText()
                if !assembled.isEmpty {
                    presenter.applyFinalSnapshot(assembled)
                }
            }
            self.previewScheduler = nil
            self.streamingQueue = nil
            return
        }

        // Kickoff never completed (no scheduler) — just release the queue.
        self.streamingQueue = nil
    }

    /// Starts recording.
    ///
    /// v1 limitation: warm-resume cannot succeed while a prior pipeline is still
    /// in flight because warm-resume requires the prior pipeline to have reached
    /// terminal so currentSessionID and pipelinePhase publish cleanly. Re-taps
    /// during the `.transcribing` tail throw, and the keyboard fast-path (Phase 4)
    /// falls back to cold-launch via jot://. See keyboard-warm-mic-60s-research.md §1a.
    func start() async throws {
        guard !isRecording else { throw RecordingError.alreadyRunning }

        // Make any in-flight TTS read-aloud yield the shared audio session BEFORE
        // we (cold OR warm) touch `.record`, so its `.playback` engine can't
        // collide with the mic. No-op when nothing is playing — the arbiter never
        // touches the session itself, so a warm-held session is untouched here.
        AudioSessionArbiter.shared.yieldForRecording()

        // Ensure the keyboard Pause/Resume Darwin observers exist before this
        // recording can be paused from the keyboard (§10.2). Idempotent.
        installCrossProcessPauseResumeObservers()

        if isPipelineInFlight {
            if isWarm {
                log.info("Warm-resume blocked - prior pipeline still in flight; caller should cold-launch")
            }
            throw RecordingError.alreadyRunning
        }

        if isWarm {
            if let engine, engine.isRunning, isTapInstalled {
                do {
                    try await startFromWarmHold(engine: engine)
                    return
                } catch RecordingError.warmYieldRestoreFailed {
                    // The on-resume `.mixWithOthers` restore threw (likely a
                    // background `cannotInterruptOthers`). Rather than resume a
                    // session left non-mixable (which would hit `.micUnavailable`),
                    // gently cool the warm engine and fall through to a full cold
                    // `configureSession` below. `startFromWarmHold` has already
                    // torn the engine down before throwing this case.
                    log.error("Warm-resume mixWithOthers restore failed — cold-starting instead")
                    exitWarmHold()
                }
            } else {
                log.error("Warm-hold state had no running tapped engine; falling back to cold start.")
                exitWarmHold()
            }
        }

        try configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        // Mic-availability preflight: with `.mixWithOthers`, configureSession
        // succeeds even when another app holds the mic exclusively (active
        // phone call, Siri capturing, another voice-input app). In that
        // state iOS reports the input bus as 0 channels / 0 Hz — the
        // engine and tap will install + start without throwing, but every
        // tap callback delivers silence. Without this guard the upstream
        // banner mechanism never fires, the hero pushes with "Listening…",
        // and the user records into a void. Catching it here surfaces a
        // real error to `triggerAutoStart`'s banner path.
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            log.error("Mic unavailable on start — input reports channels=\(hardwareFormat.channelCount) sampleRate=\(hardwareFormat.sampleRate)")
            restoreSession()
            throw RecordingError.micUnavailable
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: Self.target) else {
            restoreSession()
            throw RecordingError.converterUnavailable
        }

        let capture = CaptureContext(converter: converter, inputFormat: hardwareFormat, target: Self.target, log: log)

        // Pre-allocate the streaming queue BEFORE installTap. Tap closures
        // capture this by value (lock-protected `@unchecked Sendable` queue)
        // so post-alloc kickoff just constructs the engine + drain task
        // against it.
        let streamingQueue = StreamingBufferQueue()
        beginSlice(capture: capture, streamingQueue: streamingQueue)

        installTap(on: engine, hardwareFormat: hardwareFormat)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Log the underlying CoreAudio domain/code (mirrors configureSession's
            // diagnostics). This is the failure GitHub issue #3 surfaces when a
            // dictation intent starts the mic before the app is truly foreground —
            // capturing the exact code makes a surviving foreground-race detectable
            // on device rather than hidden behind the generic "engine failed to
            // start" banner.
            let ns = error as NSError
            log.error(
                "engine.start() FAILED — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) localizedDescription=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)"
            )
            _ = endActiveSlice()
            removeTapIfInstalled(from: input)
            restoreSession()
            self.streamingQueue = nil
            throw RecordingError.engineStart(error)
        }

        self.engine = engine
        subscribeSystemObservers(engine: engine)
        let startedAt = Date()
        isRecording = true
        // Seed the pause-aware elapsed accounting (§10.4): one fresh active
        // span begins now, with no prior accumulated time. Must precede the
        // `.recording` publish — the projection's `recordingStartedAt` is
        // assembled there.
        resetActiveElapsed()
        beginActiveSpan(at: startedAt)
        // True session-start anchor for the warm-hold nudge (R16) — NOT
        // re-anchored on resume, unlike the display clock.
        nudgeSessionStartedAtValue = startedAt
        // `setCurrentRecordingStartedAt` MUST precede `publishPipelinePhase(.recording)`
        // — the helper reads `currentRecordingStartedAt` when assembling the
        // projection, and the keyboard's elapsed-time clock renders off that
        // field. No separate `publishRecordingState` call: pipeline phase is
        // the single source of truth for cross-process recording state.
        setCurrentRecordingStartedAt(startedAt)
        publishPipelinePhase(.recording)
        log.info("Recording started at hardware \(Int(hardwareFormat.sampleRate))Hz/\(Int(hardwareFormat.channelCount))ch")

        // Fire-and-forget streaming kickoff. The engine + drain task spin
        // up against the pre-allocated queue captured by the tap closure;
        // initial samples queued before the drain is alive get consumed
        // when the drain spawns. No-op when the model isn't on disk or the
        // caller is headless (no presenter injected).
        Task { [weak self] in
            await self?.kickOffStreamingSession()
        }
    }

    private func startFromWarmHold(engine: AVAudioEngine) async throws {
        guard engine.isRunning, isTapInstalled else {
            fullyTeardownEngine()
            throw RecordingError.notRunning
        }

        warmCooldownTask?.cancel()
        warmCooldownTask = nil
        warmHeartbeatTask?.cancel()
        warmHeartbeatTask = nil

        // Restore `.mixWithOthers` (dropped at warm entry by
        // `dropMixWithOthersForWarmIdle`) BEFORE resuming, so the next dictation
        // keeps the `.micUnavailable` mitigation (can come up while another app
        // holds the mic). On throw, tear the engine down and signal `start()` to
        // cold-start rather than resume a non-mixable session. Measured on-device
        // at 15–19ms — no warm-resume regression.
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.mixWithOthers])
        } catch {
            let ns = error as NSError
            log.error("Warm-resume mixWithOthers restore failed — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public)")
            fullyTeardownEngine()
            throw RecordingError.warmYieldRestoreFailed
        }

        pendingWarmHoldPublish = false
        isWarm = false
        AppGroup.warmHoldExpiresAt = nil
        AppGroup.warmHoldHeartbeat = nil
        warmExpiresAt = nil

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: Self.target) else {
            fullyTeardownEngine()
            throw RecordingError.converterUnavailable
        }

        let capture = CaptureContext(converter: converter, inputFormat: hardwareFormat, target: Self.target, log: log)

        // Warm resume keeps the engine + tap continuously running, but each
        // slice still owns a fresh capture context and streaming queue.
        let streamingQueue = StreamingBufferQueue()
        beginSlice(capture: capture, streamingQueue: streamingQueue)

        self.engine = engine
        subscribeSystemObservers(engine: engine)
        let startedAt = Date()
        isRecording = true
        resetActiveElapsed()
        beginActiveSpan(at: startedAt)
        nudgeSessionStartedAtValue = startedAt
        setCurrentRecordingStartedAt(startedAt)
        publishPipelinePhase(.recording)
        log.info("Warm recording resumed at hardware \(Int(hardwareFormat.sampleRate))Hz/\(Int(hardwareFormat.channelCount))ch")
        log.notice("Warm-hold resumed; restored mixWithOthers")

        Task { [weak self] in
            await self?.kickOffStreamingSession()
        }
    }

    private func beginSlice(capture: CaptureContext, streamingQueue: StreamingBufferQueue) {
        self.capture = capture
        self.streamingQueue = streamingQueue
        isCapturingSlice = true
        tapRouter.beginSlice(capture: capture, streamingQueue: streamingQueue)
    }

    private func endActiveSlice() -> CaptureContext? {
        isCapturingSlice = false
        let routedCapture = tapRouter.endSlice()
        let activeCapture = capture ?? routedCapture
        capture = nil
        return activeCapture
    }

    private func clearActiveSliceRouting() {
        isCapturingSlice = false
        _ = tapRouter.endSlice()
        capture = nil
    }

    // MARK: - Pause / Resume (UX-overhaul round 2 §10)

    /// Begin a fresh active-capture span (§10.4). Called on every recording
    /// start, warm-resume, and on `resumeRecording()`. Sets the wall-clock
    /// anchor for the current span; `accumulatedActiveSeconds` is the running
    /// total of prior completed spans (reset to 0 by callers that start a
    /// brand-new session).
    private func beginActiveSpan(at date: Date) {
        currentActiveSpanStartedAt = date
    }

    /// Fold the just-ended active span into `accumulatedActiveSeconds` and
    /// clear the span anchor (§10.4). Called on pause. Idempotent: a nil
    /// anchor (already paused) is a no-op.
    private func endActiveSpan(at date: Date) {
        guard let started = currentActiveSpanStartedAt else { return }
        accumulatedActiveSeconds += max(0, date.timeIntervalSince(started))
        currentActiveSpanStartedAt = nil
    }

    /// Total active (capturing) elapsed for the current session, excluding
    /// pause gaps (§10.4). Equal to `accumulatedActiveSeconds` while paused
    /// (frozen) and growing with wall-clock while active.
    private func totalActiveElapsed() -> TimeInterval {
        if let started = currentActiveSpanStartedAt {
            return accumulatedActiveSeconds + max(0, Date().timeIntervalSince(started))
        }
        return accumulatedActiveSeconds
    }

    /// A back-dated `recordingStartedAt` so the keyboard's existing wall-clock
    /// elapsed renderer (`now − recordingStartedAt`) naturally shows
    /// pause-excluded active time. While active, re-anchoring on resume makes
    /// the keyboard's clock pick up exactly where it froze. While paused we
    /// don't move the clock at all (we publish `.paused` without re-anchoring),
    /// so the keyboard sees the same frozen value until resume.
    private func pausedAwareStartedAt() -> Date {
        Date().addingTimeInterval(-totalActiveElapsed())
    }

    /// Reset the pause-aware elapsed accounting to a clean slate. Called on
    /// terminal teardown so the next session starts from zero.
    private func resetActiveElapsed() {
        accumulatedActiveSeconds = 0
        currentActiveSpanStartedAt = nil
    }

    /// Pause the current recording (§10). Keeps the engine + tap running and
    /// the mic warm (Option A) — only the slice router is gated so buffers are
    /// dropped without ending the slice. The accumulated samples + streaming
    /// preview persist; the elapsed clock freezes; a safety-ceiling task arms
    /// so a forgotten pause auto-finalizes rather than holding the mic forever.
    ///
    /// No-op (logged) when not actively recording, already paused, or
    /// mid-stop. Cannot be called while warm-held — warm-hold is a post-stop
    /// idle state, not a live recording (§10.6).
    func pauseRecording() {
        guard isRecording, !isPaused, !isStopInFlight else {
            log.notice("Pause skipped — isRecording=\(self.isRecording, privacy: .public) isPaused=\(self.isPaused, privacy: .public) isStopInFlight=\(self.isStopInFlight, privacy: .public)")
            return
        }
        guard !isWarm else {
            log.notice("Pause skipped — warm-hold is a post-stop idle state, not a live recording.")
            return
        }

        log.notice("RECORDING PAUSE FROM: pauseRecording()")

        // Freeze the elapsed clock: fold the active span into the accumulator
        // and drop the span anchor (§10.4).
        endActiveSpan(at: Date())

        // Gate the router WITHOUT ending the slice (§10.1): buffers are now
        // dropped, but `capture` + accumulated samples survive for resume.
        isCapturingSlice = false
        tapRouter.pauseSlice()

        isPaused = true
        currentAmplitude = nil
        AmplitudeProjection.clear()

        // Promote the live streaming preview to a committed prefix (§10.5):
        // tear down THIS slice's streaming session (its preview is finalized
        // via engine.finish() inside teardown), snapshot the finalized text,
        // and hold it so resume can render `prefix + newPartial`. Done async
        // because teardown awaits the drain; the paused phase is published
        // first so the UI flips immediately.
        publishPausedPhase()
        armPauseSafetyCeiling()

        // Hold the teardown Task so `resumeRecording()` can await it before
        // installing a fresh queue / reading the committed prefix (see the
        // field doc — serializes the fast pause→resume race).
        pauseTeardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Snapshot whatever the presenter currently shows BEFORE teardown
            // so a finish() that returns nothing still keeps the visible text.
            let visiblePrefix = self.streamingPresenter?.streamingText ?? ""
            await self.tearDownStreamingSession()
            // Prefer the post-finish snapshot the presenter now holds; fall
            // back to the pre-teardown visible text.
            let finalized = self.streamingPresenter?.streamingText ?? ""
            self.committedStreamingPrefix = finalized.isEmpty ? visiblePrefix : finalized
            self.log.info("Pause committed streaming prefix — chars=\(self.committedStreamingPrefix.count, privacy: .public)")
        }
    }

    /// Resume a paused recording (§10). Re-arms capture against the SAME
    /// `CaptureContext` (samples concatenate, pause gap absent), re-anchors the
    /// elapsed clock, and starts a fresh streaming session that renders
    /// post-resume partials appended to the committed prefix.
    ///
    /// Throws `.notRunning` if there is no paused session to resume or the
    /// engine has since been torn down (e.g. an interruption while paused
    /// already routed to `internalStop`).
    func resumeRecording() async throws {
        guard isRecording, isPaused else {
            log.notice("Resume skipped — isRecording=\(self.isRecording, privacy: .public) isPaused=\(self.isPaused, privacy: .public)")
            throw RecordingError.notRunning
        }
        guard let engine, engine.isRunning, isTapInstalled, let capture else {
            log.error("Resume requested but engine/tap/capture missing — finalizing.")
            // The mic-warm engine went away under us (interruption raced the
            // resume). Treat as a hard stop of the accumulated audio.
            isPaused = false
            cancelPauseSafetyCeiling()
            internalStop(reason: "resume-without-engine")
            throw RecordingError.notRunning
        }

        log.notice("RECORDING RESUME FROM: resumeRecording()")
        cancelPauseSafetyCeiling()

        // Serialize against the pause-teardown Task (see `pauseTeardownTask`):
        // on a fast pause→resume it may still be mid-flight, and its
        // `tearDownStreamingSession()` nils `streamingQueue` + sets
        // `committedStreamingPrefix`. Awaiting it here guarantees the fresh
        // queue we install below isn't clobbered and the committed prefix is
        // populated before we seed it. No-op when teardown already finished.
        if let pending = pauseTeardownTask {
            await pending.value
            pauseTeardownTask = nil
        }

        // Fresh streaming session for the resumed tail (§10.5). A new queue is
        // installed into the router via `resumeSlice` so post-resume partials
        // flow to the new engine; the presenter renders prefix + newPartial.
        let resumedQueue = StreamingBufferQueue()
        self.streamingQueue = resumedQueue

        // Re-arm capture against the SAME capture context (§10.1).
        isCapturingSlice = true
        tapRouter.resumeSlice(streamingQueue: resumedQueue)
        // `capture` is unchanged; keep the local binding alive so the compiler
        // sees the guard's unwrap is load-bearing.
        _ = capture

        isPaused = false

        // Re-anchor the elapsed clock: a new active span starts now; the
        // accumulated total carries the paused-excluded time (§10.4).
        beginActiveSpan(at: Date())
        setCurrentRecordingStartedAt(pausedAwareStartedAt())
        publishPipelinePhase(.recording)

        log.info("Recording resumed; committed prefix chars=\(self.committedStreamingPrefix.count, privacy: .public)")

        // Spin up the fresh streaming session against the new queue, THEN
        // seed the committed prefix. Ordering is load-bearing:
        // `kickOffStreamingSession()` calls `presenter.beginSession()`, which
        // clears `resumePrefix`; seeding afterward means the first post-resume
        // partial renders as `prefix + newPartial` rather than restarting from
        // empty.
        let prefix = committedStreamingPrefix
        Task { [weak self] in
            guard let self else { return }
            await self.kickOffStreamingSession()
            if !prefix.isEmpty {
                self.streamingPresenter?.seedResumePrefix(prefix)
            }
        }
    }

    /// Publish the `.paused` phase (§10.2). Mirrors `publishPipelinePhase` but
    /// pins the projection's `recordingStartedAt` to the FROZEN pause-aware
    /// anchor so the keyboard's wall-clock elapsed renderer stays frozen at the
    /// active-time total. We intentionally do NOT route through
    /// `publishPipelinePhase` for the recordingStartedAt because that helper
    /// publishes the live `currentRecordingStartedAt`; here the displayed clock
    /// must freeze.
    private func publishPausedPhase() {
        // Freeze the projected start anchor at the accumulated active time.
        let frozenAnchor = pausedAwareStartedAt()
        setCurrentRecordingStartedAt(frozenAnchor)
        publishPipelinePhase(.paused)
    }

    /// Arm the pause safety ceiling (§10.3). If neither Resume nor Stop arrives
    /// within `pauseSafetyCeiling`, auto-finalize the accumulated audio via
    /// `internalStop` so a forgotten pause never holds the mic indefinitely.
    private func armPauseSafetyCeiling() {
        pauseSafetyTask?.cancel()
        pauseSafetyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(RecordingService.pauseSafetyCeiling))
            } catch {
                return
            }
            guard let self, self.isPaused else { return }
            self.log.notice("Pause safety ceiling reached — auto-finalizing paused recording.")
            // Drop paused state so internalStop's normal path runs (it bails
            // early when isPaused-only state would confuse teardown).
            self.isPaused = false
            self.pauseSafetyTask = nil
            self.internalStop(reason: "pause-safety-ceiling")
        }
    }

    private func cancelPauseSafetyCeiling() {
        pauseSafetyTask?.cancel()
        pauseSafetyTask = nil
    }

    /// Clear all Pause/Resume-derived state on any terminal teardown so the
    /// next recording starts clean (§10). Idempotent. Does NOT itself publish
    /// a phase — callers own the terminal phase transition.
    private func clearPauseState() {
        isPaused = false
        cancelPauseSafetyCeiling()
        resetActiveElapsed()
        committedStreamingPrefix = ""
        // Drop any in-flight pause-teardown handle. The Task is already
        // operating on the (now-superseded) streaming refs; a terminal path
        // installs its own teardown, so we just stop tracking it for the
        // resume-serialization await.
        pauseTeardownTask = nil
    }

    private func removeTapIfInstalled(from input: AVAudioInputNode) {
        guard isTapInstalled else { return }
        input.removeTap(onBus: 0)
        isTapInstalled = false
    }

    /// Installs the audio tap on `engine.inputNode` with the canonical Jot
    /// tap block (RMS amplitude → ~30Hz MainActor publication + 100ms
    /// AppGroup amplitude projection + first-buffer diagnostic log gated by
    /// `TapOnceGate`).
    ///
    /// The `@Sendable` annotation on `tapBlock` is load-bearing — see the
    /// pre-factor history of this file at HEAD~ for the full diagnostic
    /// rationale (Swift 6 isolation inference, audio-render thread, the
    /// `swift_task_checkIsolated(MainActor.shared)` trap on iPhone 17 /
    /// iOS 26.2). Do not rewrite without preserving the `@Sendable`.
    private func installTap(
        on engine: AVAudioEngine,
        hardwareFormat: AVAudioFormat
    ) {
        let input = engine.inputNode
        let tapOnce = TapOnceGate()
        let amplitudeGate = AmplitudeGate(intervalMS: 33)
        let appGroupAmplitudeGate = AmplitudeGate(intervalMS: 100)
        let tapLog = log
        let router = tapRouter
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [router, tapOnce, amplitudeGate, appGroupAmplitudeGate, tapLog, weak self] pcm, _ in
            if tapOnce.fireOnce() {
                tapLog.debug("[recording] first tap callback on \(Thread.current.description, privacy: .public)")
            }
            // Single converter pass when a slice is active: the router sends
            // the buffer to the current `CaptureContext` and streaming queue.
            // While warm-held and idle, it drops the buffer before conversion,
            // storage, amplitude publication, or live-preview fan-out.
            guard router.route(pcm) else { return }

            if amplitudeGate.shouldFire(), let amp = normalizedAmplitude(pcm) {
                Task { @MainActor in
                    guard let self, self.isRecording, self.isCapturingSlice else { return }
                    self.currentAmplitude = amp
                    if appGroupAmplitudeGate.shouldFire() {
                        AmplitudeProjection.write(amplitude: amp)
                    }
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)
        isTapInstalled = true
    }

    func stop() async throws -> [Float] {
        isStopInFlight = true
        isPipelineInFlight = true

        // A Stop from the paused state is a clean final stop (§10.6): the
        // open slice's accumulated samples drain normally below. Drop the
        // paused flag + safety ceiling so teardown runs the standard path.
        let wasPaused = isPaused
        isPaused = false
        cancelPauseSafetyCeiling()

        // If a Stop lands while the pause-teardown Task is still tearing down
        // the streaming session, await it first so its `tearDownStreamingSession()`
        // (which nils the streaming refs) fully completes before our own
        // teardown below runs — otherwise two concurrent teardowns race the
        // same `streamingEngine`/`streamingQueue`. After the await our teardown
        // is a clean no-op on already-nil refs.
        if let pending = pauseTeardownTask {
            await pending.value
            pauseTeardownTask = nil
        }

        // Snapshot ownership at stop() ENTRY (before any terminal clears it):
        // inline (in-field) sessions — Edit, Ask, keyboard-while-in-Jot — set
        // `ownsActiveRecording`, and they must NOT feed the warm-hold switching
        // nudge. The nudge (§4 / R10) detects the *targetless* keyboard/hero
        // record-and-bounce pattern only; an in-field dictation is not a bounce
        // (it saves no transcript, decision #3; bypasses DictationStats, R7), so
        // two quick inline Edits must not manufacture a false streak.
        let isInlineStop = ownsActiveRecording

        do {
            // Snapshot the recording's true start time + session ID at stop()
            // ENTRY for the warm-hold nudge (R16): `currentRecordingStartedAt`
            // is back-dated/nil'd later, so we use the dedicated session
            // anchor. Defaults to now if a start somehow skipped seeding it.
            let nudgeStartedAt = nudgeSessionStartedAtValue ?? Date()
            let nudgeSessionID = currentSessionID

            // Tolerant of the case where an interruption / route change already
            // tore down the engine internally: the UI still calls stop() and
            // expects whatever samples we collected. Only throw `.notRunning` if
            // we have no capture at all — there was nothing to stop.
            guard let capture = endActiveSlice() else {
                resetActiveElapsed()
                throw RecordingError.notRunning
            }

            let samples = capture.drain()

            // Streaming teardown — mirrors prototype `DualRecorder.swift:271-291`.
            // Slice capture has already been disabled in the router;
            // `CaptureContext.drain()` waits for in-flight tap callbacks to
            // leave the converter/storage path. The engine tap itself stays
            // installed through warm hold and drops buffers while idle.
            // tearDown then signals EOS, awaits the drain task (bounded by
            // in-flight chunk inference, ~50-200ms typical), promotes the
            // streaming preview to its final snapshot via engine.finish(), then
            // releases the FluidAudio manager via engine.cleanup()
            // (cleanup-on-every-stop policy).
            await tearDownStreamingSession()

            isRecording = false
            currentAmplitude = nil
            AmplitudeProjection.clear()
            // Pause-aware elapsed accounting is per-session; clear it now that
            // the session is ending so the next recording starts from zero.
            resetActiveElapsed()
            committedStreamingPrefix = ""
            _ = wasPaused

            // Warm-hold switching nudge (§4 / R10 / R16). Pinned to THIS one
            // clean-stop site (NOT markPipelineFinished) and deduped on the
            // session ID so a single stop appends exactly one ring entry.
            // Cancelled recordings (`cancel()`) and interruption-recovered
            // stops (`internalStop`) deliberately do NOT count toward the
            // streak (§4 "cancelled recordings don't count"; R10 explicit
            // decision to exclude interruption-recovered dictations — only a
            // clean user Stop reflects the record-and-bounce behavior the
            // nudge targets). Inline (in-field) stops are likewise excluded —
            // see `isInlineStop` above.
            if !isInlineStop {
                detectWarmHoldSwitchingNudge(
                    startedAt: nudgeStartedAt,
                    stoppedAt: Date(),
                    sessionID: nudgeSessionID
                )
            }

            let cooldownDuration = warmHoldCooldownDuration()
            let shouldEnterWarmHold = cooldownDuration > 0
                && engine?.isRunning == true
                && isTapInstalled

            if !shouldEnterWarmHold {
                fullyTeardownEngine()
            }

            // Advance the pipeline phase off `.recording`. With pipeline phase
            // as the single source of truth, the keyboard derives
            // `isRecording` from `phase == .recording`, so the moment we
            // publish `.transcribing` here the keyboard's mic CTA flips to
            // its in-flight state. `.transcribing` is the natural next phase
            // after a clean user-stop; the pipeline overwrites it with
            // `.processing` when transcription completes.
            publishPipelinePhase(.transcribing)

            let seconds = Double(samples.count) / Self.sampleRate
            log.info("Recording stopped — \(samples.count) samples (~\(seconds, privacy: .public)s)")
            // One copyable line per recording (the per-tick streaming logs are
            // filtered out). The captured AUDIO seconds here is what exposes a
            // cold-start capture miss: a long wall-clock timer but <1s captured →
            // the mic didn't actually deliver frames (the audioTooShort failure).
            DiagnosticsLog.record(
                source: "main-app",
                category: .recordingOutcome,
                message: "recording stopped",
                metadata: [
                    "capturedSec": String(format: "%.1f", seconds),
                    "samples": "\(samples.count)",
                ]
            )
            if shouldEnterWarmHold {
                enterWarmHold(duration: cooldownDuration)
            }
            isStopInFlight = false
            return samples
        } catch {
            isStopInFlight = false
            isPipelineInFlight = false
            // `stop()` itself threw — there's no transcription tail to follow
            // and no publish coming, so the keyboard would otherwise observe
            // `phase == .recording` until the 30s heartbeat-stale path fires.
            // Publish `.failed` decisively so the keyboard's mic CTA can flip
            // off `.recording` immediately and the pending-paste cleanup
            // branch runs.
            publishPipelinePhase(.failed, failureReason: "stop-throw")
            throw error
        }
    }

    private func warmHoldCooldownDuration() -> TimeInterval {
        guard AppGroup.warmHoldEnabled else { return 0 }
        if let rawDuration = AppGroup.defaults.object(forKey: AppGroup.Keys.warmHoldDurationSeconds) as? NSNumber,
           rawDuration.doubleValue <= 0 {
            return 0
        }
        return max(0, AppGroup.warmHoldDurationSeconds)
    }

    private func enterWarmHold(duration: TimeInterval) {
        log.notice("[WARM-HOLD-DEBUG] enterWarmHold called, isPipelineInFlight=\(self.isPipelineInFlight, privacy: .public)")

        guard let engine else {
            log.error("Warm-hold entry requested without an engine; fully tearing down.")
            fullyTeardownEngine()
            return
        }

        guard engine.isRunning, isTapInstalled, !isCapturingSlice else {
            log.error("Warm-hold entry requested without a running idle tap; fully tearing down.")
            fullyTeardownEngine()
            return
        }

        // Snapshot the configured duration once at entry; subsequent Settings
        // changes must NOT resize this in-flight warm window.
        warmCooldownTask?.cancel()
        let expiresAt = Date().addingTimeInterval(duration)
        isWarm = true
        warmExpiresAt = expiresAt
        warmCooldownTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard let self, self.isWarm, !self.isCapturingSlice else { return }
            self.log.notice("[WARM-HOLD-DEBUG] cooldown timer fired")
            self.exitWarmHold()
        }

        log.info("Warm hold entered; expiresAt=\(expiresAt.timeIntervalSince1970, privacy: .public)")

        // Drop `.mixWithOthers` for the idle warm window so another app starting
        // playback (YouTube, Music) generates an interruption `.began` that
        // `handleInterruption` yields on (`restoreSession` → `setActive(false,
        // .notifyOthersOnDeactivation)` lets the other app's audio through).
        // Restored on warm-resume by `startFromWarmHold`. Idle-only — never
        // during active capture (`enterWarmHold` already guards `!isCapturingSlice`).
        dropMixWithOthersForWarmIdle()

        if isPipelineInFlight {
            pendingWarmHoldPublish = true
            log.notice("[WARM-HOLD-DEBUG] publication deferred until pipeline finishes")
            return
        }

        pendingWarmHoldPublish = false
        publishWarmHoldState()
    }

    private func publishWarmHoldState() {
        guard isWarm, let warmExpiresAt else { return }

        AppGroup.warmHoldExpiresAt = warmExpiresAt
        // Seed the heartbeat immediately so the keyboard's first liveness
        // check after enterWarmHold doesn't see a nil/stale value.
        AppGroup.warmHoldHeartbeat = Date()

        warmHeartbeatTask?.cancel()
        warmHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isWarm else { return }
                AppGroup.warmHoldHeartbeat = Date()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }

        log.notice("[WARM-HOLD-DEBUG] warm state published, expiresAt=\(warmExpiresAt.timeIntervalSince1970, privacy: .public)")
    }

    // MARK: - Warm-hold mic yielding

    /// Drop `.mixWithOthers` for the idle warm window so another app starting
    /// playback generates an interruption `.began` that `handleInterruption`
    /// yields on (validated on-device: YouTube + Apple Music both interrupt and
    /// recover). A mixable `.record` session suppresses that interruption, which
    /// is why a warm-held Jot would otherwise silently block the other app's
    /// audio forever. Restored on warm-resume by `startFromWarmHold`.
    ///
    /// Idle-window only — the caller (`enterWarmHold`) already guards
    /// `engine.isRunning, isTapInstalled, !isCapturingSlice`, so this never runs
    /// during active capture. No `setActive` cycle (options-only on the live
    /// session); on a real iPhone the option clears in place (opts 1→0).
    ///
    /// On throw, skip the drop and keep the session exactly as the warm engine
    /// had it (never leave it indeterminate). The background `setCategory` can
    /// fail with `cannotInterruptOthers` (561017449); if so we simply stay
    /// mixable for this window — the only cost is that this window won't yield,
    /// which is strictly no worse than the pre-fix behavior.
    private func dropMixWithOthersForWarmIdle() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
        } catch {
            let ns = error as NSError
            log.error("Warm-hold mixWithOthers drop failed — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public). Staying mixable for this window.")
        }
    }

    private func exitWarmHold() {
        let wasWarm = isWarm
        warmCooldownTask?.cancel()
        warmCooldownTask = nil
        warmHeartbeatTask?.cancel()
        warmHeartbeatTask = nil
        pendingWarmHoldPublish = false
        warmExpiresAt = nil
        AppGroup.warmHoldExpiresAt = nil
        AppGroup.warmHoldHeartbeat = nil
        isWarm = false
        // Warm-hold is post-stop idle, mutually exclusive with pause (§10.6),
        // so paused state should already be clear — but clear defensively in
        // case a cold-start fallback routed here mid-pause.
        clearPauseState()

        fullyTeardownEngine()

        if wasWarm {
            log.notice("[WARM-HOLD-DEBUG] warm hold exited / cooled")
            log.info("Warm hold exited; audio session restored.")
        }
    }

    /// Gently release a warm-held microphone — exit warm-hold and restore the
    /// audio session — when a surface that warm-held it is dismissed (e.g.
    /// closing Ask Jot after asking a question). No-op unless the mic is
    /// currently warm-held; this is NOT `forceStop` and never tears down an
    /// active recording. Ask is a query, not a dictation to continue, so its
    /// sheet-close releases the held mic rather than leaving the orange
    /// indicator on (Warm Hold §13.2 still governs the normal dictation flow).
    func releaseWarmHold() {
        guard isWarm else { return }
        exitWarmHold()
    }

    private func fullyTeardownEngine() {
        clearActiveSliceRouting()
        if let engine {
            removeTapIfInstalled(from: engine.inputNode)
            engine.stop()
        }
        unsubscribeSystemObservers()
        self.engine = nil
        restoreSession()
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        priorCategory = session.category
        priorMode = session.mode
        priorOptions = session.categoryOptions

        do {
            // 2026-04-21 approved fix for the Action Button `AURemoteIO`
            // invalid-state failure: stop asking the background path to bring
            // up a duplex `.playAndRecord` graph when it only needs microphone
            // input. `.record` keeps the no-DSP `.measurement` mode while
            // avoiding the output leg that was implicated in the `what` trace.
            log.info("configureSession — calling setCategory(.record, .measurement, [.mixWithOthers])")
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.mixWithOthers]
            )
            log.info("configureSession — setCategory OK; now calling setActive(true)")
            try session.setActive(true, options: [])
            log.info("configureSession — setActive(true) OK")
        } catch {
            // Explicit NSError diagnostics. `privacy: .public` so the actual
            // domain + code + description survive syslog privacy filtering —
            // we NEED these values to diagnose on-device session-activation
            // failures. The prior "Session activation failed" string is the
            // NSError's localizedDescription; domain/code tell us WHICH
            // AVAudioSessionErrorCode case fired, which is what separates
            // "nonmixable in background" from "invalid option tuple" from
            // "another app holds the session."
            let ns = error as NSError
            log.error(
                "configureSession FAILED — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) localizedDescription=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)"
            )
            restoreSession()
            throw RecordingError.sessionConfiguration(error)
        }
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()

        // Deactivation and category-restore are logged independently because
        // they have very different severity. `setActive(false)` is the prime
        // suspect for the `com.apple.frontboard.after-life.interrupted`
        // zombie-process bug: if iOS thinks we're still using audio, it holds
        // the process in limbo rather than suspending-then-reaping it, and
        // the next Action Button press surfaces as a cryptic "Operation
        // couldn't be completed." Category restore is cosmetic — if it
        // fails, the next app's session config will overwrite whatever we
        // left anyway. Splitting the logs lets us pattern-match the right
        // one in idevicesyslog. Include NSError `domain` + `code` so we can
        // cross-reference against Apple's `AVFoundationErrorDomain` constants.
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            let ns = error as NSError
            log.error("AVAudioSession.setActive(false) failed — domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public). Session may stay active; process may not suspend cleanly.")
        }

        if let priorCategory, let priorMode, let priorOptions {
            do {
                try session.setCategory(priorCategory, mode: priorMode, options: priorOptions)
            } catch {
                let ns = error as NSError
                log.error("AVAudioSession.setCategory restore failed — domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public).")
            }
        }

        priorCategory = nil
        priorMode = nil
        priorOptions = nil
    }

    /// Aggressively tear down any in-flight recording. Safe to call from any
    /// state; if we're not recording, this still runs the deactivation path
    /// as defense-in-depth (no-op on a non-active session). Never throws;
    /// errors are logged and swallowed.
    ///
    /// This is the hook for scene-disconnect (`scenePhase → .background`)
    /// and hard interruption paths. The user has already decided to leave
    /// the app's foreground — we prioritize a clean AVAudioSession teardown
    /// over preserving half-collected samples, because holding the session
    /// active past scene-disconnect is the suspected cause of the
    /// `com.apple.frontboard.after-life.interrupted` zombie-process state
    /// that breaks subsequent Action Button cold-launches.
    ///
    /// User-initiated cancel from the keyboard's Cancel button (or any
    /// future surface that wants "throw away samples but keep the mic
    /// warm"). Mirrors `stop()` for teardown + warm-hold lifecycle, but
    /// discards the captured samples instead of returning them and
    /// publishes `.idle` instead of `.transcribing` (no pipeline to
    /// flush since we never call into transcription).
    ///
    /// Unlike `forceStop()`, this DOES enter warm-hold if enabled — the
    /// user's mental model is "redo my last dictation," so the mic
    /// should still be hot for the next tap.
    func cancel() async {
        guard !isStopInFlight else {
            log.notice("Cancel skipped — stop already in flight.")
            return
        }
        isStopInFlight = true
        defer { isStopInFlight = false }

        // If a Cancel lands while a pause-teardown Task is still tearing down
        // the streaming session (cancel-from-paused, fast pause→cancel), await
        // it first — otherwise its `tearDownStreamingSession()` races our own
        // below over the same `streamingEngine`/`streamingQueue`. Mirrors the
        // identical guard in `stop()`. After the await our teardown is a clean
        // no-op on already-nil refs.
        if let pending = pauseTeardownTask {
            await pending.value
            pauseTeardownTask = nil
        }

        guard let capture = endActiveSlice() else {
            log.notice("Cancel called with no active slice; nothing to discard.")
            return
        }
        let discardCount = capture.drain().count

        await tearDownStreamingSession()

        isRecording = false
        // Robustness backstop (warm-resume "won't stop" regression): cancel is a
        // terminal — clear inline ownership so no later capture inherits a stale
        // `ownsActiveRecording`.
        ownsActiveRecording = false
        currentAmplitude = nil
        AmplitudeProjection.clear()
        // Cancel-from-paused is valid; clear pause/elapsed state. Cancelled
        // recordings deliberately do NOT touch the warm-hold nudge ring (§4).
        clearPauseState()

        let cooldownDuration = warmHoldCooldownDuration()
        let shouldEnterWarmHold = cooldownDuration > 0
            && engine?.isRunning == true
            && isTapInstalled

        if !shouldEnterWarmHold {
            fullyTeardownEngine()
        }

        // .idle — no pipeline to flush. Keyboard observes this and flips
        // its mic CTA back to idle (Cancel button auto-swaps to Actions).
        publishPipelinePhase(.idle)

        if shouldEnterWarmHold {
            enterWarmHold(duration: cooldownDuration)
        }

        log.info("Recording cancelled; \(discardCount, privacy: .public) samples discarded; warm-hold=\(shouldEnterWarmHold, privacy: .public)")
    }

    /// Discards captured samples silently. If the caller needs the samples,
    /// they must call `stop()` on the happy path, not this.
    func forceStop() {
        // Robustness backstop (warm-resume "won't stop" regression): a force-stop
        // is a terminal teardown — clear inline ownership so no later capture
        // inherits a stale `ownsActiveRecording`. Done before the warm-hold
        // early-return so it covers both the release-warm-mic and the
        // discard/interruption paths.
        ownsActiveRecording = false
        if isWarm {
            exitWarmHold()
            return
        }

        guard !isStopInFlight else {
            log.notice("Force-stop skipped because stop is already in flight.")
            return
        }

        // Discards captured samples — a paused session being force-stopped
        // (scene-disconnect / hard interruption) drops its accumulated audio
        // too. Clear pause/elapsed state so the next recording starts clean.
        clearPauseState()
        clearActiveSliceRouting()
        if let engine {
            removeTapIfInstalled(from: engine.inputNode)
            engine.stop()
        }
        unsubscribeSystemObservers()
        self.engine = nil
        // Streaming teardown is async but `forceStop` is synchronous (called
        // from background-handler closures with limited wallclock). Hand off
        // to a detached Task — the queue is signaled EOS, the drain task
        // exits on its own, the engine is cleaned up post-return. The
        // streaming-preview UX ends abruptly on scene-disconnect; batch
        // path is unaffected. Local refs nil'd here so a subsequent
        // `start()` doesn't observe stale streaming state.
        //
        // Capture-list discipline: the detached Task explicitly captures
        // ONLY the snapshotted local refs (NOT `self`). This avoids extending
        // the singleton's lifetime past app shutdown and avoids racing with
        // a follow-up `start()` that might mutate the streaming fields
        // while the dispatched teardown is mid-flight. `self` mutation has
        // already happened above; the Task is operating on its own snapshots.
        let streamingQueueRef = self.streamingQueue
        let streamingPresenterRef = self.streamingPresenter
        let previewSchedulerRef = self.previewScheduler
        let previewDrainTaskRef = self.previewDrainTask
        self.streamingQueue = nil
        self.previewScheduler = nil
        self.previewDrainTask = nil
        // Terminal path — clear the keyboard "Loading …" affordance synchronously
        // so a force-stop / interruption during a cold load doesn't leave a
        // stale loading label for the next (possibly warm) session.
        endBatchLoadLabelMirror()
        if streamingQueueRef != nil || previewSchedulerRef != nil {
            Task.detached { [streamingQueueRef, streamingPresenterRef, previewSchedulerRef, previewDrainTaskRef] in
                streamingQueueRef?.endOfStream()
                if let scheduler = previewSchedulerRef {
                    // Batch-preview teardown — DISCARD path (no
                    // applyFinalSnapshot): EOS the queue (above) → await the
                    // drain task → `quiesce()` so no in-flight tick publishes a
                    // stale volatile preview AFTER the terminal `.failed` write
                    // → clear the presenter's session token. Mirrors
                    // `tearDownStreamingSession`'s batch branch minus the final
                    // snapshot. Without this, force-stop (scene-disconnect /
                    // hard interruption) leaked the scheduler + presenter ring
                    // and let a zombie tick re-flip the volatile preview.
                    await previewDrainTaskRef?.value
                    await scheduler.quiesce()
                    await MainActor.run { streamingPresenterRef?.clearSession() }
                }
            }
        }
        restoreSession()
        isRecording = false
        currentAmplitude = nil
        AmplitudeProjection.clear()
        // Force-stop discards captured samples — there's no transcription
        // tail to follow, so the pipeline phase has to move directly to a
        // terminal state. `.failed` is correct: this is an emergency stop
        // (scene-disconnect / hard interruption), not a clean user stop.
        // With pipeline phase as the single source of truth, this terminal
        // write is what flips the keyboard's mic CTA off `.recording`.
        publishPipelinePhase(.failed, failureReason: "force-stop")
        log.info("Force-stop complete (scene-disconnect / hard interruption path).")
    }

    /// Protects a user-initiated stop before its async task gets a MainActor turn.
    ///
    /// `ContentView` starts stop/transcribe work in an unstructured task. If the
    /// app backgrounds between the button tap and that task reaching `stop()`,
    /// the lifecycle force-stop path can otherwise tear down `capture` first.
    func markStopInFlight() {
        guard capture != nil || isRecording else { return }
        isStopInFlight = true
    }

    func markPipelineFinished() {
        log.notice("[WARM-HOLD-DEBUG] markPipelineFinished, pendingWarmHoldPublish=\(self.pendingWarmHoldPublish, privacy: .public)")
        isPipelineInFlight = false
        // Robustness backstop (warm-resume "won't stop" regression): clear inline
        // ownership at every pipeline terminal so no LATER capture inherits a
        // stale `ownsActiveRecording` and makes the keyboard Stop bail out of
        // `handleStopRequested` before stopping the mic. Ask sets this true only
        // for the duration of its own active session and clears it on
        // finalize/discard; this runs only after the pipeline has finished (the
        // recording is no longer active), so clearing here is consistent and
        // does not disturb a live Ask recording. `stop()` already read the flag
        // for its warm-hold-nudge classification before this point.
        ownsActiveRecording = false
        if pendingWarmHoldPublish {
            pendingWarmHoldPublish = false
            publishWarmHoldState()
        }
    }

    /// Set `isPipelineInFlight = true` from a non-`stop()` entry point.
    ///
    /// Sole legitimate caller today: `RecordingPipelineDispatch.publishAfterInterruption`
    /// (in `Shared/RecordingPipelineDispatch.swift`). The interrupt-publish
    /// path drains samples via `internalStop` and runs the post-recording
    /// pipeline asynchronously WITHOUT going through `stop()` — so `stop()`'s
    /// own `isPipelineInFlight = true` setter never fires for that path. The
    /// dispatch helper takes ownership of the flag explicitly via this
    /// method, then clears it via `markPipelineFinished()` on every exit.
    ///
    /// Symmetric with `markPipelineFinished()` above. Do NOT call from any
    /// other site — `stop()` already sets the flag, and any other caller
    /// would step on the existing pipeline-in-flight invariant.
    func markPipelineInFlight() {
        isPipelineInFlight = true
    }

    // MARK: - Pipeline phase + heartbeat (v7 auto-paste design)
    //
    // Per `tmp/research-auto-paste-best-design.md` §4.0 + §4.2: pipeline
    // phase is a single-source-of-truth on the RecordingService singleton,
    // projected to the App Group so the keyboard extension can read it
    // without a polling loop. Every phase transition writes the projection +
    // posts a Darwin notification (`pipelinePhaseChanged`) so the keyboard
    // wakes and re-reads. While non-terminal, a 3s heartbeat re-writes the
    // projection's `lastUpdatedAt` so the keyboard can detect a dead writer
    // (the synthetic-`.failed` view inside `PipelinePhaseProjection.read()`).
    //
    // Terminal phases (`.idle` / `.failed`) additionally append to
    // `TerminalSessionLog` so the keyboard's sad-path cleanup can confirm
    // "session finished, nothing further coming" without depending on a
    // single overwriteable field on the projection.

    /// Adopts a session UUID — the URL-scheme handler in `JotApp.swift`
    /// stashes the keyboard's session ID off the `?session=...` query and
    /// calls this before `start()`, so the upcoming projection writes carry
    /// the keyboard's ID. Safe to call from any phase; if a different session
    /// is in flight, the caller is responsible for deciding whether to adopt
    /// (see `handleStopRequested` in `JotApp.swift`).
    func adoptSession(_ id: UUID) {
        currentSessionID = id
    }

    /// Records the recording's start time so it can be carried into the
    /// pipeline-phase projection. Called by the start coordinator alongside
    /// the `.recording` phase transition.
    func setCurrentRecordingStartedAt(_ date: Date?) {
        currentRecordingStartedAt = date
    }

    /// Single helper for every pipeline phase transition. Updates the in-
    /// process `currentPipelinePhase`, writes the App Group projection, posts
    /// `pipelinePhaseChanged`, and manages the heartbeat task lifecycle.
    /// Terminal transitions (`.idle` / `.failed`) also append to
    /// `TerminalSessionLog` so the keyboard's sad-path cleanup can clear
    /// pending state even when the published payload's freshness window has
    /// expired.
    func publishPipelinePhase(
        _ phase: PipelinePhaseProjection.Phase,
        failureReason: String? = nil
    ) {
        let priorPhase = currentPipelinePhase
        let priorSessionID = currentSessionID
        currentPipelinePhase = phase

        let isTerminal = (phase == .idle || phase == .failed)
        let projection: PipelinePhaseProjection

        if isTerminal {
            // Append to TerminalSessionLog BEFORE the projection write so a
            // keyboard that wakes on `pipelinePhaseChanged` and reads the
            // projection can ALSO read the up-to-date log without a second
            // post race.
            //
            // Only append a record if we actually owned a non-idle session —
            // otherwise we'd write spurious records on idle→idle no-ops.
            if priorPhase != .idle, let priorOwner = priorSessionID {
                // `.idle` is reached only via successful publish; `.failed`
                // is pre-publish failure. The `hadPublish` bit is retained
                // for diagnostic logging only — the keyboard's sad-path
                // cleanup uses UUID match alone (per design Q2).
                let hadPublish = (phase == .idle)
                TerminalSessionLog.append(
                    TerminalSessionRecord(
                        sessionID: priorOwner,
                        finishedAt: Date(),
                        hadPublish: hadPublish
                    )
                )
            }
            projection = PipelinePhaseProjection(
                phase: phase,
                sessionID: nil,
                recordingStartedAt: nil,
                lastUpdatedAt: Date(),
                failureReason: failureReason
            )
            currentSessionID = nil
            currentRecordingStartedAt = nil
        } else {
            projection = PipelinePhaseProjection(
                phase: phase,
                sessionID: currentSessionID,
                recordingStartedAt: currentRecordingStartedAt,
                lastUpdatedAt: Date(),
                failureReason: nil
            )
        }

        PipelinePhaseProjection.write(projection)
        CrossProcessNotification.post(name: CrossProcessNotification.pipelinePhaseChanged)

        if isTerminal {
            stopHeartbeat()
        } else {
            startHeartbeatIfNeeded()
        }
    }

    private var heartbeatTask: Task<Void, Never>?

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(PipelinePhaseProjection.heartbeatInterval)
                    )
                } catch {
                    // Cancellation. Explicit return so we don't accidentally
                    // swallow other errors — `Task.sleep` only throws
                    // `CancellationError`.
                    return
                }
                guard let self else { return }
                if self.currentPipelinePhase == .idle
                    || self.currentPipelinePhase == .failed {
                    return
                }
                self.republishHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Re-writes the projection with the same phase + sessionID + a fresh
    /// `lastUpdatedAt`, then posts `pipelinePhaseChanged`. The Darwin post is
    /// load-bearing: the keyboard's bounded stale-deadline task arms off the
    /// projection's `lastUpdatedAt`; without a wakeup it never re-arms,
    /// defeating the dead-writer recovery design.
    private func republishHeartbeat() {
        guard currentPipelinePhase != .idle, currentPipelinePhase != .failed else {
            return
        }
        // Paused-clock freeze (§10.4). The keyboard derives the frozen elapsed
        // as `projection.lastUpdatedAt − recordingStartedAt`. Each heartbeat
        // advances `lastUpdatedAt` by `heartbeatInterval`, so re-publishing the
        // SAME frozen anchor would make that difference grow ~3s per tick —
        // the "frozen" keyboard clock would jump forward every heartbeat. While
        // paused, re-back-date the anchor against the fresh `lastUpdatedAt` so
        // `lastUpdatedAt − recordingStartedAt` stays pinned to the accumulated
        // active-time total. (The in-app hero is unaffected — it reads
        // `currentRecordingStartedAt` directly and freezes via `isPaused`.)
        if currentPipelinePhase == .paused {
            currentRecordingStartedAt = pausedAwareStartedAt()
        }
        PipelinePhaseProjection.write(
            PipelinePhaseProjection(
                phase: currentPipelinePhase,
                sessionID: currentSessionID,
                recordingStartedAt: currentRecordingStartedAt,
                lastUpdatedAt: Date(),
                failureReason: nil
            )
        )
        CrossProcessNotification.post(name: CrossProcessNotification.pipelinePhaseChanged)
    }

    // MARK: - System observers (best-practices §2.3, §2.4, §2.5)

    private func subscribeSystemObservers(engine: AVAudioEngine) {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // Interruption: phone call, Siri, other .playback session. Pre-extract
        // the Sendable `typeRaw` before hopping to MainActor so we don't
        // capture the non-Sendable Notification across the boundary.
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw)
            }
        }

        // Route change: AirPods disconnect, wired headphones pulled, etc.
        // Only `.oldDeviceUnavailable` warrants stopping — the input device
        // we were using is gone, and silent fallback to the internal mic
        // would be a WER disaster the user can't debug.
        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        // Engine configuration change: AirPlay handoff, FaceTime starting,
        // system picking a new sample rate. Our tap would keep firing against
        // a stale input format and CaptureContext would drop every buffer.
        // Stop cleanly; user presses Record again to rebuild.
        let engineConfig = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigChange()
            }
        }

        // Settings kill-switch: flipping warm hold off during the warm window
        // must cool the engine immediately. Filter to the App Group defaults
        // instance so unrelated process defaults changes do not poke the state
        // machine.
        let warmHoldDefaults = center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: AppGroup.defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWarmHoldDefaultsChange()
            }
        }

        observers = [interruption, route, engineConfig, warmHoldDefaults]
    }

    private func unsubscribeSystemObservers() {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func handleInterruption(typeRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isWarm {
                // The production warm-hold yield: dropping `.mixWithOthers` at
                // warm entry makes the idle session non-mixable, so another app
                // starting playback delivers this interruption. Cooling here
                // (`restoreSession` → `setActive(false, .notifyOthersOnDeactivation)`)
                // is what hands the mic + route back to that app.
                log.notice("warm-hold yielded mic to another app (interruption began)")
                exitWarmHold()
            } else {
                log.notice("Audio session interrupted — stopping recording")
                internalStop(reason: "interruption")
            }
        case .ended:
            // Per spec: do not auto-resume. User re-presses Record.
            // `.shouldResume` only advises us; we still defer to the user.
            break
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            if isWarm {
                log.notice("Audio route device went away during warm hold — cooling engine")
                exitWarmHold()
            } else {
                log.notice("Audio route device went away — stopping recording")
                internalStop(reason: "route change")
            }
        }
        // `.newDeviceAvailable` and friends are ignored: iOS already did the
        // right routing, and interrupting capture on every AirPod reconnect
        // would feel broken.
    }

    private func handleEngineConfigChange() {
        if isWarm {
            log.notice("Engine configuration changed during warm hold — cooling engine")
            exitWarmHold()
        } else {
            log.notice("Engine configuration changed — stopping recording")
            internalStop(reason: "engine config change")
        }
    }

    private func handleWarmHoldDefaultsChange() {
        guard isWarm, warmHoldCooldownDuration() <= 0 else { return }
        log.notice("Warm hold disabled in Settings — cooling engine")
        exitWarmHold()
    }

    // MARK: - Warm-hold switching nudge (UX-overhaul round 2 §4 / R10 / R16)
    //
    // After a CLEAN stop (this is the only site that appends, per R10), record
    // the `(startedAt, stoppedAt)` pair to a small App-Group ring buffer. Then
    // compute the streak of consecutive "qualifying returns" — a return where
    // `start[i] − stop[i−1] ≤ min(W, 120)` (W = live warm-hold duration). When
    // the streak reaches 3 AND warm hold is off AND the user hasn't permanently
    // suppressed the nudge, set the App-Group `warmHoldNudgeShouldShow` flag and
    // post `warmHoldNudgeChanged`. The keyboard process can't run this math
    // (R10b), so the app writes the boolean projection + Darwin post; the
    // keyboard renders off the boolean and writes back the two actions.

    /// One stop event in the ring buffer. `Codable` so the whole `[Entry]`
    /// serializes to the `AppGroup.captureStopRing` `Data` slot. Keyed dedupe
    /// uses `sessionID` (R10): a stop that re-fires for the same session must
    /// not double-append.
    struct CaptureStopEntry: Codable, Sendable, Equatable {
        let startedAt: Date
        let stoppedAt: Date
        let sessionID: UUID?
    }

    /// Number of recent stop pairs retained (~4 per contract). The streak math
    /// only ever needs the last few; a fixed cap keeps the App-Group write
    /// bounded and makes the streak self-expiring across app kills (R16).
    private static let captureStopRingCapacity = 4

    /// Streak threshold: fire the nudge at 3 consecutive qualifying returns
    /// (≈4 record-and-bounce recordings in tight succession) — §4.
    private static let warmHoldNudgeStreakThreshold = 3

    /// Hard clamp on the qualifying-return window (R16): even if the user has a
    /// stale 5-min warm-hold duration set on a disabled feature, the detection
    /// window can't exceed 120s — otherwise slow-motion streaks get manufactured.
    private static let warmHoldNudgeWindowClamp: TimeInterval = 120

    /// Append the just-finished clean stop to the ring buffer and re-evaluate
    /// the switching-nudge streak (§4 / R10 / R16). Called ONLY from the clean
    /// `stop()` site, after `endActiveSlice()`. Cancelled + interruption-
    /// recovered stops deliberately don't reach here.
    private func detectWarmHoldSwitchingNudge(
        startedAt: Date,
        stoppedAt: Date,
        sessionID: UUID?
    ) {
        var ring = Self.loadCaptureStopRing()

        // Dedupe on session ID (R10): if the last entry already carries this
        // session's ID, a duplicate stop fired — don't double-append.
        if let sessionID, let last = ring.last, last.sessionID == sessionID {
            log.notice("[WARM-HOLD-NUDGE] duplicate stop for session \(sessionID, privacy: .public) — skipping ring append")
            return
        }

        ring.append(
            CaptureStopEntry(startedAt: startedAt, stoppedAt: stoppedAt, sessionID: sessionID)
        )
        if ring.count > Self.captureStopRingCapacity {
            ring.removeFirst(ring.count - Self.captureStopRingCapacity)
        }
        Self.saveCaptureStopRing(ring)

        // The nudge is an OFF-state affordance — meaningless when warm hold is
        // already on, and silenced once the user permanently dismissed it.
        guard !AppGroup.warmHoldEnabled else {
            log.notice("[WARM-HOLD-NUDGE] warm hold already on — not evaluating")
            return
        }
        guard !AppGroup.warmHoldNudgeSuppressed else {
            log.notice("[WARM-HOLD-NUDGE] permanently suppressed — not evaluating")
            return
        }

        // Window = min(live W, 120) (R16). W is the user's live picker value.
        let window = min(AppGroup.warmHoldDurationSeconds, Self.warmHoldNudgeWindowClamp)

        // Streak derived from the timestamp buffer (R16): walk newest→oldest,
        // counting consecutive qualifying returns. A qualifying return is a
        // start within `window` of the PREVIOUS stop.
        let streak = Self.qualifyingReturnStreak(ring: ring, window: window)
        log.notice("[WARM-HOLD-NUDGE] streak=\(streak, privacy: .public) window=\(window, privacy: .public) ringCount=\(ring.count, privacy: .public)")

        if streak >= Self.warmHoldNudgeStreakThreshold {
            // Re-shows on every qualifying burst (§4) — set the flag even if it
            // was previously auto-hidden (passive ignore ≠ suppression). The
            // keyboard/hero render off this boolean projection.
            AppGroup.warmHoldNudgeShouldShow = true
            CrossProcessNotification.post(name: CrossProcessNotification.warmHoldNudgeChanged)
            log.notice("[WARM-HOLD-NUDGE] threshold reached — nudge flagged + posted")
        }
    }

    /// Count consecutive qualifying returns from the newest pair backward.
    /// A pair qualifies when its `startedAt` is within `window` of the
    /// immediately-preceding pair's `stoppedAt`. A gap > window resets (a real
    /// break — not the record-and-bounce pattern). Static + pure so it's
    /// trivially testable.
    static func qualifyingReturnStreak(ring: [CaptureStopEntry], window: TimeInterval) -> Int {
        guard ring.count >= 2 else { return 0 }
        var streak = 0
        var i = ring.count - 1
        while i >= 1 {
            let gap = ring[i].startedAt.timeIntervalSince(ring[i - 1].stoppedAt)
            if gap <= window {
                streak += 1
                i -= 1
            } else {
                break
            }
        }
        return streak
    }

    /// Decode the ring from the App-Group `Data` slot; empty on miss / decode
    /// failure (self-healing).
    private static func loadCaptureStopRing() -> [CaptureStopEntry] {
        guard let data = AppGroup.captureStopRing else { return [] }
        return (try? Self.ringDecoder.decode([CaptureStopEntry].self, from: data)) ?? []
    }

    private static func saveCaptureStopRing(_ ring: [CaptureStopEntry]) {
        guard let data = try? Self.ringEncoder.encode(ring) else { return }
        AppGroup.captureStopRing = data
    }

    private static let ringEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let ringDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Tear down the engine and session AND auto-drain captured samples
    /// through the post-recording pipeline. Per `tmp/research-warm-resume-design.md`
    /// §6.1 (Cut A bug-fix bundle): the prior shape "retained samples for
    /// drain" so a later in-app `stop()` could pick them up — but the
    /// keyboard / intent surfaces had already given up on the recording by
    /// then, so partial captures were effectively dropped. The new shape
    /// runs the post-recording tail (transcribe → publish → ledger) asynchronously
    /// via `RecordingPipelineDispatch.publishAfterInterruption` so EVERY entry
    /// path recovers from a mid-recording interrupt.
    ///
    /// **Behavior change vs prior shape:** the in-app "stop button works
    /// after interruption" recovery path is REPLACED by automatic dispatch.
    /// Acknowledged in design doc §6.1: "samples are retained for in-app drain
    /// but lost for keyboard / intent paths" today; with this change every
    /// path benefits, but a user looking at the in-app UI when the
    /// interruption fires no longer gets the manual stop-and-publish flow —
    /// the publish has already happened automatically by the time they tap.
    private func internalStop(reason: String) {
        if isWarm {
            log.notice("Internal stop requested during warm hold — cooling engine")
            exitWarmHold()
            return
        }

        guard isRecording, let engine else { return }

        // ===== Snapshot phase =====
        //
        // Capture every piece of state the dispatch helper needs BEFORE any
        // mutation. The terminal `publishPipelinePhase(.failed, ...)` below
        // clears `currentSessionID` / `currentRecordingStartedAt` (terminal
        // branch of the helper), so this snapshot is load-bearing — without
        // it the dispatch helper would lose the session-ID hand-off the
        // keyboard's `PendingPasteSession.id` matches against. Per
        // cut-A-reviewer's BLOCKER #4 closure.
        let snapshotSessionID = currentSessionID
        let snapshotStartedAt = currentRecordingStartedAt ?? Date()
        let snapshotCapture = endActiveSlice()
        // Ownership snapshot for the dispatch-phase guard below. Taken
        // synchronously here (with the other snapshots) so the owning
        // surface's own async teardown — which clears the flag — can't race
        // the fire-and-forget dispatch Task into reading a stale `false`.
        let snapshotOwned = ownsActiveRecording

        // Interruption-while-paused routes here (§10.7): finalize whatever was
        // accumulated rather than silently staying paused through a call that
        // seized the mic. Clear pause/elapsed state so the dispatched pipeline
        // and the next recording start clean. The accumulated samples are in
        // `snapshotCapture` (the open slice survived the pause); they drain via
        // the dispatch phase below.
        clearPauseState()

        // ===== Teardown phase =====
        removeTapIfInstalled(from: engine.inputNode)
        engine.stop()
        unsubscribeSystemObservers()
        self.engine = nil

        // Streaming teardown — same fire-and-forget shape as `forceStop`.
        // `internalStop` is synchronous (interrupt-observer path) so we
        // can't `await tearDownStreamingSession()` inline. Hand off to a
        // detached Task that signals EOS, awaits drain, releases the
        // engine. Capture-list discipline: the detached Task captures ONLY
        // the snapshotted local refs (NOT `self`). Same rationale as
        // `forceStop`'s identical block above. Streaming-preview UX ends
        // abruptly on interruption;
        // batch path is unaffected (the dispatch phase below still runs
        // through `RecordingPipelineDispatch`).
        let streamingQueueRef = self.streamingQueue
        let streamingPresenterRef = self.streamingPresenter
        let previewSchedulerRef = self.previewScheduler
        let previewDrainTaskRef = self.previewDrainTask
        self.streamingQueue = nil
        self.previewScheduler = nil
        self.previewDrainTask = nil
        // Terminal path — clear the keyboard "Loading …" affordance synchronously
        // so a force-stop / interruption during a cold load doesn't leave a
        // stale loading label for the next (possibly warm) session.
        endBatchLoadLabelMirror()
        if streamingQueueRef != nil || previewSchedulerRef != nil {
            Task.detached { [streamingQueueRef, streamingPresenterRef, previewSchedulerRef, previewDrainTaskRef] in
                streamingQueueRef?.endOfStream()
                if let scheduler = previewSchedulerRef {
                    // Batch-preview teardown — DISCARD path (no
                    // applyFinalSnapshot): EOS → await drain → `quiesce()` so no
                    // in-flight tick re-publishes a stale volatile preview after
                    // the terminal `.failed` → clear the presenter token. Same
                    // shape as `forceStop`'s block; the dispatch phase below
                    // still finalizes the captured audio via the batch stop-pass.
                    await previewDrainTaskRef?.value
                    await scheduler.quiesce()
                    await MainActor.run { streamingPresenterRef?.clearSession() }
                }
            }
        }

        restoreSession()
        isRecording = false
        currentAmplitude = nil
        AmplitudeProjection.clear()
        // Publish a terminal `.failed` so the keyboard's mic CTA flips off
        // `.recording` immediately. With pipeline phase as the single source
        // of truth, omitting this leaves the keyboard observing
        // `phase == .recording` until the 30s heartbeat-stale path fires —
        // a multi-second window where every mic tap routes to "stop" instead
        // of opening the app for a fresh recording. The dispatch helper
        // below re-arms the pipeline by calling `adoptSession(_:)` on the
        // SNAPSHOT session ID and then publishing `.processing → ... →
        // .idle`, so the keyboard re-observes proof of life on the same
        // session UUID. The trade-off acknowledged here: under interruption
        // the keyboard's pending-paste may be cleaned by the terminal-log
        // entry that this `.failed` write inserts; auto-paste-after-
        // interruption becomes best-effort, but the keyboard's mic state
        // stays correct.
        publishPipelinePhase(.failed, failureReason: "interruption")

        // ===== Dispatch phase =====
        //
        // Fire-and-forget. Safe to dispatch after internalStop returns because
        // `TranscriptionService` runs inference on a `[Float]` in memory and
        // does NOT re-grab `AVAudioSession` (verified by grep across
        // `App/Transcription/` — 0 `AVAudioSession` references). So the
        // dispatched Task cannot race iOS's interruption-handshake teardown.
        //
        // The drain runs OFF MainActor via `drainAsync()` so the audio-thread
        // bounded wait (up to 250ms catastrophic-only backstop) doesn't block
        // the MainActor. The dispatch helper then hops back to MainActor for
        // controller / pipeline calls.
        // OWNED (in-app inline) captures — Ask's question mic and the rewrite
        // picker's voice prompt — must NEVER route through the interruption
        // publish: `completeEndOfRecording(transient: false)` would SAVE the
        // utterance as a Transcript and overwrite the clipboard, but an owned
        // capture is a query/instruction whose normal stop path never saves,
        // never publishes, never pastes. Drop the audio instead (adversarial
        // review finding 2 — this also closes the identical pre-existing hole
        // for an interrupted Ask question). Bookkeeping stays consistent
        // without the dispatch helper: the terminal `.failed("interruption")`
        // was already published above (keyboard CTA + terminal log handled),
        // and the helper's only other work is the pipeline-in-flight latch it
        // takes and releases around its own run — never entered, nothing to
        // release. Ownership itself is cleared by the owning surface's
        // terminal (its next `stop()` throws `.notRunning` → its own error
        // UX, e.g. the picker's "Didn't catch that — try again."), with
        // `markPipelineFinished()` as the standing backstop.
        //
        // UNOWNED captures (FAB / Action Button / keyboard dictations) keep
        // the publish-after-interruption behavior exactly — a real dictation
        // interrupted by a call should still deliver.
        if snapshotOwned {
            log.notice("Internal stop (\(reason, privacy: .public)) — owned in-app capture; dropping partial publish (no save, no clipboard)")
            return
        }
        guard let snapshotCapture else {
            log.info("Internal stop (\(reason, privacy: .public)) — no capture to drain; skipping dispatch")
            return
        }
        log.info("Internal stop (\(reason, privacy: .public)) — dispatching partial publish")
        Task { @MainActor in
            let samples = await snapshotCapture.drainAsync()
            await RecordingPipelineDispatch.publishAfterInterruption(
                samples: samples,
                sessionID: snapshotSessionID,
                startedAt: snapshotStartedAt
            )
        }
    }

    // MARK: - Target format

    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1
    static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
}

/// Thread-safe hand-off between the long-lived audio tap and the current
/// dictation slice. The tap captures this stable object once; `start()` /
/// `stop()` swap per-slice capture state behind the lock.
private final class AudioTapRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var isCapturingSlice: Bool = false
    private var capture: CaptureContext?
    private var streamingQueue: StreamingBufferQueue?

    func beginSlice(capture: CaptureContext, streamingQueue: StreamingBufferQueue) {
        lock.lock()
        self.capture = capture
        self.streamingQueue = streamingQueue
        isCapturingSlice = true
        lock.unlock()
    }

    @discardableResult
    func endSlice() -> CaptureContext? {
        lock.lock()
        isCapturingSlice = false
        let activeCapture = capture
        capture = nil
        streamingQueue = nil
        lock.unlock()
        return activeCapture
    }

    /// Pause routing WITHOUT ending the slice (UX-overhaul round 2 §10.1).
    /// Flips `isCapturingSlice` to `false` so `route(_:)` drops buffers (same
    /// zero-per-buffer-work path as warm-hold idle), but KEEPS `capture` +
    /// `streamingQueue` so the accumulated samples and the live presenter
    /// survive the pause. `resumeSlice()` flips capture back on against the
    /// SAME `CaptureContext`, so post-resume buffers concatenate naturally —
    /// the pause gap is simply absent from the audio, no sample stitching.
    func pauseSlice() {
        lock.lock()
        isCapturingSlice = false
        lock.unlock()
    }

    /// Resume routing against the already-open slice (UX-overhaul round 2
    /// §10.1). Re-arms `isCapturingSlice` so `route(_:)` ingests buffers into
    /// the SAME `capture` the pause left in place. The caller is responsible
    /// for swapping in a fresh `streamingQueue` (a new streaming session feeds
    /// post-resume partials as `prefix + newPartial`); pass it here so the tap
    /// fan-out targets the new queue. Passing `nil` keeps the existing queue.
    func resumeSlice(streamingQueue: StreamingBufferQueue?) {
        lock.lock()
        if let streamingQueue {
            self.streamingQueue = streamingQueue
        }
        isCapturingSlice = true
        lock.unlock()
    }

    /// Returns `false` when warm-held and idle so the tap block can do
    /// literally no per-buffer work beyond the routing check.
    func route(_ pcm: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        guard isCapturingSlice, let capture else {
            lock.unlock()
            return false
        }
        let streamingQueue = self.streamingQueue
        lock.unlock()

        let convertedSamples = capture.ingest(pcm)
        if let convertedSamples, let streamingQueue {
            streamingQueue.push(convertedSamples)
        }
        return true
    }
}

/// One-shot gate for the tap-callback diagnostic log.
///
/// Reference type so the `@Sendable` tap closure can capture it by value (the
/// reference) while still mutating the `fired` flag through the lock. The tap
/// block is invoked serially per AVAudioEngine's contract, so the lock here is
/// defense-in-depth — it also makes the class legitimately `Sendable` without
/// the `@unchecked` escape hatch being required for correctness.
///
/// This exists purely to bound the diagnostic `log.debug` at the top of the
/// tap closure to a single invocation — we want the queue identity confirmed
/// on-device once, without emitting per-buffer (~12/sec at 4096@48kHz) log
/// traffic on the audio-render thread for the lifetime of the recording.
/// Remove alongside the diagnostic once the fix is verified on-device.
private final class TapOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns `true` exactly once; every subsequent call returns `false`.
    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Rate-limiter for audio-thread → MainActor amplitude updates.
///
/// The tap fires at the hardware buffer cadence: ~12 Hz at 4096 frames @
/// 48 kHz, but much higher at smaller buffers some route changes can install.
/// Dispatching a MainActor task per buffer would flood the run loop and burn
/// CPU on Observation dirty-tracking for a viz the user only sees updated at
/// screen refresh. ~30 Hz is plenty for a VU-style waveform and stays under
/// the display refresh rate we care about.
///
/// Serialization: the AVAudioEngine tap contract invokes the block serially,
/// so in practice contention is zero — the lock is defense-in-depth and also
/// makes the class legitimately Sendable without `@unchecked` being required
/// for correctness. `DispatchTime.now().uptimeNanoseconds` is nonblocking and
/// real-time-safe (it's a mach_absolute_time read).
private final class AmplitudeGate: @unchecked Sendable {
    private let intervalNS: UInt64
    private let lock = NSLock()
    private var lastFiredNS: UInt64 = 0

    init(intervalMS: Double) {
        self.intervalNS = UInt64(intervalMS * 1_000_000)
    }

    /// Returns `true` if at least `intervalMS` has elapsed since the last
    /// `true` return. Updates the internal timestamp on a `true` return so the
    /// caller is the sole source of truth for rate.
    func shouldFire() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        if now &- lastFiredNS >= intervalNS {
            lastFiredNS = now
            return true
        }
        return false
    }
}

/// Compute a display-ready normalized amplitude (0.0 – 1.0) from a raw
/// hardware PCM buffer.
///
/// Returns `nil` when the buffer isn't Float32 non-interleaved (the format
/// AVAudioEngine input delivers on iOS) — the caller skips publication and
/// the viz simply won't update for that frame.
///
/// **Scaling rationale.** Raw linear RMS for real speech sits around
/// 0.03 – 0.2 (−30 to −14 dBFS). Returning raw RMS would leave the pill's
/// waveform barely moving. We apply a mild compression — `sqrt(rms × 4)`
/// clamped to [0, 1] — so that noise floor stays visibly low while normal
/// conversational speech covers the middle-to-upper range. This is simpler
/// than a full dBFS → [0, 1] mapping and gives a VU-meter feel without
/// needing the view layer to understand dB scale.
///
/// Called on the audio-render thread — keep this allocation-free and
/// lock-free. The one buffer read is a pointer walk over `frameLength`
/// floats; no heap allocation, no Objective-C messaging on the hot path.
private func normalizedAmplitude(_ pcm: AVAudioPCMBuffer) -> Float? {
    guard let channelData = pcm.floatChannelData else { return nil }
    let frameLength = Int(pcm.frameLength)
    guard frameLength > 0 else { return 0 }

    let samples = channelData[0]
    var sumSquares: Float = 0
    for i in 0..<frameLength {
        let s = samples[i]
        sumSquares += s * s
    }
    let rms = sqrt(sumSquares / Float(frameLength))
    // Compression curve: sqrt(rms * 4) maps
    //   ambient noise 0.005 → 0.14
    //   quiet speech  0.03  → 0.35
    //   normal speech 0.1   → 0.63
    //   loud speech   0.2   → 0.89
    // Clamped to [0, 1] so the view layer has a bounded contract.
    return min(1.0, max(0.0, sqrt(rms * 4.0)))
}

/// Owns the per-capture converter and sample buffer. Lives off the MainActor
/// so the audio tap can convert + append without hopping.
///
/// ## `@unchecked Sendable` invariant
///
/// `os_unfair_lock` is allocated at a stable heap address (must NEVER be
/// value-copied — copying the lock is documented undefined behavior; copying
/// the pointer is fine). All mutable state (`storage`, `inflightCallbacks`,
/// `drainSignal`) is guarded by that one lock. The class is `@unchecked Sendable`
/// because every mutation goes through the lock, but Swift's region-based
/// isolation can't prove that without the explicit annotation.
///
/// ## Race fix (Cut A §6.2)
///
/// The previous implementation used `NSLock` and a single `drain()` that
/// swapped storage. The race: a tap callback could enter `ingest`, run
/// `convertSync(pcm)` for ~hundreds of µs, then commit to storage — but if
/// `drain()` was called between callback entry and the storage commit, the
/// converted samples would be missed. (This is NOT a buffer-lifetime issue
/// — Apple's `AVAudioPCMBuffer` is materialized into a Swift `[Float]` value
/// inside `ingest` BEFORE the storage-append, so the underlying buffer can
/// be reused freely. The bug is purely a serialization-with-drain issue.)
///
/// The fix: a 2-phase serialized drain.
///   1. Tap callback enters under lock; if a drain is in progress (signaled
///      by `drainSignal != nil`), bail without incrementing the counter or
///      converting. Otherwise increment `inflightCallbacks` and release the
///      lock for conversion work.
///   2. After conversion (which is lock-free), the success path takes the
///      lock once and atomically: appends samples, decrements the counter,
///      and signals the drain semaphore if the counter reached zero. Each
///      early-return path likewise decrements + signals (but does NOT
///      append) under the same lock.
///   3. `drainSync()` installs `drainSignal` under lock, then either takes
///      storage immediately (if `inflightCallbacks == 0`) or waits up to
///      250ms for the last in-flight callback to finish. The 250ms is a
///      catastrophic-only backstop (kernel-audio-thread wedge); steady-state
///      cost is microseconds — `inflightCallbacks` is 0 or 1, and a tap
///      callback's conversion runs sub-millisecond on A-series silicon.
///
/// ## Drain API
///
/// Two flavors are exposed:
///   - `drain()` is the synchronous wrapper preserved for the existing
///     in-scope callers (`stop()`'s cold + warm branches, `forceStop`). Safe
///     to call from MainActor in steady state because the wait is bounded
///     by one buffer cadence (~1ms typical, 250ms catastrophic backstop).
///   - `drainAsync()` runs `drainSync()` on a detached Task so the wait
///     never blocks MainActor. Used by `internalStop`'s interrupt-publish
///     dispatch, where audio-thread state is unusual at drain time and the
///     wait is more likely to be non-trivial.
private final class CaptureContext: @unchecked Sendable {
    /// Heap-allocated `os_unfair_lock` at a stable address. NEVER copy the
    /// lock value — only ever address it through this pointer. Apple's docs
    /// are explicit that lock-value copies produce undefined behavior. The
    /// pointer itself can be copied freely; Swift's `let` ensures we never
    /// reassign the pointer.
    private let lock: os_unfair_lock_t

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let target: AVAudioFormat
    private let log: Logger

    /// All three guarded by `lock`.
    private var storage: [Float] = []
    private var inflightCallbacks: Int = 0
    private var drainSignal: DispatchSemaphore?

    /// Catastrophic-only backstop. In steady state `inflightCallbacks` is 0
    /// or 1 and the in-flight callback's conversion completes sub-millisecond.
    /// 250ms is twice the longest plausible hardware buffer period — only
    /// fires on a kernel-audio-thread wedge, where the user has bigger
    /// problems than UI jank.
    private static let drainBackstopMS: Int = 250

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, target: AVAudioFormat, log: Logger) {
        self.lock = os_unfair_lock_t.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        self.converter = converter
        self.inputFormat = inputFormat
        self.target = target
        self.log = log
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Convert a hardware-format PCM buffer to 16 kHz mono Float32 samples,
    /// append them to the per-recording storage, and ALSO return them to the
    /// caller for live-preview fan-out (dual-model-streaming).
    ///
    /// Returns `nil` on every early-return / failure path (drain-in-progress,
    /// format mismatch, allocation failure, conversion error, missing channel
    /// data) so the caller can distinguish "no samples this callback" from
    /// "empty array of samples." `@discardableResult` because the historical
    /// batch path (the `installTap` tap closure) ignores the return value;
    /// only the live-preview fan-out actually consumes it.
    ///
    /// **Co-owned with the dual-model-streaming wave.** Cut A owns the §6.2
    /// race-fix invariants on `storage` / `inflightCallbacks` / `drainSignal`;
    /// dual-model-streaming owns the live-preview consumer of the return value
    /// (wired from `start()`'s `installTap` block). Changes to Phase 3
    /// ordering, the lock invariants, or the early-return semantics must be
    /// re-verified against both waves' contracts.
    @discardableResult
    func ingest(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        // ===== Phase 1: gate + counter increment under lock =====
        os_unfair_lock_lock(lock)
        if drainSignal != nil {
            // A drain is in progress and has installed its signal. By
            // definition we're in the post-removeTap window where late
            // callbacks may still arrive (Apple's tap contract: removeTap
            // does not synchronously block in-flight callbacks). Refuse
            // this callback's samples — the drainer has already committed
            // to "no further samples will join storage." Returning `nil`
            // also tells live-preview fan-out callers to skip this callback;
            // the drain has already taken the recording.
            os_unfair_lock_unlock(lock)
            return nil
        }
        inflightCallbacks += 1
        os_unfair_lock_unlock(lock)

        // ===== Phase 2: conversion (lock-free) =====
        //
        // Multiple early-return paths possible. Each MUST decrement the
        // inflight counter and signal the drain semaphore if the counter
        // reaches zero. Localized in this closure so we never duplicate the
        // lock/unlock pattern (which is exactly the kind of foot-gun a
        // future maintainer would forget).
        let decrementAndSignal: () -> Void = { [self] in
            os_unfair_lock_lock(lock)
            inflightCallbacks -= 1
            if inflightCallbacks == 0, let signal = drainSignal {
                signal.signal()
            }
            os_unfair_lock_unlock(lock)
        }

        // Drop buffers whose format disagrees with the converter — a route
        // change mid-recording would trigger this, and the engine-config
        // observer on the service will tear down the tap shortly.
        guard pcm.format == inputFormat else {
            decrementAndSignal()
            return nil
        }

        let ratio = target.sampleRate / pcm.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: estimatedFrames) else {
            decrementAndSignal()
            return nil
        }

        let supplied = Mutex<Bool>(false)
        var err: NSError?
        let status = converter.convert(to: outBuffer, error: &err) { _, inputStatus in
            let firstCall = supplied.withLock { value -> Bool in
                if value { return false }
                value = true
                return true
            }
            if !firstCall {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return pcm
        }

        switch status {
        case .error:
            log.error("Conversion error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
            decrementAndSignal()
            return nil
        case .haveData, .inputRanDry, .endOfStream:
            break
        @unknown default:
            decrementAndSignal()
            return nil
        }

        guard let channelData = outBuffer.floatChannelData else {
            decrementAndSignal()
            return nil
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))

        // ===== Phase 3: success path — append + decrement + signal atomically =====
        //
        // Single critical section preserves the invariant: by the time
        // `inflightCallbacks` reaches 0 (which signals the drain semaphore),
        // all converted samples for this callback are already in storage.
        // A drainSync call that wakes from the semaphore wait will see
        // every sample.
        os_unfair_lock_lock(lock)
        storage.append(contentsOf: samples)
        inflightCallbacks -= 1
        if inflightCallbacks == 0, let signal = drainSignal {
            signal.signal()
        }
        os_unfair_lock_unlock(lock)

        // Return the converted samples so live-preview fan-out callers
        // (dual-model-streaming) can consume them without paying a second
        // `AVAudioConverter.convert` pass on the audio thread. Pure value-
        // type return; no shared state with `storage` (storage holds a
        // separate copy via `append(contentsOf:)`).
        return samples
    }

    /// Synchronous drain. Safe to call from MainActor in steady-state /
    /// happy-path stop() flows: `inflightCallbacks` is 0 or ~1, and a tap
    /// callback's conversion runs sub-millisecond on A-series silicon.
    /// Bounded at 250ms on pathological audio-thread wedge; ~µs in steady
    /// state. Use `drainAsync()` from interrupt paths where the audio-thread
    /// state is unusual at drain time.
    func drain() -> [Float] {
        drainSync()
    }

    /// Off-MainActor drain. Used by `RecordingService.internalStop`'s
    /// interrupt-publish dispatch, where audio-thread state at drain time
    /// is more likely to be unusual (an interruption just fired) and we
    /// don't want even a 1-ms wait on MainActor.
    func drainAsync() async -> [Float] {
        await Task.detached { [self] in self.drainSync() }.value
    }

    private func drainSync() -> [Float] {
        // Install the drain signal under lock. Any tap callback that hasn't
        // yet entered Phase 1 will see `drainSignal != nil` and bail.
        // Callbacks that ARE in flight (Phase 2 conversion) have already
        // incremented `inflightCallbacks`; we wait on the semaphore for
        // them to reach Phase 3 and decrement back to zero.
        let signal = DispatchSemaphore(value: 0)
        os_unfair_lock_lock(lock)
        let needsWait = inflightCallbacks > 0
        drainSignal = signal
        os_unfair_lock_unlock(lock)

        if needsWait {
            // Catastrophic-only backstop. If a tap callback truly wedged,
            // we'd rather lose its samples than deadlock the user's stop
            // path. semaphore.wait returns `.success` on signal,
            // `.timedOut` on the deadline; we ignore the result either way
            // and read whatever's in storage.
            _ = signal.wait(timeout: .now() + .milliseconds(Self.drainBackstopMS))
        }

        os_unfair_lock_lock(lock)
        let out = storage
        storage = []
        // Don't clear drainSignal — once drained, this CaptureContext is
        // done. RecordingService nils its `capture` reference after drain
        // so a fresh CaptureContext is created for the next recording.
        os_unfair_lock_unlock(lock)
        return out
    }
}

// MARK: - Error bridging for Shortcuts / NSError consumers
//
// Shortcuts reports thrown intent errors by rendering the bridged NSError. A
// plain `LocalizedError` enum bridges via Swift's automatic path, which sets
// the domain to the mangled type name AND — more painfully for diagnostics —
// defaults `errorCode` to 0 for every case. The user-facing banner then reads
// as `"<mangled-domain> error 0"` no matter which case actually fired. The
// "Recording error 0" repro on device today is indistinguishable between
// `.alreadyRunning` (race on the toggle), `.engineStart(error)` (AVAudioSession
// conflict with the foreground scene's RecordingService instance), or
// `.converterUnavailable` (hardware format mismatch) — all three render the
// same.
//
// `CustomNSError` locks the error domain + numeric codes so the bridged
// NSError is stable and diagnostic. External tooling (unified log predicates,
// screenshots, user-reported bug IDs) gets a contract it can rely on. Codes
// are assigned to match Swift's default enum-ordinal bridging at the time of
// writing so historical "Recording error N" reports stay interpretable —
// `alreadyRunning = 0` is already the value today, just by accident of being
// the first case; pinning it here makes that value a promise rather than an
// artifact.
//
// `CustomLocalizedStringResourceConvertible` is the AppIntents-era hook: when
// an intent throws, Shortcuts reads this resource instead of the bridged
// `localizedDescription`. `LocalizedError.errorDescription` stays implemented
// as a fallback for non-AppIntents callers (e.g. main-app UI alerts surfacing
// a recording failure).
//
// Mirrors the `TranscriptionService.TranscriptionError` conformances at the
// bottom of `TranscriptionService.swift` — the one departure is that
// `RecordingError`'s user-facing text is phrased as actionable recovery ("Stop
// the current recording before starting another.") rather than a status
// report. Recording failures land on an Action Button press where the user
// has no obvious next step; telling them what to do matters more than telling
// them what happened.

extension RecordingService.RecordingError: CustomNSError {
    /// Public error domain. Treat as API — logs / screenshots / bug reports
    /// reference it. Renames require migration.
    public static var errorDomain: String { "Jot.RecordingService.RecordingError" }

    /// Stable numeric codes. Table is the public contract; do NOT renumber.
    /// - 0: `alreadyRunning`
    /// - 1: `notRunning`
    /// - 2: `converterUnavailable`
    /// - 3: `sessionConfiguration(Error)`
    /// - 4: `engineStart(Error)`
    /// - 5: `micUnavailable`
    /// - 6: `warmYieldRestoreFailed` (TRANSIENT — internal control flow only)
    public var errorCode: Int {
        switch self {
        case .alreadyRunning: return 0
        case .notRunning: return 1
        case .converterUnavailable: return 2
        case .sessionConfiguration: return 3
        case .engineStart: return 4
        case .micUnavailable: return 5
        case .warmYieldRestoreFailed: return 6
        }
    }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "Recording error."]
    }
}

extension RecordingService.RecordingError: CustomLocalizedStringResourceConvertible {
    /// Rendered by Shortcuts / AppIntents surfaces when an intent's
    /// `perform()` throws. Keep strings user-facing and actionable — the
    /// recipient is someone looking at an opaque Shortcut failure banner on
    /// an Action Button press, with no obvious "what do I do next" affordance.
    public var localizedStringResource: LocalizedStringResource {
        // Single source of truth — same friendly copy the in-app and keyboard
        // surfaces show (see `userFacingMessage`). `LocalizedStringResource`
        // wraps the already-resolved String so Shortcuts renders identical text.
        LocalizedStringResource(stringLiteral: userFacingMessage)
    }
}
