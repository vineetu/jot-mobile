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
    /// The last *named* post-stop stage (`.transcribing` / `.cleaning` /
    /// `.rewriting`). `.processing` and `.publishing` are internal beats, so
    /// the label holds the previous named stage through them — the pill never
    /// flashes back to "Transcribing" between "Cleaning up" and the paste.
    /// Reset whenever the session leaves the post-stop tail.
    private(set) var lastNamedStage: PipelinePhaseProjection.Phase = .transcribing

    /// The word the mic CTA shows while `isInflightPostRecording`. Names the
    /// stage the user is actually waiting on — most usefully the Automatic
    /// cleanup pass (features.md §7.14), which can take a few seconds and
    /// otherwise reads as an unexplained wait. Never a generic "Working".
    var inflightStatusLabel: String {
        switch lastNamedStage {
        case .cleaning: return "Cleaning up"
        case .rewriting: return "Rewriting"
        default: return "Transcribing"
        }
    }

    /// Strip-header line while the post-stop tail runs (§5.5): says what the
    /// wait is *for*, in plain words, above the held live text.
    var inflightHeaderLine: String {
        switch lastNamedStage {
        case .cleaning: return "AI is tidying this before it pastes"
        case .rewriting: return "Applying your follow-up"
        default: return "Finishing the transcript"
        }
    }

    /// Elapsed seconds frozen at the moment the recording stopped. Shown in
    /// the strip header (large widths) through the post-stop tail so the clock
    /// reads as the recording's length, not a still-ticking timer. Nil outside
    /// the tail.
    private(set) var finishingElapsedSeconds: TimeInterval?

    var isInflightPostRecording: Bool {
        switch phase {
        case .transcribing, .processing, .cleaning, .rewriting, .publishing:
            return true
        // `warmIdle` / `arming` (and any future state the keyboard doesn't yet
        // act on) are NOT in-flight — `arming` has its OWN affordance (see
        // `isArming` / B2); `warmIdle` renders idle/home. `default` keeps this
        // switch total so a new app-written state can never surface as an
        // unhandled phase.
        default:
            return false
        }
    }

    /// True while the app has requested a start but the first real audio buffer
    /// has NOT yet been confirmed (`phase == .arming`, §2.3). The record advertises
    /// `recording` ONLY after a buffer routes; until then it is `arming`, which the
    /// keyboard renders as a brief "starting…" spinner — NOT the live-mic UI and
    /// NOT idle (B2 / N4). It resolves to `.recording` (buffer confirmed) or
    /// `.failed` (arming-timeout); both transitions clear this, so the spinner can
    /// never get stuck (the "failed mirror" — a timed-out arm falls straight to
    /// home via the `.failed` → idle render). `isRecording` stays FALSE while
    /// arming (no confirmed capture), so the mic CTA never reads "Listening…"
    /// against an engine that may yet deliver silence.
    var isArming: Bool { phase == .arming }

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
            lastNamedStage = .transcribing
            finishingElapsedSeconds = nil
            update(isRecording: false, startedAt: nil)
            return
        }
        // Snapshot the live/paused clock BEFORE the projection overwrites it,
        // so the first in-flight tick can freeze the elapsed time at stop.
        let priorStartedAt = startedAt
        let priorPausedElapsed = pausedElapsedSeconds
        phase = projection.phase
        switch projection.phase {
        case .recording:
            isPaused = false
            pausedElapsedSeconds = nil
            lastNamedStage = .transcribing
            finishingElapsedSeconds = nil
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
        // `arming` (B2 / N4) — start requested, first buffer NOT yet confirmed.
        // NOT recording (no confirmed capture, so `isRecording` stays false and
        // the live-mic UI is unreachable) and NOT in-flight. `phase == .arming`
        // is surfaced via the `isArming` computed, which the mic CTA renders as a
        // brief "starting…" spinner. Listed explicitly (not in `default`) so its
        // UI is a deliberate decision, not a silent fall-through.
        case .arming:
            isPaused = false
            pausedElapsedSeconds = nil
            lastNamedStage = .transcribing
            finishingElapsedSeconds = nil
            update(isRecording: false, startedAt: nil)
        // `warmIdle` (post-stop warm window, mic warm but NOT capturing) renders
        // as idle/home. The in-flight tail + idle/failed are listed explicitly so
        // a real future state addition is a compile prompt to decide its UI, not a
        // silent fall-through — the switch is already exhaustive over `Phase`, so
        // there is no `default` (it would be provably dead code).
        case .transcribing, .processing, .cleaning, .rewriting, .publishing:
            // The post-stop tail (§5.5): the strip stays mounted, holding the
            // last live text still under a header that names the wait. The
            // clock freezes at whatever it read when the recording stopped
            // (or at the paused value if the user stopped from Pause).
            switch projection.phase {
            case .transcribing, .cleaning, .rewriting: lastNamedStage = projection.phase
            default: break
            }
            if finishingElapsedSeconds == nil {
                if let frozen = priorPausedElapsed {
                    finishingElapsedSeconds = frozen
                } else if let anchor = priorStartedAt ?? projection.recordingStartedAt {
                    finishingElapsedSeconds = max(0, projection.lastUpdatedAt.timeIntervalSince(anchor))
                }
            }
            isPaused = false
            pausedElapsedSeconds = nil
            update(isRecording: false, startedAt: nil)
        case .idle, .warmIdle, .failed:
            isPaused = false
            pausedElapsedSeconds = nil
            lastNamedStage = .transcribing
            finishingElapsedSeconds = nil
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

    /// Whether the Parakeet-upgrade nudge should render (deferred-engineering
    /// follow-up to the Apple Dictation A/B spike). Mirrors
    /// `AppGroup.showParakeetUpgradeNudge && !parakeetNudgeDeclined`. The app
    /// owns the dictation-count math; the keyboard renders off this boolean
    /// and writes the two terminal actions back (via the controller's
    /// handlers, which clear this).
    private(set) var showParakeetUpgradeNudge = false

    /// Whether the Vocabulary-adoption nudge should render. Mirrors the
    /// `AppGroup.vocabNudgeShouldShow && !vocabNudgeDeclined` projection; the
    /// keyboard renders off this flag (render precedence warm-hold › vocab ›
    /// Parakeet, `KeyboardView.topStrip`) and the controller's terminal
    /// handlers clear it.
    private(set) var showVocabNudge = false

    /// Whether the post-paste correction quick-review strip should render. Set
    /// when the app publishes asks for the just-pasted session (the
    /// `correctionAsksReady` feed, or the controller's paste-time trigger);
    /// cleared on finish/dismiss via the controller's handlers.
    private(set) var showCorrectionNudge = false

    /// The asks published by the app for the just-pasted session. Non-nil
    /// whenever `showCorrectionNudge` is true.
    private(set) var correctionAsks: CorrectionBridge.Asks?

    /// **Ask-before-paste HOLD deck (F1).** The ONE piece of deck state in the
    /// process — see `ActiveDeck`. Nil when no paste is being held. Everything the
    /// deck knows (which session, how far the owner got, what they picked, what
    /// text resolved out of it) lives here rather than on a controller or in
    /// SwiftUI-local `@State`, because both of those die while the deck is still
    /// gating a real pending paste.
    private(set) var activeDeck: ActiveDeck?

    /// Monotonic across the process lifetime; a new deck never reuses a token.
    private var deckGeneration = 0

    /// The controller iOS most recently presented. Only IT may drive proxy
    /// insertion for a deck: this codebase keeps ghost controllers alive with
    /// live-looking `textDocumentProxy`s (see the type doc above), and a ghost
    /// inserting the resolved text would paste into a field the owner is not
    /// looking at. Set from `viewWillAppear`, beside `onShouldRender`.
    private(set) var activeControllerID: ObjectIdentifier?

    func setActiveController(_ id: ObjectIdentifier) {
        activeControllerID = id
    }

    func isActiveController(_ id: ObjectIdentifier) -> Bool {
        activeControllerID == nil || activeControllerID == id
    }

    /// Render snapshot for the SwiftUI tree — non-nil ONLY while the deck is
    /// `.reviewing` (once it resolves, the strip's job is done and the paste is
    /// what the owner is waiting on). Carries the deck's progress so a remounted
    /// strip resumes at the first unanswered card instead of restarting.
    var askDeckSnapshot: AskDeckSnapshot? {
        guard let deck = activeDeck, deck.phase == .reviewing else { return nil }
        return AskDeckSnapshot(
            token: deck.token, asks: deck.asks.asks, totalUnresolved: deck.asks.totalUnresolved,
            index: deck.index, hasEngaged: deck.hasEngaged, answered: deck.answers.count)
    }

    /// Whether a held paste exists in ANY phase. F1b: dictation is modal against
    /// this — the pending-paste slot, the handoff payload and the asks blob are
    /// each single-slot, so a second dictation would overwrite the deck's own
    /// transport out from under it.
    var hasActiveDeck: Bool { activeDeck != nil }

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
    private var parakeetUpgradeNudgeObserver: CrossProcessNotification.Observer?
    private var vocabNudgeObserver: CrossProcessNotification.Observer?
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
        parakeetUpgradeNudgeObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.parakeetUpgradeNudgeChanged
        ) { [weak self] in
            self?.refreshParakeetUpgradeNudgeFromProjection()
        }
        vocabNudgeObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.vocabNudgeChanged
        ) { [weak self] in
            self?.refreshVocabNudgeFromProjection()
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
        refreshParakeetUpgradeNudgeFromProjection()
        refreshVocabNudgeFromProjection()
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
               p.phase.isActiveNonTerminal {
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

    // MARK: - Parakeet-upgrade nudge (deferred-engineering follow-up)

    private func refreshParakeetUpgradeNudgeFromProjection() {
        // Mirror the app's predicate (`shouldShow && !declined`) so the two
        // renderers can't diverge — same shape as `refreshWarmHoldNudgeFromProjection`.
        let shouldShow = hasFullAccess
            && AppGroup.showParakeetUpgradeNudge
            && !AppGroup.parakeetNudgeDeclined
        guard shouldShow != showParakeetUpgradeNudge else { return }
        showParakeetUpgradeNudge = shouldShow
        // Snapshot-backed surface: ask the active controller to re-render so
        // the nudge appears/hides live while the keyboard is presented.
        onShouldRender?()
    }

    /// Clear the Parakeet-upgrade nudge render flag (driven by the
    /// controller's two terminal actions, which also write the App-Group
    /// flags + post).
    func clearParakeetUpgradeNudge() {
        showParakeetUpgradeNudge = false
        onShouldRender?()
    }

    // MARK: - Vocabulary-adoption nudge

    private func refreshVocabNudgeFromProjection() {
        // Mirror the app's predicate (`shouldShow && !declined`) so the two
        // renderers can't diverge — same shape as the sibling nudges.
        let shouldShow = hasFullAccess
            && AppGroup.vocabNudgeShouldShow
            && !AppGroup.vocabNudgeDeclined
        guard shouldShow != showVocabNudge else { return }
        showVocabNudge = shouldShow
        onShouldRender?()
    }

    /// Clear the Vocabulary nudge render flag (driven by the controller's
    /// two terminal actions, which also write the App-Group flags + post).
    func clearVocabNudge() {
        showVocabNudge = false
        onShouldRender?()
    }

    // MARK: - Correction quick-review nudge

    /// The app just published asks for the dictation we handled — read the
    /// latest and show the nudge. This is the RELIABLE trigger (reading at paste
    /// time races the publish). Yields to an already-showing correction nudge or
    /// the warm-hold nudge.
    /// Whether a published asks blob may be surfaced by the POST-PASTE teach
    /// nudge. Only `postPasteOnly` (split-word merge teach) asks qualify: those
    /// were BLOCKED, so the owner's original words are already in the paste and
    /// confirming just teaches a sounds-like for the future — nothing to edit.
    ///
    /// A paste-holding ask (any `postPasteOnly != true` — an applied correction
    /// or a plausible KEPT proposal) must NEVER reach this surface. The post-paste
    /// nudge's verdict handler enqueues the learning verdict but CANNOT edit the
    /// host's already-pasted text (the keyboard has no reliable retro-edit into an
    /// arbitrary host field). So picking "original" on an applied correction here
    /// would flip the saved transcript (drained via `CorrectionInbox`) while the
    /// paste keeps the TERM — the exact paste/transcript divergence. The ask-
    /// before-paste HOLD deck is the sole surface that can honor the pick (it
    /// splices BEFORE the clipboard handoff); if a race let the paste land before
    /// the deck claimed the session, the ask stays reviewable on the transcript in
    /// Jot rather than being adjudicated where it can't be honored. The publisher
    /// emits homogeneous blobs (all teach OR all paste-holding — see
    /// `CorrectionAsksPublisher`), so one non-teach ask disqualifies the blob.
    private static func isPostPasteEligible(_ asks: CorrectionBridge.Asks) -> Bool {
        !asks.asks.contains { $0.postPasteOnly != true }
    }

    private func showCorrectionNudgeFromReady() {
        // Never raise the post-paste teach nudge while the pre-paste hold deck is up
        // (or already showing a nudge / warm-hold). The deck owns the asks pre-paste.
        guard !showCorrectionNudge, !showWarmHoldNudge, !hasActiveDeck else { return }
        let a = CorrectionBridge.readLatestAsks()
        if let a, !a.asks.isEmpty, Self.isPostPasteEligible(a) {
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
        // Never over a held paste: the deck owns the strip slot and these asks
        // while it is up (and the teach strip cannot honor a paste-changing pick).
        guard !showWarmHoldNudge, !hasActiveDeck else { return }
        let a = CorrectionBridge.readAsks(sessionID: sessionID)
        if let a, !a.asks.isEmpty, Self.isPostPasteEligible(a) {
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

    // MARK: - Ask-before-paste hold deck (F1 — the one state machine)

    /// Open a deck for a session whose paste the controller is gating, and return
    /// its token. `baseline` is the staged handoff text captured at hold time, so
    /// the resolution never depends on a second payload read.
    ///
    /// A deck for another session is SUPERSEDED here (one held paste at a time —
    /// the transports are single-slot). Re-holding the SAME session returns the
    /// existing token rather than restarting progress: that is the re-entrant
    /// flush arriving while the owner is mid-deck.
    func beginAskDeck(_ asks: CorrectionBridge.Asks, baseline: String) -> AskDeckToken {
        if let existing = activeDeck, existing.sessionID == asks.sessionID {
            return existing.token
        }
        deckGeneration += 1
        // Clear any post-paste teach nudge that raced in on `correctionAsksReady` —
        // the hold deck is the single surface for these asks while it's up.
        showCorrectionNudge = false
        correctionAsks = nil
        activeDeck = ActiveDeck(
            token: AskDeckToken(sessionID: asks.sessionID, generation: deckGeneration),
            asks: asks, baseline: baseline)
        onShouldRender?()
        return activeDeck!.token
    }

    /// The owner picked a word (or "Stop asking") on a card. `choice` is what the
    /// PASTE uses ("term" | "original" | "alt0"); `learning` is what the app is
    /// told ("term" | "original" | "suppress"). Answering a record that is already
    /// answered is impossible by construction — that is what kept a remounted
    /// strip from re-answering card 1 and giving the paste a last-wins value the
    /// first-event-wins `CorrectionInbox` would never agree with.
    /// Returns whether the answer was taken.
    @discardableResult
    func answerAskDeck(_ token: AskDeckToken, recordKey: String,
                       choice: String, learning: String) -> Bool {
        guard var deck = matchingDeck(token), deck.phase == .reviewing else {
            logStaleDeckAction("answer", token)
            return false
        }
        deck.hasEngaged = true
        guard deck.answers[recordKey] == nil, !deck.skipped.contains(recordKey),
              deck.asks.asks.contains(where: { $0.recordKey == recordKey })
        else {
            activeDeck = deck   // keep the engagement bit; ignore the duplicate
            return false
        }
        deck.answers[recordKey] = ActiveDeck.Answer(choice: choice, learning: learning)
        deck.answerOrder.append(recordKey)
        activeDeck = deck
        onShouldRender?()
        return true
    }

    /// A card went by without a pick (the per-card idle timeout, or teach-mode
    /// "Skip"). It is RESOLVED for progress purposes — the deck must not offer it
    /// again — but contributes no verdict and no edit.
    func skipAskDeckCard(_ token: AskDeckToken, recordKey: String) {
        guard var deck = matchingDeck(token), deck.phase == .reviewing else {
            logStaleDeckAction("skip", token)
            return
        }
        guard deck.answers[recordKey] == nil else { return }
        deck.skipped.insert(recordKey)
        activeDeck = deck
        onShouldRender?()
    }

    /// First card, zero engagement, idle timeout → don't march the owner through
    /// 3×10s. Everything unanswered is skipped and the deck falls straight to done.
    func skipAllAskDeckCards(_ token: AskDeckToken) {
        guard var deck = matchingDeck(token), deck.phase == .reviewing else {
            logStaleDeckAction("skip-all", token)
            return
        }
        for ask in deck.asks.asks where deck.answers[ask.recordKey] == nil {
            deck.skipped.insert(ask.recordKey)
        }
        activeDeck = deck
        onShouldRender?()
    }

    /// The deck is finished: `text` is what the paste should insert. Moves the
    /// phase off `.reviewing` (so the strip comes down) and hands the caller the
    /// deck it resolved, whose `answers` are the ONE batch of verdicts to enqueue.
    /// Returns nil on a stale token — a ghost controller's finish must not resolve
    /// the live deck.
    func resolveAskDeck(_ token: AskDeckToken, text: String) -> ActiveDeck? {
        guard var deck = matchingDeck(token), deck.phase == .reviewing else {
            logStaleDeckAction("resolve", token)
            return nil
        }
        deck.phase = .resolved(text: text)
        activeDeck = deck
        onShouldRender?()
        return deck
    }

    /// Claim the deck for insertion (`.resolved` → `.inserting`) so a second
    /// flush can't drive the same paste twice. Returns the text to insert, or nil
    /// if this deck isn't resolved-and-waiting.
    func beginAskDeckInsertion(_ token: AskDeckToken) -> String? {
        guard var deck = matchingDeck(token), case .resolved(let text) = deck.phase else { return nil }
        deck.phase = .inserting(text: text)
        activeDeck = deck
        return text
    }

    /// An insertion attempt ended without landing (proxy still disconnected, or
    /// the pending session moved under us). Put the deck back in `.resolved` so
    /// the next flush can try again with the owner's picks intact — the payload
    /// was NOT consumed on that path.
    func returnAskDeckToResolved(_ token: AskDeckToken) {
        guard var deck = matchingDeck(token), case .inserting(let text) = deck.phase else { return }
        deck.phase = .resolved(text: text)
        activeDeck = deck
    }

    /// TERMINAL. Every way a held paste can end — successful insertion, clipboard
    /// fallback, cancellation, the session going terminal, supersession — clears
    /// the deck through here. Session-scoped: a late cleanup for session A must
    /// never take session B's deck with it.
    func clearAskDeck(sessionID: UUID) {
        guard let deck = activeDeck, deck.sessionID == sessionID else { return }
        activeDeck = nil
        onShouldRender?()
    }

    /// The deck for `sessionID`, if that is the one currently held.
    func askDeck(for sessionID: UUID) -> ActiveDeck? {
        guard let deck = activeDeck, deck.sessionID == sessionID else { return nil }
        return deck
    }

    private func matchingDeck(_ token: AskDeckToken) -> ActiveDeck? {
        guard let deck = activeDeck, deck.token == token else { return nil }
        return deck
    }

    /// A command arrived for a deck that no longer exists (or for an older
    /// generation of it) — a stale strip/controller talking to the singleton.
    /// Fenced, and logged so the device gate can see it happen.
    private func logStaleDeckAction(_ action: String, _ token: AskDeckToken) {
        DiagnosticsLog.record(
            source: "keyboard", category: .vocabularyGate,
            message: "ask-deck: stale action fenced",
            metadata: ["action": action,
                       "session": token.sessionID.uuidString,
                       "generation": "\(token.generation)",
                       "live": activeDeck.map { "\($0.sessionID.uuidString)/\($0.generation)" } ?? "<none>"])
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

// MARK: - Ask-before-paste hold deck state (F1)

/// Identity of one hold deck: WHICH dictation it belongs to, and WHICH opening
/// of a deck for it. Every strip and controller action carries this and is
/// no-op'd on mismatch.
///
/// The session ID alone is not enough. `KeyboardStreamingHub` is a process
/// singleton while controllers are not: iOS keeps ghost controllers alive and
/// does not reliably call `viewWillDisappear`, so a stale controller (or a strip
/// that SwiftUI has not finished tearing down) can hand the singleton a command
/// that reads perfectly valid — same session, wrong deck. `@MainActor` serializes
/// those commands; it does not tell them apart. The monotonic `generation` does.
struct AskDeckToken: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let generation: Int
}

/// Everything the hold deck knows, in ONE value on the process-lifetime hub.
///
/// This replaces four per-controller dictionaries plus the strip's SwiftUI-local
/// progress. Those died with the controller/view while `showAskDeck` and the
/// real pending paste lived on, which is how a keyboard dismissed mid-deck came
/// back with no captured baseline and pasted the raw payload while the queued
/// verdicts flipped the saved transcript (D1). Progress is derived from
/// `answers`/`skipped` rather than stored as an index, so a remounted strip
/// RESUMES at the first unanswered card by construction and can never re-answer
/// a record.
///
/// Lifetime is the extension PROCESS, not the controller: eviction mid-deck
/// still loses it (accepted limit, see the plan's "Known limits").
struct ActiveDeck {
    /// What the owner chose on one card.
    struct Answer: Equatable {
        /// What the PASTE uses: "term" | "original" | "alt0".
        let choice: String
        /// What the APP learns: "term" | "original" | "suppress".
        let learning: String
    }

    /// Where the held paste is. The flush branches on this BEFORE it reads the
    /// handoff's freshness window, so a deck that outlives the 30s payload
    /// expiry still pastes (E1) instead of falling into no-payload cleanup.
    enum Phase: Equatable {
        /// The owner is answering cards. No insert, no consume, no cleanup.
        case reviewing
        /// Answered. `text` is the exact string to paste — no age check applies
        /// to it, because it is not being re-read from the expiring transport.
        case resolved(text: String)
        /// A controller is driving the proxy insert for `text` right now.
        case inserting(text: String)
    }

    let token: AskDeckToken
    let asks: CorrectionBridge.Asks
    /// The staged handoff payload, captured once at hold time. The resolution
    /// never re-reads the transport — the producer's edit descriptors were
    /// resolved against exactly this string.
    let baseline: String
    var answers: [String: Answer] = [:]
    /// Answer order, so the verdict batch reaches the app in the order the owner
    /// actually gave it.
    var answerOrder: [String] = []
    /// Cards resolved WITHOUT a pick (idle timeout / skip-all). Not verdicts —
    /// just "don't offer this again".
    var skipped: Set<String> = []
    var hasEngaged = false
    var phase: Phase = .reviewing

    init(token: AskDeckToken, asks: CorrectionBridge.Asks, baseline: String) {
        self.token = token
        self.asks = asks
        self.baseline = baseline
    }

    var sessionID: UUID { token.sessionID }
    var generation: Int { token.generation }

    /// The first card the owner has neither answered nor skipped — i.e. where a
    /// freshly-mounted strip picks up. `asks.count` means the deck is done.
    var index: Int {
        asks.asks.firstIndex { answers[$0.recordKey] == nil && !skipped.contains($0.recordKey) }
            ?? asks.asks.count
    }

    /// The verdict batch to enqueue at resolution — deduplicated by construction
    /// (one answer per record) and ordered as the owner gave them.
    var verdictEvents: [CorrectionBridge.VerdictEvent] {
        answerOrder.compactMap { key in
            guard let answer = answers[key] else { return nil }
            return CorrectionBridge.VerdictEvent(
                transcriptID: asks.transcriptID, recordKey: key, verdict: answer.learning)
        }
    }
}

/// Immutable render input for the strip: the deck's identity plus the progress
/// the view used to own privately.
struct AskDeckSnapshot: Equatable {
    let token: AskDeckToken
    let asks: [CorrectionBridge.Ask]
    let totalUnresolved: Int
    /// First unanswered card — a remounted strip resumes HERE.
    let index: Int
    let hasEngaged: Bool
    let answered: Int
}
