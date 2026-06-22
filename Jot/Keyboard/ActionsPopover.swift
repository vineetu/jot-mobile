import SwiftUI

/// 220pt-wide glass-heavy popover anchored above the bottom-right
/// Actions button (Mockup 06 / plan §4.5).
///
/// Rows (in order):
///   - Paste                — `insertText(UIPasteboard.general.string)`
///   - Copy                 — copies the host app's currently-selected
///                            text to the system clipboard via
///                            `UITextDocumentProxy.selectedText`. The
///                            caller composes the enabled flag from
///                            `hasFullAccess && hasSelection` and passes
///                            it as `hasSelection`.
///   - Undo last insertion  — controller's undo ledger
///   - Redo last insertion  — controller's redo ledger
///   - Move up              — shifts the cursor backward by approximately
///                            one host-visible window (~256-1000 chars,
///                            host-dependent). Multiple taps accumulate.
///                            Does NOT require Full Access. The internal
///                            implementation attempts to reach the start
///                            via a bounded loop but most hosts buffer
///                            the caret-update and short-circuit after
///                            one window; this is the honest copy.
///   - Move down            — shifts the cursor forward by approximately
///                            one host-visible window. Same caveat as
///                            Move up. Does NOT require Full Access.
///
/// NO "Clear field" row (plan §13 risk 9 — unreliable in keyboard
/// extensions).
///
/// Position + animation are hand-rolled (no `UIPopoverPresentationController`
/// — that doesn't play nicely in keyboard extensions). The popover is
/// rendered as a SwiftUI overlay at the bottom-right of the keyboard
/// surface with a `.scale + .opacity` transition.
struct ActionsPopover: View {
    let hasPasteboardContent: Bool
    let hasSelection: Bool
    let canUndo: Bool
    let canRedo: Bool

    let onPaste: () -> Void
    let onCopy: () -> Void
    let onAddToVocabulary: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 220pt fixed width per Mockup 06.
    private static let popoverWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            row(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                enabled: hasPasteboardContent,
                action: handle(onPaste)
            )
            divider
            row(
                title: "Copy",
                systemImage: "doc.on.doc",
                enabled: hasSelection,
                action: handle(onCopy)
            )
            divider
            row(
                title: "Add to Vocabulary",
                systemImage: "character.book.closed",
                enabled: hasSelection,
                action: handle(onAddToVocabulary)
            )
            divider
            row(
                title: "Undo last insertion",
                systemImage: "arrow.uturn.backward",
                enabled: canUndo,
                action: handle(onUndo)
            )
            divider
            row(
                title: "Redo last insertion",
                systemImage: "arrow.uturn.forward",
                enabled: canRedo,
                action: handle(onRedo)
            )
            // Move up / Move down removed for now (user request) — the
            // `onJumpToStart` / `onJumpToEnd` plumbing is kept dormant so the two
            // rows can be re-added later without re-wiring the controller.
        }
        .frame(width: Self.popoverWidth)
        .modifier(JotDesign.Surface.heavy.modifier(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions menu")
    }

    // MARK: - Row

    private func row(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(enabled ? Color.jotInk : Color.jotMuteWeak)
                    .frame(width: 22, alignment: .center)

                Text(title)
                    .font(JotType.bodyChrome)
                    .foregroundStyle(enabled ? Color.jotInk : Color.jotMuteWeak)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            // Compact rows so the 4-row popover fits the top region of the
            // 200pt keyboard ABOVE the control row (see KeyboardView — the
            // popover replaces the recents strip and never overlays the
            // dictate/controls row).
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? "Performs \(title.lowercased())" : "\(title) is unavailable")
        .accessibilityAddTraits(.isButton)
    }

    /// Wraps an action with auto-dismiss so the popover closes immediately
    /// after a tap (matches Mockup 06's transient menu behavior).
    private func handle(_ action: @escaping () -> Void) -> () -> Void {
        return {
            action()
            onDismiss()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.jotMuteWeak.opacity(0.35))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}
