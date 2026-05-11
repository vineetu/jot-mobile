import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingTranscriptionService.self) private var streamingService
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
                        Text("Parakeet 110M (lighter, faster)")
                            .tag("tdtCtc110m")
                    } label: {
                        Label("Variant", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .onChange(of: speechModelVariant) { _, newValue in
                        // Persist the new selection AND invalidate the
                        // currently-loaded manager so the next dictation
                        // rebuilds with the user-selected variant. Without
                        // this invalidation the loaded `manager` reference
                        // kept serving the OLD variant until app restart
                        // (`ensurePreparing` returns early when `manager != nil`).
                        AppGroup.speechModelVariant = newValue
                        transcriptionService.handleVariantChange()
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
                    Text(sizeFooter)
                }

                Section {
                    NavigationLink {
                        VocabularySettingsView()
                    } label: {
                        Label("Vocabulary", systemImage: "text.book.closed")
                    }
                    .accessibilityHint("Custom terms Jot should prefer during transcription")
                } header: {
                    Text("Vocabulary")
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
                "Re-download all models?",
                isPresented: $showRedownloadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Re-download", role: .destructive) {
                    Task {
                        await transcriptionService.purgeAndReload()
                        // Also ensure the streaming model is present after
                        // re-download. `purgeAndReload` only purges/reloads
                        // the batch model; EOU stays on disk. If the user
                        // had nuked EOU separately or it never landed,
                        // warmUp() is idempotent and picks it up.
                        streamingService.warmUp()
                        // Boost model — re-download bundled with the
                        // speech-model re-download under Option A
                        // (one tap covers everything). Idempotent.
                        _ = try? await CtcModelCache.shared.ensureLoaded()
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
            // Also ensure the streaming model is downloaded. EOU 120M is
            // bundled with the batch model under the same opt-in tap so
            // the live-caption strip works after a fresh install or a
            // post-purge re-download. Idempotent: a no-op if already on
            // disk + warmed.
            streamingService.warmUp()
            // CTC 110M boost model for vocabulary biasing — bundled into
            // the same explicit Download tap so the user doesn't see a
            // second download prompt later. Fire-and-forget; if it
            // fails, the Vocabulary pane's Boost-model Download button
            // is the retry surface.
            Task.detached {
                _ = try? await CtcModelCache.shared.ensureLoaded()
            }
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
        // "All models" wording reflects the Option A bundle: this single
        // tap pulls speech + EOU streaming + CTC boost. Setup wizard
        // size copy (~1.05 GB) is the authoritative byte disclosure
        // anchor; Settings-level re-download confirmation uses the same
        // unified language.
        switch transcriptionService.modelState {
        case .ready:
            return "Re-download all models"
        case .failed:
            return "Retry download"
        case .notLoaded:
            return "Download all models"
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

    private var sizeFooter: String {
        // Approximate on-disk sizes per variant — speech model only.
        // The setup wizard's ~1.05 GB number is the bundle (speech +
        // EOU + CTC boost); this Settings-footer figure is just the
        // speech-model variant the user chose, since the EOU and
        // boost models don't change when they flip the picker.
        //
        // TDT-CTC 110M total is ~330 MB on disk: ~220 MB primary repo
        // (FluidInference/parakeet-tdt-ctc-110m-coreml) + ~106 MB
        // auxiliary repo (FluidInference/parakeet-ctc-110m-coreml)
        // that FluidAudio's `AsrModels.load(.tdtCtc110m)` fetches in
        // the same call for the optional CTC head.
        switch speechModelVariant {
        case "tdtCtc110m": return "Runs entirely on this iPhone. About 330 MB on disk."
        default:           return "Runs entirely on this iPhone. About 700 MB on disk."
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
