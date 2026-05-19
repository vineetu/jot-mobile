import SwiftUI

struct RecentsNavBar: View {
    let isSelectionMode: Bool
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onCancelSelection: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "j.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
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

                Button(action: onSettings) {
                    Text("JS")
                        .font(.system(size: 13, weight: .bold, design: .default))
                        .foregroundStyle(Color.jotBlueBottom)
                        .frame(width: 36, height: 36)
                        .background(Color.jotBlueTop.opacity(0.14), in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(Color.jotBlueTop.opacity(0.24), lineWidth: 0.5)
                        )
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens Settings")

                if isSelectionMode {
                    cancelSelectionButton
                }
            }
        }
    }

    private var cancelSelectionButton: some View {
        Button {
            onCancelSelection()
        } label: {
            Text("Cancel")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(Color.jotBlueTop)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel selection")
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
