import Foundation
import Observation

/// `@Observable` projection of the main app's live recording / streaming state,
/// mirrored into the keyboard extension via App Group reads + Darwin
/// notifications. Read directly by `KeyboardView` (by reference), so mutations
/// here drive the live-preview pane incrementally with no root reassignment.
///
/// Formerly a per-``JotKeyboardViewController`` instance. It is now owned by the
/// process-lifetime ``KeyboardStreamingHub`` (one instance per keyboard
/// process), so a transient or **ghost** controller renders the SAME live
/// state as the visible one — the blank live-preview pane (a ghost feeding its
/// own off-screen copy) is structurally impossible. See `KeyboardStreamingHub`.
@MainActor
@Observable
final class KeyboardRecordingState {
    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Pipeline phase, written by `applyPipelineProjection`. Drives the
    /// `KeyboardView.micCTA` four-state UI (idle / recording / in-flight /
    /// failed) and the auto-paste lifecycle. Single source of truth for
    /// "is the keyboard observing a recording right now?" — `isRecording`
    /// is derived from `phase == .recording` via `applyPipelineProjection`.
    private(set) var phase: PipelinePhaseProjection.Phase = .idle

    /// True while the pipeline is mid-flight after recording stopped — i.e.
    /// transcribing / processing / cleaning / rewriting / publishing. Drives
    /// the mic CTA's `.disabled` state at the SwiftUI layer (per design
    /// §4.6.D). v0.4 added `.rewriting` for the chained LLM rewrite branch.
    /// `.paused` is NOT in-flight — it is a live-but-not-capturing sub-state
    /// of recording (§10.2), so the mic CTA stays interactive (Stop) and the
    /// Resume control is offered separately.
    var isInflightPostRecording: Bool {
        switch phase {
        case .transcribing, .processing, .cleaning, .rewriting, .publishing:
            return true
        case .idle, .recording, .paused, .failed:
            return false
        }
    }

    /// True while the active dictation is paused (UX-overhaul round 2 §10).
    /// Derived solely from `phase == .paused`. While paused, `isRecording`
    /// stays `true` (we're still in a live session, just not capturing) so the
    /// keyboard keeps rendering the recording chrome — only the Pause control
    /// swaps to Resume and the elapsed clock freezes.
    private(set) var isPaused = false

    /// Frozen elapsed seconds captured at the moment the `.paused` projection
    /// was published (§10.4). The app back-dates `recordingStartedAt` to the
    /// pause-aware active-time anchor; we snapshot `lastUpdatedAt − anchor`
    /// here so the keyboard's clock shows a STILL value rather than continuing
    /// to tick against a fixed anchor + live `now`. Nil while not paused.
    private(set) var pausedElapsedSeconds: TimeInterval?

    /// Single canonical surface: writes `phase` and derives `isRecording` /
    /// `startedAt` from the same projection. Pipeline phase is the only
    /// cross-process recording-state input this view-model accepts.
    func applyPipelineProjection(_ projection: PipelinePhaseProjection?) {
        guard let projection else {
            phase = .idle
            isPaused = false
            pausedElapsedSeconds = nil
            update(isRecording: false, startedAt: nil)
            return
        }
        phase = projection.phase
        switch projection.phase {
        case .recording:
            isPaused = false
            pausedElapsedSeconds = nil
            update(isRecording: true, startedAt: projection.recordingStartedAt)
        case .paused:
            // Stay "recording" so the chrome persists; freeze the clock by
            // snapshotting the active-time total at publish (§10.4).
            isPaused = true
            if let anchor = projection.recordingStartedAt {
                pausedElapsedSeconds = max(0, projection.lastUpdatedAt.timeIntervalSince(anchor))
            } else {
                pausedElapsedSeconds = nil
            }
            update(isRecording: true, startedAt: projection.recordingStartedAt)
        case .idle, .transcribing, .processing, .cleaning, .rewriting, .publishing, .failed:
            isPaused = false
            pausedElapsedSeconds = nil
            update(isRecording: false, startedAt: nil)
        }
    }

