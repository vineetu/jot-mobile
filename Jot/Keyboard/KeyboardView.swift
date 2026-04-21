import SwiftUI
import UIKit

/// Top-level SwiftUI surface for the Jot keyboard extension.
///
/// Layout is a vertical stack of two zones, top to bottom:
///
/// 1. **Accessory bar (conditional)** — Jot-specific paste affordance, hosted
///    in the same ~40pt strip Apple reserves for the QuickType candidate bar.
///    Only appears when we have something to surface (fresh-dictation paste
///    pill, or a Full Access setup hint). When there's nothing to show we
///    collapse the strip entirely rather than leaving a dead band above the
///    keys — Apple does the same on text fields that don't host suggestions.
/// 2. **Keyboard rows** — three plane rows plus the bottom action row. Each
///    row is laid out with per-row exact-fit math (see ``rowLayout(for:)``)
///    so keys never extend off the right edge and the visual rhythm matches
///    Apple's native keyboard row-by-row.
///
/// The view is stateless about app-level concerns. All behavior is driven by
/// callbacks owned by ``JotKeyboardViewController`` — it's the controller's
/// job to know what shift state to store, how to translate a letter tap into
/// `textDocumentProxy.insertText`, and when to refresh history from the App
/// Group mirror. Keeping the view "dumb" is what lets the controller drive
/// test scenarios and refresh fragments without rebuilding the whole tree.
struct KeyboardView: View {
    // MARK: - State passed down from the controller
    let preview: String?
    let hasFullAccess: Bool
    let plane: KeyboardLayouts.Plane
    let shiftState: ShiftState
    let historyEntries: [TranscriptHistoryMirror.Entry]
    let showHistory: Bool

    // MARK: - Callbacks
    let onKey: (KeyboardKeyDescriptor) -> Void
    let onKeyPressChange: (KeyboardKeyDescriptor, Bool) -> Void
    let onPaste: () -> Void
    let onToggleHistory: () -> Void
    let onInsertHistoryEntry: (TranscriptHistoryMirror.Entry) -> Void
    let onOpenFullAccess: () -> Void

    // MARK: - Dependencies

    /// Owns the haptic + audio generators. Lives on the controller for the
    /// extension's lifetime so the Taptic Engine stays warm; threaded through
    /// here as a single prop the way every other dep flows.
    let feedback: KeyboardFeedback

    var body: some View {
        ZStack(alignment: .top) {
            keyboardSurface
            if showHistory && hasFullAccess {
                HistoryOverlay(
                    entries: historyEntries,
                    onInsert: onInsertHistoryEntry,
                    onDismiss: onToggleHistory
                )
                .zIndex(1)
            }
        }
        // No explicit plane background. iOS provides a system input-view
        // background via the host UIInputViewController that extends behind
        // our SwiftUI surface; painting our own near-white plane on top
        // created a visible seam at the top (accessory bar) and bottom
        // (system mic/globe strip) where the surface boundaries didn't
        // align. User complaint 2026-04-21: "no background colors are still
        // different." Inheriting the system plane makes our surface match
        // whatever the OS drew under it. The plane stays the same shade
        // everywhere because it's literally one shared layer.
        // Min height tracks the keyboard's letters-area height plus the
        // optional accessory bar. 224 pt = large-phone 4-row height; the
        // accessory bar (when visible) adds ~42 pt.
        .frame(minHeight: 224)
    }

    // MARK: - Keyboard body

    /// Whether the accessory bar has any content to render. When false we
    /// collapse the strip so the bottom row sits tight against the screen
    /// bottom — matches one-handed reach goals.
    private var accessoryBarVisible: Bool {
        !hasFullAccess || preview != nil
    }

