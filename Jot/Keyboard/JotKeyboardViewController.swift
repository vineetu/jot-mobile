import AppIntents
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
    /// Guards the success/failure finalize so exactly ONE of {textDidChange
    /// short-circuit, deferred settled-verify} runs the consume-payload body —
    /// never both (would double-consume / double-mark). Reset when a new
    /// in-flight window opens.
    private var inFlightPasteResolved = false
    // streaming-partial, streaming-loading, warm-hold-nudge, history-mirror, and
    // correction-asks feed subscriptions moved to `KeyboardStreamingHub` (one
    // process-lifetime subscription set, observed by all controllers).

    /// Live foreground-handshake state. On a Dictate "start", the keyboard pings
    /// the app and waits `foregroundPongTimeout` for `appForegroundPong`: a pong
    /// means Jot is the foreground host → record INLINE; silence means Jot is
    /// backgrounded → cold-start via URL bounce. Replaces the stale-flag
    /// `AppGroup.isJotAppForeground()` read with a live request/response.
    private var foregroundPongObserver: CrossProcessNotification.Observer?
    private var pendingForegroundPing: UUID?
    private var foregroundPongReceived = false
    /// 120ms: a foreground app pongs in a few ms; this leaves generous headroom
    /// for Darwin round-trip + MainActor scheduling while staying imperceptible.
    private static let foregroundPongTimeout: TimeInterval = 0.12

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

    /// Whether the post-paste correction quick-review strip should render. Owned
    /// by `KeyboardStreamingHub` — set by `hub.maybeShowCorrectionNudge` (paste-
    /// time) or the `correctionAsksReady` feed; cleared on finish/dismiss.
    private var showCorrectionNudge: Bool { hub.showCorrectionNudge }

    /// The asks published by the app for the just-pasted session. Owned by
    /// `KeyboardStreamingHub`; non-nil whenever `showCorrectionNudge` is true.
    private var correctionAsks: CorrectionBridge.Asks? { hub.correctionAsks }

    // MARK: - Ask-before-paste hold deck (Thread 2)

    /// Sessions whose review deck has already run (resolved or skipped). The flush
    /// gate skips holding for these so the re-entry pastes instead of re-holding.
    private var deckHandledSessions: Set<UUID> = []
    /// Per-session text to paste after the deck resolves (the default spliced with
    /// the owner's verdicts). The flush prefers this over the raw handoff payload.
    private var deckResolvedText: [UUID: String] = [:]
    /// Per-session default (the handoff payload text), captured when the deck is
    /// presented so the splice never depends on a second payload read.
    private var deckDefaultText: [UUID: String] = [:]
    /// Per-session verdicts collected in the deck (recordKey → "term"|"original"),
    /// used to splice the final text on finish.
    private var deckVerdicts: [UUID: [String: String]] = [:]

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
        startObservingForegroundPong()
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
        hub.refreshNow()
        startObservingPipelinePhase()
        startObservingHistoryMirrorUpdated()
        startObservingForegroundPong()
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
        refreshPasteState()
        // History is refreshed via `hub.refreshNow()` above (the hub owns the
        // `historyMirrorUpdated` feed + the `historyEntries` projection).
        refreshStatusBanner()
        renderRootView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        if inFlightPasteSessionID != nil, !inFlightPasteResolved {
            ClipboardHandoff.markConsumed()
            clearPendingPasteSession()
            DiagnosticsLog.record(
                source: "keyboard",
                category: .pasteSuccess,
                message: "Teardown during open paste window — consumed payload to prevent re-present double-paste",
                metadata: ["sessionID": inFlightPasteSessionID?.uuidString ?? "nil"]
            )
        }
        inFlightPasteResolved = true
        isAutoPasteInsertInFlight = false
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
        foregroundPongObserver = nil
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
            onAskDeckVerdict: { [weak self] key, verdict in
                self?.handleAskDeckVerdict(recordKey: key, verdict: verdict)
            },
            onAskDeckStopAsking: { [weak self] key in
                self?.handleAskDeckStopAsking(recordKey: key)
            },
            onAskDeckFinished: { [weak self] in
                self?.handleAskDeckFinished()
            }
        )
    }

    /// Copies the controller's CURRENT state into the `@Observable`
    /// `keyboardInputs` bag. This replaces the old per-render value-reads in
    /// `makeKeyboardView()` — same computations, just written into the observed
    /// object instead of into a freshly-built `KeyboardView`. Called by every
    /// `renderRootView()` call site (37 of them) and once before first install.
    private func syncKeyboardInputs() {
        // Compose the popover's Copy enabled state:
        // Full Access is required for clipboard writes from a custom
        // keyboard, AND there must be a non-empty selection in the host
        // app's focused field. Read `textDocumentProxy.selectedText`
        // directly here (rather than relying on `selectedTextSnapshot`,
        // which fuses before/after context as a fallback) so the row's
        // enabled state matches what `copyHostSelection()` will actually
        // be able to read at tap time.
        let hostHasSelection: Bool = {
            guard let selected = textDocumentProxy.selectedText else { return false }
            return !selected.isEmpty
        }()
        keyboardInputs.hasFullAccess = hasFullAccess
        keyboardInputs.hasPasteboardContent = hasPasteboardContent
        keyboardInputs.needsInputModeSwitchKey = needsInputModeSwitchKey
        keyboardInputs.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        keyboardInputs.historyEntries = historyEntries
        keyboardInputs.canUndoLastInsertion = canUndoLastInsertion
        keyboardInputs.canRedoInsertion = canRedoInsertion
        keyboardInputs.undoDepth = undoLedger.undoStackDepth
        keyboardInputs.redoDepth = undoLedger.redoStackDepth
        keyboardInputs.lastPastedText = lastPastedText
        keyboardInputs.lastPastedAt = lastPastedAt
        keyboardInputs.isStopRequestPending = stopRequestPosted
        keyboardInputs.statusBanner = statusBanner
        keyboardInputs.showWarmHoldNudge = showWarmHoldNudge
        // v2 retheme (2026-05-11): host's `keyboardAppearance` hint.
        // Some hosts (dark Mail, dark Notes, Spotlight) force `.dark`
        // even when the system itself is in light mode. We pass the
        // proxy's signal through; `KeyboardView` resolves it against the
        // SwiftUI `colorScheme` env and the dark path wins if either says dark.
        keyboardInputs.keyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
        keyboardInputs.hasSelection = hasFullAccess && hostHasSelection
        keyboardInputs.showCorrectionNudge = showCorrectionNudge
        keyboardInputs.correctionAsks = correctionAsks
        keyboardInputs.showAskDeck = hub.showAskDeck
        keyboardInputs.askDeckAsks = hub.askDeckAsks
    }

    /// Called when the Actions popover is about to open. Re-reads the
    /// system clipboard so the Paste row reflects current content rather
    /// than whatever was on the clipboard at the most recent
    /// `viewWillAppear`. Reading `UIPasteboard.general.hasStrings` triggers
    /// the iOS paste-privacy toast, which is acceptable on a discrete
    /// user-initiated event (~one toast per Actions open) but would be
    /// hostile on every keystroke — see `refreshPasteState`'s comment.
    private func handleActionsTapped() {
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
        // `hub.clearWarmHoldNudge()` fires the `onShouldRender` hook, which
        // re-renders this controller — no separate `renderRootView()` needed.
        hub.clearWarmHoldNudge()
        CrossProcessNotification.post(name: CrossProcessNotification.warmHoldNudgeChanged)
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

    // MARK: - Ask-before-paste hold deck handlers (Thread 2)

    /// Hold deck: owner picked a word. Record it for the splice AND enqueue the
    /// learning verdict (identical to the post-paste teach path).
    private func handleAskDeckVerdict(recordKey: String, verdict: String) {
        guard let asks = hub.askDeckAsks else { return }
        deckVerdicts[asks.sessionID, default: [:]][recordKey] = verdict
        CorrectionBridge.enqueueVerdict(
            .init(transcriptID: asks.transcriptID, recordKey: recordKey, verdict: verdict))
    }

    /// Hold deck: owner tapped "Stop asking". Keep the original word in the pasted
    /// text and enqueue a "suppress" verdict so the app stops asking this pair on the
    /// keyboard (drained → `CorrectionStore.suppressBlock`). Transcript review is
    /// unaffected.
    private func handleAskDeckStopAsking(recordKey: String) {
        guard let asks = hub.askDeckAsks else { return }
        deckVerdicts[asks.sessionID, default: [:]][recordKey] = "original"
        CorrectionBridge.enqueueVerdict(
            .init(transcriptID: asks.transcriptID, recordKey: recordKey, verdict: "suppress"))
    }

    /// Hold deck resolved (all cards answered/skipped, or first-card skip-all).
    /// Splice the verdicts into the staged text, mark the session handled, tear the
    /// deck down, and RE-ENTER the flush — which now skips the gate and pastes the
    /// resolved text through the one proven insert path.
    private func handleAskDeckFinished() {
        guard let asks = hub.askDeckAsks else {
            hub.dismissAskDeck()
            return
        }
        let session = asks.sessionID
        let verdicts = deckVerdicts[session] ?? [:]
        if let defaultText = deckDefaultText[session], !defaultText.isEmpty {
            deckResolvedText[session] = applyVerdicts(defaultText, verdicts: verdicts, asks: asks.asks)
        }
        // else: no captured default (e.g. torn down mid-deck) — fall through; the
        // re-entered flush pastes the live payload via the normal path.
        deckHandledSessions.insert(session)
        deckDefaultText[session] = nil
        deckVerdicts[session] = nil
        hub.dismissAskDeck()
        flushPendingAutoPasteIfPossible()
    }

    /// Splice the owner's hold-deck verdicts into the staged text. Only edits where
    /// a verdict DISAGREES with what's in the published text. Resolution mirrors the
    /// app's `CorrectionReviewModel.resolveSpan`: the gated word is located by a
    /// WHOLE-WORD, punctuation-trimmed, case-insensitive match anchored at the
    /// reconciled `publishedStart` character offset — `publishedLength` is gate-time
    /// "display/diag only" (`CorrectionProvenance.Record:46`) and must NOT be used to
    /// size the splice (the strict length+equality guard is exactly what dropped a
    /// "Rama"→"Ramaa" replacement when the original carried a trailing "."). If the
    /// anchor doesn't resolve a whole-word match, that edit is skipped (fail-safe —
    /// corrupting the pasted text is worse than leaving the default).
    private func applyVerdicts(_ defaultText: String,
                               verdicts: [String: String],
                               asks: [CorrectionBridge.Ask]) -> String {
        struct Edit { let start: Int; let end: Int; let replacement: String }
        let chars = Array(defaultText)
        var edits: [Edit] = []
        for ask in asks {
            guard let v = verdicts[ask.recordKey], let anchor = ask.publishedStart else { continue }
            let inText = (ask.outcome == "applied") ? ask.term : ask.original   // word now in text
            let want = (v == "term") ? ask.term : ask.original                  // chosen word
            let inCore = Self.trimGatedWord(inText)
            let wantCore = Self.trimGatedWord(want)
            guard !wantCore.isEmpty, wantCore.caseInsensitiveCompare(inCore) != .orderedSame else { continue }
            guard let (s, e) = Self.wholeWordRange(of: inCore, anchoredAtChar: anchor, in: chars) else { continue }
            edits.append(Edit(start: s, end: e, replacement: wantCore))
        }
        DiagnosticsLog.record(
            source: "keyboard", category: .vocabularyGate,
            message: "ask-before-paste: applied verdict splices",
            metadata: ["requested": "\(verdicts.count)", "spliced": "\(edits.count)"])
        guard !edits.isEmpty else { return defaultText }
        var out = chars
        // Apply LAST occurrence first so earlier splices don't shift later offsets.
        for edit in edits.sorted(by: { $0.start > $1.start }) {
            guard edit.start >= 0, edit.end <= out.count, edit.start < edit.end else { continue }
            out.replaceSubrange(edit.start..<edit.end, with: Array(edit.replacement))
        }
        return String(out)
    }

    /// Trim the surrounding punctuation the gate/provenance may carry on a word
    /// (e.g. "Rama." → "Rama") — same set as `CorrectionReviewModel.resolveSpan`.
    private static func trimGatedWord(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
    }

    /// Char range [start,end) of `word` if it sits as a WHOLE word starting exactly
    /// at `anchor` (case-insensitive). Mirrors the app's anchor-exact resolution; nil
    /// if the anchor doesn't land on that word (the body shifted — fail safe).
    private static func wholeWordRange(of word: String, anchoredAtChar anchor: Int,
                                       in chars: [Character]) -> (Int, Int)? {
        let needle = Array(word)
        guard !needle.isEmpty, anchor >= 0 else { return nil }
        let end = anchor + needle.count
        guard end <= chars.count else { return nil }
        guard String(chars[anchor..<end]).caseInsensitiveCompare(word) == .orderedSame else { return nil }
        let beforeOK = anchor == 0 || !chars[anchor - 1].isLetter
        let afterOK = end == chars.count || !chars[end].isLetter
        guard beforeOK, afterOK else { return nil }
        return (anchor, end)
    }

    private var currentActionAvailability: KeyboardActionAvailability {
        KeyboardActionAvailability(
            hasSelection: selectedTextSnapshot != nil,
            canUndoLastInsertion: canUndoLastInsertion,
            canRedoInsertion: canRedoInsertion,
            isMagicFollowUpActive: isMagicFollowUpActive
        )
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

        // Presence check against the live proxy context. iOS windows
        // `documentContextBeforeInput` (~last 300–1024 chars), and the inserted
        // suffix sits at the caret, so `hasSuffix` holds even in a long field.
        // `contains` is a tolerant fallback for a host that appended a trailing
        // space/newline after our text within the same change.
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        guard ctx.hasSuffix(pendingText) || ctx.contains(pendingText) else { return }

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
        guard let selected = textDocumentProxy.selectedText, !selected.isEmpty else { return }
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
    /// app's vocabulary. The keyboard can't run the (CTC-rescore) vocabulary
    /// add itself, so it appends the word to a JSON `[String]` queue in the
    /// App Group and pings the app via a Darwin notification; the app drains
    /// `pendingVocabAdds` on next foreground (`VocabularyAddInbox`). Common
    /// words are filtered here so we never enqueue noise like "the".
    private func handleAddToVocabulary() {
        guard let raw = textDocumentProxy.selectedText else {
            setStatusBanner("Select a word first")
            return
        }
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if CommonWords.isCommon(word.lowercased()) {
            setStatusBanner("‘\(word)’ is a common word — not added")
            return
        }
        // Append to the App-Group queue (JSON [String]) so multiple adds before
        // the app foregrounds all land.
        var pending = AppGroup.defaults.data(forKey: AppGroup.Keys.pendingVocabAdds)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        pending.append(word)
        if let data = try? JSONEncoder().encode(pending) {
            AppGroup.defaults.set(data, forKey: AppGroup.Keys.pendingVocabAdds)
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
        clearPendingPasteSession()
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
        guard let session = readPendingPasteSession() else { return }

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
                renderRootView()
                return
            }
            // ── Ask-before-paste gate (Thread 2) ──
            // If the app staged correction asks for this session and the review deck
            // hasn't run yet, HOLD the paste: present the deck and return WITHOUT
            // inserting or consuming anything (so teardown mid-deck can neither drop
            // nor double the text — pending stays intact + the clipboard floor
            // survives). The deck re-enters this flush on resolution with the chosen
            // text in `deckResolvedText` (and `deckHandledSessions` set so this gate
            // is skipped the second time).
            if !deckHandledSessions.contains(session.id),
               let staged = CorrectionBridge.readAsks(sessionID: session.id),
               !staged.asks.isEmpty {
                // MUST: a re-entrant flush (phase-change / re-present) can land WHILE
                // the deck is open and before the session is "handled" — bail BEFORE
                // touching any state so we never wipe the verdicts the user is mid-way
                // through picking (which would paste the unspliced defaults).
                if hub.showAskDeck { return }
                // One deck at a time — drop any prior session's deck state so these
                // dictionaries can't grow over the keyboard-process lifetime (incl.
                // a session whose re-entry later sad-pathed without cleanup).
                deckResolvedText = deckResolvedText.filter { $0.key == session.id }
                deckDefaultText = deckDefaultText.filter { $0.key == session.id }
                deckVerdicts = deckVerdicts.filter { $0.key == session.id }
                deckHandledSessions = deckHandledSessions.filter { $0 == session.id }
                deckDefaultText[session.id] = payload.text
                deckVerdicts[session.id] = [:]
                DiagnosticsLog.record(
                    source: "keyboard", category: .vocabularyGate,
                    message: "ask-before-paste: holding for review deck",
                    metadata: ["sessionID": session.id.uuidString, "asks": "\(staged.asks.count)"])
                hub.presentAskDeck(staged)
                return
            }

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
            guard !isAutoPasteInsertInFlight else { return }
            isAutoPasteInsertInFlight = true

            textDocumentProxy.adjustTextPosition(byCharacterOffset: 0)

            let pendingSessionID = session.id
            // After the hold deck resolves, paste the spliced text; otherwise the
            // raw handoff payload (the common no-asks case).
            let pasteText = deckResolvedText[session.id] ?? payload.text

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
                let endsWithInserted = (afterCtx ?? "").hasSuffix(pasteText)

                guard landed else {
                    // Still no-op'd even after the re-sync — keep the transcript
                    // pending (don't burn it) so the settled `.idle` flush can
                    // try once more. Single insert per flush = no double-paste.
                    self.isAutoPasteInsertInFlight = false
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
                    // path. If so the work is already done — don't re-consume.
                    guard let pending = self.readPendingPasteSession(),
                          pending.id == pendingSessionID else { return }

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
                    if self.deckHandledSessions.contains(pendingSessionID) {
                        self.deckResolvedText[pendingSessionID] = nil
                        self.deckDefaultText[pendingSessionID] = nil
                        self.deckVerdicts[pendingSessionID] = nil
                        self.deckHandledSessions.remove(pendingSessionID)
                        // Symmetry with the teach path's onCorrectionFinished — clear
                        // the App-Group asks blob now they're resolved pre-paste.
                        CorrectionBridge.clearAsks()
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
                    let stillEndsWith = (settledCtx ?? "").hasSuffix(pasteText)
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
                    let survived = (hasTextNow && (stillEndsWith || settledLen >= immediateAfterLen))
                                || (proxyDisconnected && endsWithInserted)

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
                        ]
                    )

                    // (B) already classified this paste a success — nothing to do.
                    guard !self.inFlightPasteResolved else { return }

                    if survived {
                        finalizeSuccess(false, settledLen)
                        return
                    }

                    // FAILURE floor. Guard so a racing (B) doesn't also fire.
                    guard !self.inFlightPasteResolved else { return }
                    self.inFlightPasteResolved = true
                    self.clearInFlightPasteWindow()
                    self.isAutoPasteInsertInFlight = false

                    // The pending session may have been consumed/cleared by another
                    // path while we waited. If so, the work is already done — bail
                    // without re-consuming or re-pasting.
                    guard let pending = self.readPendingPasteSession(),
                          pending.id == pendingSessionID else { return }

                    // The immediate read lied: the host's live field did not
                    // keep the text. CONSUME the payload + clear pending so NO
                    // later flush (post-publish historyMirrorUpdated, a
                    // keyboard re-presentation, the launch-deadline backstop)
                    // can re-insert it — the 350ms in-flight guard only covers
                    // this window, so keeping it pending would DOUBLE-PASTE on
                    // a host that committed slower than 350ms (the exact
                    // double-paste class that burned builds 103-106). Recovery
                    // is the clipboard banner instead of an in-place retry:
                    // the transcript is already on UIPasteboard.general from
                    // publish (re-stamped with a 1-hour expiration), so the
                    // user taps once to paste. Silent false-success → VISIBLE
                    // one-tap recovery, with no double-paste risk.
                    DiagnosticsLog.record(
                        source: "keyboard",
                        category: .pasteRevertedAfterLanding,
                        message: "Immediate read said landed but settled read disagrees; consumed + clipboard fallback (no retry, no double-paste)",
                        metadata: [
                            "sessionID": pendingSessionID.uuidString,
                            "chars": "\(pasteText.count)",
                            "settledLen": "\(settledLen)",
                            "stillEndsWith": "\(stillEndsWith)",
                            "hasText": "\(hasTextNow)",
                        ]
                    )
                    ClipboardHandoff.markConsumed()
                    self.clearPendingPasteSession()
                    self.fallbackToClipboardWithBanner(text: pasteText)
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
                // teardown mid-poll releases cleanly.
                guard self.isAutoPasteInsertInFlight else { return }
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
            return
        }

        // Diagnostics: classify the non-happy-path branches. These splits
        // mirror the failure modes we want visible in Help → Diagnostics:
        //   - no payload at all (publish hasn't landed yet, or never will)
        //   - payload exists but sessionID doesn't match (cross-session race)
        if payload == nil {
            DiagnosticsLog.record(
                source: "keyboard",
                category: .pasteSkipNoPayload,
                message: "Flush ran with no fresh transcript",
                metadata: ["pendingSessionID": session.id.uuidString]
            )
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
            clearPendingPasteSession()
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
            clearPendingPasteSession()
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
               p.phase == .recording || p.phase == .paused {
                projection = nil
            }
        }
        armOrCancelStaleDeadline(for: projection)
        cancelLaunchDeadlineIfProofOfLife(projection)
        // Clearing `stopRequestPosted` flips the speak button's `.disabled`
        // back off, so we re-render the hosted view to pick up the change.
        // Without the explicit re-render the SwiftUI tree would only refresh
        // on the next state-derived path (next paint, next action), and the
        // user could see a stale "disabled" appearance after the projection
        // already moved off `.recording`.
        if let phase = projection?.phase, phase != .recording, stopRequestPosted {
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
    private func armDeadAppWatchdog(reason: String) {
        deadAppWatchdogTask?.cancel()
        let baseline = PipelinePhaseProjection.read()?.lastUpdatedAt
        deadAppWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.controlTapLivenessCeiling))
            } catch {
                return  // cancelled: keyboard dismissed, superseded, or recovered
            }
            guard let self, !Task.isCancelled else { return }
            let latest = PipelinePhaseProjection.read()
            // Recover ONLY on the unambiguous zombie signal: the projection is
            // STILL an active recording/paused phase AND its timestamp has not
            // advanced past the tap-time baseline. A live writer — even
            // backgrounded — stamps a heartbeat within 3s, so any advance means
            // alive; a terminal (.idle/.failed) / cleared / missing projection
            // means the app (or the normal path) already handled it — stand down
            // and never clear a still-valid pending paste.
            if let baseline, let latest,
               latest.lastUpdatedAt <= baseline,
               latest.phase == .recording || latest.phase == .paused {
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
           frozen.phase == .recording || frozen.phase == .paused,
           let frozenSession = frozen.sessionID {
            hub.recoveredZombieFreeze = (frozenSession, frozen.lastUpdatedAt)
        }
        stopRequestPosted = false
        recordingState.applyPipelineProjection(nil)
        hub.clearStreamingPartialForNewSession()
        recordingState.updateLoadingVariantLabel("")
        clearPendingPasteSession()
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
        if recordingState.isRecording { return .stop }
        return .start
    }

    // MARK: - Live foreground handshake (ping/pong)

    private func startObservingForegroundPong() {
        guard foregroundPongObserver == nil else { return }
        foregroundPongObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.appForegroundPong
        ) { [weak self] in
            self?.foregroundPongReceived = true
        }
    }

    /// Ping the app, then after `foregroundPongTimeout` branch on whether a pong
    /// arrived: pong → Jot is foreground → record INLINE; silence → Jot is
    /// backgrounded → cold-start via the URL bounce. The `pendingForegroundPing`
    /// nonce makes a superseding double-tap cancel the older resolution.
    private func resolveForegroundThenStart() {
        let ping = UUID()
        pendingForegroundPing = ping
        foregroundPongReceived = false
        CrossProcessNotification.post(name: CrossProcessNotification.keyboardForegroundPing)
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.foregroundPongTimeout * 1_000_000_000)
            )
            guard let self, self.pendingForegroundPing == ping else { return }
            self.pendingForegroundPing = nil
            if self.foregroundPongReceived {
                self.startInlineViaDarwin()
            } else {
                self.startColdViaURLBounce()
            }
        }
    }

    /// Jot is foreground → post the Darwin Dictate tap. The app starts a normal
    /// background capture (the same path the keyboard uses in any other app) and
    /// inserts the transcribed result into the focused field on stop. The wizard
    /// (W5) handles this tap with its own observer while it is presented.
    private func startInlineViaDarwin() {
        hub.clearStreamingPartialForNewSession()
        CrossProcessNotification.post(name: CrossProcessNotification.keyboardDictateTapped)
        keyboardLog.info("ping/pong: pong received -> inline tap (host=Jot)")
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
            message: "Pending session written at start (cold start, no pong)",
            metadata: ["sessionID": session.id.uuidString]
        )
        let url = URL(string: "jot://dictate?session=\(session.id.uuidString)")
            ?? Self.containingAppLaunchURL
        openContainingApp(url, onFailure: { [weak self] in
            // The pong window missed but Jot is actually foreground (iOS refuses
            // to URL-open an already-foreground app). Don't strand the tap: drop
            // the now-moot cold paste session and fall back to the inline Darwin
            // path. If a field is focused it records inline; if not, the app's
            // no-target fallback presents the hero. Either way — never dead.
            ClipboardHandoff.clearPendingPasteSession()
            self?.startInlineViaDarwin()
        })
        keyboardLog.info("ping/pong: no pong -> URL bounce (cold start)")
    }

    private func handleMicCTATap() {
        // Warm-resume fast-path. Gated on TWO signals:
        //   1. `warmHoldExpiresAt` still in the future (the 60s window)
        //   2. `warmHoldHeartbeat` is fresh (≤4s old) — proof the main
        //      app process is still alive to receive the Darwin notification
        // Without the heartbeat check, a jetsammed main app leaves a ghost
        // `warmHoldExpiresAt` that traps Dictate taps: the Darwin post
        // lands on no listener, the URL bounce never fires, and the tap
        // appears to do nothing. On stale heartbeat, clear the ghost keys
        // opportunistically and fall through to the cold-launch URL.
        //
        // 4s threshold (vs 2.5s) leaves headroom for MainActor scheduling
        // jitter on a backgrounded warm-held app — audio session restoration
        // and ASR finalize tails can stretch the 1s heartbeat cadence past
        // 2.5s on a healthy process. False-positive jetsam classification is
        // worse than a slightly delayed ghost-cleanup.
        //
        // AppGroup reads are snapshotted into locals so we don't race a
        // mid-cleanup interleave from the main app (`exitWarmHold` clearing
        // both keys non-atomically) — keeps the ghost-cleanup branch from
        // firing on a legitimate exit race.
        let now = Date()
        let expiresAtSnapshot = AppGroup.warmHoldExpiresAt
        let heartbeatSnapshot = AppGroup.warmHoldHeartbeat
        let warmWindowOpen = (expiresAtSnapshot.map { $0 > now } ?? false)
            && (heartbeatSnapshot.map { now.timeIntervalSince($0) < 4.0 } ?? false)

        if warmWindowOpen {
            // Warm-hold is ONLY a "start faster" optimisation — it must not change
            // WHERE a keyboard dictation goes. If Jot is FOREGROUND, the user is
            // dictating inside the app, which must record INLINE (insert at the
            // cursor, save NO transcript) exactly as it does without warm-hold. So
            // do NOT take the warm-RESUME *capture* path here (it saves a transcript
            // and was the cause of in-app dictations being saved); fall through to
            // the normal ping/pong, which routes the tap inline. The warm engine
            // still makes that inline start fast — so warm-hold keeps its speed
            // benefit without changing behaviour. Only when Jot is NOT foreground do
            // we warm-resume in the background (the no-foreground fast path). The
            // warm-hold keys are left intact so leaving the app still resumes warm.
            if !AppGroup.isJotAppForeground() {
                hub.clearStreamingPartialForNewSession()
                CrossProcessNotification.post(name: CrossProcessNotification.warmResumeRequested)
                keyboardLog.info("Posted warm-resume (Jot backgrounded); skipping URL bounce")
                return
            }
            keyboardLog.info("Warm window open but Jot is foreground -> routing inline (no warm capture)")
            // fall through to decideMicTap → inline
        } else if expiresAtSnapshot != nil || heartbeatSnapshot != nil {
            // Ghost cleanup — main app is gone (or just exited warm-hold).
            // Log includes deltas so we can distinguish stale-jetsam from
            // legitimate-exit-race in field reports.
            let expiresAtDelta = expiresAtSnapshot.map { $0.timeIntervalSince(now) } ?? .infinity
            let heartbeatAge = heartbeatSnapshot.map { now.timeIntervalSince($0) } ?? .infinity
            AppGroup.warmHoldExpiresAt = nil
            AppGroup.warmHoldHeartbeat = nil
            keyboardLog.notice("Ghost warm-hold projection cleared; expiresAtDelta=\(expiresAtDelta, privacy: .public)s heartbeatAge=\(heartbeatAge, privacy: .public)s; falling through to URL bounce")
        }

        // Wizard W5 short-circuit: if the host app is Jot itself (detected
        // via the App Group foreground heartbeat written by `JotApp` while
        // `scenePhase == .active`), `extensionContext.open(jot://dictate)`
        // would be silently refused by iOS (iOS will not re-launch the
        // already-foreground app via URL scheme), making the Dictate tap
        // appear to do nothing. Post a Darwin notification instead — the
        // wizard's `SetupWizardView` observes this on W5 (keyboard
        // try-it) and advances to W6 once a fresh dictation arrives.
        //
        // Gated by `hasFullAccess` because App Group reads require it —
        // without Full Access, `isJotAppForeground()` always returns
        // false, and the no-Full-Access branch below falls through to
        // `openHostSettings()` as today.
        //
        // Only short-circuit on the `.start` decision — recording / stop-
        // pending / in-flight-post-recording taps must go through the
        // normal pipeline below so the cross-process state machine stays
        // coherent. Gating on `!isRecording` alone wasn't enough: a tap
        // during the transcription/cleaning tail (`isInflightPostRecording`)
        // or while a stop is already posted (`stopRequestPosted`) would
        // still incorrectly fire `keyboardDictateTapped`. Mirroring
        // `decideMicTap()`'s state machine here keeps the two paths in
        // lock-step — if the decision says "this tap should start a new
        // recording", it's safe to delegate that to the wizard observer.
        switch decideMicTap() {
        case .noop(let reason):
            // The mic CTA is also `.disabled(...)` at the SwiftUI layer for
            // these states — this guard is defense-in-depth against
            // optimistic-UI lag (per design §4.6.D). On `no-full-access` the
            // SwiftUI layer routes the tap to "Unlock", so this branch is
            // expected only for `stop-pending` / `in-flight`.
            if reason == "no-full-access" {
                openHostSettings()
            } else {
                keyboardLog.info("mic tap noop: \(reason, privacy: .public)")
            }
            return

        case .start:
            // Live foreground handshake (ping/pong) replaces the old stale-flag
            // `isJotAppForeground()` read: ping the app, and on a pong within the
            // window record INLINE (Jot is the foreground host); on silence,
            // cold-start via the URL bounce (Jot is backgrounded / another app is
            // foreground). See `resolveForegroundThenStart()`.
            resolveForegroundThenStart()

        case .stop:
            // Arm the App Group pending-paste session BEFORE posting the
            // stop request so the upcoming publish can match on it. The
            // session UUID itself doesn't need to be passed anywhere — the
            // publish path matches on the freshly-written pending session.
            // This restores auto-paste on the normal flow (Speak → dictate
            // → Stop → paste at cursor). The duplicate-rapid-tap race that
            // motivated removing this call is still closed by the
            // `.disabled` modifier on the speak button + `decideMicTap()`
            // returning `.noop` for `stop-pending` / `in-flight` states.
            let stopSession = beginPendingPasteSession()
            DiagnosticsLog.record(
                source: "keyboard",
                category: .sessionStopRequested,
                message: "Pending session written at stop",
                metadata: ["sessionID": stopSession.id.uuidString]
            )
            // Set stopRequestPosted BEFORE the post + before any further
            // processing. Cleared inside refreshPipelinePhase when the
            // projection reflects a non-recording phase.
            stopRequestPosted = true
            renderRootView()
            CrossProcessNotification.post(name: CrossProcessNotification.stopRequested)
            // No optimistic UI flip on `recordingState.phase` per design §4.3
            // — `stopRequestPosted` (just set above) does the visual work via
            // the disabled-CTA path, and the inbound `pipelinePhaseChanged`
            // will replace `.recording` with the in-flight phase shortly.
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

    /// Option-3 safety net (docs/plans/bug-keyboard-paste-fails-claude-code.md §6):
    /// when the settled landed-verify reclassifies an insert as failed, convert the
    /// silent false-success into a VISIBLE failure with a one-tap recovery. The
    /// transcript is already on `UIPasteboard.general` (publish wrote it,
    /// `ClipboardHandoff.swift:53`); re-stamp it with a 1-hour expiration so the
    /// dictation isn't readable by other apps after the user has had a chance to
    /// paste it (leak mitigation per bug-slack-silent-paste.md), then surface the
    /// status banner. The caller CONSUMES the payload + clears the pending session
    /// before calling this (NOT an in-place retry) — keeping it pending would
    /// double-paste on a host that committed slower than the 350ms verify window
    /// (the build-103..106 double-paste class). The clipboard banner IS the
    /// recovery; in-place retry is the held Option 2, gated on the on-device probe.
    private func fallbackToClipboardWithBanner(text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.expirationDate: Date(timeIntervalSinceNow: 3600)]
        )
        self.hasPasteboardContent = UIPasteboard.general.hasStrings
        surfaceDictationStatusBanner("Couldn't paste here — saved to clipboard, tap to paste")
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

    /// Row-trailing "open in app" tap on the recents card. Brings the
    /// main app to the foreground and pushes the transcript detail view
    /// via `jot://transcript?id=<uuid>` (handled by `JotApp.onOpenURL`).
    /// No dictation auto-start — the user wants to read or edit, not
    /// record. Gated on Full Access for the same reasons as
    /// `openHostHome()`: without FA, `extensionContext.open` is refused
    /// and the bounce won't reach the app.
    private func openHistoryEntryInApp(_ entry: TranscriptHistoryMirror.Entry) {
        guard hasFullAccess else {
            openHostSettings()
            return
        }
        guard let url = URL(string: "jot://transcript?id=\(entry.id.uuidString)") else { return }
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
