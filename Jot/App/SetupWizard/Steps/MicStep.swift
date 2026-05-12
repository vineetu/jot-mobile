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
    let onAdvance: () -> Void

    @State private var permission: AVAudioApplication.recordPermission =
        AVAudioApplication.shared.recordPermission
    @State private var isRequesting = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 1), onClose: onClose)
        ) {
            VStack(spacing: 28) {
                Spacer(minLength: 60)

                coralMicTile
                    .padding(.bottom, 8)

                WizardTitle(text: titleText)

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
            if permission == .granted {
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
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: "mic.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
        .shadow(
            color: Color(red: 1.00, green: 0.23, blue: 0.19).opacity(0.35),
            radius: 15,
            x: 0,
            y: 10
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
    MicStep(onClose: {}, onAdvance: {})
}
