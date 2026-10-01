import SwiftUI
import UniformTypeIdentifiers

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

    /// Dictation language (raw `LanguageChoice`). Mirrors
    /// `AppGroup.transcriptionLanguage`. English → bundled v2 (no download);
    /// a European pick downloads Parakeet v3 once. Changing it persists and
    /// re-prepares the transcription model (downloading if needed).
    @State private var dictationLanguage: String = AppGroup.transcriptionLanguage

    /// Live per-device language capability (`DictationLanguageAvailability`). `nil`
    /// until the first `.task` resolve completes — the language picker shows
    /// every language while unresolved (never an empty picker) and the
    /// Parakeet-download gate falls back to the old `!isEnglish` assumption
    /// for that same brief window. RULE #1: never show a language, or a
    /// "download Parakeet" affordance, that can't actually run on this device.
    @State private var appleLangCodes: Set<String>?

    // Feature flag — HIDDEN for release (owner 2026-06-29). Flip to `true`
    // to re-expose; all underlying code is intact.
    private let showDataImportExport = false     // Settings → "Your Data" export/import


    /// Transcript import/export (independent on-device backup, not iCloud).
    @State private var showTranscriptExporter = false
    @State private var transcriptExportDoc: TranscriptBackupDocument?
    @State private var showTranscriptImporter = false
    /// Result message shown in an alert after an import/export completes.
    @State private var backupAlertMessage: String?


    /// Vocabulary store — the SPEECH MODEL chevron sub-screen + the
    /// VOCABULARY card row both observe `terms.count`.
    @State private var vocabularyStore = VocabularyStore.shared

    /// The English engine, observed the same way `TranscriptionService.shared`
    /// is — `languageStatusRow` reports its download/load state so English gets
    /// the same honest one-liner the downloaded languages already get.
    @State private var unifiedEnglish = UnifiedEnglishModel.shared


    // MARK: - Hidden rows (5-tap reveal)

    /// Hidden Settings rows (e.g. "Use Apple speech engine", the punctuation
    /// model status), revealed by tapping the Version row 5 times. The reveal
    /// persists in the App Group so it survives relaunch.
    @State private var hiddenRowsRevealed: Bool = AppGroup.defaults.bool(forKey: AppGroup.Keys.hiddenSettingsRevealed)
    /// Read-only status line for the punctuation-model row (5-tap reveal
    /// block). Refreshed on row appear; the fetch itself needs no controls.
    @State private var punctuationModelStatusLine: String = "Checking…"

    private func refreshPunctuationModelStatus() {
        let fetcher = PunctuationModelFetcher.shared
        if fetcher.isInstalled {
            punctuationModelStatusLine = "Installed — English dictations use it"
            return
        }
        switch fetcher.phase {
        case .downloading(let done, let total):
            let pct = total > 0 ? Int((Double(done) / Double(total)) * 100) : 0
            punctuationModelStatusLine = "Downloading — \(pct)%"
        case .installing:
            punctuationModelStatusLine = "Installing…"
        case .failed(let why):
            punctuationModelStatusLine = "Failed — \(why)"
        case .idle, .done:
            // Not installed + idle = the discretionary fetch is waiting for a
            // moment iOS likes (Wi-Fi, power). Honest wording beats a spinner.
            punctuationModelStatusLine = "Waiting for Wi-Fi — downloads automatically (57 MB)"
        }
    }
    @State private var versionTapCount: Int = 0
    /// TEMPORARY owner test switch — see `MoonshineEnglishTest`.
    @State private var moonshineEnglishTest: Bool = AppGroup.defaults.bool(forKey: AppGroup.Keys.moonshineEnglishTest)
    private var moonshineStatusLine: String {
        guard moonshineEnglishTest else { return "Off — English uses Jot's normal engine" }
        switch MoonshineEnglishTest.shared.state {
        case .idle: return "On — model loads on first use"
        case .downloading(let f): return "Downloading model — \(Int(f * 100))%"
        case .loading: return "Loading model…"
        case .ready: return "On — saved text comes from Moonshine (live text is still Parakeet)"
        case .failed(let why): return "Failed — \(why)"
        }
    }
    /// EXPERIMENTAL A/B spike (2026-07-04, temporary): Apple SpeechTranscriber
    /// vs FluidAudio Parakeet for English dictation, same CTC vocab boost on
    /// top either way. See `AppleDictationEngine.swift`.
    @State private var useAppleDictationForEnglish: Bool = AppGroup.useAppleDictationForEnglish
    /// Keeps the engine toggle honest if a background Parakeet-upgrade download
    /// auto-switches the engine while Settings is open (the toggle @State is
    /// seeded once, so it would otherwise show a stale Apple-ON).
    @State private var engineActivatedObserver: CrossProcessNotification.Observer?


    /// Re-read the engine toggle from the App Group (source of truth). Guarded so
    /// it only writes when the value actually changed — an already-synced toggle
    /// doesn't needlessly re-fire the toggle's `onChange` side-effects.
    private func refreshEngineToggle() {
        let latest = AppGroup.useAppleDictationForEnglish
        if latest != useAppleDictationForEnglish {
            useAppleDictationForEnglish = latest
        }
    }

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
                versionTapCount = 0
                // Already revealed (persisted) → keep it revealed.
                hiddenRowsRevealed = AppGroup.defaults.bool(forKey: AppGroup.Keys.hiddenSettingsRevealed) || hiddenRowsRevealed
                // Re-seed the engine toggle from the source of truth on every
                // appear — a background auto-switch (or the keyboard nudge path)
                // may have flipped it since this @State was first seeded.
                useAppleDictationForEnglish = AppGroup.useAppleDictationForEnglish
                if engineActivatedObserver == nil {
                    engineActivatedObserver = CrossProcessNotification.addObserver(
                        name: CrossProcessNotification.parakeetEngineActivated
                    ) {
                        refreshEngineToggle()
                    }
                }
                vocabularyStore.load()
            }
            .onDisappear {
                engineActivatedObserver = nil
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
                // The enhanced English model transcribes ONLY through the live
                // streaming session, so this toggle decides whether it can be
                // used at all: off drops the resident encoder, on prepares (and,
                // first time, fetches) it. Same both-edges pattern as the
                // Apple-engine toggle below.
                UnifiedEnglishModel.syncWithRouting()
            }
            .task {
                // `resolve()` is idempotent — cheap to re-await if the app
                // already resolved it at launch (`JotApp`'s scene `.task`).
                await DictationLanguageAvailability.resolve()
                appleLangCodes = DictationLanguageAvailability.appleCodes
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
            if showDataImportExport { dataSection }
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
        Text("Made with care in San Francisco.\nNo accounts, no telemetry.\nYour words stay private — on your iPhone, or in Apple's private cloud.")
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
                    languageStatusRow
                    cardDivider
                    liveTextToggleRow
                }
            }
        }
    }

    /// Languages that actually work on this device (`DictationLanguageAvailability`).
    /// Shows the full list while `appleLangCodes` hasn't resolved yet so the
    /// picker is never empty; English is always kept regardless (it's always
    /// available anyway — belt and suspenders against a resolve edge case).
    private var availableLanguages: [LanguageChoice] {
        guard let appleLangCodes else { return LanguageChoice.presentationOrder }
        return LanguageChoice.presentationOrder.filter {
            $0.isEnglish || DictationLanguageAvailability.isAvailable($0, appleCodes: appleLangCodes)
        }
    }

    /// `LanguageChoice.recentLanguages`, filtered to what's available on this
    /// device — Rule #1 applies to the Recent quick-switch too: a recent
    /// language that no longer works here (e.g. a Parakeet-only European pick
    /// on an iPad where Parakeet can't run) must not appear. Reuses
    /// `availableLanguages` so the same unresolved/English-always behavior
    /// applies without re-deriving it.
    private var availableRecentLanguages: [LanguageChoice] {
        LanguageChoice.recentLanguages.filter { availableLanguages.contains($0) }
    }

    /// Whether picking `lang` would show OUR Parakeet-download UI on this
    /// device. Falls back to the pre-capability-check assumption
    /// (`!isEnglish`) while `appleLangCodes` hasn't resolved yet.
    private func showsParakeetDownload(_ lang: LanguageChoice) -> Bool {
        guard let appleLangCodes else { return !lang.isEnglish }
        return DictationLanguageAvailability.usesParakeetDownload(lang, appleCodes: appleLangCodes)
    }

    /// Binding that persists the chosen language and re-prepares the model
    /// (downloading a European v3 model if it isn't on disk yet).
    private var languageBinding: Binding<String> {
        Binding(
            get: { dictationLanguage },
            set: { newValue in
                guard newValue != dictationLanguage else { return }
                dictationLanguage = newValue
                AppGroup.transcriptionLanguage = newValue
                if let lang = LanguageChoice(rawValue: newValue) {
                    LanguageChoice.recordRecent(lang)
                }
                TranscriptionService.shared.handleLanguageChange()
                // Apple-routed languages install their per-locale speech asset
                // via Apple (not our Parakeet download). Preinstall it now, at
                // the moment of picking, so the first recording isn't stalled by
                // a mid-session download — matching the Apple-engine toggle's
                // consent-time preinstall. Unobtrusive; no download UI.
                if TranscriptionService.activeLanguageUsesApple {
                    TranscriptionService.shared.preinstallAppleAssets()
                }
            }
        )
    }

    /// One-line status under the language row. English is bundled, so it never
    /// waits on anything — but on Jot's own engine it reports the more accurate
    /// English model's own download/load state (`UnifiedEnglishModel.state`),
    /// which is the ONLY place that 582 MB background fetch is visible. A
    /// European language reflects the live download / load / ready state of its
    /// Parakeet v3 model (observed from `TranscriptionService.shared.modelState`).
    @ViewBuilder
    private var languageStatusRow: some View {
        let lang = LanguageChoice(rawValue: dictationLanguage) ?? .english
        let (text, tint): (String, Color) = {
            if lang.isEnglish {
                // English is never blocked on a download — the bundled engine is
                // always there. But the more accurate model that supersedes it
                // (`UnifiedEnglishModel`) arrives on its own over Wi-Fi, and the
                // owner's standing complaint about the punctuation model applies
                // doubly at 582 MB: "I don't know if I'm using the new engine or
                // not". So the line reports which one is actually running.
                // Not offered = the Apple engine is selected, live text is off
                // (the enhanced model only transcribes through the live
                // session), or the device can't run Jot's own engine. In all
                // three the built-in model IS the English engine and there is
                // nothing to download, so this line stays exactly as it was —
                // do NOT advertise the enhanced download to a user whose own
                // setting is what rules it out.
                guard UnifiedEnglishModel.isOfferedForCurrentLanguage else {
                    return ("Built in — ready to use, no download.", Color.jotPageInkSecondary)
                }
                switch unifiedEnglish.state {
                case .ready:
                    return ("Enhanced English model — ready, runs on this iPhone.", Color.green)
                case .downloading(let f, _):
                    // Zero progress is NOT "downloading slowly": the session is
                    // discretionary, so iOS can hold the whole 582 MB for days
                    // waiting for Wi-Fi and power. A 0% bar sitting there reads
                    // as broken, so say what is actually happening — the same
                    // honest treatment the punctuation-model row uses.
                    // Guard on the DISPLAYED percentage, not the raw fraction:
                    // 0 < f < 0.01 still renders "… 0%", which is the exact
                    // parked-looking string this line exists to avoid.
                    guard Int(f * 100) > 0 else { return (Self.unifiedWaitingLine, Color.jotPageInkSecondary) }
                    return (
                        "Built in and ready. Downloading the enhanced English model… \(Int(f * 100))%",
                        Color.jotPageInkSecondary
                    )
                case .loading:
                    return ("Loading the enhanced English model…", Color.jotPageInkSecondary)
                case .failed:
                    return (
                        "Built in and ready. The enhanced model didn't download — Jot is using the standard one.",
                        Color.jotPageInkSecondary
                    )
                case .notDownloaded:
                    guard !UnifiedEnglishModel.isInstalledOnDisk else {
                        // On disk but not loaded in this process — the kill
                        // switch, or (transiently) the moment right after the
                        // routing flips back on, e.g. the Apple-engine toggle
                        // going ON→OFF, before `prepare()` has reached
                        // `.loading`. Say what is true rather than promising a
                        // download that already happened.
                        return ("Enhanced English model downloaded.", Color.jotPageInkSecondary)
                    }
                    return (Self.unifiedWaitingLine, Color.jotPageInkSecondary)
                }
            }
            guard showsParakeetDownload(lang) else {
                // Apple's on-device speech recognition handles this language
                // on this device (or it's one of the 4 Apple-only CJK
                // languages) — Apple manages its own speech-asset install
                // silently, so there's no Parakeet download UI to show.
                return ("Runs on this iPhone — no download needed.", Color.green)
            }
            switch TranscriptionService.shared.modelState {
            case .downloading(let f):
                return ("Downloading the \(lang.englishName) model… \(Int(f * 100))%", Color.jotPageInkSecondary)
            case .loading:
                return ("Loading the \(lang.englishName) model…", Color.jotPageInkSecondary)
            case .ready:
                return ("\(lang.englishName) — ready, runs on this iPhone.", Color.green)
            case .failed(let message):
                return ("Download failed: \(message)", Color.red)
            case .notLoaded:
                return ("Downloads a model that runs on this iPhone.", Color.jotPageInkSecondary)
            }
        }()
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
            .padding(.bottom, 12)
    }

    /// Shown both before the fetch starts and while it is enqueued at 0% — the
    /// two states are indistinguishable to the user and equally out of Jot's
    /// hands, so they say the same true thing.
    private static var unifiedWaitingLine: String {
        "Built in and ready. A more accurate English model (\(unifiedSizeLabel)) "
            + "downloads automatically over Wi-Fi."
    }

    /// Download size of the enhanced English model, summed from the fetcher's
    /// pinned manifest so the number on screen can never drift from what is
    /// actually fetched.
    private static var unifiedSizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: UnifiedEnglishModel.approximateDownloadBytes)
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
                // Quick-switch: the active language + recently used, up top.
                Section("Recent") {
                    ForEach(availableRecentLanguages) { lang in
                        Button {
                            languageBinding.wrappedValue = lang.rawValue
                        } label: {
                            if lang.rawValue == dictationLanguage {
                                Label(lang.displayName, systemImage: "checkmark")
                            } else {
                                Text(lang.displayName)
                            }
                        }
                    }
                }
                Section("All languages") {
                    Picker("Language", selection: languageBinding) {
                        ForEach(availableLanguages) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((LanguageChoice(rawValue: dictationLanguage) ?? .english).englishName)
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
            .accessibilityValue((LanguageChoice(rawValue: dictationLanguage) ?? .english).englishName)
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
            caption: "Rewrites and Ask run on Apple Intelligence — on your iPhone, with Private Cloud Compute for questions across your notes. Nothing to download."
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
        switch RewriteClient.availability {
        case .available:
            return RewriteClient.wouldUsePrivateCloudCompute
                ? "Apple Intelligence · Private Cloud Compute"
                : "Apple Intelligence · Ready"
        case .unavailable:
            return "Apple Intelligence · Off"
        }
    }

    // MARK: - PRIVACY

    private var privacySection: some View {
        settingsSection(
            label: "PRIVACY",
            caption: "Dictation stays on your iPhone. Ask and long rewrites use Apple's Private Cloud Compute — end-to-end encrypted, never stored. No accounts, no telemetry; only feedback you send is ever transmitted."
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
                Text("30 min").tag(TimeInterval(1800))
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

    // MARK: - Your Data (transcript import / export)

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("YOUR DATA")

            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(spacing: 0) {
                    Button { exportTranscripts() } label: {
                        settingsIconRow(
                            systemImage: "square.and.arrow.up",
                            tint: JotDesign.JotSemanticIcon.helpSupport,
                            shaded: JotDesign.JotSemanticIcon.helpSupportShaded,
                            title: "Export transcripts",
                            trailing: { EmptyView() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Export transcripts")
                    .accessibilityHint("Saves all your transcripts to a file you can keep in Files or iCloud Drive.")

                    cardDivider

                    Button { showTranscriptImporter = true } label: {
                        settingsIconRow(
                            systemImage: "square.and.arrow.down",
                            tint: JotDesign.JotSemanticIcon.helpSupport,
                            shaded: JotDesign.JotSemanticIcon.helpSupportShaded,
                            title: "Import transcripts",
                            trailing: { EmptyView() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Import transcripts")
                    .accessibilityHint("Restores transcripts from a file you exported earlier. Duplicates are skipped.")
                }
            }

            Text("A private, on-device copy of every transcript — independent of iCloud backup. Importing skips anything already in your library.")
                .font(.system(size: 12))
                .foregroundStyle(Color.jotPageInkCaption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        .padding(.bottom, 8)
        .fileExporter(
            isPresented: $showTranscriptExporter,
            document: transcriptExportDoc,
            contentType: .json,
            defaultFilename: "Jot-Transcripts"
        ) { result in
            switch result {
            case .success:
                backupAlertMessage = "Transcripts exported. Keep this file somewhere safe — Files or iCloud Drive."
            case .failure(let error):
                backupAlertMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showTranscriptImporter,
            allowedContentTypes: [.json]
        ) { result in
            importTranscripts(result)
        }
        .alert("Transcripts", isPresented: Binding(
            get: { backupAlertMessage != nil },
            set: { if !$0 { backupAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { backupAlertMessage = nil }
        } message: {
            Text(backupAlertMessage ?? "")
        }
    }

    private func exportTranscripts() {
        do {
            let data = try TranscriptBackup.exportData()
            transcriptExportDoc = TranscriptBackupDocument(data: data)
            showTranscriptExporter = true
        } catch {
            backupAlertMessage = "Couldn't prepare the export: \(error.localizedDescription)"
        }
    }

    private func importTranscripts(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let outcome = try TranscriptBackup.importData(data)
                backupAlertMessage = "Imported \(outcome.imported) transcript\(outcome.imported == 1 ? "" : "s")"
                    + (outcome.skipped > 0 ? ", skipped \(outcome.skipped) already in your library." : ".")
            } catch {
                backupAlertMessage = (error as? TranscriptBackup.ImportError)?.errorDescription
                    ?? "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            backupAlertMessage = "Import cancelled: \(error.localizedDescription)"
        }
    }

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

                    // "Use Apple speech engine" toggle — revealed by the
                    // 5-tap Version gesture. The
                    // Diarization Lab that formerly led this block graduated to
                    // the shipped Speaker Notes feature, so its row is gone.
                    if hiddenRowsRevealed {
                        cardDivider

                        settingsIconRow(
                            systemImage: "waveform",
                            tint: JotDesign.JotSemanticIcon.version,
                            shaded: JotDesign.JotSemanticIcon.versionShaded,
                            title: "Use Apple speech engine",
                            trailing: {
                                Toggle("", isOn: Binding(
                                    get: {
                                        // Locked ON where Jot's own engine can't run
                                        // (sub-14-Pro / non-M1) — Apple is the only option.
                                        TranscriptionService.parakeetUsable ? useAppleDictationForEnglish : true
                                    },
                                    set: { useAppleDictationForEnglish = $0 }
                                ))
                                .labelsHidden()
                                .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                                .disabled(!TranscriptionService.parakeetUsable)
                                .onChange(of: useAppleDictationForEnglish) { _, newValue in
                                    AppGroup.useAppleDictationForEnglish = newValue
                                    // The user's LAST EXPLICIT choice wins: an
                                    // explicit engine change here (either
                                    // direction) disarms any pending
                                    // download-on-charge auto-switch so it can't
                                    // later override this. The download itself is
                                    // left running — the on-disk model is still
                                    // useful, and the upgrade sheet then offers an
                                    // instant switch instead of re-downloading.
                                    AppGroup.parakeetSwitchArmed = false
                                    // Picking an engine changes whether English
                                    // routes to the unified model, so bring it in
                                    // line either way: Apple ON drops the resident
                                    // encoder, Apple OFF prepares (and, first
                                    // time, starts fetching) it.
                                    UnifiedEnglishModel.syncWithRouting()
                                    if newValue {
                                        TranscriptionService.shared.preinstallAppleAssets()
                                    } else {
                                        // Turning Apple OFF == taking the Parakeet upgrade;
                                        // clear the nudge + reset the count so it matches the
                                        // nudge's own switch path.
                                        AppGroup.showParakeetUpgradeNudge = false
                                        DictationStats.resetAppleDictationCount()
                                        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)
                                    }
                                }
                                .accessibilityLabel("Use Apple speech engine")
                            }
                        )

                        cardDivider

                        // Punctuation model status — the download is deliberately
                        // silent (discretionary Wi-Fi fetch, no user action), which
                        // meant NO way to tell whether a dictation used it (owner,
                        // 2026-08-31: "I don't know if I'm using the new engine or
                        // not"). Read-only; the fetch needs no controls because it
                        // retries itself at every launch until installed.
                        settingsIconRow(
                            systemImage: "text.badge.checkmark",
                            tint: JotDesign.JotSemanticIcon.version,
                            shaded: JotDesign.JotSemanticIcon.versionShaded,
                            title: "Punctuation model",
                            subline: punctuationModelStatusLine,
                            trailing: { EmptyView() }
                        )
                        .onAppear { refreshPunctuationModelStatus() }

                        cardDivider

                        // TEMPORARY owner test: English final transcript from
                        // Moonshine v2 (Medium Streaming). See MoonshineEnglishTest.
                        settingsIconRow(
                            systemImage: "moon.stars",
                            tint: JotDesign.JotSemanticIcon.version,
                            shaded: JotDesign.JotSemanticIcon.versionShaded,
                            title: "Moonshine v2 for English (test)",
                            subline: moonshineStatusLine,
                            trailing: {
                                Toggle("", isOn: $moonshineEnglishTest)
                                    .labelsHidden()
                                    .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                                    .onChange(of: moonshineEnglishTest) { _, on in
                                        AppGroup.defaults.set(on, forKey: AppGroup.Keys.moonshineEnglishTest)
                                        if on { MoonshineEnglishTest.shared.prepareIfNeeded() }
                                    }
                            }
                        )

                        cardDivider

                    }

                    cardDivider

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

                    NavigationLink {
                        JotForMacView()
                    } label: {
                        settingsIconRow(
                            systemImage: "laptopcomputer",
                            tint: JotDesign.JotSemanticIcon.macApp,
                            shaded: JotDesign.JotSemanticIcon.macAppShaded,
                            title: "Jot for Mac",
                            subline: "Dictate on your Mac too",
                            trailing: { RowChevron() }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jot for Mac")
                    .accessibilityHint("Opens the Jot for Mac screen")

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

    // MARK: - Hidden rows (5-tap reveal)

    /// Count taps on the Version row; reveal the hidden rows on the 5th.
    private func handleVersionTap() {
        guard !hiddenRowsRevealed else { return }
        versionTapCount += 1
        if versionTapCount >= 5 {
            withAnimation { hiddenRowsRevealed = true }
            // Persist the reveal across launches (read back on appear).
            AppGroup.defaults.set(true, forKey: AppGroup.Keys.hiddenSettingsRevealed)
        }
    }
}


#Preview {
    SettingsView()
        .environment(TranscriptionService())
}

/// Lightweight JSON `FileDocument` wrapper for `.fileExporter` — carries the
/// `TranscriptBackup.exportData()` bytes out to Files / iCloud Drive.
struct TranscriptBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
