import Foundation
import os

/// Drains words the keyboard queued for "Add to Vocabulary".
///
/// The keyboard's "..." popover lets the user add the selected word to their
/// vocabulary, but `VocabularyStore`'s file lives in the main app's private
/// Application Support (not the App Group), so the keyboard can't write it.
/// Instead the keyboard stages the word into `AppGroup.Keys.pendingVocabAdds`
/// and posts `vocabAddRequested`; the main app runs the authoritative add here.
///
/// This is the *exact* `VocabularyStore.addTerm` the transcript pane uses, minus
/// the "what should this say?" alias step — the keyboard selects an
/// already-correct word, so there's no mis-transcription to map. The keyboard
/// already applied the common-word guard for its own immediate feedback; we
/// re-apply it here as defense in depth (a common word can only be added with an
/// alias, which this path never has).
@MainActor
enum VocabularyAddInbox {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "VocabularyAddInbox"
    )

    static func drain() {
        let key = AppGroup.Keys.pendingVocabAdds
        guard let data = AppGroup.defaults.data(forKey: key),
              let words = try? JSONDecoder().decode([String].self, from: data),
              !words.isEmpty
        else { return }
        // Clear first so a crash mid-add can't replay the whole queue forever.
        AppGroup.defaults.removeObject(forKey: key)

        var added = 0
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if CommonWords.isCommon(trimmed.lowercased()) { continue }
            if VocabularyStore.shared.addTerm(trimmed) != nil { added += 1 }
        }
        if added > 0 {
            log.info("added \(added, privacy: .public) keyboard-shared vocabulary term(s)")
        }
    }
}
