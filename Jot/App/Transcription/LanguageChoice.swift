import FluidAudio
import Foundation

/// User-facing dictation **language** — the control that backs the Settings
/// language picker (and, later, a wizard step). The user picks a language; the
/// transcription stack resolves the model + the FluidAudio script hint
/// automatically. Mirrors the shipped Jot **Mac** app's `LanguageChoice`
/// (`~/code/jot/Sources/Transcription/LanguageChoice.swift`,
/// `docs/multilingual-dictation/design.md`), trimmed to the mobile bucket set:
/// English + the Parakeet v3 European union. No Japanese / Qwen3 / Nemotron on
/// mobile.
///
/// ## Mapping
/// - **English → bundled Parakeet v2** (or the 110M on sub-6GB devices) — the
///   existing device-capability path, **no download**.
/// - **Every European language → Parakeet v3** (one shared multilingual model,
///   downloaded once) + the FluidAudio Latin/Cyrillic script hint where one
///   exists. Languages with no hint case (Danish, Dutch, Finnish, Greek,
///   Hungarian, Swedish) fall back to v3 auto-detect.
///
/// ## FIRST PASS scope
/// European resolves to **int8 v3 (`AsrModelVersion.v3`) on every device** — no
/// int4 variant, no device-RAM gating yet (both tracked in the design doc §4,
/// pending an on-device memory measurement). The persisted raw value lives in
/// `AppGroup.transcriptionLanguage`; any unknown/unset tag resolves to
/// `.english`, so a stale write can never brick dictation.
enum LanguageChoice: String, CaseIterable, Sendable, Identifiable {
    case english
    // European — Latin script:
    case spanish, french, german, italian, portuguese, romanian,
         polish, czech, slovak, slovenian, croatian, bosnian
    // European — Cyrillic script:
    case russian, ukrainian, belarusian, bulgarian, serbian
    // v3-supported but no FluidAudio hint case (auto-detect):
    case danish, dutch, finnish, greek, hungarian, swedish

    var id: String { rawValue }

    /// The active language, resolved from `AppGroup.transcriptionLanguage`.
    /// Unknown / unset / malformed → `.english`.
    static var current: LanguageChoice {
        LanguageChoice(rawValue: AppGroup.transcriptionLanguage) ?? .english
    }

    var isEnglish: Bool { self == .english }

    /// (English name, native endonym). Native == English where there is no
    /// distinct endonym (English).
    private var names: (english: String, native: String) {
        switch self {
        case .english:    return ("English", "English")
        case .spanish:    return ("Spanish", "Español")
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
        default:   return nil
        }
    }
}
