//
//  YoureReadyStep.swift
//  Jot
//
//  Phase 6 — wizard panel W7 (renumbered after the bundled-Parakeet ship
//  retired the W3 speech-model download step and the W5 in-app try-it
//  step was dropped).
//  Green check circle + "You're ready." + an italic note that names the
//  two optional steps (vocab + AI rewrite). Primary CTA advances to the
//  first optional step (vocab seed); secondary CTA dismisses and marks
//  setup complete.
//

import SwiftUI

struct YoureReadyStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvanceToOptional: () -> Void
    let onSkipOptional: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 6), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 60)

                checkTile

                WizardItalicTitle(text: "You're ready.", size: 40)
                    .padding(.top, 8)

                Text("Jot works now. You can start dictating any time.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .padding(.top, 4)

                Text(optionalCopy)
                    .font(.custom(JotType.frauncesItalicText, size: 14))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(title: "Maybe later", action: onSkipOptional)
            WizardSecondaryTextButton(title: "Set up now", action: onAdvanceToOptional)
        }
    }

    /// Honest about the two optional steps. Pulls the AI download size
    /// from the design token so a backend swap propagates here.
    private var optionalCopy: String {
        let size = JotDesign.activeRewriteModelSize
        return "Two optional steps make it noticeably better — teaching Jot words you use, and adding AI rewrite. Vocabulary takes a minute. AI is a \(size) download."
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
}
