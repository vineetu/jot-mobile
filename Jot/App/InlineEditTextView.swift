import SwiftUI
import UIKit

/// A `UITextView`-backed editor that renders text **added or changed during the
/// current edit session** in *italic*, leaving the original text (present at
/// edit-start) regular. The italic is a session-only cue — the bound `text` is
/// always plain `String`, so Save persists no styling (flatten-on-save is free).
///
/// ## Why no diffing
/// Every edit this surface can produce is a SINGLE CONTIGUOUS replacement —
/// typing, backspace, paste, select-replace, and the voice stream's
/// `prefix + partial + suffix` rewrite (see `EditDictationController`). For a
/// single contiguous change the changed range is recovered EXACTLY in O(n) by a
/// common-prefix / common-suffix delta against the last text. No LCS, no fuzzy
/// alignment (which would mis-mark repeated dictation words). Keyboard typing
/// and the dictation stream both flow through this one path, so the controller
/// — which rewrites the `text` binding — needs no change.
///
/// All offsets are in UTF-16 units (UITextView's native index space) so emoji /
/// combining marks can't desync the ranges. The `selection` binding is exposed
/// as SwiftUI's `TextSelection?` (converted from the text view's UTF-16
/// `selectedRange`) so the existing insert-at-cursor controller keeps working.
struct InlineEditTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    /// Bump to start a fresh edit session: the whole current text re-baselines
    /// as "original" (regular) and the new-range set clears.
    let sessionToken: Int
    let isEditable: Bool
    let baseFont: UIFont
    let textColor: UIColor
    /// Two-way focus, replacing the SwiftUI `.focused($editorFocused)` the old
    /// `TextEditor` used: the host sets it true on edit-start to raise the
    /// keyboard, and the text view reports begin/end editing back through it.
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.textColor = textColor
        tv.font = baseFont
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        let coord = context.coordinator
        coord.lastText = text as NSString
        coord.sessionToken = sessionToken
        coord.newRanges = []
        tv.attributedText = coord.makeAttributed(text as NSString)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if tv.isEditable != isEditable { tv.isEditable = isEditable }

        // Drive first-responder off the `isFocused` binding (async so it doesn't
        // mutate responder state mid view-update). Gated on editability so we
        // never raise the keyboard on a disabled (mid-dictation) field.
        if isFocused, !tv.isFirstResponder, isEditable {
            DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        } else if !isFocused, tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }

        // New edit session → re-baseline everything as original (regular).
        if coord.sessionToken != sessionToken {
            coord.sessionToken = sessionToken
            coord.newRanges = []
            coord.lastText = text as NSString
            if tv.text != text { tv.text = text }
            coord.applyAttributed(tv, coord.makeAttributed(text as NSString),
                                  fromUser: true, caretAfterInsert: nil)
            return
        }

        // Programmatic change to the bound text (e.g. the voice stream rewrote
        // it). User keystrokes are handled in `textViewDidChange`, where
        // `tv.text` already equals the binding, so this guard skips them.
        if tv.text != text {
            coord.ingest(newText: text as NSString, in: tv, fromUser: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineEditTextView
        /// Last text we reconciled, in UTF-16 (NSString) space.
        var lastText: NSString = ""
        /// Spans added/changed this session, as UTF-16 `NSRange`s.
        var newRanges: [NSRange] = []
        var sessionToken: Int = .min
        /// Re-entrancy latch: true while WE mutate the text view, so our own
        /// delegate callbacks don't recurse.
        private var isApplying = false

        init(_ parent: InlineEditTextView) { self.parent = parent }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            guard !isApplying else { return }
            // BLOCKER 1 (review): never rebuild `attributedText` while an IME
            // composition is active (Pinyin/Kana/Hangul marked text, predictive)
            // — reassigning it tears down the composition. Keep the binding
            // current but leave `lastText` frozen at the pre-composition baseline
            // so that, on commit, the whole composed span is marked new.
            if tv.markedTextRange != nil {
                if parent.text != tv.text { parent.text = tv.text }
                return
            }
            ingest(newText: tv.text as NSString, in: tv, fromUser: true)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            guard !isApplying else { return }
            syncSelection(from: tv)
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }
        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        // MARK: Core

        /// Reconcile `newText` against `lastText`: recover the single contiguous
        /// changed range via common affixes, splice the new-range set, push the
        /// plain text to the binding, and repaint italic — caret preserved.
        func ingest(newText new: NSString, in tv: UITextView, fromUser: Bool) {
            let old = lastText
            let oldLen = old.length
            let newLen = new.length

            // Common prefix (UTF-16 units).
            var p = 0
            let maxP = min(oldLen, newLen)
            while p < maxP,
                  old.character(at: p) == new.character(at: p) { p += 1 }
            // Common suffix, not overlapping the prefix.
            var s = 0
            let maxS = min(oldLen, newLen) - p
            while s < maxS,
                  old.character(at: oldLen - 1 - s) == new.character(at: newLen - 1 - s) { s += 1 }

            let deletedLen = oldLen - p - s
            let insertedLen = newLen - p - s
            spliceNewRanges(editStart: p, deletedLen: deletedLen, insertedLen: insertedLen)

            lastText = new
            // BLOCKER 2 (review): only push the binding from the USER path — a
            // UIKit delegate callback where binding writes are tolerated. On the
            // voice/programmatic path we're inside `updateUIView` and the binding
            // was already set by the controller, so writing it again would be a
            // "modifying state during view update" hazard.
            if fromUser, parent.text != (new as String) { parent.text = new as String }

            // MAJOR 3 (review): on the voice path the saved caret is stale (the
            // text hasn't grown yet), so place the caret AFTER the inserted span.
            applyAttributed(tv, makeAttributed(new), fromUser: fromUser,
                            caretAfterInsert: fromUser ? nil : (p + insertedLen))
        }

        /// Standard interval-splice: edit at `editStart` removes `deletedLen`
        /// UTF-16 units and inserts `insertedLen`; the inserted region is new;
        /// ranges after the edit shift by `insertedLen - deletedLen`.
        private func spliceNewRanges(editStart p: Int, deletedLen: Int, insertedLen: Int) {
            let delEnd = p + deletedLen
            let delta = insertedLen - deletedLen
            var out: [NSRange] = []
            for r in newRanges {
                let a = r.location, b = r.location + r.length
                if b <= p {
                    out.append(r)                                   // entirely before
                } else if a >= delEnd {
                    out.append(NSRange(location: a + delta, length: r.length)) // entirely after
                } else {
                    if a < p { out.append(NSRange(location: a, length: p - a)) } // surviving head
                    if b > delEnd {                                  // surviving tail (shifted)
                        out.append(NSRange(location: delEnd + delta, length: b - delEnd))
                    }
                }
            }
            if insertedLen > 0 {
                out.append(NSRange(location: p, length: insertedLen)) // the new text
            }
            newRanges = Self.coalesce(out)
        }

        /// Merge touching / overlapping ranges so the attribute runs stay tidy.
        private static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
            let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
            var merged: [NSRange] = []
            for r in sorted {
                if let last = merged.last, r.location <= last.location + last.length {
                    let end = max(last.location + last.length, r.location + r.length)
                    merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
                } else {
                    merged.append(r)
                }
            }
            return merged
        }

        // MARK: Rendering

        func makeAttributed(_ string: NSString) -> NSAttributedString {
            let full = NSRange(location: 0, length: string.length)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 4 // parity with the prior TextEditor
            let attr = NSMutableAttributedString(string: string as String, attributes: [
                .font: parent.baseFont,
                .foregroundColor: parent.textColor,
                .paragraphStyle: para,
            ])
            let italic = Self.italicVariant(of: parent.baseFont)
            for r in newRanges {
                // Clamp to bounds (defense-in-depth: a wrong splice can't crash
                // `addAttribute`); style only the in-range portion.
                let clipped = NSIntersectionRange(r, full)
                if clipped.length > 0 {
                    attr.addAttribute(.font, value: italic, range: clipped)
                }
            }
            return attr
        }

        private static func italicVariant(of font: UIFont) -> UIFont {
            let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
            if let desc = font.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: desc, size: font.pointSize)
            }
            return UIFont.italicSystemFont(ofSize: font.pointSize)
        }

        /// Apply an attributed string while keeping the caret/selection where the
        /// user left it. Setting `attributedText` resets the selection to the
        /// end, so we capture and restore it.
        /// Apply an attributed string while keeping the caret sensible. Setting
        /// `attributedText` resets the selection to the end, so we restore it:
        /// the USER path restores the caret the user left (clamped to the new
        /// length); the VOICE path places it AFTER the freshly inserted span
        /// (`caretAfterInsert`, MAJOR 3). Typing attributes are pinned to ITALIC
        /// so the next typed character (new by definition) shows italic
        /// immediately with no regular→italic flicker (MAJOR 5).
        func applyAttributed(_ tv: UITextView, _ attributed: NSAttributedString,
                             fromUser: Bool, caretAfterInsert: Int?) {
            isApplying = true
            let saved = tv.selectedRange
            tv.attributedText = attributed
            let len = (tv.text as NSString).length
            if let caret = caretAfterInsert {
                tv.selectedRange = NSRange(location: min(max(caret, 0), len), length: 0)
            } else {
                let loc = min(saved.location, len)
                tv.selectedRange = NSRange(location: loc, length: min(saved.length, len - loc))
            }
            tv.typingAttributes = [
                .font: Self.italicVariant(of: parent.baseFont),
                .foregroundColor: parent.textColor,
            ]
            isApplying = false
            // Sync the selection binding. USER path = a UIKit callback (binding
            // write tolerated). VOICE path = inside `updateUIView`, so defer the
            // write off the update cycle (MAJOR 6).
            if fromUser {
                syncSelection(from: tv)
            } else {
                DispatchQueue.main.async { [weak self] in self?.syncSelection(from: tv) }
            }
        }

        // MARK: Selection bridge

        /// Mirror the UTF-16 `selectedRange` into the SwiftUI `TextSelection?`
        /// binding so `EditDictationController`'s insert-at-cursor resolves the
        /// caret. A zero-length caret and a real selection both map to a single
        /// `Range<String.Index>`.
        func syncSelection(from tv: UITextView) {
            let ns = tv.selectedRange
            let str = tv.text ?? ""
            guard let range = Range(ns, in: str) else {
                if parent.selection != nil { parent.selection = nil }
                return
            }
            parent.selection = TextSelection(range: range)
        }
    }
}
