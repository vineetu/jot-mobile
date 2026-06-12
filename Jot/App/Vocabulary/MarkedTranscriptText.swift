import SwiftUI
import UIKit

/// **The transcript body, rendered so gated words can be marked + tapped.**
/// A read-only, still-SELECTABLE `UITextView` (plan §v2-E) that renders the
/// transcript as an `AttributedString` with an underline on each unresolved
/// gated occurrence — solid blue = CHANGED (applied), dashed grey = KEPT — and
/// reports a tap on a marked word with that word's on-screen rect so the parent
/// can anchor a review bubble at it.
///
/// Why a `UITextView` and not SwiftUI `Text`: `Text` gives no per-word tap target
/// or word frame. A read-only text view keeps copy/selection working, renders
/// continuous multi-word underline spans ("claude code") that wrap naturally, and
/// exposes `boundingRect(forGlyphRange:)` for the bubble anchor. Edit mode already
/// uses a UITextView (`InlineEditTextView`), so this is consistent, not exotic.
struct MarkedTranscriptText: UIViewRepresentable {
    struct Mark: Equatable {
        let key: String          // CorrectionProvenance.Record.key
        let range: NSRange       // span in `text`
        let applied: Bool        // solid blue underline; else dashed grey
    }

    let text: String
    let marks: [Mark]
    /// A just-edited span to flash a fading blue wash over (handoff §text-mutation
    /// feedback). Carries a nonce `token` so re-supplying the SAME range re-triggers
    /// the animation. Nil = nothing flashing.
    var flash: Flash?
    /// (record key, word rect in WINDOW coordinates) — for anchoring the bubble.
    var onTapMark: (String, CGRect) -> Void
    /// Selection-menu "Add to Vocabulary": called with the sanitized selected
    /// text and its NSRange in `text` (for the confirmation flash). nil hides
    /// the menu item entirely.
    var onAddToVocabulary: ((String, NSRange) -> Void)?

    struct Flash: Equatable {
        let range: NSRange
        let token: Int   // nonce so an identical range re-fires the wash
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true                 // keep copy/select working
        tv.isScrollEnabled = false             // size to content inside the SwiftUI ScrollView
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.textContainer.lineBreakMode = .byWordWrapping
        // Single-tap = adjudicate a mark. Long-press/double-tap still drive the
        // text view's own selection (different recognizers); don't swallow touches.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        // Delegate solely for the selection edit menu ("Add to Vocabulary").
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        tv.attributedText = Self.makeAttributed(text: text, marks: marks)
        context.coordinator.runFlashIfNeeded(flash, on: tv)
    }

    /// iOS 16+: lets SwiftUI size the non-scrolling text view to its content at
    /// the proposed width (so it lays out correctly inside the ScrollView).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // A non-scrolling UITextView has no good intrinsic HEIGHT, so never cede
        // sizing back to it (that collapses to one line). Always bind a width:
        // the proposed one, else the screen width less the body gutter.
        let width: CGFloat = {
            if let w = proposal.width, w > 0, w < .greatestFiniteMagnitude { return w }
            return max(1, UIScreen.main.bounds.width - 36)
        }()
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Attributed string

