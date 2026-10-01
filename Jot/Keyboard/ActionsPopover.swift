import SwiftUI
import UIKit

/// The keyboard's ••• Actions pane (features.md §5.6). Lives in the SHORT top region
/// (~130pt) in place of the recents strip (see `KeyboardView.actionsPanel`) — so it
/// must FIT without scrolling. A 4×2 tile grid that fills the pane:
///   Row 1 (feature, gradient icons): Vocab · Rewrite · Translate · Cleanup (toggle)
///   Row 2 (utility, monochrome):     Copy · Paste · Undo · Redo
///
/// Undo/Redo carry a count badge (`undoDepth`/`redoDepth`) so the user can see how many
/// steps remain each way. Rewrite and Translate ACT on the host's selection right here
/// (§7.15 / §7.16 — on-device model / on-device translation, replaced in place, undoable);
/// there are no "how to use the system menu" guides any more. Translate opens a
/// language-chip sub-pane (`translateChooser`) before it runs.
struct ActionsPopover: View {
    let hasPasteboardContent: Bool
    let hasSelection: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoDepth: Int
    let redoDepth: Int
    /// Automatic cleanup (features.md §7.14): current state for the Cleanup
    /// toggle tile, and whether the app last saw Apple Intelligence able to
    /// run it (a washed tile that explains itself on tap when not).
    let cleanupEnabled: Bool
    let cleanupAvailable: Bool
    /// §7.15 — Apple's on-device model can rewrite the host selection right
    /// here. When false the Rewrite tile is washed and its tap explains why
    /// (the controller's banner) instead of running.
    let rewriteAvailable: Bool
    let rewriteInFlight: Bool
    /// §7.16 — the Translate pane's target languages for the current selection
    /// (empty while the installed-pack check runs) and its in-flight guard.
    let translateOptions: [KeyboardTranslateOption]
    let translateInFlight: Bool

    let onPaste: () -> Void
    let onCopy: () -> Void
    let onAddToVocabulary: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onToggleCleanup: () -> Void
    let onRewriteSelection: () -> Void
    /// Returns false (after explaining via banner) when there is nothing to
    /// translate; true starts the language check and opens the pane.
    let onTranslateOpen: () -> Bool
    let onTranslateSelection: (String) -> Void
    /// The keyboard's current status (§5.10). The pane never adds a row for it
    /// — its tiles fill a fixed height, so any extra row cropped the bottom
    /// row. A short "why not" answer to a tile tap ("Select text") shows ON
    /// that tile for a moment; anything longer closes the pane so the Recents
    /// card reports it. Statuses not caused by a tap here are left for Recents.
    var status: KeyboardStatus? = nil
    var onDismissStatus: () -> Void = {}
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Pane { case grid, translate }
    @State private var pane: Pane = .grid
    /// The last tile / chip tapped, so a status that lands right after can be
    /// attributed to it.
    @State private var lastTap: (tile: String, at: Date)?
    /// A short reason shown in place of a tile's label ("Select text").
    @State private var tileHint: (tile: String, message: String)?
    @State private var hintShakes = 0
    @State private var hintClearTask: Task<Void, Never>?

    /// Longest message that fits a tile's label slot; longer ones go to Recents.
    private static let tileHintMaxLength = 16

    // Icon-tile gradients (top-leading → bottom-trailing).
    private static let vocabColors = [Color(red: 0x1F/255, green: 0xCE/255, blue: 0xD1/255),
                                      Color(red: 0x19/255, green: 0xA9/255, blue: 0xAB/255)]
    private static let aiColors = [Color(red: 0xFF/255, green: 0x5E/255, blue: 0x9A/255),
                                   Color(red: 0xA3/255, green: 0x5B/255, blue: 0xFF/255),
                                   Color(red: 0x3B/255, green: 0x9B/255, blue: 0xFF/255)]
    private static let translateColors = [Color(red: 0x1A/255, green: 0x8C/255, blue: 0xFF/255),
                                          Color(red: 0x15/255, green: 0x73/255, blue: 0xD1/255)]
    /// Same purple as the app's AI cleanup tile (Settings → AI), so the toggle
    /// here and the card there read as one feature.
    private static let cleanupColors = [Color(red: 0x7C/255, green: 0x5C/255, blue: 0xFF/255),
                                        Color(red: 0x66/255, green: 0x4B/255, blue: 0xD1/255)]

