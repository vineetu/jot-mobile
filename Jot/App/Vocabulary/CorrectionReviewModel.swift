import SwiftData
import SwiftUI

/// Shared state + actions for the correction-review surfaces (the in-text marks +
/// tap bubble AND the summary-row accordion). Owning this once — above the
/// transcript detail's tab `.id` boundary — means both surfaces read the same
/// verdicts and the per-occurrence text-edit anchoring lives in ONE place
/// (plan §v2-C/F). The model is created by `TranscriptDetailView` and passed to
/// both the body renderer and `CorrectionReviewSection`.
@MainActor
@Observable
final class CorrectionReviewModel {
    let transcript: Transcript
    private let modelContext: ModelContext
    var payload = CorrectionProvenance.Payload()
    var accordionExpanded = false
    /// Set when a verdict mutates the transcript text — the body renderer flashes
    /// a fading blue wash over this span (handoff §text-mutation feedback). The
    /// `token` nonce makes an identical range re-fire.
    var flash: MarkedTranscriptText.Flash?
    private var flashNonce = 0

    init(transcript: Transcript, modelContext: ModelContext) {
        self.transcript = transcript
        self.modelContext = modelContext
    }

    // MARK: - Derived reads

    var records: [CorrectionProvenance.Record] { payload.records }
    func verdict(of r: CorrectionProvenance.Record) -> String? { payload.verdicts[r.key] }
    func record(forKey key: String) -> CorrectionProvenance.Record? { records.first { $0.key == key } }
    var unresolvedCount: Int { records.filter { payload.verdicts[$0.key] == nil }.count }
    var allReviewed: Bool { !records.isEmpty && unresolvedCount == 0 }

    /// Underline marks for the body — UNRESOLVED occurrences only. The marked
    /// word is the one currently in the text (applied → term, kept → original),
    /// resolved to its live span at the reconciled anchor.
    func marks() -> [MarkedTranscriptText.Mark] {
        let text = transcript.text
        var out: [MarkedTranscriptText.Mark] = []
        for r in records where payload.verdicts[r.key] == nil {
            let word = r.outcome == "applied" ? r.term : r.originalWord
            // Anchors are reconciled at reload; a span that still fails to
            // resolve EXACTLY was edited away — drop the mark rather than guess
            // onto the wrong repeat (plan §v2-A(c)). The accordion row still
            // lets them adjudicate it.
            guard let range = resolveSpan(word: word, offset: r.publishedStart, in: text)
            else { continue }
            out.append(.init(key: r.key, range: NSRange(range, in: text), applied: r.outcome == "applied"))
        }
        return out
    }

    /// Spoken-context snippet around record `r`'s LIVE span — a few words before
    /// the gated word and a few after — so an accordion row can show WHICH
    /// occurrence it's about (otherwise three "name" rows are indistinguishable).
    /// Returns (before, gated, after) with ellipses; nil if the span can't be
    /// resolved exactly (e.g. the body was hand-edited).
    func context(for r: CorrectionProvenance.Record, window: Int = 28)
        -> (before: String, gated: String, after: String)? {
        let text = transcript.text
        let word = r.outcome == "applied" ? r.term : r.originalWord
        guard let range = resolveSpan(word: word, offset: r.publishedStart, in: text)
        else { return nil }
        let beforeStart = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let afterEnd = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        var before = String(text[beforeStart..<range.lowerBound])
        var after = String(text[range.upperBound..<afterEnd])
        if beforeStart != text.startIndex { before = "\u{2026}" + before }
        if afterEnd != text.endIndex { after += "\u{2026}" }
        return (before, String(text[range]), after)
    }

    // MARK: - Load

    /// Refresh from the actor truth, reconciling every record's anchor to the
    /// CURRENT transcript text (hand-edits, keyboard-verdict drains, and this
    /// model's own verdict edits all shift anchors through the same diff).
    func reload() async {
        payload = await CorrectionProvenance.shared.reconciledPayload(
            transcriptID: transcript.id, currentText: transcript.text)
    }

    // MARK: - Verdicts

