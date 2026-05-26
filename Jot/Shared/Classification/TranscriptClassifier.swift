import Foundation
import OSLog

// Main-app-only: the classifier reaches into `LLMClientFactory` which
// pulls MLX + Apple Foundation Models — neither is linkable into the
// keyboard extension's 60 MB envelope. Wrapping in `JOT_APP_HOST`
// keeps the file in `Shared/` (because the @Model + BG-task wiring
// it pairs with also lives there) while preventing the keyboard from
// compiling the inference symbols.
#if JOT_APP_HOST

/// Background classifier that tags a transcript with one of:
/// `email | message | note | code | general`.
///
/// ## How it works (v1)
///
/// Prompts Qwen 3.5 4B (already on-device for AI Rewrite) with a
/// classification system prompt + the transcript text. The model is asked
/// to respond with a JSON object describing its top pick, second pick, and
/// a self-reported gap score. Output flows through the existing
/// grammar-constrained `LLMClient.rewrite(text:systemPrompt:)` API — the
/// grammar enforces `{text: String}`, and we ask the model to put the
/// classification JSON *inside* that text field. We then parse the inner
/// JSON.
///
/// This piggybacking is pragmatic for v1: it adds no new MLX surface, no
/// new `@Generable` types, no protocol additions. If field telemetry
/// shows the model often disobeys the inner-JSON contract (e.g. just
/// emits the category name as a bare word), we graduate to a real
/// `classify(...)` LLMClient method with a dedicated `@Generable`
/// `ClassifyResult` schema in a later build.
///
/// ## Gating
///
/// - If `gap < 0.3` → fall back to `.general`.
///   Self-reported gap is calibration-suspect, but combined with this
///   threshold the bias is conservative: "when in doubt, bucket as
///   general." Better to leave a real email bucketed `general` than to
///   mis-tag a random note as `email`.
/// - On any parse failure (bad JSON, unknown category name, model
///   produced free text) → `.general`.
///
/// ## What this is NOT
///
/// - **Not synchronous.** The recommended call site is from a
///   `BGProcessingTask` handler (`TranscriptClassifierTask`), not the
///   dictation pipeline. A single classification takes ~2-5 seconds on
///   Qwen and we don't want to block transcript completion.
/// - **Not re-entrant for the same transcript.** Caller is responsible
///   for filtering already-classified rows (`category != nil`).
/// - **Not currently aware of `cleanedText` / `rewriteUserEdit`.** v1
///   classifies on `text` (the raw transcript) only.
@available(iOS 26.0, *)
@MainActor
enum TranscriptClassifier {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "classifier"
    )

    /// Canonical category set. Stored on `Transcript.category` as the
    /// rawValue string.
    enum Category: String, CaseIterable {
        case email
        case message
        case note
        case code
        case general
    }

    /// Minimum self-reported gap needed to accept the model's `top`
    /// category. Below this we bucket as `.general`. See class doc
    /// for the rationale — gap from an LLM's self-report is a hint,
    /// not a calibrated probability.
    private static let gapThreshold: Double = 0.3

    /// Maximum characters of input fed to Qwen for classification.
    /// Bounded for two reasons:
    /// 1. Memory: KV cache during inference scales linearly with input
    ///    token count. A 5000-word ramble is ~6500 tokens, which gives
    ///    a KV cache of ~500 MB on top of the 2.5 GB model weights.
    ///    On a 6 GB iPhone budget that's the difference between
    ///    "fits" and "jetsam."
    /// 2. Signal: classification doesn't need the whole text. The
    ///    first ~500 words tell you reliably whether it's an email
    ///    vs. a code snippet vs. a note. The tail just slows us down
    ///    without improving accuracy.
    ///
    /// 2000 chars ≈ 400-500 words ≈ 500-700 tokens. Empirically more
    /// than enough for the 5-class taxonomy. Truncation is invisible
    /// to the user — they still see the full transcript everywhere
    /// else; this only affects what the classifier sees.
    private static let maxInputCharacters: Int = 2000

    /// System prompt seen by Qwen on every classification call.
    ///
    /// IMPORTANT — grammar contract: this call routes through
    /// `LLMClient.rewrite(...)`, whose grammar-constrained decoder forces
    /// output of the shape `{"text": "<string>"}`. We tell the model
    /// explicitly that the inner `<string>` MUST be a JSON-encoded
    /// classification object. The class doc covers the trick; this
    /// prompt is where the contract becomes load-bearing — without the
    /// explicit "your reply will be wrapped" instruction the model often
    /// puts a bare word ("email") or a natural-language hedge in the
    /// text field, breaking our parser.
    private static let systemPrompt: String = """
        You are classifying a user's dictation transcript into ONE category from this list:
        - email: drafting or composing an email
        - message: short message, SMS, Slack, chat, text reply
        - note: personal note, journal, todo, reminder, idea capture
        - code: programming, technical/code-like content
        - general: anything that doesn't clearly fit above

        OUTPUT CONTRACT — read carefully:
        Your reply will be wrapped by the system into a JSON object: {"text": "<your-reply>"}.
        You MUST write your reply so the <your-reply> string contains EXACTLY this JSON object (and nothing else):
        {"top":"<category>","second":"<alternate_category>","gap":<float between 0.0 and 1.0>}

        Where:
        - "top" is the best-fit category name from the list above (one word, lowercase).
        - "second" is the second-best category name (one word, lowercase). If nothing else fits, use "general".
        - "gap" estimates how strongly top beats second: 0.0 = tied, 1.0 = overwhelmingly clear.

        Do NOT write a bare word like "email" by itself.
        Do NOT write a natural-language sentence.
        Do NOT add commentary, preamble, quoting, or markdown fences.
        ONLY the classification JSON object — nothing else — in the text field.

        Examples of correct replies (these are what you'd write inside <your-reply>):
        - {"top":"message","second":"email","gap":0.4}
        - {"top":"email","second":"general","gap":0.9}
        - {"top":"note","second":"general","gap":0.8}
        - {"top":"code","second":"general","gap":0.9}
        """

    // MARK: - Public API

    /// Classifies a single transcript text. Always returns a `Category` —
    /// `.general` on any failure path (empty text, model error, malformed
    /// output, gap below threshold).
    ///
    /// Each call invokes one round-trip to Qwen, which takes ~2-5 seconds.
    /// Callers should batch and bound their iteration count to fit inside
    /// a `BGProcessingTask`'s wall-clock budget.
    static func classify(text: String) async -> Category {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.notice("classify: empty text -> general")
            return .general
        }

        // Truncate before inference. See `maxInputCharacters` doc for
        // the memory-vs-signal rationale. We use simple character
        // truncation rather than word-aware splitting because the
        // classifier doesn't care about token boundaries — it just
        // needs enough lead text to recognize the kind of content.
        // Append an ellipsis marker so the model knows the input was
        // cut (avoids it trying to "finish" the dangling sentence).
        let input: String
        let wasTruncated: Bool
        if trimmed.count > maxInputCharacters {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxInputCharacters)
            input = String(trimmed[..<cutoff]) + " […]"
            wasTruncated = true
        } else {
            input = trimmed
            wasTruncated = false
        }

        let client = LLMClientFactory.shared.client()

        let started = Date()
        let raw: String
        do {
            raw = try await client.rewrite(text: input, systemPrompt: systemPrompt)
        } catch is CancellationError {
            log.notice("classify: cancelled mid-call")
            return .general
        } catch {
            log.error(
                "classify: rewrite call FAILED error=\(error.localizedDescription, privacy: .public)"
            )
            return .general
        }
        let elapsed = Date().timeIntervalSince(started)

        let category = parseClassification(raw: raw)
        log.info(
            "classify: \(category.rawValue, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s inputChars=\(input.count, privacy: .public) rawChars=\(raw.count, privacy: .public) truncated=\(wasTruncated, privacy: .public)"
        )
        return category
    }

    // MARK: - Parsing

    /// Parses the model's raw output (the contents of the `text` field
    /// of the `Rewrite` JSON) as a classification JSON. Falls back to
    /// `.general` on any failure.
    ///
    /// Tolerates leading/trailing whitespace and surrounding noise by
    /// extracting the first `{...}` block we find. Some hosted models
    /// occasionally wrap structured output in markdown fences (\`\`\`json ...
    /// \`\`\`); the block-extraction approach side-steps that.
    private static func parseClassification(raw: String) -> Category {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonRange = firstJSONObjectRange(in: trimmed) else {
            log.error("classify: no JSON object in output, raw=\(trimmed, privacy: .public)")
            return .general
        }

        let jsonSubstring = String(trimmed[jsonRange])
        struct ClassifyOutput: Codable {
            let top: String
            let second: String?
            let gap: Double?
        }
        guard let data = jsonSubstring.data(using: .utf8),
              let output = try? JSONDecoder().decode(ClassifyOutput.self, from: data) else {
            log.error("classify: JSON decode failed, raw=\(jsonSubstring, privacy: .public)")
            return .general
        }

        guard let category = Category(rawValue: output.top.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) else {
            log.notice(
                "classify: unknown top=\(output.top, privacy: .public) -> general"
            )
            return .general
        }

        // Gap is optional in the schema (some model runs omit it). Treat
        // missing gap as "model didn't tell us — accept top anyway." A
        // missing gap is a different failure mode from a *low* gap.
        if let gap = output.gap, gap < gapThreshold {
            log.notice(
                "classify: top=\(category.rawValue, privacy: .public) gap=\(gap, privacy: .public) < \(gapThreshold) -> general"
            )
            return .general
        }

        return category
    }

    /// Finds the range of the first balanced `{...}` block in `s`.
    /// Returns nil if no balanced block exists. Used to peel the JSON
    /// out of any preamble/postamble the model may emit despite the
    /// "no other text" instruction.
    private static func firstJSONObjectRange(in s: String) -> Range<String.Index>? {
        guard let open = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = open
        while idx < s.endIndex {
            let c = s[idx]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    return open..<s.index(after: idx)
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }
}

#endif  // JOT_APP_HOST
