//
//  WarmHoldStep.swift
//  Jot
//
//  Phase 6 — wizard panel W6 (formerly W7 before the in-app try-it step
//  was dropped).
//  Lets the user choose whether Jot keeps the audio session warm briefly
//  after recording so the next dictation starts faster.
//

import SwiftUI

struct WarmHoldStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    @State private var warmHoldEnabled = true

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 5), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 44)

                readyTile

                WizardItalicTitle(text: "Keep the mic ready", size: 32)
                    .padding(.top, 8)

                WizardBody(text: bodyCopy)
                    .padding(.top, 2)

                warmHoldToggleRow
                    .padding(.top, 8)

                Spacer(minLength: 18)
            }
        } footer: {
            WizardPrimaryButton(title: "Continue") {
                AppGroup.warmHoldEnabled = warmHoldEnabled
                onAdvance()
            }
        }
        .onAppear {
            warmHoldEnabled = storedWarmHoldChoice ?? true
        }
    }

    private var bodyCopy: String {
        "After you dictate, Jot stays ready for two minutes — so your next dictation starts instantly, without hopping back to the app. Nothing is recorded until you tap Dictate."
    }

    private var warmHoldBinding: Binding<Bool> {
        Binding(
            get: { warmHoldEnabled },
            set: { newValue in
                warmHoldEnabled = newValue
                AppGroup.warmHoldEnabled = newValue
            }
        )
    }

    private var storedWarmHoldChoice: Bool? {
        guard AppGroup.defaults.object(forKey: AppGroup.Keys.warmHoldEnabled) != nil else {
            return nil
        }
        return AppGroup.warmHoldEnabled
    }

    private var readyTile: some View {
        IconTile(
            systemImage: "mic.fill",
            tint: JotDesign.JotSemanticIcon.privacyMicReady,
            shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded,
            size: JotDesign.Spacing.tileHeroSize
        )
        .accessibilityHidden(true)
    }

    private var warmHoldToggleRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: warmHoldBinding) {
                Text("Keep mic ready")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .tint(Color.jotSuccess)

            StatusPillV09(
                label: warmHoldEnabled ? "Always" : "Off",
                tint: warmHoldEnabled ? .always : .neutral
            )
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
