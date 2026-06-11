#if JOT_APP_HOST
import Foundation
import OSLog

/// One chunk of the bundled help corpus — a single `§N.M` feature subsection
/// distilled from `features.md` (see `docs/ask-product-help/design.md`). The
/// chunking strategy (structural, one chunk per authored subsection) was chosen
/// by an offline retrieval experiment: it beat both LLM and embedding-based
/// semantic chunking on this corpus.
struct HelpChunk {
    let id: String        // "§N.M" section id, e.g. "2.4"
    let title: String     // human title, e.g. "Pause / Resume"
    let anchor: String     // citation / future deep-link target
    let text: String      // embedded + prompted body (title-led; no §id in text)
    let vector: [Float]   // 256-d unit-norm, EmbeddingGemma `.document`
    /// Ephemeral per-launch id so the corpus can reuse the UUID-keyed
    /// `BM25Index` / `RRFFusion` without a parallel String-keyed implementation.
    let uuid: UUID
}

/// In-memory index over the bundled, static help corpus. Powers Ask's
/// product-help lane ("how do I use Jot"). Loaded once on first use — no
/// SwiftData, no migration, no runtime embedding of the corpus itself (only the
/// *query* is embedded at query time, by `EmbeddingGemmaService`).
///
/// ## Version safety
///
/// The bundle stamps the embedding `modelVersion` it was built with. If that
/// doesn't match the runtime embedder, the corpus vectors are incomparable to
/// runtime query vectors (cosine collapses to noise) — so the lane **disables
/// itself** (Ask routes everything to the transcript lane) rather than serving
/// garbage. `scripts/check-help-corpus-fresh.sh` guards staleness vs
/// `features.md` at build time.
actor HelpCorpusIndex {
    static let shared = HelpCorpusIndex()

    private struct CorpusChunk: Decodable {
        let id: String; let title: String; let anchor: String
        let text: String; let vector: [Float]
    }
    private struct CorpusBundle: Decodable {
        let modelVersion: String; let sourceHash: String; let chunks: [CorpusChunk]
    }

    private var didLoad = false
    private var chunks: [HelpChunk] = []
    private var available = false

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot", category: "help-corpus")

    /// Load + validate once. Returns whether the help lane is usable.
    private func ensureLoaded() -> Bool {
        if didLoad { return available }
        didLoad = true
        guard let url = Bundle.main.url(forResource: "help-corpus", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            Self.log.error("help-corpus.json not found in bundle — help lane disabled")
            return false
        }
        guard let bundle = try? JSONDecoder().decode(CorpusBundle.self, from: data) else {
            Self.log.error("help-corpus.json failed to decode — help lane disabled")
            return false
        }
        guard bundle.modelVersion == EmbeddingGemmaService.modelVersion else {
            Self.log.error("""
                help-corpus modelVersion \(bundle.modelVersion, privacy: .public) != runtime \
                \(EmbeddingGemmaService.modelVersion, privacy: .public) — help lane DISABLED \
                (regenerate help-corpus.json)
                """)
            return false
        }
        chunks = bundle.chunks.map {
            HelpChunk(id: $0.id, title: $0.title, anchor: $0.anchor,
                      text: $0.text, vector: $0.vector, uuid: UUID())
        }
        available = !chunks.isEmpty
        Self.log.info("help corpus loaded: \(self.chunks.count) chunks, sourceHash=\(bundle.sourceHash.prefix(12), privacy: .public)")
        return available
    }

    /// Best (max) cosine of `queryVector` against any help chunk — the lane
    /// selection signal (compared against the best transcript-chunk cosine).
    /// 0 when the lane is unavailable. `queryVector` must be unit-norm.
    func bestCosine(_ queryVector: [Float]) -> Float {
        guard ensureLoaded() else { return 0 }
        var best: Float = 0
        for c in chunks {
            let s = Self.dot(queryVector, c.vector)
            if s > best { best = s }
        }
        return best
    }

    /// Hybrid retrieve: dense cosine + in-memory BM25, fused with RRF (k=60),
    /// mirroring the transcript lane. Returns up to `k` help chunks in fused
    /// order. `queryVector` must be unit-norm (`.query` role).
    func retrieve(query: String, queryVector: [Float], k: Int) -> [HelpChunk] {
        guard ensureLoaded() else { return [] }
        let byUUID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.uuid, $0) })
        let dense = chunks
            .map { (id: $0.uuid, score: Self.dot(queryVector, $0.vector)) }
            .sorted { $0.score > $1.score }
            .prefix(50).map { $0.id }
        let lexical = BM25Index(documents: chunks.map { (id: $0.uuid, text: $0.text) })
            .search(query, limit: 50).map { $0.id }
        let fused = RRFFusion.fuse([Array(dense), lexical], k: 60).prefix(k)
        return fused.compactMap { byUUID[$0] }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        for i in 0..<n { s += a[i] * b[i] }
        return s
    }
}
#endif
