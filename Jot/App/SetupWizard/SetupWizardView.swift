@preconcurrency import AVFAudio
import SwiftUI
import UIKit

struct SetupWizardView: View {
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(\.openURL) private var openURL

    let onComplete: () -> Void

    @State private var step: SetupStep = .welcome
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var isRequestingMicrophone = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader

                Spacer(minLength: 24)

                Group {
                    switch step {
                    case .welcome:
                        WelcomeStep {
                            advance(to: .microphone)
                        }
                    case .microphone:
                        MicrophoneStep(
                            permission: microphonePermission,
                            isRequesting: isRequestingMicrophone,
                            requestPermission: requestMicrophonePermission,
                            openSettings: openSystemSettings,
                            continueAction: { advance(to: .model) }
                        )
                    case .model:
                        ModelDownloadStep(
                            modelState: transcriptionService.modelState,
                            startDownload: startModelDownload,
                            continueAction: { advance(to: .done) }
                        )
                        .task {
                            if transcriptionService.modelState == .notLoaded {
                                startModelDownload()
                            }
                        }
                    case .done:
                        DoneStep {
                            SetupCompletion.markCompleted()
                            onComplete()
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                refreshMicrophonePermission()
            }
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases) { item in
                Capsule()
                    .fill(item.index <= step.index ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance(to next: SetupStep) {
        withAnimation(.easeInOut(duration: 0.2)) {
            step = next
        }
    }

    private func refreshMicrophonePermission() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    private func requestMicrophonePermission() {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true

        Task { @MainActor in
            _ = await AVAudioApplication.requestRecordPermission()
            refreshMicrophonePermission()
            isRequestingMicrophone = false

            if microphonePermission == .granted {
                advance(to: .model)
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func startModelDownload() {
        transcriptionService.warmUp()
    }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case welcome
    case microphone
    case model
    case done

    var id: String { rawValue }

    var index: Int {
        switch self {
        case .welcome: return 0
        case .microphone: return 1
        case .model: return 2
        case .done: return 3
        }
    }
}

private struct WelcomeStep: View {
    let continueAction: () -> Void

    var body: some View {
        WizardCard(
            systemImage: "mic.fill",
            title: "Welcome to Jot",
            message: "Speak. It's written. Jot records and transcribes entirely on this iPhone.",
            primaryTitle: "Get Started",
            primaryAction: continueAction
        )
    }
}

private struct MicrophoneStep: View {
    let permission: AVAudioApplication.recordPermission
    let isRequesting: Bool
    let requestPermission: () -> Void
    let openSettings: () -> Void
    let continueAction: () -> Void

    var body: some View {
        WizardCard(
            systemImage: symbol,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            primaryAction: primaryAction,
            primaryDisabled: isRequesting,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction,
            accessory: {
                if isRequesting {
                    ProgressView()
                } else {
                    EmptyView()
                }
            }
        )
    }

    private var symbol: String {
        switch permission {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "mic.slash.fill"
        case .undetermined: return "mic.fill"
        @unknown default: return "mic.fill"
        }
    }

    private var title: String {
        switch permission {
        case .granted: return "Microphone Ready"
        case .denied: return "Microphone Access Off"
        case .undetermined: return "Allow Microphone"
        @unknown default: return "Allow Microphone"
        }
    }

    private var message: String {
        switch permission {
        case .granted:
            return "Jot can record your voice. Audio stays on this iPhone."
        case .denied:
            return "Turn microphone access on in Settings before recording."
        case .undetermined:
            return "Jot needs the microphone to capture dictation. Audio is transcribed on device."
        @unknown default:
            return "Jot needs microphone access to capture dictation."
        }
    }

    private var primaryTitle: String {
        switch permission {
        case .granted: return "Continue"
        case .denied: return "Open Settings"
        case .undetermined: return isRequesting ? "Requesting..." : "Allow Microphone"
        @unknown default: return "Allow Microphone"
        }
    }

    private var primaryAction: () -> Void {
        switch permission {
        case .granted: return continueAction
        case .denied: return openSettings
        case .undetermined: return requestPermission
        @unknown default: return requestPermission
        }
    }

    private var secondaryTitle: String? {
        nil
    }

    private var secondaryAction: (() -> Void)? {
        nil
    }
}

private struct ModelDownloadStep: View {
    let modelState: TranscriptionService.ModelState
    let startDownload: () -> Void
    let continueAction: () -> Void

    var body: some View {
        WizardCard(
            systemImage: symbol,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            primaryAction: primaryAction,
            primaryDisabled: primaryDisabled,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction,
            accessory: {
                accessory
            }
        )
    }

    @ViewBuilder
    private var accessory: some View {
        switch modelState {
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .loading:
            ProgressView()
        default:
            EmptyView()
        }
    }

    private var symbol: String {
        switch modelState {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading, .loading: return "arrow.down.circle.fill"
        case .notLoaded: return "square.and.arrow.down.fill"
        }
    }

    private var title: String {
        switch modelState {
        case .ready: return "Speech Model Installed"
        case .failed: return "Download Failed"
        case .loading: return "Preparing Speech Model"
        case .downloading: return "Downloading Parakeet"
        case .notLoaded: return "Download Parakeet"
        }
    }

    private var message: String {
        switch modelState {
        case .ready:
            return "Parakeet is ready for English dictation."
        case .failed(let reason):
            return reason
        case .loading:
            return "Loading the on-device speech model."
        case .downloading:
            return "About 1.25 GB. Keep Jot open until the first download finishes."
        case .notLoaded:
            return "Jot needs the on-device Parakeet model for private English transcription."
        }
    }

    private var primaryTitle: String {
        switch modelState {
        case .ready: return "Continue"
        case .failed: return "Retry Download"
        case .notLoaded: return "Download Parakeet"
        case .downloading: return "Downloading..."
        case .loading: return "Preparing..."
        }
    }

    private var primaryAction: () -> Void {
        switch modelState {
        case .ready: return continueAction
        case .failed, .notLoaded: return startDownload
        case .downloading, .loading: return {}
        }
    }

    private var primaryDisabled: Bool {
        switch modelState {
        case .downloading, .loading: return true
        case .notLoaded, .failed, .ready: return false
        }
    }

    private var secondaryTitle: String? {
        nil
    }

    private var secondaryAction: (() -> Void)? {
        nil
    }
}

private struct DoneStep: View {
    let finishAction: () -> Void

    var body: some View {
        WizardCard(
            systemImage: "checkmark.circle.fill",
            title: "You're Set Up",
            message: "Tap the mic to dictate. You can re-run setup any time from Settings.",
            primaryTitle: "Take Me to Jot",
            primaryAction: finishAction
        )
    }
}

private struct WizardCard<Accessory: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    var primaryDisabled = false
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)

            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accessory()
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }

                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(primaryDisabled)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension WizardCard where Accessory == EmptyView {
    init(
        systemImage: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        primaryDisabled: Bool = false,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.primaryDisabled = primaryDisabled
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.accessory = { EmptyView() }
    }
}

#Preview {
    SetupWizardView {}
        .environment(TranscriptionService())
}