    func pick(_ r: CorrectionProvenance.Record, choice: String) async {
        // Refresh from the actor truth FIRST (reconciles anchors), then re-fetch
        // the record by its stable key — the `r` the view handed us is a SNAPSHOT
        // whose `publishedStart` may have just been shifted by the reconcile.
        await reload()
        let r = record(forKey: r.key) ?? r
        let priorVerdict = payload.verdicts[r.key]   // for the blocked-keep transition guard below
        // kept + term → apply the term here; applied + original → revert here.
        if choice == "term", r.outcome == "kept" {
            await reportSelfEdit(editText(r, find: r.originalWord, replaceWith: r.term), key: r.key)
        } else if choice == "original", r.outcome == "applied" {
            await reportSelfEdit(editText(r, find: r.term, replaceWith: r.originalWord), key: r.key)
        }
        let delta = await CorrectionProvenance.shared.setVerdict(transcriptID: transcript.id, record: r, verdict: choice)
        await applyLearning(delta)
        // "Keep original" on a BLOCKED pair contributes 0 to `net` (demote needs an
        // APPLIED revert), so a common-word proposal like "okay"→"Okta" would be
        // re-asked forever no matter how often it's rejected. Count it separately so
        // the keyboard stops re-asking after `keyboardKeepSuppressThreshold` keeps.
        // Keyboard-only suppression; the transcript pane still surfaces it. Guard on a
        // genuine transition INTO "original" so a re-pick of the same verdict can't
        // double-count (the increment is otherwise non-idempotent).
        if choice == "original", r.outcome == "kept", priorVerdict != "original" {
            await CorrectionStore.shared.noteBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        await reload()
    }

    func undo(_ r: CorrectionProvenance.Record) async {
        await reload()   // actor truth + anchor reconcile before the reverse edit (see pick)
        let r = record(forKey: r.key) ?? r
        let v = payload.verdicts[r.key]
        if v == "term", r.outcome == "kept" {
            await reportSelfEdit(editText(r, find: r.term, replaceWith: r.originalWord), key: r.key)
        } else if v == "original", r.outcome == "applied" {
            await reportSelfEdit(editText(r, find: r.originalWord, replaceWith: r.term), key: r.key)
        }
        let delta = await CorrectionProvenance.shared.clearVerdict(transcriptID: transcript.id, record: r)
        await applyLearning(delta)
        // Symmetric with the blocked-keep increment in `pick`: undoing a "keep
        // original" on a blocked pair gives back its `blockedKeeps`, so the keyboard
        // suppression count never drifts above the real number of standing keeps.
        if v == "original", r.outcome == "kept" {
            await CorrectionStore.shared.clearBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        await reload()
    }

    /// Flash the blue wash over an arbitrary span — same feedback as a verdict
    /// edit. Used by the selection-menu "Add to Vocabulary" confirmation.
    func flashSpan(_ range: NSRange) {
        flashNonce += 1
        flash = MarkedTranscriptText.Flash(range: range, token: flashNonce)
    }

    /// Hand the exact span of one of OUR OWN edits to the provenance actor —
    /// anchors shift by report, never by diff-inference, for self edits (a diff
    /// is ambiguous when replacement and replaced word share a suffix, e.g.
    /// "nathan" → "Ramanathan", and would shift this record's anchor off its
    /// own word, breaking Undo).
    private func reportSelfEdit(_ edit: SelfEdit?, key: String) async {
        guard let edit else { return }
        await CorrectionProvenance.shared.noteSelfEdit(
            transcriptID: transcript.id, recordKey: key,
            start: edit.start, oldLength: edit.oldLength,
            newLength: edit.newLength, newText: edit.newText)
    }

    /// Move the mapping's global learning net by the provenance-computed delta.
    private func applyLearning(_ delta: CorrectionProvenance.MappingDelta?) async {
        guard let d = delta else { return }
        await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
    }

    // MARK: - Deterministic per-occurrence text edit (plan §v2-A)

    /// What one verdict edit did to the text, in Character offsets — reported
    /// to the provenance actor so anchors shift exactly (see `reportSelfEdit`).
    struct SelfEdit {
        let start: Int
        let oldLength: Int
        let newLength: Int
        let newText: String
    }

    private func editText(_ r: CorrectionProvenance.Record, find word: String, replaceWith replacement: String) -> SelfEdit? {
        let text = transcript.text
        // STRICT resolution only — if the word isn't EXACTLY at its reconciled
        // anchor, the user edited it away; record the verdict (learning) but
        // never edit a guessed span. The old nearest-match fallback here is what
        // fired verdict edits on the WRONG occurrence after a hand-edit.
        guard let target = resolveSpan(word: word, offset: r.publishedStart, in: text) else { return nil }
        var newText = text
        newText.replaceSubrange(target, with: replacement)
        guard newText != text else { return nil }
        // The replaced span starts at the same position; its NEW length is the
        // replacement's length. Build the flash range in UTF-16 (NSRange units) —
        // the location must be the UTF-16 offset of the span start, NOT a Character
        // distance, or a non-BMP char (emoji) earlier in the body would shift it.
        let startUTF16 = NSRange(target, in: text).location
        let flashRange = NSRange(location: startUTF16, length: (replacement as NSString).length)
        // Keep the live (model-context) object current so this model's own
        // subsequent synchronous reads — `reload()`'s anchor reconcile against
        // `transcript.text`, `marks()`, `context()` — see the new text within
        // the same `pick()`/`undo()` call. The Repository persists the same
        // value on its own context (sole writer of the store + mirror); the
        // two contexts converge on identical text, so there is no conflicting
        // double-write.
        transcript.text = newText
        do {
            try TranscriptStore.setText(id: transcript.id, newText: newText)
            flashNonce += 1
            flash = MarkedTranscriptText.Flash(range: flashRange, token: flashNonce)
            return SelfEdit(
                start: text.distance(from: text.startIndex, to: target.lowerBound),
                oldLength: text.distance(from: target.lowerBound, to: target.upperBound),
                newLength: replacement.count,
                newText: newText)
        } catch {
            // Revert the optimistic in-memory mutation so the model's text
            // doesn't drift from on-disk state after a failed save.
            transcript.text = text
            return nil
        }
    }

    /// Whole-word span of `word` starting EXACTLY at `offset` — nil otherwise.
    /// Strict only, for marks AND edits: `publishedStart` anchors are reconciled
    /// to the live text at every reload, so an exact miss means the span was
    /// genuinely edited away. Fail safe (no mark, no edit) rather than guess a
    /// repeat of the same word — the deleted nearest-match fallback did exactly
    /// that and replaced the wrong occurrence after hand-edits.
    private func resolveSpan(word: String, offset: Int, in text: String) -> Range<String.Index>? {
        let needle = word.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
        guard !needle.isEmpty else { return nil }
        return Self.wholeWordRanges(of: needle, in: text)
            .first { text.distance(from: text.startIndex, to: $0.lowerBound) == offset }
    }

    /// Every whole-word, case-insensitive occurrence of `word` in `text`.
    static func wholeWordRanges(of word: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var search = text.startIndex
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { ranges.append(r) }
            search = r.upperBound
            if search == text.endIndex { break }
        }
        return ranges
    }
}
