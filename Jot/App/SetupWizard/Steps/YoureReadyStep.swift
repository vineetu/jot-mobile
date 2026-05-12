//
//  YoureReadyStep.swift
//  Jot
//
//  Phase 6 — wizard panel W10.
//  Green check circle + "You're ready." + an italic note that names the
//  two optional steps (vocab + AI rewrite). Primary CTA advances to W11
//  for optional setup; secondary CTA dismisses and marks setup complete.
//

import SwiftUI

struct YoureReadyStep: View {
    let onClose: () -> Void
    let onAdvanceToOptional: () -> Void
    let onSkipOptional: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 9), onClose: onClose)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 60)

                checkTile

                Text("You're ready.")
                    .font(.custom(JotType.frauncesSemiBold, size: 40))
                    .foregroundStyle(Color.jotInk)
                    .tracking(-0.8)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Text("Jot works now. You can start dictating any time.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
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
            WizardPrimaryButton(title: "Set up now", action: onAdvanceToOptional)
            WizardSecondaryTextButton(title: "Maybe later", action: onSkipOptional)
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
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.204, green: 0.780, blue: 0.349),
                            Color(red: 0.169, green: 0.659, blue: 0.290)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: "checkmark")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 72, height: 72)
        .shadow(
            color: Color(red: 0.204, green: 0.780, blue: 0.349).opacity(0.30),
            radius: 15,
            x: 0,
            y: 10
        )
        .accessibilityHidden(true)
    }
}