    private var keyboardSurface: some View {
        VStack(spacing: 0) {
            if accessoryBarVisible {
                KeyboardAccessoryBar(
                    preview: preview,
                    hasFullAccess: hasFullAccess,
                    onPaste: onPaste,
                    onOpenFullAccess: onOpenFullAccess
                )
                // User screenshot review 2026-04-21: accessory sat too close
                // to the top edge of the system keyboard plane. Add 2 pt of
                // extra air without changing the pill itself.
                .padding(.top, 6)
            }

            GeometryReader { proxy in
                let metrics = KeyboardMetrics(availableWidth: proxy.size.width)
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(Array(KeyboardLayouts.rows(for: plane).enumerated()), id: \.offset) { _, row in
                        keyRow(row, metrics: metrics)
                    }
                    keyRow(KeyboardLayouts.bottomRow(for: plane), metrics: metrics)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, metrics.sideInset)
                .padding(.vertical, metrics.verticalInset)
            }
            // Four rows × row height + three inter-row gaps + top/bottom
            // insets. We can't make this fully dynamic because the
            // `GeometryReader` inside needs a parent-imposed height to
            // measure width. Pick the large-phone bucket so Pro Max keys
            // are full-sized; standard-phone keyboards get ~8pt of extra
            // space at the bottom which is imperceptible.
            // `KeyboardMetrics(availableWidth: 430)` evaluates to
            // rowHeight 56 → keysAreaHeight 224 pt (non-Liquid-Glass).
            .frame(height: KeyboardMetrics(availableWidth: 430).keysAreaHeight)
        }
    }

    // MARK: - Row rendering

    /// Renders a single row. All per-row sizing is precomputed by
    /// ``rowLayout(for:metrics:)`` — this function just consumes the result.
    @ViewBuilder
    private func keyRow(_ row: [KeyboardKeyDescriptor], metrics: KeyboardMetrics) -> some View {
        let layout = rowLayout(for: row, metrics: metrics)
        HStack(spacing: metrics.keySpacing) {
            ForEach(Array(row.enumerated()), id: \.offset) { idx, key in
                KeyboardKey(
                    descriptor: key,
                    shiftState: shiftState,
                    width: layout.widths[idx],
                    height: metrics.keyHeight,
                    cornerRadius: metrics.buttonCornerRadius,
                    feedback: feedback,
                    onTap: onKey,
                    onPressChanged: onKeyPressChange
                )
            }
        }
        .padding(.horizontal, layout.edgeInset)
    }

    // MARK: - Per-row layout math

    /// Compute exact per-row key widths + a horizontal edge inset so every
    /// row fits the available inner width without overflowing and without
    /// leaving uneven gaps.
    ///
    /// ## Why per-row and not per-key
    ///
    /// The previous approach relied on a `widthWeight` property on the key
    /// descriptor + half-key `Spacer` flanks on 9-key rows. That produced
    /// two compounding bugs:
    ///
    /// 1. Row 2 of letters (9 letters) had the half-key spacers plus the
    ///    `HStack.spacing` between each spacer and its neighbour letter —
    ///    total width exceeded `innerWidth` by one full `keySpacing`.
    /// 2. Row 3 of letters (shift + 7 letters + backspace) matched the
    ///    same `count == 9` heuristic for the indent AND carried
    ///    `widthWeight = 1.5` flanks — overflow was roughly 10% of
    ///    `innerWidth` (e.g. 39pt on an iPhone 14).
    ///
    /// The overflow propagated visually as "keys extend off the right
    /// edge" — row 1 fit exactly, row 2 drifted 6pt past the edge, and
    /// row 3 drifted a full keycap past the edge.
    ///
    /// Doing the math once per row with the actual descriptor shape —
    /// rather than relying on per-key weights + Spacer tricks — fixes
    /// both cases and keeps the renderer honest about what each row
    /// costs.
    ///
    /// ## Row shapes
    ///
    /// | Shape | Widths | Edge inset |
    /// |---|---|---|
    /// | 10 primaries (row 1 letters/digits) | `W × 10` | 0 |
    /// | 9 primaries (row 2 letters/digits) | `W × 9` | `(W + s) / 2` |
    /// | Shift-flanked (row 3 letters) | `[flank, W × 7, flank]` | 0 |
    /// | Toggle-flanked (row 3 numbers/symbols) | `[flank, W × 5, flank]` | `(innerWidth − rowWidth) / 2` |
    /// | Bottom (planeToggle / history / space / return) | `[1.5W, 1.5W, space, 2W]` | 0 |
    ///
    /// `flank = 1.5W + 0.5s` — the value that makes letters row 3 fill
    /// innerWidth exactly. Numbers/symbols row 3 uses the same flank
    /// width so the shift-key column aligns vertically across planes,
    /// but has fewer inner keys so the row is shorter than innerWidth
    /// and picks up a symmetric edge inset to re-center.
    private func rowLayout(
        for row: [KeyboardKeyDescriptor],
        metrics: KeyboardMetrics
    ) -> RowLayout {
        let W = metrics.letterKeyWidth
        let spacing = metrics.keySpacing
        let innerWidth = metrics.innerWidth
        let actionFlankW = 1.5 * W + 0.5 * spacing

        // Bottom action row. Fixed-width plane toggle + history + return,
        // space absorbs the remainder.
        if row.contains(.space) {
            let planeToggleW: CGFloat = 1.5 * W
            let historyW: CGFloat = 1.5 * W
            let returnW: CGFloat = 2.0 * W
            let spacingSum = spacing * CGFloat(row.count - 1)
            let spaceW = max(
                80,
                innerWidth - planeToggleW - historyW - returnW - spacingSum
            )
            var widths: [CGFloat] = []
            for key in row {
                switch key {
                case .planeToggle: widths.append(planeToggleW)
                case .historyKey:  widths.append(historyW)
                case .returnKey:   widths.append(returnW)
                case .space:       widths.append(spaceW)
                default:           widths.append(W)
                }
            }
            return RowLayout(edgeInset: 0, widths: widths)
        }

        // Rows whose first or last key is an action-flank key (shift /
        // backspace / plane toggle). Those flanks each take
        // `actionFlankW`; everything else is a letter-width key; any
        // remaining space splits into symmetric edge padding.
        if isActionFlank(row.first) || isActionFlank(row.last) {
            var widths: [CGFloat] = []
            for key in row {
                widths.append(isActionFlank(key) ? actionFlankW : W)
            }
            let rowWidth = widths.reduce(0, +) + spacing * CGFloat(row.count - 1)
            let edgeInset = max(0, (innerWidth - rowWidth) / 2)
            return RowLayout(edgeInset: edgeInset, widths: widths)
        }

        // Plain letters/literals row — equal widths, centered if short.
        let widths = Array(repeating: W, count: row.count)
        let rowWidth = widths.reduce(0, +) + spacing * CGFloat(row.count - 1)
        let edgeInset = max(0, (innerWidth - rowWidth) / 2)
        return RowLayout(edgeInset: edgeInset, widths: widths)
    }

    private func isActionFlank(_ key: KeyboardKeyDescriptor?) -> Bool {
        guard let key else { return false }
        switch key {
        case .shift, .backspace:  return true
        case .planeToggle:        return true
        default:                  return false
        }
    }
}

/// Precomputed per-row layout. `widths[i]` is the width for row key `i`;
/// `edgeInset` is the symmetric horizontal padding applied to the row's
/// HStack so short rows center inside the keyboard's inner width.
private struct RowLayout {
    let edgeInset: CGFloat
    let widths: [CGFloat]
}
