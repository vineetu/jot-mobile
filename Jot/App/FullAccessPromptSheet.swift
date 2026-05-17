//
//  FullAccessPromptSheet.swift
//  Jot
//
//  Explanatory sheet shown when the keyboard's locked-state pill
//  ("Enable Full Access") is tapped. The keyboard URL-bounces to
//  `jot://full-access`, the main app foregrounds, and this sheet
//  is what the user lands on — not iOS Settings directly. The user
//  reads why Full Access is required, sees the literal Settings
//  breadcrumb, then taps "Open Settings" to be deep-linked into the
//  iOS Settings app.
//
//  Visual style matches the W3 KeyboardInstallStep wizard panel
//  (WizardWallpaper, IconTile hero, italic serif headline, system
//  body), but the CTA uses the blue `Color.jotBlueTop` accent the
//  keyboard already uses for the Dictate pill — so the brand thread
//  from "the blue pill in the keyboard" to "the blue button you tap
//  to fix it" is visually continuous.
//

import SwiftUI
import UIKit

/// Presented by `JotApp` in response to `jot://full-access`.
///
/// Wrapped in its own dismiss action: the sheet owns its lifecycle
/// via the binding the caller passes in. The "Open Settings" button
/// dismisses the sheet AND opens iOS Settings (the user will be in
/// Settings when they come back, so leaving the sheet open behind
/// them would feel stale).
struct FullAccessPromptSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            WizardWallpaper()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top-right close affordance mirrors the wizard chrome
                // so the sheet doesn't feel like a foreign surface
                // bolted onto the app.
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Spacer(minLength: 24)

                ScrollView {
                    VStack(spacing: 22) {
                        lockTile

                        WizardItalicTitle(text: "Allow Full Access")

                        WizardBody(
                            text: "Jot's keyboard pastes your dictations into other apps. iOS only lets keyboards do that when Full Access is on — it stays on your device and Jot never sends what you type anywhere."
                        )

                        breadcrumb
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)
                }
                .scrollBounceBehavior(.basedOnSize)

                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    openSettingsButton

                    Button {
                        isPresented = false
                    } label: {
                        Text("Not now")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.jotMute)
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)

                WizardHomeIndicator()
            }
        }
    }

    // MARK: - Hero tile

    private var lockTile: some View {
        // Matches W3's hero size; uses the blue token pair so the visual
        // ties to the keyboard's blue lock pill the user just tapped.
        IconTile(
            systemImage: "lock.shield.fill",
            tint: Color.jotBlueTop,
            shaded: Color.jotBlueBottom,
            size: JotDesign.Spacing.tileHeroSize
        )
        .accessibilityHidden(true)
    }

    // MARK: - Breadcrumb

    /// The exact iOS Settings path the user will need to walk after
    /// tapping "Open Settings". Monospaced so it reads as a literal
    /// system path, with chevron separators between each step.
    private var breadcrumb: some View {
        Text("Settings → General → Keyboard → Keyboards → Jot Keyboard → Allow Full Access")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.jotPageInkCaption)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .accessibilityLabel("Settings, then General, then Keyboard, then Keyboards, then Jot Keyboard, then Allow Full Access")
    }

    // MARK: - CTA

    private var openSettingsButton: some View {
        Button(action: openSettings) {
            HStack(spacing: 10) {
                Image(systemName: "gear")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Open Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.jotBlueTop, Color.jotBlueBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .inset(by: 0.5)
                    .stroke(Color.white.opacity(0.40), lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.jotBlueTop.opacity(0.35), radius: 10, x: 0, y: 8)
            .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel("Open Settings")
        .accessibilityHint("Opens the iOS Settings app at Jot's settings page so you can grant Full Access.")
    }

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .padding(8)
        }
        .accessibilityLabel("Close")
    }

    // MARK: - Actions

    /// Dismiss the sheet, then open iOS Settings on the next runloop tick
    /// so the dismiss animation isn't fighting the app-switch transition.
    private func openSettings() {
        isPresented = false
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}

#if DEBUG
#Preview {
    StatefulPreviewWrapper(true) { binding in
        FullAccessPromptSheet(isPresented: binding)
    }
}

/// Tiny helper that gives `#Preview` a mutable `Binding<Value>` without
/// pulling in a full `@State` host view.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
#endif
