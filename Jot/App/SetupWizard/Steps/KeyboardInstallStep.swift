//
//  KeyboardInstallStep.swift
//  Jot
//
//  Phase 6 — wizard panel W3 (renumbered from W4 after the bundled-Parakeet
//  ship retired the standalone speech-model download step).
//  Sends the user to System Settings to add Jot as a keyboard and enable
//  Full Access in one trip. Both signals are auto-detected on return:
//  keyboard installation via `UITextInputMode.activeInputModes`, and Full
//  Access via the `AppGroup.keyboardHasFullAccess` mirror the keyboard
//  extension writes on every presentation. Caveat: the FA mirror requires
//  the user to have presented the Jot keyboard at least once after
//  enabling Full Access (iOS gives the main app no direct API).
//

import SwiftUI
import UIKit

struct KeyboardInstallStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void
    /// Parent-owned permission for the first-mount auto-skip. The parent
    /// flips this to `false` after the first forward advance so that
    /// back-navigation from W4 doesn't re-skip the user forward — the
    /// pattern mirrors `MicStep.allowsAutoAdvance`. See
    /// `SetupWizardView.keyboardAutoAdvanceConsumed`.
    let allowsAutoAdvance: Bool

    /// Bundle identifier of the JotKeyboard extension. Used to detect
    /// whether the user has added the keyboard in Settings.
    private static let keyboardBundleID = "com.vineetu.jot.mobile.Jot.Keyboard"

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardInstalled = false
    @State private var fullAccessGranted = false

    /// Both signals are required to consider setup complete. Either
    /// missing → show the "Open Keyboard Settings" default state with
    /// no special-case copy; the user does one trip to Settings and
    /// returns with both flipped.
    private var isReady: Bool { keyboardInstalled && fullAccessGranted }

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

                WizardItalicNote(text: "We'll detect both the keyboard and Full Access when you're back.")

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(
                title: isReady ? "Continue" : "Open Keyboard Settings",
                action: {
                    if isReady {
                        onAdvance()
                    } else {
                        openSettings()
                    }
                }
            )

            WizardSecondaryTextButton(title: "I've already done this", action: onAdvance)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
            }
        }
        .task {
            refresh()
            // First-mount-only auto-advance: returning users who already
            // installed the keyboard and granted Full Access should never
            // see W3. Gated on `allowsAutoAdvance` (owned by the parent
            // wizard so back-navigation from W4 doesn't re-skip), and
            // gated on `.task` (not the scenePhase refresh) so an
            // in-session Settings round-trip still surfaces the "Jot
            // keyboard detected → Continue" state rather than silently
            // jumping the user forward.
            if allowsAutoAdvance && keyboardInstalled && fullAccessGranted {
                onAdvance()
            }
        }
    }

    private var titleText: String {
        isReady ? "Jot keyboard detected" : "Set up Jot Keyboard"
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
        let fa = AppGroup.keyboardHasFullAccess
        if fa != fullAccessGranted {
            fullAccessGranted = fa
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
