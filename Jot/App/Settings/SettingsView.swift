import SwiftUI

/// v0.9 Settings main, matched to the design handoff's `SettingsScreen`.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(RecordingService.self) private var recordingService

    /// Called from `handleRerunSetupTap` BEFORE this sheet dismisses so the
    /// host (ContentView) can latch a "fire rerun once the sheet has fully
    /// torn down" flag. The actual `SettingsRerunTrigger.requestRerun()` is
    /// deferred until the sheet's `onDismiss` runs — guessing at the dismiss
    /// animation length with `DispatchQueue.main.async` is the dual-modal
    /// crash path we're avoiding.
    var onRerunRequested: (() -> Void)? = nil

    /// Mirror of `AppGroup.warmHoldDurationSeconds` for the Privacy picker.
    @State private var warmHoldDurationSeconds: TimeInterval = AppGroup.warmHoldDurationSeconds

    /// Mirror of `AppGroup.warmHoldEnabled` for the Privacy kill-switch.
    @State private var warmHoldEnabled: Bool = AppGroup.warmHoldEnabled

    /// Resolved "Live text while dictating" state (tri-state under the
    /// hood — see `liveTextToggleRow`). A user touch writes explicit
    /// on/off; `auto` only persists until first touch.
    @State private var liveTextOn: Bool = DeviceCapability.liveTextEnabled

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
                warmHoldDurationSeconds = AppGroup.warmHoldDurationSeconds
                warmHoldEnabled = AppGroup.warmHoldEnabled
                liveTextOn = DeviceCapability.liveTextEnabled
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
            .onChange(of: liveTextOn) { _, newValue in
                // First touch graduates "auto" to an explicit choice —
                // never clobbered by future capability-default changes.
                AppGroup.liveTextSetting = newValue ? "on" : "off"
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

                    // Single bundled model — English only. Static row (no
                    // picker): there is one language today, so this surfaces it
                    // without an interactive chevron.
                    HStack(spacing: 10) {
                        Text("Language")
                            .font(JotType.rowTitle)
                            .tracking(-0.2)
                            .foregroundStyle(Color.jotPageInk)

                        Spacer()

                        Text("English")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                    .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Language, English")

                    cardDivider
                    liveTextToggleRow
                }
            }
        }
    }

    /// "Live text while dictating" — the streaming on/off axis
    /// (docs/plans/batch-only-streaming.md). Tri-state under the hood
    /// (`AppGroup.liveTextSetting`: auto/on/off — auto follows
    /// `DeviceCapability`); the switch shows the RESOLVED state and a touch
    /// writes an explicit on/off. Takes effect on the next dictation start.
    private var liveTextToggleRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Live text while dictating")
                    .font(JotType.rowTitle)
                    .foregroundStyle(Color.jotPageInk)
                    .tracking(-0.2)

                Text("Show words as you speak. Turning off saves battery — your transcript is unaffected.")
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $liveTextOn)
                .labelsHidden()
                .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                .accessibilityLabel("Live text while dictating")
                .accessibilityHint("Turning off saves battery. Your saved transcript is unaffected.")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Capable devices show the bundled 600M; sub-6GB devices fall back to the
    /// smaller English model fetched on demand. Choice is automatic (device
    /// RAM), never a user picker.
    private var speechModelDisplayName: String {
        DeviceCapability.is600MCapable ? "Parakeet 600M" : "Parakeet 110M"
    }

    private var speechModelLocationCopy: String {
        if DeviceCapability.is600MCapable {
            return "On your iPhone · about 440 MB"
        }
        // Sub-6GB device: the 110M is fetched on first dictation. Reflect
        // whether it's already on disk so the copy isn't misleading pre-fetch.
        return speechModelInstalled
            ? "On your iPhone · about 220 MB"
            : "Downloads on first use · about 220 MB"
    }

    private var speechModelFooter: String {
        "Runs entirely on this iPhone. Audio never leaves the device."
    }

    /// "Installed" gate for the SPEECH MODEL display. AND across the bundled
    /// speech model and the CTC aux (vocabulary). Both ship in the IPA, so on
    /// a healthy install this is always true. Gating on bare
    /// `modelState == .ready` is wrong here — that flag is the "warmed into
    /// ANE for recording" signal, not the "is the model installed" signal.
    private var speechModelInstalled: Bool {
        TranscriptionService.modelsExistOnDiskForSelectedVariant()
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

                    Link(destination: URL(string: "https://jot-transcribe.com/privacy")!) {
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


#Preview {
    SettingsView()
        .environment(TranscriptionService())
}
