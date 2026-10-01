//
//  LanguageStep.swift
//  Jot
//
//  Wizard panel W2 — "What language will you speak?" (inserted right after
//  Welcome). The user picks a dictation LANGUAGE; the transcription stack
//  resolves the model automatically:
//
//    - English → the bundled Parakeet v2 (or the 110M on sub-6GB devices) —
//      NO download, instant, the common path.
//    - Any European language → one shared Parakeet Ultra multilingual model
//      (post-trained v3), downloaded once (~632 MB). One download unlocks every European
//      language; switching among them later is free.
//
//  This is the wizard sibling of the Settings → Dictation language picker
//  (`SettingsView.languageRow` / `languageStatusRow`). Both surfaces read/write
//  the single `AppGroup.transcriptionLanguage` key and drive the same
//  `TranscriptionService.shared.handleLanguageChange()` (evict the old model,
//  download + warm the new one), so they stay in lockstep.
//
//  Look/behaviour reference: `docs/multilingual-dictation/design.md §5.2` +
//  `docs/multilingual-dictation/mockup/language-step.html` (recreated natively
//  with real Jot tokens — light theme by default).
//
//  Advance gate (design §5.2): Continue is enabled when the resolved model is
//  on disk. English is always satisfied (bundled). A European language is
//  satisfied once its Ultra download completes; while downloading, Continue is
//  disabled. The step is also skippable — Skip leaves the system-locale default
//  in place and the model can be fetched later from Settings.
//
//  No recording is started here, so the wizard teardown / warm-hold contract is
//  unaffected (only W6's keyboard test records).
//

import SwiftUI

