//
//  HowItWorksStep.swift
//  Jot
//
//  Phase 6 — wizard panel W4 (renumbered from W5 after the bundled-Parakeet
//  ship retired the standalone speech-model download step).
//  Single lead sentence + the keyboard → origami-crane → SWIPE → keyboard
//  flow diagram (scaled up ~1.7× to anchor the panel, with the Jot brand
//  crane in the middle position replacing the coral mic glyph).
//  Caption: "TAP DICTATE → SWIPE BACK → STOP → TEXT PASTED".
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
            VStack(spacing: 20) {
                Spacer(minLength: 16)

                WizardItalicTitle(text: "How it works", size: 30)
                    .padding(.bottom, 2)

                Text("Tap Dictate, swipe back to your app, then stop from the keyboard.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                diagram
                    .padding(.top, 24)
                    .padding(.bottom, 4)

                Text("TAP DICTATE → SWIPE BACK → STOP → TEXT PASTED")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                    .tracking(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(title: "Got it", action: onAdvance)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Diagram (dialled back from the ~1.7× round — keyboard glyphs
    // ~64pt, crane ~80pt so it still reads as the brand anchor)

    private var diagram: some View {
        HStack(spacing: 8) {
            keyboardGlyph
            arrow
            craneGlyph
            swipeIndicator
            keyboardGlyph
        }
        .accessibilityLabel("Tap dictate, record in Jot, swipe back, text pasted")
    }

    private var keyboardGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
            Image(systemName: "keyboard")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.jotInk.opacity(0.8))
        }
        .frame(width: 64, height: 64)
    }

    /// Origami crane — the Jot brand mark — sits at the centre of the flow
    /// to read as "Jot opens to record." Replaces the earlier coral mic glyph.
    /// Clipped to a continuous rounded rect so the PNG's baked-in black
    /// margin reads as an iOS app-icon shape rather than a square frame.
    private var craneGlyph: some View {
        Image("OrigamiCrane")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityLabel("Jot opens")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.jotMute)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private var swipeIndicator: some View {
        VStack(spacing: 3) {
            Image(systemName: "arrow.forward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotAccent)
                .rotationEffect(.degrees(-12))
            Text("SWIPE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.jotAccent)
                .tracking(0.6)
        }
        .frame(width: 44)
        .accessibilityHidden(true)
    }
}
