//
//  MicStep.swift
//  Jot
//
//  Phase 6 — wizard panel W2.
//  Coral 92pt mic IconBox + "Let Jot hear you" + iOS mic permission
//  request. Auto-advances on grant.
//

@preconcurrency import AVFAudio
import SwiftUI
import UIKit

struct MicStep: View {
    let onClose: () -> Void
    /// Non-nil — Mic is always W2 (never the first step), so a back
    /// affordance always exists. Threaded into `WizardHeader` so the
    /// shared chrome renders the back chevron + edge-swipe gesture.
    let onBack: () -> Void
    let allowsAutoAdvance: Bool
    let onAdvance: () -> Void

    @State private var permission: AVAudioApplication.recordPermission =
        AVAudioApplication.shared.recordPermission
    @State private var isRequesting = false
    /// Local defense-in-depth for this view instance. The parent also
    /// owns `micAutoAdvanceConsumed` so re-entry cannot auto-advance twice.
    @State private var didAutoAdvance = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 1), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 28) {
                Spacer(minLength: 60)

                coralMicTile
                    .padding(.bottom, 8)

                WizardItalicTitle(text: titleText)

                WizardBody(text: bodyText)

                Spacer(minLength: 20)
            }
        } footer: {
            WizardPrimaryButton(
                title: primaryTitle,
                isDisabled: isRequesting,
                action: primaryAction
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
            }
        }
        .task {
            refresh()
            // If the user has already granted permission, auto-advance
            // straight through W2 — they don't need to see the prompt.
            if permission == .granted, allowsAutoAdvance, !didAutoAdvance {
                didAutoAdvance = true
                onAdvance()
            }
        }
    }

    // MARK: - State copy

    private var titleText: String {
        switch permission {
        case .denied: return "Microphone access is off"
        default: return "Let Jot hear you"
        }
    }

    private var bodyText: String {
        switch permission {
        case .denied:
            return "Turn microphone access on in Settings, then come back."
        default:
            return "Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded."
        }
    }

    private var primaryTitle: String {
        switch permission {
        case .granted: return "Continue"
        case .denied: return "Open Settings"
        case .undetermined: return isRequesting ? "Requesting…" : "Grant microphone"
        @unknown default: return "Grant microphone"
        }
    }

    private var primaryAction: () -> Void {
        switch permission {
        case .granted: return onAdvance
        case .denied: return openSettings
        case .undetermined: return request
        @unknown default: return request
        }
    }

    // MARK: - Tile

    private var coralMicTile: some View {
        IconTile(
            systemImage: "mic.fill",
            tint: JotDesign.JotSemanticIcon.privacyMicReady,
            shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded,
            size: JotDesign.Spacing.tileHeroSize
        )
        .accessibilityHidden(true)
    }

    // MARK: - Permission flow

    private func refresh() {
        permission = AVAudioApplication.shared.recordPermission
    }

    private func request() {
        guard !isRequesting else { return }
        isRequesting = true
        Task { @MainActor in
            _ = await AVAudioApplication.requestRecordPermission()
            refresh()
            isRequesting = false
            if permission == .granted {
                didAutoAdvance = true
                onAdvance()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#Preview {
    MicStep(onClose: {}, onBack: {}, allowsAutoAdvance: true, onAdvance: {})
}
