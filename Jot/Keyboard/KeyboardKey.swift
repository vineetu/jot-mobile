import SwiftUI
import UIKit

/// A single rendered key on the keyboard. Receives a descriptor + the width it
/// should occupy, and emits the tap event via `onTap`. Press-in visual
/// highlight is handled here; the controller is responsible for behavior on
/// release (insertion, delete, etc).
///
/// ## Why not `Button(action:)`
///
/// SwiftUI's `Button` waits for the touch-up-inside gesture before firing, and
/// the built-in pressed highlight is tuned for hero actions, not the tight,
/// snappy feedback an iOS keyboard wants. A minimal `DragGesture(minimumDistance:
/// 0)` driven by local pressed state gives us Apple's "highlight on finger-
/// down, fire on finger-up inside bounds" behavior with zero configuration.
///
/// ## Visual + haptic + audio feedback
///
/// On the press-down transition, we fire three things in quick succession:
///
/// 1. **Visual** — the key cap background flips to its pressed color
///    (no scale animation; iOS native uses color-only feedback). Alpha keys
///    pick up the action-key color; action keys pick up the alpha-key
///    color. The swap direction inverts with light/dark appearance, which
///    is why we read from `UIColor.keyboardButtonBackground` /
///    `.keyboardDarkButtonBackground` rather than hardcoding.
/// 2. **Haptic** — `UISelectionFeedbackGenerator.selectionChanged()`. Same
///    generator for every key class. Research §4.2 explains why this beats
///    `UIImpactFeedbackGenerator(.light)` for rapid typing.
/// 3. **Audio** — dispatches by key class. Input keys (letters, digits,
///    punctuation, space) fire `UIDevice.playInputClick()` which plays
    ///    SystemSoundID 1104 when the system keyboard-sound toggle is on.
    ///    Delete fires 1155; return fires 1156. See ``KeyboardFeedback`` for
    ///    the dispatch table.
///
/// ## Preview bubble ("key pop-up")
///
    /// Character keys (``KeyboardKeyDescriptor/literal``) show a balloon above
    /// the key on press, displaying the same glyph in a much larger light-weight
    /// font. Suppressed for action keys and space — those have no callout on
    /// iOS native either. Also suppressed in landscape (compact vertical size
    /// class) to stay inside the keyboard bounds.
///
/// The bubble is wider than the key cap (keyWidth + 26 pt) and extends
/// ~70 pt above the key top. We render it via `.overlay(alignment: .top)`
/// with a negative Y offset; SwiftUI doesn't clip overlays to the parent
/// frame by default, so the bubble renders cleanly into the row above.
struct KeyboardKey: View {
    let descriptor: KeyboardKeyDescriptor
    let width: CGFloat
    let height: CGFloat
    /// Corner radius pulled from ``KeyboardMetrics`` — 5 pt pre-iOS-26, 9 pt
    /// under Liquid Glass. Passing it down (vs each key deriving its own)
    /// keeps the look consistent even if a key is previewed with a
    /// non-default metrics struct.
    let cornerRadius: CGFloat
    /// Shared haptic + audio owner — see ``KeyboardFeedback``. Single
    /// instance per controller so the Taptic Engine stays warm.
    let feedback: KeyboardFeedback
    let onTap: (KeyboardKeyDescriptor) -> Void
    /// Called on finger-down (`true`) and finger-up / drag-off (`false`) for
    /// every key. The controller inspects the descriptor and ignores the
    /// event for keys that don't need press-state (only backspace uses it to
    /// drive hold-to-delete auto-repeat).
    let onPressChanged: (KeyboardKeyDescriptor, Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isPressed = false

    var body: some View {
        keycap
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(pressGesture)
            .overlay(alignment: .top) { previewBubble }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(descriptor.accessibilityLabel())
            .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - Keycap visual

    @ViewBuilder
    private var keycap: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
                .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.28),
                        radius: 0, x: 0, y: 1)

