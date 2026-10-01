import Foundation
import JotVocabCore
import os

/// Drains the vocabulary corrections the keyboard queued ("Add to Vocabulary"
/// on a selection) into `VocabularyLearning.apply` — the one correction path
/// every surface takes (Learn from Corrections).
///
/// `VocabularyStore`'s file lives in the main app's private Application Support
/// (not the App Group), so the keyboard can't write it. It queues Codable
/// `Correction`s into `AppGroup.Keys.pendingVocabCorrections` and posts
/// `vocabAddRequested`; the app drains here on that ping and on foreground.
/// A selection is queued as `.correct(heard: "", term:)` — a term with no
/// misheard form, which adds it without re-casing an existing term (the
/// selection may be sentence-start capitalized). Words an older keyboard build
/// queued as plain strings (`AppGroup.Keys.pendingVocabAdds`) drain the same way.
///
/// The keyboard already applied the (English) common-word guard for its own
/// immediate feedback; a plain add is re-checked here in the dictation
/// language as defense in depth.
@MainActor
enum VocabularyAddInbox {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "VocabularyAddInbox"
    )

    private static var isDraining = false

    static func drain() async {
        // The ping and the foreground drain can overlap; the queue is cleared
        // before applying, so a second pass would find it empty anyway — this
        // just keeps one pass at a time.
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        // Clear first so a crash mid-apply can't replay the queue forever
        // (apply is idempotent on the list, but not on the store's counters).
        let queued = take([Correction].self, key: AppGroup.Keys.pendingVocabCorrections) ?? []
        let legacy = (take([String].self, key: AppGroup.Keys.pendingVocabAdds) ?? [])
            .map { Correction.correct(heard: "", term: $0) }
        let corrections = legacy + queued
        guard !corrections.isEmpty else { return }

        let resource = LanguageChoice.current.commonWordsResource
        var added = 0
        for correction in corrections {
            // A plain add (no heard form) of an everyday word is noise.
            if case .correct(let heard, let word, _, _, _) = correction,
               heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !CommonWords.isCommon(trimmed.lowercased(), resource: resource) else { continue }
            }
            if case .added = await VocabularyLearning.shared.apply(correction).outcome { added += 1 }
        }
        if added > 0 {
            log.info("added \(added, privacy: .public) keyboard-queued vocabulary term(s)")
        }
    }

    private static func take<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        AppGroup.defaults.removeObject(forKey: key)
        return try? JSONDecoder().decode(type, from: data)
    }
}