    /// `--dot-done`: white@50% (dark) / rgba(54,62,78,0.42) (light). Built
    /// directly to hit the handoff value exactly (no existing token lands at
    /// this alpha; jotPageInkSecondary sits at 0.62/0.72, too strong).
    static let keptUnderlineColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.50)
            : UIColor(red: 54 / 255, green: 62 / 255, blue: 78 / 255, alpha: 0.42)
    }

    static func makeAttributed(text: String, marks: [Mark]) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .regular),
            .foregroundColor: UIColor(Color.jotPageInk),
            .kern: -0.1,
            .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString(string: text, attributes: base)
        let len = (text as NSString).length
        for m in marks {
            guard m.range.location >= 0, m.range.location + m.range.length <= len, m.range.length > 0 else { continue }
            let style: NSUnderlineStyle = m.applied ? .single : [.single, .patternDash]
            s.addAttribute(.underlineStyle, value: style.rawValue, range: m.range)
            // Handoff marks: APPLIED → jotAccent @ 0.32 (`--jot-blue-border`);
            // KEPT → `--dot-done` (white@50% dark / rgba(54,62,78,0.42) light),
            // dashed. NOTE: NSUnderlineStyle renders at a 1px hairline — the
            // handoff's 1.5px weight is not expressible via underlineStyle, so
            // this is an accepted ~1px approximation.
            s.addAttribute(
                .underlineColor,
                value: m.applied
                    ? UIColor(Color.jotAccent).withAlphaComponent(0.32)
                    : keptUnderlineColor,
                range: m.range)
        }
        return s
    }

    // MARK: - Coordinator (taps)

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkedTranscriptText
        weak var textView: UITextView?
        /// Last flash token we animated, so a re-render with the same token
        /// doesn't re-fire (we only animate on a NEW token).
        private var lastFlashToken: Int?
        init(_ p: MarkedTranscriptText) { parent = p }

        /// Flash a fading blue wash over a just-edited word (handoff §text-mutation
        /// feedback: #1A8CFF @ ~20% fading over 1.5s, signature ease). Implemented
        /// as a transient subview over the glyph rect so it doesn't perturb the
        /// attributed text / layout.
        func runFlashIfNeeded(_ flash: Flash?, on tv: UITextView) {
            guard let flash else { return }
            guard flash.token != lastFlashToken else { return }
            lastFlashToken = flash.token
            let len = (tv.text as NSString).length
            guard flash.range.location >= 0,
                  flash.range.location + flash.range.length <= len,
                  flash.range.length > 0 else { return }
            // Defer one runloop so the new attributedText has laid out before we
            // measure the glyph rect of the edited span.
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                let lm = tv.layoutManager
                let glyphRange = lm.glyphRange(forCharacterRange: flash.range, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
                rect = rect.offsetBy(dx: tv.textContainerInset.left, dy: tv.textContainerInset.top)
                rect = rect.insetBy(dx: -3, dy: -1)   // ~3px spread like the CSS box-shadow
                let wash = UIView(frame: rect)
                wash.isUserInteractionEnabled = false
                wash.layer.cornerRadius = 4
                wash.backgroundColor = UIColor(Color.jotAccent).withAlphaComponent(0.20)
                tv.addSubview(wash)
                // signature ease cubic-bezier(0.45,0.02,0.2,1)
                let timing = CAMediaTimingFunction(controlPoints: 0.45, 0.02, 0.2, 1)
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1.0
                anim.toValue = 0.0
                anim.duration = 1.5
                anim.timingFunction = timing
                anim.isRemovedOnCompletion = true
                wash.layer.add(anim, forKey: "fade")
                CATransaction.begin()
                CATransaction.setCompletionBlock { wash.removeFromSuperview() }
                UIView.animate(withDuration: 1.5) { wash.alpha = 0 } completion: { _ in
                    wash.removeFromSuperview()
                }
                CATransaction.commit()
            }
        }

        // MARK: Selection edit menu — "Add to Vocabulary"

        /// Appends "Add to Vocabulary" to the system selection menu (Copy /
        /// Look Up / Translate) when the selection trims to a plausible term
        /// and isn't one already. The SELECTION and the RANGE handed to the
        /// callback are the SAME trimmed span — the confirm step compares
        /// substring(range) == selected before replacing, so handing it the
        /// sanitized string with the raw range would make the text fix
        /// silently no-op on any selection with edge punctuation (review R3
        /// finding 1).
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let onAdd = parent.onAddToVocabulary,
                  let (selected, trimmedRange) = Self.trimmedSelection(
                      in: textView.text as NSString, range: range),
                  Self.isPlausibleTerm(selected),
                  !VocabularyStore.shared.terms.contains(where: {
                      !$0.isBlank && $0.text.compare(selected, options: .caseInsensitive) == .orderedSame
                  })
            else { return UIMenu(children: suggestedActions) }
            let add = UIAction(
                title: "Add to Vocabulary",
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in
                onAdd(selected, trimmedRange)
            }
            return UIMenu(children: suggestedActions + [add])
        }

        /// The selection with edge whitespace + punctuation trimmed, as the
        /// EXACT (substring, range) pair — both sides of the later
        /// "is the text still what was selected" check come from here.
        static func trimmedSelection(in ns: NSString, range: NSRange) -> (String, NSRange)? {
            guard range.location >= 0, range.length > 0,
                  range.location + range.length <= ns.length else { return nil }
            let edge = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".,;:!?\"'()[]{}\u{2019}\u{201C}\u{201D}\u{2026}"))
            var start = range.location
            var end = range.location + range.length
            while start < end, let s = Unicode.Scalar(ns.character(at: start)), edge.contains(s) {
                start += 1
            }
            while end > start, let s = Unicode.Scalar(ns.character(at: end - 1)), edge.contains(s) {
                end -= 1
            }
            guard end > start else { return nil }
            let trimmed = NSRange(location: start, length: end - start)
            return (ns.substring(with: trimmed), trimmed)
        }

        /// A short word-run someone would plausibly teach as a term: 1–4
        /// words, ≤60 chars, contains letters, no newline (a sentence or a
        /// paragraph is not a term) — false hides the menu item.
        static func isPlausibleTerm(_ s: String) -> Bool {
            guard !s.contains("\n"), s.count <= 60,
                  s.rangeOfCharacter(from: .letters) != nil else { return false }
            let words = s.split(whereSeparator: { $0.isWhitespace })
            return !words.isEmpty && words.count <= 4
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = textView, !parent.marks.isEmpty else { return }
            let pt = g.location(in: tv)
            let lm = tv.layoutManager
            var frac: CGFloat = 0
            let idx = lm.characterIndex(
                for: pt, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: &frac)
            let len = (tv.text as NSString).length
            guard idx >= 0, idx < len else { return }
            for m in parent.marks where NSLocationInRange(idx, m.range) {
                let glyphRange = lm.glyphRange(forCharacterRange: m.range, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
                rect = rect.offsetBy(dx: tv.textContainerInset.left, dy: tv.textContainerInset.top)
                parent.onTapMark(m.key, tv.convert(rect, to: nil))   // window coords
                return
            }
        }
    }
}
