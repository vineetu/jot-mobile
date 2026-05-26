//
//  ActionBar.swift
//  Jot
//
//  Phase 3 of the UX overhaul — transcript-detail floating action dock.
//  See: Jot/tmp/ux-overhaul-plan.md §5.3 + §3 (Mockup 09).
//
//  Glass-heavy ~60pt floating dock anchored to the bottom of the transcript
//  detail surface. Hosts Copy / Share / Rewrite (prominent blue pill) /
//  More. Each row item is ≥44pt for HIG-compliant hit targets; the Rewrite
//  pill is the visually loudest control (blue fill + white glyph) so it
//  reads as the primary CTA without competing with the back / sparkle
//  toolbar buttons up top.
//

import SwiftUI

/// A single non-primary action surfaced in the dock (Copy / Share / More).
struct ActionBarItem: Identifiable {
    let id = UUID()
    let systemImage: String
    let label: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    init(
        systemImage: String,
        label: String,
        accessibilityLabel: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Floating glass-heavy action dock. The `primary` item renders as a blue
/// pill in the middle; the surrounding items render as small glass buttons.
///
/// Layout: leading-trailing trio with the primary CTA centered. The four
/// slots are intentionally fixed (left-left / center-primary / right-right)
/// because the mockup is explicit about which actions belong where; a more
/// flexible API can be added if more screens adopt this dock.
struct ActionBar: View {
    let leading: [ActionBarItem]
    let primary: ActionBarItem
    let trailing: [ActionBarItem]

    init(
        leading: [ActionBarItem],
        primary: ActionBarItem,
        trailing: [ActionBarItem]
    ) {
        self.leading = leading
        self.primary = primary
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(leading) { item in
                secondaryButton(item)
            }

            Spacer(minLength: 8)

            primaryButton(primary)

            Spacer(minLength: 8)

            ForEach(trailing) { item in
                secondaryButton(item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .frame(maxWidth: .infinity)
        .modifier(
            JotDesign.Surface.heavy.modifier(
                cornerRadius: JotDesign.Spacing.sheetRadius
            )
        )
    }

    @ViewBuilder
    private func secondaryButton(_ item: ActionBarItem) -> some View {
        Button(action: item.action) {
            Image(systemName: item.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                // Without contentShape, SwiftUI's hit area for the
                // button is just the drawn icon pixels — taps on the
                // surrounding padding (which looks tappable) silently
                // no-op. contentShape(Rectangle()) makes the full 44pt
                // frame hit-testable.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1.0 : 0.45)
        .accessibilityLabel(item.accessibilityLabel)
    }

    @ViewBuilder
    private func primaryButton(_ item: ActionBarItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(item.label)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotBlueTop,
                                Color.jotBlueBottom
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .shadow(color: Color.jotBlueTop.opacity(0.30), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1.0 : 0.45)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}
