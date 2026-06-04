import SwiftUI

struct RecentsNavBar: View {
    let isSelectionMode: Bool
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onCancelSelection: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                // Brand mark — the app/watch icon art clipped to a circle (the
                // watch's circular masking), matching the icon on the Home
                // Screen. Replaces the old `j.circle.fill` SF monogram.
                Image("JotBrandTile")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                Text("Jot")
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .tracking(-0.1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                glassIconButton(
                    systemName: "questionmark",
                    accessibilityLabel: "Help",
                    accessibilityHint: "Opens the Help screen",
                    action: onHelp
                )

                // WS-E §1.9: the "JS" initials avatar is replaced by a bigger
                // gear glyph, light/dark aware. The gear reads as "settings"
                // without faking a user-account avatar Jot doesn't have.
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(
                            colorScheme == .dark
                                ? Color.jotPageInk
                                : Color.jotPageInkSecondary
                        )
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
                        )
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens Settings")
            }
        }
        // Selection-mode Cancel now floats at the top of the home view
        // (`ContentView.floatingCancelButton`) so it stays reachable when the
        // header scrolls away — it is no longer rendered inline here.
    }

    private func glassIconButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}
