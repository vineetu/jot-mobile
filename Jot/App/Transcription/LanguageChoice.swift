import FluidAudio
import Foundation

/// User-facing dictation **language** — the control that backs the Settings
/// language picker (and, later, a wizard step). The user picks a language; the
/// transcription stack resolves the model + the FluidAudio script hint
/// automatically. Mirrors the shipped Jot **Mac** app's `LanguageChoice`
/// (`~/code/jot/Sources/Transcription/LanguageChoice.swift`,
/// `docs/multilingual-dictation/design.md`), trimmed to the mobile bucket set:
/// English + the Parakeet v3 European union, plus four Apple-only languages
/// FluidAudio has no model for at all (Japanese, Korean, Mandarin, Cantonese —
/// see `isAppleOnly`). No Qwen3 / Nemotron on mobile.
///
/// ## Mapping
/// - **English → bundled Parakeet v2** (or the 110M on sub-6GB devices) — the
///   existing device-capability path, **no download**.
/// - **Every European language → Parakeet v3** (one shared multilingual model,
///   downloaded once) + the FluidAudio Latin/Cyrillic script hint where one
///   exists. Languages with no hint case (Danish, Dutch, Finnish, Greek,
///   Hungarian, Swedish) fall back to v3 auto-detect.
/// - **Japanese / Korean / Mandarin / Cantonese → Apple's on-device
///   `SpeechTranscriber`, always** (`isAppleOnly`) — FluidAudio ships no model
///   for these, so there is no fallback engine and no vocabulary rescore.
///
/// ## FIRST PASS scope
/// European resolves to **Parakeet Ultra (`AsrModelVersion.ultra`, post-trained v3, int8 encoder) on every device** — no
/// int4 variant, no device-RAM gating yet (both tracked in the design doc §4,
/// pending an on-device memory measurement). The persisted raw value lives in
/// `AppGroup.transcriptionLanguage`; any unknown/unset tag resolves to
/// `.english`, so a stale write can never brick dictation.
enum LanguageChoice: String, CaseIterable, Sendable, Identifiable {
    case english
    // European — Latin script (Parakeet v3), plus Latin-American Spanish which
    // is Apple-only (locale es-MX): Parakeet's Spanish is European, so the
    // Latin-American variant routes exclusively through Apple's engine.
    case spanish, spanishLatinAmerica, french, german, italian, portuguese, romanian,
         polish, czech, slovak, slovenian, croatian, bosnian
    // European — Cyrillic script:
    case russian, ukrainian, belarusian, bulgarian, serbian
    // v3-supported but no FluidAudio hint case (auto-detect):
    case danish, dutch, finnish, greek, hungarian, swedish
    // Apple-only — FluidAudio has NO model for these at all (not even
    // auto-detect); they route exclusively through Apple's on-device
    // `SpeechTranscriber` (see `isAppleOnly`/`appleLocaleIdentifier` below).
    // Cantonese ships as TWO rows (device-verified against the iOS 26
    // SpeechTranscriber catalog): Hong Kong Cantonese is `zh-HK`, Mainland
    // Cantonese is `yue-CN`. (`yue-HK` does not exist — it aliases to
    // `zh-HK`.) Traditional-script Mandarin (`zh-TW`) ships as its own row
    // (owner call, 2026-07-16) — same Apple-only path as the rest.
    case japanese, korean, chineseMandarin, cantoneseHongKong, chineseTraditional
    // LEGACY rawValue PIN — do NOT "clean up" to "cantoneseMainland".
    // The originally-shipped single `cantonese` case (builds 267–278) was
    // locale yue-CN, i.e. Mainland Cantonese. Pinning THIS case's rawValue
    // back to "cantonese" makes every already-stored selection, historical
    // `Transcript.language` string, and MRU-recents entry decode straight to
    // the correct case with ZERO migration code. `cantoneseHongKong` is new,
    // so it keeps its implicit "cantoneseHongKong" rawValue.
    case cantoneseMainland = "cantonese"

    var id: String { rawValue }

    /// The active language, resolved from `AppGroup.transcriptionLanguage`.
    /// Unknown / unset / malformed → `.english`.
    static var current: LanguageChoice {
        LanguageChoice(rawValue: AppGroup.transcriptionLanguage) ?? .english
    }

