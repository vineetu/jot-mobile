//
//  HelpRows.swift
//  Jot
//
//  Reusable row chrome for the redesigned Help screen:
//    • `HelpExpandableRow` — an icon-tile + title row that taps to reveal an
//      expandable body (the "What Jot does" feature card + the Troubleshooting
//      accordion). Chevron rotates 180°; height animates on the app's standard
//      ~0.3s ease.
//    • `HelpLinkRow` — an icon-tile + title (+ optional subtitle) row with a
//      trailing right-chevron, used inside a `NavigationLink` to push a
//      sub-page. Matches the Settings row rhythm.
//
//  Both compose JotDesign tokens + `IconTile` + `RowChevron` — no new palette.
//

import SwiftUI

/// Tap-to-expand row. The header (tile + title + chevron) is always visible;
/// `body` reveals/hides beneath it with an animated height + chevron rotation.
/// Used for the feature card (with an icon tile) and the troubleshooting
/// accordion (no tile — a plain question line).
struct HelpExpandableRow<Body: View>: View {
    /// SF Symbol for the leading icon tile. `nil` → no tile (troubleshooting).
    var systemImage: String?
    /// Icon-tile gradient stops (token pair). Ignored when `systemImage == nil`.
    var tint: Color = .clear
    var shaded: Color = .clear

    let title: String
    /// Title face — features use 16.5/600; troubleshooting uses 15.5/500.
    var titleFont: Font = .system(size: 16.5, weight: .semibold)

    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let bodyContent: () -> Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    if let systemImage {
                        IconTile(systemImage: systemImage, tint: tint, shaded: shaded)
                    }

                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(Color.jotInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")

            if isExpanded {
                bodyContent()
                    // Indent the body so it aligns under the title (past the
                    // 30pt tile + 14pt gap = 44pt) when there's a tile; a flat
                    // 16pt gutter otherwise.
                    .padding(.leading, systemImage == nil ? 16 : 16 + JotDesign.Spacing.tileRowSize + 14)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isExpanded)
    }
}

/// Icon-tile row with a trailing right-chevron, used inside a `NavigationLink`
/// to push a Help sub-page. Optional subtitle below the title.
struct HelpLinkRow: View {
    let systemImage: String
    let tint: Color
    let shaded: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: systemImage, tint: tint, shaded: shaded)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            RowChevron()
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Hairline divider matching the Help card row separators. Inset to align with
/// the row content (past the icon tile when present).
struct HelpRowDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Divider()
            .overlay(Color.jotMuteWeak.opacity(0.45))
            .padding(.leading, inset)
    }
}
