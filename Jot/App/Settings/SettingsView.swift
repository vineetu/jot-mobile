import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcriptionService
    @State private var showRedownloadConfirmation = false

    /// Mirror of `AppGroup.speechModelVariant`. Picker tags are the FluidAudio
    /// `Repo` raw values resolved by `TranscriptionService.selectedVersion`
    /// at every `ensurePreparing()` boundary. A user flip here only takes
    /// effect on the NEXT dictation start — never mid-session — because the
    /// service snapshots the variant once at the top of `loadOrFail`. The
    /// in-flight pipeline (whose model handle is already loaded into ANE)
    /// continues running against the previous variant until the next stop.
    @State private var speechModelVariant: String = AppGroup.speechModelVariant

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $speechModelVariant) {
                        Text("Parakeet 600M (more accurate)")
                            .tag("parakeetV2")
                        Text("Parakeet 110M (lighter, custom words coming)")
                            .tag("tdtCtc110m")
                    } label: {
                        Label("Variant", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .onChange(of: speechModelVariant) { _, newValue in
                        // The new selection only takes effect on the NEXT
                        // dictation start. `TranscriptionService` re-resolves
                        // `selectedVersion` on each `ensurePreparing()` and
                        // snapshots once at the top of `loadOrFail` — so an
                        // in-flight session keeps running against whatever
                        // model it cold-loaded with.
                        AppGroup.speechModelVariant = newValue
                    }

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