    var isEnglish: Bool { self == .english }

    /// `true` for languages FluidAudio has no model for at all (not bundled,
    /// not v3, not even auto-detect) — these MUST route through Apple's
    /// on-device `SpeechTranscriber` for every pass (streaming + stop-pass),
    /// and MUST NOT fall back to FluidAudio on an Apple failure the way
    /// English's Apple-engine toggle does, because there is no FluidAudio
    /// model to fall back to. `fluidAudioLanguage` is irrelevant/unused for
    /// these.
    var isAppleOnly: Bool {
        switch self {
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional: return true
        // Latin-American Spanish: Parakeet only ships European Spanish, so this
        // variant is forced through Apple (which has es-MX). Treating it as
        // Apple-only also keeps the Parakeet-upgrade nudge away from it.
        case .spanishLatinAmerica: return true
        default: return false
        }
    }

    /// Bundle resource base name (`<name>.txt`) of the high-frequency
    /// common-word list for THIS language, used by the vocabulary gate's
    /// common-word guard (`CommonWords`). `nil` → no list ships for this
    /// language, so the guard is inert for it (the plausibility + confidence
    /// guards still apply). English is the original `common-words`; the
    /// Parakeet-v3 European set has per-language lists (`common-words-<code>`).
    /// `nil` for the Apple-only CJK languages (vocab correction never runs for
    /// them) and for Belarusian (no reliable frequency data — falls back to no
    /// guard, unchanged from before per-language lists shipped).
    var commonWordsResource: String? {
        switch self {
        case .english: return "common-words"
        case .spanish, .spanishLatinAmerica: return "common-words-es"
        case .french: return "common-words-fr"
        case .german: return "common-words-de"
        case .italian: return "common-words-it"
        case .portuguese: return "common-words-pt"
        case .romanian: return "common-words-ro"
        case .polish: return "common-words-pl"
        case .czech: return "common-words-cs"
        case .slovak: return "common-words-sk"
        case .slovenian: return "common-words-sl"
        // Croatian/Bosnian/Serbian share the Serbo-Croatian frequency list.
        case .croatian, .bosnian, .serbian: return "common-words-sr"
        case .russian: return "common-words-ru"
        case .ukrainian: return "common-words-uk"
        case .bulgarian: return "common-words-bg"
        case .danish: return "common-words-da"
        case .dutch: return "common-words-nl"
        case .finnish: return "common-words-fi"
        case .greek: return "common-words-el"
        case .hungarian: return "common-words-hu"
        case .swedish: return "common-words-sv"
        // No reliable frequency data (Belarusian) → no guard, unchanged.
        case .belarusian: return nil
        // Apple-only CJK — vocab correction never runs for these.
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional: return nil
        }
    }

    /// Primary language subtag for `VocabularyCorrector` (the model-free
    /// vocabulary corrector), or `nil` when no frequency list ships.
    ///
    /// DERIVED from `commonWordsResource` on purpose: the corrector's safety
    /// rests entirely on the common-word brake, so the code it is served under
    /// and the list that brakes it must be the same decision. Two hand-written
    /// tables would eventually disagree, and the failure mode is a language
    /// running with the brake pointed at the wrong list.
    ///
    /// Being non-nil is NOT permission to run — `VocabularyCorrector.isServed`
    /// still has to clear the code against its measured table, which is what
    /// keeps Croatian/Serbian/Bosnian (they share the `sr` list), Slovenian and
    /// Belarusian off. Fail closed.
    var correctorLanguageCode: String? {
        guard let resource = commonWordsResource else { return nil }
        guard resource != "common-words" else { return "en" }
        return String(resource.dropFirst("common-words-".count))
    }

