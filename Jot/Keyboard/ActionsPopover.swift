import SwiftUI
import UIKit

/// The keyboard's ••• Actions pane (features.md §5.6). Lives in the SHORT top region
/// (~130pt) in place of the recents strip (see `KeyboardView.actionsPanel`) — so it
/// must FIT without scrolling. A 4×2 tile grid that fills the pane:
///   Row 1 (feature, gradient icons): Add to Vocabulary · AI Rewrite · Translate · Close
///   Row 2 (utility, monochrome):     Copy · Paste · Undo · Redo
///
/// Undo/Redo carry a count badge (`undoDepth`/`redoDepth`) so the user can see how many
/// steps remain each way. AI Rewrite / Translate are GUIDES (no engine in the keyboard):
/// they teach the system Writing Tools / Translate, which iOS exposes in the selection
/// menu. The Writing Tools step shows Apple's own glyph rather than the words.
///
/// The init signature keeps Paste/Copy/Undo/Redo callbacks (no longer dormant) so the
/// controller wiring doesn't change.
struct ActionsPopover: View {
    let hasPasteboardContent: Bool
    let hasSelection: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoDepth: Int
    let redoDepth: Int

    let onPaste: () -> Void
    let onCopy: () -> Void
    let onAddToVocabulary: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Pane { case grid, aiRewrite, translate }
    @State private var pane: Pane = .grid

    // Icon-tile gradients (top-leading → bottom-trailing).
    private static let vocabColors = [Color(red: 0x1F/255, green: 0xCE/255, blue: 0xD1/255),
                                      Color(red: 0x19/255, green: 0xA9/255, blue: 0xAB/255)]
    private static let aiColors = [Color(red: 0xFF/255, green: 0x5E/255, blue: 0x9A/255),
                                   Color(red: 0xA3/255, green: 0x5B/255, blue: 0xFF/255),
                                   Color(red: 0x3B/255, green: 0x9B/255, blue: 0xFF/255)]
    private static let translateColors = [Color(red: 0x1A/255, green: 0x8C/255, blue: 0xFF/255),
                                          Color(red: 0x15/255, green: 0x73/255, blue: 0xD1/255)]

    /// Apple's Writing Tools / Apple Intelligence menu glyph. Falls back to `sparkles`
    /// on any device that lacks the symbol so it can never render blank.
    private static let writingToolsGlyph: String =
        UIImage(systemName: "apple.intelligence") != nil ? "apple.intelligence" : "sparkles"

