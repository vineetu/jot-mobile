import Foundation
import FluidAudio

/// Post-transcription paragraph segmentation. Pure function with no I/O —
/// safe to call from any batch-transcription path (in-app hero, keyboard,
/// wizard W5 mic test, Shortcuts intent, etc.). Streaming is NOT covered;
/// the streaming pipeline never goes through this surface.
///
/// Heuristic (v1, deliberately simple — no discourse-marker rules,
/// no safety caps):
///   - For each adjacent word pair, if `next.start - prev.end > 1.6s`
///     AND prev word ends in `.`, `!`, or `?` (after trimming trailing
///     quotes/brackets), insert `\n\n` between them.
///   - Otherwise, the words are joined with a single space.
///   - Any accidental consecutive `\n\n\n\n` is collapsed to `\n\n`.
///
/// The output replaces the rescored text only when both the
/// token-to-word reassembly and the word-index alignment with the
/// post-rescore text succeed. Any failure mode (degenerate inputs,
/// reassembly drift, rescore word-count drift > 5%) returns the
/// rescored text untouched — the segmenter can never regress the
/// user-visible transcription.
enum ParagraphSegmenter {

    /// Pause (seconds) between adjacent words that, combined with a
    /// sentence-final punctuation mark on the prior word, triggers a
    /// paragraph break.
    static let paragraphPauseThreshold: TimeInterval = 1.6

    /// Punctuation that, when found at the trailing edge of a word
    /// (after trimming closing quotes/brackets), counts as
    /// sentence-final for paragraph-break purposes.
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// Characters trimmed off the trailing edge of a word before
    /// checking for sentence-final punctuation. Covers ASCII closing
    /// quotes/brackets plus the common curly variants users dictate.
    private static let trailingTrimSet = CharacterSet(charactersIn: "\"')]}»’”")

    /// Token-boundary markers Parakeet BPE tokenizers use to indicate
    /// "this token starts a new word." Tokens NOT prefixed with one of
    /// these are continuations of the previous word.
    private static let wordStartMarkers: [Character] = ["▁", " "]

    /// Reassembled-word view of the FluidAudio token-timing array.
    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Top-level entry point. Returns the rescored text untouched on
    /// any degenerate or unsupported input.
    static func segment(
        rescoredText: String,
        tokenTimings: [TokenTiming]
    ) -> String {
        let words = reassembleWords(from: tokenTimings)
        return apply(breaks: words, to: rescoredText)
    }

    /// Visible for testing — converts FluidAudio's BPE token timings
    /// into word-level boundaries. Tokens prefixed with `▁` or a
    /// leading space start a new word; everything else extends the
    /// previous one. First token always starts a word.
    static func reassembleWords(from tokens: [TokenTiming]) -> [Word] {
        guard !tokens.isEmpty else { return [] }

        var words: [Word] = []
        var currentText = ""
        var currentStart: TimeInterval = tokens[0].startTime
        var currentEnd: TimeInterval = tokens[0].endTime

        for (index, token) in tokens.enumerated() {
            let trimmed = stripWordStartMarker(token.token)
            // Skip pad/empty/special tokens entirely — they shouldn't
            // contribute to a word's text but also shouldn't split it.
            guard !trimmed.isEmpty else { continue }

            let isWordStart = index == 0 || isWordStartToken(token.token)

            if isWordStart {
                if !currentText.isEmpty {
                    words.append(
                        Word(text: currentText, start: currentStart, end: currentEnd)
                    )
                }
                currentText = trimmed
                currentStart = token.startTime
                currentEnd = token.endTime
            } else {
                currentText += trimmed
                currentEnd = token.endTime
            }
        }

        if !currentText.isEmpty {
            words.append(
                Word(text: currentText, start: currentStart, end: currentEnd)
            )
        }

        return words
    }

    /// Visible for testing — given the reassembled word boundaries and
    /// the post-rescore text, returns either the segmented text or the
    /// rescored text unchanged. Splits the rescored text on
    /// whitespace and walks the same word-index positions.
    static func apply(breaks words: [Word], to text: String) -> String {
        guard words.count > 1 else { return text }

        // Compute break positions on the raw words first.
        var breakAfterWordIndex: Set<Int> = []
        for i in 0..<(words.count - 1) {
            let gap = words[i + 1].start - words[i].end
            guard gap > paragraphPauseThreshold else { continue }
            let trimmed = words[i].text.trimmingCharacters(in: trailingTrimSet)
            guard let lastChar = trimmed.last,
                  sentenceEnders.contains(lastChar) else { continue }
            breakAfterWordIndex.insert(i)
        }

        if breakAfterWordIndex.isEmpty { return text }

        // Re-split the post-rescore text. omittingEmptySubsequences:true
        // so accidental double spaces don't inflate the token count
        // (which would false-fire the drift guard below).
        let rescoredTokens = text.split(
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )

        // Word-count drift guard. If the rescorer added or removed
        // words by more than a small tolerance, the word-index
        // positions don't line up and we'd insert breaks in the
        // wrong places. Bail out and return the rescored text
        // unchanged — losing paragraph segmentation on this one
        // transcript is preferable to garbling the text.
        let drift = abs(rescoredTokens.count - words.count)
        let tolerance = max(1, Int(Double(words.count) * 0.05))
        guard drift <= tolerance else { return text }

        var out: [String] = []
        out.reserveCapacity(rescoredTokens.count * 2)
        for (i, t) in rescoredTokens.enumerated() {
            out.append(String(t))
            guard i < rescoredTokens.count - 1 else { continue }
            // Index-safety guard: even when the raw-word array says "break
            // after word i", confirm the rescored token at this position
            // ALSO ends in sentence-final punctuation. If raw and rescored
            // disagree on where the period attaches (BPE tokenizers often
            // emit "." as its own ▁-prefixed word, but rescored whitespace-
            // split packages "." onto the preceding token), the raw word
            // index can map to a rescored mid-sentence position. Without
            // this check the paragraph break lands mid-sentence — exactly
            // the bug users reported. False negatives (missing a break) are
            // invisible; false positives (wrong-place break) are jarring.
            let shouldBreak = breakAfterWordIndex.contains(i) && {
                let trimmed = String(t).trimmingCharacters(in: trailingTrimSet)
                guard let lastChar = trimmed.last else { return false }
                return sentenceEnders.contains(lastChar)
            }()
            out.append(shouldBreak ? "\n\n" : " ")
        }

        var result = out.joined()
        // Collapse any accidental consecutive paragraph breaks.
        while result.contains("\n\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n\n", with: "\n\n")
        }
        return result
    }

    // MARK: - Helpers

    private static func isWordStartToken(_ raw: String) -> Bool {
        guard let first = raw.first else { return false }
        return wordStartMarkers.contains(first)
    }

    private static func stripWordStartMarker(_ raw: String) -> String {
        guard let first = raw.first, wordStartMarkers.contains(first) else {
            return raw
        }
        return String(raw.dropFirst())
    }
}
