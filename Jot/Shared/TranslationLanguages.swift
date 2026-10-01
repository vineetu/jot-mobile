import Foundation

/// The languages Apple's on-device Translation framework supports, one primary
/// code each, alphabetical by name. Shared by the app's Translate sheet
/// (features.md §3.9) and the keyboard's Translate pane (§7.16) so both offer
/// the same list.
enum TranslationLanguages {
    struct Language: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let all: [Language] = [
        .init(code: "ar", name: "Arabic"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "en", name: "English"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "it", name: "Italian"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "pl", name: "Polish"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "es", name: "Spanish"),
        .init(code: "th", name: "Thai"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "vi", name: "Vietnamese"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }
}