            content
                .foregroundStyle(foreground)
                .font(font)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        // No scale animation on press — iOS native keyboard uses a pure
        // color swap (research §6.4). Removing the scaleEffect is one of
        // the four fixes for the user's "doesn't feel like pressing"
        // complaint.
    }

    @ViewBuilder
    private var content: some View {
        if let symbol = descriptor.symbolName() {
            Image(systemName: symbol)
                .imageScale(.medium)
        } else if let label = descriptor.label() {
            Text(label)
                .kerning(0)
        }
    }

    /// Apple's keycap font. Size tuned to match the native keyboard at standard
    /// iPhone widths.
    private var font: Font {
        switch descriptor {
        case .literal:
            return .system(size: 22, weight: .regular, design: .default)
        case .space:
            return .system(size: 14, weight: .regular, design: .default)
        case .returnKey, .backspace:
            return .system(size: 18, weight: .regular, design: .default)
        }
    }

    // MARK: - Background / foreground tokens

    private var background: Color {
        if isPressed { return pressedBackground }

        switch descriptor.style {
        case .primary:
            // Alpha, digits, punctuation, space — the lighter of the two
            // key tones, sits against the darker keyboard base. The
            // `keyboardButtonBackground` asset auto-adapts: `#FFFFFF` in
            // light, `#6B6B6B` in dark. Research §1 summary table.
            return Color(uiColor: .keyboardButtonBackground)
        case .action:
            // Shift, delete, plane toggle, history — the darker tone.
            // `keyboardDarkButtonBackground` → `#ABB1BA` light / `#474747`
            // dark.
            return Color(uiColor: .keyboardDarkButtonBackground)
        case .returnAccent:
            // Return key accent. iOS uses `.systemBlue` for primary-action
            // return types (Go / Search / Send). We use a similar accent
            // that's readable in both appearances.
            return Color.accentColor.opacity(scheme == .dark ? 0.75 : 0.92)
        }
    }

    /// Pressed feedback. Research §6.1: iOS inverts — alpha keys flip to
    /// the action-key color (and vice versa). The swap direction itself
    /// inverts with light/dark appearance, which is why we read the
    /// appearance-aware `UIColor` tokens rather than hardcoding hex.
    private var pressedBackground: Color {
        switch descriptor.style {
        case .primary:
            return Color(uiColor: .keyboardDarkButtonBackground)
        case .action:
            return Color(uiColor: .keyboardButtonBackground)
        case .returnAccent:
            return Color.accentColor.opacity(scheme == .dark ? 0.55 : 0.75)
        }
    }

    private var foreground: Color {
        switch descriptor.style {
        case .primary, .action:
            return Color(uiColor: .label)
        case .returnAccent:
            return .white
        }
    }

    // MARK: - Preview bubble overlay

    /// Whether to render a preview bubble for this key on press. True for
    /// character keys in portrait; false for action keys and always in
    /// landscape (per research §3.2).
    private var showsPreviewBubble: Bool {
        guard isPressed else { return false }
        // Compact vertical size class = landscape. Skip on landscape to
        // match iOS native.
        if verticalSizeClass == .compact { return false }
        switch descriptor {
        case .literal:
            return true
        case .space, .returnKey, .backspace:
            return false
        }
    }

    /// The glyph the bubble should display. Only resolvable for character
    /// keys; `nil` otherwise.
    private var previewCharacter: String? {
        switch descriptor {
        case .literal(let text):
            return text
        case .space, .returnKey, .backspace:
            return nil
        }
    }

    @ViewBuilder
    private var previewBubble: some View {
        if showsPreviewBubble, let character = previewCharacter {
            KeyPreviewBubble(
                character: character,
                keyWidth: width,
                keyHeight: height
            )
            // Anchor: `.overlay(alignment: .top)` pins the overlay's top
            // edge at the key's top edge. The bubble's total height is
            // bubbleBody(55) + stem(15) = 70; we shift it up by
            // `bubbleBody` (55) so the stem overlaps ~15 pt into the key
            // top, producing the seamless "balloon inflates out of the
            // key" illusion from research §6.3.
            .offset(y: -55)
            .transition(.opacity.animation(.easeOut(duration: 0.08)))
            .zIndex(999)
        }
    }

    // MARK: - Press tracking

    /// `DragGesture(minimumDistance: 0)` = press + release with drag-cancel
    /// support for free. A release that drifts outside the key bounds is
    /// ignored — matches Apple's "drag off the key to abort" behavior.
    ///
    /// Haptic + audio fire on the finger-down transition (false → true).
    /// They do NOT fire again on finger-up or on drag-cancel; research §4.2
    /// says iOS native uses `.selectionChanged` on both press and release,
    /// but in practice the press fire is what the user reads as "I pressed
    /// the key" — double-firing felt busy in device testing.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let wasPressed = isPressed
                let inside = bounds(containing: value.location)
                if !wasPressed && inside {
                    isPressed = true
                    feedback.firePress(for: descriptor)
                    onPressChanged(descriptor, true)
                } else if wasPressed && !inside {
                    isPressed = false
                    onPressChanged(descriptor, false)
                }
            }
            .onEnded { value in
                let wasPressed = isPressed
                isPressed = false
                onPressChanged(descriptor, false)
                if wasPressed && bounds(containing: value.location) {
                    onTap(descriptor)
                }
            }
    }

    /// Re-derives whether a point is still over this key, expressed in the
    /// gesture's local coordinate space.
    private func bounds(containing point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height
    }
}
