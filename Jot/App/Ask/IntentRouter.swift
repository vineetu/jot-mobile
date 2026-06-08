#if JOT_APP_HOST
import Foundation

/// The retrieval strategy an Ask query should take. Picked once, up front, by
/// `IntentRouter` from the raw query text plus two cheap caller-supplied flags.
///
/// - `lookup`: a specific question ("what did I say about X") → hybrid retrieve
///   → rerank → QA-with-citations. This is the **safe default** — see below.
/// - `summarize`: an aggregate / reflective ask ("what have I been thinking
///   about lately", "themes this week", a bare date window) → metadata filter →
///   map-reduce summarize, NOT vector search.
/// - `browse`: pure metadata listing with no question to synthesize ("my work
///   notes", "long recordings") → metadata filter → list.
enum AskIntent: Equatable {
    case lookup
    case summarize
    case browse
}

/// Classifies an Ask query into an `AskIntent`. Deterministic, cheap, no model
/// (an optional Qwen disambiguation pass is deferred to T3.3's stretch goal).
///
/// ## Why the bias toward `lookup`
///
/// Per `docs/plans/ask-retrieval-architecture.md` §2.B.1, the cost of a
/// misclassification is asymmetric: a wrong `lookup` **degrades gracefully**
/// (the user still sees relevant notes), while a wrong `summarize` makes the
/// model **confabulate** across loosely-related notes. So whenever `summarize`
/// and `lookup` both look plausible — the classic "topic AND time" case, e.g.
/// "what did I think about X lately" — we choose `lookup` and let the date
/// filter narrow the pool. `lookup` is also the catch-all default for anything
/// we don't positively recognize as `summarize` or `browse`.
///
/// ## Decision order
///
/// 1. **`summarize`** — the query is aggregate/reflective (recap verbs,
///    "lately", "themes", "what have I been thinking", "what did I talk about")
///    AND has no strong specific topic; OR a date scope is present with no
///    strong topic (a bare time window = "summarize that window").
/// 2. **`browse`** — pure metadata filtering with no interrogative synthesis
///    ("my work notes", "show my <tag> notes", "long recordings", "notes from
///    my watch"): an imperative/possessive listing, not a question.
/// 3. **`lookup`** — everything else, and any ambiguity.
enum IntentRouter {
    /// - Parameters:
    ///   - query: the raw Ask query text.
    ///   - hasDateScope: whether a date range was already parsed from the query
    ///     (the caller runs `AskController.parseDateScope` and passes the result).
    ///   - hasStrongTopic: whether the query contains substantive topic words
    ///     beyond stopwords / time-words / meta-words. The caller computes this
    ///     best-effort; it disambiguates "topic AND time" toward `lookup`.
    static func route(_ query: String, hasDateScope: Bool, hasStrongTopic: Bool) -> AskIntent {
        let lower = query.lowercased()

        func matches(_ pattern: String) -> Bool {
            lower.range(of: pattern, options: .regularExpression) != nil
        }

        // --- Step 1: summarize (aggregate / reflective, no strong topic) -----
        //
        // These phrasings ask the model to synthesize across many notes rather
        // than pull a specific fact. We only route here when there's no strong
        // topic — "what have I been thinking about *the database migration*"
        // has a topic and should be a lookup, not a fuzzy recap.
        let aggregatePhrasings = [
            #"\bwhat\s+have\s+i\s+been\s+(thinking|saying|talking|working|up\s+to)\b"#,
            #"\bwhat'?s?\s+been\s+on\s+my\s+mind\b"#,
            #"\bwhat\s+did\s+i\s+(talk|think)\s+about\b"#,
            #"\b(summari[sz]e|summary|recap|overview|tl;?dr|catch\s+me\s+up)\b"#,
            #"\bthemes?\b"#,
            #"\b(lately|recently)\b"#,
        ]
        let isAggregatePhrasing = aggregatePhrasings.contains { matches($0) }

        if !hasStrongTopic && (isAggregatePhrasing || hasDateScope) {
            return .summarize
        }

        // --- Step 2: browse (pure metadata listing, no question) -------------
        //
        // Imperative/possessive list requests with no interrogative synthesis.
        // Gated on the ABSENCE of question words so "what are my work notes
        // about" stays a lookup. A strong topic doesn't disqualify browse —
        // "my work notes" has "work" as a topic-ish word but is still a listing.
        let hasQuestionShape =
            matches(#"^\s*(what|who|when|where|why|how|did|do|does|is|are|was|were|tell\s+me)\b"#)
            || matches(#"\?\s*$"#)

        let browsePhrasings = [
            #"^\s*(show|list|find|get|pull\s+up|bring\s+up|give\s+me)\b"#,
            #"^\s*my\s+\w+\s+(notes?|recordings?|transcripts?|memos?)\b"#,
            #"\b(long|short)\s+(notes?|recordings?|transcripts?|memos?)\b"#,
            #"\bnotes?\s+from\s+(my\s+)?(watch|keyboard|phone)\b"#,
        ]
        let isBrowsePhrasing = browsePhrasings.contains { matches($0) }

        if !hasQuestionShape && isBrowsePhrasing {
            return .browse
        }

        // --- Step 3: safe default --------------------------------------------
        // Everything else, and every ambiguity (incl. topic + date), is lookup.
        return .lookup
    }
}
#endif
