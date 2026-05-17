import SwiftUI

/// Tint variants for v0.9 status pills used by readiness, persistent setting,
/// warning, informational, and neutral states.
enum StatusPillV09Tint {
    case ready
    case always
    case warning
    case info
    case neutral

    var color: Color {
        switch self {
        case .ready, .always:
            return .jotSuccess
        case .warning:
            return .jotWarning
        case .info:
            return .jotBlueTop
        case .neutral:
            return .jotPageInkSecondary
        }
    }
}

/// Compact v0.9 status pill with a token-tinted dot and capsule chrome; the
/// capsule shape carries the same fully rounded intent as `JotDesign.Spacing.pillRadius`.
struct StatusPillV09: View {
    private let label: String
    private let tint: StatusPillV09Tint

    init(label: String, tint: StatusPillV09Tint) {
        self.label = label
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint.color)
                .frame(
                    width: JotDesign.Spacing.statusDotDiameter,
                    height: JotDesign.Spacing.statusDotDiameter
                )

            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint.color)
        }
        .padding(.horizontal, JotDesign.Spacing.statusPillPaddingH)
        .padding(.vertical, JotDesign.Spacing.statusPillPaddingV)
        .background {
            Capsule(style: .continuous)
                .fill(tint.color.opacity(0.22))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.color.opacity(0.36), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

#Preview("Status Pill v0.9") {
    HStack(spacing: 8) {
        StatusPillV09(label: "Ready", tint: .ready)
        StatusPillV09(label: "Always", tint: .always)
        StatusPillV09(label: "Warn", tint: .warning)
        StatusPillV09(label: "Info", tint: .info)
        StatusPillV09(label: "Idle", tint: .neutral)
    }
    .padding()
    .background(Color.jotPageBase)
}
