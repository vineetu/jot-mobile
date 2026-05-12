//
//  HowItWorksStep.swift
//  Jot
//
//  Phase 6 — wizard panel W6.
//  Two-paragraph explanation + the keyboard → coral mic → SWIPE → keyboard
//  diagram. Caption: "TAP DICTATE → RECORD IN JOT → SWIPE BACK → TEXT PASTED".
//

import SwiftUI

struct HowItWorksStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 5), onClose: onClose)
        ) {
            VStack(spacing: 16) {
                Spacer(minLength: 24)

                WizardTitle(text: "How it works", size: 28)
                    .padding(.bottom, 6)

                Text("Jot is dictation-only — no QWERTY. Keep your usual keyboard for typing.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Tapping Dictate opens Jot to record (iOS doesn't allow mic access from keyboards). After recording, swipe right along the bottom to return — text is in the field.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)

                diagram
                    .padding(.top, 18)

                Text("TAP DICTATE → RECORD IN JOT → SWIPE BACK → TEXT PASTED")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                    .tracking(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(title: "Got it", action: onAdvance)
        }
    }

    // MARK: - Diagram

    private var diagram: some View {
        HStack(spacing: 6) {
            keyboardGlyph
            arrow
            coralMicGlyph
            swipeIndicator
            keyboardGlyph
        }
        .accessibilityLabel("Tap dictate, record in Jot, swipe back, text pasted")
    }

    private var keyboardGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
            Image(systemName: "keyboard")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.jotInk.opacity(0.8))
        }
        .frame(width: 52, height: 52)
    }

    private var coralMicGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.32, blue: 0.28),
                            Color(red: 0.90, green: 0.23, blue: 0.19)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 52, height: 52)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.jotMute)
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    private var swipeIndicator: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotAccent)
                .rotationEffect(.degrees(-12))
            Text("SWIPE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.jotAccent)
                .tracking(0.5)
        }
        .frame(width: 36)
        .accessibilityHidden(true)
    }
}
