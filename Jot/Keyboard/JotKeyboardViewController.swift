import AppIntents
import SwiftUI
import UIKit
import OSLog

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

    private var hostingController: UIHostingController<AnyView>?
    private let recordingState = KeyboardRecordingState()

    // MARK: - Phase 2.5 collapsed-keyboard state
    //
    // Height transitions are driven by an explicit `NSLayoutConstraint`
    // on `self.view.heightAnchor` (priority 999, long-lived). We mutate
    // `.constant` between `expandedHeight` and `collapsedHeight` and
    // animate via `UIView.animate(...)` + `layoutIfNeeded()`. SwiftUI's
    // `withAnimation` is deliberately NOT used for the envelope because
    // `UIHostingController` on iOS 17+ mis-handles height-affecting
    // animations (Apple Developer Forums thread 776712); SwiftUI only
    // owns the inner content cross-fade.
    //
    // Persistence: `UserDefaults.standard`, scoped to the appex
    // sandbox. We deliberately do NOT share this preference with the
    // main app via App Group — collapse is a keyboard-only affordance.

    private static let collapsedHeight: CGFloat = 58
    // Bug 8 (2026-05-11): keyboard was too tall at 450pt — recents strip
    // alone was 268pt. After Bug 8/9/11 fixes the strip drops to ~128pt
    // (3 visible rows + scroll) and the bottom row loses the globe key,
    // so total envelope can shrink to the native-keyboard band (~310pt).
    private static let expandedHeight: CGFloat = 310

    /// User-preferred collapsed state, persisted across keyboard
    /// presentations. Seeded from `UserDefaults.standard` so a user who
    /// last left the keyboard collapsed re-opens to the same surface.
    private var isCollapsed: Bool = UserDefaults.standard.bool(
        forKey: "jot.keyboard.collapsed"
    )

    /// Long-lived height pin on `self.view`. Installed in `viewDidLoad`,
    /// mutated by `applyCollapsedHeight(animated:)`, re-applied on
    /// rotation to defend against any platform-side constraint solver
    /// resets.
    private var heightConstraint: NSLayoutConstraint?

    /// Safety timer fallback for the status-banner auto-expand. The
    /// banner's SwiftUI `.task` normally calls `clearStatusBannerSlot()`
    /// at ~2.5s, but if the banner is dropped without that callback
    /// firing (e.g. external clear path) we still want to drop back to
    /// the collapsed bar — this Task enforces that.
    private var bannerAutoExpandResetTask: Task<Void, Never>?
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
    private var historyMirrorUpdatedObserver: CrossProcessNotification.Observer?
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
    /// v2 retheme (2026-05-11): last `textDocumentProxy.keyboardAppearance`
    /// value passed into the SwiftUI tree. Tracked here so
    /// `renderRootViewIfAppearanceChanged()` can re-render when a host
    /// dynamically switches its appearance (e.g. dark Mail flipping
    /// to a light compose modal mid-session). Initially `nil` so the
    /// first render always sets the baseline.
    private var renderedKeyboardAppearance: UIKeyboardAppearance?
    private var magicFollowUpExpiresAt: Date?

    /// Snapshot of recent transcripts loaded from the App Group mirror.
    /// Captured on appearance and whenever the user opens history — the
    /// mirror is cheap to read, but we still avoid re-reading on every
    /// keystroke.
    private var historyEntries: [TranscriptHistoryMirror.Entry] = []

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

    override func loadView() {
        let inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        self.view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Jot mic CTA is its own affordance; we do not provide a system dictation key.
        hasDictationKey = false
        installKeyboardView()
        installHeightConstraint()
        startObservingHistoryMirrorUpdated()
        startObservingPipelinePhase()
        startObservingStreamingPartial()
        // [KB-COLLAPSE-DEBUG] One-time static-config snapshot. The
        // UIInputView.allowsSelfSizing flag is set in loadView() and
        // never mutated; logging it once at startup tells us whether
        // self-sizing is the suspect when the collapse height fails to
        // visibly apply (Symptom 2 — outer envelope stays expanded).
        let allowsSelfSizing = (self.view as? UIInputView)?.allowsSelfSizing ?? false
        keyboardLog.log(
            "[KB-COLLAPSE-DEBUG] viewDidLoad allowsSelfSizing=\(allowsSelfSizing, privacy: .public)"
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh the Full Access grant — the user can flip "Allow Full
        // Access" in Settings between keyboard presentations, and haptic +
        // audio both require it. Then warm the Taptic Engine so the first
        // keypress feels as crisp as the hundredth (HIG → Playing Haptics).
        feedback.fullAccess = hasFullAccess
        feedback.prepare()
        // Mirror Full Access state to the App Group so the main app
        // (specifically the W3 wizard step) can detect it. iOS does not
        // expose a direct API for the main app to read `hasFullAccess`;
        // this write is the workaround. Caveat: until the user has
        // presented the keyboard at least once after enabling FA, the
        // flag remains false on the app side.
        AppGroup.keyboardHasFullAccess = hasFullAccess
        startObservingHistoryMirrorUpdated()
        startObservingPipelinePhase()
        startObservingStreamingPartial()
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
        refreshStatusBanner()
        renderRootView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        historyMirrorUpdatedObserver = nil
        pipelinePhaseObserver = nil
        streamingPartialObserver = nil
        pipelineStaleDeadlineTask?.cancel()
        pipelineStaleDeadlineTask = nil
        pendingLaunchDeadlineTask?.cancel()
        pendingLaunchDeadlineTask = nil
        cancelBackspaceRepeat()
        cancelBannerAutoExpandReset()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
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
        renderedKeyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
    }

    private func renderRootView() {
        hostingController?.rootView = makeRootView()
        renderedActionAvailability = currentActionAvailability
        // v2 retheme: snapshot the appearance so we can detect future
        // dynamic flips without re-rendering on every text-input poll.
        renderedKeyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
    }

    // MARK: - Phase 2.5 collapsed-keyboard plumbing

    /// Installs the long-lived height pin on `self.view`. Priority
    /// `.required - 1` (999) so iOS's own input-view geometry
    /// constraints (system-imposed, priority 1000) always win in any
    /// hypothetical edge case — but at 999 our value drives the layout
    /// pass under normal conditions. Long-lived: never deactivated,
    /// only its `.constant` mutates.
    private func installHeightConstraint() {
        guard heightConstraint == nil else { return }
        let constraint = view.heightAnchor.constraint(
            equalToConstant: isCollapsed
                ? Self.collapsedHeight
                : Self.expandedHeight
        )
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint
    }

    /// User-initiated flip between collapsed (58pt) and standard
    /// (450pt). Persists the new state to `UserDefaults` so the next
    /// keyboard presentation honors the user's choice, announces the
    /// transition over VoiceOver, then animates the height. The
    /// SwiftUI tree picks up the new `isCollapsed` via `renderRootView`
    /// and does its own cross-fade (the `withAnimation` keyed on
    /// `isCollapsed` inside `KeyboardView.body`).
    func toggleCollapsed() {
        // [KB-COLLAPSE-DEBUG] Entry log captures the PRE-toggle state plus
        // the full geometry snapshot. A second toggleCollapsed call within
        // ~250ms (Symptom 1 — double-tap race) shows up here as two entries
        // back-to-back with matching `isCollapsed=old` values.
        logCollapseGeometry(label: "toggleCollapsed entry isCollapsed=\(isCollapsed)")
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: "jot.keyboard.collapsed")
        UIAccessibility.post(
            notification: .announcement,
            argument: isCollapsed ? "Keyboard minimized" : "Keyboard expanded"
        )
        // Re-render BEFORE the animate block so the SwiftUI branch swap
        // begins immediately; UIKit handles the height envelope.
        renderRootView()
        applyCollapsedHeight(animated: true)
    }

    /// Mutates the height constraint to match the current `isCollapsed`
    /// value. Honors Reduce Motion (no-animate branch). The
    /// `layoutIfNeeded()` call is what actually drives the visible
    /// height change — without it AutoLayout would batch the constant
    /// change to the next layout pass.
    private func applyCollapsedHeight(animated: Bool) {
        guard let constraint = heightConstraint else { return }
        let target: CGFloat = isCollapsed ? Self.collapsedHeight : Self.expandedHeight
        // [KB-COLLAPSE-DEBUG] Entry: what we are about to ask the
        // constraint solver for. Compare the post-settle bounds against
        // `target` to know whether the solver actually honored our pin.
        logCollapseGeometry(
            label: "applyCollapsedHeight target=\(Int(target)) animated=\(animated)"
        )
        constraint.constant = target

        let runImmediate = !animated || UIAccessibility.isReduceMotionEnabled
        if runImmediate {
            view.layoutIfNeeded()
            // [KB-COLLAPSE-DEBUG] Post-layout in the immediate (no-animate)
            // path so we capture the same moment as the animated branch.
            logCollapseGeometry(label: "post-layoutIfNeeded (immediate)")
            DispatchQueue.main.async { [weak self] in
                self?.logCollapseGeometry(label: "post-settle (next runloop, immediate)")
            }
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) { [weak self] in
            self?.view.layoutIfNeeded()
            // [KB-COLLAPSE-DEBUG] Inside the animate block, immediately
            // after `layoutIfNeeded()` — bounds here should reflect the
            // post-layout state for the in-flight animation pass.
            self?.logCollapseGeometry(label: "post-layoutIfNeeded")
        }
        // [KB-COLLAPSE-DEBUG] Schedule a post-settle snapshot on the
        // NEXT runloop tick (NOT in the animate completion handler — we
        // want the steady-state value after the system input-view host
        // gets a chance to re-evaluate intrinsicContentSize / its own
        // size constraints, which Symptom 2 suggests is the failure
        // mode for the outer envelope).
        DispatchQueue.main.async { [weak self] in
            self?.logCollapseGeometry(label: "post-settle (next runloop)")
        }
    }

    /// [KB-COLLAPSE-DEBUG] Single value-capture helper so every log point
    /// records the same geometry fields. Centralizing the snapshot keeps
    /// the call sites tiny and guarantees a consistent format for the
    /// user's Console.app filter. Pure read — no side effects, no
    /// layout triggers.
    private func logCollapseGeometry(label: String) {
        let constraintConstant = heightConstraint?.constant ?? -1
        let bounds = view.bounds.height
        let intrinsic = view.intrinsicContentSize.height
        let hostingHeight = hostingController?.view.bounds.height ?? -1
        keyboardLog.log(
            "[KB-COLLAPSE-DEBUG] \(label, privacy: .public) isCollapsed=\(self.isCollapsed, privacy: .public) constraint.constant=\(constraintConstant, privacy: .public) view.bounds.h=\(bounds, privacy: .public) view.intrinsic.h=\(intrinsic, privacy: .public) hosting.bounds.h=\(hostingHeight, privacy: .public)"
        )
    }

    /// Defensive re-application of the height after a rotation /
    /// trait-collection change. The system input-view container may
    /// reset solver state across orientation changes; re-asserting our
    /// preferred constant inside the transition coordinator keeps the
    /// collapsed state visually consistent.
    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        // [KB-COLLAPSE-DEBUG] viewWillTransition fires on rotation /
        // trait-collection change. If Symptom 1 (failed maximize) ever
        // correlates with an unexpected transition right at tap time
        // (e.g. the system input-view host re-sizing us underneath the
        // animate block), it should show up here interleaved with the
        // toggleCollapsed entry log.
        logCollapseGeometry(label: "viewWillTransition to=\(size.width)x\(size.height)")
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.heightConstraint?.constant = self.isCollapsed
                ? Self.collapsedHeight
                : Self.expandedHeight
            self.view.layoutIfNeeded()
        })
    }

    /// Central setter for `statusBanner`. Routes every write through a
    /// single seam so the Phase 2.5 auto-expand hook fires consistently:
    /// when a banner needs to render and the user is in collapsed mode,
    /// we temporarily lift the height to `expandedHeight` so the banner
    /// is visible, then collapse back after the banner lifecycle ends
    /// (either via `clearStatusBannerSlot()` from the SwiftUI `.task`
    /// or via the 2.5s safety timer).
    ///
    /// The user's `isCollapsed` preference is NOT mutated by this auto-
    /// expand — only the live height constraint is. When the banner
    /// clears we restore the height to whatever `isCollapsed` says it
    /// should be (per plan §14.2).
    private func setStatusBanner(_ message: String?) {
        let previous = statusBanner
        statusBanner = message

        let wasNil = (previous == nil)
        let isNonNil = (message != nil && !(message?.isEmpty ?? true))
        let nowNil = (message == nil || (message?.isEmpty ?? true))

        if wasNil, isNonNil, isCollapsed {
            // nil → non-nil while collapsed: temporary expand for the
            // banner lifetime so the user actually sees the message.
            temporarilyExpandForBanner()
        } else if !wasNil, nowNil, isCollapsed {
            // non-nil → nil while user preference is collapsed: snap
            // back to the collapsed envelope.
            cancelBannerAutoExpandReset()
            applyCollapsedHeight(animated: true)
        }
    }

    /// Lifts the height to `expandedHeight` so a status banner is
    /// visible in collapsed mode. Arms a 2.5s safety reset Task that
    /// restores the collapsed height even if `clearStatusBannerSlot()`
    /// never fires (defensive — the banner's SwiftUI `.task` should
    /// always fire, but a host that tears the keyboard down mid-banner
    /// would skip the callback).
    private func temporarilyExpandForBanner() {
        guard isCollapsed, let constraint = heightConstraint else { return }
        constraint.constant = Self.expandedHeight
        if UIAccessibility.isReduceMotionEnabled {
            view.layoutIfNeeded()
        } else {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState]
            ) { [weak self] in
                self?.view.layoutIfNeeded()
            }
        }
        cancelBannerAutoExpandReset()
        bannerAutoExpandResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_500))
            guard let self, !Task.isCancelled else { return }
            // Only collapse back if the user still prefers collapsed —
            // a user-initiated expand during the banner lifetime should
            // win.
            if self.isCollapsed {
                self.applyCollapsedHeight(animated: true)
            }
            self.bannerAutoExpandResetTask = nil
        }
    }

    private func cancelBannerAutoExpandReset() {
        bannerAutoExpandResetTask?.cancel()
        bannerAutoExpandResetTask = nil
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

    private func makeRootView() -> AnyView {
        // Builds the hosted SwiftUI keyboard surface.
        AnyView(makeKeyboardView())
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            hasFullAccess: hasFullAccess,
            hasPasteboardContent: hasPasteboardContent,
            recordingState: recordingState,
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            returnKeyType: textDocumentProxy.returnKeyType ?? .default,
            historyEntries: historyEntries,
            canUndoLastInsertion: canUndoLastInsertion,
            canRedoInsertion: canRedoInsertion,
            lastPastedText: lastPastedText,
            lastPastedAt: lastPastedAt,
            isStopRequestPending: stopRequestPosted,
            statusBanner: statusBanner,
            isCollapsed: isCollapsed,
            // v2 retheme (2026-05-11): host's `keyboardAppearance` hint.
            // Some hosts (dark Mail, dark Notes, Spotlight) force
            // `.dark` even when the system itself is in light mode. We
            // pass the proxy's signal through; `KeyboardView` resolves
            // it against the SwiftUI `colorScheme` env and the dark
            // path wins if either says dark.
            keyboardAppearance: textDocumentProxy.keyboardAppearance ?? .default,
            onCopy: { [weak self] in self?.handleCopyMenuSelection() },
            onPaste: { [weak self] in self?.handlePasteMenuSelection() },
            onCopyLastDictation: { [weak self] in self?.handleCopyLastDictation() },
            onUndoLastInsertion: { [weak self] in self?.handleUndoMenuSelection() },
            onRedoInsertion: { [weak self] in self?.handleRedoMenuSelection() },
            onTapToSpeak: { [weak self] in self?.handleMicCTATap() },
            onInsertHistoryEntry: { [weak self] entry in self?.insertHistoryEntry(entry) },
            onInsertText: { [weak self] text in self?.insertHistoryText(text) },
            onKey: { [weak self] key in self?.handleKeyTap(key) },
            onKeyPressChange: { [weak self] key, pressed in self?.handleKeyPressChange(key, pressed: pressed) },
            onAdvanceToNextInputMode: { [weak self] in self?.advanceToNextInputMode() },
            onOpenFullAccess: { [weak self] in self?.openFullAccessPrompt() },
            onStatusBannerRendered: { [weak self] in self?.clearStatusBannerSlot() },
            onOpenHome: { [weak self] in self?.openHostHome() },
            onToggleCollapsed: { [weak self] in self?.toggleCollapsed() },
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
            // Snapshot the surfaces that may shift as a result of the
            // write, then refresh and re-render only on actual change.
            // Banner state can move because timeout / error fallback
            // paths write a new message immediately before the ledger
            // append that triggered this notification.
            let priorBanner = self.statusBanner
            let priorHistory = self.historyEntries
            self.refreshStatusBanner()
            // The mirror is the source of truth for the RecentsStrip
            // rows. Without this reload, a new dictation only appears
            // the next time the keyboard is re-presented — the just-now
            // marker ages out after 5s and the strip then shows stale
            // entries missing the latest transcript.
            self.refreshHistory()
            if priorBanner != self.statusBanner
                || priorHistory != self.historyEntries {
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
            // Phase 2 just-now marker (plan §4.3 / §13 risk 7) — stamp
            // the keyboard's own state at the moment of insertion so the
            // RecentsStrip's top row can render in the green just-now
            // style for ~5s. Reading AppGroup.lastDictation after this
            // returns nil because markConsumed() (below) clears it.
            stampJustNowMarker(text: payload.text)
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

    /// Copies the most recent transcript to the system clipboard. Backs
    /// the Actions popover "Copy last" row (Mockup 06 / plan §4.5).
    /// Sourced from `historyEntries` (a `TranscriptHistoryMirror`
    /// projection) — NOT from `AppGroup.lastDictation`, which is
    /// consumed by auto-paste.
    private func handleCopyLastDictation() {
        fireMenuSelectionFeedback()
        guard hasFullAccess else { return }
        guard let latest = historyEntries.first else { return }
        UIPasteboard.general.string = latest.text
        hasPasteboardContent = true
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
        if let expiresAt = expiresAtSnapshot, expiresAt > now,
           let heartbeat = heartbeatSnapshot,
           now.timeIntervalSince(heartbeat) < 4.0 {
            CrossProcessNotification.post(name: CrossProcessNotification.warmResumeRequested)
            keyboardLog.info("Posted warm-resume; skipping URL bounce")
            return
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
        let decision = decideMicTap()
        if hasFullAccess && AppGroup.isJotAppForeground(),
           case .start = decision {
            CrossProcessNotification.post(
                name: CrossProcessNotification.keyboardDictateTapped
            )
            keyboardLog.info("mic tap routed via Darwin notification (host=Jot)")
            return
        }
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

    /// Bounces to the main app via `jot://full-access` so the user lands
    /// on `FullAccessPromptSheet` — an explanatory screen with the
    /// literal Settings breadcrumb and an "Open Settings" CTA — rather
    /// than being silently dumped into iOS Settings.
    ///
    /// Called when the user taps the locked-state "Enable Full Access"
    /// pill in either the standard `KeyboardView` or the
    /// `CollapsedBarView`. The main app's `.onOpenURL` handler in
    /// `JotApp.swift` recognises the `full-access` host and presents
    /// the sheet without auto-foregrounding Settings — see that handler
    /// for rationale.
    ///
    /// Falls back to `openHostSettings()` (direct iOS Settings) if the
    /// URL construction somehow fails or `extensionContext.open` reports
    /// failure — better to drop the user in raw Settings than to leave
    /// the tap doing nothing.
    private func openFullAccessPrompt() {
        guard let url = URL(string: "jot://full-access") else {
            openHostSettings()
            return
        }
        extensionContext?.open(url) { [weak self] success in
            guard !success else { return }
            Task { @MainActor in
                self?.openHostSettings()
            }
        }
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
