//
//  KeyboardInstallStep.swift
//  Jot
//
//  Phase 6 — wizard panel W3 (renumbered from W4 after the bundled-Parakeet
//  ship retired the standalone speech-model download step).
//  Sends the user to System Settings to add Jot as a keyboard and turn on
//  Full Access. Only keyboard installation is auto-detected (via
//  `UITextInputMode.activeInputModes`) — Full Access remains a manual user
//  attestation because iOS exposes no API for the main app to read it.
//

import SwiftUI
import UIKit

struct KeyboardInstallStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    /// Bundle identifier of the JotKeyboard extension. Used to detect
    /// whether the user has added the keyboard in Settings.
    private static let keyboardBundleID = "com.vineetu.jot.mobile.Jot.Keyboard"

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardInstalled = false

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 2), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                keyboardTile
                    .padding(.bottom, 4)

                WizardItalicTitle(text: titleText)

                WizardBody(text: "In Settings, add Jot as a keyboard, then turn on Full Access so dictations can paste into other apps.")

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(
                title: keyboardInstalled ? "Continue" : "Open Keyboard Settings",
                action: {
                    if keyboardInstalled {
                        onAdvance()
                    } else {
                        openSettings()
                    }
                }
            )

            // Only show the manual escape when we DON'T already see the
            // keyboard installed — once detected, "Continue" is enough and
            // the secondary button is redundant noise.
            if !keyboardInstalled {
                WizardSecondaryTextButton(title: "I've already done this", action: onAdvance)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
            }
        }
        .task {
            refresh()
        }
    }

    private var titleText: String {
        keyboardInstalled ? "Jot keyboard detected" : "Set up Jot Keyboard"
    }

    // MARK: - Tile

    private var keyboardTile: some View {
        IconTile(
            systemImage: "keyboard.fill",
            tint: Color(red: 0.953, green: 0.933, blue: 0.906),
            shaded: Color(red: 0.886, green: 0.847, blue: 0.792),
            size: JotDesign.Spacing.tileHeroSize
        )
        .accessibilityHidden(true)
    }

    // MARK: - Detection

    /// Returns true iff the user has added the Jot keyboard in System
    /// Settings. Reads from `UITextInputMode.activeInputModes`, which is
    /// the public surface for "keyboards the user has enabled for typing".
    /// It does NOT report the separate Full Access setting.
    private func isKeyboardInstalled() -> Bool {
        for mode in UITextInputMode.activeInputModes {
            let id = mode.value(forKey: "identifier") as? String ?? ""
            if id.contains(Self.keyboardBundleID) {
                return true
            }
        }
        return false
    }

    private func refresh() {
        let installed = isKeyboardInstalled()
        if installed != keyboardInstalled {
            keyboardInstalled = installed
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