    var body: some View {
        Group {
            switch pane {
            case .grid:       grid
            case .aiRewrite:  aiRewriteGuide
            case .translate:  translateGuide
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    // MARK: - Grid (4×2 tiles that FILL the pane)

    private var grid: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                // Washed tiles stay TAPPABLE: a tap on an unavailable action surfaces a
                // status banner ("Select a word first" …) from the controller instead of
                // doing nothing, and keeps the pane open so the user can satisfy the
                // precondition and retry. Only a SUCCESSFUL action dismisses the pane.
                denseTile("Vocab", "character.book.closed", colors: Self.vocabColors, enabled: hasSelection) {
                    if hasSelection { onAddToVocabulary(); onDismiss() } else { onAddToVocabulary() }
                }
                denseTile("Rewrite", "sparkles", colors: Self.aiColors, enabled: true) { pane = .aiRewrite }
                denseTile("Translate", "globe", colors: Self.translateColors, enabled: true) { pane = .translate }
                denseTile("Close", "xmark", colors: nil, enabled: true) { onDismiss() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                denseTile("Copy", "doc.on.doc", colors: nil, enabled: hasSelection) {
                    if hasSelection { onCopy(); onDismiss() } else { onCopy() }
                }
                // Paste is ALWAYS offered (never washed): the clipboard isn't polled live
                // (reading it fires iOS's paste-privacy toast), so we validate at tap time —
                // an empty clipboard shows "Nothing to paste yet" instead of pasting.
                denseTile("Paste", "doc.on.clipboard", colors: nil, enabled: true) { onPaste(); onDismiss() }
                // Undo / Redo stay open so repeated taps work; badge shows steps remaining.
                denseTile("Undo", "arrow.counterclockwise", colors: nil, enabled: canUndo, badge: undoDepth) { onUndo() }
                denseTile("Redo", "arrow.clockwise", colors: nil, enabled: canRedo, badge: redoDepth) { onRedo() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    /// One compact grid tile. `colors != nil` → a gradient icon square (feature
    /// actions); `colors == nil` → a monochrome glyph (utility actions). `badge > 0`
    /// draws a count chip on the icon (Undo/Redo stack depth).
    ///
    /// `enabled` controls the VISUAL state only (washed when false) — the tile is
    /// always tappable so an unavailable tap can explain itself via a status banner.
    /// The caller's `action` closure decides what an unavailable tap does.
    private func denseTile(
        _ title: String,
        _ systemImage: String,
        colors: [Color]?,
        enabled: Bool,
        badge: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    // Every icon shares the same 32pt rounded footprint so glyph-over-label
                    // is identical across all tiles — gradient square for features, a subtle
                    // neutral square for utilities.
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        // Enabled = full ink (readable); disabled = the muted "washed" tone (still
                        // visible, just clearly off); white-on-gradient stays full.
                        .foregroundStyle(colors != nil ? Color.white : (enabled ? Color.jotInk : Color.jotMute))
                        .frame(width: 32, height: 32)
                        .background(iconBackground(colors: colors, enabled: enabled))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 15)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.jotAccent))
                            .offset(x: 7, y: -5)
                    }
                }
                Text(title)
                    // Medium weight (not semibold) so it's softer than before — but FULL ink when
                    // enabled (not washed). The muted "washed" tone is reserved for disabled tiles.
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(enabled ? Color.jotInk : Color.jotMute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .background(glassCard(cornerRadius: 13))
            .opacity(enabled ? 1 : 0.85)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        // Intentionally NOT `.disabled(!enabled)`: a washed tile must still accept a
        // tap so it can surface a "why" banner. `enabled` only drives the visuals.
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) available" : title)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Guides (compact — fit the pane, no scroll)

    private var aiRewriteGuide: some View {
        guideScaffold(
            title: "Rewrite with Apple Intelligence",
            steps: [
                Text("**Select** your text"),
                Text("Tap ")
                    + Text(Image(systemName: Self.writingToolsGlyph)).foregroundColor(Color.jotAccent)
                    + Text(" in the menu"),
                Text("Pick **Rewrite**, **Concise**, or **Proofread**"),
            ]
        )
    }

    private var translateGuide: some View {
        guideScaffold(
            title: "Translate, built into iPhone",
            steps: [
                Text("**Select** your text"),
                // Translate isn't on the first menu page — it's behind the menu's
                // "more" arrow. Show the arrow glyph (not the word) and the real flow.
                Text("Tap ")
                    + Text(Image(systemName: "chevron.right")).foregroundColor(Color.jotAccent)
                    + Text(", then **Translate**"),
                Text("Pick a language to replace it"),
            ]
        )
    }

    private func guideScaffold(title: String, steps: [Text]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button { pane = .grid } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.jotInk)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.jotKeyboardKeyFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to actions")
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 1)

            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .center, spacing: 9) {
                    Text("\(idx + 1)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(Color.jotAccent))
                    step
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassCard(cornerRadius: 18))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
    }

    /// Rounded icon footprint shared by every tile: a colored gradient for feature
    /// actions, a subtle neutral fill for utility actions — so all icons read at the
    /// same size and centering above their label.
    @ViewBuilder
    private func iconBackground(colors: [Color]?, enabled: Bool) -> some View {
        if let colors {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: enabled ? colors : [Color.jotMute, Color.jotMute],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.jotKeyboardKeyFill)
        }
    }

    // MARK: - Liquid Glass surface (same recipe as recents / vocab cards)

    private func glassCard(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.jotKeyboardGlassFill1, Color.jotKeyboardGlassFill2],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            // Glassy top-edge sheen (same as the vocab/recents cards).
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            // Hairline border so each tile reads as glass and separates from the chrome.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 5, x: 0, y: 3)
    }
}
