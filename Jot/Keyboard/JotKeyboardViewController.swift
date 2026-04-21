import SwiftUI
import UIKit

/// Jot's custom keyboard extension. Provides an Apple-faithful QWERTY +
/// numbers + symbols surface plus two Jot-specific affordances:
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

    private var hostingController: UIHostingController<KeyboardView>?

    // MARK: - Keyboard state

    /// Which plane (letters / numbers / symbols) we're showing. Rendered
    /// by ``KeyboardView``.
    private var plane: KeyboardLayouts.Plane = .letters

    /// Shift modifier. Single tap cycles off ↔ shifted; double-tap locks
    /// caps. See ``handleShiftTap`` for the double-tap window.
    private var shiftState: ShiftState = .off

    /// Timestamp of the most recent shift tap. Two taps inside
    /// ``shiftDoubleTapWindow`` promote to caps lock.
    private var lastShiftTapAt: Date?

    private let shiftDoubleTapWindow: TimeInterval = 0.35

    // MARK: - Jot affordance state

    /// Latest preview string from ``ClipboardHandoff`` — nil when no fresh
    /// dictation is available. Refreshed in ``viewWillAppear`` and cleared
    /// after a paste.
    private var freshPreview: String?

    /// Snapshot of recent transcripts loaded from the App Group mirror.
    /// Captured on appearance and whenever the user opens history — the
    /// mirror is cheap to read, but we still avoid re-reading on every
    /// keystroke.
    private var historyEntries: [TranscriptHistoryMirror.Entry] = []

    /// Whether the history overlay is currently visible.
    private var showHistory = false

    /// Guards against auto-paste firing twice within a single keyboard
    /// presentation (e.g. orientation change → `viewWillAppear` re-entry).
    private var autoPasteAttempted = false

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
        installKeyboardView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh the Full Access grant — the user can flip "Allow Full
        // Access" in Settings between keyboard presentations, and haptic +
        // audio both require it. Then warm the Taptic Engine so the first
        // keypress feels as crisp as the hundredth (HIG → Playing Haptics).
        feedback.fullAccess = hasFullAccess
        feedback.prepare()
        refreshPasteState()
        refreshHistory()
        renderRootView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelBackspaceRepeat()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // Intentionally a no-op. Reading UIPasteboard here would fire iOS's
        // paste-privacy toast on every keystroke. The pasteboard is only
        // queried on appearance via refreshPasteState().
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
    }

    private func renderRootView() {
        hostingController?.rootView = makeRootView()
    }

    private func makeRootView() -> KeyboardView {
        KeyboardView(
            preview: freshPreview,
            hasFullAccess: hasFullAccess,
            plane: plane,
            shiftState: shiftState,
            historyEntries: historyEntries,
            showHistory: showHistory,
            onKey: { [weak self] key in self?.handleKeyTap(key) },
            onKeyPressChange: { [weak self] key, pressed in self?.handleKeyPressChange(key, pressed: pressed) },
            onPaste: { [weak self] in self?.insertFreshTranscript() },
            onToggleHistory: { [weak self] in self?.toggleHistory() },
            onInsertHistoryEntry: { [weak self] entry in self?.insertHistoryEntry(entry) },
            onOpenFullAccess: { [weak self] in self?.openHostSettings() },
            feedback: feedback
        )
    }

    // MARK: - Paste / handoff

    private func refreshPasteState() {
        // Without Full Access, the extension's UIPasteboard read is isolated
        // from the main app's clipboard and the App Group defaults return
        // sandboxed values on some iOS versions. Surface a setup hint via the
        // accessory bar instead of pretending there's nothing to paste.
        guard hasFullAccess else {
            freshPreview = nil
            return
        }

        let preview = ClipboardHandoff.pendingFreshTranscriptPreview()
        let autoPasteEnabled = AppGroup.defaults.bool(forKey: AppGroup.Keys.keyboardAutoPasteEnabled)

        if preview != nil, autoPasteEnabled, !autoPasteAttempted {
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

        textDocumentProxy.insertText(text)
        ClipboardHandoff.markConsumed()
        freshPreview = nil
        renderRootView()
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

    private func toggleHistory() {
        if !showHistory {
            refreshHistory()
        }
        showHistory.toggle()
        renderRootView()
    }

    private func insertHistoryEntry(_ entry: TranscriptHistoryMirror.Entry) {
        textDocumentProxy.insertText(entry.text)
        showHistory = false
        renderRootView()
    }

    // MARK: - Key dispatch

    private func handleKeyTap(_ key: KeyboardKeyDescriptor) {
        switch key {
        case .letter, .literal, .space, .returnKey:
            if let text = key.insertion(for: shiftState) {
                textDocumentProxy.insertText(text)
                if case .letter = key {
                    shiftState = shiftState.afterLetterInsert()
                }
                renderRootView()
            }

        case .backspace:
            textDocumentProxy.deleteBackward()
            // No state change — renderer doesn't depend on cursor position.

        case .shift:
            handleShiftTap()

        case .planeToggle(let target, _):
            plane = target
            // Cycling through planes resets shift — matches Apple; the
            // number + symbol planes don't meaningfully "shift".
            if target != .letters {
                shiftState = .off
            }
            renderRootView()

        case .historyKey:
            // Bottom-row placement — thumb-reachable on a one-handed grip.
            // Toggling here mirrors the old accessory-bar button one-for-one,
            // so the overlay path (refresh + show/hide) is unchanged.
            toggleHistory()
        }
    }

    /// Single vs double-tap resolution for the shift key. Inside the double-
    /// tap window we promote to caps lock; otherwise we cycle on/off.
    private func handleShiftTap() {
        let now = Date()
        if let last = lastShiftTapAt, now.timeIntervalSince(last) < shiftDoubleTapWindow {
            shiftState = .capsLocked
            lastShiftTapAt = nil
        } else {
            shiftState = shiftState.singleTapped()
            lastShiftTapAt = now
        }
        renderRootView()
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
            self?.openFallbackSettingsURL(fallbackURLString)
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
