import AppIntents
// F3: the shared, Foundation-only paste-edit resolver/applier. One
// implementation for the producer (main app) and this consumer.
import JotVocabCore
import SwiftUI
import UIKit
import OSLog
import UniformTypeIdentifiers

private let keyboardLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.Keyboard", category: "keyboard")

/// Jot's custom keyboard extension. Provides a compact dictation-first keyboard
/// surface plus two Jot-specific affordances:
///
/// 1. **Paste fresh dictation** — when the main app has just recorded a
///    transcript (within ``ClipboardHandoff/freshnessWindow``), a paste pill
///    appears in the accessory bar. If `keyboardAutoPasteEnabled` is on, we
///    insert automatically on the first appearance after fresh dictation.
/// 2. **Transcript history** — a glyph in the accessory bar opens a list of
///    the most recent transcripts; tapping a row inserts it at the cursor.
///    History is read from ``TranscriptHistoryMirror`` (an App Group JSON
///    projection of the main app's SwiftData ledger) — never from SwiftData
///    directly. See that type's doc for the memory / migration reasoning.
///
/// All actual typing goes through ``UIInputViewController/textDocumentProxy``,
/// which is safe to call without Full Access — only the paste and history
/// features depend on App Group / clipboard access (and therefore on the
/// user flipping "Allow Full Access" in Settings).
///
/// ## Haptic + audio feedback
///
/// We conform to ``UIInputViewAudioFeedback`` so
/// ``UIDevice/current.playInputClick()`` can fire the system keyboard click
/// on input keys. The conformance returns `true` from
/// ``enableInputClicksWhenVisible`` — the OS handles the rest, respecting
/// the user's Settings → Sounds & Haptics → Keyboard Feedback toggles and
/// the ring/silent switch automatically.
///
/// ``KeyboardFeedback`` owns the haptic + audio generators for the
/// lifetime of this controller. Instantiated in ``viewDidLoad`` and
/// prepared on every ``viewWillAppear`` so the Taptic Engine is warm
/// before the first keypress. Both haptic and audio silently no-op without
/// Full Access (Apple Developer Forums thread 63493).
final class JotKeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {

    // MARK: - UIInputViewAudioFeedback

    /// Tells iOS this view wants to play keyboard clicks. Without this,
    /// `UIDevice.playInputClick()` is a no-op even with Full Access granted.
    /// See Apple docs for `UIInputViewAudioFeedback`.
    var enableInputClicksWhenVisible: Bool { true }

    // MARK: - Hosted SwiftUI tree

    private var hostingController: UIHostingController<KeyboardRootHostView>?

    /// The process-lifetime streaming/recording feed + projection hub. The
    /// cross-process feed and the projected state it produces (recording phase,
    /// streaming partial, loading label, warm-hold nudge, history, correction
    /// asks) used to live on THIS controller, bound to the per-view-controller
    /// lifecycle. iOS keeps ghost controllers alive and doesn't reliably call
    /// `viewWillDisappear` (the only teardown point), so a ghost kept feeding the
    /// stream into its own off-screen `recordingState` → the visible pane went
    /// blank. The state now lives in ONE process-lifetime `@Observable` hub that
    /// every controller (visible or ghost) observes, so the blank is structurally
    /// impossible. The controller still owns ALL paste / proxy / per-presentation
    /// machinery (see `KeyboardStreamingHub` for the seam).
    private var hub: KeyboardStreamingHub { KeyboardStreamingHub.shared }

    /// Pass-through to the hub's single `KeyboardRecordingState` so the existing
    /// `recordingState.X` call sites in this controller and the SwiftUI host read
    /// the one shared projection.
    private var recordingState: KeyboardRecordingState { hub.recordingState }

    /// `@Observable` bag of every *value* input `KeyboardView` takes. The root
    /// host is built ONCE (`makeRootHostView()`); every UI value update now
    /// mutates this object via `syncKeyboardInputs()` instead of reassigning a
    /// type-erased root — letting SwiftUI's `@Observable` machinery recompose
    /// only the affected subtree (fixes the streaming-preview stale-frame bug).
    private let keyboardInputs = KeyboardViewInputs()

    // MARK: - Keyboard height
    //
    // The keyboard's height is pinned by an explicit `NSLayoutConstraint`
    // on `self.view.heightAnchor` (priority 999, long-lived). The
    // minimize/expand affordance (and its 58pt collapsed envelope) was
    // removed in the UX-overhaul round 2 WS-D restructure — the keyboard
    // is a fixed-height surface now. The constraint stays as the single
    // height pin so SwiftUI's intrinsic-size machinery doesn't emit
    // "Unable to simultaneously satisfy constraints" console spam.

    // MUST equal `KeyboardView`'s `.frame(minHeight:)`. This 999-priority
    // `heightAnchor` pin sets the keyboard height, BUT the edge-pinned
    // `UIHostingController` lets the hosted SwiftUI content's intrinsic height
    // propagate up into `self.view`; when that intrinsic height exceeds this
    // pin it can override the 999 constraint, so the host lays out a taller
    // input view and the bottom controls fall below the visible envelope — the
    // "strip shows but the buttons are clipped / untappable" bug (was a 310
    // SwiftUI minHeight vs a 204 pin). Keeping the two equal removes the
    // disagreement. Derived from content, not guessed: top 8 + RecentsStrip 129
    // + spacing 6 + controls ~49 + bottom 4 ≈ 196pt idle; recording is shorter
    // (StreamingStrip 124 ⇒ ~191). Pin 200; the Spacer absorbs the slack.
    private static let expandedHeight: CGFloat = 200

    /// Long-lived height pin on `self.view`. Installed in `viewDidLoad`,
    /// re-applied on rotation to defend against any platform-side
    /// constraint solver resets.
    private var heightConstraint: NSLayoutConstraint?

    /// Observer for `historyMirrorUpdated`. Posted by the main app AFTER
    /// `TranscriptHistoryMirror.refresh(...)` finishes writing — see
    /// `CrossProcessNotification.swift`. We listen here instead of
    /// `transcriptReady` because the dictation pipeline posts
    /// `transcriptReady` BEFORE the SwiftData append + mirror write run
    /// (publish-first contract). An observer on `transcriptReady` would
    /// reload the mirror before the new row hits disk and re-render
    /// stale recents. The pipeline-phase observer covers the auto-paste
    /// flush + status banner path independently, so dropping the old
    /// `transcriptReady` observer here doesn't regress paste behaviour.
    /// Thin controller-scoped observer of `pipelinePhaseChanged`. The hub owns
    /// the phase STATE half (`recordingState.applyPipelineProjection` +
    /// zombie-freeze suppression); THIS observer runs only the controller-scoped
    /// proxy side-effects (auto-paste flush, watchdog arm/cancel, clear
    /// `stopRequestPosted`). Splitting by concern keeps the verified paste path
    /// byte-for-byte unchanged (plan §"phase split" option 2).
    private var pipelinePhaseObserver: CrossProcessNotification.Observer?
    /// Thin controller-scoped observer of `historyMirrorUpdated` for the
    /// per-presentation STATUS BANNER refresh only. The hub owns the history
    /// reload (its `historyMirrorUpdated` feed mutates `hub.historyEntries` and
    /// fires the `onShouldRender` hook so the active controller re-renders the
    /// RecentsStrip — the strip reads a plain snapshot of `historyEntries` via
    /// `KeyboardViewInputs`, NOT a live `@Observable`); the status banner is
    /// controller-scoped (`AppGroup.lastDictationStatusMessage`) so it stays here.
    private var historyMirrorUpdatedObserver: CrossProcessNotification.Observer?
    /// Set while a re-synced auto-paste insert is scheduled but not yet run
    /// (the ~12ms run-loop hop between requesting the proxy re-sync and the
    /// actual `insertText`). Guards against a second phase-change flush
    /// stacking a duplicate insert for the same payload → would double-paste.
    /// See `flushPendingAutoPasteIfPossible`.
    private var isAutoPasteInsertInFlight = false
    /// In-flight-paste window state for the `textDidChange` landed-signal
    /// (cure §4-B). Set AFTER the single `insertText` runs and the immediate
    /// read-back said "landed"; cleared when the deferred verify resolves OR
    /// when `textDidChange` short-circuits to success. While non-nil, a host
    /// `textDidChange` that carries our inserted text is treated as an
    /// authoritative "the host committed" confirmation — letting us classify
    /// success without waiting the full deferred window. Gated tightly (session
    /// id + inserted-text-present check) so a user's own typing or an unrelated
    /// host change can't false-confirm. The closure runs the success-finalize
    /// body shared with the deferred verify; calling it cancels the pending
    /// deferred work via `inFlightPasteResolved`.
    private var inFlightPasteSessionID: UUID?
    private var inFlightPasteText: String?
    private var inFlightPasteConfirm: (() -> Void)?
    /// Window state the corroborated-partial confirm arm needs (F4). Captured
    /// at window-open from the insert's own read-back: when the paste is longer
    /// than the host's context window the FULL-text presence check can never
    /// match, so the arm instead asks whether the host callback is CONTINUOUS
    /// with our insert — same tail, not shrunk, and soon enough to belong to
    /// this insert. Cleared with the rest of the window.
    private var inFlightPasteInsertedAt: Date?
    private var inFlightPasteImmediateLen: Int = 0
    private var inFlightPasteImmediateEvidence: PasteEvidence = .none
    /// Guards the success/failure finalize so exactly ONE of {textDidChange
    /// short-circuit, deferred settled-verify} runs the consume-payload body —
    /// never both (would double-consume / double-mark). Reset when a new
    /// in-flight window opens.
    private var inFlightPasteResolved = false
    // streaming-partial, streaming-loading, warm-hold-nudge, history-mirror, and
    // correction-asks feed subscriptions moved to `KeyboardStreamingHub` (one
    // process-lifetime subscription set, observed by all controllers).

    // MARK: - v7 auto-paste deadline tasks
    //
    // Two bounded one-shot Tasks (§4.0 #2 of the v7 design). Both are
    // state-derived liveness/deadline checks, NOT periodic timers and NOT
    // wall-clock guesses about transcription latency.
    //
    // `pipelineStaleDeadlineTask` — armed on observing a non-terminal phase,
    // fires at `lastUpdatedAt + heartbeatStaleThreshold + 2s`, cancelled and
    // re-armed on every `pipelinePhaseChanged`. Catches the dead-writer case:
    // app crashed mid-pipeline, no further heartbeat, the projection's
    // `read()` synthesizes `.failed` once age > 30s.
    //
    // `pendingLaunchDeadlineTask` — armed when pending is set, fires at
    // `pendingSession.createdAt + launchDeadline (15s)`, cancelled the moment
    // any projection with `sessionID == pending` is observed (proof of life).
    // Catches the cold-launch failure case: keyboard sets pending → opens
    // jot:// URL → app fails to launch / crashes before any phase write.
    private var pipelineStaleDeadlineTask: Task<Void, Never>?
    private var pendingLaunchDeadlineTask: Task<Void, Never>?

    // `deadAppWatchdogTask` — armed on a recording-control tap (Stop / Pause /
    // Cancel / Resume). The keyboard drives those controls by posting Darwin
    // requests the MAIN app must handle; if iOS jetsammed the app mid-recording
    // there is no live handler, the projection is frozen at `.recording`, and
    // the keyboard would otherwise hang until the 30s stale path. This watchdog
    // snapshots the projection's `lastUpdatedAt` at the tap and, after the 5s
    // ceiling, recovers the keyboard to idle if it never advanced. A live app —
    // foreground or background — refreshes within the 3s heartbeat (and
    // immediately when it processes the control), so it never trips this.
    private var deadAppWatchdogTask: Task<Void, Never>?

    // After a dead-app recovery, the shared `PipelinePhaseProjection` is still
    // frozen at `.recording` (the jetsammed writer never wrote a terminal phase,
    // and the 30s stale synth hasn't fired). The recovered-zombie tombstone
    // gates the phase STATE projection — now owned by `KeyboardStreamingHub`
    // (`hub.recoveredZombieFreeze`), so a re-read can't resurrect the zombie
    // recording UI. Set in `recoverFromUnresponsiveApp`.

    /// Bound on cold-launch / URL-delivery latency. iOS delivers a URL to a
    /// foreground-target target in O(seconds), not O(minutes), so 15s is a
    /// state question ("did the pipeline ever come up?"), not a workload-
    /// latency guess. Per design §4.6.G.
    private static let launchDeadline: TimeInterval = 15

    /// Hard ceiling on how long the keyboard waits for proof the main app is
    /// alive after a recording-control tap before recovering itself to idle.
    /// The 3s projection heartbeat (`PipelinePhaseProjection.heartbeatInterval`)
    /// sits comfortably under this, so a live app always clears it; only a
    /// jetsammed app — which stamps nothing — trips it.
    private static let controlTapLivenessCeiling: TimeInterval = 5

    /// B1 — the freshness window the record-based start decision uses to answer
    /// "is the writer alive right now?" (`now − record.liveness < livenessFresh`).
    /// Sized ≥ the old 4s warm window (the legacy `handleMicCTATap` heartbeat
    /// check) so a healthy BACKGROUNDED warm app — which tolerates MainActor
    /// jitter on a 1s stamp cadence — is never misclassified as dead and forced
    /// to cold-start (§6, backgrounded-alive liveness latency). The writer stamps
    /// `liveness` every 1s, so 4s leaves headroom for ~3 missed ticks. Consumed
    /// LIVE by `recordStartDecision()` (and the diagnostic comparison).
    private static let livenessFresh: TimeInterval = 4.0

    // MARK: - Jot affordance state

    /// Latest preview string from ``ClipboardHandoff`` — nil when no fresh
    /// dictation is available. Refreshed in ``viewWillAppear`` and cleared
    /// after a paste.
    private var freshPreview: String?

    /// Whether the system pasteboard currently has string content. Refreshed
    /// on appearance only so we don't trip pasteboard privacy reads on every
    /// keystroke.
    private var hasPasteboardContent = false

    /// Snapshot of the host selection. Used to enable/disable Actions menu rows.
    private var selectedTextSnapshot: String?

    /// Tracks keyboard-owned insertions so the Actions menu can undo only when
    /// the host document still ends with the last inserted string.
    private let undoLedger = KeyboardUndoLedger()
    private var renderedActionAvailability = KeyboardActionAvailability.empty
    /// v2 retheme (2026-05-11): last `textDocumentProxy.keyboardAppearance`
    /// value passed into the SwiftUI tree. Tracked here so
    /// `renderRootViewIfAppearanceChanged()` can re-render when a host
    /// dynamically switches its appearance (e.g. dark Mail flipping
    /// to a light compose modal mid-session). Initially `nil` so the
    /// first render always sets the baseline.
    private var renderedKeyboardAppearance: UIKeyboardAppearance?
    private var magicFollowUpExpiresAt: Date?

    /// Snapshot of recent transcripts loaded from the App Group mirror. Now
    /// owned by `KeyboardStreamingHub` (mirrored on `historyMirrorUpdated` once
    /// per process); read through here so existing call sites are unchanged.
    private var historyEntries: [TranscriptHistoryMirror.Entry] { hub.historyEntries }

    /// Transient banner string read off `AppGroup.lastDictationStatusMessage`.
    /// `nil` when no banner is pending. The keyboard view runs a 2.5s `task`
    /// per banner instance, then calls back into
    /// `clearStatusBannerSlot()` to drop the App Group slot.
    private var statusBanner: String?

    /// Phase 2 just-now marker source of truth (plan §13 risk 7).
    /// Set the moment a successful auto-paste lands. The `RecentsStrip`
    /// renders the top row in the green "just now" style when the
    /// timestamp is within 5s; after the window expires the row ages
    /// back into a normal mono-timestamp row.
    ///
    /// We CANNOT read `AppGroup.lastDictation` for this — that slot is
    /// consumed by the auto-paste pipeline (`markConsumed()`) so by the
    /// time the strip would observe it, the payload is gone.
    private var lastPastedText: String?
    private var lastPastedAt: Date?

    /// Guards against auto-paste firing twice within a single keyboard
    /// presentation (e.g. orientation change → `viewWillAppear` re-entry).
    private var autoPasteAttempted = false

    /// True from the moment the keyboard posts `stopRequested` until the next
    /// `pipelinePhaseChanged` reflecting the app's view of the world. Drives
    /// the speak button's `.disabled` modifier (so iOS suppresses taps while
    /// the stop is in flight) and the controller-level `decideMicTap`
    /// noop branch (defense-in-depth against optimistic-UI lag). Cleared in
    /// `refreshPipelinePhase` once projection moves off `.recording`.
    private var stopRequestPosted = false

    /// Whether the warm-hold switching nudge should render on the strip
    /// (UX-overhaul round 2 §4 / WS-F). Owned by `KeyboardStreamingHub`
    /// (mirrored on `warmHoldNudgeChanged`); read through here. The two terminal
    /// actions write the App-Group flags back and clear via `hub.clearWarmHoldNudge`.
    private var showWarmHoldNudge: Bool { hub.showWarmHoldNudge }

    /// Whether the Parakeet-upgrade nudge should render on the strip
    /// (deferred-engineering follow-up to the Apple Dictation A/B spike).
    /// Owned by `KeyboardStreamingHub` (mirrored on `parakeetUpgradeNudgeChanged`);
    /// read through here. The two terminal actions write the App-Group flags
    /// back and clear via `hub.clearParakeetUpgradeNudge`.
    private var showParakeetUpgradeNudge: Bool { hub.showParakeetUpgradeNudge }

    /// Whether the Vocabulary-adoption nudge should render. Owned by
    /// `KeyboardStreamingHub` (mirrored on `vocabNudgeChanged`); the two
    /// terminal actions write the App-Group flags back and clear via
    /// `hub.clearVocabNudge`.
    private var showVocabNudge: Bool { hub.showVocabNudge }

    /// Whether the post-paste correction quick-review strip should render. Owned
    /// by `KeyboardStreamingHub` — set by `hub.maybeShowCorrectionNudge` (paste-
    /// time) or the `correctionAsksReady` feed; cleared on finish/dismiss.
    private var showCorrectionNudge: Bool { hub.showCorrectionNudge }

    /// The asks published by the app for the just-pasted session. Owned by
    /// `KeyboardStreamingHub`; non-nil whenever `showCorrectionNudge` is true.
    private var correctionAsks: CorrectionBridge.Asks? { hub.correctionAsks }

    // MARK: - Ask-before-paste hold deck (F1)
    //
    // The deck's state used to be FOUR per-controller dictionaries here
    // (handled-sessions / default text / verdicts / resolved text). They died
    // with the controller while the hub's deck flag and the real pending paste
    // lived on, so a keyboard dismissed mid-deck came back with no captured
    // baseline and pasted the raw payload while the queued verdicts flipped the
    // saved transcript. All of it now lives in ONE `ActiveDeck` on
    // `KeyboardStreamingHub` (process-lifetime, generation-fenced); this
    // controller only drives the proxy, which is correctly per-presentation.

    // MARK: - Haptic + audio feedback

    /// Owns the long-lived `UISelectionFeedbackGenerator` and
    /// `UIImpactFeedbackGenerator` instances, plus the per-key-class audio
    /// dispatch table. Instantiated lazily in ``viewDidLoad`` once
    /// `hasFullAccess` is knowable; reused for every keypress for the
    /// controller's lifetime.
    private lazy var feedback: KeyboardFeedback = KeyboardFeedback(fullAccess: hasFullAccess)

    // MARK: - Backspace auto-repeat

    /// Repeat timer backing hold-to-delete on the backspace key. Schedule a
    /// one-shot initial delay, then a faster repeating tick — mirrors
    /// Apple's feel (~0.4s initial delay, ~0.07s repeat). Stored so we can
    /// cancel when the finger lifts.
    private var backspaceRepeatTimer: Timer?

    // MARK: - Keyboard-active heartbeat

    /// Repeating ~1s Timer that writes `AppGroup.keyboardActiveHeartbeat`
    /// while the keyboard is on screen, so the main app (setup wizard W5)
    /// can tell the Jot keyboard is the frontmost keyboard and dismiss its
    /// globe-switch cue. Mirror of the app→keyboard `appForegroundHeartbeat`.
    /// Started in `viewWillAppear`, invalidated in `viewWillDisappear`.
    private var keyboardActiveHeartbeatTimer: Timer?

    // MARK: - Lifecycle

    override func loadView() {
        let inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        self.view = inputView
    }

