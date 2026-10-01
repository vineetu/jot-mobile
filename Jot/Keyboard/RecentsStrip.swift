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

    /// Fired when the user taps the row-trailing Rewrite button. Caller is
    /// expected to bounce to `jot://transcript?id=<uuid>&ai=1` so the main app
    /// pushes the transcript detail view AND rewrites the note right away with
    /// the user's Cleanup prompt (features.md §5.2). Distinct from
    /// `onInsertEntry` (paste-at-cursor) so the row carries two clear
    /// affordances: paste on the body, rewrite in Jot on the trailing icon.
    let onOpenInApp: (TranscriptHistoryMirror.Entry) -> Void

    /// "See all" header link — routes to `jot://history` via the
    /// keyboard controller (see `openHostHome()`).
    let onSeeAll: () -> Void

    /// A dictation outcome to report inside the card (§5.10): shown as a slim
    /// tinted row between the header and the entries, pushing them down while
    /// it holds. Nil ⇒ nothing to say.
    var status: KeyboardStatus? = nil
    var onDismissStatus: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which touch affordance is currently held, driving the contextual header
    /// hint ("Pastes here" / "Rewrite in Jot"). Set by the row-body / rewrite
    /// button styles on press and cleared on release — or when a press turns
    /// into a scroll, since a `ButtonStyle`'s `isPressed` cancels then too.
    /// PURE affordance: no gesture or behavior change, just feedback.
    @State private var pressHint: PressHint?

    private enum PressHint { case paste, open }

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
            // Clipped so the status row emerges from under the header — it
            // grows out of the card's top edge rather than dropping in.
            VStack(alignment: .leading, spacing: Self.headerToRowsSpacing) {
                if let status {
                    KeyboardStatusRow(status: status, reduceMotion: reduceMotion, onDismiss: onDismissStatus)
                        .transition(KeyboardStatusRow.transition(reduceMotion: reduceMotion))
                }
                rowsScrollView
            }
            .clipped()
            .animation(KeyboardStatusRow.animation(reduceMotion: reduceMotion), value: status)
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
        // Contextual hint, centered over the header's spare space — names what
        // the touch under the user's finger will do. Only present while a row
        // or the open button is actually held (overlay, so it never reflows
        // "Recent" / "See all").
        .overlay(alignment: .center) {
            if let pressHint {
                Text(pressHint == .paste ? "Pastes here" : "Rewrite in Jot")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.jotKeyboardStreamText.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: pressHint)
    }

    // MARK: - Rows

    /// Fixed-height ScrollView showing 3 rows by default; the rest
    /// (up to 10) are reached via internal scroll. A soft fade mask on
    /// the bottom edge advertises "more below" when applicable.
    private var rowsScrollView: some View {
        let rows = topTen
        // While a status row shows, the entries give up its height (the card
        // itself can't grow — the keyboard's height is fixed) and scroll.
        let statusInset: CGFloat = status == nil ? 0 : KeyboardStatusRow.height + Self.headerToRowsSpacing
        let hasOverflow = rows.count > Int(Self.visibleRowCount) || statusInset > 0
        let scrollHeight = Self.rowHeight * Self.visibleRowCount
            + Self.rowDividerHeight * (Self.visibleRowCount - 1)
            - statusInset

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
        // The strip draws its own bottom fade; the system's iOS 26 scroll-edge
        // effect would blur/wash the top row under the header.
        .scrollEdgeEffectHidden(true, for: .all)
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

    /// Single recents row, split into two independently-tappable zones:
    ///
    /// - **Body zone** (timestamp + transcript text + optional sparkles):
    ///   paste-at-cursor. Visually dominant — this is the primary action.
    /// - **Trailing zone** (`wand.and.stars` button): open the note in the
    ///   main app, which rewrites it immediately with the user's Cleanup
    ///   prompt and lands on the Rewrite tab (features.md §5.2). Distinct hit
    ///   region with its own padding so a careless brush against the right
    ///   edge doesn't bounce the user out of the host app when they meant to
    ///   paste.
    ///
    /// History: this slot was a plain "open in app" arrow (replaced 2026-07-25
    /// per owner direction — "put AI there"), then the system Writing Tools
    /// glyph while the app only *taught* that menu; since 2026-09-15 the app
    /// rewrites on arrival, so the icon is the wand. Deliberately NOT
    /// `sparkles`, which the row body already uses in coral to mark an entry
    /// that HAS a rewrite. The icon uses `jotKeyboardAccent` (the blue accent
    /// the rest of the keyboard treats as the actionable color), so it reads
    /// as the row's secondary CTA without competing with the body.
    private func normalRow(entry: TranscriptHistoryMirror.Entry) -> some View {
        HStack(spacing: 0) {
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
                        .lineLimit(1)
                        .frame(width: 52, alignment: .leading)

                    Text(entry.text)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    if entry.hasRewrite {
                        // Single coral `sparkles` glyph signals "this entry was
                        // AI-rewritten" — same affordance the main app's home
                        // rows use, kept identical here so the visual language
                        // stays consistent across surfaces. Static coral; reads
                        // on both light + dark glass.
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.jotCoralTop)
                            .padding(.trailing, 2)
                            .accessibilityLabel("Rewritten")
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: Self.rowVisualHeight, alignment: .leading)
                .padding(.vertical, Self.rowVerticalPad)
                .contentShape(Rectangle())
            }
            .buttonStyle(RecentRowPressStyle(onPress: { pressed in
                pressHint = pressed ? .paste : nil
            }))
            .accessibilityLabel(entry.createdAt.formatted(date: .omitted, time: .shortened))
            .accessibilityValue(entry.text)
            .accessibilityHint("Pastes this transcript")
            .accessibilityAddTraits(.isButton)

            Button {
                onOpenInApp(entry)
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotKeyboardAccent)
                    // Hit zone is intentionally wider than the glyph so the
                    // button is reachable on a cramped strip without
                    // shrinking the body's pasteable area more than needed.
                    .frame(width: 32, height: Self.rowVisualHeight)
                    .padding(.vertical, Self.rowVerticalPad)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OpenInAppPressStyle(onPress: { pressed in
                pressHint = pressed ? .open : nil
            }))
            .accessibilityLabel("Rewrite in Jot")
            .accessibilityHint("Opens this note in Jot and rewrites it with your Cleanup prompt")
            .accessibilityAddTraits(.isButton)
        }
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

// MARK: - Press affordance styles (UX-only, no behavior change)

/// Row-body press feedback. On press: a soft blue wash + a leading accent bar
/// mark the row the touch will paste. A `ButtonStyle`'s `isPressed` already
/// mirrors the existing gesture semantics — it goes false when a press turns
/// into a scroll — so tap / hold-release / hold-scroll all behave exactly as
/// before; this only *shows* the active target. Reports press changes so the
/// header can name the action.
private struct RecentRowPressStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.jotKeyboardAccent.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                    .fill(Color.jotKeyboardAccent)
                    .frame(width: 2.5)
                    .padding(.vertical, 2)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// Rewrite-in-app press feedback: a small blue rounded wash behind the Writing
/// Tools glyph so it reads as a target distinct from the paste body. Reports
/// press so the header hint can switch to "Rewrite in Jot".
private struct OpenInAppPressStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.jotKeyboardAccent.opacity(configuration.isPressed ? 0.14 : 0))
                    .padding(.horizontal, 2)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}
