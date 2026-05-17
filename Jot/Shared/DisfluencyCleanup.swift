import Foundation
import OSLog

// Bundled disfluency-cleanup tagger. Only compiled into the main-app target —
// the keyboard appex doesn't link `CoreML`/`Tokenizers` for this code path
// (cleanup runs inside `DictationPipeline.completeEndOfRecording` after the
// keyboard's URL bounce arrives at the main app). The model files ARE bundled
// into the keyboard for forward compatibility (see `project.yml`), so a
// future in-extension cleanup path is a Swift-only change.
//
// The `#if JOT_APP_HOST` gate mirrors the pattern in
// `Shared/RecordingPipelineDispatch.swift` — files that live in `Shared/`
// for source organization but only compile inside the main-app target.

#if JOT_APP_HOST

import CoreML
import Hub
import Tokenizers

/// On-device, opt-in disfluency cleanup. Removes filler words ("um", "uh"),
/// discourse-marker phrases ("you know", "I mean"), and short false-starts
/// from a freshly-transcribed dictation using a 3.6 MB INT8-quantized BERT
/// tagger (Rocholl 6×96 backbone, trained on the DisfluencySpeech corpus,
/// Apache 2.0). Lives inside the dictation pipeline's `.cleaning` phase —
/// gated entirely on `AppGroup.disfluencyCleanupEnabled`.
///
/// ## Contract
///
/// `clean(_:)` is the ONLY public entry point. It is fail-safe by design:
/// every failure path (model load throws, tokenizer load throws, inference
/// throws, anything else) returns the raw transcript unchanged. There is no
/// regex fallback and no rule-based safety net — the user mandated none.
/// Empty / very-short utterances skip cleanup entirely.
///
/// ## Threading
///
/// `@MainActor` because the call site (`DictationPipeline.completeEndOfRecording`)
/// is itself MainActor, and the lazy load + a single ~5-10 ms inference per
/// 80-word chunk is acceptable inside the existing `.cleaning` Live Activity
/// window. The model + tokenizer are loaded on the FIRST call (never at app
/// launch) and held for the process lifetime once loaded.
///
/// ## Tokenization → predictions → cleaned text
///
/// 1. Split the transcript into words on whitespace, keeping a per-word
///    `(originalRange, lowercasedTokenizerInput)` index so we can rebuild
///    the cleaned string with original punctuation/casing of surviving
///    words intact.
/// 2. Chunk into windows of `maxSequenceLength - 2` source words (room for
///    `[CLS]` + `[SEP]`) with overlap so border words still get a real
///    inference context.
/// 3. For each window, run WordPiece tokenization with subword tracking,
///    pad to `maxSequenceLength`, run inference, and read the per-token
///    DELETE logit. The label for a source word is taken from its FIRST
///    subword (matches the training labeller's contract).
/// 4. Average the per-word DELETE probability across overlapping windows.
/// 5. Threshold at `deleteThreshold` (0.9) and drop those source words from
///    the output, preserving surrounding whitespace.
@MainActor
public final class DisfluencyCleanup {
    public static let shared = DisfluencyCleanup()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "disfluency-cleanup"
    )

    // MARK: - Tunables (load-bearing — keep in sync with the trained model)

    /// Fixed sequence length the CoreML model was traced with. Changing this
    /// requires re-converting the model (`convert_to_coreml.py`).
    private static let maxSequenceLength = 128

    /// Word count per inference window. Reserve 2 slots inside the
    /// sequence-length budget for `[CLS]` + `[SEP]`, then leave additional
    /// headroom for subword expansion — WordPiece on natural English speech
    /// fans out at roughly 1.2-1.5 subwords per source word, so a 80-word
    /// window comfortably fits inside 128 - 2 = 126 subword slots without
    /// truncation. Matches the eval harness's chunking parameters.
    private static let windowSize = 80

    /// Overlap between consecutive windows. Border words near a chunk edge
    /// have less left/right context, so averaging across overlapping windows
    /// stabilises their score. Same value as `eval_jot.py`.
    private static let windowOverlap = 16

    /// REMOVE-class probability threshold above which a word is dropped.
    /// 0.9 came out of the head-to-head eval at
    /// `tmp/disfluencyspeech-eval-results.md` — at this threshold the Rocholl
    /// 6×96 model averages ~1 true content-word false positive per 10k words
    /// on real Jot transcripts, which is the closest-to-zero setting that
    /// still catches filler-words / discourse-markers / false-starts.
    private static let deleteThreshold: Float = 0.9

    /// Minimum word count for cleanup to run at all. Below this threshold,
    /// the latency tax isn't worth the cleanup payoff — the user is
    /// probably dictating a one-line snippet ("yes", "tomorrow", "thanks")
    /// where any deletion is more disruptive than a stray "um".
    private static let minimumWordCountForCleanup = 3

    /// Vocabulary file name (bundled alongside the mlpackage in
    /// `Resources/DisfluencyCleanup/`). One token per line, line index ==
    /// token id (standard bert-base-uncased WordPiece vocab).
    private static let vocabResourceName = "vocab"
    private static let vocabResourceExtension = "txt"

    /// Compiled model resource. Xcode's CoreML build phase turns the
    /// `disfluency_rocholl6x96.mlpackage` source into a
    /// `disfluency_rocholl6x96.mlmodelc` directory inside the app bundle.
    private static let modelResourceName = "disfluency_rocholl6x96"
    private static let modelResourceExtension = "mlmodelc"

    // MARK: - Lazy state

    private var loadAttempted = false
    private var model: MLModel?
    private var tokenizer: BertTokenizer?
    private var clsTokenId: Int32 = 0
    private var sepTokenId: Int32 = 0
    private var padTokenId: Int32 = 0

    private init() {}

    // MARK: - Public API

    /// Clean `transcript` in place. Returns the cleaned text, or the raw
    /// `transcript` unchanged on any failure / skip condition.
    ///
    /// Skip conditions:
    ///   - Word count is ≤ `minimumWordCountForCleanup`.
    ///   - Model or tokenizer failed to load (first call) or was nil.
    ///
    /// Failure conditions (also return the raw transcript):
    ///   - Inference throws on any chunk.
    ///   - Output shape doesn't match expectations.
    public func clean(_ transcript: String) -> String {
        // Skip-short guard — see `minimumWordCountForCleanup` doc.
        let words = parseWords(in: transcript)
        guard words.count > Self.minimumWordCountForCleanup else {
            return transcript
        }

        // Lazy-load the model + tokenizer. Only one attempt — if the first
        // load fails, every subsequent call returns the raw transcript
        // without re-attempting. The bundle is read-only; a load that
        // failed once will fail every time, and retrying just burns CPU.
        guard ensureLoaded(), let model, let tokenizer else {
            return transcript
        }

        let probabilities: [Float]
        do {
            probabilities = try predictDeleteProbabilities(
                for: words,
                model: model,
                tokenizer: tokenizer
            )
        } catch {
            logger.error(
                "disfluency cleanup degraded to raw — inference failed: \(error.localizedDescription, privacy: .public)"
            )
            return transcript
        }

        // Defensive: if probability array shape doesn't match, abandon cleanup.
        // This can never happen if `predictDeleteProbabilities` returns
        // normally, but the contract is "fail-safe", not "fail-louder".
        guard probabilities.count == words.count else {
            logger.error(
                "disfluency cleanup degraded to raw — probability/word count mismatch (probs=\(probabilities.count, privacy: .public), words=\(words.count, privacy: .public))"
            )
            return transcript
        }

        return assembleCleanedText(
            transcript: transcript,
            words: words,
            deleteProbabilities: probabilities,
            threshold: Self.deleteThreshold
        )
    }

    // MARK: - Lazy load

    /// Resolve the bundle URLs, compile the model, load the tokenizer. On
    /// success populates `model` + `tokenizer` + the special-token ids.
    /// Returns `true` if both are loaded and usable. Idempotent — safe to
    /// call on every `clean(_:)`.
    private func ensureLoaded() -> Bool {
        if loadAttempted {
            return model != nil && tokenizer != nil
        }
        loadAttempted = true

        guard let modelURL = Bundle.main.url(
            forResource: Self.modelResourceName,
            withExtension: Self.modelResourceExtension
        ) else {
            logger.error(
                "disfluency cleanup unavailable — bundled model `\(Self.modelResourceName, privacy: .public).\(Self.modelResourceExtension, privacy: .public)` not found"
            )
            return false
        }

        guard let vocabURL = Bundle.main.url(
            forResource: Self.vocabResourceName,
            withExtension: Self.vocabResourceExtension
        ) else {
            logger.error(
                "disfluency cleanup unavailable — bundled vocab `\(Self.vocabResourceName, privacy: .public).\(Self.vocabResourceExtension, privacy: .public)` not found"
            )
            return false
        }

        let loadedModel: MLModel
        do {
            // CPU+ANE is the right default for a 3.6 MB BERT tagger — the
            // model is small enough that ANE residency cost is negligible
            // and CPU fallback is fast. Avoid `.all` because GPU dispatch
            // for tiny matmuls is usually slower than ANE/CPU for batch=1.
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error(
                "disfluency cleanup unavailable — model load failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let loadedTokenizer: BertTokenizer
        do {
            loadedTokenizer = try Self.loadBertTokenizer(vocabURL: vocabURL)
        } catch {
            logger.error(
                "disfluency cleanup unavailable — tokenizer load failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        guard
            let cls = loadedTokenizer.convertTokenToId("[CLS]"),
            let sep = loadedTokenizer.convertTokenToId("[SEP]"),
            let pad = loadedTokenizer.convertTokenToId("[PAD]")
        else {
            logger.error(
                "disfluency cleanup unavailable — vocab missing required special tokens"
            )
            return false
        }

        self.model = loadedModel
        self.tokenizer = loadedTokenizer
        self.clsTokenId = Int32(cls)
        self.sepTokenId = Int32(sep)
        self.padTokenId = Int32(pad)
        logger.info("disfluency cleanup ready — model + tokenizer loaded")
        return true
    }

    /// Read `vocab.txt` (one token per line, id == line index) into the
    /// `[String: Int]` map `BertTokenizer` expects. `do_lower_case: true`
    /// matches the training tokenizer (bert-base-uncased).
    private static func loadBertTokenizer(vocabURL: URL) throws -> BertTokenizer {
        let raw = try String(contentsOf: vocabURL, encoding: .utf8)
        var vocab: [String: Int] = [:]
        // `components(separatedBy:)` is correct over `split(separator:)` here:
        // the standard bert vocab has no empty lines, but if a trailing
        // newline produces one we want to keep the id counting consistent
        // with the file ordering (drop the empty trailing entry only).
        let lines = raw.components(separatedBy: "\n")
        vocab.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.isEmpty && index == lines.count - 1 {
                continue
            }
            vocab[line] = index
        }
        return BertTokenizer(
            vocab: vocab,
            merges: nil,
            tokenizeChineseChars: true,
            bosToken: nil,
            eosToken: nil,
            fuseUnknownTokens: false,
            doLowerCase: true
        )
    }

    // MARK: - Word parsing

    /// A whitespace-bounded source-word slice. Preserves the original
    /// `Range<String.Index>` so cleanup can splice the raw transcript
    /// rather than re-stringifying — that keeps punctuation, casing, and
    /// inter-word spacing untouched for the words we KEEP.
    private struct SourceWord {
        let range: Range<String.Index>
        /// Lowercased, punctuation-stripped form fed to the tokenizer.
        /// Matches the training preprocessing in `eval_jot.py` (lowercase,
        /// strip `,.?!:;"'\`-()[]` plus collapse runs of pure punctuation).
        let tokenizerInput: String
        /// True when the lowercased + stripped form is empty (pure punctuation
        /// run, e.g. "..." or "—"). These words are NEVER dropped (we treat
        /// them as KEEP by default), but they don't contribute to inference
        /// either; their probability slot reads back as 0.
        let isPunctuationOnly: Bool
    }

    /// Stripping set lifted from `eval_jot.py`'s `tokenize_words(...)` so
    /// the at-inference preprocessing matches what the model trained on.
    private static let surroundingStripChars: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: ",.?!:;\"'`-()[]")
        return set
    }()

    private func parseWords(in transcript: String) -> [SourceWord] {
        var words: [SourceWord] = []
        var current = transcript.startIndex
        while current < transcript.endIndex {
            // Skip whitespace.
            while current < transcript.endIndex,
                  transcript[current].isWhitespace {
                current = transcript.index(after: current)
            }
            guard current < transcript.endIndex else { break }

            // Consume to next whitespace boundary.
            let wordStart = current
            while current < transcript.endIndex,
                  !transcript[current].isWhitespace {
                current = transcript.index(after: current)
            }
            let wordRange = wordStart..<current
            let raw = String(transcript[wordRange])
            // Mirror eval_jot.py: strip surrounding punctuation, lowercase,
            // discard pure-punctuation runs from the tokenizer feed.
            let stripped = raw.trimmingCharacters(in: Self.surroundingStripChars)
            let lowered = stripped.lowercased()
            let onlyPunctuation = lowered.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.alphanumerics.contains(scalar)
            }
            words.append(
                SourceWord(
                    range: wordRange,
                    tokenizerInput: onlyPunctuation ? "" : lowered,
                    isPunctuationOnly: onlyPunctuation
                )
            )
        }
        return words
    }

    // MARK: - Inference

    /// Run inference across overlapping windows and emit a per-source-word
    /// DELETE probability. Punctuation-only words are pinned to `0.0` (KEEP).
    private func predictDeleteProbabilities(
        for words: [SourceWord],
        model: MLModel,
        tokenizer: BertTokenizer
    ) throws -> [Float] {
        var sums = [Float](repeating: 0, count: words.count)
        var counts = [Int](repeating: 0, count: words.count)

        var windowStart = 0
        while windowStart < words.count {
            let windowEnd = min(words.count, windowStart + Self.windowSize)
            try runWindow(
                start: windowStart,
                end: windowEnd,
                words: words,
                tokenizer: tokenizer,
                model: model,
                sums: &sums,
                counts: &counts
            )
            if windowEnd == words.count {
                break
            }
            windowStart += max(1, Self.windowSize - Self.windowOverlap)
        }

        var probs = [Float](repeating: 0, count: words.count)
        for i in 0..<words.count {
            // A word that never landed in any window (rare — only possible
            // if every chunk that should contain it truncated past it) is
            // safest treated as KEEP. Punctuation-only words follow the same
            // KEEP-by-default rule (their inference slot was skipped).
            if counts[i] > 0 {
                probs[i] = sums[i] / Float(counts[i])
            } else {
                probs[i] = 0
            }
        }
        return probs
    }

    /// One window of inference. Tokenizes the slice `[start..<end)` of
    /// `words` into WordPiece subwords (skipping punctuation-only words),
    /// builds the `[CLS] subwords... [SEP]` sequence, truncates to fit
    /// within `maxSequenceLength`, pads with `[PAD]`, runs the model, and
    /// accumulates the first-subword DELETE probability for each source
    /// word into `sums` / `counts`.
    private func runWindow(
        start: Int,
        end: Int,
        words: [SourceWord],
        tokenizer: BertTokenizer,
        model: MLModel,
        sums: inout [Float],
        counts: inout [Int]
    ) throws {
        let maxSubwords = Self.maxSequenceLength - 2  // [CLS] + [SEP]

        var inputIds: [Int32] = [clsTokenId]
        // Parallel array: for each subword position (after [CLS]), the
        // index into `words` of the source word it came from — or `nil`
        // for the special tokens / padding. Used to attribute each token's
        // logit back to the correct source word.
        var sourceWordIndex: [Int?] = [nil]
        // For each source word in `[start..<end)`, the input-id position
        // of its FIRST subword (or `nil` if it was skipped or truncated).
        // Reading the model output through this map matches the training
        // labeller's "first subword carries the per-word label" contract.
        var firstSubwordPosition: [Int: Int] = [:]

        for wordIndex in start..<end {
            let word = words[wordIndex]
            if word.tokenizerInput.isEmpty {
                // Punctuation-only / empty — don't feed to the model, don't
                // attribute any probability to this source word.
                continue
            }
            let subwords = tokenizer.tokenize(text: word.tokenizerInput)
            if subwords.isEmpty {
                continue
            }
            // Convert to ids defensively — `BertTokenizer.tokenize` should
            // always emit in-vocab subwords (UNK is a real id) but we guard
            // against any future tokenizer changes that could emit OOV.
            var subwordIds: [Int32] = []
            subwordIds.reserveCapacity(subwords.count)
            for sub in subwords {
                guard let id = tokenizer.convertTokenToId(sub) else {
                    // Fall back to UNK if available, else skip.
                    if let unk = tokenizer.unknownTokenId {
                        subwordIds.append(Int32(unk))
                    }
                    continue
                }
                subwordIds.append(Int32(id))
            }
            if subwordIds.isEmpty { continue }
            // If even the FIRST subword wouldn't fit before [SEP], we have
            // to truncate the window. Record the firstSubword position only
            // if at least one subword landed in the sequence — the per-word
            // probability for any source word that overflowed will read
            // back as KEEP (count == 0 in the aggregator).
            if inputIds.count - 1 + subwordIds.count > maxSubwords {
                // Truncate to what fits, but only commit if at least one
                // subword survives. (If 0 fit, we leave the word
                // unattributed.)
                let remaining = maxSubwords - (inputIds.count - 1)
                if remaining <= 0 { break }
                firstSubwordPosition[wordIndex] = inputIds.count
                let take = subwordIds.prefix(remaining)
                for sid in take {
                    inputIds.append(sid)
                    sourceWordIndex.append(wordIndex)
                }
                break
            }
            firstSubwordPosition[wordIndex] = inputIds.count
            for sid in subwordIds {
                inputIds.append(sid)
                sourceWordIndex.append(wordIndex)
            }
        }
        inputIds.append(sepTokenId)
        sourceWordIndex.append(nil)

        // Pad to MAX_LEN with [PAD].
        let realLength = inputIds.count
        while inputIds.count < Self.maxSequenceLength {
            inputIds.append(padTokenId)
            sourceWordIndex.append(nil)
        }
        // Defensive truncation (should never trip — every overflow path
        // above stops before exceeding MAX_LEN).
        if inputIds.count > Self.maxSequenceLength {
            inputIds = Array(inputIds.prefix(Self.maxSequenceLength))
            sourceWordIndex = Array(sourceWordIndex.prefix(Self.maxSequenceLength))
        }

        let inputIdsArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.maxSequenceLength)],
            dataType: .int32
        )
        let attentionMaskArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.maxSequenceLength)],
            dataType: .int32
        )
        // Direct pointer write avoids the per-element `NSNumber` boxing of
        // the subscript setter — measurable at MAX_LEN=128 across many
        // windows on a long transcript.
        let idsPtr = inputIdsArray.dataPointer.bindMemory(
            to: Int32.self, capacity: Self.maxSequenceLength
        )
        let maskPtr = attentionMaskArray.dataPointer.bindMemory(
            to: Int32.self, capacity: Self.maxSequenceLength
        )
        for i in 0..<Self.maxSequenceLength {
            idsPtr[i] = inputIds[i]
            maskPtr[i] = i < realLength ? 1 : 0
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIdsArray),
            "attention_mask": MLFeatureValue(multiArray: attentionMaskArray),
        ])
        let output = try model.prediction(from: provider)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw DisfluencyCleanupError.missingLogitsOutput
        }
        // Expected shape [1, MAX_LEN, 2]. Validate strictly so a model
        // regeneration with a wrong shape surfaces as a load-time error
        // instead of producing silently-wrong cleanup.
        let shape = logits.shape.map { $0.intValue }
        guard shape == [1, Self.maxSequenceLength, 2] else {
            throw DisfluencyCleanupError.unexpectedLogitsShape(shape)
        }

        // Pull DELETE-class softmax probability for each first-subword position
        // we recorded, and fold into the running averages.
        let logitsPtr = logits.dataPointer.bindMemory(
            to: Float.self, capacity: shape[0] * shape[1] * shape[2]
        )
        for (wordIndex, position) in firstSubwordPosition {
            let baseOffset = position * 2
            let keepLogit = logitsPtr[baseOffset]
            let deleteLogit = logitsPtr[baseOffset + 1]
            // Numerically-stable softmax over 2 classes.
            let maxLogit = max(keepLogit, deleteLogit)
            let keepExp = expf(keepLogit - maxLogit)
            let deleteExp = expf(deleteLogit - maxLogit)
            let deleteProb = deleteExp / (keepExp + deleteExp)
            sums[wordIndex] += deleteProb
            counts[wordIndex] += 1
        }
    }

    // MARK: - Reassembly

    /// Rebuild the cleaned transcript by stitching together the original
    /// substring slices for every word whose DELETE probability stayed
    /// below `threshold`. Walks character-by-character over the original
    /// `transcript`, emitting whitespace between surviving words and
    /// suppressing whitespace adjacent to deleted words so the output
    /// doesn't end up with double-spaces or stray leading space.
    private func assembleCleanedText(
        transcript: String,
        words: [SourceWord],
        deleteProbabilities: [Float],
        threshold: Float
    ) -> String {
        // Decide KEEP/DELETE per source word.
        var keep = [Bool](repeating: true, count: words.count)
        for i in 0..<words.count {
            // Punctuation-only "words" are always kept; they were never
            // scored. (Defensive: also enforce here in case
            // `predictDeleteProbabilities` ever changes its KEEP-by-default
            // rule for unscored slots.)
            if words[i].isPunctuationOnly {
                keep[i] = true
                continue
            }
            keep[i] = deleteProbabilities[i] < threshold
        }

        // Walk the original transcript and emit kept words + the whitespace
        // that came AFTER each kept word, but never any whitespace that
        // came after a deleted word (so a deleted leading "um " disappears
        // cleanly without leaving a leading space). Whitespace BEFORE the
        // first kept word is preserved if the very first word is kept;
        // otherwise it's stripped.
        var result = ""
        result.reserveCapacity(transcript.count)

        var lastEmittedEnd: String.Index? = nil
        for (i, word) in words.enumerated() {
            guard keep[i] else { continue }
            // Inter-word whitespace: between `lastEmittedEnd` and `word.range.lowerBound`.
            if let lastEnd = lastEmittedEnd {
                if lastEnd < word.range.lowerBound {
                    // Collapse multi-space gaps to a single space. The
                    // original may have had several spaces between words
                    // if a deleted word was between them; preserve the
                    // user's intent (one separator between words).
                    result.append(" ")
                }
            } else if word.range.lowerBound > transcript.startIndex {
                // First kept word — preserve only whitespace that
                // immediately preceded the start of the transcript IF
                // there's actually any. (Most transcripts don't start
                // with whitespace, but the dictation buffer occasionally
                // ships a leading space; preserving it costs nothing.)
                // Only emit if it's a single line's worth of whitespace,
                // not a paragraph break — we don't want to invent gaps.
                let leading = transcript[transcript.startIndex..<word.range.lowerBound]
                if leading.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" }) {
                    // Preserve newlines exactly (paragraph structure), but
                    // skip pure spaces/tabs (which the trimming above
                    // already handles for the typical case).
                    let onlyNewlines = String(leading.filter { $0 == "\n" })
                    result.append(onlyNewlines)
                }
            }
            result.append(String(transcript[word.range]))
            lastEmittedEnd = word.range.upperBound
        }

        return result
    }
}

private enum DisfluencyCleanupError: Error, CustomStringConvertible {
    case missingLogitsOutput
    case unexpectedLogitsShape([Int])

    var description: String {
        switch self {
        case .missingLogitsOutput:
            return "model output missing `logits` feature"
        case .unexpectedLogitsShape(let shape):
            return "model output `logits` has shape \(shape); expected [1, 128, 2]"
        }
    }
}

#endif
