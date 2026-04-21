import AudioToolbox
import UIKit

/// Owns the haptic + audio generators used by the keyboard. A single instance
/// lives on ``JotKeyboardViewController`` for the lifetime of the extension
/// view, so the Taptic Engine stays warm and the first keypress feels as
/// crisp as the hundredth.
///
/// ## Why `UISelectionFeedbackGenerator` (not `UIImpactFeedbackGenerator`)
///
/// The main Jot macOS app uses `UIImpactFeedbackGenerator(.medium / .soft /
/// .rigid)` for record/stop/action events. That's the correct pattern for
/// one-shot app gestures. A keyboard is different: every press is a
/// discrete-choice event (like a picker tick or a segmented-control tap),
/// and iOS's own keyboard uses `UISelectionFeedbackGenerator` for every
/// press, release, and repeat.
///
/// Two reasons `.selectionChanged` beats `.light` impact for rapid typing,
/// both verified in `docs/research/ios-keyboard-1to1.md` §4.3:
///
/// 1. The Taptic Engine's selection profile has ~10 ms of ring-down vs
///    ~25 ms for a light impact. On a fast typist, light impacts literally
///    smear across subsequent presses.
/// 2. `.selectionChanged` is the API Apple designed for discrete-choice
///    feedback. The KeyboardKit maintainers landed on it after extensive
///    device comparison; we follow their lead.
///
/// The only place we use impact is the long-press transition (e.g. entering
/// the action callout, engaging space-drag cursor navigation). That's a
/// heavier state change and `.mediumImpact` signals it correctly.
///
/// ## Why the generators are long-lived
///
/// Apple's HIG → Playing Haptics explicitly says: "Prepare a haptic
/// generator shortly before you expect to play haptic feedback." If we
/// allocate the generator per keypress, the Taptic Engine has to ramp up
/// and the first tick is noticeably weaker. Instead, we prepare once at
/// view-will-appear time and call `prepare()` again after every fire to
/// keep the engine warm for the next press.
///
/// The main Jot app has a comment noting `AVHapticClient.finish` error
/// -4805 ("Player was not running") when generators aren't persisted —
/// same class of bug, same fix.
///
/// ## Full Access gate
///
/// Keyboard extensions run in a sandbox that silently drops
/// `AudioServicesPlaySystemSound`, `UIDevice.playInputClick`, and
/// `UIImpactFeedbackGenerator.impactOccurred` unless the user has granted
/// Full Access (`RequestsOpenAccess = YES` in the extension's Info.plist,
/// plus the user toggling "Allow Full Access" in Settings).
///
/// We check `fullAccess` before every fire: no-op when it's off, so the
/// keyboard silently degrades to "no haptic, no audio" instead of throwing
/// or logging spew.
///
/// ## Per-key audio dispatch
///
/// The iOS native keyboard differentiates three distinct system sounds:
///
/// | Key class | SystemSoundID | Source |
/// |---|---|---|
/// | Input (alpha, digits, punctuation) | 1104 | `Tock.caf` — fires via `UIDevice.current.playInputClick()` |
/// | Delete / backspace | 1155 | Distinct "Tock-Delete" |
/// | System (shift, 123/ABC, return, globe) | 1156 | Distinct "Tock-System" |
///
/// A build that plays 1104 on every key sounds subtly wrong to attentive
/// users. We use `UIDevice.playInputClick()` for input (which hands the
/// decision to iOS — respects the Settings toggle, respects the mute
/// switch, uses the right sound) and `AudioServicesPlaySystemSound` for the
/// two other classes.
///
/// `UIDevice.playInputClick()` requires the host view to conform to
/// `UIInputViewAudioFeedback` and return `true` from
/// `enableInputClicksWhenVisible`. That conformance lives on
/// ``JotKeyboardViewController`` — see its `enableInputClicksWhenVisible`
/// override.
///
/// ## Concurrency
///
/// `@MainActor`-isolated: every member touches a UIKit API
/// (`UISelectionFeedbackGenerator`, `UIImpactFeedbackGenerator`,
/// `UIDevice`, `AudioServicesPlaySystemSound`) that Swift 6 marks
/// main-actor-only. The keyboard view controller is itself `@MainActor`,
/// and every call site fires from a main-actor context (press gesture,
/// timer tick on the main run loop), so isolating the whole class is
/// the cleanest fit — no cross-actor bookkeeping, and the compiler
/// guarantees we never try to fire a haptic from a background queue.
@MainActor
final class KeyboardFeedback {

