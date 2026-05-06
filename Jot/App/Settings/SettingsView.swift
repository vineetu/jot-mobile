import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcriptionService
    @State private var showRedownloadConfirmation = false
    /// Mirror of `AppGroup.liveActivityTranscriptEnabled`. SwiftUI's `Toggle`
    /// needs a `Binding`; we read the AppGroup value into local `@State` on
    /// appear and write back via the binding's set side. Default `true`
    /// matches the AppGroup accessor's missing-key default so first-launch
    /// flips to `true` without an explicit write and the toggle reads ON
    /// immediately.
    @State private var liveActivityTranscriptEnabled: Bool = AppGroup.liveActivityTranscriptEnabled

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: transcriptionService.speechModelIdentifier)

                    LabeledContent {
                        HStack(spacing: 8) {
                            Image(systemName: modelStatusSymbol)
                                .foregroundStyle(modelStatusColor)
                            Text(modelStatusText)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("Status")
                    }

                    Button {
                        handleModelAction()
                    } label: {
                        Label(modelActionTitle, systemImage: "arrow.down.circle")
                    }
                    .disabled(modelActionDisabled)
                } header: {
                    Text("Speech model")
                } footer: {
                    Text("Runs entirely on this iPhone. About 1.25 GB on disk.")
                }

                Section {
                    Toggle(isOn: $liveActivityTranscriptEnabled) {
                        Label("Show live transcript in Dynamic Island", systemImage: "captions.bubble")
                    }
                    .onChange(of: liveActivityTranscriptEnabled) { _, newValue in
                        AppGroup.liveActivityTranscriptEnabled = newValue
                    }
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("When off, the Dynamic Island and lock-screen banner show only the recording state, not the words you're speaking.")
                }

                Section {
                    NavigationLink {
                        AIRewriteSettingsView()
                    } label: {
                        Label("AI Rewrite", systemImage: "wand.and.stars")
                    }
                    .accessibilityHint("Configure the on-device language model and saved rewrite prompts")
                } header: {
                    Text("Rewrite")
                }

                Section {
                    Button {
                        SettingsRerunTrigger.shared.requestRerun()
                        dismiss()
                    } label: {
                        Label("Re-run setup wizard", systemImage: "arrow.clockwise")
                    }

                    LabeledContent("Version", value: versionString)

                    Label {
                        Text("Your words stay on your iPhone. No accounts, no cloud, no telemetry.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://jot.ideaflow.page/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "heart")
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Re-download speech model?",
                isPresented: $showRedownloadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Re-download", role: .destructive) {
                    Task {
                        await transcriptionService.purgeAndReload()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func handleModelAction() {
        if case .ready = transcriptionService.modelState {
            showRedownloadConfirmation = true
        } else {
            transcriptionService.warmUp()
        }
    }

    private var modelStatusText: String {
        switch transcriptionService.modelState {
        case .notLoaded:
            return "Not downloaded"
        case .downloading(let fraction):
            return "Downloading \(Int((fraction * 100).rounded()))%"
        case .loading:
            return "Loading"
        case .ready:
            return "Ready"
        case .failed(let reason):
            return reason
        }
    }

    private var modelStatusSymbol: String {
        switch transcriptionService.modelState {
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .downloading, .loading:
            return "arrow.down.circle.fill"
        case .notLoaded:
            return "circle"
        }
    }

    private var modelStatusColor: Color {
        switch transcriptionService.modelState {
        case .ready:
            return .green
        case .failed:
            return .orange
        case .downloading, .loading:
            return .accentColor
        case .notLoaded:
            return .secondary
        }
    }

    private var modelActionTitle: String {
        switch transcriptionService.modelState {
        case .ready:
            return "Re-download model"
        case .failed:
            return "Retry download"
        case .notLoaded:
            return "Download model"
        case .downloading:
            return "Downloading"
        case .loading:
            return "Loading"
        }
    }

    private var modelActionDisabled: Bool {
        switch transcriptionService.modelState {
        case .downloading, .loading:
            return true
        case .notLoaded, .failed, .ready:
            return false
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(TranscriptionService())
}
