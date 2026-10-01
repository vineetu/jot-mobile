import Foundation
import NaturalLanguage
import Translation
import os

/// A target language as the keyboard's Translate pane offers it (§7.16).
/// `installed` = the source→target pack is on the phone, so the keyboard can
/// translate offline right now; otherwise the pack has to be downloaded from
/// the app (the system's download prompt only works in a foreground app).
struct KeyboardTranslateOption: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let installed: Bool
    var id: String { code }
}

/// On-device translation for the actions pane's **Translate** tile (features.md
/// §5.6 / §7.16): translates the host field's selected text with Apple's
/// Translation framework and hands the result back for an in-place replacement.
///
/// Uses the framework's non-UI session (`TranslationSession(installedSource:
/// target:)`), which works only for language packs already on the phone — a
/// keyboard extension can't show Apple's download prompt. `installedTargets`
/// tells the pane which languages are ready; the rest are offered washed with a
/// pointer to the app, whose Translate sheet (§3.9) triggers the download.
/// Nothing leaves the phone.
@MainActor
final class KeyboardTranslator {
    static let shared = KeyboardTranslator()

    static let timeout: Duration = .seconds(20)

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot.Keyboard",
        category: "translator"
    )

    enum Failure: LocalizedError {
        case notInstalled(String)
        case emptyOutput
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): return "\(name) isn't downloaded yet"
            case .emptyOutput: return "nothing came back"
            case .timedOut: return "it took too long"
            }
        }
    }

    private var task: Task<String, Error>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Best guess at the selection's language: the on-device language
    /// recognizer, else English. Region variants collapse to the primary code
    /// (`zh-Hans` → `zh`) to match `TranslationLanguages`.
    static func detectSource(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage?.rawValue else { return "en" }
        return String(dominant.split(separator: "-").first ?? Substring(dominant))
    }

    /// Codes (from `TranslationLanguages.all`) whose `source`→code pack is
    /// installed. Checked concurrently; local and fast.
    func installedTargets(from source: String) async -> Set<String> {
        let sourceLanguage = Locale.Language(identifier: source)
        let codes = TranslationLanguages.all.map(\.code).filter { $0 != source }
        return await withTaskGroup(of: (String, Bool).self, returning: Set<String>.self) { group in
            for code in codes {
                // `LanguageAvailability` isn't Sendable — give each child its
                // own (it's a lightweight handle onto the system service).
                group.addTask {
                    let status = await LanguageAvailability().status(
                        from: sourceLanguage,
                        to: Locale.Language(identifier: code)
                    )
                    return (code, status == .installed)
                }
            }
            var installed = Set<String>()
            for await (code, ok) in group where ok { installed.insert(code) }
            return installed
        }
    }

    /// Translate `text` from `source` to `target` (ISO codes). Throws
    /// `Failure.notInstalled` when the pack isn't on the phone.
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        cancel()
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        guard status == .installed else { throw Failure.notInstalled(TranslationLanguages.name(for: target)) }

        let work = Task { @MainActor () throws -> String in
            let started = Date()
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            let response = try await session.translate(text)
            let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { throw Failure.emptyOutput }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Self.log.info("keyboard translate \(source, privacy: .public)→\(target, privacy: .public) in \(ms) ms — \(text.count) → \(out.count) chars")
            return out
        }
        task = work
        defer { if task == work { task = nil } }

        let outcome: Result<String, Error> = await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask { await work.result }
            group.addTask {
                do {
                    try await Task.sleep(for: Self.timeout)
                    return .failure(Failure.timedOut)
                } catch {
                    return .failure(CancellationError())
                }
            }
            let first = await group.next() ?? .failure(CancellationError())
            group.cancelAll()
            return first
        }
        if case .failure(let error) = outcome, error is Failure { work.cancel() }
        return try outcome.get()
    }
}
