#if JOT_APP_HOST
import Foundation
import OSLog

/// In-memory BM25 lexical (keyword) search index over transcript chunks.
///
/// ## Why this exists
///
/// Ask-mode retrieval is **hybrid**: a dense vector (embedding) scan catches
/// semantic matches, and this lexical index catches *exact* terms — names,
/// jargon, codenames, acronyms — that dense search routinely misses because
/// those tokens collapse into the same neighbourhood in embedding space.
/// See `docs/plans/ask-retrieval-architecture.md` §2.B.
///
/// It is deliberately an **in-memory** index rather than SQLite FTS5. SwiftData
/// owns the underlying store and hides the raw SQLite handle, so FTS5 virtual
/// tables aren't reachable. Building a small inverted index in memory at query
/// time is therefore the zero-new-dependency option (Foundation only — no
/// SwiftData, no ML, no packages). Corpus sizes here are small (a user's own
/// transcript chunks), so the memory + build cost is negligible.
///
/// ## The BM25 algorithm
///
/// BM25 (Robertson / Sparck-Jones, the "Okapi" ranking function) scores a
/// document `D` against a query `Q` as the sum over query terms `t`:
///
///     score(D, Q) = Σ_t  IDF(t) · ( f(t,D) · (k1 + 1) )
///                                  ───────────────────────────────────────
///                                  f(t,D) + k1 · (1 - b + b · |D| / avgdl)
///
/// where
///   - `f(t,D)`   = raw frequency of term `t` in document `D`,
///   - `|D|`      = length of `D` in tokens,
///   - `avgdl`    = average document length across the corpus,
///   - `IDF(t)`   = ln(1 + (N - n(t) + 0.5) / (n(t) + 0.5)),
///   - `N`        = number of documents, `n(t)` = docs containing `t`.
///
/// `k1` controls term-frequency saturation (more occurrences help, with
/// diminishing returns); `b` controls how aggressively long documents are
/// penalised relative to `avgdl`. The standard defaults are `k1 = 1.5`,
/// `b = 0.75`. The IDF form above is the BM25+ "always non-negative" variant
/// (the `1 +` inside the log keeps IDF ≥ 0 even for terms appearing in more
/// than half the corpus, avoiding negative contributions).
///
/// ## Tokenisation (v1, deliberately minimal)
///
/// Lowercase, then split on any non-alphanumeric Unicode boundary
/// (letters/digits survive, everything else is a separator), dropping empty
/// tokens. **No stemming and no stopword list** — this is an intentional v1
/// choice: stemming risks mangling the very codenames/jargon this index is
/// meant to catch, and a stopword list adds a tuning surface we don't need at
/// this corpus size. Both can be layered in later without changing the public
/// interface.
///
/// ## Determinism
///
/// Pure and deterministic: no `Date()`, no randomness. Score ties are broken by
/// original insertion order (lower document index first) so identical corpora
/// always produce identical rankings.
struct BM25Index {

    // MARK: - Stored index

    /// Document ids, in the order supplied to `init` (the "insertion order"
    /// used for deterministic tie-breaking).
    private let ids: [UUID]

    /// Token length of each document, parallel to `ids`.
    private let docLengths: [Int]

    /// Average document length across the corpus (0 for an empty corpus).
    private let avgdl: Double

    /// Inverted index: term → postings list of (document index, term frequency).
    private let postings: [String: [(doc: Int, freq: Int)]]

    private let k1: Double
    private let b: Double

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "bm25-index"
    )

    // MARK: - Build

    /// Build the inverted index over the given documents. `id` is the chunk's UUID.
    init(documents: [(id: UUID, text: String)], k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b

        var ids: [UUID] = []
        ids.reserveCapacity(documents.count)
        var lengths: [Int] = []
        lengths.reserveCapacity(documents.count)
        var postings: [String: [(doc: Int, freq: Int)]] = [:]

        var totalLength = 0

        for (docIndex, document) in documents.enumerated() {
            ids.append(document.id)

            let tokens = Self.tokenize(document.text)
            lengths.append(tokens.count)
            totalLength += tokens.count

            // Collapse this doc's tokens into term → frequency, then append one
            // posting per distinct term.
            var freqs: [String: Int] = [:]
            for token in tokens {
                freqs[token, default: 0] += 1
            }
            for (term, freq) in freqs {
                postings[term, default: []].append((doc: docIndex, freq: freq))
            }
        }

        self.ids = ids
        self.docLengths = lengths
        self.postings = postings
        self.avgdl = documents.isEmpty ? 0 : Double(totalLength) / Double(documents.count)

        let builtDocs = documents.count
        let builtTerms = postings.count
        let builtAvgdl = self.avgdl
        Self.log.debug(
            "Built BM25 index: \(builtDocs, privacy: .public) docs, \(builtTerms, privacy: .public) terms, avgdl \(builtAvgdl, privacy: .public)"
        )
    }

    // MARK: - Query

    /// Returns up to `limit` doc ids ranked best-first with their BM25 score.
    func search(_ query: String, limit: Int) -> [(id: UUID, score: Double)] {
        guard limit > 0, !ids.isEmpty else { return [] }

        let queryTerms = Self.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        let n = Double(ids.count)

        // Accumulate score per document index. Only documents that contain at
        // least one query term ever get an entry, so the sparse dictionary
        // matches the "docs that contain any query term" requirement.
        var scores: [Int: Double] = [:]

        // De-duplicate query terms so a term repeated in the query doesn't
        // double-count its IDF contribution.
        for term in Set(queryTerms) {
            guard let termPostings = postings[term] else { continue }

            let df = Double(termPostings.count) // n(t): docs containing the term
            let idf = Foundation.log(1 + (n - df + 0.5) / (df + 0.5))

            for posting in termPostings {
                let f = Double(posting.freq)
                let docLen = Double(docLengths[posting.doc])
                let denom = f + k1 * (1 - b + b * (docLen / avgdl))
                let contribution = idf * (f * (k1 + 1)) / denom
                scores[posting.doc, default: 0] += contribution
            }
        }

        guard !scores.isEmpty else { return [] }

        // Sort by score descending; break ties by lower document index
        // (insertion order) for determinism.
        let ranked = scores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        return ranked.prefix(limit).map { (id: ids[$0.key], score: $0.value) }
    }

    // MARK: - Introspection

    var documentCount: Int { ids.count }

    // MARK: - Tokenisation

    /// Lowercase and split on non-alphanumeric Unicode boundaries, dropping
    /// empty tokens. No stemming, no stopwords (see type doc — v1 choice).
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
#endif
