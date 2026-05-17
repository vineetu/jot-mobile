import SwiftUI

/// Primary v0.9 coral CTA for save, run, dictate, and wizard actions; the
/// capsule shape carries the same fully rounded intent as `JotDesign.Spacing.pillRadius`.
struct CoralActionButton: View {
    private let label: String
    private let systemImage: String?
    private let isEnabled: Bool
    private let action: () -> Void

    init(
        label: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }

                Text(label)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.jotCoralTop, .jotCoralBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .shadow(color: Color.jotCoralTop.opacity(0.40), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
    }
}

#Preview("Coral Action Button") {
    ZStack {
        Color.jotPageBase
            .ignoresSafeArea()

        VStack(spacing: 16) {
            CoralActionButton(label: "Dictate", systemImage: "mic.fill") {}
            CoralActionButton(label: "Save", isEnabled: false) {}
        }
    }
}
