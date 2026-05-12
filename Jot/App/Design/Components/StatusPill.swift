//
//  StatusPill.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §3.
//

import SwiftUI

/// Tint variant for a `StatusPill`. Drives both the LED dot color and the
/// hand-rolled gradient background.
///
/// Phase 1 punch-list FIX 8: dot/ink colours now come from design tokens
/// (`Color.jotSuccess`, `Color.jotWarning`, `Color.jotAccent`, …) instead
/// of inline `Color(red:green:blue:)` literals.
enum PillTint {
    case success
    case warning
    case info

    var dotColor: Color {
        switch self {
        case .success: return .jotSuccess
        case .warning: return .jotWarning
        case .info:    return .jotAccent
        }
    }

    var inkColor: Color {
        switch self {
        case .success: return .jotSuccessInk
        case .warning: return .jotWarningInk
        case .info:    return .jotAccent
        }
    }

    var bgGradient: LinearGradient {
        // ~24% tint, fading slightly across the pill.
        LinearGradient(
            colors: [
                dotColor.opacity(0.20),
                dotColor.opacity(0.12)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var borderColor: Color {
        dotColor.opacity(0.30)
    }
}

/// 5pt LED dot + label, ~28pt tall. Sub-44pt by design — we hand-roll the
/// background rather than use `.glassEffect()` (per plan §13 risk 1).
///
/// Phase 1 punch-list FIX 5: padding tightened from 10×5 to plan-spec 8×4
/// via `JotDesign.Spacing.statusPillPaddingH` / `…PaddingV`.
struct StatusPill: View {
    let label: String
    let tint: PillTint

    init(label: String, tint: PillTint) {
        self.label = label
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint.dotColor)
                .frame(
                    width: JotDesign.Spacing.statusDotDiameter,
                    height: JotDesign.Spacing.statusDotDiameter
                )
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.inkColor)
        }
        .padding(.horizontal, JotDesign.Spacing.statusPillPaddingH)
        .padding(.vertical, JotDesign.Spacing.statusPillPaddingV)
        .frame(minHeight: JotDesign.Spacing.statusPillHeight)
        .background(
            Capsule(style: .continuous)
                .fill(tint.bgGradient)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.borderColor, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}