struct LanguageStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    /// Observe the transcription service so the download / load / ready status
    /// re-renders live as a European v3 model fetches and warms.
    @Environment(TranscriptionService.self) private var transcriptionService

    /// The raw `LanguageChoice` value, mirrored from
    /// `AppGroup.transcriptionLanguage`. That key defaults to English until the
    /// user picks otherwise (here or in Settings) — there is no system-locale
    /// default-seeding yet; `LanguageChoice.fromSystemLocale` exists but is not
    /// wired (deferred). So a fresh install lands on English here.
    @State private var languageRaw: String = AppGroup.transcriptionLanguage

    /// Drives the searchable language-list sheet (mockup state 2).
    @State private var pickerPresented = false

    /// Live per-device language capability (`DictationLanguageAvailability`). `nil`
    /// until the first `.task` resolve completes — the picker sheet shows
    /// every language while unresolved (never an empty picker) and the
    /// Parakeet-download gate falls back to the old `!isEnglish` assumption
    /// for that same brief window. RULE #1: never show a language, or a
    /// "download Parakeet" affordance, that can't actually run on this device.
    @State private var appleLangCodes: Set<String>?

    private var language: LanguageChoice {
        LanguageChoice(rawValue: languageRaw) ?? .english
    }

    /// Languages that actually work on this device. English is always kept
    /// regardless (belt and suspenders — it's always available anyway).
    private var availableLanguages: [LanguageChoice] {
        guard let appleLangCodes else { return LanguageChoice.presentationOrder }
        return LanguageChoice.presentationOrder.filter {
            $0.isEnglish || DictationLanguageAvailability.isAvailable($0, appleCodes: appleLangCodes)
        }
    }

    /// Whether picking `lang` would show our Parakeet-download UI on this
    /// device. Falls back to the pre-capability-check assumption
    /// (`!isEnglish`) while `appleLangCodes` hasn't resolved yet.
    private func showsParakeetDownload(_ lang: LanguageChoice) -> Bool {
        guard let appleLangCodes else { return !lang.isEnglish }
        return DictationLanguageAvailability.usesParakeetDownload(lang, appleCodes: appleLangCodes)
    }

    var body: some View {
        WizardPanel(
            header: WizardHeader(
                style: .core(current: 1),
                onClose: onClose,
                onBack: onBack
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 12)

                WizardItalicTitle(text: "What language will you speak?", size: 29)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityAddTraits(.isHeader)

                Text("Jot transcribes on this iPhone, on the Apple Neural Engine. You can change this anytime in Settings.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 26)

                pickerRow

                statusLine
                    .padding(.top, 12)

                downloadControl

                Spacer(minLength: 24)

                Text("Jot picks the on-device model for your language automatically. You can switch languages later in Settings.")
                    .font(.custom(JotType.frauncesItalicText, size: 13))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        } footer: {
            WizardPrimaryButton(
                title: "Continue",
                isDisabled: !canContinue,
                action: onAdvance
            )
            WizardSecondaryTextButton(title: "Skip", action: onAdvance)
        }
        .sheet(isPresented: $pickerPresented) {
            LanguagePickerSheet(selectedRaw: languageRaw, availableLanguages: availableLanguages) { picked in
                select(picked)
            }
        }
        .task {
            // `resolve()` is idempotent — cheap to re-await if the app
            // already resolved it at launch (`JotApp`'s scene `.task`).
            await DictationLanguageAvailability.resolve()
            appleLangCodes = DictationLanguageAvailability.appleCodes
        }
    }

    // MARK: - Picker row

    /// Tappable field row — current language (English name + native endonym)
    /// with a trailing chevron; tap opens the searchable list sheet.
    private var pickerRow: some View {
        Button {
            pickerPresented = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.englishName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                    if language.nativeName != language.englishName {
                        Text(language.nativeName)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.jotMute)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jotMute)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictation language")
        .accessibilityValue(language.englishName)
        .accessibilityHint("Choose the language you'll dictate in.")
    }

    // MARK: - Status line (mirrors SettingsView.languageStatusRow)

    /// One-line readiness/download status beneath the picker. English is bundled
    /// (no download); a European language reflects the live download / load /
    /// ready state of its Parakeet v3 model, observed from `modelState`.
    @ViewBuilder
    private var statusLine: some View {
        let (text, tint, ok) = statusContent
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "shippingbox")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private var statusContent: (String, Color, Bool) {
        if language.isEnglish {
            return ("Built in — ready to use, no download.", Color.green, true)
        }
        guard showsParakeetDownload(language) else {
            // Apple's on-device speech recognition handles this language on
            // this device (or it's one of the 4 Apple-only CJK languages) —
            // Apple manages its own speech-asset install silently, so there's
            // no Parakeet download UI to show.
            return ("Runs on this iPhone — no download needed.", Color.green, true)
        }
        switch transcriptionService.modelState {
        case .downloading(let f):
            return ("Downloading — keep Jot open. \(Int(f * 100))%", Color.jotPageInkSecondary, false)
        case .loading:
            return ("Preparing the \(language.englishName) model…", Color.jotPageInkSecondary, false)
        case .ready:
            return ("Ready — runs entirely on this iPhone.", Color.green, true)
        case .failed(let message):
            return ("Download failed: \(message)", Color.red, false)
        case .notLoaded:
            if modelOnDisk {
                return ("Ready — runs entirely on this iPhone.", Color.green, true)
            }
            return ("Downloads a ~632 MB model that runs entirely on this iPhone.", Color.jotPageInkSecondary, false)
        }
    }

    // MARK: - Download control

    /// For a language whose model isn't on disk and isn't already fetching,
    /// show a Download button + (while fetching) a progress bar. Shows
    /// nothing for English (bundled) or for any language Apple's on-device
    /// engine already handles on this device — Apple's own asset install is
    /// silent, so there's nothing of ours to show progress for.
    @ViewBuilder
    private var downloadControl: some View {
        if showsParakeetDownload(language) {
            switch transcriptionService.modelState {
            case .downloading(let f):
                HStack(spacing: 10) {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .tint(Color.jotAccent)
                    Text("\(Int(f * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .padding(.top, 16)
            case .ready:
                EmptyView()
            default:
                // Retry / fallback affordance. Picking a European language
                // ALREADY auto-starts the download (via `select` →
                // `handleLanguageChange`), which flips `modelState` to
                // `.downloading` and renders the progress row above instead of
                // this button. So this button only surfaces when the model is
                // NOT downloading and NOT on disk — i.e. the auto-download
                // hasn't started or failed back to `.notLoaded`/`.failed`. It
                // re-kicks the same fetch.
                if !modelOnDisk {
                    Button {
                        retryDownload()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Download")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.jotAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .accessibilityLabel("Download the \(language.englishName) model")
                }
            }
        }
    }

    // MARK: - State

    /// True when the resolved model for the active language is on disk.
    /// English is always satisfied (bundled in the IPA), as is any language
    /// Apple's on-device engine handles on this device (no Parakeet fetch to
    /// wait on). A language that DOES route to Parakeet is satisfied once its
    /// v3 download has completed.
    private var modelOnDisk: Bool {
        guard showsParakeetDownload(language) else { return true }
        return TranscriptionService.modelsExistOnDiskForSelectedVariant()
    }

    /// Continue gate (design §5.2): enabled when the resolved model is ready.
    private var canContinue: Bool {
        guard showsParakeetDownload(language) else { return true }
        if case .ready = transcriptionService.modelState { return true }
        return modelOnDisk
    }

    /// Persist the picked language and re-prepare the model — exactly the
    /// Settings path. Picking IS the consent: for a European language this
    /// auto-starts the v3 download immediately (the in-wizard pick is the
    /// 4.2.3(ii)-sanctioned trigger), and this step observes its progress via
    /// `modelState`. For English it resolves to the bundled model (no fetch).
    private func select(_ picked: LanguageChoice) {
        guard picked.rawValue != languageRaw else { return }
        languageRaw = picked.rawValue
        AppGroup.transcriptionLanguage = picked.rawValue
        LanguageChoice.recordRecent(picked)
        // Evicts the old model + downloads/warms the newly-selected one.
        transcriptionService.handleLanguageChange()
        // An Apple-routed language (the 4 CJK + Latin-American Spanish, plus
        // any Apple-supported language the user hasn't opted down to Parakeet)
        // installs its per-locale asset through Apple, not our Parakeet
        // download. Kick that install now — at the moment of picking — so the
        // first recording isn't stalled by a mid-session asset download
        // (the same consent-time preinstall the Apple-engine Settings toggle
        // does). Apple's install is unobtrusive, so no download UI is shown.
        if TranscriptionService.activeLanguageUsesApple {
            transcriptionService.preinstallAppleAssets()
        }
    }

    /// Retry the European-model fetch after it failed to start / fell back to
    /// `.notLoaded` (the `default` branch's button). The persisted language
    /// already resolves to that model, so re-running the same warm/prepare pass
    /// re-kicks the download.
    private func retryDownload() {
        transcriptionService.handleLanguageChange()
    }
}

// MARK: - Searchable language list sheet (mockup state 2)

/// The language list — English first by relevance (it's the bundled, instant
/// path), then every supported language alphabetically by English name, each
/// row showing the English name + native endonym. Type-to-search filters on
/// both. English carries a "Built in" badge; the active row carries a check.
private struct LanguagePickerSheet: View {
    let selectedRaw: String
    /// Languages that actually work on this device (`LanguageStep.availableLanguages`) —
    /// already filtered by `DictationLanguageAvailability`; English is always included.
    let availableLanguages: [LanguageChoice]
    let onPick: (LanguageChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// English pinned to the top (the instant, no-download path), then the rest
    /// alphabetically by English name.
    private var ordered: [LanguageChoice] {
        let rest = availableLanguages.filter { !$0.isEnglish }
        return [.english] + rest
    }

    private var filtered: [LanguageChoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered }
        return ordered.filter {
            $0.englishName.localizedCaseInsensitiveContains(q)
                || $0.nativeName.localizedCaseInsensitiveContains(q)
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `LanguageChoice.recentLanguages`, filtered to what's available on this
    /// device (Rule #1 applies to the Recent quick-switch too). Reuses
    /// `availableLanguages` so the same unresolved/English-always behavior
    /// applies without re-deriving it.
    private var availableRecents: [LanguageChoice] {
        LanguageChoice.recentLanguages.filter { availableLanguages.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    ForEach(filtered) { languageRow($0) }
                } else {
                    // Recent languages up top for quick switching — the active
                    // one first, then previously-used, up to five.
                    Section("Recent") {
                        ForEach(availableRecents) { languageRow($0) }
                    }
                    Section("All languages") {
                        ForEach(ordered) { languageRow($0) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search languages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        // Owner prefers light theme by default.
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func languageRow(_ lang: LanguageChoice) -> some View {
        Button {
            onPick(lang)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(lang.englishName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.jotPageInk)
                if lang.nativeName != lang.englishName {
                    Text(lang.nativeName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.jotMute)
                }
                Spacer(minLength: 8)
                if lang.isEnglish {
                    Text("Built in")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.jotMute)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.jotMute.opacity(0.4), lineWidth: 0.5)
                        )
                }
                if lang.rawValue == selectedRaw {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LanguageStep(onClose: {}, onBack: {}, onAdvance: {})
        .environment(TranscriptionService())
}
