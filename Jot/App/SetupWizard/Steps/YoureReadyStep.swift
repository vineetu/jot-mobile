//
//  YoureReadyStep.swift
//  Jot
//
//  Phase 6 — wizard panel W7 (renumbered after the bundled-Parakeet ship
//  retired the W3 speech-model download step and the W5 in-app try-it
//  step was dropped). W7 is now TERMINAL — the optional AI-offer
//  follow-on step was dropped (AI rewrite is set up from Settings, not
//  onboarding). Green success check tile + "You're ready." + an Apple
//  Watch "one more thing" handoff card. A single "Start jotting." CTA
//  dismisses the wizard and marks setup complete.
//

import SwiftUI

struct YoureReadyStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onFinish: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 6), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 60)

                checkTile

                WizardItalicTitle(text: "You're ready.", size: 40)
                    .padding(.top, 8)

                Text("Jot works now — start dictating in any app, any time.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .padding(.top, 4)

                watchCard
                    .padding(.top, 8)

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(title: "Start jotting.", action: onFinish)
        }
    }

    // MARK: - Tile

    private var checkTile: some View {
        IconTile(
            systemImage: "checkmark",
            tint: JotDesign.JotSemanticIcon.privacyOnDevice,
            shaded: JotDesign.JotSemanticIcon.privacyOnDeviceShaded,
            size: JotDesign.Spacing.tileHeroSize
        )
        .accessibilityHidden(true)
    }

    // MARK: - Apple Watch handoff card

    private var watchCard: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.jotAccent.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "applewatch")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.jotAccent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("It's on your wrist, too")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)

                Text("Caught an idea without your phone? Tap the Jot complication and speak — it syncs back automatically.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(1.3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("It's on your wrist, too. Caught an idea without your phone? Tap the Jot complication and speak — it syncs back automatically.")
    }
}
