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
    /// resolved to its live span via the deterministic offset.
    func marks() -> [MarkedTranscriptText.Mark] {
        let text = transcript.text
        var out: [MarkedTranscriptText.Mark] = []
        for r in records where payload.verdicts[r.key] == nil {
            let word = r.outcome == "applied" ? r.term : r.originalWord
            // STRICT for marks: only draw an underline where the span resolves
            // EXACTLY at its computed offset. If the user has hand-edited the body
            // and the offset no longer lands on the word, DROP the mark rather than
            // nearest-guess onto the wrong repeat (plan §v2-A(c)). The accordion
            // row still lets them adjudicate it.
            guard let range = resolveSpan(word: word, offset: currentOffset(for: r), in: text, strict: true)
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
        guard let range = resolveSpan(word: word, offset: currentOffset(for: r), in: text, strict: true)
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

    func reload() async {
        payload = await CorrectionProvenance.shared.payload(transcriptID: transcript.id)
    }

    // MARK: - Verdicts

    func pick(_ r: CorrectionProvenance.Record, choice: String) async {
        // Refresh from the actor truth FIRST so the offset math (which counts
        // earlier resolved edits) and any branch see current state, even if a
        // prior tap's `reload()` hasn't landed yet (avoids a stale-snapshot race).
        await reload()
        // kept + term → apply the term here; applied + original → revert here.
        if choice == "term", r.outcome == "kept" {
            _ = editText(r, find: r.originalWord, replaceWith: r.term)
        } else if choice == "original", r.outcome == "applied" {
            _ = editText(r, find: r.term, replaceWith: r.originalWord)
        }
        let delta = await CorrectionProvenance.shared.setVerdict(transcriptID: transcript.id, record: r, verdict: choice)
        await applyLearning(delta)
        await reload()
    }

    func undo(_ r: CorrectionProvenance.Record) async {
        await reload()   // actor truth before deciding the reverse edit (see pick)
        let v = payload.verdicts[r.key]
        if v == "term", r.outcome == "kept" {
            _ = editText(r, find: r.term, replaceWith: r.originalWord)
        } else if v == "original", r.outcome == "applied" {
            _ = editText(r, find: r.originalWord, replaceWith: r.term)
        }
        let delta = await CorrectionProvenance.shared.clearVerdict(transcriptID: transcript.id, record: r)
        await applyLearning(delta)
        await reload()
    }

    /// Move the mapping's global learning net by the provenance-computed delta.
    private func applyLearning(_ delta: CorrectionProvenance.MappingDelta?) async {
        guard let d = delta else { return }
        await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
    }

    // MARK: - Deterministic per-occurrence text edit (plan §v2-A)

    @discardableResult
    private func editText(_ r: CorrectionProvenance.Record, find word: String, replaceWith replacement: String) -> Bool {
        let text = transcript.text
        guard let target = resolveSpan(word: word, offset: currentOffset(for: r), in: text) else { return false }
        var newText = text
        newText.replaceSubrange(target, with: replacement)
        guard newText != text else { return false }
        // The replaced span starts at the same position; its NEW length is the
        // replacement's length. Build the flash range in UTF-16 (NSRange units) —
        // the location must be the UTF-16 offset of the span start, NOT a Character
        // distance, or a non-BMP char (emoji) earlier in the body would shift it.
        let startUTF16 = NSRange(target, in: text).location
        let flashRange = NSRange(location: startUTF16, length: (replacement as NSString).length)
        transcript.text = newText
        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            flashNonce += 1
            flash = MarkedTranscriptText.Flash(range: flashRange, token: flashNonce)
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    /// Live char offset of record `r`'s span: gate-time `publishedStart` shifted by
    /// the cumulative length change of every EARLIER occurrence already edited.
    private func currentOffset(for r: CorrectionProvenance.Record) -> Int {
        var delta = 0
        for e in records where e.publishedStart < r.publishedStart {
            guard let v = payload.verdicts[e.key] else { continue }
            delta += editLengthDelta(e, verdict: v)
        }
        return r.publishedStart + delta
    }

    /// Length change of an EARLIER record's resolved verdict. `publishedLength` is
    /// the gate-placed (old) whole-word length — equals what `editText`'s needle
    /// matches, so the delta is exact (see CorrectionReviewSection invariant note).
    private func editLengthDelta(_ e: CorrectionProvenance.Record, verdict: String) -> Int {
        if e.outcome == "kept" && verdict == "term" { return e.term.count - e.publishedLength }
        if e.outcome == "applied" && verdict == "original" { return e.originalWord.count - e.publishedLength }
        return 0
    }

    /// Whole-word span of `word` at exactly `offset`. With `strict`, returns nil
    /// when no span starts exactly there (used for MARKS — fail safe rather than
    /// underline the wrong repeat). Without `strict`, falls back to the nearest
    /// match for a user-initiated EDIT where the body was hand-edited.
    private func resolveSpan(word: String, offset: Int, in text: String, strict: Bool = false) -> Range<String.Index>? {
        let needle = word.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
        guard !needle.isEmpty else { return nil }
        let ranges = Self.wholeWordRanges(of: needle, in: text)
        guard !ranges.isEmpty else { return nil }
        if let exact = ranges.first(where: { text.distance(from: text.startIndex, to: $0.lowerBound) == offset }) {
            return exact
        }
        if strict { return nil }
        return ranges.min(by: { a, b in
            abs(text.distance(from: text.startIndex, to: a.lowerBound) - offset)
                < abs(text.distance(from: text.startIndex, to: b.lowerBound) - offset)
        })
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
