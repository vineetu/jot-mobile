import SwiftUI

/// The thin accessory row above the QWERTY grid. Hosts the Jot-specific
/// paste-fresh-dictation affordance in the visual real-estate Apple's
/// native keyboard reserves for the QuickType candidate bar. Matching that
/// height (~40pt) keeps the keyboard visually cohesive with the system
/// keyboard when we do show it.
///
/// History access moved to the bottom row (see
/// ``KeyboardKeyDescriptor/historyKey``) after device testing — the
/// accessory-bar placement buried the most-used Jot-specific action under
/// the thumb-unreachable top of a portrait phone. Keeping history on the
/// bottom row makes one-handed use work.
///
/// Two presentations:
///
/// - **Fresh dictation available** (`preview != nil`, Full Access granted):
///   a single full-width paste pill.
/// - **No Full Access**: a single setup hint button that deep-links into
///   Settings. Paste + history are both unreachable without App Group /
///   pasteboard access.
///
/// The caller (`KeyboardView`) hides this view entirely in the "Full Access
/// granted, no fresh preview" case — there's no reason to leave a blank
/// 40pt band over the keyboard when we have nothing to surface.
struct KeyboardAccessoryBar: View {
    let preview: String?
    let hasFullAccess: Bool
    let onPaste: () -> Void
    let onOpenFullAccess: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if !hasFullAccess {
            fullAccessHint
        } else if let preview {
            pastePill(preview: preview)
        } else {
            // Nothing to surface. The caller also short-circuits before
            // rendering this view in this branch, but we keep the path
            // well-defined so a stale callsite degrades to an empty strip
            // rather than a crash.
            Spacer(minLength: 0)
        }
    }

    // MARK: - Paste pill

    private func pastePill(preview: String) -> some View {
        Button(action: onPaste) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.footnote.weight(.semibold))
                Text(preview)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("Paste")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pastePillBackground, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paste dictation")
        .accessibilityValue(preview)
        .accessibilityHint("Inserts text you just dictated in the Jot app")
        .accessibilityAddTraits(.isButton)
    }

    /// Gradient on the paste pill. Reduce Motion flattens to a solid accent
    /// so the gradient sweep doesn't register as subtle motion.
    private var pastePillBackground: AnyShapeStyle {
        reduceMotion
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(Color.accentColor.gradient)
    }

    // MARK: - Full Access hint

    private var fullAccessHint: some View {
        Button(action: onOpenFullAccess) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Enable Full Access")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .foregroundStyle(Color(uiColor: .label))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // No background — banner floats on the plane. The breadcrumb
            // ("Settings → General → Keyboard → …") was previously rendered
            // as a secondary line but wrapped to 3 cramped lines on-device
            // (user complaint 2026-04-21 "access is sooo clobbered"). Users
            // who can't figure out where to go will see instructional copy
            // in the main app's Settings screen after tapping.
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enable Full Access for Jot")
        .accessibilityHint("Opens the Jot settings page where you can tap Enable Full Access")
        .accessibilityAddTraits(.isButton)
    }
}
