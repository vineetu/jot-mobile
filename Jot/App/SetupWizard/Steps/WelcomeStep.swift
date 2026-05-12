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
                Spacer(minLength: 90)

                Text("Jot")
                    .font(.custom(JotType.frauncesSemiBold, size: 80))
                    .foregroundStyle(Color.jotInk)
                    .tracking(-3.0)
                    .accessibilityAddTraits(.isHeader)

                Text("Voice transcription,\non your iPhone.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
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