    func update(isRecording: Bool, startedAt: Date?) {
        self.isRecording = isRecording
        self.startedAt = isRecording ? startedAt : nil
    }

    /// Latest live partial-transcript text mirrored from the main app via the
    /// App Group `streamingPartialText` projection. Drives the keyboard's
    /// live caption strip while `isRecording == true`. Empty string while
    /// idle or before the EOU model has emitted its first partial.
    private(set) var streamingPartialText: String = ""

    func updateStreamingPartial(_ text: String) {
        streamingPartialText = text
    }

    /// Mirrors `AppGroup.streamingLoadingVariantLabel`. Non-empty
    /// while the main app's `StreamingTranscriptionService` is
    /// ANE-loading the streaming graph for the active recording —
    /// e.g. "Parakeet 110M". Empty when no load is in flight. The
    /// streaming strip swaps its empty-state "Listening…" placeholder
    /// for a "Loading [label]…" pair (spinner + serif-italic label)
    /// whenever this is non-empty. Driven by
    /// `KeyboardStreamingHub.refreshStreamingLoadingFromProjection`.
    private(set) var loadingVariantLabel: String = ""

    func updateLoadingVariantLabel(_ label: String) {
        loadingVariantLabel = label
    }
}

/// Process-lifetime owner of the cross-process streaming/recording feed and the
/// projected state it produces.
///
/// ## Why this exists (the ghost-controller fix)
///
/// iOS keeps old `JotKeyboardViewController` instances alive and does NOT
/// reliably call `viewWillDisappear` (the only place the per-controller Darwin
/// observers used to be torn down). A leaked **ghost** controller kept its
/// subscriptions live and kept feeding the cross-process stream into its OWN
/// off-screen, per-controller `KeyboardRecordingState`. The visible host
/// belonged to a different controller, so its pane went blank.
///
/// The defect was architectural: session-scoped feed + projection state was
/// wrongly bound to the per-view-controller lifecycle. This hub hoists BOTH the
/// single set of feed subscriptions AND the projected state into ONE
/// process-lifetime `@MainActor @Observable` object. Controllers observe it and
/// own none of it; a ghost renders the SAME live state as the visible
/// controller, so the blank is structurally impossible and there is exactly one
/// subscription set (no ghost can double-consume the feed).
///
/// Lives in the keyboard appex only. Foundation/Observation-only — no SwiftUI
/// dependency (it is read by SwiftUI via `@Observable`), appex-safe, no new
/// deps. Never touches `textDocumentProxy` / the host / per-presentation paste
/// machinery — that all STAYS on the controller.
///
/// Lifetime: first access (`shared`) lazily subscribes; the subscriptions are
/// never torn down (process-lifetime). Process death takes the singleton with
/// it — a relaunch re-subscribes lazily, which is correct.
@MainActor
@Observable
final class KeyboardStreamingHub {
    static let shared = KeyboardStreamingHub()

    // MARK: - Full Access

    /// Mirror of the controller's `UIInputViewController.hasFullAccess`. The hub
    /// can't read that inherited property (it isn't a view controller), so the
    /// active controller pushes it in (`setHasFullAccess`) on every appearance.
    /// Full Access is a process-global grant, so the most-recent controller's
    /// value is authoritative. All App-Group reads in the hub gate on this —
    /// iOS sandboxes App-Group reads when FA is off, returning stale/false data.
    private var hasFullAccess = false

    func setHasFullAccess(_ value: Bool) {
        hasFullAccess = value
    }

    // MARK: - Projected state (read by the view / controller)

    /// The single live recording/streaming projection. `KeyboardView` reads
    /// this by reference; the controller passes it through to the host.
    let recordingState = KeyboardRecordingState()

