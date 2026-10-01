import Foundation
import JotVocabCore

/// **Learn from transcript edits** (Learn from Corrections, Mac 1.23 —
/// `EditLearning.swift` there). The iPhone side of `JotVocabCore.EditLearner`:
/// turns one finished edit session (the text when Edit was pressed vs. what
/// was saved) into `Correction`s for `VocabularyLearning.apply`, the one path
/// every correction surface takes.
///
/// `TranscriptDetailView.saveEdit` is the only caller, after the edit is
/// persisted. It captures every string up front, so nothing here re-reads the
/// transcript.
@MainActor
enum EditLearning {

    /// - Parameters:
    ///   - before: the edited field's text when Edit was pressed.
    ///   - after: the text the user saved.
    ///   - raw: what the model itself wrote, for D11 (a word AI cleanup wrote
    ///     was not misheard, so it gets no sounds-like). Empty ⇒ every original
    ///     counts as heard: an Original-tab edit, where the field IS the model's
    ///     text (iOS keeps no separate copy of it once the user hand-edits).
    ///   - reviewText: the transcript's Original text after the save when this
    ///     edit changed it — the text the review records are anchored in — so
    ///     the pair's still-open records close with the edit's verdict. nil for
    ///     a Rewrite-tab edit: the records describe the Original text, which
    ///     that edit didn't touch, so they stay open for the review list.
    /// - Returns: the lessons acted on, so the caller doesn't offer to teach a
    ///   pair this edit already taught.
    @discardableResult
    static func learn(
        transcriptID: UUID, before: String, after: String, raw: String, reviewText: String?
    ) async -> [EditLearner.Lesson] {
        guard before != after else { return [] }
        // No everyday-word list for the active language ⇒ no D8 brake, so
        // nothing is learned — the same rule the model-free corrector follows.
        guard AppVocabCore.hasActiveCommonWords else { return [] }
        let store = CorrectionStore.shared
        let terms = VocabularyStore.shared.terms
        // The diff is pure and can be long (a meeting): off the main actor.
        let lessons = await Task.detached(priority: .utility) {
            EditLearner.learn(
                before: before, after: after, raw: raw, vocabulary: terms,
                isCommonWord: { AppVocabCore.isCommonOriginal($0) })
        }.value
        guard !lessons.isEmpty else { return [] }

        for lesson in lessons {
            switch lesson {
            case .substitute(let original, let term, let heardByModel):
                let common = store.refusesLearning(originalWord: original)
                let open = await openReviewRecords(
                    transcriptID: transcriptID, reviewText: reviewText, original: original, term: term)
                // The user typed the spelling, so its casing wins.
                let receipt = await VocabularyLearning.shared.apply(.correct(
                    heard: original, term: term, heardByModel: heardByModel, userCasing: true))
                await close(open, transcriptID: transcriptID, verdict: "term",
                            applyLearning: !common, receipt: receipt)
            case .reverse(let original, let term):
                let common = store.refusesLearning(originalWord: original)
                let open = await openReviewRecords(
                    transcriptID: transcriptID, reviewText: reviewText, original: original, term: term)
                let receipt = await VocabularyLearning.shared.apply(.keepOriginal(heard: original, term: term))
                await close(open, transcriptID: transcriptID, verdict: "original",
                            applyLearning: !common, receipt: receipt)
                // Ask-ranking prior (not learning): a rare pair's net drops
                // through a normal revert; a common pair's never goes positive.
                if !common, open.isEmpty {
                    await store.revert(originalWord: original, term: term)
                }
            case .recase(let term):
                await VocabularyLearning.shared.apply(.recase(term))
            }
        }
        DiagnosticsLog.record(
            source: "main-app", category: .vocabularyGate,
            message: "learned from transcript edit",
            metadata: ["lessons": "\(lessons.count)"])
        return lessons
    }

    /// Whether `lessons` already taught `heard → term` (a substitute of that
    /// pair), compared the way the store keys pairs.
    static func taught(_ lessons: [EditLearner.Lesson], heard: String, term: String) -> Bool {
        let h = CorrectionKey.normalize(heard)
        let t = CorrectionKey.normalize(term)
        return lessons.contains {
            if case .substitute(let original, let learned, _) = $0 {
                return CorrectionKey.normalize(original) == h && CorrectionKey.normalize(learned) == t
            }
            return false
        }
    }

    /// This transcript's still-open review records for `(original → term)`.
    private static func openReviewRecords(
        transcriptID: UUID, reviewText: String?, original: String, term: String
    ) async -> [CorrectionProvenance.Record] {
        guard let reviewText else { return [] }
        return await CorrectionProvenance.shared.reconciledPayload(
            transcriptID: transcriptID, currentText: reviewText
        ).openRecords(originalWord: original, term: term)
    }

    /// Close `records` with `verdict`, so the review list can't count the pair
    /// a second time. The provenance deltas reach the store's net (the ask
    /// ranking prior) only when `applyLearning` (rare originals). The first
    /// record keeps the lesson's receipt for the list's Undo — one lesson, one
    /// undo.
    private static func close(
        _ records: [CorrectionProvenance.Record], transcriptID: UUID, verdict: String,
        applyLearning: Bool, receipt: VocabularyLearning.Receipt
    ) async {
        for (i, record) in records.enumerated() {
            let deltas = await CorrectionProvenance.shared.setVerdict(
                transcriptID: transcriptID, record: record, verdict: verdict, fromEdit: true,
                receipt: i == 0 ? receipt : nil)
            guard applyLearning else { continue }
            for d in deltas {
                await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
            }
        }
    }
}
