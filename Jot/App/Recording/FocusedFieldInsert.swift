import UIKit

/// In-process insertion of dictated text into Jot's OWN focused field.
///
/// ## Why this exists
/// In-Jot keyboard dictation (Send Feedback, transcript Edit, Setup-Wizard W5)
/// stops via the keyboard's cross-process `stopRequested`, but the resulting
/// paste must NOT rely on the keyboard's `textDocumentProxy.insertText` flush.
/// When Jot is itself the host, Jot's own SwiftUI re-render on the
/// recording-state flip perturbs the focused field's `documentIdentifier` /
/// first-responder mid round-trip — exactly the condition the keyboard's
/// same-host paste guards reject (`JotKeyboardViewController`
/// `flushPendingAutoPasteIfPossible`: documentIdentifier-changed skip +
/// `documentContextBeforeInput == nil` no-op). The result is a silently
/// dropped paste.
///
/// The pre-unification engine sidestepped this by inserting in-process into the
/// app's own field binding (the deleted `InlineDictationReceiver` did exactly
/// this). This helper restores that one capability — a direct first-responder
/// insert — WITHOUT reviving the registration layer. It's a single sink, not a
/// register/deregister/heroFallback machinery.
///
/// ## App-Store safety
/// Public UIKit APIs only: the `sendAction(to: nil)` first-responder trap (the
/// standard, documented way to discover the current first responder) and the
/// `UIKeyInput.insertText(_:)` protocol method. No private selectors.
enum FocusedFieldInsert {

    /// Inserts `text` at the caret of the current first responder if it is a
    /// text-input field (`UIKeyInput`). Returns `true` when the insert was
    /// dispatched to a field, `false` when there was no editable first responder
    /// (or `text` was empty) so the caller can fall back.
    ///
    /// `UIKeyInput.insertText` is what `UITextField` / `UITextView` (SwiftUI
    /// `TextField` / `TextEditor` / the transcript-edit `InlineEditTextView`)
    /// implement — so this lands in all three in-Jot surfaces.
    @MainActor
    @discardableResult
    static func insertIntoFocusedField(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let responder = UIResponder.jotCurrentFirstResponder(),
              let keyInput = responder as? UIKeyInput else {
            return false
        }
        keyInput.insertText(text)
        return true
    }
}

/// Box for the first-responder trap result. (A `UIResponder` extension can't
/// hold a stored static property, so the captured responder lives here.)
private enum FirstResponderBox {
    @MainActor static weak var responder: UIResponder?
}

extension UIResponder {
    /// The current first responder, found via the canonical `sendAction(to:nil)`
    /// trap: with a `nil` target the action is delivered to the first responder
    /// and travels up the chain. Because `jotCaptureFirstResponder` is defined
    /// on `UIResponder`, the first responder itself handles it and records
    /// `self` — so the captured object IS the first responder. Read synchronously
    /// right after the (synchronous) dispatch, so there's no interleave.
    @MainActor
    static func jotCurrentFirstResponder() -> UIResponder? {
        FirstResponderBox.responder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.jotCaptureFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        return FirstResponderBox.responder
    }

    @MainActor
    @objc private func jotCaptureFirstResponder() {
        FirstResponderBox.responder = self
    }
}