    // MARK: - Configuration

    /// Whether the keyboard extension has Full Access. Read from
    /// ``UIInputViewController.hasFullAccess`` on init and refreshed on
    /// every `viewWillAppear` (the user can flip the Settings toggle while
    /// the keyboard is dismissed).
    var fullAccess: Bool

    // MARK: - Generators

    /// The workhorse generator. Fires on every press/release/repeat on
    /// every key class. One shared instance so the Taptic Engine stays warm.
    private let selection = UISelectionFeedbackGenerator()

    /// Reserved for long-press transitions (callout open, space-drag entry).
    /// Medium impact signals the state change without overwhelming rapid
    /// typing — exactly the role `UISelectionFeedbackGenerator` fills for
    /// ordinary presses.
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Lifecycle

    init(fullAccess: Bool) {
        self.fullAccess = fullAccess
    }

    /// Warm up both generators. Call from `viewWillAppear` — Apple's HIG
    /// guidance is to prepare a few hundred milliseconds before expected
    /// use, which matches the time between the keyboard appearing and the
    /// first keypress.
    func prepare() {
        guard fullAccess else { return }
        selection.prepare()
        mediumImpact.prepare()
    }

    // MARK: - Fire — haptic

    /// A key was pressed, released, or fired as part of a repeat tick. Same
    /// haptic for all three — matches iOS's selection-flavored keyboard
    /// feel. Re-prepares after firing to keep the engine warm.
    func selectionTick() {
        guard fullAccess else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    /// The user held a key long enough to open the action callout (the
    /// long-press alternate popover), or pressed-and-held space to engage
    /// cursor-drag. Medium impact on entry; subsequent character moves use
    /// ``selectionTick``.
    func longPressImpact() {
        guard fullAccess else { return }
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    // MARK: - Fire — audio

    /// An input key was tapped — alpha, digits, punctuation, space. Uses
    /// `UIDevice.playInputClick()`, which respects the system's keyboard
    /// sound Settings and requires the containing view to conform to
    /// `UIInputViewAudioFeedback`.
    func inputClick() {
        guard fullAccess else { return }
        UIDevice.current.playInputClick()
    }

    /// Delete / backspace was tapped. iOS uses SystemSoundID 1155 for this
    /// — a distinct "Tock-Delete" tone.
    func deleteClick() {
        guard fullAccess else { return }
        AudioServicesPlaySystemSound(1155)
    }

    /// A system key was tapped — shift, plane toggle (123/ABC/#+=), return,
    /// globe. iOS uses SystemSoundID 1156 for all of these — a distinct
    /// "Tock-System" tone.
    func systemClick() {
        guard fullAccess else { return }
        AudioServicesPlaySystemSound(1156)
    }
}

// MARK: - Descriptor convenience

extension KeyboardFeedback {
    /// Fire the haptic + audio pair appropriate for `descriptor` on its
    /// press event. Centralizes the per-key-class audio dispatch so
    /// ``KeyboardKey`` doesn't grow a switch on descriptor — the feedback
    /// object owns that knowledge.
    func firePress(for descriptor: KeyboardKeyDescriptor) {
        selectionTick()
        switch descriptor {
        case .letter, .literal, .space:
            inputClick()
        case .backspace:
            deleteClick()
        case .shift, .returnKey, .planeToggle, .historyKey:
            systemClick()
        }
    }
}