    /// Snapshot of recent transcripts loaded from the App Group mirror.
    /// Mirrored from `TranscriptHistoryMirror` on `historyMirrorUpdated` (and
    /// on `refreshNow()`). The controller reads this into `keyboardInputs`.
    private(set) var historyEntries: [TranscriptHistoryMirror.Entry] = []

    /// Whether the warm-hold switching nudge should render (WS-F / §4 R10).
    /// Mirrors `AppGroup.warmHoldNudgeShouldShow && !suppressed`. The app owns
    /// the streak math; the keyboard renders off this boolean and writes the two
    /// terminal actions back (via the controller's handlers, which clear this).
    private(set) var showWarmHoldNudge = false

    /// Whether the post-paste correction quick-review strip should render. Set
    /// when the app publishes asks for the just-pasted session (the
    /// `correctionAsksReady` feed, or the controller's paste-time trigger);
    /// cleared on finish/dismiss via the controller's handlers.
    private(set) var showCorrectionNudge = false

    /// The asks published by the app for the just-pasted session. Non-nil
    /// whenever `showCorrectionNudge` is true.
    private(set) var correctionAsks: CorrectionBridge.Asks?

    // MARK: - Render-notify hook (snapshot-backed surfaces only)

    /// Hook the active controller installs (in `viewWillAppear`) so the hub can
    /// ask it to re-render. REQUIRED for the surfaces that are SNAPSHOTTED into
    /// `KeyboardViewInputs` by `syncKeyboardInputs()` and therefore only update
    /// when the controller calls `renderRootView()`: the warm-hold nudge, the
    /// correction nudge (+ its asks), and the RecentsStrip history rows. Those
    /// surfaces moved to the hub but the hub can't reach the controller's
    /// `UIHostingController` directly — this hook is the bridge.
    ///
    /// Deliberately NOT used by the streaming-partial / streaming-loading or
    /// pipeline-phase-STATE paths: those drive `recordingState`, which the
    /// SwiftUI tree reads LIVE by reference via `@Observable`, so they recompose
    /// without a `renderRootView()` and MUST stay render-thrash-free (calling
    /// `renderRootView()` on every partial tick was the build-139 stale-frame bug).
    ///
    /// Last-appeared (visible) controller wins: each `viewWillAppear` overwrites
    /// it; teardown does NOT clear it (the closure captures `[weak self]`, so a
    /// dealloc'd controller's hook safely no-ops, and clearing it on disappear
    /// would risk nil'ing a newer controller's hook). `[weak self]` in the
    /// installed closure means a stale hook never resurrects a dead controller.
    var onShouldRender: (() -> Void)?

    // MARK: - Recovered dead-app zombie suppression

    /// After `recoverFromUnresponsiveApp` the shared `PipelinePhaseProjection`
    /// can still read `.recording`/`.paused` (the dead writer never wrote a
    /// terminal phase, and the 30s stale synth hasn't fired). Tombstone that
    /// exact session + frozen timestamp so a re-read of the projection does NOT
    /// resurrect the zombie recording UI. Cleared the moment the projection
    /// advances past the frozen timestamp or a new session appears (a live
    /// writer is back). This gates the phase STATE, which the hub owns, so the
    /// tombstone lives here too.
    var recoveredZombieFreeze: (sessionID: UUID, frozenAt: Date)?

    // MARK: - Feed subscriptions (process-lifetime; never torn down)

    private var streamingPartialObserver: CrossProcessNotification.Observer?
    private var streamingLoadingObserver: CrossProcessNotification.Observer?
    private var pipelinePhaseObserver: CrossProcessNotification.Observer?
    private var warmHoldNudgeObserver: CrossProcessNotification.Observer?
    private var historyMirrorUpdatedObserver: CrossProcessNotification.Observer?
    private var correctionAsksReadyObserver: CrossProcessNotification.Observer?

    private var didStartObserving = false

    private init() {
        startObserving()
    }

