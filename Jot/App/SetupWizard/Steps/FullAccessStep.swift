//
//  FullAccessStep.swift
//  Jot
//
//  Phase 6 — wizard panel W5.
//  Green shield IconBox + "Enable Full Access" + Settings deep-link.
//
//  Detection caveat: `hasFullAccess` is a property of
//  `UIInputViewController` which only resolves inside the keyboard
//  extension process. The main-app process can't read it directly; the
//  closest we have is an App Group flag the keyboard writes on its
//  first viewWillAppear with Full Access granted. To keep the wizard
//  decisive without depending on the keyboard being launched mid-flow,
//  this step provides a manual "I've enabled Full Access" continue
//  affordance once the user has been to Settings at least once.
//

import SwiftUI
import UIKit

struct FullAccessStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasBeenToSettings = false

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 4), onClose: onClose)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                shieldTile
                    .padding(.bottom, 4)

                WizardTitle(text: "Enable Full Access")

                WizardBody(text: "The keyboard needs Full Access to paste text. Your dictations never leave your iPhone.")

                WizardItalicNote(text: "iOS will show a warning. Standard for any custom keyboard.")

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(
                title: hasBeenToSettings ? "I've enabled it" : "Open Settings",
                action: {
                    if hasBeenToSettings {
                        onAdvance()
                    } else {
                        openSettings()
                        hasBeenToSettings = true
                    }
                }
            )

            if hasBeenToSettings {
                WizardSecondaryTextButton(title: "Open Settings again", action: openSettings)
            }
        }
        // TODO: when the keyboard extension writes an App Group flag on
        // first appearance with Full Access granted, observe scenePhase →
        // .active and check that flag to auto-advance. Today the keyboard
        // doesn't write that flag, so manual confirmation is the path.
    }

    // MARK: - Tile

    private var shieldTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
        .shadow(
            color: Color(red: 0.204, green: 0.780, blue: 0.349).opacity(0.30),
            radius: 15,
            x: 0,
            y: 10
        )
        .accessibilityHidden(true)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
