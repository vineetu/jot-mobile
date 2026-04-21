import SwiftUI
import UIKit

/// The "balloon" that pops above a key cap when the user presses it. Matches
/// iOS's native input callout: a rounded rectangle wider than the key,
/// tapering through a short curve to meet the key's top edge, with the
/// pressed character displayed in a large light-weight font.
///
/// ## Geometry
///
/// All values come from `docs/research/ios-keyboard-1to1.md` §3.1, which
/// extracted them from KeyboardKit's `Callouts+CalloutStyle.swift`:
///
/// - Bubble body: **55 pt** tall, **keyWidth + 26 pt** wide
/// - Corner radius: **10 pt**
/// - Stem: **8 pt** wide × **15 pt** tall on each side (the curved transition
///   between the wide bubble body and the narrow key cap it sits on)
/// - Font: **.largeTitle, .light** (~34 pt, SF Pro)
/// - Shadow: **`black.opacity(0.1)`**, radius **5 pt**
///
/// ## When shown
///
/// Suppressed for action keys (shift, delete, return, space, plane-toggle,
/// globe, history) — they have no callout on iOS native either. Suppressed
/// in landscape — iOS collapses the bubble to keycap size on landscape
/// iPhone to stay inside keyboard bounds. Suppressed while a long-press
/// action callout is open.
///
/// The callout appears on press-down and fades on release with a short
/// delay so the user has time to visually confirm the character. We use
/// SwiftUI's `.transition(.opacity.animation(.easeOut(duration: 0.08)))`
/// approximation of KeyboardKit's spring-based appearance.
///
/// ## Positioning
///
/// The caller is responsible for anchoring the bubble above the key — we
/// render at the origin of the wrapper view and let the parent (`KeyboardKey`)
/// `.offset(y: -calloutHeight)` it into place. iPhone vertical offset is
/// 0 pt (iPad adds 20 pt; out of scope for Jot MVP).
struct KeyPreviewBubble: View {
    /// The character to display in the bubble. For letters, this is the
    /// case-resolved glyph (uppercase if shift is active).
    let character: String

    /// The width of the underlying key cap. The bubble computes its own
    /// width as `keyWidth + 26 pt`.
    let keyWidth: CGFloat

    /// The height of the underlying key cap. Drives how far the bubble sits
    /// above the key (it overlaps the key's top by the stem height so the
    /// shape reads as a single "balloon-out-of-the-key").
    let keyHeight: CGFloat

    // MARK: - Constants (from research §3.1)

    private let bubbleBodyHeight: CGFloat = 55
    private let stemHeight: CGFloat = 15
    private let cornerRadius: CGFloat = 10
    private let widthOvershoot: CGFloat = 26  // total = keyWidth + 26

    private var bubbleWidth: CGFloat { keyWidth + widthOvershoot }
    private var totalHeight: CGFloat { bubbleBodyHeight + stemHeight }
    /// Horizontal distance from the bubble's outer edge to the key's outer
    /// edge at the stem base. Equals `(bubbleWidth - keyWidth) / 2 = 13`.
    private var stemOffset: CGFloat { (bubbleWidth - keyWidth) / 2 }

    var body: some View {
        BalloonShape(
            keyWidth: keyWidth,
            bubbleBodyHeight: bubbleBodyHeight,
            stemHeight: stemHeight,
            cornerRadius: cornerRadius
        )
        .fill(Color(uiColor: .keyboardButtonBackground))
        .overlay(
            BalloonShape(
                keyWidth: keyWidth,
                bubbleBodyHeight: bubbleBodyHeight,
                stemHeight: stemHeight,
                cornerRadius: cornerRadius
            )
            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(
            // Character centered in the bubble body (not across the full
            // bubble-plus-stem rect — iOS centers inside the body only).
            Text(character)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.primary)
                .frame(width: bubbleWidth, height: bubbleBodyHeight)
                .offset(y: -stemHeight / 2)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 1)
        .frame(width: bubbleWidth, height: totalHeight)
        .allowsHitTesting(false)
    }
}