    deinit {
        // HYGIENE: stop any controller-scoped resources that could outlive a
        // ghost. UIKit deallocates view controllers on the main thread, so
        // `assumeIsolated` is valid here; the Darwin observer tokens auto-remove
        // via ARC as they release, and the deadline Tasks capture `[weak self]`,
        // but the repeating heartbeat / backspace `Timer`s would otherwise keep
        // ticking into a `[weak self]` no-op until invalidated. Tear them down.
        MainActor.assumeIsolated {
            tearDownControllerScopedResources()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Jot mic CTA is its own affordance; we do not provide a system dictation key.
        hasDictationKey = false
        // Push current Full Access into the process-lifetime hub before its
        // first feed read, then ensure its subscriptions are live (first `shared`
        // access lazily subscribes; idempotent thereafter).
        hub.setHasFullAccess(hasFullAccess)
        _ = hub
        installKeyboardView()
        installHeightConstraint()
        startObservingPipelinePhase()
        startObservingHistoryMirrorUpdated()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh the Full Access grant — the user can flip "Allow Full
        // Access" in Settings between keyboard presentations, and haptic +
        // audio both require it. Then warm the Taptic Engine so the first
        // keypress feels as crisp as the hundredth (HIG → Playing Haptics).
        feedback.fullAccess = hasFullAccess
        feedback.prepare()
        // Start signalling "Jot keyboard is frontmost" to the main app. The
        // wizard W5 step reads this to dismiss its globe-switch cue. iOS
        // blocks the AppGroup write when Full Access is off — the write
        // simply no-ops then (no crash); W5 dictation already requires FA.
        startKeyboardActiveHeartbeat()
        // Note: we DON'T mirror `hasFullAccess` to the App Group. iOS
        // blocks AppGroup writes when FA is off, so a mirror can only
        // ever go true → it can't reliably report "FA was turned off".
        // The main app stays honest by not claiming to know FA state.
        // Push current Full Access into the hub (it gates all App-Group reads),
        // then have this freshly-presented controller paint current projected
        // state immediately. The hub's feed subscriptions are process-lifetime
        // (subscribed once on first `shared` access) — nothing to re-subscribe.
        hub.setHasFullAccess(hasFullAccess)
        // Install the hub→controller render-notify hook so the SNAPSHOT-backed
        // surfaces (warm-hold nudge, correction nudge + asks, RecentsStrip
        // history) — which the hub mutates but only refresh when we call
        // `renderRootView()` — re-render live on their feeds. Last-appeared
        // (visible) controller wins; we do NOT clear it on teardown (the closure
        // is `[weak self]`, so a dealloc'd controller's hook safely no-ops, and
        // clearing it would risk nil'ing a newer controller's hook). The
        // streaming pane is NOT driven by this hook — it reads `recordingState`
        // live via `@Observable`.
        hub.onShouldRender = { [weak self] in self?.renderRootView() }
        // Same last-appeared-wins rule, for a different reason: only this
        // controller may drive the proxy insert for a resolved hold deck (F1).
        hub.setActiveController(ObjectIdentifier(self))
        hub.refreshNow()
        startObservingPipelinePhase()
        startObservingHistoryMirrorUpdated()
        // Controller-scoped proxy side-effects for the current phase (auto-paste
        // flush / watchdog / stopRequestPosted). The hub already applied the
        // phase STATE in `refreshNow()` above.
        refreshPipelinePhaseSideEffects()
        refreshSelectionState()
        // refreshPipelinePhase() already calls flushPendingAutoPasteIfPossible
        // at the bottom; calling it explicitly here is redundant but harmless
        // and preserved for symmetry with the existing call sequence.
        flushPendingAutoPasteIfPossible()
        // If pending exists from a prior presentation and its launch deadline
        // has already passed, re-arm — the deadline machinery will re-check
        // immediately and clear if still no proof of life. Extension recycle
        // does not strand pending.
        rearmLaunchDeadlineIfPending()
        // Controls-hang fix: if this presentation opens onto a still-active,
        // still-frozen pipeline projection (a prior control tap the app never
        // serviced — dismissed keyboard, suspended app), re-arm the dead-app
        // watchdog so recovery happens in ~5s instead of waiting on the 30s stale
        // path. A live app advances the heartbeat past the snapshot baseline, so
        // this stands down harmlessly when the app is healthy.
        rearmDeadAppWatchdogIfFrozen()
        refreshPasteState()
        // History is refreshed via `hub.refreshNow()` above (the hub owns the
        // `historyMirrorUpdated` feed + the `historyEntries` projection).
        refreshStatusBanner()
        renderRootView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A rewrite finishing after the keyboard is gone must not write into
        // whatever field is focused next.
        rewriteTask?.cancel()
        KeyboardRewriter.shared.cancel()
        translateTask?.cancel()
        KeyboardTranslator.shared.cancel()
        tearDownControllerScopedResources()
        // Close any open in-flight-paste window (cure §4-B) so a textDidChange in
        // a re-presented keyboard can't confirm a stale session, and mark it
        // resolved so an in-flight deferred verify that fires after teardown
        // short-circuits without re-consuming. Release the in-flight guard too so
        // a flush after re-appear isn't permanently blocked.
        //
        // CRITICAL (re-presentation double-paste, review): the in-flight window is
        // only opened AFTER the immediate read-back said the insert LANDED — so if
        // it's still open here (sessionID set, not resolved), the text is already
        // in the host field but the deferred ~350ms verify hasn't consumed the
        // payload yet. If we tear down without consuming, a re-presentation within
        // the 30s freshness window would re-flush and insert a SECOND copy (the
        // double-paste class that burned builds 103-106). So CONSUME the payload +
        // clear pending here: assume-landed is the safe teardown stance (the
        // transcript also stays on UIPasteboard from publish as the floor if it
        // turns out it didn't truly land). Never re-offer this sessionID.
        if let openSession = inFlightPasteSessionID, !inFlightPasteResolved {
            ClipboardHandoff.markConsumed()
            clearPendingPasteSession()
            // The payload is burned, so the deck can never paste — end it here
            // rather than leaving it holding a session that no longer exists.
            endDeck(sessionID: openSession)
            DiagnosticsLog.record(
                source: "keyboard",
                category: .pasteSuccess,
                message: "Teardown during open paste window — consumed payload to prevent re-present double-paste",
                metadata: ["sessionID": inFlightPasteSessionID?.uuidString ?? "nil"]
            )
        }
        inFlightPasteResolved = true
        isAutoPasteInsertInFlight = false
        // A deck claimed into `.inserting` whose insert this teardown just
        // cancelled (dismissal inside the 30-400ms pre-insert poll window —
        // `inFlightPasteSessionID` is still nil there, so the consume branch
        // above did not run) must be handed BACK, or it is stranded in
        // `.inserting` forever: the re-presented flush returns on that phase,
        // and `hasActiveDeck` keeps Dictate disabled for the rest of the
        // process. `returnAskDeckToResolved` no-ops for any other phase and
        // for an already-cleared deck, so this is safe on every teardown.
        if let deck = hub.activeDeck { hub.returnAskDeckToResolved(deck.token) }
        clearInFlightPasteWindow()
    }

    /// HYGIENE (ghost-controller fix): iOS does NOT reliably call
    /// `viewWillDisappear` on an outgoing/leaked `UIInputViewController`, so a
    /// ghost would keep its remaining controller-scoped observers/timers/tasks
    /// burning cycles. Correctness no longer depends on this teardown (the live
    /// feed + projection now live in the process-lifetime hub), but we still tear
    /// these down here AND in `viewDidDisappear` / `deinit` so a ghost stops
    /// spending work. Idempotent — safe to call from all three.
    private func tearDownControllerScopedResources() {
        pipelinePhaseObserver = nil
        historyMirrorUpdatedObserver = nil
        pipelineStaleDeadlineTask?.cancel()
        pipelineStaleDeadlineTask = nil
        pendingLaunchDeadlineTask?.cancel()
        pendingLaunchDeadlineTask = nil
        deadAppWatchdogTask?.cancel()
        deadAppWatchdogTask = nil
        cancelBackspaceRepeat()
        stopKeyboardActiveHeartbeat()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Defensive: if the OS skipped `viewWillAppear`/`viewWillDisappear`
        // pairing (app-switch / memory pressure), make sure this controller's
        // remaining observers/timers/tasks are torn down.
        tearDownControllerScopedResources()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // CURE §4-B — host textDidChange as an authoritative landed-signal.
        // Under the iOS-17 out-of-process keyboard, `insertText` is fire-and-
        // forget IPC and the proxy's `documentContext*` cache can grow WITHOUT
        // the host committing (the false-success that shipped 4 wrong builds).
        // `textDidChange`, when it fires, is the HOST pushing back that ITS
        // document actually changed — a signal the proxy cache can't fake. If it
        // fires inside our in-flight-paste window AND our inserted text is
        // actually present in the proxy context now, treat it as definitive
        // success and short-circuit the deferred ~350ms verify.
        //
        // Tightly gated so a user's own typing / an unrelated host change can't
        // false-confirm: (a) a window must be open (`inFlightPasteConfirm` non-
        // nil — only set AFTER our insert's immediate read said landed), and
        // (b) the inserted text must be present in the host context right now.
        // Its ABSENCE proves nothing (many hosts never fire it for proxy-
        // originated inserts), so the deferred verify floor still runs when this
        // doesn't fire — we never treat a missing callback as failure.
        maybeConfirmPasteViaTextDidChange()
        // Keep selection and undo-menu enablement fresh without reading
        // UIPasteboard here, which would fire iOS's paste-privacy toast on
        // every keystroke. The pasteboard is only queried on appearance via
        // refreshPasteState().
        refreshSelectionState()
        renderRootViewIfActionAvailabilityChanged()
        // v2 retheme: also re-render if the host swapped its
        // `keyboardAppearance` mid-session (rare, but happens with
        // sheets inside dark-mode apps).
        renderRootViewIfKeyboardAppearanceChanged()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshSelectionState()
        renderRootViewIfActionAvailabilityChanged()
        renderRootViewIfKeyboardAppearanceChanged()
    }

    // MARK: - Hosting

    private func installKeyboardView() {
        // Reflect current controller state into the `@Observable` inputs BEFORE
        // the host is built once, so the first frame is correct.
        syncKeyboardInputs()
        let host = UIHostingController(rootView: makeRootHostView())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.hostingController = host
        renderedActionAvailability = currentActionAvailability
        renderedKeyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
    }

    /// Pushes the controller's current state into the `@Observable`
    /// `keyboardInputs` bag. No longer reassigns a type-erased root — the host
    /// (`KeyboardRootHostView`) is built once in `installKeyboardView()` and
    /// recomposes off these observed values, which is what fixes the
    /// streaming-preview stale-frame thrash. Name + all 37 call sites are kept
    /// so callers don't need to change.
    private func renderRootView() {
        syncKeyboardInputs()
        renderedActionAvailability = currentActionAvailability
        // v2 retheme: snapshot the appearance so we can detect future
        // dynamic flips without re-rendering on every text-input poll.
        renderedKeyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
    }

    // MARK: - Keyboard height

    /// Installs the long-lived height pin on `self.view`. Priority
    /// `.required - 1` (999) so iOS's own input-view geometry
    /// constraints (system-imposed, priority 1000) always win in any
    /// hypothetical edge case — but at 999 our value drives the layout
    /// pass under normal conditions. Fixed at `expandedHeight`; the
    /// minimize/expand affordance was removed in the WS-D restructure so
    /// there is no second height to switch to.
    private func installHeightConstraint() {
        guard heightConstraint == nil else { return }
        let constraint = view.heightAnchor.constraint(
            equalToConstant: Self.expandedHeight
        )
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint
    }

    /// Defensive re-application of the height after a rotation /
    /// trait-collection change. The system input-view container may
    /// reset solver state across orientation changes; re-asserting our
    /// preferred constant inside the transition coordinator keeps the
    /// height stable.
    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.heightConstraint?.constant = Self.expandedHeight
            self.view.layoutIfNeeded()
        })
    }

    /// Central setter for `statusBanner`. Pushes to the `@Observable`
    /// `keyboardInputs` bag IMMEDIATELY so the banner renders the moment it's set —
    /// not on the next interaction-driven `syncKeyboardInputs()`. Without this push,
    /// mid-session banners that don't also call `renderRootView()` — notably
    /// "Added '…' to your dictionary" from Add to Vocabulary — stayed invisible until
    /// the user next touched the keyboard, because mutating the local store alone
    /// doesn't notify SwiftUI (user-reported bug). All banner copy flows through here,
    /// so every popup (success/warning/error/progress) now appears on time.
    private func setStatusBanner(_ message: String?) {
        statusBanner = message
        keyboardInputs.statusBanner = message
    }

    private func renderRootViewIfActionAvailabilityChanged() {
        guard currentActionAvailability != renderedActionAvailability else { return }
        renderRootView()
    }

    /// v2 retheme: re-render when the host's `keyboardAppearance` flips
    /// dynamically. Some hosts switch their proxy appearance mid-
    /// session (e.g. a sheet inside a dark-mode app). Without this
    /// check the keyboard would stay frozen on whatever appearance
    /// was passed at viewWillAppear. Called from textDidChange /
    /// selectionDidChange, the same hooks that re-poll the proxy for
    /// other reasons — adding one more cheap comparison is fine.
    private func renderRootViewIfKeyboardAppearanceChanged() {
        let current = textDocumentProxy.keyboardAppearance ?? .default
        guard current != renderedKeyboardAppearance else { return }
        renderRootView()
    }

    /// Builds the build-once concrete root host. Value inputs come from the
    /// `@Observable` `keyboardInputs` bag (kept fresh by `syncKeyboardInputs()`);
    /// `recordingState`, `feedback`, and all action closures are passed straight
    /// through. The closures are unchanged from the old `makeKeyboardView()`.
    private func makeRootHostView() -> KeyboardRootHostView {
        KeyboardRootHostView(
            inputs: keyboardInputs,
            recordingState: recordingState,
            feedback: feedback,
            onCopy: { [weak self] in self?.handleCopyMenuSelection() },
            onAddToVocabulary: { [weak self] in self?.handleAddToVocabulary() },
            onPaste: { [weak self] in self?.handlePasteMenuSelection() },
            onUndoLastInsertion: { [weak self] in self?.handleUndoMenuSelection() },
            onRedoInsertion: { [weak self] in self?.handleRedoMenuSelection() },
            onToggleCleanup: { [weak self] in self?.handleCleanupToggle() },
            onRewriteSelection: { [weak self] in self?.handleRewriteSelection() },
            onTranslateOpen: { [weak self] in self?.handleTranslateOpen() ?? false },
            onTranslateSelection: { [weak self] code in self?.handleTranslateSelection(code) },
            onJumpToStart: { [weak self] in self?.handleJumpToStart() },
            onJumpToEnd: { [weak self] in self?.handleJumpToEnd() },
            onTapToSpeak: { [weak self] in self?.handleMicCTATap() },
            onInsertHistoryEntry: { [weak self] entry in self?.insertHistoryEntry(entry) },
            onInsertText: { [weak self] text in self?.insertHistoryText(text) },
            onKey: { [weak self] key in self?.handleKeyTap(key) },
            onKeyPressChange: { [weak self] key, pressed in self?.handleKeyPressChange(key, pressed: pressed) },
            onAdvanceToNextInputMode: { [weak self] in self?.advanceToNextInputMode() },
            onOpenFullAccess: { [weak self] in self?.openFullAccessPrompt() },
            onStatusBannerRendered: { [weak self] in self?.clearStatusBannerSlot() },
            onOpenHome: { [weak self] in self?.openHostHome() },
            onOpenHistoryEntryInApp: { [weak self] entry in self?.openHistoryEntryInApp(entry) },
            onActionsTapped: { [weak self] in self?.handleActionsTapped() },
            onCancelRecording: { [weak self] in self?.handleCancelRecording() },
            onPauseRecording: { [weak self] in self?.handlePauseRecording() },
            onResumeRecording: { [weak self] in self?.handleResumeRecording() },
            onWarmHoldNudgeKeepMicReady: { [weak self] in self?.handleWarmHoldNudgeAccept() },
            onWarmHoldNudgeDismiss: { [weak self] in self?.handleWarmHoldNudgeDismiss() },
            onParakeetUpgradeNudgeUpgrade: { [weak self] in self?.handleParakeetNudgeUpgrade() },
            onParakeetUpgradeNudgeDismiss: { [weak self] in self?.handleParakeetNudgeDismiss() },
            onVocabNudgeSetUp: { [weak self] in self?.handleVocabNudgeSetUp() },
            onVocabNudgeDismiss: { [weak self] in self?.handleVocabNudgeDismiss() },
            onCorrectionVerdict: { [weak self] key, verdict in
                guard let self, let a = self.correctionAsks else { return }
                CorrectionBridge.enqueueVerdict(
                    .init(transcriptID: a.transcriptID, recordKey: key, verdict: verdict)
                )
            },
            onCorrectionFinished: { [weak self] in
                guard let self else { return }
                // `clearCorrectionNudge()` fires the `onShouldRender` hook, which
                // re-renders this controller — no separate `renderRootView()`.
                self.hub.clearCorrectionNudge()
                CorrectionBridge.clearAsks()
            },
            onAskDeckVerdict: { [weak self] token, key, verdict in
                self?.handleAskDeckVerdict(token, recordKey: key, verdict: verdict)
            },
            onAskDeckStopAsking: { [weak self] token, key in
                self?.handleAskDeckStopAsking(token, recordKey: key)
            },
            onAskDeckSkipCard: { [weak self] token, key in
                self?.handleAskDeckSkipCard(token, recordKey: key)
            },
            onAskDeckSkipAll: { [weak self] token in
                self?.handleAskDeckSkipAll(token)
            },
            onAskDeckFinished: { [weak self] token in
                self?.handleAskDeckFinished(token)
            }
        )
    }

    /// Copies the controller's CURRENT state into the `@Observable`
    /// `keyboardInputs` bag. This replaces the old per-render value-reads in
    /// `makeKeyboardView()` — same computations, just written into the observed
    /// object instead of into a freshly-built `KeyboardView`. Called by every
    /// `renderRootView()` call site (37 of them) and once before first install.
    private func syncKeyboardInputs() {
        // Copy / Add-to-Vocabulary enabled state: Full Access is required for clipboard
        // writes from a custom keyboard, AND there must be a non-empty selection in the
        // host's focused field. `hostHasSelection` reads `textDocumentProxy.selectedText`
        // directly (not `selectedTextSnapshot`, which fuses before/after context as a
        // fallback) so the tile state matches what Copy can actually read at tap time —
        // and the availability gate keys off the same property, so the two never diverge.
        keyboardInputs.hasFullAccess = hasFullAccess
        keyboardInputs.hasPasteboardContent = hasPasteboardContent
        keyboardInputs.needsInputModeSwitchKey = needsInputModeSwitchKey
        keyboardInputs.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        keyboardInputs.historyEntries = historyEntries
        keyboardInputs.canUndoLastInsertion = canUndoLastInsertion
        keyboardInputs.canRedoInsertion = canRedoInsertion
        keyboardInputs.undoDepth = undoLedger.undoStackDepth
        keyboardInputs.redoDepth = undoLedger.redoStackDepth
        keyboardInputs.cleanupEnabled = AppGroup.defaults.bool(forKey: AppGroup.Keys.cleanupEnabled)
        keyboardInputs.cleanupAvailable = AppGroup.defaults.object(forKey: AppGroup.Keys.aiCleanupAvailable) as? Bool ?? true
        keyboardInputs.lastPastedText = lastPastedText
        keyboardInputs.lastPastedAt = lastPastedAt
        keyboardInputs.isStopRequestPending = stopRequestPosted
        keyboardInputs.statusBanner = statusBanner
        keyboardInputs.showWarmHoldNudge = showWarmHoldNudge
        keyboardInputs.showParakeetUpgradeNudge = showParakeetUpgradeNudge
        keyboardInputs.showVocabNudge = showVocabNudge
        // v2 retheme (2026-05-11): host's `keyboardAppearance` hint.
        // Some hosts (dark Mail, dark Notes, Spotlight) force `.dark`
        // even when the system itself is in light mode. We pass the
        // proxy's signal through; `KeyboardView` resolves it against the
        // SwiftUI `colorScheme` env and the dark path wins if either says dark.
        keyboardInputs.keyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
        keyboardInputs.hasSelection = hasFullAccess && hostHasSelection
        keyboardInputs.showCorrectionNudge = showCorrectionNudge
        keyboardInputs.correctionAsks = correctionAsks
        keyboardInputs.askDeckSnapshot = hub.askDeckSnapshot
        keyboardInputs.askDeckBlocksDictation = hub.hasActiveDeck
    }

    /// Called when the Actions popover is about to open. Re-reads the
    /// system clipboard so the Paste row reflects current content rather
    /// than whatever was on the clipboard at the most recent
    /// `viewWillAppear`. Reading `UIPasteboard.general.hasStrings` triggers
    /// the iOS paste-privacy toast, which is acceptable on a discrete
    /// user-initiated event (~one toast per Actions open) but would be
    /// hostile on every keystroke — see `refreshPasteState`'s comment.
    private func handleActionsTapped() {
        // The pane's Rewrite tile needs to know whether the on-device model can
        // run; ask once per open rather than on every render.
        keyboardInputs.rewriteAvailable = KeyboardRewriter.isAvailable
        refreshPasteState()
        renderRootView()
    }

    /// Called when the user taps the Cancel button while a dictation is
    /// actively recording. Posts a Darwin notification; the main app's
    /// `CrossProcessRecordingStopCoordinator.handleCancelRequested()`
    /// runs `RecordingService.shared.forceStop()`. The main app's
    /// resulting `.failed` pipeline phase publish flips this keyboard's
    /// `recordingState.isRecording` back to false, which auto-swaps the
    /// Cancel button back to the Actions button.
    private func handleCancelRecording() {
        keyboardLog.info("Posted cross-process recording cancel request")
        CrossProcessNotification.post(name: CrossProcessNotification.cancelRequested)
        armDeadAppWatchdog(reason: "cancel")
    }

    /// Called when the user taps Pause during an active dictation (WS-C / §10).
    /// Posts a Darwin notification; the main app's `RecordingService` (the
    /// single engine owner) runs `pauseRecording()` and publishes the `.paused`
    /// pipeline phase, which flips this keyboard's `recordingState.isPaused`
    /// and swaps the Pause control to Resume. The keyboard never touches the
    /// engine itself.
    private func handlePauseRecording() {
        keyboardLog.info("Posted cross-process recording pause request")
        CrossProcessNotification.post(name: CrossProcessNotification.pauseRequested)
        armDeadAppWatchdog(reason: "pause")
    }

    /// Called when the user taps Resume on a paused dictation (WS-C / §10).
    /// Posts a Darwin notification; the main app's `RecordingService` calls
    /// `resumeRecording()`, re-arms capture against the same slice (samples
    /// concatenate), and publishes `.recording` again.
    private func handleResumeRecording() {
        keyboardLog.info("Posted cross-process recording resume request")
        CrossProcessNotification.post(name: CrossProcessNotification.resumeRequested)
        armDeadAppWatchdog(reason: "resume")
    }

    /// Accept the warm-hold switching nudge (WS-F / §4). One tap, no confirm:
    /// flip warm hold ON (the satisfied terminal — never nudges again), clear
    /// the show flag, and post `warmHoldNudgeChanged` so the app re-reads.
    private func handleWarmHoldNudgeAccept() {
        AppGroup.warmHoldEnabled = true
        resolveWarmHoldNudge()
    }

    /// Dismiss the warm-hold nudge (WS-F / §4). One tap, no confirm: set the
    /// permanent suppression flag so it never shows again, then clear + post.
    private func handleWarmHoldNudgeDismiss() {
        AppGroup.warmHoldNudgeSuppressed = true
        resolveWarmHoldNudge()
    }

    /// Shared terminal for both nudge actions: clear the App-Group show flag,
    /// drop the hub render flag, post the cross-process change, and re-render.
    private func resolveWarmHoldNudge() {
        AppGroup.warmHoldNudgeShouldShow = false
        // Cross-nudge quiet period: stamp so no OTHER nudge arms right after
        // this one was answered (`AppGroup.nudgeQuietPeriodActive`).
        AppGroup.lastNudgeResolvedAt = Date().timeIntervalSince1970
        // `hub.clearWarmHoldNudge()` fires the `onShouldRender` hook, which
        // re-renders this controller — no separate `renderRootView()` needed.
        hub.clearWarmHoldNudge()
        CrossProcessNotification.post(name: CrossProcessNotification.warmHoldNudgeChanged)
    }

    /// Accept the Parakeet-upgrade nudge (deferred-engineering follow-up to
    /// the Apple Dictation A/B spike). Opens the main app's upgrade screen via
    /// a deep link — the actual engine switch happens there, not here; this
    /// controller only navigates and resolves its own nudge render state.
    private func handleParakeetNudgeUpgrade() {
        keyboardLog.info("Parakeet-upgrade nudge: opening upgrade screen")
        // MUST use the responder-chain opener, NOT `extensionContext?.open`:
        // on iOS 18+ UIKit silently force-fails the deprecated open path for
        // keyboard extensions (see `openContainingApp`), so the tap did nothing.
        // This is the same mechanism the `jot://dictate` launch relies on.
        if let url = URL(string: "jot://upgrade-engine") {
            openContainingApp(url)
        }
        resolveParakeetUpgradeNudge()
    }

    /// Dismiss the Parakeet-upgrade nudge. One tap, no confirm: set the
    /// permanent decline flag so it never shows again, then clear + post.
    private func handleParakeetNudgeDismiss() {
        AppGroup.parakeetNudgeDeclined = true
        resolveParakeetUpgradeNudge()
    }

    /// Shared terminal for both Parakeet-upgrade nudge actions: clear the
    /// App-Group show flag, drop the hub render flag, post the cross-process
    /// change, and re-render. Mirrors `resolveWarmHoldNudge`.
    private func resolveParakeetUpgradeNudge() {
        AppGroup.showParakeetUpgradeNudge = false
        // Cross-nudge quiet period stamp (see `resolveWarmHoldNudge`).
        AppGroup.lastNudgeResolvedAt = Date().timeIntervalSince1970
        // `hub.clearParakeetUpgradeNudge()` fires the `onShouldRender` hook,
        // which re-renders this controller — no separate `renderRootView()`.
        hub.clearParakeetUpgradeNudge()
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
    }

    /// Accept the Vocabulary nudge: open the app's Vocabulary screen via a
    /// deep link (opt-in — nothing auto-enables; the user flips the toggle /
    /// adds terms there). Same responder-chain opener as the Parakeet nudge
    /// (`extensionContext?.open` silently force-fails on iOS 18+).
    private func handleVocabNudgeSetUp() {
        keyboardLog.info("Vocabulary nudge: opening Vocabulary screen")
        if let url = URL(string: "jot://vocabulary") {
            openContainingApp(url)
        }
        resolveVocabNudge()
    }

    /// Dismiss the Vocabulary nudge. One tap, no confirm: set the permanent
    /// decline flag so it never shows again, then clear + post.
    private func handleVocabNudgeDismiss() {
        AppGroup.vocabNudgeDeclined = true
        resolveVocabNudge()
    }

    /// Shared terminal for both Vocabulary-nudge actions. Mirrors
    /// `resolveParakeetUpgradeNudge`.
    private func resolveVocabNudge() {
        AppGroup.vocabNudgeShouldShow = false
        // Cross-nudge quiet period stamp (see `resolveWarmHoldNudge`).
        AppGroup.lastNudgeResolvedAt = Date().timeIntervalSince1970
        hub.clearVocabNudge()
        CrossProcessNotification.post(name: CrossProcessNotification.vocabNudgeChanged)
    }

    /// After a successful auto-paste, surface the correction quick-review strip
    /// IFF the app published asks for this exact session. The nudge STATE is
    /// owned by the hub (`hub.maybeShowCorrectionNudge`), which fires the
    /// `onShouldRender` hook to re-render this controller. Read + render only —
    /// verdicts/teaching happen via the bridge; this never edits the host's
    /// already-pasted text (teach-only).
    private func maybeShowCorrectionNudge(sessionID: UUID) {
        hub.maybeShowCorrectionNudge(sessionID: sessionID)
    }

    // MARK: - Ask-before-paste hold deck handlers (F1 / F3 consumer)

    /// Hold deck: owner picked a word. Recorded ONCE in the hub's `ActiveDeck`
    /// (which refuses a second answer for the same record) — the learning verdict
    /// is NOT enqueued here. It goes out as one deduplicated batch at deck
    /// resolution, because the bridge queue is first-event-wins on the app side
    /// (`CorrectionInbox`) while the paste used the last value written: answering
    /// the same card twice made those two disagree, which is the divergence this
    /// deck exists to prevent.
    private func handleAskDeckVerdict(_ token: AskDeckToken, recordKey: String, verdict: String) {
        hub.answerAskDeck(token, recordKey: recordKey, choice: verdict, learning: verdict)
    }

    /// Hold deck: owner tapped "Stop asking". The ORIGINAL word stays in the
    /// pasted text, and the app is told to stop asking this pair on the keyboard
    /// (drained → `CorrectionStore.suppressBlock`). Transcript review is unaffected.
    private func handleAskDeckStopAsking(_ token: AskDeckToken, recordKey: String) {
        hub.answerAskDeck(token, recordKey: recordKey, choice: "original", learning: "suppress")
    }

    /// Hold deck: a card timed out. Resolved for progress, no verdict, no edit.
    private func handleAskDeckSkipCard(_ token: AskDeckToken, recordKey: String) {
        hub.skipAskDeckCard(token, recordKey: recordKey)
    }

    /// Hold deck: first card, no engagement, timed out → skip the rest.
    private func handleAskDeckSkipAll(_ token: AskDeckToken) {
        hub.skipAllAskDeckCards(token)
    }

    /// Hold deck resolved (all cards answered/skipped, or first-card skip-all).
    /// Resolve the final text, enqueue the verdict batch ONCE, move the deck to
    /// `.resolved` (which takes the strip down), and RE-ENTER the flush — which
    /// now takes F2's `.resolved` branch and pastes that exact text through the
    /// one proven insert path.
    private func handleAskDeckFinished(_ token: AskDeckToken) {
        guard let deck = hub.askDeck(for: token.sessionID), deck.token == token else {
            // Stale finish (a torn-down strip, or a ghost controller's copy).
            // `resolveAskDeck` logs the fence; nothing else to do.
            _ = hub.resolveAskDeck(token, text: "")
            return
        }
        // Double-finish fence up front: `resolveAskDeck` would refuse a
        // non-`.reviewing` deck anyway, but without this a second finish
        // performs the whole descriptor resolve just to discard it.
        guard case .reviewing = deck.phase else { return }
        let resolvedText = resolveDeckText(deck)
        guard hub.resolveAskDeck(token, text: resolvedText) != nil else { return }
        // ONE batch, deduplicated by record and in the owner's answer order.
        for event in deck.verdictEvents { CorrectionBridge.enqueueVerdict(event) }
        flushPendingAutoPasteIfPossible()
    }

    /// **F3 consumer — apply the owner's picks to the text about to be pasted.**
    ///
    /// The producer (`CorrectionAsksPublisher`) resolved every paste-changing
    /// choice against the exact string it handed us and shipped the span it
    /// occupies (`baseEdit` / `altEdit`). So the work here is verification, not
    /// searching: confirm the descriptor's verbatim substring still stands where
    /// it claims in OUR copy of the baseline, then replace it. A descriptor
    /// resolved against a different string can only fail closed.
    ///
    /// Two rules earn their own line:
    ///
    ///  * the no-op test is `replacement == span.text`, CASE-SENSITIVE. The
    ///    previous splice compared case-INsensitively, which made every
    ///    casing-only correction ("Claude code" → "Claude Code", "iphone" →
    ///    "iPhone" — the canonical 3-option `alt0` shape) a guaranteed silent
    ///    no-op while its verdict still flipped the saved transcript. That was
    ///    not an intermittent race; it was 100% of casing picks.
    ///  * an overlapping batch is rejected WHOLE. Applying half of it would put
    ///    text in the host that matches neither what the owner picked nor what
    ///    Jot proposed.
    ///
    /// Asks published before descriptors existed (an older app version against a
    /// newer keyboard) fall back to resolving the span here — through the SAME
    /// shared `PasteEditResolver` the producer uses, so the two can't drift.
    private func resolveDeckText(_ deck: ActiveDeck) -> String {
        let baseline = deck.baseline
        guard !baseline.isEmpty else { return baseline }
        let chars = Array(baseline)
        var edits: [PasteEditResolver.Replacement] = []
        var answered = 0, alreadyDesired = 0, unresolvable = 0, descriptors = 0

        for ask in deck.asks.asks {
            guard let answer = deck.answers[ask.recordKey] else { continue }
            answered += 1

            // Which span the pick edits, and what it becomes. `alt0` replaces the
            // alternate's wider `find` phrase (winner + following words) with the
            // longer term; everything else replaces the word standing in the text
            // (applied → term, kept → original), one span serving both directions.
            let descriptor: CorrectionBridge.EditSpan?
            let want: String
            if answer.choice == "alt0", let altTerm = ask.altTerm {
                descriptor = ask.altEdit
                want = altTerm
            } else {
                descriptor = ask.baseEdit
                want = (answer.choice == "term") ? ask.term : ask.original
            }
            let replacement = PasteEditResolver.trimGatedWord(want)
            guard !replacement.isEmpty else { continue }

            let span: PasteEditResolver.Span?
            if let descriptor {
                descriptors += 1
                // Well-formedness first (a degenerate descriptor is an unvalidated
                // insertion, invisible to overlap checking), then the verbatim
                // substring against OUR baseline.
                span = descriptor.isWellFormed
                    ? PasteEditResolver.verify(start: descriptor.start, text: descriptor.text, in: chars)
                    : nil
            } else {
                span = legacySpan(for: ask, choice: answer.choice, in: baseline)
            }
            guard let span else {
                unresolvable += 1
                continue
            }
            // Case-SENSITIVE: the span carries the baseline's own casing, so this
            // is true only when the text already reads exactly as the owner asked.
            if replacement == span.text {
                alreadyDesired += 1
                continue
            }
            edits.append(.init(start: span.start, end: span.end, text: replacement))
        }

        let editsRequired = edits.count
        let resolved = PasteEditResolver.apply(edits, to: chars)
        if resolved == nil { unresolvable += editsRequired }

        DiagnosticsLog.record(
            source: "keyboard", category: .vocabularyGate,
            message: "ask-before-paste: resolved deck text",
            metadata: [
                "sessionID": deck.sessionID.uuidString,
                "answered": "\(answered)",
                "editsRequired": "\(editsRequired)",
                // Equal-after-trim and "Stop asking" are SUCCESSES, not failures —
                // the invariant is editsApplied == editsRequired && unresolvable == 0.
                "editsApplied": "\(resolved == nil ? 0 : editsRequired)",
                "alreadyDesired": "\(alreadyDesired)",
                "unresolvable": "\(unresolvable)",
                "descriptors": "\(descriptors)",
                // Non-nil only when `apply` refused the batch — i.e. the
                // producer's non-overlap validation and ours disagreed.
                "overlapRejected": "\(resolved == nil && editsRequired > 0)",
            ])
        return resolved ?? baseline
    }

    /// Back-compat span resolution for an ask published WITHOUT F3 descriptors
    /// (an older app version). Same shared implementation the producer runs —
    /// the keyboard's own copy of this algorithm is gone, so the two cannot
    /// drift apart again.
    private func legacySpan(for ask: CorrectionBridge.Ask, choice: String,
                            in baseline: String) -> PasteEditResolver.Span? {
        guard let anchor = ask.publishedStart else { return nil }
        let inText: String
        let primaryLength: Int?
        if choice == "alt0", let altFind = ask.altFind {
            inText = altFind
            // The ask's `contextAfter` starts right after the PRIMARY word — i.e.
            // INSIDE the altFind tail — so after-side corroboration must search
            // from there, not from the end of the whole match.
            primaryLength = PasteEditResolver.trimGatedWord(
                (ask.outcome == "applied") ? ask.term : ask.original).count
        } else {
            inText = (ask.outcome == "applied") ? ask.term : ask.original
            primaryLength = nil
        }
        return PasteEditResolver.resolve(
            needle: PasteEditResolver.trimGatedWord(inText), anchoredAt: anchor, in: baseline,
            contextBefore: ask.contextBefore, contextAfter: ask.contextAfter,
            primaryLengthInNeedle: primaryLength)
    }

    private var currentActionAvailability: KeyboardActionAvailability {
        KeyboardActionAvailability(
            // Use the SAME signal the tiles display (`hostHasSelection`), not
            // `selectedTextSnapshot`. The snapshot is non-nil whenever the field holds
            // ANY text (it fuses before+selected+after), so it never moved when the
            // user selected/deselected — the gate below saw "no change" and suppressed
            // the re-sync, leaving Copy/Vocab frozen until the pane was reopened. Keying
            // the gate off the real selection makes the tiles update live.
            hasSelection: hasFullAccess && hostHasSelection,
            canUndoLastInsertion: canUndoLastInsertion,
            canRedoInsertion: canRedoInsertion,
            isMagicFollowUpActive: isMagicFollowUpActive
        )
    }

    /// True when the host's focused field has a non-empty selection. Single source of
    /// truth for the selection-dependent tiles (Copy / Add to Vocabulary) AND the
    /// availability gate — they MUST agree or the gate suppresses a sync the UI needs.
    private var hostHasSelection: Bool {
        guard let selected = textDocumentProxy.selectedText else { return false }
        return !selected.isEmpty
    }

    private var canUndoLastInsertion: Bool {
        undoLedger.canUndo(contextBeforeInput: textDocumentProxy.documentContextBeforeInput)
    }

    private var canRedoInsertion: Bool {
        undoLedger.canRedo
    }

    private var isMagicFollowUpActive: Bool {
        if let expiresAt = magicFollowUpExpiresAt, expiresAt > Date() {
            return true
        }
        return ClipboardHandoff.readFresh() != nil
    }

    // MARK: - Paste / handoff

    private func insertTrackedText(_ text: String) {
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        undoLedger.recordInsertion(text)
        // §14.4-cluster diagnostic: capture the moment of ledger growth.
        // If a user later reports "I tapped Recents but Undo was disabled,"
        // we want to see whether (a) this log fired at all (ledger
        // unrecorded — code path bypassed insertTrackedText) or (b) it
        // fired but `canUndo` returned false at render time (proxy
        // buffering means `documentContextBeforeInput` doesn't yet end
        // with the inserted text — Undo gate needs to re-check after
        // textDidChange).
        keyboardLog.info("undo-ledger record insertion chars=\(text.count, privacy: .public) depth=\(self.undoLedger.undoStackDepth, privacy: .public)")
    }

    /// Closes the in-flight-paste window used by the `textDidChange` landed-signal
    /// (cure §4-B). Called when EITHER the textDidChange short-circuit OR the
    /// deferred settled-verify resolves the paste, so a LATER host change (the
    /// user's own typing, an unrelated re-render) can never re-trigger
    /// `inFlightPasteConfirm`. Does NOT touch `inFlightPasteResolved` — that latch
    /// is owned by the finalize bodies and reset only when a new window opens.
    private func clearInFlightPasteWindow() {
        inFlightPasteSessionID = nil
        inFlightPasteText = nil
        inFlightPasteConfirm = nil
        inFlightPasteInsertedAt = nil
        inFlightPasteImmediateLen = 0
        inFlightPasteImmediateEvidence = .none
    }

    /// Cure §4-B confirm path, called from `textDidChange`. Confirms the in-flight
    /// paste as landed ONLY when a window is open AND the inserted text is present
    /// in the host context right now. The presence check is what gates out a
    /// user's own typing / an unrelated host re-render: those fire `textDidChange`
    /// too, but won't make our exact inserted text appear at the caret. The
    /// confirm closure finalizes success and closes the window (so a subsequent
    /// `textDidChange` is a no-op). Absence is silent — the deferred verify floor
    /// still classifies in that case.
    private func maybeConfirmPasteViaTextDidChange() {
        guard let confirm = inFlightPasteConfirm,
              let pendingText = inFlightPasteText,
              !inFlightPasteResolved else { return }

        // ARM 1 — FULL presence check against the live proxy context. iOS
        // windows `documentContextBeforeInput` (~last 300–1024 chars), and the
        // inserted suffix sits at the caret, so `hasSuffix` holds even in a long
        // field. `contains` is a tolerant fallback for a host that appended a
        // trailing space/newline after our text within the same change.
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        let fullArm = ctx.hasSuffix(pendingText) || ctx.contains(pendingText)

        // ARM 2 — CORROBORATED PARTIAL (F4). Arm 1 compares a string that can be
        // LONGER than the window iOS is willing to expose: for a long dictation
        // both `hasSuffix` and `contains` are structurally false however cleanly
        // the paste landed, so arm 1 cannot fire at all and this whole fast path
        // goes dark for exactly the payloads that need it most. Arm 2 covers
        // only that windowed case, and never relaxes arm 1's comparator — it
        // ADDS conjunctions instead. What is trusted here is still the CALLBACK
        // (host-originated; the proxy cache cannot fire it), not the suffix.
        //
        // The arm's REAL time budget is ~350 ms: the deferred settled-verify
        // fires then and closes the in-flight window either way, so a host
        // callback later than that finds no window to confirm. Condition (6)'s
        // `pasteConfirmMaxAge` is only the belt for a verify delayed under load.
        let ctxTail = Self.trimmingTrailingWhitespace(
            ctx, maxCharacters: Self.pasteConfirmTrailingSlack)
        let callbackAge = inFlightPasteInsertedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let partialArm =
            // (1) windowed case only — never competes with or shadows arm 1
            pendingText.count > ctx.count
            // (2) the ENTIRE window is our tail and nothing else. Stricter than
            //     arm 1's `contains`: over a window we cannot tell "the host
            //     appended" from "the host replaced our text with something
            //     ending the same way", so only trailing whitespace is tolerated.
            && pendingText.hasSuffix(ctxTail)
            // (3) enough exact tail agreement that coincidence is implausible
            && ctxTail.count >= Self.pastePartialConfirmFloor
            // (4) our OWN read right after insertText already showed this tail
            && inFlightPasteImmediateEvidence.isPartial(atLeast: Self.pastePartialConfirmFloor)
            // (5) the context has not receded since our insert
            && ctx.count >= inFlightPasteImmediateLen
            // (6) this callback belongs to THIS insert, not to a later edit
            && callbackAge <= Self.pasteConfirmMaxAge

        guard fullArm || partialArm else { return }

        // Log ONLY the corroborated-partial arm. `finalizeSuccess` already
        // writes a `.pasteLandedViaTextDidChange` entry for this very same
        // event (the `confirm()` below runs it synchronously), so emitting on
        // the full arm too would double-count every short-circuit success in
        // the device-gate read. The full arm needs no extra entry — it is the
        // pre-F4 behaviour and finalize's entry already covers it. The
        // partial arm is the one thing F4 added, and its entry carries the
        // calibration fields finalize does not. Hence the F4 gate read: if
        // `arm=corroborated-partial` never appears, Option B contributed
        // nothing and Option G is the entire fix.
        guard partialArm && !fullArm else { confirm(); return }

        DiagnosticsLog.record(
            source: "keyboard",
            category: .pasteLandedViaTextDidChange,
            message: "textDidChange corroborated-partial confirm arm matched",
            metadata: [
                "arm": "corroborated-partial",
                "pasteLen": "\(pendingText.count)",
                "ctxLen": "\(ctx.count)",
                "ctxTailLen": "\(ctxTail.count)",
                "immediateLen": "\(inFlightPasteImmediateLen)",
                "immediateEvidence": inFlightPasteImmediateEvidence.logLabel,
                "immediateOverlap":
                    "\(inFlightPasteImmediateEvidence.matchedLength(pasteLength: pendingText.count))",
                "confirmFloor": "\(Self.pastePartialConfirmFloor)",
                "callbackAgeMs": "\(Int((callbackAge.isFinite ? callbackAge : -0.001) * 1000))",
            ]
        )

        confirm()
    }

    /// Records a just-paste event for the Phase 2 recents-strip just-now
    /// marker (plan §4.3). The `RecentsStrip` reads `lastPastedText` +
    /// `lastPastedAt` and renders the top row in green-marker style for
    /// 5s before ageing it back into a normal mono-timestamp row.
    ///
    /// Idempotent: a second paste of the same text within the window
    /// re-stamps `lastPastedAt` so the visual cue extends.
    private func stampJustNowMarker(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastPastedText = trimmed
        lastPastedAt = Date()
    }

    private func refreshMagicFollowUpWindowFromHandoff() {
        if let payload = ClipboardHandoff.readFresh() {
            magicFollowUpExpiresAt = payload.timestamp.addingTimeInterval(ClipboardHandoff.freshnessWindow)
        } else if let expiresAt = magicFollowUpExpiresAt, expiresAt <= Date() {
            magicFollowUpExpiresAt = nil
        }
    }

    private func refreshPasteState() {
        // Without Full Access, the extension's UIPasteboard read is isolated
        // from the main app's clipboard and the App Group defaults return
        // sandboxed values on some iOS versions. Surface a setup hint via the
        // accessory bar instead of pretending there's nothing to paste.
        guard hasFullAccess else {
            freshPreview = nil
            hasPasteboardContent = false
            refreshMagicFollowUpWindowFromHandoff()
            return
        }

        hasPasteboardContent = UIPasteboard.general.hasStrings
        refreshMagicFollowUpWindowFromHandoff()
        let preview = ClipboardHandoff.pendingFreshTranscriptPreview()
        let autoPasteEnabled = AppGroup.defaults.bool(forKey: AppGroup.Keys.keyboardAutoPasteEnabled)
        let hasPending = (readPendingPasteSession() != nil)

        if preview != nil, autoPasteEnabled, !autoPasteAttempted, !hasPending {
            autoPasteAttempted = true
            insertFreshTranscript()
            return
        }

        freshPreview = preview
    }

    /// Inserts the full transcript from the system clipboard (source of
    /// truth; App Group only carries a truncated preview). Consumes the
    /// handoff so repeat keyboard presentations don't re-offer it.
    private func insertFreshTranscript() {
        guard hasFullAccess else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            freshPreview = nil
            renderRootView()
            return
        }

        magicFollowUpExpiresAt = Date().addingTimeInterval(ClipboardHandoff.freshnessWindow)
        insertTrackedText(text)
        // Manual paste of a fresh dictation — same UX as the auto-paste
        // path, so stamp the just-now marker too.
        stampJustNowMarker(text: text)
        ClipboardHandoff.markConsumed()
        freshPreview = nil
        hasPasteboardContent = UIPasteboard.general.hasStrings
        renderRootView()
    }

    private func insertGeneralPasteboardString() {
        guard hasFullAccess else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            hasPasteboardContent = false
            // Paste is always offered, so a tap with an empty clipboard lands here —
            // tell the user why rather than silently doing nothing.
            setStatusBanner("Clipboard empty")
            renderRootView()
            return
        }

        if ClipboardHandoff.readFresh() != nil {
            magicFollowUpExpiresAt = Date().addingTimeInterval(ClipboardHandoff.freshnessWindow)
        }
        insertTrackedText(text)
        ClipboardHandoff.markConsumed()
        freshPreview = nil
        hasPasteboardContent = UIPasteboard.general.hasStrings
        renderRootView()
    }

    private func copySelectionToPasteboard() {
        guard hasFullAccess else { return }
        guard let selected = textDocumentProxy.selectedText, !selected.isEmpty else {
            setStatusBanner("Select text")
            return
        }
        UIPasteboard.general.string = selected
        selectedTextSnapshot = selected
        // Pasteboard now has fresh content — refresh Actions affordance state.
        hasPasteboardContent = true
        renderRootView()
    }

    private func handleCopyMenuSelection() {
        fireMenuSelectionFeedback()
        copySelectionToPasteboard()
    }

    /// "Add to Vocabulary" — queue the host's current selection for the main
    /// app's vocabulary. The keyboard can't write the app's list, so it queues
    /// a `Correction` (Codable, JotVocabCore) in the App Group and
    /// pings the app via a Darwin notification; the app runs it through
    /// `VocabularyLearning.apply` — the one correction path — when it is
    /// running, else on next foreground (`VocabularyAddInbox`). Common words
    /// are filtered here so we never enqueue noise like "the".
    private func handleAddToVocabulary() {
        guard let raw = textDocumentProxy.selectedText else {
            setStatusBanner("Select a word")
            return
        }
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if CommonWords.isCommon(word.lowercased()) {
            setStatusBanner("‘\(word)’ is a common word — not added")
            return
        }
        // Append to the App-Group queue (JSON [Correction]) so multiple adds
        // before the app foregrounds all land. The selection is an
        // already-correct word — nothing was misheard — so it is a term with no
        // heard form. Not user-cased: the selection's casing can be a sentence
        // start ("Ebay"), so an existing term keeps the list's spelling.
        var pending = AppGroup.defaults.data(forKey: AppGroup.Keys.pendingVocabCorrections)
            .flatMap { try? JSONDecoder().decode([Correction].self, from: $0) } ?? []
        pending.append(.correct(heard: "", term: word))
        if let data = try? JSONEncoder().encode(pending) {
            AppGroup.defaults.set(data, forKey: AppGroup.Keys.pendingVocabCorrections)
        }
        CrossProcessNotification.post(name: CrossProcessNotification.vocabAddRequested)
        setStatusBanner("Added ‘\(word)’ to your dictionary")
    }

    private func handlePasteMenuSelection() {
        fireMenuSelectionFeedback()
        insertGeneralPasteboardString()
    }

    private func handleUndoMenuSelection() {
        fireMenuSelectionFeedback()
        undoLastInsertion()
    }

    private func handleRedoMenuSelection() {
        fireMenuSelectionFeedback()
        redoInsertion()
    }

    /// In-flight keyboard rewrite (§7.15); cancelled if the keyboard goes away.
    private var rewriteTask: Task<Void, Never>?

    /// The actions pane's Rewrite tile (features.md §5.6 / §7.15): rewrite the
    /// host's selected text IN PLACE with the user's Cleanup prompt on Apple's
    /// on-device model — no system-menu tutorial, no round trip to the app.
    /// The selection is re-read right before the insert; if the host moved on
    /// (focus change, new selection) nothing is written. The replacement lands
    /// on the undo stack so Undo restores the original words.
    private func handleRewriteSelection() {
        fireMenuSelectionFeedback()
        guard let original = textDocumentProxy.selectedText,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatusBanner("Select text")
            return
        }
        guard KeyboardRewriter.isAvailable else {
            setStatusBanner("Turn on Apple Intelligence in Settings to rewrite here")
            return
        }
        guard !keyboardInputs.rewriteInFlight else { return }

        // The same prompt Automatic cleanup runs (§7.14): the user's chosen
        // saved prompt, else the built-in Cleanup prompt.
        let prompt = CleanupSettings.load().instructions
        keyboardInputs.rewriteInFlight = true
        setStatusBanner("Rewriting…")
        rewriteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                keyboardInputs.rewriteInFlight = false
                rewriteTask = nil
            }
            do {
                let rewritten = try await KeyboardRewriter.shared.rewrite(original, prompt: prompt)
                guard !Task.isCancelled else { return }
                guard textDocumentProxy.selectedText == original else {
                    setStatusBanner("Selection changed — rewrite not applied")
                    return
                }
                // Typing over a selection replaces it; the undo ledger's
                // `.replacement` entry reverses exactly this.
                textDocumentProxy.insertText(rewritten)
                undoLedger.recordReplacement(deleted: original, inserted: rewritten)
                keyboardLog.info("keyboard rewrite applied: \(original.count) → \(rewritten.count) chars")
                setStatusBanner("Rewritten — Undo brings back your words")
                syncKeyboardInputs()
                renderRootView()
            } catch is CancellationError {
                // Keyboard went away mid-rewrite: drop the "Rewriting…" row so
                // it isn't still there when the keyboard comes back.
                setStatusBanner(nil)
            } catch {
                setStatusBanner("Couldn't rewrite — \(error.localizedDescription)")
            }
        }
    }

    /// In-flight keyboard translation (§7.16); cancelled if the keyboard goes away.
    private var translateTask: Task<Void, Never>?

    /// Translate tile tapped with a selection (§7.16): detect the selection's
    /// language, find which target packs are on the phone, and hand the pane
    /// its chips (last-used language first, installed ones next). Returns
    /// false — after a banner — when there is nothing selected.
    private func handleTranslateOpen() -> Bool {
        fireMenuSelectionFeedback()
        guard let selected = textDocumentProxy.selectedText,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatusBanner("Select text")
            return false
        }
        let source = KeyboardTranslator.detectSource(of: selected)
        keyboardInputs.translateSource = source
        keyboardInputs.translateOptions = []
        let lastUsed = AppGroup.defaults.string(forKey: AppGroup.Keys.keyboardTranslateTarget)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let installed = await KeyboardTranslator.shared.installedTargets(from: source)
            var options = TranslationLanguages.all
                .filter { $0.code != source }
                .map { KeyboardTranslateOption(code: $0.code, name: $0.name, installed: installed.contains($0.code)) }
            options.sort { a, b in
                if (a.code == lastUsed) != (b.code == lastUsed) { return a.code == lastUsed }
                if a.installed != b.installed { return a.installed }
                return a.name < b.name
            }
            keyboardInputs.translateOptions = options
        }
        return true
    }

    /// A language chip tapped (§7.16): translate the host's selection IN PLACE
    /// with Apple's on-device translation and record the replacement so Undo
    /// restores the original. A language whose pack isn't on the phone explains
    /// itself — the download can only happen from the app.
    private func handleTranslateSelection(_ code: String) {
        fireMenuSelectionFeedback()
        let name = TranslationLanguages.name(for: code)
        guard let option = keyboardInputs.translateOptions.first(where: { $0.code == code }) else { return }
        guard option.installed else {
            setStatusBanner("\(name) isn't downloaded yet — translate a note to \(name) in Jot once to get it")
            return
        }
        guard let original = textDocumentProxy.selectedText,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatusBanner("Select the text to translate first")
            return
        }
        guard !keyboardInputs.translateInFlight else { return }

        let source = keyboardInputs.translateSource
        AppGroup.defaults.set(code, forKey: AppGroup.Keys.keyboardTranslateTarget)
        keyboardInputs.translateInFlight = true
        setStatusBanner("Translating to \(name)…")
        translateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                keyboardInputs.translateInFlight = false
                translateTask = nil
            }
            do {
                let translated = try await KeyboardTranslator.shared.translate(original, from: source, to: code)
                guard !Task.isCancelled else { return }
                guard textDocumentProxy.selectedText == original else {
                    setStatusBanner("Selection changed — translation not applied")
                    return
                }
                textDocumentProxy.insertText(translated)
                undoLedger.recordReplacement(deleted: original, inserted: translated)
                keyboardLog.info("keyboard translate applied \(source, privacy: .public)→\(code, privacy: .public): \(original.count) → \(translated.count) chars")
                setStatusBanner("Translated to \(name) — Undo brings back your words")
                syncKeyboardInputs()
                renderRootView()
            } catch is CancellationError {
                setStatusBanner(nil)
            } catch {
                setStatusBanner("Couldn't translate — \(error.localizedDescription)")
            }
        }
    }

    /// The actions pane's Cleanup tile (features.md §5.6): flips Automatic
    /// cleanup (§7.14) without opening the app. Writes the same App-Group key
    /// the app's AI settings card reads, so both surfaces stay in step. A tap
    /// that can't take effect explains itself in the status banner instead of
    /// silently doing nothing (same rule as every other tile).
    private func handleCleanupToggle() {
        fireMenuSelectionFeedback()
        guard hasFullAccess else {
            setStatusBanner("Enable Full Access to change AI cleanup")
            return
        }
        let isOn = AppGroup.defaults.bool(forKey: AppGroup.Keys.cleanupEnabled)
        let available = AppGroup.defaults.object(forKey: AppGroup.Keys.aiCleanupAvailable) as? Bool ?? true
        if !isOn, !available {
            setStatusBanner("Turn on Apple Intelligence in Settings to use AI cleanup")
            return
        }
        AppGroup.defaults.set(!isOn, forKey: AppGroup.Keys.cleanupEnabled)
        syncKeyboardInputs()
        // No message (§5.6): the tile's On/Off chip is the confirmation.
    }

    /// Shifts the host caret backward through the focused text field.
    /// User-facing name is "Move up" because that's what users
    /// actually observe — each tap moves the caret by approximately one
    /// host-visible window (~256-1000 chars depending on the host), not
    /// to the true start of the field.
    ///
    /// The intent of the bounded loop below was to converge on the
    /// actual start by repeatedly walking `documentContextBeforeInput`
    /// → `adjustTextPosition(-before.count)`. In practice most hosts
    /// buffer the caret update so the proxy's `documentContextBeforeInput`
    /// returns the SAME window on the next iteration, and the loop
    /// short-circuits via the `!before.isEmpty` guard once the proxy
    /// has refreshed. Net effect on most hosts: one window's worth of
    /// shift per tap. The 50-iter cap is preserved as a safety net
    /// against any host where multiple iterations DO advance.
    ///
    /// Does not require Full Access — caret moves are a proxy-only
    /// call. `RECORDING START FROM:`-style breadcrumbs are not
    /// required here; cursor jumps are not recording events.
    private func handleJumpToStart() {
        fireMenuSelectionFeedback()
        // Iterate ASYNC across runloop ticks. The earlier synchronous
        // 50-iter loop didn't actually advance — iOS hosts coalesce
        // rapid `adjustTextPosition` calls into a single UI cycle, so
        // only one window's worth (often only one visible line) shifted
        // per tap. Dispatching each iteration with a small delay lets
        // the host update `documentContextBeforeInput` between calls so
        // the next iteration sees fresh context and can advance further.
        // 200-iter cap + no-progress guard prevents infinite loops on
        // hosts that don't honor offsets.
        moveUpStep(iter: 0, totalMoved: 0, prevBeforeLen: -1)
    }

    /// Recursive async step for `handleJumpToStart`. Continues until:
    /// - `documentContextBeforeInput` is empty (we hit the top), OR
    /// - the before-length didn't change since last iter (host won't
    ///   advance further — common on WebView-backed hosts), OR
    /// - we exhaust the 200-iter safety cap.
    private func moveUpStep(iter: Int, totalMoved: Int, prevBeforeLen: Int) {
        guard iter < 200 else {
            keyboardLog.info("move-up max iters; total-moved=\(totalMoved, privacy: .public)")
            return
        }
        let proxy = textDocumentProxy
        let beforeLen = proxy.documentContextBeforeInput?.count ?? 0
        guard beforeLen > 0 else {
            keyboardLog.info("move-up iter=\(iter, privacy: .public) reached start; total-moved=\(totalMoved, privacy: .public)")
            return
        }
        if iter > 0 && beforeLen == prevBeforeLen {
            keyboardLog.info("move-up iter=\(iter, privacy: .public) no-progress (host buffered); total-moved=\(totalMoved, privacy: .public)")
            return
        }
        let step = max(beforeLen + 1, 64)
        proxy.adjustTextPosition(byCharacterOffset: -step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            self?.moveUpStep(iter: iter + 1, totalMoved: totalMoved + step, prevBeforeLen: beforeLen)
        }
    }

    /// Shifts the host caret forward through the focused text field.
    /// User-facing name is "Move down". See `handleJumpToStart` for the
    /// bounded-loop rationale and the host-buffering caveat that means
    /// each tap shifts approximately one window, not to the true end.
    private func handleJumpToEnd() {
        fireMenuSelectionFeedback()
        // See `handleJumpToStart` — same async-iteration rationale to
        // defeat host coalescing of rapid `adjustTextPosition` calls.
        moveDownStep(iter: 0, totalMoved: 0, prevAfterLen: -1)
    }

    /// Recursive async step for `handleJumpToEnd`. Mirror of
    /// `moveUpStep`. Same termination conditions, opposite direction.
    private func moveDownStep(iter: Int, totalMoved: Int, prevAfterLen: Int) {
        guard iter < 200 else {
            keyboardLog.info("move-down max iters; total-moved=\(totalMoved, privacy: .public)")
            return
        }
        let proxy = textDocumentProxy
        let afterLen = proxy.documentContextAfterInput?.count ?? 0
        guard afterLen > 0 else {
            keyboardLog.info("move-down iter=\(iter, privacy: .public) reached end; total-moved=\(totalMoved, privacy: .public)")
            return
        }
        if iter > 0 && afterLen == prevAfterLen {
            keyboardLog.info("move-down iter=\(iter, privacy: .public) no-progress (host buffered); total-moved=\(totalMoved, privacy: .public)")
            return
        }
        let step = max(afterLen + 1, 64)
        proxy.adjustTextPosition(byCharacterOffset: step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            self?.moveDownStep(iter: iter + 1, totalMoved: totalMoved + step, prevAfterLen: afterLen)
        }
    }

    private func fireMenuSelectionFeedback() {
        feedback.selectionTick()
        feedback.systemClick()
    }

    private func undoLastInsertion() {
        guard let entry = undoLedger.popUndo(
            contextBeforeInput: textDocumentProxy.documentContextBeforeInput
        ) else {
            setStatusBanner("Nothing to undo")
            renderRootView()
            return
        }

        switch entry {
        case .insertion(let text):
            for _ in text {
                textDocumentProxy.deleteBackward()
            }
        case .replacement(let deleted, let inserted):
            // Reverse the replacement: delete the rewritten text, then
            // restore the original selection that was replaced.
            for _ in inserted {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(deleted)
        }
        renderRootView()
    }

    private func redoInsertion() {
        guard let entry = undoLedger.popRedo() else {
            setStatusBanner("Nothing to redo")
            renderRootView()
            return
        }

        switch entry {
        case .insertion(let text):
            textDocumentProxy.insertText(text)
        case .replacement(let deleted, let inserted):
            // Re-apply the replacement: delete the original (now restored
            // by undo), insert the rewritten text again.
            for _ in deleted {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(inserted)
        }
        renderRootView()
    }

    // MARK: - Keyboard-initiated auto-paste

    /// Observes `historyMirrorUpdated`, which the main app posts AFTER
    /// `TranscriptHistoryMirror.refresh(...)` finishes writing. Unlike
    /// `transcriptReady` (which the dictation pipeline posts BEFORE the
    /// SwiftData append + mirror write run as part of its publish-first
    /// contract), this notification arrives only once the mirror file
    /// reflects the latest history — including append, delete, and
    /// in-app rewrite write paths. Reloading on this signal is the
    /// canonical fix for the keyboard rendering stale recents until the
    /// next presentation.
    ///
    /// Auto-paste + status banner state is driven by
    /// `pipelinePhaseChanged` (via `refreshPipelinePhase`), which fires
    /// in lockstep with the publish step, so this observer focuses on
    /// the history-mirror reload and the dependent UI surfaces that
    /// read from AppGroup state already settled by the time the mirror
    /// finishes writing.
    private func startObservingHistoryMirrorUpdated() {
        guard historyMirrorUpdatedObserver == nil else { return }
        historyMirrorUpdatedObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.historyMirrorUpdated
        ) { [weak self] in
            guard let self else { return }
            // STATUS-BANNER half only (controller-scoped). The history reload +
            // RecentsStrip re-render is owned by the hub: its `historyMirrorUpdated`
            // feed mutates `hub.historyEntries` and fires the `onShouldRender`
            // hook so the active controller re-renders (the strip reads a plain
            // snapshot of `historyEntries` via `KeyboardViewInputs`, NOT a live
            // `@Observable`). Banner state can shift on this signal because
            // timeout / error fallback paths write a new message immediately
            // before the ledger append that triggered it; refresh + re-render
            // only on an actual banner change.
            let priorBanner = self.statusBanner
            self.refreshStatusBanner()
            if priorBanner != self.statusBanner {
                self.renderRootView()
            }
        }
    }

    /// Generates a fresh `PendingPasteSession`, writes it to the App Group,
    /// and arms the launch-deadline task. The same-input-context guards
    /// (`hostKeyboardTypeRaw`, `hostDocumentIdentifier`) are best-effort
    /// snapshots taken at tap time. Returns the new session so call sites
    /// can use the UUID immediately (e.g. for the `jot://dictate?session=`
    /// URL).
    @discardableResult
    private func beginPendingPasteSession() -> PendingPasteSession {
        let session = PendingPasteSession(
            id: UUID(),
            createdAt: Date(),
            hostKeyboardTypeRaw: textDocumentProxy.keyboardType?.rawValue,
            hostDocumentIdentifier: textDocumentProxy.documentIdentifier
        )
        if let data = try? JSONEncoder().encode(session) {
            AppGroup.defaults.set(data, forKey: AppGroup.Keys.pendingPasteSession)
        }
        armLaunchDeadline(for: session)
        return session
    }

    private func clearPendingPasteSession() {
        ClipboardHandoff.clearPendingPasteSession()
        pendingLaunchDeadlineTask?.cancel()
        pendingLaunchDeadlineTask = nil
    }

    private func readPendingPasteSession() -> PendingPasteSession? {
        guard let data = AppGroup.defaults.data(
            forKey: AppGroup.Keys.pendingPasteSession
        ) else { return nil }
        return try? JSONDecoder().decode(PendingPasteSession.self, from: data)
    }

    /// Arms a bounded one-shot Task that fires `launchDeadline` (15s) after
    /// `session.createdAt`. Cancelled by `cancelLaunchDeadlineIfProofOfLife`
    /// the moment ANY projection with `sessionID == session.id` is observed
    /// (proof of life — pipeline is up, dead-writer machinery covers further
    /// recovery from there).
    private func armLaunchDeadline(for session: PendingPasteSession) {
        pendingLaunchDeadlineTask?.cancel()
        let interval = max(
            0,
            session.createdAt
                .addingTimeInterval(Self.launchDeadline)
                .timeIntervalSinceNow
        )
        pendingLaunchDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            self?.handleLaunchDeadlineFired(forSessionID: session.id)
        }
    }

    /// Cancels the launch deadline once we observe ANY projection for our
    /// pending session. Subsequent recovery is handled by the stale-deadline
    /// task and TerminalSessionLog cleanup.
    private func cancelLaunchDeadlineIfProofOfLife(_ projection: PipelinePhaseProjection?) {
        guard let projection,
              let pending = readPendingPasteSession(),
              projection.sessionID == pending.id
        else { return }
        pendingLaunchDeadlineTask?.cancel()
        pendingLaunchDeadlineTask = nil
    }

    /// Fired only when ZERO observable pipeline activity has occurred for
    /// our pending session within `launchDeadline`. Treats this as a
    /// failed-to-launch and clears pending. Re-checks state once more before
    /// clearing in case a projection or terminal-log entry landed in the
    /// same wake window.
    private func handleLaunchDeadlineFired(forSessionID sessionID: UUID) {
        pendingLaunchDeadlineTask = nil
        guard let pending = readPendingPasteSession(),
              pending.id == sessionID
        else { return }
        let projection = PipelinePhaseProjection.read()
        if let projection, projection.sessionID == sessionID {
            return
        }
        if TerminalSessionLog.contains(sessionID: sessionID) {
            flushPendingAutoPasteIfPossible()
            return
        }
        keyboardLog.info(
            "Pending session \(sessionID) — no projection within \(Int(Self.launchDeadline))s; treating as failed-to-launch and clearing."
        )
        DiagnosticsLog.record(
            source: "keyboard", category: .pasteSkipOther,
            message: "Gave up on paste — Jot never picked up the dictation (15s)",
            metadata: ["sessionID": sessionID.uuidString]
        )
        clearPendingPasteSession()
        endDeck(sessionID: sessionID)
        renderRootView()
    }

    /// Re-arms the launch deadline if pending exists. Called from
    /// `viewWillAppear` so an extension recycle doesn't strand pending past
    /// its deadline.
    ///
    /// Skip the re-arm if a deadline task is ALREADY armed — typical paths:
    ///   - The just-completed `refreshPipelinePhase()` saw proof-of-life
    ///     for the pending session and cancelled the launch deadline. Re-
    ///     arming here would create a fresh 15s task that fires after
    ///     proof-of-life was already established, which is logically wrong
    ///     even though `handleLaunchDeadlineFired` is defensive enough to
    ///     no-op on a re-armed-then-fired deadline.
    ///   - The launch task survived viewWillDisappear → viewWillAppear (it
    ///     didn't, since `viewWillDisappear` cancels it). But the
    ///     `pendingLaunchDeadlineTask != nil` guard is a cheap safety net.
    /// If the task IS nil here AND pending exists, the extension was likely
    /// recycled — re-arm so the launch deadline still fires.
    private func rearmLaunchDeadlineIfPending() {
        guard let session = readPendingPasteSession() else {
            pendingLaunchDeadlineTask?.cancel()
            pendingLaunchDeadlineTask = nil
            return
        }
        guard pendingLaunchDeadlineTask == nil else { return }
        armLaunchDeadline(for: session)
    }


    /// The ONE proven insert path: re-sync the host proxy, poll it for a stable
    /// input session, insert, then corroborate that the text actually survived.
    /// Extracted so the fresh-payload path and F2's `.resolved` deck path share it
    /// verbatim — the deck's text must land through exactly the same machinery,
    /// not a second copy of it.
    ///
    /// `deck` is the token of the hold deck this insertion belongs to (nil for
    /// ordinary traffic). It is what the terminal branches clear, and what keeps a
    /// failed attempt recoverable: the deck goes back to `.resolved` so a later
    /// flush re-drives the owner's picks rather than the raw payload.
    /// TERMINAL cleanup for a deck AND its cross-process asks blob, in one
    /// place. The blob is a single global slot, so the clear is session-guarded
    /// — a path ending an OLD deck (supersession, stranded sweeps) must never
    /// delete a NEWER session's just-published asks. Every deck-terminal site
    /// routes through here so the two can't fall out of sync (Batch-2 review:
    /// the asymmetry made nudge suppression hard to reason about).
    private func endDeck(sessionID: UUID) {
        hub.clearAskDeck(sessionID: sessionID)
        CorrectionBridge.clearAsks(matching: sessionID)
    }

    /// Shared tail of the flush's `.resolved` and healed-`.inserting` branches:
    /// gate on the active controller, claim the deck into `.inserting`, and
    /// drive the proven insert path with the deck's held text.
    private func insertResolvedDeckText(_ text: String, session: UUID, deck: ActiveDeck) {
        // Only the controller iOS most recently presented may drive the
        // insert. Ghost controllers keep live-looking proxies in this
        // codebase; one of them pasting would put the text in a field
        // the owner is not looking at.
        guard hub.isActiveController(ObjectIdentifier(self)) else { return }
        guard !text.isEmpty else {
            // Can't happen (an empty payload never opens a deck), but a
            // deck that somehow resolved to nothing must end, not spin.
            endDeck(sessionID: session)
            return
        }
        guard let claimed = hub.beginAskDeckInsertion(deck.token) else { return }
        performAutoPasteInsertion(pasteText: claimed, pendingSessionID: session, deck: deck.token)
    }

    /// How strongly a host context window supports "the text we inserted is
    /// present" (F4 of docs/plans/vocab-hold-deck-reliability.md; review
    /// findings 9 + 10).
    ///
    /// iOS WINDOWS `documentContextBeforeInput` (~last 300–1024 chars). For a
    /// long dictation `context.hasSuffix(pasteText)` is therefore structurally
    /// false however cleanly the paste landed — and the single boolean the
    /// verify used read that as "reverted", showing "Couldn't paste here" over
    /// text sitting right there in the field. Splitting the read into three
    /// explicit strengths lets each branch decide how much proof it needs.
    ///
    /// NOTHING here is evidence of ABSENCE: a nil window is a dropped input
    /// connection, not a revert.
    private enum PasteEvidence: Equatable {
        /// Context nil or empty. Proves nothing in EITHER direction — every
        /// string vacuously "ends with" an empty window (review finding 9), so
        /// this can never be upgraded into success on its own.
        case none
        /// The whole `pasteText` fits inside the window and sits at the caret.
        /// The strong signal the verify has always used.
        case full
        /// `pasteText` is LONGER than the window and the ENTIRE window equals
        /// the corresponding tail of `pasteText`. Consistent with a landed long
        /// paste — but also with a host that kept only our tail, so it needs
        /// corroboration before it counts as survival.
        case partial(overlapLength: Int)

        /// True for windowed evidence carrying at least `floor` characters of
        /// exact tail agreement. `full`/`none` deliberately answer false: they
        /// have their own arms in the decision table.
        func isPartial(atLeast floor: Int) -> Bool {
            if case .partial(let overlapLength) = self { return overlapLength >= floor }
            return false
        }

        /// Characters of the paste this window can account for — all of them
        /// for `full`, the window for `partial`, zero for `none`. Diagnostics
        /// only; the device gate calibrates the floor off this number.
        func matchedLength(pasteLength: Int) -> Int {
            switch self {
            case .none: return 0
            case .full: return pasteLength
            case .partial(let overlapLength): return overlapLength
            }
        }

        var logLabel: String {
            switch self {
            case .none: return "none"
            case .full: return "full"
            case .partial: return "partial"
            }
        }
    }

    /// Minimum characters of exact tail agreement before WINDOWED (`partial`)
    /// evidence may count toward survival. 24 is a defensible starting point,
    /// NOT a measured one: long enough that a coincidental tail match is
    /// implausible for dictated prose, short enough to be reachable by every
    /// host window we know of. The F4 device gate calibrates it — every
    /// settled-verify decision logs its evidence kind and overlap so the real
    /// distribution is readable in Diagnostics before this number is trusted.
    private static let pasteEvidenceOverlapFloor = 24

    /// Minimum characters of exact tail agreement before the `textDidChange`
    /// CORROBORATED-PARTIAL arm may confirm a paste. Deliberately higher than
    /// `pasteEvidenceOverlapFloor`: that floor only ever contributes to a
    /// decision alongside other evidence, whereas this arm single-handedly
    /// declares success and consumes the payload. The asymmetric cost sets the
    /// number — too high and the arm never fires and we are exactly where we
    /// were; too low and a swallowed paste is consumed with no banner and the
    /// dictation is gone. Device-gate calibrated off the confirm-arm log.
    private static let pastePartialConfirmFloor = 64

    /// Belt, NOT the primary bound. The real budget for the corroborated-partial
    /// arm is the deferred settled-verify, which fires ~350 ms after the insert
    /// and closes the in-flight window whichever way it decides — so in practice
    /// a callback older than ~350 ms never reaches the arm at all. This constant
    /// only covers the case where that verify is itself delayed under main-queue
    /// load, keeping a late, unrelated host change from being read as continuity
    /// of our paste.
    private static let pasteConfirmMaxAge: TimeInterval = 1.0

    /// Trailing whitespace characters tolerated when testing "the entire window
    /// is our tail". Hosts that append a space/newline after an insert are
    /// common, and without this slack the corroborated-partial arm would
    /// silently never fire in exactly those hosts. Anything beyond whitespace
    /// fails the arm by design — see the comment at the arm itself.
    private static let pasteConfirmTrailingSlack = 4

    /// Classifies an already-read host context against the text we inserted.
    /// Pure and static so the immediate read and the settled read are judged by
    /// the same rules (and so the rules are readable without a live proxy).
    private static func pasteEvidence(context: String?, pasteText: String) -> PasteEvidence {
        // An empty paste can't be evidenced (and never reaches here — the flush
        // rejects an empty payload); an empty/nil window proves nothing.
        guard let context, !context.isEmpty, !pasteText.isEmpty else { return .none }
        if pasteText.count <= context.count {
            // The window is big enough to hold the whole insert, so the strong
            // caret-adjacent suffix check is decisive either way.
            return context.hasSuffix(pasteText) ? .full : .none
        }
        // Windowed: the most the host can expose is our tail. Require the
        // ENTIRE window to be that tail — a shorter agreement is not evidence.
        return pasteText.hasSuffix(context) ? .partial(overlapLength: context.count) : .none
    }

    /// Drops up to `maxCharacters` trailing whitespace/newline characters. The
    /// corroborated-partial confirm arm needs this because a host that appends a
    /// space after our insert must not break the "the entire window is our tail"
    /// test — while an UNBOUNDED trim would let a host that appended a whole run
    /// of its own whitespace pass as continuity of our paste.
    private static func trimmingTrailingWhitespace(_ text: String,
                                                   maxCharacters: Int) -> String {
        var result = text
        var dropped = 0
        while dropped < maxCharacters, let last = result.last, last.isWhitespace {
            result.removeLast()
            dropped += 1
        }
        return result
    }

    private func performAutoPasteInsertion(pasteText: String, pendingSessionID: UUID,
                                           deck: AskDeckToken?) {
        magicFollowUpExpiresAt = Date().addingTimeInterval(ClipboardHandoff.freshnessWindow)

        // RE-SYNC THE HOST PROXY BEFORE INSERTING — bounded reconnect-poll.
        //
        // The transcript arrives ~hundreds of ms after the user's Stop tap
        // (record → transcribe → cross-process publish), not as part of a UI
        // event. During that gap a custom / web-backed compose field (Slack,
        // Claude) can re-mount its text view, leaving our `textDocumentProxy`
        // pointed at a stale input connection: the pointer still looks valid
        // and the caret still blinks, but a cold `insertText` silently
        // no-ops. Native fields (Messages) keep the connection, which is why
        // it pastes there but not in those apps.
        //
        // Issuing ANY `adjustTextPosition` forces the host to re-establish
        // the input connection. iOS COALESCES that into the current UI cycle,
        // so a synchronous nudge-then-insert still hits the stale link — we
        // must yield AT LEAST one run-loop tick. The build-103→106 fix used a
        // single fixed 12ms hop; the research (docs/plans/reliable-web-field-
        // paste.md §1.3 / §4-A) shows a constant can't scale: a HEAVY
        // re-mounted web field (Claude's 906-char draft) is still rehydrating
        // its remote input session at +12ms, so the IPC drops while the proxy
        // cache grows → silent false-success.
        //
        // CURE: after `adjustTextPosition(0)`, POLL the proxy for a STABLE
        // input session — read `documentContextBeforeInput` (+ `hasText`)
        // every ~30ms up to a ~400ms ceiling, and only insert once we see
        // TWO CONSECUTIVE EQUAL reads (the host finished rehydrating). A fast
        // / native field is stable on poll #1 (no added latency, no
        // regression); a heavy web field gets the time its session needs. The
        // poll is bounded (hard iteration ceiling, async — never a busy-wait /
        // main-thread block) and on ceiling we insert anyway (best effort,
        // then the deferred verify + clipboard floor catch a miss).
        //
        // `isAutoPasteInsertInFlight` guards the ENTIRE poll + insert +
        // deferred-verify window (set true here, reset only when the verify
        // resolves) so a second phase-change flush can't stack a duplicate
    // insert → single paste, no retry band-aid.
        guard !isAutoPasteInsertInFlight else {
            // Another insert owns the proxy window. Release the deck's claim so
            // it stays `.resolved` and a later flush re-drives it — leaving it
            // `.inserting` would park the paste forever.
            if let deck { hub.returnAskDeckToResolved(deck) }
            return
        }
        isAutoPasteInsertInFlight = true

        textDocumentProxy.adjustTextPosition(byCharacterOffset: 0)

        // Bounded reconnect-poll tunables.
        let pollIntervalMs = 30
        let pollCeilingMs = 400
        let pollStartedAt = Date()

        // The insert + verify body. Runs ONCE, after the poll settles (or hits
        // the ceiling). `iterations`/`settleMs` are passed through for the
        // POLL diagnostic. Factored into a local closure so the poll loop has a
        // single exit point into the (unchanged) landed-detection logic below.
        func performInsertAndVerify(iterations: Int, settleMs: Int) {
            // The pending session may have been consumed/cleared by another
            // path during the poll; re-validate before inserting. Release the
            // in-flight guard on this early exit (no insert ran, no deferred
            // verify scheduled).
            guard let pending = self.readPendingPasteSession(),
                  pending.id == pendingSessionID else {
                self.isAutoPasteInsertInFlight = false
                // Nothing inserted, nothing consumed — hand the deck back so a
                // later flush can still paste the owner's picks.
                if let deck { self.hub.returnAskDeckToResolved(deck) }
                return
            }

            DiagnosticsLog.record(
                source: "keyboard",
                category: .pasteReconnectPoll,
                message: "Reconnect-poll settled before insert",
                metadata: [
                    "sessionID": pendingSessionID.uuidString,
                    "iterations": "\(iterations)",
                    "settleMs": "\(settleMs)",
                    "hitCeiling": "\(settleMs >= pollCeilingMs)",
                ]
            )

            // Detect whether the insert LANDED by reading the proxy AFTER it.
            // After a REAL insert the pre-caret context is non-nil (it now
            // holds at least the text we just inserted); after a no-op into a
            // still-disconnected proxy it stays nil. (`proxyHadContextBefore`
            // covers the empty-field case where the field legitimately had no
            // text before the caret — see build-105 empty-field double-paste.)
            let beforeCtx = self.textDocumentProxy.documentContextBeforeInput
            self.insertTrackedText(pasteText)
            let afterCtx = self.textDocumentProxy.documentContextBeforeInput
            let proxyHadContextBefore = (beforeCtx != nil)
            let proxyHasContextAfter = (afterCtx != nil)
            let landed = proxyHadContextBefore || proxyHasContextAfter

            // [PASTE-DIAG] The REAL signal for custom/web fields (Claude
            // Code): did the proxy's pre-caret buffer actually change? The
            // `landed` nil-check can't tell a real insert from a no-op when
            // there's stale context. `delta`>0 / `endsWith`=true → the resync
            // reconnected and the text went in (an empty visible box is then
            // a host-render limit); `delta`==0 → the insert no-op'd despite
            // the resync (ours to fix). Lengths + a bool only — no content.
            // Note: iOS windows `documentContextBeforeInput`, so `delta` can
            // under-count a long paste; `endsWith` is the firmer signal.
            let beforeLen = beforeCtx?.count ?? 0
            let afterLen = afterCtx?.count ?? 0
            // Same rules as the settled read (F4). `endsWithInserted` keeps its
            // exact old meaning — the whole insert fits the window and sits at
            // the caret — while `immediateEvidence` also carries the windowed
            // case a long paste can only ever reach.
            let immediateEvidence = Self.pasteEvidence(context: afterCtx, pasteText: pasteText)
            let endsWithInserted = (immediateEvidence == .full)

            guard landed else {
                // Still no-op'd even after the re-sync — keep the transcript
                // pending (don't burn it) so the settled `.idle` flush can
                // try once more. Single insert per flush = no double-paste.
                self.isAutoPasteInsertInFlight = false
                // Same for the deck: the picks aren't lost, they're waiting for
                // the next attempt.
                if let deck { self.hub.returnAskDeckToResolved(deck) }
                DiagnosticsLog.record(
                    source: "keyboard",
                    category: .pasteSkipProxyDisconnected,
                    message: "Insert no-op'd after re-sync — proxy not connected; kept pending",
                    metadata: [
                        "sessionID": pendingSessionID.uuidString,
                        "chars": "\(pasteText.count)",
                        "beforeLen": "\(beforeLen)",
                        "afterLen": "\(afterLen)",
                        "delta": "\(afterLen - beforeLen)",
                        "endsWith": "\(endsWithInserted)",
                    ]
                )
                return
            }

            // The IMMEDIATE read-back says it landed — but on a web/custom
            // field (Claude Code = WKWebView, Slack = React-Native) the proxy
            // can update its OWN local pre-caret cache while the host's live
            // document never commits the change (stale/detached connection) or
            // re-renders it away. `delta`/`endsWith` are computed from that same
            // possibly-stale cache and lie together — that is exactly why
            // `pasteSuccess` shipped as a false positive four times.
            //
            // So DO NOT consume the payload or log `pasteSuccess` on the
            // immediate read alone. Two corroborations narrow the window:
            //   (B) the host's `textDidChange` input-delegate callback — when
            //       it fires for our session with our text present, that is the
            //       HOST talking back (the proxy cache can't fake it), so we
            //       short-circuit straight to success (cure §4-B); and
            //   (C) a deferred (~350ms) settled re-read as the FLOOR — gate
            //       success on the inserted suffix still present AND `hasText`
            //       (a separate UITextInput signal the local cache can't fake
            //       on its own — Path D of bug-slack-silent-paste.md). This
            //       runs when textDidChange never fires (many hosts skip it for
            //       proxy-originated inserts — its absence proves nothing).
            // Exactly ONE of {B, C} runs the finalize body — `inFlightPaste-
            // Resolved` guards it so we never double-consume. The
            // `isAutoPasteInsertInFlight` guard stays armed across the whole
            // window so a second flush can't stack.
            //
            // Native fields (Messages/Notes = UITextView) commit synchronously
            // into the same object the proxy reads, so the settled read still
            // shows the suffix + hasText → classified success, no regression
            // (incl. the >2000-char windowing case: the window always holds the
            // freshly-inserted suffix regardless of how much precedes it).
            let immediateAfterLen = afterLen

            // Shared SUCCESS finalize. Runs from EITHER the textDidChange
            // short-circuit (B) or the deferred settled-verify (C). Guarded by
            // `inFlightPasteResolved` so only the first caller wins — the other
            // becomes a no-op (no double-consume, no double just-now marker).
            let finalizeSuccess: (_ viaTextDidChange: Bool, _ settledLen: Int) -> Void = { [weak self] viaTextDidChange, settledLen in
                guard let self else { return }
                guard !self.inFlightPasteResolved else { return }
                self.inFlightPasteResolved = true
                self.clearInFlightPasteWindow()
                self.isAutoPasteInsertInFlight = false

                // The pending session may have been consumed/cleared by another
                // path. If so the work is already done — don't re-consume. The
                // deck for it is terminal either way (every path that clears
                // pending clears it too; this is the belt to that suspenders).
                guard let pending = self.readPendingPasteSession(),
                      pending.id == pendingSessionID else {
                    self.endDeck(sessionID: pendingSessionID)
                    return
                }

                DiagnosticsLog.record(
                    source: "keyboard",
                    category: viaTextDidChange ? .pasteLandedViaTextDidChange : .pasteSuccess,
                    message: viaTextDidChange
                        ? "Host textDidChange confirmed insert landed (short-circuit)"
                        : "Inserted transcript into host (settled-verified)",
                    metadata: [
                        "chars": "\(pasteText.count)",
                        "sessionID": pendingSessionID.uuidString,
                        "beforeLen": "\(beforeLen)",
                        "afterLen": "\(afterLen)",
                        "delta": "\(afterLen - beforeLen)",
                        "endsWith": "\(endsWithInserted)",
                        "settledLen": "\(settledLen)",
                    ]
                )
                // Phase 2 just-now marker (plan §4.3 / §13 risk 7) — stamp
                // the keyboard's own state at the moment of insertion so the
                // RecentsStrip's top row can render in the green just-now
                // style for ~5s. Reading AppGroup.lastDictation after this
                // returns nil because markConsumed() (below) clears it.
                self.stampJustNowMarker(text: pasteText)
                ClipboardHandoff.markConsumed()
                self.clearPendingPasteSession()
                self.freshPreview = nil
                self.hasPasteboardContent = UIPasteboard.general.hasStrings
                self.renderRootView()
                // Post-paste correction quick-review: if the app published asks
                // for this session, take over the strip slot to collect verdicts.
                // Skip when the ask-before-paste deck already handled this session
                // (the verdicts were collected pre-paste) — and clean up its state.
                if deck != nil {
                    // TERMINAL for the deck: its text is in the host. `endDeck`
                    // also clears the App-Group asks blob (session-guarded).
                    self.endDeck(sessionID: pendingSessionID)
                } else {
                    self.maybeShowCorrectionNudge(sessionID: pendingSessionID)
                }
            }

            // Open the in-flight-paste window for the textDidChange (B) path.
            // The override checks `inFlightPasteSessionID`/`inFlightPasteText`
            // and, when its host change carries our text, calls
            // `inFlightPasteConfirm` → finalizeSuccess(viaTextDidChange: true).
            self.inFlightPasteResolved = false
            self.inFlightPasteSessionID = pendingSessionID
            self.inFlightPasteText = pasteText
            // Continuity state for the corroborated-partial confirm arm: when
            // our insert happened, how much context it left, and what our own
            // read-back saw. The arm asks whether the host's callback is
            // consistent with THIS insert — it never re-derives the answer from
            // the callback alone.
            self.inFlightPasteInsertedAt = Date()
            self.inFlightPasteImmediateLen = afterLen
            self.inFlightPasteImmediateEvidence = immediateEvidence
            self.inFlightPasteConfirm = { [weak self] in
                // settledLen unknown on the textDidChange path; read it live
                // for the log only. `[weak self]` so the property storing this
                // closure on `self` isn't a retain cycle keeping the keyboard
                // alive (it's nil'd on resolve, but a torn-down keyboard before
                // resolve must still dealloc).
                guard let self else { return }
                let liveLen = self.textDocumentProxy.documentContextBeforeInput?.count ?? -1
                finalizeSuccess(true, liveLen)
            }

            // (C) Deferred settled-verify FLOOR. Always scheduled; if (B)
            // already resolved, the `inFlightPasteResolved` guard inside
            // finalize makes this a no-op (it only logs the VERIFY read).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }

                let settledCtx = self.textDocumentProxy.documentContextBeforeInput
                let settledLen = settledCtx?.count ?? -1
                let settledEvidence = Self.pasteEvidence(context: settledCtx, pasteText: pasteText)
                let stillEndsWith = (settledEvidence == .full)
                let hasTextNow = self.textDocumentProxy.hasText
                // A NIL settled context (`settledLen == -1`, `hasText == false`)
                // means the host's INPUT CONNECTION went away after our insert —
                // web fields (Claude Code) re-render and drop the proxy. That is
                // NOT a revert: a genuine revert leaves a SHORTER but non-nil
                // context. Treating the disconnect as failure false-flagged
                // "couldn't paste" on every review re-entry even though the text
                // landed (immediateLen>0). So a disconnected settle is
                // INCONCLUSIVE — fall back to the immediate landed evidence.
                let proxyDisconnected = (settledCtx == nil)
                // Survived = the text is still there. Strong signal: the context
                // still ends with what we inserted. Tolerant fallback: the
                // context did NOT SHRINK (settledLen >= post-insert length) —
                // absorbs a host autocorrect/keystroke mutating the inserted TAIL
                // within the 350ms window. A genuine revert SHRINKS the context
                // (non-nil, shorter) → still not-survived. Disconnect (nil) +
                // confirmed-immediate-insert ⇒ trust the immediate read (the
                // transcript is on the clipboard from publish as a silent floor
                // either way, so a rare true-miss is still recoverable, but we
                // no longer cry wolf + invite a double-paste on the common case).
                //
                // F4 decision table (plan §F4; review findings 9 + 10). `full`
                // and `none` behave EXACTLY as before — a nil/empty window
                // still falls to the `hasTextNow`/`settledLen` arm and still
                // proves nothing on its own. The WINDOWED case is what F4 had
                // to answer: iOS caps `documentContextBeforeInput`, so a paste
                // longer than the window can never be `full` no matter how
                // cleanly it landed, and the deck's review dwell widens the
                // disconnect window that then trips this floor — "the text is
                // right there but the banner says it failed". Partial evidence
                // NEVER decides survival HERE: the windowed case is answered
                // upstream, by the `textDidChange` corroborated-partial confirm
                // arm (which resolves through `finalizeSuccess`, so this closure
                // short-circuits), and by Option G downgrading this branch's
                // banner copy. A disconnect with only partial evidence stays
                // INCONCLUSIVE and is classified not-survived — which is now only
                // LOGGED (see the note where `survived` is consumed below).
                let contextDidNotShrink = (settledLen >= immediateAfterLen)
                // REVIEW BLOCKER FIX: a "settled partial + non-shrink" pair is
                // NOT independent corroboration — both derive from the same
                // `documentContextBeforeInput` read, which the proxy's local
                // cache can satisfy after a swallowed paste (Path D,
                // bug-slack-silent-paste.md). `hasText` is the one signal in
                // this block the cache can't fake, so no survival arm may
                // bypass it — and with `hasTextNow` added, this pair is
                // strictly subsumed by the `settled-no-shrink` arm. It
                // therefore contributes NOTHING as a decision and exists only
                // in the log metadata (settledOverlap) for floor calibration.
                let survived = (hasTextNow && (stillEndsWith || contextDidNotShrink))
                            || (proxyDisconnected && endsWithInserted)

                // Which arm decided, in the same order `survived` evaluates
                // them — the device gate reads this against the evidence kinds
                // and overlaps to calibrate `pasteEvidenceOverlapFloor` and to
                // catch a partial arm turning a swallowed paste into a success.
                let decisionBranch: String
                if hasTextNow && stillEndsWith {
                    decisionBranch = "settled-full"
                } else if hasTextNow && contextDidNotShrink {
                    decisionBranch = "settled-no-shrink"
                } else if proxyDisconnected && endsWithInserted {
                    decisionBranch = "disconnect-immediate-full"
                } else if proxyDisconnected {
                    decisionBranch = "disconnect-inconclusive"
                } else {
                    decisionBranch = "settled-shrank"
                }

                DiagnosticsLog.record(
                    source: "keyboard",
                    category: .pasteVerifyDeferred,
                    message: "Deferred landed-verify read-back",
                    metadata: [
                        "sessionID": pendingSessionID.uuidString,
                        "immediateLen": "\(immediateAfterLen)",
                        "settledLen": "\(settledLen)",
                        "stillEndsWith": "\(stillEndsWith)",
                        "hasText": "\(hasTextNow)",
                        "alreadyResolved": "\(self.inFlightPasteResolved)",
                        "pasteLen": "\(pasteText.count)",
                        "settledEvidence": settledEvidence.logLabel,
                        "settledOverlap": "\(settledEvidence.matchedLength(pasteLength: pasteText.count))",
                        "immediateEvidence": immediateEvidence.logLabel,
                        "immediateOverlap": "\(immediateEvidence.matchedLength(pasteLength: pasteText.count))",
                        "overlapFloor": "\(Self.pasteEvidenceOverlapFloor)",
                        "branch": decisionBranch,
                        "survived": "\(survived)",
                    ]
                )

                // (B) already classified this paste a success — nothing to do.
                guard !self.inFlightPasteResolved else { return }

                // The settled read is RECORDED, never turned into a "couldn't
                // paste" verdict. It is not an oracle in either direction:
                // build 103-108 (Claude Code) showed it reading "landed" over a
                // paste the screen never showed, and build 313 (2026-09-26,
                // session F5FCEDE4) showed the opposite — it fell back to the
                // exact pre-paste context (settledLen 104 = beforeLen, overlap
                // 0, branch settled-shrank) while the 339 chars had landed and
                // stayed. The same reading means both things, so no rule built
                // on it can be right, and every error it raised over a good
                // paste told the owner something false. The keyboard now claims
                // only what it can prove: an insert into a connected field
                // (`landed`, checked before we got here) is delivered. The
                // transcript stays on the clipboard from publish as the quiet
                // floor for the rare host that drops a paste, and it tops the
                // Recents card, one tap from re-inserting.
                if !survived {
                    DiagnosticsLog.record(
                        source: "keyboard",
                        category: .pasteRevertedAfterLanding,
                        message: "Settled read disagrees with the insert — treated as landed (the read can't tell a dropped paste from a stale one)",
                        metadata: [
                            "sessionID": pendingSessionID.uuidString,
                            "chars": "\(pasteText.count)",
                            "settledLen": "\(settledLen)",
                            "hasText": "\(hasTextNow)",
                            "settledEvidence": settledEvidence.logLabel,
                            "immediateEvidence": immediateEvidence.logLabel,
                            "branch": decisionBranch,
                        ]
                    )
                }
                finalizeSuccess(false, settledLen)
            }
        }

        // Kick off the bounded reconnect-poll. `pollForStableSession` recurses
        // via `asyncAfter` (NOT a busy-wait): it captures the prior read, and
        // after each ~30ms tick compares the fresh read to it. Two consecutive
        // equal reads → STABLE → insert. Hitting the ceiling → insert anyway
        // (best effort; the verify + clipboard floor catch a miss). `iteration`
        // is 1-based for the first comparison.
        func pollForStableSession(previous: String?, previousHasText: Bool, iteration: Int) {
            // Re-validate the in-flight guard / pending session each tick so a
            // teardown mid-poll releases cleanly. Belt to the teardown's
            // suspenders: if the flag dropped while a deck sits in
            // `.inserting`, hand it back so it can paste on re-present
            // instead of stranding (no-op for any other phase).
            guard self.isAutoPasteInsertInFlight else {
                if let deck = self.hub.activeDeck {
                    self.hub.returnAskDeckToResolved(deck.token)
                }
                return
            }
            let elapsedMs = Int(Date().timeIntervalSince(pollStartedAt) * 1000)

            let current = self.textDocumentProxy.documentContextBeforeInput
            let currentHasText = self.textDocumentProxy.hasText

            // STABLE when this read matches the previous one (both context and
            // hasText unchanged). The FIRST comparison is the pre-poll read vs
            // the read ~30ms later, so a native/fast host (whose context never
            // keeps changing) is stable on poll #1 → minimal added latency, no
            // regression. A heavy re-mounting web field whose context is still
            // growing fails the equality and polls again until it settles.
            let stable = (current == previous) && (currentHasText == previousHasText)

            if stable || elapsedMs >= pollCeilingMs {
                performInsertAndVerify(iterations: iteration, settleMs: elapsedMs)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pollIntervalMs)) {
                pollForStableSession(previous: current, previousHasText: currentHasText, iteration: iteration + 1)
            }
        }
        // First read is taken on the next tick (one run-loop hop after the
        // `adjustTextPosition(0)` re-sync request, matching the original
        // single-hop semantics), then compared against the tick after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pollIntervalMs)) {
            pollForStableSession(
                previous: self.textDocumentProxy.documentContextBeforeInput,
                previousHasText: self.textDocumentProxy.hasText,
                iteration: 1
            )
        }
    }

    /// v7 flush logic. Match-fresh-payload happy-path FIRST (per design Q1
    /// user-decision §4.6.A), then sad-path TerminalSessionLog cleanup, then
    /// sad-path synthetic `.failed` cleanup. Running terminal cleanup before
    /// the match check would race-clear pending and drop a valid paste —
    /// `completeEndOfRecording` writes the terminal-log entry and the
    /// publish payload in the same call, and they can land in the same wake
    /// window.
    private func flushPendingAutoPasteIfPossible() {
        // Diagnostics: only log the Full-Access skip when a pending session
        // exists and is therefore actually being lost. Logging on every
        // routine refresh (e.g. textDidChange in a non-Full-Access host)
        // would flood the buffer with noise.
        guard hasFullAccess else {
            if let pending = readPendingPasteSession() {
                DiagnosticsLog.record(
                    source: "keyboard",
                    category: .pasteSkipNoFullAccess,
                    message: "No Full Access at flush",
                    metadata: ["pendingSessionID": pending.id.uuidString]
                )
            }
            return
        }
        guard let session = readPendingPasteSession() else {
            // No pending paste at all: any deck is holding a session whose paste
            // can never happen. Ending it here is what keeps a stranded deck from
            // blocking dictation for the rest of the process (F1b makes the deck
            // modal, so a deck that outlives its session would be a dead end).
            if let stranded = hub.activeDeck { endDeck(sessionID: stranded.sessionID) }
            return
        }

        // SUPERSESSION. F1b stops the KEYBOARD starting a second dictation over a
        // held paste, but the main app can still start one (the FAB), and that
        // overwrites the single pending-paste slot. The deck's payload slot is
        // gone with it, so the older deck is terminal.
        if let stale = hub.activeDeck, stale.sessionID != session.id {
            endDeck(sessionID: stale.sessionID)
        }

        // ── F2: phase-aware deck branch, BEFORE the freshness read ──
        //
        // Ordering is the whole fix. `readFresh()` drops a payload older than
        // ClipboardHandoff.freshnessWindow (30s), and a worst-case deck (three
        // cards × a 10s dwell) runs past that — so an expired payload never even
        // reached the deck gate below and fell straight into the no-payload
        // terminal cleanup: the owner answered every card and NOTHING pasted.
        // A resolved deck already holds its exact text, captured at hold time
        // from the payload; nothing about it can go stale, so no age check
        // applies to it.
        if let deck = hub.askDeck(for: session.id) {
            switch deck.phase {
            case .reviewing:
                // The owner is still choosing. Insert nothing, consume nothing,
                // clean up nothing — a re-entrant flush (phase change, keyboard
                // re-presentation) must not paste the defaults out from under
                // the cards they are tapping.
                return
            case .inserting(let held):
                // Another pass is already driving the proxy for this deck —
                // but only if one actually IS. `.inserting` with no local
                // insert in flight means the claiming controller died between
                // the claim and the insert without running its teardown
                // hand-back (ghost controllers skipping `viewWillDisappear`
                // are a documented reality here). Self-heal: hand the deck
                // back and drive the insert from THIS pass, instead of
                // returning forever on a phase nobody owns.
                if isAutoPasteInsertInFlight { return }
                hub.returnAskDeckToResolved(deck.token)
                DiagnosticsLog.record(
                    source: "keyboard", category: .pasteSuccess,
                    message: "ask-deck: healed an orphaned .inserting claim",
                    metadata: ["sessionID": session.id.uuidString]
                )
                insertResolvedDeckText(held, session: session.id, deck: deck)
                return
            case .resolved(let text):
                insertResolvedDeckText(text, session: session.id, deck: deck)
                return
            }
        }

        let payload = ClipboardHandoff.readFresh()
        let projection = PipelinePhaseProjection.read()

        // Happy path: payload session ID matches our pending session.
        if let payload, payload.sessionID == session.id {
            // Single paste path: iOS only presents the keyboard when a text
            // input is focused, so if we're flushing there IS an input — paste
            // wherever the cursor is now. The old documentIdentifier /
            // keyboardType "same-field" guards were removed deliberately: they
            // rejected a valid paste whenever Jot re-rendered its own field on
            // stop, which is what forced the in-process side-door insert and
            // produced the in-app double paste.
            // Empty-text diagnostic: an empty payload would no-op inside
            // `insertTrackedText` and silently fall through the rest of the
            // happy-path cleanup. Surface it explicitly in the log so a
            // user reproducing the regression can see "publish landed but
            // it was empty" as a distinct failure mode from "publish never
            // landed". Behavior-preserving — same cleanup path runs.
            if payload.text.isEmpty {
                DiagnosticsLog.record(
                    source: "keyboard",
                    category: .pasteSkipEmptyText,
                    message: "Payload text was empty",
                    metadata: ["sessionID": session.id.uuidString]
                )
                ClipboardHandoff.markConsumed()
                clearPendingPasteSession()
                endDeck(sessionID: session.id)
                renderRootView()
                return
            }
            // ── Ask-before-paste gate ──
            // If the app staged correction asks for this session, HOLD the paste:
            // open the deck and return WITHOUT inserting or consuming anything (so
            // teardown mid-deck can neither drop nor double the text — pending
            // stays intact + the clipboard floor survives). Resolution re-enters
            // this flush and takes the F2 branch above.
            //
            // No "already handled" set is needed any more: every terminal path
            // that clears the deck also clears the pending session (successful
            // paste, clipboard fallback, terminal-log cleanup, launch deadline,
            // teardown-consume), so a session can never arrive here twice.
            if let staged = CorrectionBridge.readAsks(sessionID: session.id),
               !staged.asks.isEmpty,
               // V2-3: teach-only asks (split-word merge class) must NEVER
               // hold the paste — if EVERY staged ask is post-paste-only,
               // skip the hold entirely; they surface via the post-paste
               // teach strip instead (`maybeShowCorrectionNudge`).
               staged.asks.contains(where: { $0.postPasteOnly != true }) {
                // The baseline is captured HERE, once, from the payload we just
                // read — the resolution never depends on a second (possibly
                // expired) transport read, and it is the exact string the
                // producer resolved its edit descriptors against.
                let token = hub.beginAskDeck(staged, baseline: payload.text)
                DiagnosticsLog.record(
                    source: "keyboard", category: .vocabularyGate,
                    message: "ask-before-paste: holding for review deck",
                    metadata: ["sessionID": session.id.uuidString,
                               "asks": "\(staged.asks.count)",
                               "generation": "\(token.generation)"])
                return
            }

            performAutoPasteInsertion(
                pasteText: payload.text, pendingSessionID: session.id, deck: nil)
            return
        }

        // Diagnostics: classify the non-happy-path branches. These splits
        // mirror the failure modes we want visible in Help → Diagnostics:
        //   - no payload at all (publish hasn't landed yet, or never will)
        //   - payload exists but sessionID doesn't match (cross-session race)
        // "No payload yet" is the normal state of every flush between Stop and
        // publish (phase changes + 3s heartbeats fire several per dictation);
        // recording it evicted the real paste evidence from the 100-entry
        // ring. It stays in os_log only. The silent CLEARS below — where a
        // dictation is actually given up on — are what reach Diagnostics.
        if payload == nil {
            keyboardLog.debug("Flush ran with no fresh transcript for \(session.id)")
        } else if let payload {
            DiagnosticsLog.record(
                source: "keyboard",
                category: .pasteSkipSessionMismatch,
                message: "Payload session ID did not match pending",
                metadata: [
                    "payloadSessionID": payload.sessionID?.uuidString ?? "<nil>",
                    "pendingSessionID": session.id.uuidString
                ]
            )
            // Option-4 stale-payload hygiene (plan §6 Option 4): a payload whose
            // sessionID is neither the current pending nor a just-published blob
            // (within a short grace) is a leftover from a prior session that
            // `markConsumed()` never cleared (e.g. a paste we kept pending, or a
            // session that never reached the keyboard). Left in place it makes
            // EVERY future flush log a spurious `pasteSkipSessionMismatch` until
            // the 30s freshness window expires. Clear it so future sessions start
            // clean. Behavior-neutral: this payload already does not match our
            // pending and is NOT being pasted here either way; the grace protects
            // a payload that is racing in just ahead of its own pending write.
            let staleGrace: TimeInterval = 2
            if payload.sessionID != session.id,
               Date().timeIntervalSince(payload.timestamp) >= staleGrace {
                ClipboardHandoff.markConsumed()
            }
        }

        // Sad path: no matching payload. Consult terminal state. The UUID
        // state machine is the source of truth — terminal-without-payload
        // means `.failed` / cancelled OR `.idle` observed after the 30s
        // freshness window expired. Either way, nothing further is coming
        // for our session.
        //
        // The `hadPublish` bit on TerminalSessionRecord is retained for
        // diagnostic logging only — it does NOT gate cleanup (per design
        // Q2). Gating on `!hadPublish` would leave pending stuck whenever
        // `.idle` (hadPublish=true) was observed after freshness expired.
        if TerminalSessionLog.contains(sessionID: session.id) {
            keyboardLog.info("Pending session \(session.id) appears in terminal log; clearing.")
            DiagnosticsLog.record(
                source: "keyboard", category: .pasteSkipOther,
                message: "Gave up on paste — session ended with no transcript to paste",
                metadata: ["sessionID": session.id.uuidString]
            )
            clearPendingPasteSession()
            // Session-scoped: a deck for a DIFFERENT session is untouched.
            endDeck(sessionID: session.id)
            renderRootView()
            return
        }

        // Synthetic `.failed` from stale heartbeat with sessionID matching
        // ours. Catches the dead-writer case where the app crashed before
        // writing to the terminal log.
        if let projection,
           projection.sessionID == session.id,
           projection.phase == .failed {
            keyboardLog.info("Pending session \(session.id) — projection synthesizes .failed (likely dead writer); clearing.")
            DiagnosticsLog.record(
                source: "keyboard", category: .pasteSkipOther,
                message: "Gave up on paste — Jot stopped responding",
                metadata: ["sessionID": session.id.uuidString]
            )
            clearPendingPasteSession()
            endDeck(sessionID: session.id)
            renderRootView()
            return
        }

        // Otherwise: session is still in flight; leave pending intact. Next
        // wakeup (Darwin notification, presentation event, or stale-deadline
        // task) will re-enter this function.
    }

    // Streaming-partial, streaming-loading, warm-hold-nudge, and correction-asks
    // feed subscriptions + their projected state moved to `KeyboardStreamingHub`
    // (process-lifetime, observed by every controller). The controller-scoped
    // nudge ACTIONS (accept/dismiss/finish, paste-time correction trigger) still
    // live on the controller and now mutate hub state via `hub.*` mutators.

    // MARK: - Pipeline phase observer (v7 auto-paste design)

    private func startObservingPipelinePhase() {
        guard pipelinePhaseObserver == nil else { return }
        pipelinePhaseObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.pipelinePhaseChanged
        ) { [weak self] in
            self?.refreshPipelinePhaseSideEffects()
        }
    }

    /// Controller-scoped HALF of the old `refreshPipelinePhase` (plan §"phase
    /// split", option 2). The hub independently owns the phase STATE
    /// (`KeyboardStreamingHub.refreshPipelinePhaseState` → `recordingState`
    /// apply + zombie-freeze suppression) via its OWN `pipelinePhaseChanged`
    /// observer. THIS method runs ONLY the proxy / per-presentation side-effects:
    /// arm/cancel the stale-deadline task, cancel the launch deadline on proof of
    /// life, clear `stopRequestPosted`, and run the auto-paste flush.
    ///
    /// These side-effects read the pipeline projection / `ClipboardHandoff`
    /// DIRECTLY — they do NOT read `recordingState` — so they are independent of
    /// the hub's state-apply and there is no cross-observer ordering dependency.
    /// The paste path is byte-for-byte unchanged from the pre-hub
    /// `refreshPipelinePhase`. The recovered-zombie tombstone now lives on the
    /// hub (`hub.recoveredZombieFreeze`); we read it here (without mutating it —
    /// the hub owns its clearing) to apply the SAME suppression to the
    /// projection these side-effects act on, preserving prior behavior.
    private func refreshPipelinePhaseSideEffects() {
        guard hasFullAccess else { return }
        var projection = PipelinePhaseProjection.read()
        // Mirror the hub's zombie suppression for the side-effect projection so a
        // recovered dead-app session can't re-arm the stale deadline or block a
        // launch-deadline cancel. Read-only here — the hub clears the tombstone
        // when the writer advances.
        if let freeze = hub.recoveredZombieFreeze {
            if let p = projection,
               p.sessionID == freeze.sessionID,
               p.lastUpdatedAt <= freeze.frozenAt,
               p.phase.isActiveNonTerminal {
                projection = nil
            }
        }
        armOrCancelStaleDeadline(for: projection)
        cancelLaunchDeadlineIfProofOfLife(projection)
        // B3 — resolve the "stop pending" VIEW when the RECORD advances off the
        // live-capture set {recording, paused} — the app's ack — NOT on a local
        // timer. `stopRequestPosted` is now a pure view of the record ("I posted a
        // stop AND the record still shows a live capture"); the moment the record
        // leaves {recording, paused} (→ in-flight tail / terminal) it clears.
        // Clearing flips the speak button's `.disabled` back off, so we re-render
        // to pick up the change live rather than on the next state-derived paint.
        if let phase = projection?.phase,
           phase != .recording, phase != .paused,
           stopRequestPosted {
            stopRequestPosted = false
            renderRootView()
        }
        flushPendingAutoPasteIfPossible()
    }

    /// Schedules a single bounded `Task` that waits until the projection's
    /// `lastUpdatedAt + heartbeatStaleThreshold (30s)` and then re-reads.
    /// Cancelled and re-armed against the new lastUpdatedAt on every observed
    /// phase change. Cancelled and dropped when phase transitions to a
    /// terminal state (`.idle` / `.failed`). One outstanding task at a time.
    ///
    /// Per design §4.6: this catches the dead-writer case. App crashes mid-
    /// transcription, no further heartbeat ever arrives, this task fires at
    /// deadline +30s, re-reads the projection, sees the synthetic `.failed`
    /// (read() age-gates non-idle projections), and triggers the terminal
    /// cleanup branch in `flushPendingAutoPasteIfPossible`.
    private func armOrCancelStaleDeadline(for projection: PipelinePhaseProjection?) {
        pipelineStaleDeadlineTask?.cancel()
        pipelineStaleDeadlineTask = nil
        guard let projection,
              projection.phase != .idle,
              projection.phase != .failed
        else { return }
        let deadline = projection.lastUpdatedAt
            .addingTimeInterval(PipelinePhaseProjection.heartbeatStaleThreshold)
            .addingTimeInterval(2)
        let interval = max(0, deadline.timeIntervalSinceNow)
        pipelineStaleDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            self?.refreshPipelinePhaseStateAndSideEffects()
        }
    }

    /// Re-read the pipeline projection into BOTH the hub's phase STATE and the
    /// controller's proxy side-effects, in the original order. Used by the
    /// deadline/watchdog Tasks (which are self-driven re-reads, not Darwin
    /// posts, so neither observer fires for them). Equivalent to the pre-hub
    /// `refreshPipelinePhase()`.
    private func refreshPipelinePhaseStateAndSideEffects() {
        hub.refreshPipelinePhaseState()
        refreshPipelinePhaseSideEffects()
    }

    /// Arm the dead-app watchdog after a recording-control tap. Snapshots the
    /// pipeline projection's freshness; if `lastUpdatedAt` has not advanced
    /// within `controlTapLivenessCeiling`, the main app was jetsammed
    /// mid-recording and we recover the keyboard to idle. A live app refreshes
    /// the projection within the 3s heartbeat (and immediately when it processes
    /// the control), so it never trips this. Tap-triggered only — no polling. A
    /// newer control tap (or a recovery) supersedes any in-flight watchdog.
    /// Re-arm the dead-app watchdog on re-present IFF the projection is still an
    /// active non-terminal phase (a control the app never serviced). Without this,
    /// a keyboard that was dismissed after a control tap (cancelling the prior
    /// watchdog Task in teardown) and re-presented onto a suspended app would only
    /// recover via the 30s stale path. Skips a session already tombstoned by a
    /// prior recovery (the hub's `recoveredZombieFreeze`) so we don't re-arm
    /// against an already-handled zombie.
    private func rearmDeadAppWatchdogIfFrozen() {
        guard hasFullAccess else { return }
        guard let projection = PipelinePhaseProjection.read(),
              projection.phase.isActiveNonTerminal else { return }
        if let freeze = hub.recoveredZombieFreeze,
           projection.sessionID == freeze.sessionID,
           projection.lastUpdatedAt <= freeze.frozenAt {
            return  // already recovered this exact frozen session
        }
        armDeadAppWatchdog(reason: "re-present")
    }

    private func armDeadAppWatchdog(reason: String) {
        deadAppWatchdogTask?.cancel()
        // B3 — base recovery liveness on the record's unified `liveness` stamp
        // (1s cadence) rather than `lastUpdatedAt` (3s heartbeat). `liveness` is
        // the single "is the writer alive right now?" stamp the start decision
        // also uses, so the watchdog and `recordStartDecision()` share one
        // freshness notion. `livenessOrLegacy` falls back to `lastUpdatedAt` for
        // a pre-A2 blob (none in this build, but keeps the reader total).
        let baseline = PipelinePhaseProjection.read()?.livenessOrLegacy
        deadAppWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.controlTapLivenessCeiling))
            } catch {
                return  // cancelled: keyboard dismissed, superseded, or recovered
            }
            guard let self, !Task.isCancelled else { return }
            let latest = PipelinePhaseProjection.read()
            // Recover ONLY on the unambiguous zombie signal: the record is STILL
            // an active NON-TERMINAL phase AND its `liveness` has not advanced past
            // the tap-time baseline. A live writer — even backgrounded — stamps
            // `liveness` every 1s (and advances on the control ack), so any advance
            // means alive; a terminal (.idle/.failed) / cleared / missing record
            // means the app (or the normal path) already handled it — stand down
            // and never clear a still-valid pending paste.
            //
            // This is the BOUNDED, after-the-fact recovery — it resets the
            // keyboard's LOCAL UI only. The genuinely-suspended orphan (held mic /
            // un-finalized session) is reconciled APP-side on next foreground
            // (§2.4 M2 — `RecordingService.reconcileOrphanedSessionOnForeground`).
            // It covers `.recording/.paused` AND the in-flight tail
            // (`.transcribing/.processing/.cleaning/...`) so a Stop tapped while
            // the app is suspended mid-transcription still recovers here.
            if let baseline, let latest,
               latest.livenessOrLegacy <= baseline,
               latest.phase.isActiveNonTerminal {
                self.recoverFromUnresponsiveApp(reason: reason)
            } else {
                self.deadAppWatchdogTask = nil
            }
        }
    }

    /// Reset the keyboard out of a zombie "recording" UI after the main app was
    /// found unresponsive on a control tap. Does NOT write the shared projection
    /// blob (writer-owns-clears — `PipelinePhaseProjection`); it resets only the
    /// keyboard's local mirror + stuck control state, mirroring the synthetic
    /// `.failed` recovery the 30s stale path runs, just fired early.
    private func recoverFromUnresponsiveApp(reason: String) {
        keyboardLog.notice("Liveness: main app silent after \(reason, privacy: .public) tap — recovering keyboard to idle")
        DiagnosticsLog.record(
            source: "keyboard",
            category: .appUnresponsiveRecovery,
            message: "App unresponsive after \(reason) — recovered to idle",
            metadata: ["reason": reason]
        )
        // Tombstone this exact frozen session so a keyboard dismiss/re-present
        // within the 30s stale window can't resurrect it from the still-active
        // shared projection (the dead writer never goes terminal).
        if let frozen = PipelinePhaseProjection.read(),
           frozen.phase.isActiveNonTerminal,
           let frozenSession = frozen.sessionID {
            hub.recoveredZombieFreeze = (frozenSession, frozen.lastUpdatedAt)
        }
        stopRequestPosted = false
        recordingState.applyPipelineProjection(nil)
        hub.clearStreamingPartialForNewSession()
        recordingState.updateLoadingVariantLabel("")
        // Read the stranded session BEFORE clearing pending — the hold deck for
        // it is terminal too (its paste is never coming), and deck cleanup is
        // session-scoped so a deck for anything else is left alone.
        let strandedSession = readPendingPasteSession()?.id
        clearPendingPasteSession()
        if let strandedSession { endDeck(sessionID: strandedSession) }
        pipelineStaleDeadlineTask?.cancel()
        pipelineStaleDeadlineTask = nil
        deadAppWatchdogTask?.cancel()
        deadAppWatchdogTask = nil
        renderRootView()
    }

    // MARK: - Selection state

    /// Reconstructs selection context because iOS may truncate
    /// `UITextDocumentProxy.selectedText` for long selections.
    private func reconstructedSelectionTextFromDocumentContext() -> String? {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let selected = textDocumentProxy.selectedText ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        guard !selected.isEmpty || !(before + after).isEmpty else { return nil }
        let reconstructed = before + selected + after
        let selection = reconstructed.trimmingCharacters(in: .whitespacesAndNewlines)
        return selection.isEmpty ? nil : selection
    }

    private func refreshSelectionState() {
        guard let selectedText = reconstructedSelectionTextFromDocumentContext() else {
            selectedTextSnapshot = nil
            return
        }
        selectedTextSnapshot = selectedText
    }

    // MARK: - History
    //
    // History reload moved to `KeyboardStreamingHub` (it owns the
    // `historyMirrorUpdated` feed + the `historyEntries` projection). The
    // controller reads `hub.historyEntries` (via its `historyEntries` computed
    // pass-through) into `KeyboardViewInputs` in `syncKeyboardInputs()` — a plain
    // SNAPSHOT, not a live `@Observable`. The hub fires its `onShouldRender` hook
    // when `historyEntries` changes, which re-renders this controller so the
    // RecentsStrip shows a just-dictated transcript without waiting for re-present.

    /// Phase 2: the legacy `HistoryOverlay` modal was replaced by the
    /// always-visible `RecentsStrip` at the top of the keyboard. Tapping a
    /// row inserts the transcript into the host. Kept on the controller
    /// because the keyboard's renderRootView is the one path everything
    /// hangs off — the row's tap handler is wired through
    /// `makeKeyboardView`'s `onInsertHistoryEntry` closure.
    private func insertHistoryEntry(_ entry: TranscriptHistoryMirror.Entry) {
        insertTrackedText(entry.text)
        renderRootView()
    }

    /// Inserts an arbitrary string into the host. Used by the recents
    /// strip's just-now row (the user re-inserting their own most-recent
    /// dictation by tapping the green marker).
    private func insertHistoryText(_ text: String) {
        guard !text.isEmpty else { return }
        insertTrackedText(text)
        renderRootView()
    }

    // MARK: - Key dispatch

    private func handleKeyTap(_ key: KeyboardKeyDescriptor) {
        switch key {
        case .literal, .space, .returnKey:
            if let text = key.insertion() {
                insertTrackedText(text)
                renderRootView()
            }

        case .backspace:
            textDocumentProxy.deleteBackward()
            renderRootViewIfActionAvailabilityChanged()
        }
    }

    // MARK: - Backspace repeat

    /// Routes press state-change events. Only backspace currently cares —
    /// everything else is a no-op so the keyboard view can fire the same
    /// callback for every key without the controller growing a per-key
    /// dispatch table.
    private func handleKeyPressChange(_ key: KeyboardKeyDescriptor, pressed: Bool) {
        guard case .backspace = key else { return }
        handleBackspacePressChange(pressed)
    }

    /// Backspace hold-to-delete. Finger-down schedules the initial delay
    /// (~0.4s), then a ~0.07s repeating tick until finger-up. `Timer` is
    /// intentionally chosen over `Task` / `DispatchSourceTimer` — it's the
    /// simplest shape that preserves MainActor-isolated `deleteBackward`
    /// calls without a Sendable dance.
    private func handleBackspacePressChange(_ pressed: Bool) {
        cancelBackspaceRepeat()
        guard pressed else { return }
        // `Timer.scheduledTimer` callbacks are typed `(Timer) -> Void` — not
        // MainActor-isolated in Swift 6's eyes even though the run loop is
        // the main one. `MainActor.assumeIsolated` is the right escape hatch:
        // we know the timer was scheduled on the main run loop from a
        // MainActor context, and we need to call MainActor-isolated methods
        // (`deleteBackward`, `startBackspaceTick`) from inside.
        backspaceRepeatTimer = Timer.scheduledTimer(
            withTimeInterval: 0.4,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startBackspaceTick()
            }
        }
    }

    private func startBackspaceTick() {
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = Timer.scheduledTimer(
            withTimeInterval: 0.07,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textDocumentProxy.deleteBackward()
                // Repeat tick fires the selection haptic per character
                // deleted — matches iOS native, where the haptic-per-tick
                // is what makes hold-to-delete feel controlled rather than
                // like a runaway. Research §4.2: `repeat = .selectionChanged`.
                self.feedback.selectionTick()
            }
        }
    }

    private func cancelBackspaceRepeat() {
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    // MARK: - Keyboard-active heartbeat

    /// Begin writing `AppGroup.keyboardActiveHeartbeat` immediately and then
    /// every ~1s. The immediate write makes the cue dismiss as fast as
    /// possible once the Jot keyboard rises; the repeating write keeps the
    /// heartbeat fresh against the 3s stale window. A Timer + UserDefaults
    /// write is trivially within the keyboard's ~60MB budget. Mirrors the
    /// `backspaceRepeatTimer` Swift-6 main-actor escape-hatch style.
    private func startKeyboardActiveHeartbeat() {
        AppGroup.keyboardActiveHeartbeat = Date()
        keyboardActiveHeartbeatTimer?.invalidate()
        keyboardActiveHeartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                AppGroup.keyboardActiveHeartbeat = Date()
            }
        }
    }

    private func stopKeyboardActiveHeartbeat() {
        keyboardActiveHeartbeatTimer?.invalidate()
        keyboardActiveHeartbeatTimer = nil
    }

    // MARK: - Outbound

    /// Single launch destination — bring Jot to the foreground so the
    /// host's `.onOpenURL` handler can route to dictation auto-start.
    private static let containingAppLaunchURL = URL(string: "jot://dictate")!

    private func launchJotAppForDictation() {
        guard hasFullAccess else {
            openHostSettings()
            return
        }
        openContainingApp(Self.containingAppLaunchURL)
    }

    /// Outcome of a mic CTA tap, decided up-front from the current keyboard
    /// state. Building the decision in ONE read closes the "duplicate rapid
    /// tap overwrites pending" race: by the time we branch on the decision,
    /// the only side-effect a noop has produced is a log line.
    private enum MicTapDecision {
        case start
        case stop
        case noop(reason: String)
    }

    private func decideMicTap() -> MicTapDecision {
        guard hasFullAccess else { return .noop(reason: "no-full-access") }
        if stopRequestPosted { return .noop(reason: "stop-pending") }
        if recordingState.isInflightPostRecording { return .noop(reason: "in-flight") }
        // `arming` is the transient start-requested-but-no-buffer-yet state (B2):
        // tapping does nothing (the CTA is also `.disabled` while arming), so the
        // tap resolves to neither a stop nor a fresh start. Without this, a tap
        // mid-arm would fall to `.start` here while the record reads `.stop` — a
        // divergence between the local mirror and the record-based start decision.
        if recordingState.isArming { return .noop(reason: "arming") }
        // STOP is decided before the deck guard below: an APP-initiated
        // dictation (FAB / DictateIntent / Siri) can be live while a deck is
        // still reviewing, and the keyboard must stay able to stop the mic
        // from the surface the user is on — the deck is modal for STARTING,
        // never for stopping.
        if recordingState.isRecording { return .stop }
        // F1b — a held paste is MODAL for STARTING a dictation. The
        // pending-paste slot, the handoff payload and the asks blob are each
        // single-slot and cleared globally, so a second dictation would
        // overwrite the transport the open deck is still gating and then race
        // its cleanup. The SwiftUI CTA is also `.disabled` for this; the guard
        // is defense-in-depth against optimistic-UI lag, same as the states
        // above.
        if hub.hasActiveDeck { return .noop(reason: "ask-deck-open") }
        return .start
    }

    // MARK: - B1 record-based start decision (LIVE — routes the tap, §2.4a)

    /// The warm-vs-cold start decision, computed from the unified
    /// `RecordingRecord` (state + liveness + warm window) instead of the legacy
    /// warm keys + ping/pong. **B1 promoted this from A4's log-only shadow to the
    /// LIVE decision `handleMicCTATap` routes on**, fenced behind Build A's
    /// device-confirmed shadow agreement.
    ///
    /// `.cold` is the record's verdict "the app is not alive in a resumable
    /// state" — the LIVE router then splits `.cold` into inline (Jot is the
    /// foreground host) vs a cold URL bounce via the ONE retained
    /// `isJotAppForeground()` read (N3 — the record answers "alive," not
    /// "foreground"). The shadow logger (`logShadowStartDecision`) still runs
    /// beside this for continued diagnostics (B4 cleanup deferred).
    private enum RecordStartDecision: String {
        case stop        // a fresh RECORDING/PAUSED record → request a stop
        case busy        // a fresh ARMING or post-recording pipeline record → ignore the tap (never stop an arming recording, never cold-start over it) — W6 regression fix
        case warmResume  // fresh warmIdle, window open → warm-resume in background
        case cold        // idle / nil / stale → inline (if Jot foreground) or cold URL bounce
        case noFullAccess
    }

    /// Pure function of the record (§2.4a). Reads `PipelinePhaseProjection`
    /// (the evolving record) and applies `decideStart(record, now)`. No
    /// side-effects, no storage mutation.
    private func recordStartDecision() -> RecordStartDecision {
        guard hasFullAccess else { return .noFullAccess }
        let now = Date()
        // Use `read()` (which already synthesizes stale warmIdle → `.idle` and
        // stale in-flight → `.failed`, §2.2) AND apply the explicit `fresh`
        // liveness check below — belt-and-suspenders, so the decision reflects
        // exactly the record state §2.4a consumes.
        guard let record = PipelinePhaseProjection.read() else { return .cold }
        let fresh = now.timeIntervalSince(record.livenessOrLegacy) < Self.livenessFresh
        switch record.phase {
        case .recording, .paused:
            // A genuinely-LIVE recording (or paused session), fresh → a stop
            // request; stale → the writer is dead, so a tap should cold-start.
            return fresh ? .stop : .cold
        case .arming, .transcribing, .processing,
             .cleaning, .rewriting, .publishing:
            // Fresh but NOT a live recording: still ARMING (coming up) or already
            // PAST it (post-recording pipeline). A tap here must NOT be turned into
            // a stop — stopping a just-armed recording is the W6 regression (a
            // duplicate callback in the mirror-lag window killed the recording that
            // had only just started). Ignore the tap (busy); never cold-start over
            // it either. Stale → the writer is dead → cold-start.
            return fresh ? .busy : .cold
        case .warmIdle:
            let windowOpen = record.warmExpiresAt.map { $0 > now } ?? false
            return (fresh && windowOpen) ? .warmResume : .cold
        case .idle, .failed:
            return .cold
        }
    }

    // MARK: - Start routing (inline vs cold)
    //
    // Warm-vs-cold is decided by `recordStartDecision()` (the record's liveness);
    // inline-vs-cold is the single `isJotAppForeground()` read (N3). The old
    // ping/pong foreground handshake (`resolveForegroundThenStart` + the
    // `appForegroundPong` observer + the `keyboardForegroundPing` post) was
    // removed in B4 — the record + the one foreground read replace it.
    // `startInlineViaDarwin` / `startColdViaURLBounce` are the two routed paths.

    /// Jot is foreground → post the Darwin Dictate tap. The app starts a normal
    /// background capture (the same path the keyboard uses in any other app) and
    /// inserts the transcribed result into the focused field on stop. The wizard
    /// (W5) handles this tap with its own observer while it is presented.
    private func startInlineViaDarwin() {
        hub.clearStreamingPartialForNewSession()
        CrossProcessNotification.post(name: CrossProcessNotification.keyboardDictateTapped)
        keyboardLog.info("Jot foreground -> inline Dictate tap (host=Jot)")
    }

    /// Jot is NOT foreground → cold-start by URL-bouncing into the app (the
    /// hero's swipe-back coaching path). Stamps a pending-paste session so the
    /// app's `onOpenURL` can `adoptSession(_:)` before recording-start.
    private func startColdViaURLBounce() {
        hub.clearStreamingPartialForNewSession()
        let session = beginPendingPasteSession()
        DiagnosticsLog.record(
            source: "keyboard",
            category: .sessionStarted,
            message: "Pending session written at start (cold start)",
            metadata: ["sessionID": session.id.uuidString]
        )
        let url = URL(string: "jot://dictate?session=\(session.id.uuidString)")
            ?? Self.containingAppLaunchURL
        openContainingApp(url, onFailure: { [weak self] in
            // The foreground read said backgrounded but Jot is actually foreground
            // (iOS refuses to URL-open an already-foreground app). Don't strand the
            // tap: drop the now-moot cold paste session and fall back to the inline
            // Darwin path. If a field is focused it records inline; if not, the
            // app's no-target fallback presents the hero. Either way — never dead.
            ClipboardHandoff.clearPendingPasteSession()
            self?.startInlineViaDarwin()
        })
        keyboardLog.info("Jot backgrounded -> URL bounce (cold start)")
        // In-app-visible breadcrumb: the URL bounce re-enters the app through
        // `triggerAutoStart` (forceStop + fresh start) — if a live recording
        // dies and the strip flashes "Starting", THIS line in Diagnostics says
        // the bounce fired (the W6 bug's LINK-B suspect). One tap should log
        // either the inline-Darwin line OR this — never both.
        // What the warm/cold decision saw, so a cold start while Jot still
        // holds the mic says WHY: a stale liveness stamp (the app stopped
        // stamping — suspended, or its stamper died), a non-warm phase, or an
        // expired warm window.
        let record = PipelinePhaseProjection.read()
        let now = Date()
        DiagnosticsLog.record(
            source: "keyboard",
            category: .recordingOutcome,
            message: "Dictate tap took the URL-bounce (cold) path",
            metadata: [
                "phase": record.map { "\($0.phase)" } ?? "none",
                "livenessAgeS": record.map { String(format: "%.1f", now.timeIntervalSince($0.livenessOrLegacy)) } ?? "none",
                "warmExpiresInS": record?.warmExpiresAt.map { String(format: "%.0f", $0.timeIntervalSince(now)) } ?? "none",
            ]
        )
    }

    private func handleMicCTATap() {
        // Warm-vs-cold reads the unified RecordingRecord, NOT the legacy warm keys
        // + ping/pong. The record's `liveness` answers "is the writer alive right
        // now?" from one atomic blob (`recordStartDecision()`), so the 120ms
        // ping/pong round-trip and the separate warm `expiresAt`/`heartbeat` gate
        // are gone from the start path. A backgrounded-ALIVE app stamps `liveness`
        // within `livenessFresh`, so "backgrounded" is never misread as "dead" —
        // no app-wake on a start that should warm-resume in place.

        // Local noop / stop / start triage from the record MIRROR (`recordingState`):
        //   • noop  — stop already posted, in-flight tail, or arming (transient)
        //   • stop  — a live recording/paused session → request a stop
        //   • start — nothing live locally → resolve the START routing from the
        //             record below (warm-resume / inline / cold)
        // This keeps the in-flight + stop-pending + arming guards intact; B1 flips
        // only the warm-vs-cold START routing onto the record.
        switch decideMicTap() {
        case .noop(let reason):
            // The mic CTA is also `.disabled(...)` at the SwiftUI layer for
            // these states — this guard is defense-in-depth against
            // optimistic-UI lag (per design §4.6.D). On `no-full-access` the
            // SwiftUI layer routes the tap to "Unlock", so this branch is
            // expected only for `stop-pending` / `in-flight` / `arming`.
            if reason == "no-full-access" {
                openHostSettings()
            } else {
                keyboardLog.info("mic tap noop: \(reason, privacy: .public)")
            }
            return

        case .start:
            // B1 — resolve warm-vs-cold from the RECORD. The record answers
            // "alive in a resumable state," NOT "foreground"; the ONE retained
            // `isJotAppForeground()` read (N3) splits the foreground-host (W5 /
            // in-Jot inline) case from the backgrounded cold-start. This is the
            // accepted 2.5s-stale read, scoped to the foreground-host branch only
            // — never on the hot warm-vs-cold decision.
            switch recordStartDecision() {
            case .noFullAccess:
                openHostSettings()

            case .warmResume:
                // Warm-hold is ONLY a "start faster" optimisation — it must not
                // change WHERE a keyboard dictation goes. If Jot is FOREGROUND the
                // user is dictating inside the app, which must record INLINE (save
                // NO transcript) exactly as without warm-hold. So even when the
                // record says warm-resume, route INLINE when Jot is the foreground
                // host; only warm-resume in the background (the no-foreground fast
                // path — the warm engine still makes the inline start fast).
                if hasFullAccess, AppGroup.isJotAppForeground() {
                    keyboardLog.info("Record warm-idle but Jot is foreground -> routing inline (no warm capture)")
                    startInlineViaDarwin()
                } else {
                    hub.clearStreamingPartialForNewSession()
                    CrossProcessNotification.post(name: CrossProcessNotification.warmResumeRequested)
                    keyboardLog.info("Record warm-idle + window open + Jot backgrounded -> warm-resume; skipping URL bounce")
                }

            case .cold:
                // The record says "not alive in a resumable state." Split inline
                // vs cold on the SINGLE foreground-host read (N3): Jot foreground
                // → inline Darwin tap (W5 / in-Jot dictation, no URL bounce iOS
                // would refuse anyway); else cold-start via the URL bounce.
                if hasFullAccess, AppGroup.isJotAppForeground() {
                    keyboardLog.info("Record cold + Jot foreground -> inline Darwin tap (host=Jot)")
                    startInlineViaDarwin()
                } else {
                    startColdViaURLBounce()
                }

            case .busy:
                // The record is ARMING (coming up) or in its post-recording
                // pipeline — a fresh in-flight state that is NOT a live recording.
                // Ignore the tap: do NOT requestStop (stopping the just-armed
                // recording is the W6 regression) and do NOT cold-start over it.
                // The mirror will catch up in a beat; the user can stop once it's
                // actually recording.
                keyboardLog.notice("Record reads arming/pipeline on a local .start -> ignoring (busy)")
                DiagnosticsLog.record(
                    source: "keyboard", category: .recordingOutcome,
                    message: "mic tap ignored — record arming/pipeline (busy, W6 fix)"
                )

            case .stop:
                // The record reads a fresh LIVE recording/paused session that the
                // local mirror hasn't caught up to yet (it returned `.start`). Treat
                // as a stop request so we don't cold-start over a live session. Rare
                // race; the record is authoritative.
                keyboardLog.notice("Record reads live on a local .start -> routing stop (mirror lag)")
                requestStop()
            }

        case .stop:
            requestStop()
        }
    }

    /// Post the cross-process stop request. Factored out of `handleMicCTATap` so
    /// both the local `.stop` decision and the record-authoritative mirror-lag
    /// race branch share one path.
    private func requestStop() {
        // Arm the App Group pending-paste session BEFORE posting the
        // stop request so the upcoming publish can match on it. The
        // session UUID itself doesn't need to be passed anywhere — the
        // publish path matches on the freshly-written pending session.
        // This restores auto-paste on the normal flow (Speak → dictate
        // → Stop → paste at cursor). The duplicate-rapid-tap race that
        // motivated removing this call is still closed by the
        // `.disabled` modifier on the speak button + `decideMicTap()`
        // returning `.noop` for `stop-pending` / `in-flight` / `arming` states.
        let stopSession = beginPendingPasteSession()
        DiagnosticsLog.record(
            source: "keyboard",
            category: .sessionStopRequested,
            message: "Pending session written at stop",
            metadata: ["sessionID": stopSession.id.uuidString]
        )
        // B3 — `stopRequestPosted` is no longer the CORRECTNESS source for "stop
        // resolved"; that is now derived from the RECORD advancing off
        // {recording, paused} (see `refreshPipelinePhaseSideEffects`). It is kept
        // ONLY as a transient VIEW flag ("I posted a stop AND the record still
        // shows recording") so the CTA stays disabled in the ms before the record
        // advances. The inbound `pipelinePhaseChanged` clears it the moment the
        // record leaves `.recording`.
        stopRequestPosted = true
        renderRootView()
        CrossProcessNotification.post(name: CrossProcessNotification.stopRequested)
        keyboardLog.info("Posted cross-process recording stop request")
        armDeadAppWatchdog(reason: "stop")

        // Single 750ms post-tap resync sweep: Darwin coalesces, so cover
        // the case where the immediate `pipelinePhaseChanged` is dropped
        // or arrives before our observer is wired.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            self?.refreshPipelinePhaseStateAndSideEffects()
        }
    }

    // MARK: - Status banner (v0.4)

    private func refreshStatusBanner() {
        guard hasFullAccess else {
            setStatusBanner(nil)
            return
        }
        setStatusBanner(AppGroup.lastDictationStatusMessage)
    }

    /// Called by the SwiftUI banner overlay's `task` after ~2.5s on-screen
    /// so the next presentation doesn't re-render the same banner. Kept
    /// idempotent — clearing an already-empty slot is a no-op.
    private func clearStatusBannerSlot() {
        guard statusBanner != nil else { return }
        AppGroup.lastDictationStatusMessage = nil
        setStatusBanner(nil)
        renderRootView()
    }

    private func surfaceDictationStatusBanner(_ message: String) {
        AppGroup.lastDictationStatusMessage = message
        setStatusBanner(message)
        renderRootView()
    }

    /// Opens the keyboard's containing app via custom URL scheme.
    ///
    /// On iOS 18+, the deprecated `openURL:` selector is silently
    /// force-failed by UIKit ("BUG IN CLIENT OF UIKIT … Force returning
    /// false (NO)"). The non-deprecated selector
    /// `openURL:options:completionHandler:` still works, but only when:
    ///   1. We resolve the responder to its concrete `UIApplication` /
    ///      `UIWindowScene` type and call the typed Swift method directly
    ///      (NOT via `perform()`).
    ///   2. The user has Full Access enabled (already gated upstream).
    ///   3. The URL scheme is registered in the host's `CFBundleURLTypes`.
    ///
    /// Pattern from KeyboardKit's `Sources/KeyboardKit/Navigation/UrlOpener.swift`.
    ///
    /// Walks the entire responder chain (not first-match) — a private
    /// view subclass can respond to the selector without being a usable
    /// opener.
    private func openContainingApp(_ url: URL, onFailure: (@MainActor @Sendable () -> Void)? = nil) {
        let selector = sel_registerName("openURL:options:completionHandler:")

        // Shared failure handling — the open was refused (most commonly: Jot is
        // ALREADY foreground, which iOS refuses to URL-open, e.g. when a Dictate
        // tap's pong was missed by timing jitter) or no opener exists in the
        // responder chain. When the caller supplies `onFailure`, it owns recovery
        // (the cold-dictate path falls back to the inline Darwin tap so the tap is
        // never a silent dead-end); otherwise we clear the pending paste + banner.
        let handleFailure: @MainActor @Sendable () -> Void = { [weak self] in
            if let onFailure {
                onFailure()
            } else {
                ClipboardHandoff.clearPendingPasteSession()
                self?.surfaceDictationStatusBanner("Couldn't open Jot - tap again")
            }
        }

        let completion: @MainActor @Sendable (Bool) -> Void = { [url] success in
            if success {
                keyboardLog.info("Opened containing app for url=\(url.absoluteString, privacy: .public)")
            } else {
                keyboardLog.error("openURL completion=false for url=\(url.absoluteString, privacy: .public)")
                handleFailure()
            }
        }

        var responder: UIResponder? = self
        while let current = responder {
            defer { responder = current.next }
            guard current.responds(to: selector) else { continue }
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: completion)
                return
            }
            if let scene = current as? UIWindowScene {
                scene.open(url, options: nil, completionHandler: completion)
                return
            }
            keyboardLog.debug("Skipping non-castable responder=\(String(describing: type(of: current)), privacy: .public)")
        }

        keyboardLog.error("No UIApplication/UIWindowScene in responder chain for url=\(url.absoluteString, privacy: .public)")
        handleFailure()
    }

    /// "See all" link in the recents card header. Brings the containing
    /// app to the foreground at home (the default scene root, where the
    /// recents list lives). Distinct from `launchJotAppForDictation()` —
    /// `jot://history` is a no-op auto-start URL in `JotApp.onOpenURL`,
    /// so the user lands on the home view WITHOUT a recording kicking
    /// off behind their back.
    private func openHostHome() {
        guard hasFullAccess else {
            openHostSettings()
            return
        }
        guard let url = URL(string: "jot://history") else { return }
        openContainingApp(url)
    }

    /// Row-trailing Apple Intelligence tap on the recents card. Brings the
    /// main app to the foreground, pushes the transcript detail view, and
    /// starts the rewrite flow via `jot://transcript?id=<uuid>&ai=1`
    /// (handled by `JotApp.onOpenURL`). The `ai=1` marker is what separates
    /// this from a plain view-in-app open — see `features.md §5.2`.
    /// No dictation auto-start — the user wants to rewrite, not record.
    /// Gated on Full Access for the same reasons as `openHostHome()`:
    /// without FA, `extensionContext.open` is refused and the bounce won't
    /// reach the app.
    private func openHistoryEntryInApp(_ entry: TranscriptHistoryMirror.Entry) {
        guard hasFullAccess else {
            openHostSettings()
            return
        }
        guard let url = URL(string: "jot://transcript?id=\(entry.id.uuidString)&ai=1") else { return }
        openContainingApp(url)
    }

    /// Bounces to the Jot main app via `jot://full-access`. The app's URL
    /// handler immediately opens iOS Settings to Jot's app-settings page
    /// via `UIApplication.shared.open(openSettingsURLString)` (which only
    /// works from the main app — from a keyboard extension, that URL
    /// opens the host app's settings, not Jot's).
    ///
    /// Why not `extensionContext.open(openSettingsURLString)` directly?
    /// From a keyboard extension, `openSettingsURLString` resolves to
    /// the *host app's* settings page (the app the user is typing in —
    /// Messages, Safari, etc.), not Jot's. Useless. The URL-bounce is
    /// the only way to land on Jot's iOS-Settings page from the keyboard.
    ///
    /// Requires `jot` in the keyboard extension's `LSApplicationQueriesSchemes`
    /// (see `project.yml`'s JotKeyboard `info.properties` block). iOS 9+
    /// blocks extension URL opens for schemes not declared there.
    private func openFullAccessPrompt() {
        guard let url = URL(string: "jot://full-access") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func openHostSettings() {
        openSettingsURL(UIApplication.openSettingsURLString)
    }

    private func openSettingsURL(_ urlString: String, fallback fallbackURLString: String? = nil) {
        guard let url = URL(string: urlString) else {
            openFallbackSettingsURL(fallbackURLString)
            return
        }

        extensionContext?.open(url) { [weak self] success in
            guard !success else { return }
            Task { @MainActor in
                self?.openFallbackSettingsURL(fallbackURLString)
            }
        }
    }

    private func openFallbackSettingsURL(_ urlString: String?) {
        guard
            let urlString,
            let url = URL(string: urlString)
        else { return }

        extensionContext?.open(url, completionHandler: nil)
    }
}

