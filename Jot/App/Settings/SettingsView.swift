import SwiftUI

/// Phase 5 — Settings main (mockup 15).
///
/// Reflowed from the original `Form`-based layout into editorial chrome:
/// a Fraunces "Settings" 32pt header + glass Done pill at the top, then
/// stacked `GlassCard(.regular)` sections in the order
/// SPEECH MODEL → VOCABULARY → AI → PRIVACY → ABOUT.
///
/// The full speech-model variant picker + re-download confirmation moved
/// into a dedicated `SpeechModelVariantPicker` pushed onto the nav stack
/// via the "Variant" chevron row inside the SPEECH MODEL card. The main
/// settings page only surfaces the active model name + status pill +
/// size footer + the Variant chevron — the picker view owns variant
/// selection, the re-download confirmation dialog, and the status detail.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingTranscriptionService.self) private var streamingService
    @Environment(RecordingService.self) private var recordingService

    /// Called from `handleRerunSetupTap` BEFORE this sheet dismisses so the
    /// host (ContentView) can latch a "fire rerun once the sheet has fully
    /// torn down" flag. The actual `SettingsRerunTrigger.requestRerun()` is
    /// deferred until the sheet's `onDismiss` runs — guessing at the dismiss
    /// animation length with `DispatchQueue.main.async` is the dual-modal
    /// crash path we're avoiding.
    var onRerunRequested: (() -> Void)? = nil

    /// Mirror of `AppGroup.speechModelVariant` — read on appear so the
    /// SPEECH MODEL card footer reflects the active variant's on-disk size.
    @State private var speechModelVariant: String = AppGroup.speechModelVariant

    /// Mirror of `AppGroup.warmHoldEnabled` for the Privacy kill-switch.
    @State private var warmHoldEnabled: Bool = AppGroup.warmHoldEnabled

    /// Vocabulary store — the SPEECH MODEL chevron sub-screen + the
    /// VOCABULARY card row both observe `terms.count`.
    @State private var vocabularyStore = VocabularyStore.shared

    /// LLM adapter for the AI-row's sub-status. Resolved lazily on appear;
    /// `nil` until then. Lives only for the lifetime of the Settings sheet
    /// so we don't pin Phi-4 weights in memory when the user just glanced
    /// at Settings.
    @State private var clientAdapter: LLMClientUIAdapter?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {
                    editorialHeader

                    speechModelSection
                    vocabularySection
                    aiSection
                    privacySection
                    aboutSection

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 8)
            }
            .background(JotDesign.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear {
                speechModelVariant = AppGroup.speechModelVariant
                warmHoldEnabled = AppGroup.warmHoldEnabled
                vocabularyStore.load()
                if clientAdapter == nil {
                    let client = LLMClientFactory.shared.client()
                    let adapter = LLMClientUIAdapter(client: client)
                    adapter.start()
                    clientAdapter = adapter
                }
            }
            .onDisappear {
                clientAdapter?.stop()
            }
            .onChange(of: warmHoldEnabled) { _, newValue in
                AppGroup.warmHoldEnabled = newValue
            }
        }
    }

    // MARK: - Editorial header

    private var editorialHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Settings")
                .font(.custom(JotType.frauncesSemiBold, size: 32))
                .foregroundStyle(Color.jotInk)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("Done")
            .accessibilityHint("Dismisses Settings")
        }
        .padding(.top, 4)
    }

    // MARK: - SPEECH MODEL

    private var speechModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("SPEECH MODEL")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        IconBox(
                            symbol: "waveform.badge.magnifyingglass",
                            tint: Color.blue,
                            size: 44
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(speechModelDisplayName)
                                .font(.custom(JotType.frauncesSemiBold, size: 18))
                                .foregroundStyle(Color.jotInk)
                            Text(speechModelLocationCopy)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.jotMute)
                        }

                        Spacer()

                        speechModelStatusPill
                    }

                    Divider().opacity(0.4)

                    NavigationLink {
                        SpeechModelVariantPicker()
                            .environment(transcriptionService)
                            .environment(streamingService)
                    } label: {
                        HStack(spacing: 10) {
                            Text("Variant")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.jotInk)
                            Spacer()
                            Text(variantShortName)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.jotMute)
                            RowChevron()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Variant, currently \(variantShortName)")
                    .accessibilityHint("Opens variant picker")
                }
            }

            Text(speechModelFooter)
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    private var speechModelDisplayName: String {
        switch speechModelVariant {
        case "tdtCtc110m": return "Parakeet TDT-CTC 110M"
        default:           return "Parakeet TDT"
        }
    }

    private var variantShortName: String {
        switch speechModelVariant {
        case "tdtCtc110m": return "TDT-CTC 110M"
        default:           return "Parakeet 600M"
        }
    }

    private var speechModelLocationCopy: String {
        // Sentence-form per plan §8 — "About 700 MB" not "1.5 GB".
        switch speechModelVariant {
        case "tdtCtc110m": return "On your iPhone · about 330 MB"
        default:           return "On your iPhone · about 700 MB"
        }
    }

    private var speechModelFooter: String {
        "Runs entirely on this iPhone. Audio never leaves the device."
    }

    /// "Installed" gate for the SPEECH MODEL display. Mirrors the 3-way AND
    /// pattern in `SpeechModelStep.modelAlreadyOnDisk` so Settings doesn't
    /// say "Not downloaded" when the bundles are on disk but Parakeet hasn't
    /// been warmed into ANE yet (e.g. user opened Settings before recording).
    /// Gating on bare `modelState == .ready` is wrong here — that flag is
    /// the "warmed into ANE for recording" signal, not the "is the model
    /// installed" signal.
    private var speechModelInstalled: Bool {
        TranscriptionService.modelsExistOnDiskForSelectedVariant()
            && StreamingTranscriptionService.modelsExistOnDisk()
            && CtcModelCache.shared.isCached
    }

    @ViewBuilder
    private var speechModelStatusPill: some View {
        // In-progress states win over the on-disk probe: if a download or
        // load is happening right now, surface the live progress chrome.
        switch transcriptionService.modelState {
        case .downloading(let fraction):
            StatusPill(label: "\(Int((fraction * 100).rounded()))%", tint: .info)
        case .loading:
            StatusPill(label: "Loading", tint: .info)
        case .failed where !speechModelInstalled:
            // Surface failures only when the bundles aren't already on disk
            // — a stale failure flag is not a reason to mislead the user
            // into thinking the model is missing.
            StatusPill(label: "Error", tint: .warning)
        case .ready, .notLoaded, .failed:
            if speechModelInstalled {
                StatusPill(label: "Ready", tint: .success)
            } else {
                StatusPill(label: "Not downloaded", tint: .warning)
            }
        }
    }

    // MARK: - VOCABULARY

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("VOCABULARY")
                .padding(.horizontal, 4)

            NavigationLink {
                VocabularySettingsView()
            } label: {
                GlassCard(tier: .regular, padding: 14) {
                    HStack(spacing: 14) {
                        IconBox(
                            symbol: "text.book.closed",
                            tint: Color.teal,
                            size: 36
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Custom terms")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.jotInk)
                            Text(vocabularySubline)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.jotMute)
                        }

                        Spacer()
                        RowChevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom terms, \(vocabularyStore.terms.count) entries")
            .accessibilityHint("Opens the vocabulary list")

            Text("Bias the speech model toward names, technical terms, and words Jot tends to mishear.")
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    private var vocabularySubline: String {
        let n = vocabularyStore.terms.count
        return n == 1 ? "1 term · on this iPhone" : "\(n) terms · on this iPhone"
    }

    // MARK: - AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("AI")
                .padding(.horizontal, 4)

            NavigationLink {
                AIRewriteSettingsView()
            } label: {
                GlassCard(tier: .regular, padding: 14) {
                    HStack(spacing: 14) {
                        IconBox(
                            symbol: "wand.and.stars",
                            tint: Color.jotAccent,
                            size: 36
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Rewrite & prompts")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.jotInk)
                            Text(aiSubline)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.jotMute)
                        }

                        Spacer()
                        RowChevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rewrite and prompts, \(aiSubline)")
            .accessibilityHint("Opens AI Rewrite settings")

            Text("Titles and tags use the system's built-in AI automatically.")
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    private var aiSubline: String {
        let modelName = JotDesign.activeRewriteModelDisplayName
        let status: String
        switch clientAdapter?.observableStatus ?? .notReady {
        case .ready:               status = "Ready"
        case .loading:             status = "Loading"
        case .downloading(let f):  status = "Downloading \(Int((f * 100).rounded()))%"
        case .evicted:             status = "Unloaded"
        case .error:               status = "Error"
        case .notReady:            status = AppGroup.aiRewriteEnabled ? "Tap to download" : "Off"
        }
        return "\(modelName) · \(status)"
    }

    // MARK: - PRIVACY

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("PRIVACY")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 14) {
                VStack(spacing: 0) {
                    privacyRow(
                        symbol: "iphone",
                        tint: Color.green,
                        title: "On-device only",
                        value: "Always",
                        showDivider: true
                    )

                    privacyRow(
                        symbol: "lock.shield",
                        tint: Color.indigo,
                        title: "Full Access",
                        value: "Required for paste",
                        statusLabel: "Enabled",
                        showDivider: true
                    )

                    privacyToggleRow(
                        symbol: "mic",
                        tint: Color.orange,
                        title: "Keep mic ready",
                        value: "Skips cold-start latency for repeat dictations within 60 seconds. " +
                            "While ready, the iOS orange microphone indicator stays on — the audio session is active but Jot is not transcribing.",
                        isOn: $warmHoldEnabled,
                        showDivider: false
                    )
                }
            }

            Text("Your words stay on your iPhone. No accounts, no cloud, no telemetry.")
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func privacyRow(
        symbol: String,
        tint: Color,
        title: String,
        value: String,
        statusLabel: String? = nil,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBox(symbol: symbol, tint: tint, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.jotInk)
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                }

                Spacer()

                if let statusLabel {
                    StatusPill(label: statusLabel, tint: .success)
                } else {
                    StatusPill(label: "Always", tint: .success)
                }
            }
            .frame(minHeight: 44)
            .padding(.vertical, 6)

            if showDivider {
                Divider().opacity(0.4)
            }
        }
    }

    @ViewBuilder
    private func privacyToggleRow(
        symbol: String,
        tint: Color,
        title: String,
        value: String,
        isOn: Binding<Bool>,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            Toggle(isOn: isOn) {
                HStack(spacing: 12) {
                    IconBox(symbol: symbol, tint: tint, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.jotInk)
                        Text(value)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.jotMute)
                    }
                }
            }
            .tint(.jotAccent)
            .frame(minHeight: 44)
            .padding(.vertical, 6)

            if showDivider {
                Divider().opacity(0.4)
            }
        }
    }

    // MARK: - ABOUT

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("ABOUT")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                VStack(spacing: 0) {
                    // Help & Support sits at the top of ABOUT — it's the
                    // first row a confused user will scroll for, and the
                    // mirror to the home header's "?" sheet entry point.
                    NavigationLink {
                        HelpView()
                    } label: {
                        aboutRowBody(
                            symbol: "questionmark.circle",
                            tint: Color.teal,
                            title: "Help & Support",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4).padding(.leading, 56)

                    aboutRow(
                        symbol: "arrow.clockwise",
                        tint: Color.blue,
                        title: "Re-run setup wizard",
                        trailing: { RowChevron() },
                        action: handleRerunSetupTap
                    )
                    Divider().opacity(0.4).padding(.leading, 56)

                    aboutLink(
                        symbol: "envelope",
                        tint: Color.indigo,
                        title: "Send feedback",
                        destination: URL(string: "mailto:feedback@jot.app?subject=Jot%20iOS%20Feedback")!
                    )
                    Divider().opacity(0.4).padding(.leading, 56)

                    aboutRow(
                        symbol: "info.circle",
                        tint: Color.gray,
                        title: "Version",
                        trailing: {
                            Text(versionString)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.jotMute)
                        },
                        action: {}
                    )
                    Divider().opacity(0.4).padding(.leading, 56)

                    aboutLink(
                        symbol: "hand.raised",
                        tint: Color.purple,
                        title: "Privacy Policy",
                        destination: URL(string: "https://jot.ideaflow.page/privacy")!
                    )
                    Divider().opacity(0.4).padding(.leading, 56)

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        aboutRowBody(
                            symbol: "heart",
                            tint: Color.pink,
                            title: "Acknowledgements",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)

                    #if DEBUG
                    Divider().opacity(0.4).padding(.leading, 56)

                    NavigationLink {
                        JotDesignCatalog()
                    } label: {
                        aboutRowBody(
                            symbol: "paintpalette",
                            tint: Color.orange,
                            title: "Design catalog (debug)",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }

            Text("Made with care in San Francisco. No accounts, no cloud, no telemetry.")
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func aboutRow<Trailing: View>(
        symbol: String,
        tint: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            aboutRowBody(symbol: symbol, tint: tint, title: title, trailing: trailing)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aboutLink(
        symbol: String,
        tint: Color,
        title: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            aboutRowBody(
                symbol: symbol,
                tint: tint,
                title: title,
                trailing: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jotMuteWeak)
                }
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aboutRowBody<Trailing: View>(
        symbol: String,
        tint: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            IconBox(symbol: symbol, tint: tint, size: 30)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Color.jotInk)
            Spacer()
            trailing()
        }
        .frame(minHeight: 44)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Misc

    /// Re-run setup wizard tap handler. Order is load-bearing: SwiftUI
    /// will crash / log a "tried to present X on Y while Y is presenting
    /// Z" violation if we ask `JotApp` to raise the wizard's fullScreenCover
    /// while this Settings sheet is still up. Latching a flag on the host
    /// via `onRerunRequested` and firing the trigger from the host's sheet
    /// `onDismiss` is the deterministic fix — `DispatchQueue.main.async`
    /// only buys one runloop turn, which isn't guaranteed to outlast the
    /// ~300ms dismiss animation. Also stop any in-flight recording so the
    /// wizard's W7 in-app dictation test doesn't collide with a live engine.
    private func handleRerunSetupTap() {
        if recordingService.isRecording {
            recordingService.forceStop()
        }
        onRerunRequested?()
        dismiss()
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Speech model variant picker (pushed from the SPEECH MODEL chevron)

/// Detail screen that owns variant selection + the re-download confirmation.
/// Previously these controls lived inline inside `SettingsView`'s `Form`; the
/// editorial reflow moves them behind the SPEECH MODEL card's "Variant"
/// chevron row so the main settings page stays single-glance.
struct SpeechModelVariantPicker: View {
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingTranscriptionService.self) private var streamingService

    @State private var speechModelVariant: String = AppGroup.speechModelVariant
    @State private var showRedownloadConfirmation = false

    var body: some View {
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
                .pickerStyle(.inline)
                .onChange(of: speechModelVariant) { _, newValue in
                    AppGroup.speechModelVariant = newValue
                    transcriptionService.handleVariantChange()
                }
            } header: {
                Text("Variant")
            } footer: {
                Text(sizeFooter)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Image(systemName: modelStatusSymbol)
                            .foregroundStyle(modelStatusColor)
                        Text(modelStatusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    handleModelAction()
                } label: {
                    Label(modelActionTitle, systemImage: "arrow.down.circle")
                }
                .disabled(modelActionDisabled)
            } header: {
                Text("Model")
            }
        }
        .navigationTitle("Variant")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Re-download all models?",
            isPresented: $showRedownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-download", role: .destructive) {
                Task {
                    await transcriptionService.purgeAndReload()
                    streamingService.warmUp()
                    _ = try? await CtcModelCache.shared.ensureLoaded()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // The state-driven copy below mirrors the original `SettingsView` —
    // identical logic, identical wording. The reflow only moves these
    // affordances into a sub-screen; behavior is preserved exactly.

    /// Same 3-way AND gate as `SettingsView.speechModelInstalled`. Used to
    /// decide "is the model installed" independent of whether Parakeet has
    /// been warmed into ANE this session. Without this gate the picker
    /// would say "Not downloaded" + offer "Download all models" when the
    /// bundles are clearly on disk (and dictation is working).
    private var speechModelInstalled: Bool {
        TranscriptionService.modelsExistOnDiskForSelectedVariant()
            && StreamingTranscriptionService.modelsExistOnDisk()
            && CtcModelCache.shared.isCached
    }

    private func handleModelAction() {
        // Gate the re-download confirmation on the on-disk probe, not on
        // `modelState == .ready` — otherwise an un-warmed but installed
        // model would route through the cold-download path and re-fetch
        // bundles already on disk.
        if speechModelInstalled {
            showRedownloadConfirmation = true
        } else {
            transcriptionService.warmUp()
            streamingService.warmUp()
            Task.detached {
                _ = try? await CtcModelCache.shared.ensureLoaded()
            }
        }
    }

    private var modelStatusText: String {
        // Live-progress states still win — show the actual download/load
        // percent rather than a stale "Ready" pill from a previous session.
        switch transcriptionService.modelState {
        case .downloading(let fraction):
            return "Downloading \(Int((fraction * 100).rounded()))%"
        case .loading:
            return "Loading"
        case .failed(let reason) where !speechModelInstalled:
            return reason
        case .ready, .notLoaded, .failed:
            return speechModelInstalled ? "Ready" : "Not downloaded"
        }
    }

    private var modelStatusSymbol: String {
        switch transcriptionService.modelState {
        case .downloading, .loading:
            return "arrow.down.circle.fill"
        case .failed where !speechModelInstalled:
            return "exclamationmark.triangle.fill"
        case .ready, .notLoaded, .failed:
            return speechModelInstalled ? "checkmark.circle.fill" : "circle"
        }
    }

    private var modelStatusColor: Color {
        switch transcriptionService.modelState {
        case .downloading, .loading:
            return .accentColor
        case .failed where !speechModelInstalled:
            return .orange
        case .ready, .notLoaded, .failed:
            return speechModelInstalled ? .green : .secondary
        }
    }

    private var modelActionTitle: String {
        switch transcriptionService.modelState {
        case .downloading:
            return "Downloading"
        case .loading:
            return "Loading"
        case .failed where !speechModelInstalled:
            return "Retry download"
        case .ready, .notLoaded, .failed:
            // On-disk → re-download CTA; otherwise cold-download CTA.
            // Decouples the action label from the ANE-warmed flag so an
            // un-warmed but installed model still surfaces "Re-download"
            // instead of misleading the user into another full fetch.
            return speechModelInstalled ? "Re-download all models" : "Download all models"
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
        switch speechModelVariant {
        case "tdtCtc110m": return "Runs entirely on this iPhone. About 330 MB on disk."
        default:           return "Runs entirely on this iPhone. About 700 MB on disk."
        }
    }
}

#Preview {
    SettingsView()
        .environment(TranscriptionService())
}