// MARK: - Balloon shape

/// The balloon outline — a rounded rectangle wider than the key cap, tapered
/// by a short quadratic curve to meet the key cap's top edge. Drawn in
/// local coordinates where (0, 0) is the top-left of the bubble body and
/// (keyWidth + stemOffset*2, bubbleBodyHeight + stemHeight) is the
/// bottom-right at the key cap's top.
private struct BalloonShape: Shape {
    let keyWidth: CGFloat
    let bubbleBodyHeight: CGFloat
    let stemHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let bubbleBottom = bubbleBodyHeight
        let stemBottom = bubbleBodyHeight + stemHeight
        let stemOffset = (w - keyWidth) / 2

        var path = Path()

        // Top-left rounded corner — start at the point where the top edge
        // begins (just right of the corner arc).
        path.move(to: CGPoint(x: cornerRadius, y: 0))

        // Top edge
        path.addLine(to: CGPoint(x: w - cornerRadius, y: 0))

        // Top-right corner
        path.addArc(
            center: CGPoint(x: w - cornerRadius, y: cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Right edge of bubble body down to the stem transition
        path.addLine(to: CGPoint(x: w, y: bubbleBottom))

        // Right stem curve — taper inward to the key's top-right corner.
        // Control point at (w, stemBottom) gives a convex flare that
        // matches KeyboardKit's CustomRoundedRectangle outline.
        path.addQuadCurve(
            to: CGPoint(x: w - stemOffset, y: stemBottom),
            control: CGPoint(x: w, y: stemBottom)
        )

        // Bottom edge — across the top of the key cap.
        path.addLine(to: CGPoint(x: stemOffset, y: stemBottom))

        // Left stem curve — taper outward back up to the bubble body.
        path.addQuadCurve(
            to: CGPoint(x: 0, y: bubbleBottom),
            control: CGPoint(x: 0, y: stemBottom)
        )

        // Left edge of bubble body up to the top-left corner
        path.addLine(to: CGPoint(x: 0, y: cornerRadius))

        // Top-left corner
        path.addArc(
            center: CGPoint(x: cornerRadius, y: cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Color palette

extension UIColor {
    /// The keyboard plane behind the keys. On native iOS in light mode this
    /// reads as a near-white sheet with only a subtle contrast against the
    /// alpha keys, which is why the letters feel like they're sitting on a
    /// single surface instead of floating over a gray slab. Dark mode keeps
    /// the plane darker than the alpha keys so their elevation still reads.
    static let keyboardPlaneBackground: UIColor = {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 54/255, green: 54/255, blue: 58/255, alpha: 1)
                : UIColor(red: 248/255, green: 249/255, blue: 252/255, alpha: 1)
        }
    }()

    /// The light-mode "keyboard button" background — the idle color for
    /// alpha keys, and the fill color for the preview bubble on both
    /// appearances (the bubble inverts with the system appearance).
    /// Values match KeyboardKit's `keyboardButtonBackground.colorset` from
    /// research §1 summary table.
    static let keyboardButtonBackground: UIColor = {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 107/255, green: 107/255, blue: 107/255, alpha: 1)
                : UIColor.white
        }
    }()

    /// The action-key background — shift / delete / return (non-accent) /
    /// plane toggle / history / globe. Idle color; pressed flips to
    /// `.keyboardButtonBackground` in light mode and to the dark-mode
    /// alpha color in dark mode. Values match KeyboardKit's
    /// `keyboardDarkButtonBackground.colorset`.
    static let keyboardDarkButtonBackground: UIColor = {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 71/255, green: 71/255, blue: 71/255, alpha: 1)
                : UIColor(red: 171/255, green: 177/255, blue: 186/255, alpha: 1)
        }
    }()
}
