import Foundation
import UIKit

/// One grammar or spelling issue the system checker found in a transcript.
struct GrammarIssue: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A grammar problem (agreement, punctuation, word choice …).
        case grammar
        /// A misspelling with a system-suggested correction.
        case spelling
    }

    let id: UUID
    let kind: Kind
    /// UTF-16 range of the problem in the text that was checked.
    let range: NSRange
    /// The problematic text as it appears in the transcript.
    let original: String
    /// Plain-language description from the system checker (may be empty).
    let detail: String
    /// Replacement candidates, best first. Empty when the checker only
    /// flagged the problem without a fix.
    let suggestions: [String]

    var hasSuggestion: Bool { !suggestions.isEmpty }
}

/// Proofreading for dictated text without a language model.
///
/// Wraps the iOS 27 grammar checker (`UITextChecker.requestGrammarChecking`) —
/// the same on-device engine behind the system keyboard's grammar
/// underlines. Fast, offline, no quota, every device. It is deliberately
/// *suggestive*: results are surfaced as underlines + an accept/ignore sheet
/// (`ProofreadSheet`), never applied silently, because dictated names and
/// vocabulary terms are exactly what a grammar checker likes to "fix"
/// (features.md §3.7 / §8).
///
/// Below iOS 27 there is no grammar API, so `isAvailable` is false and the
/// editor shows no proofread affordance.
enum GrammarCheckService {
    /// Keys of the `grammarDetails` dictionaries on a grammar
    /// `NSTextCheckingResult`. Foundation only exports the AppKit constants on
    /// macOS; on iOS the keys are the same strings, so they are spelled out.
    private static let grammarRangeKey = "NSGrammarRange"
    private static let grammarUserDescriptionKey = "NSGrammarUserDescription"
    private static let grammarCorrectionsKey = "NSGrammarCorrections"

    static var isAvailable: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    /// Check the whole `text` and return its issues in document order.
    /// Sentences with both a spelling and a grammar hit report both.
    static func check(_ text: String) async -> [GrammarIssue] {
        guard #available(iOS 27.0, *) else { return [] }
        let length = (text as NSString).length
        guard length > 0 else { return [] }
        // The checker's results are non-Sendable `NSTextCheckingResult`s, so
        // they are flattened into `GrammarIssue`s inside the completion and
        // only the Sendable issues cross the continuation.
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let checker = UITextChecker()
                checker.requestGrammarChecking(
                    of: text,
                    range: NSRange(location: 0, length: length),
                    waitForAllResults: true
                ) { results in
                    continuation.resume(returning: issues(from: results, in: text as NSString))
                }
            }
        }
    }

    /// Flatten checker results into issues. A grammar result covers a whole
    /// sentence and carries one `grammarDetails` entry per problem inside it;
    /// a correction result is a single misspelled word.
    private static func issues(from results: [NSTextCheckingResult], in text: NSString) -> [GrammarIssue] {
        var out: [GrammarIssue] = []
        let full = NSRange(location: 0, length: text.length)
        for result in results {
            switch result.resultType {
            case .grammar:
                let sentence = NSIntersectionRange(result.range, full)
                guard sentence.length > 0 else { continue }
                for detail in result.grammarDetails ?? [] {
                    guard let rangeValue = detail[grammarRangeKey] as? NSValue else { continue }
                    // `NSGrammarRange` is relative to the sentence.
                    let local = rangeValue.rangeValue
                    let absolute = NSIntersectionRange(
                        NSRange(location: sentence.location + local.location, length: local.length),
                        full
                    )
                    guard absolute.length > 0 else { continue }
                    let corrections = (detail[grammarCorrectionsKey] as? [String]) ?? []
                    out.append(GrammarIssue(
                        id: UUID(),
                        kind: .grammar,
                        range: absolute,
                        original: text.substring(with: absolute),
                        detail: (detail[grammarUserDescriptionKey] as? String) ?? "",
                        suggestions: corrections
                    ))
                }
            case .correction:
                let range = NSIntersectionRange(result.range, full)
                guard range.length > 0 else { continue }
                let replacement = result.replacementString ?? ""
                out.append(GrammarIssue(
                    id: UUID(),
                    kind: .spelling,
                    range: range,
                    original: text.substring(with: range),
                    detail: "",
                    suggestions: replacement.isEmpty ? [] : [replacement]
                ))
            default:
                continue
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Apply one suggestion to `text`, returning the new text. Ranges of the
    /// other issues shift, so callers re-run `check` afterwards.
    static func apply(_ suggestion: String, for issue: GrammarIssue, to text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let range = NSIntersectionRange(issue.range, full)
        guard range.length > 0, ns.substring(with: range) == issue.original else { return text }
        return ns.replacingCharacters(in: range, with: suggestion)
    }
}
