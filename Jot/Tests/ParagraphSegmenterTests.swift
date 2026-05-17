import XCTest
import FluidAudio
@testable import Jot

/// Unit tests for the post-transcription paragraph segmenter. Tests
/// exercise the pure helper functions directly (no FluidAudio model
/// load, no I/O).
final class ParagraphSegmenterTests: XCTestCase {

    // MARK: - apply(breaks:to:) — the four cases from the spec

    /// (a) Sentence-final punctuation + pause > threshold → insert
    /// `\n\n` between the two words.
    func testPeriodLongPauseBreaks() {
        let words = [
            ParagraphSegmenter.Word(text: "Hello.", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "World.", start: 2.5, end: 3.0)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "Hello. World.")
        XCTAssertEqual(out, "Hello.\n\nWorld.")
    }

    /// (b) Sentence-final punctuation but pause below threshold →
    /// no break, joined with a single space.
    func testPeriodShortPauseNoBreak() {
        let words = [
            ParagraphSegmenter.Word(text: "Hello.", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "World.", start: 1.0, end: 1.5)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "Hello. World.")
        XCTAssertEqual(out, "Hello. World.")
    }

    /// (c) Long pause but no sentence-final punctuation on the prior
    /// word → no break.
    func testLongPauseNoPunctNoBreak() {
        let words = [
            ParagraphSegmenter.Word(text: "hello", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "world", start: 2.5, end: 3.0)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "hello world")
        XCTAssertEqual(out, "hello world")
    }

    /// (d) Sentence-final punctuation followed by a closing quote +
    /// long pause → break still fires (trailing-quote trim is
    /// applied before the sentence-ender check).
    func testQuotePeriodLongPauseBreaks() {
        let words = [
            ParagraphSegmenter.Word(text: "said.\"", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "Then", start: 2.5, end: 3.0)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "said.\" Then")
        XCTAssertEqual(out, "said.\"\n\nThen")
    }

    // MARK: - safety guards

    /// Empty word array → input text returned untouched (segmenter is
    /// a no-op rather than crashing on degenerate input).
    func testEmptyWordsReturnsTextUnchanged() {
        let out = ParagraphSegmenter.apply(breaks: [], to: "anything")
        XCTAssertEqual(out, "anything")
    }

    /// Single-word transcript → no possible break, returned unchanged.
    func testSingleWordReturnsTextUnchanged() {
        let words = [ParagraphSegmenter.Word(text: "Hi.", start: 0.0, end: 0.5)]
        let out = ParagraphSegmenter.apply(breaks: words, to: "Hi.")
        XCTAssertEqual(out, "Hi.")
    }

    /// Rescore drifted word count beyond tolerance → fall through and
    /// return the rescored text unchanged (better to lose paragraphs
    /// on one transcript than to insert breaks at the wrong word
    /// boundaries).
    func testWordCountDriftBeyondToleranceReturnsTextUnchanged() {
        // Raw words say there should be a break after word 0.
        let words = [
            ParagraphSegmenter.Word(text: "First.", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "Second.", start: 2.5, end: 3.0)
        ]
        // Rescored text has 8 tokens vs the 2 raw words — far beyond
        // the 5% tolerance (or the 1-word minimum).
        let rescored = "this rescored text has many many more words now"
        let out = ParagraphSegmenter.apply(breaks: words, to: rescored)
        XCTAssertEqual(out, rescored)
    }

    // MARK: - reassembleWords

    /// Three BPE tokens reassemble into two words at the `▁` boundary
    /// marker. First word's timings span tokens 0..1; second word
    /// starts at token 2.
    func testReassembleWordsBoundaryMarker() {
        let tokens = [
            TokenTiming(token: "▁Hel", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 1.0),
            TokenTiming(token: "lo.", tokenId: 2, startTime: 0.2, endTime: 0.5, confidence: 1.0),
            TokenTiming(token: "▁World.", tokenId: 3, startTime: 2.5, endTime: 3.0, confidence: 1.0)
        ]
        let words = ParagraphSegmenter.reassembleWords(from: tokens)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, "Hello.")
        XCTAssertEqual(words[0].start, 0.0)
        XCTAssertEqual(words[0].end, 0.5)
        XCTAssertEqual(words[1].text, "World.")
        XCTAssertEqual(words[1].start, 2.5)
        XCTAssertEqual(words[1].end, 3.0)
    }

    /// Empty token array → empty word array.
    func testReassembleEmptyTokens() {
        let out = ParagraphSegmenter.reassembleWords(from: [])
        XCTAssertEqual(out, [])
    }
}