private struct KeyboardActionAvailability: Equatable {
    let hasSelection: Bool
    let canUndoLastInsertion: Bool
    let canRedoInsertion: Bool
    let isMagicFollowUpActive: Bool

    static let empty = KeyboardActionAvailability(
        hasSelection: false,
        canUndoLastInsertion: false,
        canRedoInsertion: false,
        isMagicFollowUpActive: false
    )
}

@MainActor
private final class KeyboardUndoLedger {
    enum Entry {
        case insertion(String)
        case replacement(deleted: String, inserted: String)

        /// The text that should match the document's trailing context for an
        /// undo to be valid. For replacements, this is the *currently visible*
        /// rewritten text that we'll need to remove.
        var trailingTextForUndo: String {
            switch self {
            case .insertion(let text): return text
            case .replacement(_, let inserted): return inserted
            }
        }
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let maximumEntries = 20

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Diagnostic surface: lets the keyboard log the ledger growth.
    var undoStackDepth: Int { undoStack.count }

    /// How many redo steps are queued — drives the Redo tile's count badge.
    var redoStackDepth: Int { redoStack.count }

    func recordInsertion(_ text: String) {
        guard !text.isEmpty else { return }
        undoStack.append(.insertion(text))
        if undoStack.count > maximumEntries {
            undoStack.removeFirst(undoStack.count - maximumEntries)
        }
        redoStack.removeAll()
    }

