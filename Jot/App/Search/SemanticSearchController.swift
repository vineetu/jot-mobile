#if JOT_APP_HOST
import Foundation
import OSLog
import SwiftData

/// Live semantic-search controller, used as `@State` inside SwiftUI
/// surfaces that want hybrid (substring + meaning) transcript search.
///
/// ## Hybrid contract
///
/// The controller publishes ONLY the semantic half of the result —
/// substring matching is cheap and remains in the consuming view's
/// existing filter logic. Consumers compose `searchText.contains(...)`
/// with `semanticMatches.contains(transcript.id)` to get the union.
/// Substring matches surface immediately on keystroke (no async); the
/// semantic set fills in ~250-400ms later (200ms debounce + 30-50ms
/// query embed + 10-20ms cosine scan).
///
/// ## Chunk-based retrieval
///
/// Retrieval now runs over EmbeddingGemma **chunk** embeddings rather
/// than one MiniLM vector per whole transcript. Each transcript is split
/// into overlapping text chunks at index time; every chunk gets its own
/// 256-d unit-norm Gemma vector (`role: .document`). At search time the
/// query is embedded with `role: .query` (asymmetric prompt) and scored
/// against every chunk. A transcript matches if ANY of its chunks clears
/// the threshold; we dedup to the single best-scoring chunk per
/// transcript so each transcript counts once.
///
/// ## Threshold
///
/// Defaults to 0.50 — a strict cosine cutoff that prioritizes precision
/// over recall. Gemma query/document cosines for "clearly the same topic"
/// chunk pairs typically sit > 0.5; below 0.5 false positives climb fast
/// (related-but-different topics). Tunable per-call.
///
/// ## Performance envelope
///
/// At ~10k transcripts, one search loads the chunk vectors into memory
/// for the cosine pass. Chunking inflates row count vs. the old
/// whole-transcript scheme; users with very large libraries may need a
/// streaming variant — flag noted in `docs/plans/minilm-embeddings.md`
/// §Open question 3.
@MainActor
@Observable
final class SemanticSearchController {
    /// Last completed semantic-match set for the currently-published
    /// query. Empty when the query is blank or the search is in flight.
    /// Consumers read this from view bodies; SwiftUI re-renders when it
    /// changes via `@Observable`.
    private(set) var semanticMatches: Set<UUID> = []

    /// `true` while a search task is in flight (post-debounce). Views
    /// can show a subtle spinner; not required for v1.
    private(set) var isSearching: Bool = false

    /// Cosine cutoff applied during `findMatches`. Higher = more precise,
    /// fewer results. 0.5 is the build-53 default per user direction.
    private let defaultThreshold: Float = 0.50

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "semantic-search"
    )

    private var searchTask: Task<Void, Never>?

    /// Updates the search query. Cancels any in-flight task, debounces
    /// ~200 ms (so rapid typing doesn't fire one embed per keystroke),
    /// then embeds + matches. Empty / whitespace query clears matches
    /// synchronously.
    func search(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            semanticMatches = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            // Debounce — keystroke storms shouldn't spawn a full embed
            // per stroke.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            // Embed the query with the ASYMMETRIC query prompt — chunks
            // were indexed with `role: .document`, so the query MUST use
            // `role: .query` to land in the same space.
            guard let queryVector = try? await EmbeddingGemmaService.shared.encode(trimmed, role: .query) else {
                await MainActor.run { self?.isSearching = false }
                return
            }
            if Task.isCancelled { return }
            let matches = await Self.findMatches(
                queryVector: queryVector,
                threshold: self?.defaultThreshold ?? 0.50
            )
            if Task.isCancelled { return }
            await MainActor.run {
                self?.semanticMatches = matches
                self?.isSearching = false
            }
        }
    }

    /// Convenience reset — used when consuming view goes away (the
    /// search task is also cancelled via `searchTask?.cancel()` in
    /// `search(query:)`).
    func clear() {
        searchTask?.cancel()
        semanticMatches = []
        isSearching = false
    }

    // MARK: - Cosine scan

    @MainActor
    private static func findMatches(
        queryVector: [Float],
        threshold: Float
    ) async -> Set<UUID> {
        let normalizedQuery = normalize(queryVector)
        // Empty / zero query vector — nothing to score against.
        guard !normalizedQuery.isEmpty else { return [] }

        // Pull every chunk indexed under the current Gemma model version.
        // (Version-scoping prevents matching against stale vectors written
        // by a prior model.) Empty pool -> no matches.
        let chunks = ChunkStore.allChunks(modelVersion: EmbeddingGemmaService.modelVersion)
        guard !chunks.isEmpty else { return [] }

        // Both query and chunk vectors are already unit-norm out of Gemma,
        // so cosine == dot. We still defensively re-normalize so a stray
        // un-normalized blob can't poison the score. Best score per
        // transcript wins; a transcript matches if its best chunk clears
        // the threshold.
        var bestByTranscript: [UUID: Float] = [:]
        for chunk in chunks {
            let vector = chunk.vector
            guard vector.count == normalizedQuery.count else { continue }
            let normalizedRow = normalize(vector)
            guard !normalizedRow.isEmpty else { continue }
            let cosine = dot(normalizedQuery, normalizedRow)
            guard cosine >= threshold else { continue }
            let id = chunk.transcriptID
            if let existing = bestByTranscript[id] {
                if cosine > existing { bestByTranscript[id] = cosine }
            } else {
                bestByTranscript[id] = cosine
            }
        }
        return Set(bestByTranscript.keys)
    }

    // MARK: - Math

    private static func normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return [] }
        return v.map { $0 / norm }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { sum += a[i] * b[i] }
        return sum
    }
}
#endif
