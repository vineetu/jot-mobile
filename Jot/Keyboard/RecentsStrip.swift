import SwiftUI

/// Idle-state top strip showing recent transcripts.
///
/// Rebuilt 2026-05-11 per `Jot/tmp/keyboard-design-reference.html`:
///
/// - Header row: uppercase `Recent` label on the leading edge + an
///   iOS-blue "See all" chevron link on the trailing edge. Tapping
///   "See all" calls `onSeeAll`, which routes to `jot://history` and
///   brings the main app to the foreground at home (the recents list).
///   Route is documented in `JotKeyboardViewController.openHostHome()`.
/// - List: up to 10 recents inside a fixed-height ScrollView showing
///   3 rows by default. Each row is a SF-Mono timestamp (`#8b8b95`)
///   followed by the body text in soft-navy `#3C5A99` — NOT black.
/// - **Just-now / green-checkmark row removed entirely.** Per the
///   2026-05-11 spec: "fresh entries just appear at the top with
///   their normal timestamp." The just-now marker was redundant with
///   the row already sitting at index 0 and read as scaffolding.
/// - Surface: Liquid Glass card — translucent-white linear gradient
///   (0.78 → 0.48 opacity) + 0.5pt hairline + soft drop shadow.
///   System material blur shows through via `.background(.ultraThinMaterial)`
///   so the underlying chrome (warm cream idle / blue-tinted recording)
///   bleeds in at the spec'd ~180% saturate, ~20pt blur recipe.
///
/// ### Why rows are below the 44pt HIG hit-target floor
/// Each row is ~32pt total (24pt visual + 4pt × 2 vertical padding).
/// Deliberate density tradeoff (2026-05-11) per user direction —
/// the strip is "tap to re-insert", taps are precise + intentional,
/// not scrubbed. Other interactive surfaces in the keyboard (action
/// row, dictate pill, key caps) keep ≥44pt hit targets.
struct RecentsStrip: View {
    let entries: [TranscriptHistoryMirror.Entry]
    let onInsertEntry: (TranscriptHistoryMirror.Entry) -> Void

    /// "See all" header link — routes to `jot://history` via the
    /// keyboard controller (see `openHostHome()`).
    let onSeeAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Top-10 view of the mirrored history. We render 3 by default and
    /// keep the rest accessible via internal scroll. Empty when no
    /// Full Access / no history yet — the strip still draws header +
    /// reserved space so the keys below don't reflow.
    private var topTen: [TranscriptHistoryMirror.Entry] {
        Array(entries.prefix(10))
    }

    // MARK: - Layout constants

    /// Visual row height (the part the user sees). One line of mono
    /// timestamp + truncated body.
    private static let rowVisualHeight: CGFloat = 24

    /// Top + bottom padding per row. Total row height = visual + 2×pad.
    private static let rowVerticalPad: CGFloat = 4

    /// Effective per-row height inside the ScrollView (visual + pads).
    private static var rowHeight: CGFloat {
        rowVisualHeight + rowVerticalPad * 2
    }

    /// Visible-row count before the user has to scroll.
    private static let visibleRowCount: CGFloat = 3

    /// Explicit hairline thickness used between rows.
    private static let rowDividerHeight: CGFloat = 0.5

    /// Header label height — leaves room for both the section label
    /// ascender and the "See all" chevron baseline.
    private static let headerHeight: CGFloat = 16

