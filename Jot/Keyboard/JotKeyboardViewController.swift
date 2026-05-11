import AppIntents
import SwiftUI
import UIKit
import OSLog

private let keyboardLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.Keyboard", category: "keyboard")

/// Shared `category=rewrite` log handle so the keyboard's URL-bounce
/// rewrite path emits to the same `subsystem=com.vineetu.jot.mobile
/// category=rewrite` stream the in-app rewrite uses. Single Console.app
/// filter (`subsystem:com.vineetu.jot.mobile category:rewrite`) covers
/// both code paths.
private let keyboardRewriteLog = Logger(
    subsystem: "com.vineetu.jot.mobile",
    category: "rewrite"
)

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

    private var hostingController: UIHostingController<AnyView>?
    private let recordingState = KeyboardRecordingState()
    private var transcriptReadyObserver: CrossProcessNotification.Observer?
    private var pipelinePhaseObserver: CrossProcessNotification.Observer?
    private var streamingPartialObserver: CrossProcessNotification.Observer?

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

    /// Bound on cold-launch / URL-delivery latency. iOS delivers a URL to a
    /// foreground-target target in O(seconds), not O(minutes), so 15s is a
    /// state question ("did the pipeline ever come up?"), not a workload-
    /// latency guess. Per design §4.6.G.
    private static let launchDeadline: TimeInterval = 15

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
    private var magicFollowUpExpiresAt: Date?

    /// Snapshot of recent transcripts loaded from the App Group mirror.
    /// Captured on appearance and whenever the user opens history — the
    /// mirror is cheap to read, but we still avoid re-reading on every
    /// keystroke.
    private var historyEntries: [TranscriptHistoryMirror.Entry] = []

    /// Saved rewrite prompts available to the keyboard's selection rewrite
    /// menu. Empty without Full Access because the App Group store is not
    /// readable.
    private var availableSavedPrompts: [SavedPrompt] = []

    /// True when the AI Rewrite master toggle is OFF in the main app's
    /// settings. Drives the wand button's "AI off" state in the keyboard
    /// accessory bar. Phi-4 readiness (download in progress, download
    /// error, etc.) is communicated to the user in the main app's
    /// settings; the keyboard surfaces only the master-toggle state
    /// because Phi-4 status is opaque to the extension target.
    private var aiUnavailable: Bool = false

    /// Transient banner string read off `AppGroup.lastDictationStatusMessage`.
    /// `nil` when no banner is pending. The keyboard view runs a 2.5s `task`
    /// per banner instance, then calls back into
    /// `clearStatusBannerSlot()` to drop the App Group slot.
    private var statusBanner: String?

    /// Whether the history overlay is currently visible.
    private var showHistory = false

    /// Guards against auto-paste firing twice within a single keyboard
    /// presentation (e.g. orientation change → `viewWillAppear` re-entry).
    private var autoPasteAttempted = false

    /// True while an in-keyboard Apple Intelligence rewrite is running for
    /// the current pending session. Set the moment we claim the payload
    /// (markConsumed + clearPending) and start the rewrite Task; cleared
    /// after the final paste lands. Prevents the `transcriptReady` Darwin
    /// notification observer (or a subsequent `viewWillAppear`-triggered
    /// flush) from re-entering the happy-path branch and double-pasting
    /// while the LLM call is still in flight.
    ///
    /// Note: by the time this is set, `clearPendingPasteSession()` and
    /// `ClipboardHandoff.markConsumed()` have already been called, so any
    /// re-entry would early-return on the `let session = readPendingPasteSession()`
    /// guard — this flag is belt-and-suspenders.
    private var rewriteInFlight: Bool = false

    /// True from the moment the keyboard posts `stopRequested` until the next
    /// `pipelinePhaseChanged` reflecting the app's view of the world. Drives
    /// the speak button's `.disabled` modifier (so iOS suppresses taps while
    /// the stop is in flight) and the controller-level `decideMicTap`
    /// noop branch (defense-in-depth against optimistic-UI lag). Cleared in
    /// `refreshPipelinePhase` once projection moves off `.recording`.
    private var stopRequestPosted = false

    // MARK: - URL-bounce rewrite correlation state (plan §5 Step 4)
    //
    // In-memory mirror of the keyboard's currently-pending rewrite. Used as
    // a fast-path read; on keyboard extension recycle these go to nil and
    // `viewWillAppear` rehydrates from `AppGroup.keyboardPendingRewriteState`.
    //
    // The session UUID stored here is the SAME UUID that's:
    //   - the `?session=<uuid>` query param on `jot://rewrite?...`
    //   - `PendingRewriteRequest.id` in the AppGroup stash
    //   - `KeyboardPendingRewriteState.sessionID` in the AppGroup snapshot
    //   - `AppGroup.rewriteResultSessionID` written by the dispatcher on
    //     terminal completion
    // — so a single UUID equality check correlates the result back to the
    // captured selection.
    private var pendingRewriteSessionID: UUID?
    private var pendingRewriteSelectionText: String?
    private var pendingRewriteSelectionLength: Int?
    private var pendingRewriteStartedAt: Date?

    /// Observer for `RewriteNotifications.rewriteCompleted`. Installed on
    /// `viewWillAppear` AFTER the drain step (so a result that landed
    /// before the keyboard reappeared isn't missed by the observer-only
    /// path). Torn down on `viewWillDisappear` along with the other
    /// cross-process observers.
    private var rewriteCompletedObserver: RewriteNotifications.Observer?

    /// Tracks whether the live timeout banner has already fired for the
    /// current pending rewrite. The 60s timeout task arms inside
    /// `viewWillAppear` and is cancelled on drain or `viewWillDisappear`.
    private var rewriteLiveTimeoutTask: Task<Void, Never>?

    /// Wall-clock ceiling for the URL-bounce rewrite round trip — keyboard
    /// captures selection → URL launches main app → main app dispatches
    /// rewrite → AppGroup result lands → keyboard drains. Mirrors the
    /// previous in-keyboard `keyboardRewriteTimeoutSeconds` (45s) plus a
    /// 15s slack for the launch + dispatcher overhead. Per plan §5 Step 4d.
    private static let rewriteRoundTripTimeoutSeconds: TimeInterval = 60

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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Jot mic CTA is its own affordance; we do not provide a system dictation key.
        hasDictationKey = false
        // Seed the bundled default rewrite prompt so the in-app transcript
        // view's AI rewrite menu never starts empty. Idempotent — no-op when
        // the user already has at least one row. Settings UI runs the same
        // call; keeping it here ensures the prompts list is populated even
        // before the user opens Settings.
        SavedPromptStore.seedIfNeeded()
        installKeyboardView()
        startObservingTranscriptReady()
        startObservingPipelinePhase()
        startObservingStreamingPartial()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        showHistory = false
        // Refresh the Full Access grant — the user can flip "Allow Full
        // Access" in Settings between keyboard presentations, and haptic +
        // audio both require it. Then warm the Taptic Engine so the first
        // keypress feels as crisp as the hundredth (HIG → Playing Haptics).
        feedback.fullAccess = hasFullAccess
        feedback.prepare()
        startObservingTranscriptReady()
        startObservingPipelinePhase()
        startObservingStreamingPartial()
        // Rewrite drain MUST run BEFORE installing the live observer so a
        // result that landed while the keyboard was detached (the common
        // URL-bounce case — Jot foregrounded, keyboard torn down) is not
        // missed by the observer-only path. Drain reads correlation state
        // from AppGroup if the in-memory mirror went away during extension
        // recycle. Per plan §5 Step 4d.
        drainPendingRewriteResultOnAppear()
        startObservingRewriteCompleted()
        rearmRewriteLiveTimeoutIfPending()
        refreshPipelinePhase()
        refreshStreamingPartialFromProjection()
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
        refreshHistory()
        refreshAIAvailability()
        refreshAvailableSavedPrompts()
        refreshStatusBanner()
        renderRootView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        transcriptReadyObserver = nil
        pipelinePhaseObserver = nil
        streamingPartialObserver = nil
        // Tear the rewrite observer down so a result delivered while the
        // keyboard is detached doesn't hop onto a stale @MainActor handler.
        // The next `viewWillAppear` re-installs after draining whatever
        // landed in the meantime — durable delivery via AppGroup, not via
        // a long-lived observer.
        rewriteCompletedObserver = nil
        rewriteLiveTimeoutTask?.cancel()
        rewriteLiveTimeoutTask = nil
        pipelineStaleDeadlineTask?.cancel()
        pipelineStaleDeadlineTask = nil
        pendingLaunchDeadlineTask?.cancel()
        pendingLaunchDeadlineTask = nil
        cancelBackspaceRepeat()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // Keep selection and undo-menu enablement fresh without reading
        // UIPasteboard here, which would fire iOS's paste-privacy toast on
        // every keystroke. The pasteboard is only queried on appearance via
        // refreshPasteState().
        refreshSelectionState()
        renderRootViewIfActionAvailabilityChanged()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshSelectionState()
        renderRootViewIfActionAvailabilityChanged()
    }

    // MARK: - Hosting

    private func installKeyboardView() {
        let host = UIHostingController(rootView: makeRootView())
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
    }

    private func renderRootView() {
        hostingController?.rootView = makeRootView()
        renderedActionAvailability = currentActionAvailability
    }

    private func renderRootViewIfActionAvailabilityChanged() {
        guard currentActionAvailability != renderedActionAvailability else { return }
        renderRootView()
    }

    private func makeRootView() -> AnyView {
        // Builds the hosted SwiftUI keyboard surface.
        AnyView(makeKeyboardView())
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            hasFullAccess: hasFullAccess,
            hasPasteboardContent: hasPasteboardContent,
            hasSelection: selectedTextSnapshot != nil,
            availableSavedPrompts: availableSavedPrompts,
            isRewritingSelection: rewriteInFlight,
            recordingState: recordingState,
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            returnKeyType: textDocumentProxy.returnKeyType ?? .default,
            historyEntries: historyEntries,
            showHistory: showHistory,
            canUndoLastInsertion: canUndoLastInsertion,
            canRedoInsertion: canRedoInsertion,
            isStopRequestPending: stopRequestPosted,
            aiUnavailable: aiUnavailable,
            statusBanner: statusBanner,
            onCopy: { [weak self] in self?.handleCopyMenuSelection() },
            onPaste: { [weak self] in self?.handlePasteMenuSelection() },
            onUndoLastInsertion: { [weak self] in self?.handleUndoMenuSelection() },
            onRedoInsertion: { [weak self] in self?.handleRedoMenuSelection() },
            onSelectPromptForSelection: { [weak self] prompt in
                self?.handleSelectPromptForSelection(prompt)
            },
            onTapToSpeak: { [weak self] in self?.handleMicCTATap() },
            onShowHistory: { [weak self] in self?.showHistoryOverlay() },
            onInsertHistoryEntry: { [weak self] entry in self?.insertHistoryEntry(entry) },
            onDismissHistory: { [weak self] in self?.dismissHistoryOverlay() },
            onKey: { [weak self] key in self?.handleKeyTap(key) },
            onKeyPressChange: { [weak self] key, pressed in self?.handleKeyPressChange(key, pressed: pressed) },
            onAdvanceToNextInputMode: { [weak self] in self?.advanceToNextInputMode() },
            onOpenFullAccess: { [weak self] in self?.openHostSettings() },
            onStatusBannerRendered: { [weak self] in self?.clearStatusBannerSlot() },
            feedback: feedback
        )
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

    private func startObservingTranscriptReady() {
        guard transcriptReadyObserver == nil else { return }
        transcriptReadyObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.transcriptReady
        ) { [weak self] in
            guard let self else { return }
            self.flushPendingAutoPasteIfPossible()
            // Banner state may have changed (timeout / error fallback wrote
            // a new message before publishing the raw transcript). Refresh
            // and re-render so the banner overlay starts its 2.5s task.
            let priorBanner = self.statusBanner
            let priorPrompts = self.availableSavedPrompts
            self.refreshAvailableSavedPrompts()
            self.refreshStatusBanner()
            if priorBanner != self.statusBanner
                || priorPrompts != self.availableSavedPrompts {
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
        guard hasFullAccess,
              let session = readPendingPasteSession()
        else { return }

        let payload = ClipboardHandoff.readFresh()
        let projection = PipelinePhaseProjection.read()

        // Happy path: payload session ID matches our pending session.
        if let payload, payload.sessionID == session.id {
            // Best-effort same-input-context guard. The actual API on
            // UITextDocumentProxy is `documentIdentifier` (UUID-typed);
            // `textInputContextIdentifier` is on UIResponder and isn't
            // accessible via the proxy abstraction. Fall back to
            // `keyboardType` rawValue when documentIdentifier is nil.
            if let claimedDoc = session.hostDocumentIdentifier {
                let nowDoc = textDocumentProxy.documentIdentifier
                if nowDoc != claimedDoc {
                    keyboardLog.info("Skipped auto-paste because document identifier changed since tap")
                    clearPendingPasteSession()
                    renderRootView()
                    return
                }
            } else if let claimedKbRaw = session.hostKeyboardTypeRaw,
                      let nowKb = textDocumentProxy.keyboardType?.rawValue,
                      nowKb != claimedKbRaw {
                keyboardLog.info("Skipped auto-paste because keyboard type changed since tap")
                clearPendingPasteSession()
                renderRootView()
                return
            }
            magicFollowUpExpiresAt = Date().addingTimeInterval(ClipboardHandoff.freshnessWindow)
            insertTrackedText(payload.text)
            ClipboardHandoff.markConsumed()
            clearPendingPasteSession()
            freshPreview = nil
            hasPasteboardContent = UIPasteboard.general.hasStrings
            renderRootView()
            return
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

    // MARK: - Streaming partial mirror

    private func startObservingStreamingPartial() {
        guard streamingPartialObserver == nil else { return }
        streamingPartialObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.streamingPartialChanged
        ) { [weak self] in
            self?.refreshStreamingPartialFromProjection()
        }
    }

    private func refreshStreamingPartialFromProjection() {
        guard hasFullAccess else {
            recordingState.updateStreamingPartial("")
            return
        }
        let text = AppGroup.defaults.string(forKey: AppGroup.Keys.streamingPartialText) ?? ""
        recordingState.updateStreamingPartial(text)
    }

    // MARK: - Pipeline phase observer (v7 auto-paste design)

    private func startObservingPipelinePhase() {
        guard pipelinePhaseObserver == nil else { return }
        pipelinePhaseObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.pipelinePhaseChanged
        ) { [weak self] in
            self?.refreshPipelinePhase()
        }
    }

    /// Single source of truth for pipeline phase reads. Reads the projection,
    /// applies it to the keyboard's `KeyboardRecordingState`, arms or cancels
    /// the stale-deadline task, cancels the launch deadline if proof of life,
    /// clears `stopRequestPosted` if projection moved off `.recording`, and
    /// runs the flush. Per design §4.6 + §4.6.G.
    private func refreshPipelinePhase() {
        guard hasFullAccess else { return }
        let projection = PipelinePhaseProjection.read()
        recordingState.applyPipelineProjection(projection)
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
            self?.refreshPipelinePhase()
        }
    }

    // MARK: - Selection state

    private func refreshSelectionState() {
        guard let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty else {
            selectedTextSnapshot = nil
            return
        }
        selectedTextSnapshot = selectedText
    }

    // MARK: - History

    /// Reloads the App Group mirror. Called on appearance and when the user
    /// opens the history overlay — the extra read when opening catches new
    /// dictations recorded while the keyboard is still presented.
    private func refreshHistory() {
        guard hasFullAccess else {
            historyEntries = []
            return
        }
        historyEntries = TranscriptHistoryMirror.load()
    }

    private func refreshAvailableSavedPrompts() {
        guard hasFullAccess else {
            availableSavedPrompts = []
            return
        }
        availableSavedPrompts = SavedPromptStore.all()
    }

    private func toggleHistory() {
        if !showHistory {
            refreshHistory()
        }
        showHistory.toggle()
        renderRootView()
    }

    private func showHistoryOverlay() {
        refreshHistory()
        showHistory = true
        renderRootView()
    }

    private func dismissHistoryOverlay() {
        showHistory = false
        renderRootView()
    }

    private func insertHistoryEntry(_ entry: TranscriptHistoryMirror.Entry) {
        insertTrackedText(entry.text)
        showHistory = false
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

    private func handleMicCTATap() {
        let decision = decideMicTap()
        switch decision {
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
            // Write the App Group pending-paste session ONLY in the start
            // branch. Moving the write inside the decision switch (vs.
            // calling it before the branch as the prior shape did) closes
            // the rapid-double-tap race where a tap arriving while a stop
            // was in flight would silently overwrite the pending session
            // the app is about to capture.
            //
            // Stamp the session ID into the URL so the app's `onOpenURL`
            // can `adoptSession(_:)` before recording-start.
            let session = beginPendingPasteSession()
            let url = URL(string: "jot://dictate?session=\(session.id.uuidString)")
                ?? Self.containingAppLaunchURL
            openContainingApp(url)

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
            let _ = beginPendingPasteSession()
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

            // Single 750ms post-tap resync sweep: Darwin coalesces, so cover
            // the case where the immediate `pipelinePhaseChanged` is dropped
            // or arrives before our observer is wired.
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
                self?.refreshPipelinePhase()
            }
        }
    }

    // MARK: - AI availability

    /// Refreshes the AI-rewrite availability gate for keyboard rewrite
    /// affordances. No Full Access means the keyboard cannot read the
    /// App Group, so we leave the gate open (treat the wand as
    /// available); the rewrite path itself will fail later if the user
    /// has truly disabled AI rewrite.
    ///
    /// The keyboard no longer probes `SystemLanguageModel.default.availability`
    /// — Apple Intelligence is no longer a rewrite provider. The only
    /// signal the keyboard can read cheaply is `AppGroup.aiRewriteEnabled`
    /// (the master toggle in the main app's settings). Phi-4's actual
    /// readiness (download in progress, weights missing, load failure) is
    /// opaque to the extension target — those failures surface through
    /// the URL-bounce dispatcher round-trip and the keyboard's inline
    /// error banner.
    private func refreshAIAvailability() {
        guard hasFullAccess else {
            aiUnavailable = false
            return
        }
        aiUnavailable = !AppGroup.aiRewriteEnabled
    }

    /// Fires the selection-rewrite handoff: captures the live host
    /// selection, stashes a `PendingRewriteRequest` and a
    /// `KeyboardPendingRewriteState` snapshot in the App Group, then
    /// URL-bounces into the main app via `jot://rewrite?session=<uuid>`.
    /// The main app's `RewriteRequestDispatcher` runs the LLM call and
    /// writes the terminal result to AppGroup; the keyboard drains it on
    /// the next `viewWillAppear` (the URL bounce foregrounds Jot, which
    /// detaches the keyboard) and re-applies it via the safe-replacement
    /// gate.
    ///
    /// Why URL bounce instead of in-process inference: the keyboard
    /// extension is bounded by iOS to a 60 MB memory ceiling. The
    /// Phi-4 mini weights are ~2.4 GB on disk and the MLX runtime
    /// itself doesn't fit either. The main app already runs the
    /// rewrite stack for the in-app transcript pane; we route the
    /// keyboard's request to the same dispatcher rather than maintain
    /// a second inference path.
    private func handleSelectPromptForSelection(_ prompt: SavedPrompt) {
        guard hasFullAccess else { return }
        guard !rewriteInFlight else { return }
        guard let selection = textDocumentProxy.selectedText, !selection.isEmpty else { return }
        // SavedPrompt.id is `UUID`; the App Group `PendingRewriteRequest`
        // carries it as a `String` (forward-compat with non-UUID prompt
        // IDs the dispatcher already tolerates). The dispatcher parses
        // the string back to a UUID and falls through to "Prompt not
        // found" on bad input.
        let promptIDString = prompt.id.uuidString

        keyboardRewriteLog.notice(
            "KB.rewrite (selection): ENTRY chars=\(selection.count, privacy: .public) promptID=\(promptIDString, privacy: .public)"
        )

        let sessionID = UUID()
        let selectionLength = selection.utf16.count
        let startedAt = Date()

        // Stash the dispatcher's input — the URL handler in `JotApp` reads
        // and deletes `pendingRewriteRequest` on receipt. Both struct
        // identifiers carry the same `sessionID` so the keyboard's drain
        // can correlate the dispatcher's `rewriteResultSessionID` back
        // to its captured selection. Order: write the AppGroup state
        // FIRST, open the URL SECOND. iOS may suspend the extension as
        // soon as the URL hands off; if the URL went first the dispatcher
        // could find an empty stash and discard the request.
        AppGroup.pendingRewriteRequest = PendingRewriteRequest(
            id: sessionID,
            promptID: promptIDString,
            selection: selection,
            selectionLength: selectionLength,
            createdAt: startedAt
        )
        AppGroup.keyboardPendingRewriteState = KeyboardPendingRewriteState(
            sessionID: sessionID,
            selectionText: selection,
            selectionLength: selectionLength,
            startedAt: startedAt
        )
        // Belt-and-suspenders: the dispatcher already echoes
        // `selectionLength` into this slot from the request, but pre-
        // writing it here guarantees the keyboard's drain has a usable
        // length even if the dispatcher hasn't started yet (for
        // diagnostic logging only — the safe-replacement gate uses
        // strict text equality, never length).
        AppGroup.rewriteSelectionLength = selectionLength

        // Mirror to in-memory state for the fast-path (no extension
        // recycle case). On recycle these are nil and `viewWillAppear`
        // hydrates from `keyboardPendingRewriteState`.
        pendingRewriteSessionID = sessionID
        pendingRewriteSelectionText = selection
        pendingRewriteSelectionLength = selectionLength
        pendingRewriteStartedAt = startedAt

        rewriteInFlight = true
        // In-flight state is surfaced in the streaming display panel via
        // `isRewritingSelection`. The 60s round-trip timeout banner is
        // handled by the live-timeout task armed below.
        renderRootView()

        // Open `jot://rewrite?session=<uuid>` via the responder-chain
        // workaround. Apple does NOT guarantee `extensionContext.open`
        // for keyboards — see the doc on `openContainingApp`. The
        // open-failure completion clears the pending state slots so a
        // failed launch doesn't strand a pending rewrite that will
        // never receive a result.
        guard let url = URL(string: "jot://rewrite?session=\(sessionID.uuidString)") else {
            keyboardRewriteLog.error("KB.rewrite (selection): URL construction failed for sessionID=\(sessionID, privacy: .public)")
            clearPendingRewriteState()
            rewriteInFlight = false
            AppGroup.lastDictationStatusMessage = "Couldn't open Jot — please open the app and try again."
            statusBanner = AppGroup.lastDictationStatusMessage
            renderRootView()
            return
        }
        openContainingAppForRewrite(url)

        // Arm the 60s wall-clock round-trip timeout. Cancelled on drain
        // (success path) or on the next `viewWillDisappear`. If the task
        // fires, it surfaces a banner and clears pending state.
        rearmRewriteLiveTimeoutIfPending()
    }

    // MARK: - Rewrite handoff plumbing (URL bounce + AppGroup drain)

    /// Wraps `openContainingApp` for the rewrite path with a tighter
    /// failure path: when responder-chain `open(_:)` returns `false`,
    /// clear the pending rewrite state so the next `viewWillAppear`
    /// drain doesn't sit there waiting for a result that will never
    /// arrive. We can't return failure synchronously — `open(_:)` is
    /// async by Apple's contract — so we route through a callback that
    /// inspects `AppGroup.rewriteResultSessionID` to disambiguate "open
    /// failed" from "open succeeded but result hasn't landed yet."
    ///
    /// `openContainingApp` already calls `ClipboardHandoff.clearPendingPasteSession()`
    /// on failure; we additionally clear the rewrite-specific slots
    /// here. The two clear paths are independent — pending paste and
    /// pending rewrite are different App Group keys.
    private func openContainingAppForRewrite(_ url: URL) {
        // Reuse the existing responder-chain workaround. It handles its
        // own logging and one inline cleanup (paste session). The
        // rewrite-specific cleanup is handled here on the failure-poll
        // path below.
        openContainingApp(url)

        // Best-effort post-launch sanity check: 1.5s after the URL post,
        // if the dispatcher hasn't even claimed the stash (the dispatcher
        // clears `pendingRewriteRequest` synchronously on receipt — see
        // `RewriteRequestDispatcher.swift:67`), assume open failed and
        // clear pending state. This is heuristic, not authoritative —
        // a slow launch can race with the 1.5s window — so we guard with
        // an extra "still pending and stash not consumed" check.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            // Already drained or already cleared — nothing to do.
            guard let sessionID = self.pendingRewriteSessionID else { return }
            // Dispatcher took the stash (good) — the round-trip timeout
            // still applies, but the open succeeded.
            if AppGroup.pendingRewriteRequest == nil { return }
            // Stash still present → dispatcher never received the URL.
            // This is the "RequestsOpenAccess denied" / private-URL-blocked
            // case. Clear pending state and show the open-failure banner.
            keyboardRewriteLog.error("KB.rewrite (selection): open(_:) appears to have failed — sessionID=\(sessionID, privacy: .public)")
            self.clearPendingRewriteState()
            self.rewriteInFlight = false
            AppGroup.lastDictationStatusMessage = "Couldn't open Jot — please open the app and try again."
            self.statusBanner = AppGroup.lastDictationStatusMessage
            self.renderRootView()
        }
    }

    /// Installs the rewrite-completion Darwin observer. Called from
    /// `viewWillAppear` AFTER `drainPendingRewriteResultOnAppear` so the
    /// drain consumes any result that landed while the keyboard was
    /// detached. The observer covers the rare case where the keyboard
    /// stays foregrounded across the full round trip — host == Jot
    /// itself (e.g. rewriting in the in-app transcript editor while the
    /// keyboard is still the active input view).
    private func startObservingRewriteCompleted() {
        guard rewriteCompletedObserver == nil else { return }
        rewriteCompletedObserver = RewriteNotifications.addCompletedObserver { [weak self] in
            guard let self else { return }
            self.drainPendingRewriteResultOnAppear()
        }
    }

    /// Drains the dispatcher's terminal result from AppGroup if it
    /// matches the keyboard's pending session. Recovers correlation
    /// state from `keyboardPendingRewriteState` first if the in-memory
    /// mirror is nil (extension-recycle case). Idempotent — running it
    /// twice with no result waiting is a no-op.
    ///
    /// Reads in the order the dispatcher writes (reverse of write
    /// order):
    ///   - `rewriteResultSessionID` first (correlation key)
    ///   - then `rewriteResult` / `rewriteError` (payload)
    /// — so a partial write where the dispatcher set the payload but
    /// not yet the session ID surfaces as "no result yet" rather than
    /// as a mis-correlated drain. The dispatcher writes both
    /// synchronously on `@MainActor`, so a torn write is unlikely; this
    /// ordering is belt-and-suspenders.
    private func drainPendingRewriteResultOnAppear() {
        // Hydrate from AppGroup snapshot if in-memory mirror was lost
        // (extension recycled between URL post and result delivery).
        if pendingRewriteSessionID == nil, let snapshot = AppGroup.keyboardPendingRewriteState {
            pendingRewriteSessionID = snapshot.sessionID
            pendingRewriteSelectionText = snapshot.selectionText
            pendingRewriteSelectionLength = snapshot.selectionLength
            pendingRewriteStartedAt = snapshot.startedAt
            // Restore the in-flight flag so the UI guard
            // (`isRewritingSelection`) and the new-rewrite gate in
            // `handleSelectPromptForSelection` correctly recognize that a
            // rewrite is still pending after an extension recycle. Without
            // this, the user could trigger a duplicate rewrite while the
            // hydrated one is still in flight.
            rewriteInFlight = true
            keyboardRewriteLog.info(
                "KB.rewrite drain: hydrated from AppGroup snapshot sessionID=\(snapshot.sessionID, privacy: .public)"
            )
        }
        guard let pendingSessionID = pendingRewriteSessionID else { return }

        // Read the correlation slot. If it's nil or mismatches, the
        // dispatcher hasn't written a terminal value yet (or it wrote
        // one for a different rewrite that completed and was already
        // drained). Either way, leave the result slots alone and wait
        // for either the live observer or the next viewWillAppear.
        guard let resultSessionID = AppGroup.rewriteResultSessionID,
              resultSessionID == pendingSessionID
        else {
            return
        }

        // We own this terminal write — drain payload.
        let result = AppGroup.rewriteResult
        let errorMsg = AppGroup.rewriteError
        let pendingText = pendingRewriteSelectionText ?? ""

        // Clear AppGroup terminal state BEFORE applying the result so
        // re-entry (e.g. the live observer firing during a slow
        // applyDrainedRewriteResult) doesn't double-consume.
        AppGroup.rewriteResult = nil
        AppGroup.rewriteError = nil
        AppGroup.rewriteResultSessionID = nil
        AppGroup.rewriteSelectionLength = nil
        AppGroup.keyboardPendingRewriteState = nil
        // pendingRewriteRequest was already consumed by the dispatcher
        // (it deletes the key synchronously on dispatch). Belt-and-
        // suspenders: clear it here too in case a malformed dispatch
        // left it stranded.
        AppGroup.pendingRewriteRequest = nil

        // Cancel the round-trip timeout — we got a terminal value.
        rewriteLiveTimeoutTask?.cancel()
        rewriteLiveTimeoutTask = nil

        // Clear in-memory pending state and the in-flight flag.
        clearInMemoryPendingRewriteState()
        rewriteInFlight = false

        if let errorMsg, !errorMsg.isEmpty {
            // Cancellation is user-driven — silent fallback, no banner.
            // Anything else surfaces to the user.
            if errorMsg == RewriteNotifications.cancelledSentinel {
                keyboardRewriteLog.notice(
                    "KB.rewrite drain: CANCELLED sessionID=\(pendingSessionID, privacy: .public)"
                )
                statusBanner = nil
            } else {
                keyboardRewriteLog.error(
                    "KB.rewrite drain: ERROR sessionID=\(pendingSessionID, privacy: .public) error=\(errorMsg, privacy: .public)"
                )
                AppGroup.lastDictationStatusMessage = "Rewrite failed: \(errorMsg)"
                statusBanner = AppGroup.lastDictationStatusMessage
            }
            renderRootView()
            return
        }

        guard let result, !result.isEmpty else {
            // Empty result from a successful path — surface as error so
            // the user isn't left wondering why nothing changed.
            keyboardRewriteLog.error("KB.rewrite drain: empty result sessionID=\(pendingSessionID, privacy: .public)")
            AppGroup.lastDictationStatusMessage = "Rewrite returned empty text"
            statusBanner = AppGroup.lastDictationStatusMessage
            renderRootView()
            return
        }

        keyboardRewriteLog.notice(
            "KB.rewrite drain: SUCCESS sessionID=\(pendingSessionID, privacy: .public) outputChars=\(result.count, privacy: .public)"
        )
        applyDrainedRewriteResult(result, capturedSelection: pendingText)
    }

    /// Strict-text-equality safe-replacement gate (plan §5 Step 4e —
    /// pass-4 P3-1). Only auto-replaces when the live host selection
    /// EXACTLY equals the captured selection text. Any divergence —
    /// nil/empty selection, different text, or even same-length-but-
    /// different-text — falls to pasteboard + banner. Length-based
    /// gates are unsafe because the user may have collapsed the
    /// selection and re-selected something else of the same length;
    /// we deliberately do NOT attempt a length-only fallback.
    ///
    /// Length is logged for diagnostics but does not authorize
    /// replacement.
    private func applyDrainedRewriteResult(_ rewritten: String, capturedSelection: String) {
        let live = textDocumentProxy.selectedText ?? ""
        let liveLen = live.utf16.count
        let capLen = capturedSelection.utf16.count

        if !live.isEmpty, live == capturedSelection {
            // Strict-equality match — selection is still the captured
            // text. Single `deleteBackward()` clears the entire active
            // selection on a host that reports a non-empty selection
            // range; we deliberately do NOT loop deleteBackward over
            // selection.count because once the first call collapses
            // the selection, further deletes would chew unselected
            // document text.
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(rewritten)
            undoLedger.recordReplacement(deleted: capturedSelection, inserted: rewritten)
            statusBanner = nil
            keyboardRewriteLog.notice(
                "KB.rewrite apply: AUTO-REPLACE liveLen=\(liveLen, privacy: .public) capLen=\(capLen, privacy: .public) outputChars=\(rewritten.count, privacy: .public)"
            )
            renderRootView()
            return
        }

        // Pasteboard + banner fallback. Replacing the wrong text
        // silently is a worse failure mode than asking the user to
        // paste — so we err on the safe side whenever we cannot prove
        // the live selection still contains the exact captured text.
        UIPasteboard.general.string = rewritten
        AppGroup.lastDictationStatusMessage = "Tap to paste rewritten text"
        statusBanner = AppGroup.lastDictationStatusMessage
        keyboardRewriteLog.notice(
            "KB.rewrite apply: PASTEBOARD-FALLBACK liveLen=\(liveLen, privacy: .public) capLen=\(capLen, privacy: .public) outputChars=\(rewritten.count, privacy: .public)"
        )
        renderRootView()
    }

    /// Arms the 60s wall-clock round-trip timeout if a rewrite is
    /// pending and not already armed. Cancelled on drain (success path)
    /// or on the next `viewWillDisappear`. Also re-armed by
    /// `viewWillAppear` so a long round-trip across an extension
    /// recycle still surfaces a "took too long" banner instead of
    /// hanging indefinitely.
    ///
    /// Computes the remaining timeout from `pendingRewriteStartedAt`
    /// (or the AppGroup-hydrated value), so re-arming after a recycle
    /// fires near the original 60s mark, not 60s from re-arm.
    private func rearmRewriteLiveTimeoutIfPending() {
        guard pendingRewriteSessionID != nil else { return }
        guard rewriteLiveTimeoutTask == nil else { return }
        let startedAt = pendingRewriteStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = Self.rewriteRoundTripTimeoutSeconds - elapsed
        guard remaining > 0 else {
            // Already past the deadline — fire immediately.
            handleRewriteRoundTripTimeout()
            return
        }
        rewriteLiveTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            self.handleRewriteRoundTripTimeout()
        }
    }

    /// Fires when the 60s round-trip timeout elapses without a result.
    /// Clears pending state (both in-memory and AppGroup) and surfaces
    /// the timeout banner. Result slots are NOT cleared — the
    /// dispatcher may still complete and overwrite them; on the next
    /// `viewWillAppear` they'll be ignored because the
    /// `keyboardPendingRewriteState` slot is gone (no correlation key
    /// to match against).
    private func handleRewriteRoundTripTimeout() {
        guard let pendingSessionID = pendingRewriteSessionID else { return }
        keyboardRewriteLog.error(
            "KB.rewrite TIMEOUT sessionID=\(pendingSessionID, privacy: .public) — clearing pending state"
        )
        rewriteLiveTimeoutTask = nil
        clearPendingRewriteState()
        rewriteInFlight = false
        AppGroup.lastDictationStatusMessage = "Rewrite timed out"
        statusBanner = AppGroup.lastDictationStatusMessage
        renderRootView()
    }

    /// Clears both the AppGroup and in-memory keyboard-pending state.
    /// Called on open-failure, on round-trip timeout, and on terminal
    /// drain. Does NOT touch the dispatcher's result slots — those are
    /// independently cleared on drain (where they were just consumed)
    /// and left alone on timeout (where the dispatcher may still write
    /// them).
    private func clearPendingRewriteState() {
        AppGroup.keyboardPendingRewriteState = nil
        AppGroup.pendingRewriteRequest = nil
        AppGroup.rewriteSelectionLength = nil
        clearInMemoryPendingRewriteState()
    }

    private func clearInMemoryPendingRewriteState() {
        pendingRewriteSessionID = nil
        pendingRewriteSelectionText = nil
        pendingRewriteSelectionLength = nil
        pendingRewriteStartedAt = nil
    }

    // MARK: - Status banner (v0.4)

    private func refreshStatusBanner() {
        guard hasFullAccess else {
            statusBanner = nil
            return
        }
        statusBanner = AppGroup.lastDictationStatusMessage
    }

    /// Called by the SwiftUI banner overlay's `task` after ~2.5s on-screen
    /// so the next presentation doesn't re-render the same banner. Kept
    /// idempotent — clearing an already-empty slot is a no-op.
    private func clearStatusBannerSlot() {
        guard statusBanner != nil else { return }
        AppGroup.lastDictationStatusMessage = nil
        statusBanner = nil
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
    private func openContainingApp(_ url: URL) {
        let selector = sel_registerName("openURL:options:completionHandler:")

        let completion: @MainActor @Sendable (Bool) -> Void = { [url] success in
            if success {
                keyboardLog.info("Opened containing app for url=\(url.absoluteString, privacy: .public)")
            } else {
                keyboardLog.error("openURL completion=false for url=\(url.absoluteString, privacy: .public)")
                ClipboardHandoff.clearPendingPasteSession()
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
        ClipboardHandoff.clearPendingPasteSession()
    }

    private func openHostSettings() {
        // Always use `UIApplication.openSettingsURLString` (a.k.a. "app-settings:").
        // This is the documented public URL extensions are guaranteed to be
        // able to open via `extensionContext.open`, and Apple documents it as
        // a deep link to the app's custom settings page.
        //
        // We previously tried private URLs (`App-prefs:General&path=Keyboard/
        // KEYBOARDS`) to land closer to the toggle. On iOS 26 those are
        // silently blocked — `extensionContext.open` still returns
        // `success: true` (the URL was accepted by the context) but iOS does
        // nothing. That made the fallback path unreachable and the tap
        // appear to do nothing. User confirmed broken 2026-04-21.
        //
        // Whether the app settings page still exposes a path to "Allow Full
        // Access" on iOS 26.3.1 needs device verification; see
        // `tmp/reviews/keyboard-polish.md`.
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
        guard let entry = undoStack.last else { return nil }
        let trailing = entry.trailingTextForUndo
        guard !trailing.isEmpty else { return nil }
        guard contextBeforeInput?.hasSuffix(trailing) == true else { return nil }
        return entry
    }
}

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
    var isInflightPostRecording: Bool {
        switch phase {
        case .transcribing, .processing, .cleaning, .rewriting, .publishing:
            return true
        case .idle, .recording, .failed:
            return false
        }
    }

    /// Single canonical surface: writes `phase` and derives `isRecording` /
    /// `startedAt` from the same projection. Pipeline phase is the only
    /// cross-process recording-state input this view-model accepts.
    func applyPipelineProjection(_ projection: PipelinePhaseProjection?) {
        guard let projection else {
            phase = .idle
            update(isRecording: false, startedAt: nil)
            return
        }
        phase = projection.phase
        switch projection.phase {
        case .recording:
            update(isRecording: true, startedAt: projection.recordingStartedAt)
        case .idle, .transcribing, .processing, .cleaning, .rewriting, .publishing, .failed:
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
}