    var body: some View {
        Group {
            switch pane {
            case .grid:      grid
            case .translate: translateChooser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
        .onChange(of: status) { _, newStatus in handleStatus(newStatus) }
        .onDisappear { hintClearTask?.cancel() }
    }

    /// Route a status that follows a tap in this pane (see `status`).
    private func handleStatus(_ status: KeyboardStatus?) {
        guard let status, status.severity != .progress,
              let lastTap, Date().timeIntervalSince(lastTap.at) < 1 else { return }
        self.lastTap = nil
        guard pane == .grid, status.message.count <= Self.tileHintMaxLength else {
            onDismiss() // the Recents card reports it
            return
        }
        tileHint = (lastTap.tile, status.message)
        if !reduceMotion {
            withAnimation(.linear(duration: 0.3)) { hintShakes += 1 }
        }
        onDismissStatus()
        UIAccessibility.post(notification: .announcement, argument: status.message)
        hintClearTask?.cancel()
        hintClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { tileHint = nil }
        }
    }

    private func hint(for tile: String) -> String? {
        tileHint?.tile == tile ? tileHint?.message : nil
    }

    // MARK: - Grid (4×2 tiles that FILL the pane)

    /// Row 1 = features (gradient icons): Vocab · Rewrite · Translate · Cleanup
    /// (the one TOGGLE — Automatic cleanup on/off, §7.14). Row 2 = editing
    /// utilities (monochrome): Copy · Paste · Undo · Redo. There is no Close
    /// tile (owner call, 2026-09-15): the ••• control that opened the pane
    /// turns into an × while it is open and closes it.
    private var grid: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                // Washed tiles stay TAPPABLE: a tap on an unavailable action surfaces a
                // short answer ("Select a word" …) from the controller, shown on the tile itself, instead of
                // doing nothing, and keeps the pane open so the user can satisfy the
                // precondition and retry. Only a SUCCESSFUL action dismisses the pane.
                denseTile("Vocab", "character.book.closed", colors: Self.vocabColors, enabled: hasSelection) {
                    if hasSelection { onAddToVocabulary(); onDismiss() } else { onAddToVocabulary() }
                }
                // Rewrite ACTS: it rewrites the host's selection in place with the
                // user's Cleanup prompt on the on-device model (§7.15). A start
                // closes the pane — the status banner carries "Rewriting…" →
                // "Rewritten". Washed (no selection / model off / already
                // running) it stays open and the controller's banner says why.
                let rewriteEnabled = rewriteAvailable && hasSelection && !rewriteInFlight
                denseTile("Rewrite", "sparkles", colors: Self.aiColors, enabled: rewriteEnabled) {
                    onRewriteSelection()
                    if rewriteEnabled { onDismiss() }
                }
                // Translate runs for real (§7.16): with a selection the tile opens
                // the language chooser; a chip then translates the selection in
                // place. No selection: the washed tile's tap explains via banner.
                denseTile("Translate", "globe", colors: Self.translateColors,
                          enabled: hasSelection && !translateInFlight) {
                    if onTranslateOpen() { pane = .translate }
                }
                // The toggle stays open on tap so the state flip is seen in place; the
                // controller's banner confirms it ("AI cleanup on — …").
                cleanupToggleTile
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                denseTile("Copy", "doc.on.doc", colors: nil, enabled: hasSelection) {
                    if hasSelection { onCopy(); onDismiss() } else { onCopy() }
                }
                // Paste is ALWAYS offered (never washed): the clipboard isn't polled live
                // (reading it fires iOS's paste-privacy toast), so we validate at tap time —
                // an empty clipboard answers "Clipboard empty" instead of pasting.
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
        let hint = hint(for: title)
        return Button {
            lastTap = (title, Date())
            action()
        } label: {
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
                // The label slot doubles as the answer to a washed tap: "Select
                // text" replaces "Copy" for a moment, in the warning ink, while the
                // tile gives a small shake — feedback where the finger is, with no
                // layout change.
                Text(hint ?? title)
                    // Medium weight (not semibold) so it's softer than before — but FULL ink when
                    // enabled (not washed). The muted "washed" tone is reserved for disabled tiles.
                    .font(.system(size: 10.5, weight: hint == nil ? .medium : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(hint != nil ? Color.jotWarningInk : (enabled ? Color.jotInk : Color.jotMute))
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(glassCard(cornerRadius: 13))
            .opacity(enabled ? 1 : 0.85)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .modifier(TileShake(animatableData: hint != nil ? CGFloat(hintShakes) : 0))
        }
        .buttonStyle(.plain)
        // Intentionally NOT `.disabled(!enabled)`: a washed tile must still accept a
        // tap so it can surface a "why" banner. `enabled` only drives the visuals.
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) available" : title)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Translate pane (compact — fits the pane, no scroll)

    /// The Translate pane (§7.16): a row of language chips, the same list and
    /// look as the app's Translate sheet (§3.9), sized for the keyboard. The
    /// last-used language leads; languages whose pack is on the phone are
    /// bright, the rest are washed with a download glyph (their tap explains
    /// that the download happens in Jot). A bright chip translates the
    /// selection in place and closes the pane.
    private var translateChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text("Translate to")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if translateInFlight {
                    ProgressView().controlSize(.small)
                }
            }

            if translateOptions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking languages…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.jotMute)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(translateOptions) { option in
                            translateChip(option)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollEdgeEffectHidden(true, for: .all)
            }

