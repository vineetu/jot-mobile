//
//  HowItWorksStep.swift
//  Jot
//
//  Phase 6 — wizard panel W4 (renumbered from W5 after the bundled-Parakeet
//  ship retired the standalone speech-model download step).
//
//  Step-by-step redesign (wizard-overhaul): the capture flow is taught as
//  FOUR explicit numbered steps, each held for ~3.25 seconds in a looping
//  13-second mini-phone animation, with the active step's number shown in the
//  scene AND highlighted in the list below:
//    1. Tap Dictate on your keyboard
//    2. Jot opens and starts recording
//    3. Swipe back to your app
//    4. Stop from the keyboard when you're done
//  The honest "we'd skip this if we could" note sits at the bottom, just above
//  the Got it button. Reduce-motion renders a single static frame (no loop).
//
//  The animated scene + numbered step list now live in the reusable
//  `HowItWorksScene` (shared with the Help → "How Jot works" page); this panel
//  composes that bundle (with `showFootnote: false`) and supplies the footnote
//  in its own footer slot, from the same `HowItWorksScene.honestFootnote`
//  source of truth, so the panel reads identically to before the extraction.
//

import SwiftUI

struct HowItWorksStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 3), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 8)

                WizardItalicTitle(text: "How it works", size: 35)

                // Scene + step list only; the footnote stays in the footer
                // (below), just above Got it — same layout as before extraction.
                HowItWorksScene(showFootnote: false)

                Spacer(minLength: 8)
            }
        } footer: {
            VStack(spacing: 12) {
                // The honest note sits at the bottom, just above Got it.
                Text(HowItWorksScene.honestFootnote)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)

                WizardPrimaryButton(title: "Got it", action: onAdvance)
                    .padding(.horizontal, 16)
            }
        }
    }
}
