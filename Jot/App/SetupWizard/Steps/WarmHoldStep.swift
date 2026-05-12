//
//  WarmHoldStep.swift
//  Jot
//
//  Phase 6 — wizard panel W9.
//  Lets the user choose whether Jot keeps the audio session warm briefly
//  after recording so the next dictation starts faster.
//

import SwiftUI

struct WarmHoldStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 8), onClose: onClose)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 44)

                readyTile

                WizardTitle(text: "Keep mic ready?", size: 32)
                    .padding(.top, 8)

                WizardBody(text: bodyCopy)
                    .padding(.top, 2)

                Spacer(minLength: 18)
            }
        } footer: {
            VStack(spacing: 10) {
                WarmHoldChoiceButton(
                    title: "Keep mic ready",
                    action: { chooseWarmHold(true) }
                )

                WarmHoldChoiceButton(
                    title: "No thanks",
                    action: { chooseWarmHold(false) }
                )
            }
        }
    }

    private var bodyCopy: String {
        "After a dictation, Jot can keep a 60-second audio session active so the next recording starts faster. The orange mic indicator stays on during that wait, but Jot is not transcribing while it waits. You can change this anytime in Settings."
    }

    private func chooseWarmHold(_ enabled: Bool) {
        AppGroup.warmHoldEnabled = enabled
        onAdvance()
    }

    private var readyTile: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.jotAccent)
        }
        .frame(width: 76, height: 76)
        .shadow(color: Color.jotAccent.opacity(0.18), radius: 16, x: 0, y: 10)
        .accessibilityHidden(true)
    }
}

private struct WarmHoldChoiceButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
