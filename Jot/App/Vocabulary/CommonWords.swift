import Foundation
import os.log

/// The bundled high-frequency English word set used by the vocabulary gate's
/// **common-word guard** (`VocabularyGate`). A custom vocabulary correction is
/// never allowed to silently overwrite a word in this set — that is what stops
/// "name" → "Jamy" and "cloud" → "Claude" on confident, correct words.
///
/// Asset: `Resources/common-words.txt` — the top ~24k English words by
/// frequency, **with popular given names removed** so a name a user adds to
/// vocab (Jamie, John, Sarah…) is NOT treated as an untouchable common word and
/// can be learned/applied. Names were stripped via SSA name-popularity (peak
/// share ≥ 0.005) minus a curated dual-meaning allowlist (may/will/mark/rose/
/// grace/april… stay protected — they're common words that happen to also be
/// names). The removed list is audited in
/// `docs/plans/correction-review-names-excluded.txt`. This is a *universal*
/// signal (works for every user, no per-term computation); see
/// docs/plans/adaptive-vocabulary-correction.md §3.2.
///
/// Loaded once, lazily, into a `Set` for O(1) membership.
enum CommonWords {
    /// Lowercased high-frequency word set. Empty if the asset is missing
    /// (the gate then degrades to confidence/margin-only — still safe).
    static let set: Set<String> = load()

    static func isCommon(_ word: String) -> Bool {
        set.contains(word.lowercased())
    }

    private static func load() -> Set<String> {
        let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "VocabularyGate")
        guard
            let url = Bundle.main.url(forResource: "common-words", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            log.error("common-words.txt NOT found in bundle — common-word guard is DISABLED")
            return []
        }
        let set = Set(text.split(separator: "\n").map { String($0).lowercased() })
        log.info("common-words loaded: \(set.count, privacy: .public) words")
        return set
    }
}
