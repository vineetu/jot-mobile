import SwiftUI

/// v0.9 Settings main, matched to the design handoff's `SettingsScreen`.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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

    /// Dictation language. English is the only option today; the selector is a
    /// native iOS pull-down menu (Apple pattern) so adding languages later is a
    /// drop-in. Local state — there's nothing to persist while it's English-only.
    @State private var dictationLanguage: String = "en"


    /// Vocabulary store — the SPEECH MODEL chevron sub-screen + the
    /// VOCABULARY card row both observe `terms.count`.
    @State private var vocabularyStore = VocabularyStore.shared

    /// LLM adapter for the AI-row's sub-status. Resolved lazily on appear;
    /// `nil` until then. Lives only for the lifetime of the Settings sheet
    /// so we don't pin LLM weights in memory when the user just glanced
    /// at Settings.
    @State private var clientAdapter: LLMClientUIAdapter?

    // MARK: - TTS Lab (hidden reveal)

    /// Hidden "Text-to-Speech (Lab)" opt-in. The section is revealed by tapping
    /// the Version row 5 times (mirrors the warm-yield reveal pattern). Once
    /// revealed for this Settings session, the section stays up; the toggle
    /// itself is persisted in the App Group so it survives relaunch.
    /// See `docs/tts-lab/design.md`.
    @State private var ttsLabRevealed: Bool = AppGroup.defaults.bool(forKey: AppGroup.Keys.ttsLabEnabled)
    @State private var ttsLabVersionTapCount: Int = 0
    @State private var ttsLabEnabled: Bool = AppGroup.defaults.bool(forKey: AppGroup.Keys.ttsLabEnabled)
    @State private var ttsService = TTSService.shared
    /// Presents `VoiceCloneRecorderView` from the Lab's "Clone my voice" row.
    @State private var showVoiceCloneSheet: Bool = false


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
                ttsLabVersionTapCount = 0
                // If the Lab was already opted in (persisted), keep it revealed.
                ttsLabRevealed = AppGroup.defaults.bool(forKey: AppGroup.Keys.ttsLabEnabled) || ttsLabRevealed
                ttsLabEnabled = AppGroup.defaults.bool(forKey: AppGroup.Keys.ttsLabEnabled)
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
            .onChange(of: ttsLabEnabled) { _, newValue in
                AppGroup.defaults.set(newValue, forKey: AppGroup.Keys.ttsLabEnabled)
                // Turning the Lab ON is the user's explicit opt-in to the
                // model download (the deliberate sidestep of "download-first").
                if newValue && !ttsService.isReady {
                    Task { await ttsService.download() }
                }
            }
            .sheet(isPresented: $showVoiceCloneSheet) {
                VoiceCloneRecorderView()
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
        Text("Settings")
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

    @ViewBuilder
    private func sectionCaption(_ caption: String) -> some View {
        if !caption.isEmpty {
            Text(caption)
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkCaption)
                .padding(.horizontal, 22)
                .padding(.top, 8)
        }
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
        // Renamed SPEECH MODEL → DICTATION: we no longer surface a model name to
        // the user (single bundled model, chosen automatically by device), so the
        // card is now just the dictation Language + the live-text toggle. The
        // model name / size / READY pill and the "runs on device" footer were
        // removed — they weren't information the user comes here to act on.
        settingsSection(label: "DICTATION", caption: "") {
            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    languageRow
                    cardDivider
                    liveTextToggleRow
                }
            }
        }
    }

    /// Dictation language as a native iOS pull-down menu (the Apple selector
    /// pattern: current value + up/down chevron, tap → checked menu). English is
    /// the only option today; the `Picker` makes adding languages a drop-in and
    /// the affordance reads as a real selector without crowding the row.
    private var languageRow: some View {
        HStack(spacing: 14) {
            IconTile(
                systemImage: "waveform",
                tint: JotDesign.JotSemanticIcon.speechModel,
                shaded: JotDesign.JotSemanticIcon.speechModelShaded
            )

            Text("Language")
                .font(JotType.rowTitle)
                .tracking(-0.2)
                .foregroundStyle(Color.jotPageInk)

            Spacer(minLength: 12)

            Menu {
                Picker("Language", selection: $dictationLanguage) {
                    Text("English").tag("en")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("English")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.jotPageInkSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
            }
            .buttonStyle(.plain)
            // Let the Menu keep its own button/pop-up-menu trait — do NOT wrap
            // the row in `.accessibilityElement(.combine)`, which would flatten
            // the Menu into a static element and strip the "tap to choose"
            // affordance. The leading text + this label cover the read-out.
            .accessibilityLabel("Language")
            .accessibilityValue("English")
            .accessibilityHint("Choose the dictation language")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
            }
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

                    // HIDDEN 2026-06-17 per owner — the "Indexing" row (opens
                    // `EmbeddingsPanelView`) is no longer surfaced in Settings.
                    // The screen + the on-device indexing feature are unchanged;
                    // only this entry point is hidden. Restore the NavigationLink
                    // to bring it back.

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

                    // Tapping the Version row 5 times reveals the hidden
                    // "Text-to-Speech (Lab)" section (see ttsLabSection). A
                    // plain Button keeps the row's appearance identical to the
                    // static version row it replaces.
                    Button {
                        handleVersionTap()
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Version \(versionString)")

                    if ttsLabRevealed {
                        cardDivider
                        ttsLabSection
                    }

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

                    // HIDDEN 2026-06-17 per owner — the "Backed up with iCloud"
                    // transparency row is no longer surfaced in Settings. Backup
                    // behavior is unchanged (the App Group store still rides iOS
                    // Device Backup); restore the `settingsIconRow` here to bring
                    // the row back.

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

                    cardDivider

                    // MOVED to the bottom 2026-06-17 per owner (was mid-list,
                    // between Apple Watch and Re-run setup).
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

    // MARK: - TTS Lab (hidden)

    /// Count taps on the Version row; reveal the Lab section on the 5th.
    private func handleVersionTap() {
        guard !ttsLabRevealed else { return }
        ttsLabVersionTapCount += 1
        if ttsLabVersionTapCount >= 5 {
            withAnimation { ttsLabRevealed = true }
        }
    }

    /// Hidden experimental section: an opt-in toggle for the on-device Kokoro
    /// TTS + Apple-Translation transcript playback, plus a "Download voices"
    /// row that surfaces download progress. Turning the toggle on triggers the
    /// download (wired in `.onChange(of: ttsLabEnabled)`).
    @ViewBuilder
    private var ttsLabSection: some View {
        // The toggle row.
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemImage: "speaker.wave.2",
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Text-to-Speech (Lab)")
                    .font(JotType.rowTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)

                Text("Experimental. Read a transcript aloud in different voices and accents, fully on-device. Non-English voices translate first using Apple Translation. Turning this on downloads the voice model.")
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $ttsLabEnabled)
                .labelsHidden()
                .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                .accessibilityLabel("Text-to-Speech Lab")
                .accessibilityHint("Enables experimental on-device read-aloud and downloads the voice model.")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())

        // The download / status row — only meaningful once enabled.
        if ttsLabEnabled {
            cardDivider
            ttsLabDownloadRow
            cardDivider
            cloneVoiceRow
            ForEach(ttsService.clonedVoices) { voice in
                cardDivider
                clonedVoiceRow(voice)
            }
            if ttsService.isReady {
                cardDivider
                deleteModelsRow
            }
        }
    }

    /// "Delete downloaded voices" — frees the TTS model storage. Only the TTS
    /// model cache is removed (never the dictation/ASR models), so transcription
    /// is unaffected. Shown once the model has been downloaded.
    @ViewBuilder
    private var deleteModelsRow: some View {
        Button(role: .destructive) {
            ttsService.deleteDownloadedModels()
        } label: {
            settingsIconRow(
                systemImage: "trash",
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded,
                title: "Delete downloaded voices",
                subline: "Frees the voice-model storage. Dictation is unaffected; cloned voices are kept.",
                trailing: { EmptyView() }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete downloaded voices")
        .accessibilityHint("Removes the downloaded voice models to free space; dictation is unaffected.")
    }

    /// "Clone my voice" entry — presents the recorder sheet.
    @ViewBuilder
    private var cloneVoiceRow: some View {
        Button {
            showVoiceCloneSheet = true
        } label: {
            settingsIconRow(
                systemImage: "waveform.and.mic",
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded,
                title: "Clone my voice",
                subline: "Record a short sample to add your own voice",
                trailing: { RowChevron() }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clone my voice")
        .accessibilityHint("Record a short sample to create a read-aloud voice in your own voice.")
    }

    /// One cloned-voice row with a trailing delete control (Settings uses a
    /// custom card layout, not a `List`, so we surface an explicit delete
    /// button rather than swipe-to-delete).
    @ViewBuilder
    private func clonedVoiceRow(_ voice: TTSVoice) -> some View {
        settingsIconRow(
            systemImage: "person.wave.2",
            tint: JotDesign.JotSemanticIcon.version,
            shaded: JotDesign.JotSemanticIcon.versionShaded,
            title: voice.label,
            subline: "Your cloned voice",
            trailing: {
                Button {
                    ttsService.deleteClonedVoice(voice)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(.systemRed))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete voice \(voice.label)")
            }
        )
    }

    @ViewBuilder
    private var ttsLabDownloadRow: some View {
        Button {
            Task { await ttsService.download() }
        } label: {
            settingsIconRow(
                systemImage: ttsDownloadIcon,
                tint: JotDesign.JotSemanticIcon.version,
                shaded: JotDesign.JotSemanticIcon.versionShaded,
                title: "Voice model",
                subline: ttsDownloadSubline,
                trailing: {
                    if ttsService.downloadState == .downloading {
                        ProgressView()
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(ttsService.downloadState == .downloading || ttsService.isReady)
        .accessibilityLabel("Voice model — \(ttsDownloadSubline)")
    }

    private var ttsDownloadIcon: String {
        switch ttsService.downloadState {
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "arrow.down.circle"
        }
    }

    private var ttsDownloadSubline: String {
        switch ttsService.downloadState {
        case .notStarted: return "Tap to download"
        case .downloading: return "Downloading…"
        case .ready: return "Ready"
        case .failed(let message): return "Failed — tap to retry (\(message))"
        }
    }
}


#Preview {
    SettingsView()
        .environment(TranscriptionService())
}
