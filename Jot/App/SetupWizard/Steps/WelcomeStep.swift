//
//  WelcomeStep.swift
//  Jot
//
//  Phase 6 — wizard panel W1.
//  "Jot" (Fraunces 80pt) + "Voice transcription, on your iPhone."
//  One word, one sentence, one button.
//

import SwiftUI

struct WelcomeStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 0), onClose: onClose)
        ) {
            VStack(spacing: 20) {
                Spacer(minLength: 72)

                IconTile(
                    systemImage: "sparkles",
                    tint: Color.jotCoralTop,
                    shaded: Color.jotCoralBottom,
                    size: JotDesign.Spacing.tileHeroSize
                )
                .accessibilityHidden(true)

                WizardItalicTitle(text: "Welcome to Jot.", size: 38)
                    .accessibilityAddTraits(.isHeader)

                Text("Voice transcription,\non your iPhone.")
                    .font(JotType.displaySerif(17))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 4)

                Spacer(minLength: 40)
            }
        } footer: {
            WizardPrimaryButton(title: "Get started", action: onAdvance)
        }
    }
}

#Preview {
    WelcomeStep(onClose: {}, onAdvance: {})
}