    /// The language code handed to `FillerWordCleaner.clean(_:language:)`, or
    /// `nil` for languages whose transcripts must not be filler-cleaned at all.
    ///
    /// `"en"` selects the full English chain (fillers + `NumberNormalizer`).
    /// es/fr/de/it/pt select the per-language NON-LEXICAL hesitation lists the
    /// shared pipeline ships (`jot-shared` §5) — fillers ONLY, **never**
    /// `NumberNormalizer`: its spelled-cardinal rules are English-hardcoded and
    /// mis-convert Romance output (French "six cents" = 600 → "6¢"; that exact
    /// regression is why the Mac gates it the same way). Everything else
    /// (Japanese, Polish, Russian, …) returns `nil`: no filler lists exist for
    /// them, so their transcripts pass through untouched.
    ///
    /// Mirrors `LanguageChoice.fillerLanguageCode` in the Mac app
    /// (`~/code/jot/Sources/Transcription/LanguageChoice.swift`) — the two must
    /// agree, since both consume the same shared word lists.
    var fillerLanguageCode: String? {
        switch self {
        case .english: return "en"
        // Latin-American Spanish routes through Apple (which never reaches the
        // cleanup chain), but the hesitation sounds are the same Spanish ones —
        // map it correctly rather than leaving a hole if it ever routes to v3.
        case .spanish, .spanishLatinAmerica: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .italian: return "it"
        case .portuguese: return "pt"
        // No hesitation list ships for these — pass through untouched.
        case .romanian, .polish, .czech, .slovak, .slovenian, .croatian, .bosnian,
             .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return nil
        // Apple-only CJK — never reaches the Parakeet cleanup chain anyway.
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional:
            return nil
        }
    }

    /// Whether the downloaded punctuation / true-casing model
    /// (`PunctuationRestorer`) runs for this language. `nil` = skip it and keep
    /// the engine's own punctuation.
    ///
    /// Deliberately a per-language switch rather than an `isEnglish` check, so
    /// enabling a language later is one line here — the same shape as
    /// `fillerLanguageCode`, for the same reason.
    ///
    /// **English-only today, and that is an evidence gate, not a technical one.**
    /// The model shipped is the English export; the same author publishes a
    /// 47-language build at nearly the same size (233 MB vs 210 MB fp32) which
    /// covers 17 of Jot's 24 Parakeet-routed languages. It is not enabled because
    /// the blind evaluation behind this feature was English-only — see
    /// `docs/research/granite-turboctc/PUNCTUATION.md`. Enable a language when it
    /// has passed the same judging, not before.
    ///
    /// This is a per-LANGUAGE gate, not a per-engine one: English returns "en"
    /// on BOTH engines (owner call 2026-08-30 — "just enable it for both"), so
    /// an English dictation routed through Apple's `SpeechTranscriber` is
    /// re-punctuated the same as a Parakeet one. That is safe to layer because
    /// `PunctuationRestorer` strips existing case/punctuation before re-adding
    /// its own — Apple's built-in punctuation is replaced, never doubled.
    var punctuationLanguageCode: String? {
        switch self {
        case .english: return "en"
        // Not yet evaluated. The 47-language model would cover most of these.
        case .spanish, .spanishLatinAmerica, .french, .german, .italian, .portuguese,
             .romanian, .polish, .czech, .slovak, .slovenian, .croatian, .bosnian,
             .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return nil
        // CJK: not a candidate for THIS model regardless of evaluation — its
        // label set is `.` `,` `?` (not `。` `、`) and per-character true-casing
        // is meaningless for these scripts. Needs the 47-language build AND a
        // per-language eval if ever revisited.
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional:
            return nil
        }
    }

