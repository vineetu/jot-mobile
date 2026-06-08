#if JOT_APP_HOST
import Foundation

/// Reciprocal Rank Fusion of multiple ranked lists into one. Used to combine
/// the dense (chunk-vector cosine) and lexical (in-memory BM25) candidate lists
/// in the Ask hybrid-retrieval pipeline — see
/// `docs/plans/ask-retrieval-architecture.md` §2.B.2.
///
/// ## Why RRF
///
/// RRF fuses on **rank**, not raw score, so it needs no per-source score
/// normalization or tuning — a dense cosine of 0.42 and a BM25 score of 11.3
/// are incomparable as numbers but trivially comparable as positions. The score
/// for a doc is Σ over the lists it appears in of `1 / (k + rank)`, where `rank`
/// is its 0-based position in that list. Larger `k` flattens the contribution
/// of top ranks (the standard default is 60).
enum RRFFusion {
    /// Fuse `rankedLists` (each ordered best-first, rank 0 = best) into a single
    /// best-first, deduped ordering of doc ids.
    ///
    /// Score: for each id, Σ over every list containing it of `1 / (k + rank)`.
    /// Higher summed score sorts earlier. Ties are broken deterministically by
    /// the best (smallest) rank the id was seen at across any list, then by
    /// first appearance order — so the output is fully stable for a given input.
    ///
    /// Empty input (no lists, or all lists empty) returns `[]`.
    static func fuse(_ rankedLists: [[UUID]], k: Int = 60) -> [UUID] {
        var score: [UUID: Double] = [:]
        var bestRank: [UUID: Int] = [:]
        var firstSeen: [UUID: Int] = [:]
        var order = 0

        for list in rankedLists {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / Double(k + rank)
                if let prev = bestRank[id] {
                    bestRank[id] = min(prev, rank)
                } else {
                    bestRank[id] = rank
                    firstSeen[id] = order
                    order += 1
                }
            }
        }

        return score.keys.sorted { lhs, rhs in
            let sl = score[lhs] ?? 0
            let sr = score[rhs] ?? 0
            if sl != sr { return sl > sr }
            let bl = bestRank[lhs] ?? Int.max
            let br = bestRank[rhs] ?? Int.max
            if bl != br { return bl < br }
            return (firstSeen[lhs] ?? Int.max) < (firstSeen[rhs] ?? Int.max)
        }
    }
}
#endif