    /// Idempotent, `@MainActor`. Wires the six cross-process feed subscriptions
    /// exactly once for the life of the process. Called from `init` (first
    /// `shared` access).
    private func startObserving() {
        guard !didStartObserving else { return }
        didStartObserving = true

        streamingPartialObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.streamingPartialChanged
        ) { [weak self] in
            self?.refreshStreamingPartialFromProjection()
        }
        streamingLoadingObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.streamingLoadingChanged
        ) { [weak self] in
            self?.refreshStreamingLoadingFromProjection()
        }
        pipelinePhaseObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.pipelinePhaseChanged
        ) { [weak self] in
            self?.refreshPipelinePhaseState()
        }
        warmHoldNudgeObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.warmHoldNudgeChanged
        ) { [weak self] in
            self?.refreshWarmHoldNudgeFromProjection()
        }
        historyMirrorUpdatedObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.historyMirrorUpdated
        ) { [weak self] in
            self?.refreshHistory()
        }
        correctionAsksReadyObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.correctionAsksReady
        ) { [weak self] in
            self?.showCorrectionNudgeFromReady()
        }
    }

    /// One-shot full repaint of all projected state. Called by a freshly
    /// presented controller in `viewWillAppear` so it paints current state
    /// immediately (the per-VC model got this "for free" by being recreated).
    func refreshNow() {
        refreshPipelinePhaseState()
        refreshStreamingPartialFromProjection()
        refreshStreamingLoadingFromProjection()
        refreshWarmHoldNudgeFromProjection()
        refreshHistory()
    }

    // MARK: - Pipeline phase (STATE half only — proxy side-effects stay on the controller)

    /// Reads the pipeline projection and applies it to `recordingState`,
    /// honouring the recovered-zombie tombstone. This is the FEED-READ /
    /// STATE half of the old `refreshPipelinePhase`. The controller-scoped
    /// side-effects (auto-paste flush, watchdog arming, `stopRequestPosted`
    /// clearing) stay on the controller via its own thin `pipelinePhaseChanged`
    /// observer — the paste path is unchanged.
    func refreshPipelinePhaseState() {
        guard hasFullAccess else { return }
        var projection = PipelinePhaseProjection.read()
        if let freeze = recoveredZombieFreeze {
            if let p = projection,
               p.sessionID == freeze.sessionID,
               p.lastUpdatedAt <= freeze.frozenAt,
               p.phase == .recording || p.phase == .paused {
                projection = nil
            } else {
                recoveredZombieFreeze = nil
            }
        }
        recordingState.applyPipelineProjection(projection)
    }

    // MARK: - Streaming partial mirror

    private func refreshStreamingPartialFromProjection() {
        guard hasFullAccess else {
            recordingState.updateStreamingPartial("")
            return
        }
        let text = AppGroup.defaults.string(forKey: AppGroup.Keys.streamingPartialText) ?? ""
        recordingState.updateStreamingPartial(text)
    }

    /// Clear the live-transcript projection (local + App Group) the instant a
    /// NEW dictation is initiated. The previous session can leave its final
    /// text in the projection — the keyboard-dictation path doesn't reliably
    /// receive the main app's post-batch `reset()` — and because that stale
    /// text is non-empty, the streaming strip renders it verbatim (skipping the
    /// "Loading…/Listening…" placeholder) for the beat between the strip
    /// reappearing and the new session's first partial. Clearing on start makes
    /// the strip open clean every time. Driven explicitly by the controller on
    /// a new session start (the per-VC model got this "for free" by being
    /// recreated).
    func clearStreamingPartialForNewSession() {
        recordingState.updateStreamingPartial("")
        if hasFullAccess {
            AppGroup.defaults.set("", forKey: AppGroup.Keys.streamingPartialText)
        }
    }

    // MARK: - Streaming load-state mirror

    private func refreshStreamingLoadingFromProjection() {
        guard hasFullAccess else {
            recordingState.updateLoadingVariantLabel("")
            return
        }
        let label = AppGroup.streamingLoadingVariantLabel
        recordingState.updateLoadingVariantLabel(label)
    }

    // MARK: - Warm-hold switching nudge (WS-F / §4 R10)

    private func refreshWarmHoldNudgeFromProjection() {
        // Mirror the app's predicate (`shouldShow && !suppressed`,
        // ContentView.refreshWarmHoldNudge) so the two renderers can't diverge.
        let shouldShow = hasFullAccess
            && AppGroup.warmHoldNudgeShouldShow
            && !AppGroup.warmHoldNudgeSuppressed
        guard shouldShow != showWarmHoldNudge else { return }
        showWarmHoldNudge = shouldShow
        // Snapshot-backed surface: ask the active controller to re-render so the
        // nudge appears/hides live while the keyboard is presented.
        onShouldRender?()
    }

    /// Clear the warm-hold nudge render flag (driven by the controller's two
    /// terminal nudge actions, which also write the App-Group flags + post).
    func clearWarmHoldNudge() {
        showWarmHoldNudge = false
        onShouldRender?()
    }

    // MARK: - Correction quick-review nudge

    /// The app just published asks for the dictation we handled — read the
    /// latest and show the nudge. This is the RELIABLE trigger (reading at paste
    /// time races the publish). Yields to an already-showing correction nudge or
    /// the warm-hold nudge.
    private func showCorrectionNudgeFromReady() {
        guard !showCorrectionNudge, !showWarmHoldNudge else { return }
        let a = CorrectionBridge.readLatestAsks()
        if let a, !a.asks.isEmpty {
            DiagnosticsLog.record(source: "keyboard", category: .vocabularyGate,
                message: "asks-ready", metadata: ["found": "\(a.asks.count)"])
            correctionAsks = a
            showCorrectionNudge = true
            // Snapshot-backed surface — this is the RELIABLE post-paste trigger;
            // re-render so the nudge appears live.
            onShouldRender?()
        }
    }

    /// After a successful auto-paste, surface the correction quick-review strip
    /// IFF the app published asks for this exact session. Yields to the warm-hold
    /// nudge if that's already showing (one strip overlay at a time). Read-only;
    /// never edits the host's already-pasted text (teach-only). Driven by the
    /// controller's paste-time flush.
    func maybeShowCorrectionNudge(sessionID: UUID) {
        guard !showWarmHoldNudge else { return }
        let a = CorrectionBridge.readAsks(sessionID: sessionID)
        if let a, !a.asks.isEmpty {
            DiagnosticsLog.record(source: "keyboard", category: .vocabularyGate,
                message: "nudge check", metadata: ["found": "\(a.asks.count)"])
            correctionAsks = a
            showCorrectionNudge = true
            onShouldRender?()
        }
    }

    /// Clear the correction nudge (driven by the controller's "finished"
    /// handler, which also clears the bridge asks).
    func clearCorrectionNudge() {
        showCorrectionNudge = false
        correctionAsks = nil
        onShouldRender?()
    }

    // MARK: - History

    /// Reloads the App Group mirror. Mirrored on `historyMirrorUpdated` and on
    /// `refreshNow()` / explicit controller refresh (e.g. opening history).
    func refreshHistory() {
        guard hasFullAccess else {
            if !historyEntries.isEmpty {
                historyEntries = []
                onShouldRender?()
            }
            return
        }
        let loaded = TranscriptHistoryMirror.load()
        guard loaded != historyEntries else { return }
        historyEntries = loaded
        // Snapshot-backed surface: the RecentsStrip reads a plain snapshot of
        // `historyEntries` via `KeyboardViewInputs`, so without this the strip
        // wouldn't show a just-dictated transcript until the keyboard
        // re-presents (the previously-fixed stale-recents regression). Re-render
        // only on actual change to avoid needless work on the `historyMirrorUpdated`
        // feed.
        onShouldRender?()
    }
}
