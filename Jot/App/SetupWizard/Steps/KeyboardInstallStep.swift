//
//  KeyboardInstallStep.swift
//  Jot
//
//  Phase 6 — wizard panel W4.
//  Sends the user to System Settings to add Jot as a keyboard, then
//  auto-detects when they return by inspecting
//  `UITextInputMode.activeInputModes` for the Jot keyboard identifier.
//

import SwiftUI
import UIKit

struct KeyboardInstallStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    /// Bundle identifier of the JotKeyboard extension. Used to detect
    /// whether the user has added the keyboard in Settings.
    private static let keyboardBundleID = "com.vineetu.jot.mobile.Jot.Keyboard"

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardInstalled = false

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 3), onClose: onClose)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                keyboardTile
                    .padding(.bottom, 4)

                WizardTitle(text: titleText)

                WizardBody(text: "iOS Settings → General → Keyboard → Keyboards → Add New Keyboard → Jot.")

                WizardItalicNote(text: "We'll detect when you're back.")

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(
                title: keyboardInstalled ? "Continue" : "Open Settings",
                action: {
                    if keyboardInstalled {
                        onAdvance()
                    } else {
                        openSettings()
                    }
                }
            )
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
        keyboardInstalled ? "Jot keyboard installed" : "Add Jot as a keyboard"
    }

    // MARK: - Tile

    private var keyboardTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 1.0),
                            Color(red: 0.949, green: 0.941, blue: 0.922)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.8), lineWidth: 0.5)
                .blendMode(.plusLighter)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)

            // Stylized keyboard pictogram: three top rows of light pips + a
            // coral space bar.
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(Color.jotInk.opacity(row == 0 ? 0.85 : 0.35))
                                .frame(width: 6, height: 5)
                        }
                    }
                }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.jotAccent)
                    .frame(width: 26, height: 5)
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 8)
        .accessibilityHidden(true)
    }

    // MARK: - Detection

    /// Returns true iff the user has added the Jot keyboard in System
    /// Settings. Reads from `UITextInputMode.activeInputModes`, which is
    /// the public surface for "keyboards the user has enabled for typing"
    /// — it does NOT require Full Access (W5 handles that).
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
