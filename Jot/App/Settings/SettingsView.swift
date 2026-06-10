import SwiftUI

/// v0.9 Settings main, matched to the design handoff's `SettingsScreen`.
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

    /// Mirror of `AppGroup.warmHoldDurationSeconds` for the Privacy picker.
    @State private var warmHoldDurationSeconds: TimeInterval = AppGroup.warmHoldDurationSeconds

    /// Mirror of `AppGroup.warmHoldEnabled` for the Privacy kill-switch.
    @State private var warmHoldEnabled: Bool = AppGroup.warmHoldEnabled

    /// Ask-mode backend toggle. OFF = Apple Intelligence (built-in, no download);
    /// ON = on-board Qwen (better answers, needs the model downloaded).
    @State private var askUseQwen: Bool = (AppGroup.askBackend == "qwen")


    /// Vocabulary store — the SPEECH MODEL chevron sub-screen + the
    /// VOCABULARY card row both observe `terms.count`.
    @State private var vocabularyStore = VocabularyStore.shared

    /// LLM adapter for the AI-row's sub-status. Resolved lazily on appear;
    /// `nil` until then. Lives only for the lifetime of the Settings sheet
    /// so we don't pin LLM weights in memory when the user just glanced
    /// at Settings.
    @State private var clientAdapter: LLMClientUIAdapter?


    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    settingsContent
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                speechModelVariant = AppGroup.speechModelVariant
                warmHoldDurationSeconds = AppGroup.warmHoldDurationSeconds
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
            .onChange(of: warmHoldDurationSeconds) { _, newValue in
                AppGroup.warmHoldDurationSeconds = newValue
            }
        }
        // Soften every card's drop shadow throughout Settings by 50% (light mode
        // only — dark mode already omits it). Scoped to this NavigationStack, so
        // Home / Recents cards keep their full shadow.
        .environment(\.liquidGlassShadowScale, 0.5)
    }

    // MARK: - Page chrome

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            navRow
            heroTitle
            speechModelSection
            vocabularySection
            aiSection
            privacySection
            aboutSection
            settingsFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var navRow: some View {
        HStack {
            HStack(spacing: 8) {
                // Brand mark — the app/watch icon art clipped to a circle,
                // matching Home. Replaces the old `j.square.fill` SF monogram.
                Image("JotBrandTile")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                Text("Jot")
                    .font(.system(size: 15, weight: .semibold))
                    // Adaptive secondary ink — the old hardcoded #3C3C43 was the
                    // light-mode label gray and rendered near-invisible on the
                    // dark navy wallpaper. jotPageInkSecondary lifts to white@0.62
                    // in dark, stays the same muted gray in light.
                    .foregroundStyle(Color.jotPageInkSecondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotPageInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("Done")
            .accessibilityHint("Dismisses Settings")
        }
        .padding(.horizontal, JotDesign.Spacing.pageGutter)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var heroTitle: some View {
        Text("Settings.")
            .font(JotType.displaySerif(44))
            .tracking(-1.6)
            .foregroundStyle(Color.jotPageInk)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 22)
            .padding(.trailing, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        label: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(label)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

            sectionCaption(caption)
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(JotType.sectionLabel)
            .tracking(1.5)
            .foregroundStyle(Color.jotPageInkCaption)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func sectionCaption(_ caption: String) -> some View {
        Text(caption)
            .font(JotType.rowSub)
            .foregroundStyle(Color.jotPageInkCaption)
            .padding(.horizontal, 22)
            .padding(.top, 8)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.jotPageSeparator)
            .frame(height: 0.5)
            .padding(.leading, 60)
    }

    @ViewBuilder
    private func settingsIconRow<Trailing: View>(
        systemImage: String,
        tint: Color,
        shaded: Color,
        title: String,
        subline: String? = nil,
        alignment: VerticalAlignment = .center,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: alignment, spacing: 14) {
            IconTile(
                systemImage: systemImage,
                tint: tint,
                shaded: shaded
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(JotType.rowTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)

                if let subline {
                    Text(subline)
                        .font(JotType.rowSub)
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
            }

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var externalArrow: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.jotPageInkCaption)
            .accessibilityHidden(true)
    }

    private var settingsFooter: some View {
        Text("Made with care in San Francisco.\nNo accounts, no cloud, no telemetry.\nOnly feedback you send leaves your iPhone.")
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.45))
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .padding(.horizontal, 22)
    }

    // MARK: - SPEECH MODEL

    private var speechModelSection: some View {
        settingsSection(label: "SPEECH MODEL", caption: speechModelFooter) {
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        IconTile(
                            systemImage: "waveform",
                            tint: JotDesign.JotSemanticIcon.speechModel,
                            shaded: JotDesign.JotSemanticIcon.speechModelShaded
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(speechModelDisplayName)
                                .font(JotType.rowTitle)
                                .tracking(-0.2)
                                .foregroundStyle(Color.jotPageInk)

                            Text(speechModelLocationCopy)
                                .font(JotType.rowSub)
                                .foregroundStyle(Color.jotPageInkSecondary)
                        }

                        Spacer(minLength: 12)
                        speechModelStatusPill
                    }
                    .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

                    cardDivider

                    NavigationLink {
                        SpeechModelVariantPicker()
                            .environment(transcriptionService)
                            .environment(streamingService)
                    } label: {
                        HStack(spacing: 10) {
                            Text("Variant")
                                .font(JotType.rowTitle)
                                .tracking(-0.2)
                                .foregroundStyle(Color.jotPageInk)

                            Spacer()

                            Text(variantShortName)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.jotPageInkSecondary)

                            RowChevron()
                        }
                        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Variant, currently \(variantShortName)")
                    .accessibilityHint("Opens variant picker")
                }
            }
        }
    }

    private var speechModelDisplayName: String {
        switch speechModelVariant {
        case "parakeetV2":   return "Parakeet 600M"
        default:             return "Parakeet 110M"
        }
    }

    private var variantShortName: String {
        switch speechModelVariant {
        case "parakeetV2":   return "Parakeet 600M"
        default:             return "Parakeet 110M"
        }
    }

    private var speechModelLocationCopy: String {
        switch speechModelVariant {
        case "parakeetV2":   return "On your iPhone · about 440 MB"
        default:             return "On your iPhone · about 330 MB"
        }
    }

    private var speechModelFooter: String {
        "Runs entirely on this iPhone. Audio never leaves the device."
    }

    /// "Installed" gate for the SPEECH MODEL display. Three-way AND across
    /// the batch TDT, the streaming EOU, and the CTC aux. For the default
    /// (bundled) TDT-CTC 110M variant all three are always present in the
    /// IPA; for the 0.6B v2 opt-in variant the batch TDT lives in
    /// Application Support and may still need a Settings download tap.
    /// Gating on bare `modelState == .ready` is wrong here — that flag is
    /// the "warmed into ANE for recording" signal, not the "is the model
    /// installed" signal.
    private var speechModelInstalled: Bool {
        TranscriptionService.modelsExistOnDiskForSelectedVariant()
            && StreamingTranscriptionService.modelsExistOnDisk()
            && CtcModelCache.shared.isCached
    }

    private var displayedModelState: TranscriptionService.ModelState {
        transcriptionService.modelState
    }

    @ViewBuilder
    private var speechModelStatusPill: some View {
        // In-progress states win over the on-disk probe: if a download or
        // load is happening right now, surface the live progress chrome.
        switch displayedModelState {
        case .downloading(let fraction):
            StatusPillV09(label: "\(Int((fraction * 100).rounded()))%", tint: .info)
        case .loading:
            StatusPillV09(label: "Loading", tint: .info)
        case .failed where !speechModelInstalled:
            // Surface failures when the bundles aren't on disk — the user
            // is missing files AND we couldn't load. The label below
            // distinguishes the "files present but load failed" case from
            // this one.
            StatusPillV09(label: "Error", tint: .warning)
        case .failed:
            // Files present on disk but the load still failed — usually
            // means the bundle is corrupted (truncated weights, mismatched
            // mlmodelc, etc). Don't show "Ready" here; that misleads the
            // user into thinking dictation will work when every tap will
            // throw "Load failed: ..." at the moment of use.
            StatusPillV09(label: "Load failed", tint: .warning)
        case .ready, .notLoaded:
            if speechModelInstalled {
                StatusPillV09(label: "Ready", tint: .ready)
            } else {
                StatusPillV09(label: "Not downloaded", tint: .warning)
            }
        }
    }

    // MARK: - VOCABULARY

    private var vocabularySection: some View {
        settingsSection(
            label: "VOCABULARY",
            caption: "Bias the speech model toward names, technical terms, and words Jot tends to mishear."
        ) {
            NavigationLink {
                VocabularySettingsView()
            } label: {
                LiquidGlassCard(paddingH: 0, paddingV: 0) {
                    settingsIconRow(
                        systemImage: "text.book.closed",
                        tint: JotDesign.JotSemanticIcon.vocabulary,
                        shaded: JotDesign.JotSemanticIcon.vocabularyShaded,
                        title: "Custom terms",
                        subline: vocabularySubline,
                        trailing: { RowChevron() }
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom terms, \(vocabularyStore.terms.count) entries")
            .accessibilityHint("Opens the vocabulary list")
        }
    }

    private var vocabularySubline: String {
        let n = vocabularyStore.terms.count
        return n == 1 ? "1 term · on this iPhone" : "\(n) terms · on this iPhone"
    }

    // MARK: - AI

    private var aiSection: some View {
        settingsSection(
            label: "AI",
            caption: "Titles and tags use the system's built-in AI automatically. Ask answers questions across your notes — pick which model below."
        ) {
            VStack(spacing: 10) {
                NavigationLink {
                    AIRewriteSettingsView()
                } label: {
                    LiquidGlassCard(paddingH: 0, paddingV: 0) {
                        settingsIconRow(
                            systemImage: "wand.and.stars",
                            tint: JotDesign.JotSemanticIcon.ai,
                            shaded: JotDesign.JotSemanticIcon.aiShaded,
                            title: "Rewrite & prompts",
                            subline: aiSubline,
                            trailing: { RowChevron() }
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewrite and prompts, \(aiSubline)")
                .accessibilityHint("Opens AI Rewrite settings")

                askBackendRow
            }
        }
    }

    /// Ask backend toggle: OFF = Apple Intelligence (built-in, instant, no
    /// download); ON = on-board Qwen (better answers, needs the model).
    private var askBackendRow: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(
                    systemImage: "sparkles",
                    tint: JotDesign.JotSemanticIcon.ai,
                    shaded: JotDesign.JotSemanticIcon.aiShaded
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use on-board Qwen for Ask")
                        .font(JotType.rowTitle)
                        .tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                    Text(askUseQwen
                         ? "Ask uses the on-board Qwen model — better answers, runs fully on-device (needs the model downloaded)."
                         : "Ask uses Apple Intelligence — built-in and instant, no download. Turn on for higher-quality answers from on-board Qwen.")
                        .font(JotType.rowSub)
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .lineSpacing(2)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $askUseQwen)
                    .labelsHidden()
                    .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                    .accessibilityLabel("Use on-board Qwen for Ask")
            }
            .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .onChange(of: askUseQwen) { _, newValue in
            AppGroup.askBackend = newValue ? "qwen" : "appleIntelligence"
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
        case .notReady:            status = "Tap to download"
        }
        return "\(modelName) · \(status)"
    }

    // MARK: - PRIVACY

    private var privacySection: some View {
        settingsSection(
            label: "PRIVACY",
            caption: "Your words stay on your iPhone. No accounts, no cloud, no telemetry — only feedback you send is ever transmitted."
        ) {
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(spacing: 0) {
                    // The on-device-only row was deleted — the section
                    // caption already says "Your words stay on your iPhone."
                    // and the redundant ALWAYS chip was self-congratulatory
                    // noise. The Full Access row becomes the first item.
                    //
                    // Full Access — tappable Link to iOS Settings (Jot's
                    // app-settings page). The user navigates from there to
                    // General → Keyboard → Keyboards → Jot Keyboard →
                    // Allow Full Access. The subline carries the breadcrumb
                    // because the deep-link can't go further from the main
                    // app — `prefs:` URLs are keyboard-extension-only per
                    // Apple's QA1924, the main app can't open them.
                    // No status pill: iOS doesn't let us read FA state.
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        settingsIconRow(
                            systemImage: "lock.shield",
                            tint: JotDesign.JotSemanticIcon.privacyFullAccess,
                            shaded: JotDesign.JotSemanticIcon.privacyFullAccessShaded,
                            title: "Full Access",
                            subline: "General → Keyboard → Keyboards → Jot",
                            trailing: { externalArrow }
                        )
                    }
                    .buttonStyle(.plain)

                    cardDivider
                    privacyMicReadyRow

                    if warmHoldEnabled {
                        cardDivider
                        privacyMicReadyDurationRow
                    }
                }
            }
        }
    }

    private var privacyMicReadyRow: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemImage: "mic",
                tint: JotDesign.JotSemanticIcon.privacyMicReady,
                shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Keep mic ready")
                    .font(JotType.rowTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)

                Text("Skips cold-start latency for repeat dictations within the selected ready window. While ready, the iOS orange microphone indicator stays on — the audio session is active but Jot is not transcribing.")
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $warmHoldEnabled)
                .labelsHidden()
                .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                .accessibilityLabel("Keep mic ready")
                .accessibilityHint("Skips cold-start latency for repeat dictations within the selected ready window.")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var privacyMicReadyDurationRow: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(
                systemImage: "mic",
                tint: JotDesign.JotSemanticIcon.privacyMicReady,
                shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded
            )

            Text("Ready for")
                .font(JotType.rowTitle)
                .foregroundStyle(Color.jotPageInk)
                .tracking(-0.2)

            Spacer(minLength: 12)

            Picker("", selection: $warmHoldDurationSeconds) {
                Text("60s").tag(TimeInterval(60))
                Text("2 min").tag(TimeInterval(120))
                Text("3 min").tag(TimeInterval(180))
                Text("5 min").tag(TimeInterval(300))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Mic-ready duration")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - ABOUT

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ABOUT")

            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(spacing: 0) {
                    if DictationStats.totalCount > 0 {
                        statsRow
                        cardDivider
                    }

                    NavigationLink {
                        HelpView()
                    } label: {
                        settingsIconRow(
                            systemImage: "questionmark.circle",
                            tint: JotDesign.JotSemanticIcon.helpSupport,
                            shaded: JotDesign.JotSemanticIcon.helpSupportShaded,
                            title: "Help & Support",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Help & Support")
                    .accessibilityHint("Opens Help")

                    cardDivider

                    NavigationLink {
                        EmbeddingsPanelView()
                    } label: {
                        settingsIconRow(
                            systemImage: "sparkles",
                            tint: Color.jotBlueTop,
                            shaded: Color.jotBlueBottom.opacity(0.15),
                            title: "Indexing",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Indexing")
                    .accessibilityHint("Manage on-device indexing of your dictations.")

                    cardDivider

                    NavigationLink {
                        DiagnosticsWatchView()
                    } label: {
                        settingsIconRow(
                            systemImage: "applewatch",
                            tint: JotDesign.JotSemanticIcon.helpSupport,
                            shaded: JotDesign.JotSemanticIcon.helpSupportShaded,
                            title: "Apple Watch",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apple Watch sync status")
                    .accessibilityHint("Shows watch connection status and Reset sync button.")

                    cardDivider

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        settingsIconRow(
                            systemImage: "stethoscope",
                            tint: JotDesign.JotSemanticIcon.version,
                            shaded: JotDesign.JotSemanticIcon.versionShaded,
                            title: "Diagnostics",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Diagnostics")
                    .accessibilityHint("Recent events from the keyboard and main app; copy and send to support.")

                    cardDivider

                    Button {
                        handleRerunSetupTap()
                    } label: {
                        settingsIconRow(
                            systemImage: "arrow.clockwise",
                            tint: JotDesign.JotSemanticIcon.rerunWizard,
                            shaded: JotDesign.JotSemanticIcon.rerunWizardShaded,
                            title: "Re-run setup wizard",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)

                    cardDivider

                    NavigationLink {
                        FeedbackView()
                    } label: {
                        settingsIconRow(
                            systemImage: "envelope",
                            tint: JotDesign.JotSemanticIcon.sendFeedback,
                            shaded: JotDesign.JotSemanticIcon.sendFeedbackShaded,
                            title: "Send feedback",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)

                    cardDivider

                    settingsIconRow(
                        systemImage: "info.circle",
                        tint: JotDesign.JotSemanticIcon.version,
                        shaded: JotDesign.JotSemanticIcon.versionShaded,
                        title: "Version",
                        trailing: {
                            Text(versionString)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.jotPageInkSecondary)
                        }
                    )

                    cardDivider

                    NavigationLink {
                        DonationsView()
                    } label: {
                        settingsIconRow(
                            systemImage: "gift",
                            tint: JotDesign.JotSemanticIcon.donations,
                            shaded: JotDesign.JotSemanticIcon.donationsShaded,
                            title: "Donations",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Donations")
                    .accessibilityHint("Opens Donations")

                    cardDivider

                    Link(destination: URL(string: "https://jot.ideaflow.page/privacy")!) {
                        settingsIconRow(
                            systemImage: "hand.raised",
                            tint: JotDesign.JotSemanticIcon.privacyPolicy,
                            shaded: JotDesign.JotSemanticIcon.privacyPolicyShaded,
                            title: "Privacy Policy",
                            trailing: { externalArrow }
                        )
                    }
                    .buttonStyle(.plain)

                    cardDivider

                    // Backup transparency row. Static copy; we can't detect
                    // whether the user has iCloud Backup actually enabled
                    // from inside the app (no public API), so we use neutral
                    // "if-enabled" phrasing rather than a misleading ✓.
                    // Data path: SwiftData store + saved prompts + vocab
                    // live in the App Group container, which iOS Device
                    // Backup includes. Audio is never stored. The AI
                    // Rewrite model (~2.5 GB) lives under Library/Caches/
                    // which iOS unconditionally excludes from backup —
                    // it re-downloads on first use after restore.
                    settingsIconRow(
                        systemImage: "icloud",
                        tint: JotDesign.JotSemanticIcon.backup,
                        shaded: JotDesign.JotSemanticIcon.backupShaded,
                        title: "Backed up with iCloud",
                        subline: "When iCloud Backup is enabled in iOS Settings",
                        trailing: { EmptyView() }
                    )

                    cardDivider

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        settingsIconRow(
                            systemImage: "heart",
                            tint: JotDesign.JotSemanticIcon.acknowledgements,
                            shaded: JotDesign.JotSemanticIcon.acknowledgementsShaded,
                            title: "Acknowledgements",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        }
    }

    private var statsRow: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(
                systemImage: "chart.line.uptrend.xyaxis",
                tint: JotDesign.JotSemanticIcon.speechModel,
                shaded: JotDesign.JotSemanticIcon.speechModelShaded
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Time saved")
                    .font(JotType.rowTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)

                Text(statsSubline)
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
            }

            Spacer(minLength: 12)

            RecentsSparkline(
                values: DictationStats.last14DaysSeconds,
                width: 60,
                height: 20
            )
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time saved — \(statsSubline)")
    }

    private var statsSubline: String {
        let mins = max(0, Int(((DictationStats.todaySeconds * DictationStats.timeSavedMultiplier) / 60).rounded()))
        return "\(mins) min today · \(RecentsFormatting.dictationCountText(DictationStats.totalCount))"
    }

    // (Lab section removed in build 48 — the embeddings kill-switch and
    // the hand-seeding UI now live behind Settings → About → Classification
    // via `EmbeddingsPanelView`.)

    // MARK: - Misc

    /// Re-run setup wizard tap handler. Order is load-bearing: SwiftUI
    /// will crash / log a "tried to present X on Y while Y is presenting
    /// Z" violation if we ask `JotApp` to raise the wizard's fullScreenCover
    /// while this Settings sheet is still up. Latching a flag on the host
    /// via `onRerunRequested` and firing the trigger from the host's sheet
    /// `onDismiss` is the deterministic fix — `DispatchQueue.main.async`
    /// only buys one runloop turn, which isn't guaranteed to outlast the
    /// ~300ms dismiss animation. Also stop any in-flight recording so the
    /// wizard's W6 in-app dictation test doesn't collide with a live engine.
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
                    Text("Parakeet 110M (lighter, faster)")
                        .tag("tdtCtc110m")
                    Text("Parakeet 600M (more accurate)")
                        .tag("parakeetV2")
                } label: {
                    Label("Variant", systemImage: "waveform.badge.magnifyingglass")
                }
                .pickerStyle(.inline)
                .onChange(of: speechModelVariant) { _, newValue in
                    AppGroup.speechModelVariant = newValue
                    transcriptionService.handleVariantChange()
                    // The streaming service also needs to re-evaluate
                    // disk presence for the new variant; without this
                    // call the Status pill would lag one navigation
                    // cycle behind reality after flipping variants.
                    streamingService.handleVariantChange()
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

                // Hide the download / re-download CTA for the bundled 110M
                // variant — its weights live in the read-only IPA bundle, so
                // both "Download all models" (nothing to fetch) and
                // "Re-download all models" (purgeAndReload short-circuits for
                // the bundled case) are dead-end taps. The opt-in 600M v2
                // download keeps the CTA: its Application Support cache is
                // writable + re-downloadable.
                if speechModelVariant != "tdtCtc110m" {
                    Button {
                        handleModelAction()
                    } label: {
                        Label(modelActionTitle, systemImage: "arrow.down.circle")
                    }
                    .disabled(modelActionDisabled)
                }
            } header: {
                Text("Model")
            }
        }
        .navigationTitle("Variant")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Re-download?",
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

    private var displayedModelState: TranscriptionService.ModelState {
        transcriptionService.modelState
    }

    private var modelStatusText: String {
        // Live-progress states still win — show the actual download/load
        // percent rather than a stale "Ready" pill from a previous session.
        switch displayedModelState {
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
        switch displayedModelState {
        case .downloading, .loading:
            return "arrow.down.circle.fill"
        case .failed where !speechModelInstalled:
            return "exclamationmark.triangle.fill"
        case .ready, .notLoaded, .failed:
            return speechModelInstalled ? "checkmark.circle.fill" : "circle"
        }
    }

    private var modelStatusColor: Color {
        switch displayedModelState {
        case .downloading, .loading:
            return .accentColor
        case .failed where !speechModelInstalled:
            return .orange
        case .ready, .notLoaded, .failed:
            return speechModelInstalled ? .green : .secondary
        }
    }

    private var modelActionTitle: String {
        switch displayedModelState {
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
            return speechModelInstalled ? "Re-download" : "Download"
        }
    }

    private var modelActionDisabled: Bool {
        switch displayedModelState {
        case .downloading, .loading:
            return true
        case .notLoaded, .failed, .ready:
            return false
        }
    }

    private var sizeFooter: String {
        switch speechModelVariant {
        case "parakeetV2":   return "Runs entirely on this iPhone. About 440 MB on disk."
        default:             return "Runs entirely on this iPhone. About 330 MB on disk."
        }
    }
}

#Preview {
    SettingsView()
        .environment(TranscriptionService())
}