    func recordReplacement(deleted: String, inserted: String) {
        guard !inserted.isEmpty else { return }
        undoStack.append(.replacement(deleted: deleted, inserted: inserted))
        if undoStack.count > maximumEntries {
            undoStack.removeFirst(undoStack.count - maximumEntries)
        }
        redoStack.removeAll()
    }

    func canUndo(contextBeforeInput: String?) -> Bool {
        undoCandidate(contextBeforeInput: contextBeforeInput) != nil
    }

    func popUndo(contextBeforeInput: String?) -> Entry? {
        guard let entry = undoCandidate(contextBeforeInput: contextBeforeInput) else {
            return nil
        }
        _ = undoStack.popLast()
        redoStack.append(entry)
        if redoStack.count > maximumEntries {
            redoStack.removeFirst(redoStack.count - maximumEntries)
        }
        return entry
    }

    func popRedo() -> Entry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        if undoStack.count > maximumEntries {
            undoStack.removeFirst(undoStack.count - maximumEntries)
        }
        return entry
    }

    private func undoCandidate(contextBeforeInput: String?) -> Entry? {
        // Just trust the stack. The proxy-buffered `hasSuffix` check
        // here was disabling Undo when the inserted text was visibly
        // there but the proxy hadn't refreshed yet — that was the §14.6
        // "Undo broken after N inserts" bug. Redo is the recovery path
        // if Undo ever deletes the wrong text.
        guard let entry = undoStack.last else { return nil }
        guard !entry.trailingTextForUndo.isEmpty else { return nil }
        _ = contextBeforeInput  // intentionally unused
        return entry
    }
}