    /// Whether the CTC custom-vocabulary boost (keyword spot + merge) runs
    /// for this language. Two independent reasons force a skip, both covered
    /// here so the gate is a single named flag rather than scattered checks:
    ///
    /// - **No inter-word spaces** (Japanese, Mandarin, Cantonese): the vocab
    ///   pipeline splits transcript text on the literal space character to
    ///   find word spans (`VocabularyGate` / `VocabularyRescorerHolder` /
    ///   `AppleDictationEngine.words(from:)`); these scripts would collapse an
    ///   entire clause into one "word" and break the merge.
    /// - **CTC-scorer script mismatch** (Korean): the scorer
    ///   (`parakeet-ctc-110m`) is English/Latin-trained, and the merge IS
    ///   reachable on the Apple path (Apple emits synthetic `tokenTimings`),
    ///   so running it over Korean audio can false-positive-inject a Latin
    ///   term into otherwise-correct Korean text. Korean stays OFF pending an
    ///   on-device Korean + Latin-term false-positive test (see the
    ///   apple-only-languages plan's as-built note) — "safe no-op" was an
    ///   unverified assumption, and vocab trustworthiness is not worth the
    ///   risk here.
    ///
    /// Latin-American Spanish is also listed (it routes to Apple): this keeps
    /// the shipped behavior unchanged. European Spanish (Parakeet) keeps vocab
    /// on; enabling LatAm Spanish for parity is a deliberate future call, not
    /// a silent flip. Net: currently equivalent to `!isAppleOnly`, but written
    /// as an explicit list so a future no-word-space FluidAudio language
    /// (e.g. Thai) is skipped too rather than wrongly treated as eligible.
    var isVocabEligible: Bool {
        switch self {
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional, .spanishLatinAmerica:
            return false
        default:
            return true
        }
    }

    /// BCP-47 locale identifier for Apple's `SpeechTranscriber`, threaded into
    /// `AppleStreamingSession`/`AppleDictationEngine`. Non-nil for EVERY
    /// language Apple's modern engine actually supports (device-verified:
    /// de/en/es/fr/it/pt/ja/ko/zh/yue) — Apple is the DEFAULT engine for all
    /// of them. `nil` for the European languages Apple can't do (Polish,
    /// Czech, Ukrainian, …), which stay FluidAudio-only.
    var appleLocaleIdentifier: String? {
        switch self {
        case .english:         return "en-US"
        case .spanish:         return "es-ES"
        case .spanishLatinAmerica: return "es-MX"
        case .french:          return "fr-FR"
        case .german:          return "de-DE"
        case .italian:         return "it-IT"
        case .portuguese:      return "pt-BR"
        case .japanese:        return "ja-JP"
        case .korean:          return "ko-KR"
        case .chineseMandarin: return "zh-CN"
        case .chineseTraditional: return "zh-TW"
        case .cantoneseHongKong: return "zh-HK"
        case .cantoneseMainland: return "yue-CN"
        default:               return nil
        }
    }

    /// Whether Apple's modern `SpeechTranscriber` supports this language at
    /// all — i.e. Apple is a usable engine for it. The 10 languages with an
    /// `appleLocaleIdentifier`. Apple is the DEFAULT engine for these;
    /// FluidAudio/Parakeet is the optional upgrade where it also exists
    /// (English + the 5 European overlaps) and the ONLY engine for the
    /// European languages Apple lacks.
    var isAppleSupported: Bool { appleLocaleIdentifier != nil }

    /// (English name, native endonym). Native == English where there is no
    /// distinct endonym (English).
    private var names: (english: String, native: String) {
        switch self {
        case .english:    return ("English", "English")
        case .spanish:    return ("Spanish", "Español")
        // Region qualifier lives in the English name only — repeating it in the
        // endonym ("Español (Latinoamérica)") made the picker row wrap to three
        // lines and hyphenate mid-word. Short native keeps the row clean.
        case .spanishLatinAmerica: return ("Spanish (Latin America)", "Español")
        case .french:     return ("French", "Français")
        case .german:     return ("German", "Deutsch")
        case .italian:    return ("Italian", "Italiano")
        case .portuguese: return ("Portuguese", "Português")
        case .romanian:   return ("Romanian", "Română")
        case .polish:     return ("Polish", "Polski")
        case .czech:      return ("Czech", "Čeština")
        case .slovak:     return ("Slovak", "Slovenčina")
        case .slovenian:  return ("Slovenian", "Slovenščina")
        case .croatian:   return ("Croatian", "Hrvatski")
        case .bosnian:    return ("Bosnian", "Bosanski")
        case .russian:    return ("Russian", "Русский")
        case .ukrainian:  return ("Ukrainian", "Українська")
        case .belarusian: return ("Belarusian", "Беларуская")
        case .bulgarian:  return ("Bulgarian", "Български")
        case .serbian:    return ("Serbian", "Српски")
        case .danish:     return ("Danish", "Dansk")
        case .dutch:      return ("Dutch", "Nederlands")
        case .finnish:    return ("Finnish", "Suomi")
        case .greek:      return ("Greek", "Ελληνικά")
        case .hungarian:  return ("Hungarian", "Magyar")
        case .swedish:    return ("Swedish", "Svenska")
        case .japanese:        return ("Japanese", "日本語")
        case .korean:          return ("Korean", "한국어")
        case .chineseMandarin: return ("Chinese (Mandarin)", "中文（简体）")
        case .chineseTraditional: return ("Chinese (Traditional)", "中文（繁體）")
        // Both rows share the short native endonym (粵語); the region
        // qualifier lives in the English name only — same treatment as
        // Latin-American Spanish above, keeping the picker row clean.
        case .cantoneseHongKong: return ("Cantonese (Hong Kong)", "粵語")
        case .cantoneseMainland: return ("Cantonese (Mainland China)", "粵語")
        }
    }