            Text("Replaces the selected text · Undo brings it back")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.jotMute)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassCard(cornerRadius: 18))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
    }

    private func translateChip(_ option: KeyboardTranslateOption) -> some View {
        Button {
            lastTap = ("Translate", Date())
            onTranslateSelection(option.code)
            if option.installed { onDismiss() }
        } label: {
            HStack(spacing: 4) {
                Text(option.name)
                    .font(.system(size: 13, weight: option.installed ? .semibold : .regular))
                if !option.installed {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(option.installed ? Color.jotInk : Color.jotMute)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(translateChipBackground(installed: option.installed))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(translateInFlight)
        .accessibilityLabel(option.installed
                            ? "Translate to \(option.name)"
                            : "\(option.name), not downloaded")
        .accessibilityHint(option.installed
                           ? "Replaces the selected text with the translation"
                           : "Translate a note to \(option.name) in Jot once to download it")
    }

    @ViewBuilder
    private func translateChipBackground(installed: Bool) -> some View {
        if installed {
            Capsule().fill(
                LinearGradient(colors: Self.translateColors.map { $0.opacity(0.18) },
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(Capsule().strokeBorder(Self.translateColors[0].opacity(0.45), lineWidth: 0.5))
        } else {
            Capsule().fill(Color.jotKeyboardKeyFill)
        }
    }

    /// The Cleanup TOGGLE tile. Reads as a switch, not a command: the icon
    /// square is the purple feature gradient when ON and the neutral utility
    /// square when OFF, and a small "On" / "Off" chip sits on the icon's corner
    /// (where Undo wears its count) so the state is legible at a glance. When
    /// Apple Intelligence can't run the cleanup the OFF tile is washed and the
    /// tap explains why (banner) instead of switching on a pass that can't run.
    private var cleanupToggleTile: some View {
        let hint = hint(for: "Cleanup")
        return Button {
            lastTap = ("Cleanup", Date())
            onToggleCleanup()
        } label: {
            VStack(spacing: 6) {
                cleanupToggleIcon
                Text(hint ?? "Cleanup")
                    .font(.system(size: 10.5, weight: hint == nil ? .medium : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(hint != nil ? Color.jotWarningInk : (cleanupUsable ? Color.jotInk : Color.jotMute))
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .background(glassCard(cornerRadius: 13))
            .opacity(cleanupUsable ? 1 : 0.85)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: cleanupEnabled)
        .accessibilityLabel("AI cleanup")
        .accessibilityValue(cleanupEnabled ? "On" : "Off")
        .accessibilityHint(cleanupEnabled
                           ? "Double-tap to stop tidying every dictation"
                           : "Double-tap to tidy every dictation with AI")
    }

    /// ON, or OFF but switchable. OFF + Apple Intelligence unavailable = washed.
    private var cleanupUsable: Bool { cleanupEnabled || cleanupAvailable }

    private var cleanupToggleIcon: some View {
        let glyphColor: Color = cleanupEnabled ? .white : (cleanupUsable ? .jotInk : .jotMute)
        let chipColor: Color = cleanupEnabled ? .jotSuccess : .jotMute
        return ZStack(alignment: .topTrailing) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 32, height: 32)
                .background(cleanupToggleIconBackground)
            Text(cleanupEnabled ? "On" : "Off")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(chipColor))
                .offset(x: 8, y: -5)
        }
    }

    @ViewBuilder
    private var cleanupToggleIconBackground: some View {
        if cleanupEnabled {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: Self.cleanupColors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.jotKeyboardKeyFill)
        }
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

/// A short horizontal shake for a tile that answers a washed tap. Driven by an
/// incrementing counter so each new hint shakes once.
private struct TileShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 3 * sin(animatableData * .pi * 4), y: 0))
    }
}
