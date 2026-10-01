#if JOT_APP_HOST
import Foundation
import OSLog

/// One chunk of the bundled help corpus — a single `§N.M` feature subsection
/// distilled from `features.md` (see `docs/ask-product-help/design.md`). The
/// chunking strategy (structural, one chunk per authored subsection) was chosen
/// by an offline retrieval experiment: it beat both LLM and embedding-based
/// semantic chunking on this corpus.
struct HelpChunk: Sendable {
    let id: String        // "§N.M" section id, e.g. "2.4"
    let title: String     // human title, e.g. "Pause / Resume"
    let anchor: String    // citation / future deep-link target
    let text: String      // title-led body (no §id in text)
    /// Ephemeral per-launch id so the corpus can reuse the UUID-keyed
    /// `BM25Index` without a parallel String-keyed implementation.
    let uuid: UUID
}

/// In-memory index over the bundled, static help corpus. Powers Ask's
/// product-help lane ("how do I use Jot"): the Ask model calls
/// `JotHelpSearchTool`, which retrieves from here with BM25 over the chunk
/// text. No embedder, no download, no SwiftData — loaded once on first use.
///
/// `scripts/check-help-corpus-fresh.sh` guards staleness vs `features.md`
/// (the bundle stamps `features.md`'s sha256 as `sourceHash`).
actor HelpCorpusIndex {
    static let shared = HelpCorpusIndex()

    private struct CorpusChunk: Decodable {
        let id: String; let title: String; let anchor: String; let text: String
    }
    private struct CorpusBundle: Decodable {
        let sourceHash: String; let chunks: [CorpusChunk]
    }

    private var didLoad = false
    private var chunks: [HelpChunk] = []
    private var index: BM25Index?
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
        chunks = bundle.chunks.map {
            HelpChunk(id: $0.id, title: $0.title, anchor: $0.anchor, text: $0.text, uuid: UUID())
        }
        index = BM25Index(documents: chunks.map { (id: $0.uuid, text: $0.text) })
        available = !chunks.isEmpty
        Self.log.info("help corpus loaded: \(self.chunks.count) chunks, sourceHash=\(bundle.sourceHash.prefix(12), privacy: .public)")
        return available
    }

    /// Whether the bundled corpus loaded and has at least one chunk.
    var isAvailable: Bool { ensureLoaded() }

    /// Lexical (BM25) retrieval over the help chunks. Returns up to `k`
    /// chunks, best match first.
    func retrieve(query: String, k: Int) -> [HelpChunk] {
        guard ensureLoaded(), let index else { return [] }
        let byUUID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.uuid, $0) })
        return index.search(query, limit: k).compactMap { byUUID[$0.id] }
    }
}
#endif