    /// Inner spacing between header and the scroll region.
    private static let headerToRowsSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Self.headerToRowsSpacing) {
            header
            rowsScrollView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: stripHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassSurface)
        .overlay(
            // Inset top highlight — the Liquid Glass recipe's bright
            // top hairline (`rgba(255,255,255,0.85)`) per spec.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            // 0.5pt outer hairline at `rgba(0,0,0,0.04)`.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
    }

    // MARK: - Header

    /// Uppercase "RECENT" + iOS-blue "See all" chevron link.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            SectionLabel("Recent")
            Spacer(minLength: 0)
            Button {
                onSeeAll()
            } label: {
                HStack(spacing: 2) {
                    Text("See all")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.jotKeyboardAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See all recents")
            .accessibilityHint("Opens Jot to the full recents list")
            .accessibilityAddTraits(.isButton)
        }
        .frame(height: Self.headerHeight)
    }

    // MARK: - Rows

    /// Fixed-height ScrollView showing 3 rows by default; the rest
    /// (up to 10) are reached via internal scroll. A soft fade mask on
    /// the bottom edge advertises "more below" when applicable.
    private var rowsScrollView: some View {
        let rows = topTen
        let hasOverflow = rows.count > Int(Self.visibleRowCount)
        let scrollHeight = Self.rowHeight * Self.visibleRowCount
            + Self.rowDividerHeight * (Self.visibleRowCount - 1)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, entry in
                    normalRow(entry: entry)
                    if idx < rows.count - 1 {
                        rowDivider
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: scrollHeight)
        .mask(scrollFadeMask(showFade: hasOverflow))
    }

    /// Fixed-thickness inter-row rule. v2 retheme: use the adaptive
    /// glass-hairline token so the divider follows the card's own
    /// light/dark hairline value instead of a fixed mute.
    private var rowDivider: some View {
        Color.jotKeyboardGlassHairline
            .frame(height: Self.rowDividerHeight)
    }

    /// Soft fade at the bottom edge when the list overflows.
    @ViewBuilder
    private func scrollFadeMask(showFade: Bool) -> some View {
        if showFade {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.85),
                    .init(color: .black.opacity(0.15), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    // MARK: - Row

    /// Single recents row — mono timestamp + soft-navy body + trailing
    /// `chevron.right` glyph. Body color is `jotKeyboardStreamText`
    /// (`#3C5A99`) per spec.
    private func normalRow(entry: TranscriptHistoryMirror.Entry) -> some View {
        Button {
            onInsertEntry(entry)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9.5, design: .monospaced))
                    // v2 retheme: adaptive mute so the time stamp reads
                    // correctly on the dark glass card (where the prior
                    // `.jotMute` was too dark to be legible).
                    .foregroundStyle(Color.jotKeyboardTimeMute)
                    .frame(width: 42, alignment: .leading)

                Text(entry.text)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color.jotKeyboardStreamText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    // v2 retheme: adaptive chevron color follows the
                    // time-mute token so the trailing affordance stays
                    // legible on both light + dark glass.
                    .foregroundStyle(Color.jotKeyboardTimeMute)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: Self.rowVisualHeight)
            .padding(.vertical, Self.rowVerticalPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.createdAt.formatted(date: .omitted, time: .shortened))
        .accessibilityValue(entry.text)
        .accessibilityHint("Inserts this transcript")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Surface

    /// Strip total height. Math: outer V-padding 12 + header 16 +
    /// headerToRows 4 + 3 × 32 + 2 × 0.5 = 129pt. Stays constant
    /// regardless of entry count (internal scroll absorbs the rest).
    private var stripHeight: CGFloat {
        Self.headerHeight
            + Self.headerToRowsSpacing
            + Self.rowHeight * Self.visibleRowCount
            + Self.rowDividerHeight * (Self.visibleRowCount - 1)
            + 12 // outer vertical padding (6 top + 6 bottom)
    }

    /// Liquid Glass card surface. We stack `.ultraThinMaterial` (gives
    /// us iOS 26's 20pt-blur + ~180% saturate "vibrant" recipe out of
    /// the box) under a translucent-white gradient so the spec'd
    /// `rgba(255,255,255,0.78) → rgba(255,255,255,0.48)` fade comes
    /// through without losing the live blur of the underlying chrome.
    @ViewBuilder
    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.jotKeyboardGlassFill1,
                            Color.jotKeyboardGlassFill2,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}