    /// English name — the stable sort key.
    var englishName: String { names.english }

    /// Native endonym (may be non-Latin).
    var nativeName: String { names.native }

    /// Picker row label: "English — native" (just the English name when the
    /// endonym is identical, e.g. English).
    var displayName: String {
        let n = names
        return n.native == n.english ? n.english : "\(n.english) — \(n.native)"
    }

    /// The FluidAudio v3 script hint (Latin/Cyrillic filter). `nil` for English
    /// (v2 is monolingual and ignores it) and for European languages with no
    /// hint case (auto-detect). Only the v3 European paths exercise the filter.
    var fluidAudioLanguage: Language? {
        switch self {
        case .english:    return nil
        case .spanish:    return .spanish
        case .french:     return .french
        case .german:     return .german
        case .italian:    return .italian
        case .portuguese: return .portuguese
        case .romanian:   return .romanian
        case .polish:     return .polish
        case .czech:      return .czech
        case .slovak:     return .slovak
        case .slovenian:  return .slovenian
        case .croatian:   return .croatian
        case .bosnian:    return .bosnian
        case .russian:    return .russian
        case .ukrainian:  return .ukrainian
        case .belarusian: return .belarusian
        case .bulgarian:  return .bulgarian
        case .serbian:    return .serbian
        // v3-supported but no FluidAudio hint case → auto-detect.
        case .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return nil
        // Apple-only — FluidAudio has no model at all, so there is no
        // script hint to give it; these never reach a FluidAudio call.
        // Latin-American Spanish is forced to Apple too (no FluidAudio call).
        case .japanese, .korean, .chineseMandarin, .cantoneseHongKong, .cantoneseMainland,
             .chineseTraditional, .spanishLatinAmerica:
            return nil
        }
    }

    /// ISO-639 language code (e.g. `"en"`, `"fr"`). Inverse of
    /// `fromLanguageCode`. Used by the Translate sheet to exclude the
    /// transcript's own language from the target list and to pass a source-
    /// language hint to Apple Translation.
    var isoCode: String {
        switch self {
        case .english:    return "en"
        case .spanish:    return "es"
        // Latin-American Spanish is still "Spanish" for translation/display.
        case .spanishLatinAmerica: return "es"
        case .french:     return "fr"
        case .german:     return "de"
        case .italian:    return "it"
        case .portuguese: return "pt"
        case .romanian:   return "ro"
        case .polish:     return "pl"
        case .czech:      return "cs"
        case .slovak:     return "sk"
        case .slovenian:  return "sl"
        case .croatian:   return "hr"
        case .bosnian:    return "bs"
        case .russian:    return "ru"
        case .ukrainian:  return "uk"
        case .belarusian: return "be"
        case .bulgarian:  return "bg"
        case .serbian:    return "sr"
        case .danish:     return "da"
        case .dutch:      return "nl"
        case .finnish:    return "fi"
        case .greek:      return "el"
        case .hungarian:  return "hu"
        case .swedish:    return "sv"
        case .japanese:        return "ja"
        case .korean:          return "ko"
        // Traditional-script Mandarin is still "zh" for Translate/display,
        // same treatment as the two Cantonese rows sharing "yue".
        case .chineseMandarin, .chineseTraditional: return "zh"
        // Both Cantonese rows are the same spoken language (yue). Keeping the
        // ISO code as "yue" for HK too (rather than zh-HK's "zh") keeps it
        // distinct from Mandarin for Translate/exclusion and lets the device
        // availability resolver key both rows on Apple's Cantonese support.
        case .cantoneseHongKong, .cantoneseMainland: return "yue"
        }
    }

