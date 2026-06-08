import SwiftUI

// MARK: - WatchCard

/// Watch-native echo of the iOS `LiquidGlassCard`.
///
/// Single layered fill + hairline border. No `.regularMaterial`, no
/// multi-layer blurs, no drop shadow — watchOS AMOLED can't render any
/// of those cleanly, and a 40mm tile is too small to host the iOS
/// card's full visual stack. ~5x cheaper to render than a port of
/// `LiquidGlassCard` would be.
///
/// Use as the standard "grouped surface" wrapper on the watch — frames
/// related rows the same way `LiquidGlassCard` does on iOS.
struct WatchCard<Content: View>: View {
    var paddingH: CGFloat = JotDesignWatchSafe.watchCardPaddingH
    var paddingV: CGFloat = JotDesignWatchSafe.watchCardPaddingV
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: JotDesignWatchSafe.watchCardRadius,
                    style: .continuous
                )
                .fill(JotDesignWatchSafe.watchCardFill)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: JotDesignWatchSafe.watchCardRadius,
                    style: .continuous
                )
                .strokeBorder(JotDesignWatchSafe.watchHairline, lineWidth: 0.5)
            )
    }
}

// MARK: - WatchSectionLabel

/// Watch-native echo of the iOS `SectionLabel`. UPPERCASE caption2,
/// tracking 1.0, secondary color. Marks the boundary between regions
/// of the root scroll surface.
struct WatchSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.0)
            .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - WatchUtilityRow

/// Single-row utility entry — used for "Sync diagnostics" footer link
/// at the bottom of the root scroll. Deliberately low-contrast (uses
/// `watchUtilityInk`) so the user reads it as "below the fold of normal
/// usage." Full-width tap target via `.contentShape(Rectangle())`.
struct WatchUtilityRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
            Text(title)
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
        }
        .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
        .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - WatchTranscriptRow

/// Single transcript row — used both inline on `RootView` and inside
/// `RecentTranscriptsView`'s card. Same content as the prior private
/// `TranscriptRow` in `RecentTranscriptsView`, with `.contentShape`
/// applied so the tap region covers the full row width (defensive
/// against the hit-test gap that mis-routed taps in build 46-48).
struct WatchTranscriptRow: View {
    let transcript: WatchTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transcript.preview)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                Text(transcript.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                if transcript.source == "watch" {
                    Image(systemName: "applewatch")
                        .font(.caption2)
                        .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                }
            }
        }
        .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
        .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - WatchInlineDivider

/// Thin 0.5pt divider for stacked rows inside a `WatchCard`. Adaptive
/// via `Color.primary.opacity(...)` so it reads in both schemes.
struct WatchInlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}