    /// Resolve a stored `Transcript.language` raw value (or `nil`) to a
    /// `LanguageChoice`, treating unknown/`nil` as English (multilingual
    /// dictation only just shipped, so historical rows are English).
    static func fromStored(_ raw: String?) -> LanguageChoice {
        guard let raw, let lang = LanguageChoice(rawValue: raw) else { return .english }
        return lang
    }

    /// Alphabetical by English name — a single predictable list (the picker can
    /// add type-to-search later).
    static var presentationOrder: [LanguageChoice] {
        allCases.sorted {
            $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
        }
    }

    // MARK: - Recent languages (MRU quick-switch)

    private static let recentsKey = "jot.dictation.recentLanguages"

    /// How many recent languages the picker surfaces at the top.
    static let maxRecents = 5

    /// Most-recently-used dictation languages (≤ `maxRecents`), the active one
    /// always first. Shared across the wizard + Settings pickers via the App
    /// Group, so it's consistent everywhere and survives app updates. The active
    /// language is forced to the front so the list always reflects the current
    /// selection even if it was set outside the picker (watch, deep link).
    static var recentLanguages: [LanguageChoice] {
        let stored = (AppGroup.defaults.stringArray(forKey: recentsKey) ?? [])
            .compactMap { LanguageChoice(rawValue: $0) }
        var list = stored
        let active = current
        list.removeAll { $0 == active }
        list.insert(active, at: 0)
        return Array(list.prefix(maxRecents))
    }

    /// Move `language` to the front of the recents list (cap `maxRecents`).
    /// Call whenever the user selects a dictation language.
    static func recordRecent(_ language: LanguageChoice) {
        var raws = AppGroup.defaults.stringArray(forKey: recentsKey) ?? []
        raws.removeAll { $0 == language.rawValue }
        raws.insert(language.rawValue, at: 0)
        AppGroup.defaults.set(Array(raws.prefix(maxRecents)), forKey: recentsKey)
    }

    /// Seed the current language into the recents on first ever use, so the
    /// first language switch still keeps the prior (default) language visible.
    /// Idempotent — a no-op once anything has been recorded.
    static func seedRecentsIfNeeded() {
        let stored = AppGroup.defaults.stringArray(forKey: recentsKey) ?? []
        if stored.isEmpty { recordRecent(current) }
    }

    /// Default language from the system locale, falling back to `.english` when
    /// the locale isn't a supported transcription language. (Not wired as the
    /// persisted default in the first pass — kept for the wizard step.)
    static func fromSystemLocale(_ locale: Locale = .current) -> LanguageChoice {
        guard let code = locale.language.languageCode?.identifier.lowercased() else {
            return .english
        }
        return fromLanguageCode(code) ?? .english
    }

    /// Map an ISO-639 code (e.g. `"de"`) to a `LanguageChoice`; `nil` if
    /// unsupported.
    static func fromLanguageCode(_ code: String) -> LanguageChoice? {
        switch code.lowercased() {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ro": return .romanian
        case "pl": return .polish
        case "cs": return .czech
        case "sk": return .slovak
        case "sl": return .slovenian
        case "hr": return .croatian
        case "bs": return .bosnian
        case "ru": return .russian
        case "uk": return .ukrainian
        case "be": return .belarusian
        case "bg": return .bulgarian
        case "sr": return .serbian
        case "da": return .danish
        case "nl": return .dutch
        case "fi": return .finnish
        case "el": return .greek
        case "hu": return .hungarian
        case "sv": return .swedish
        case "ja": return .japanese
        case "ko": return .korean
        case "zh": return .chineseMandarin
        // "yue" maps to the Mainland row as the canonical Cantonese default
        // (system-locale seeding only; the user can pick the HK row explicitly).
        case "yue": return .cantoneseMainland
        default:   return nil
        }
    }
}
