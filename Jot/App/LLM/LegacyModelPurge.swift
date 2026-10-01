import Foundation
import os

/// One-shot purge of on-disk weights left behind by rewrite / retrieval
/// backends Jot no longer ships:
///
/// - **Qwen 3.5 4B (MLX)** — the former "Jot's AI" rewrite + Ask model, a
///   ~2.5 GB Hugging Face hub snapshot under the HF cache root.
/// - **Phi-4 mini (MLX)** — the model Qwen replaced; same cache layout.
/// - **EmbeddingGemma 300M (CoreML-LLM)** — the former Ask/search embedder,
///   installed under `Library/Application Support/CoreMLLLM/` (plus its
///   download staging directory).
///
/// Rewrite and Ask now run on Apple Foundation Models (on-device, with
/// Private Cloud Compute on iOS 27), and retrieval is Core Spotlight — none
/// of this needs a download any more, so the only job here is to give the
/// user their disk back.
///
/// Each leg is gated by its own `UserDefaults` flag so it runs at most once
/// per install. The flag is flipped BEFORE the detached delete is dispatched
/// so a slow delete that overlaps the next cold launch is not re-attempted
/// (same pattern as the earlier Phi-4 purge). Best-effort: never throws,
/// logs and bails on any FS error.
enum LegacyModelPurge {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "legacy-model-purge"
    )

    /// Run every purge leg that hasn't run yet. Call once from `JotApp.init`.
    static func runAllIfNeeded() {
        let hub = hfHubCacheRoot()
        purgeIfNeeded(
            flag: "jot.didPurgePhi4Weights",
            label: "Phi-4",
            directories: [hub.appendingPathComponent("models--mlx-community--Phi-4-mini-instruct-4bit", isDirectory: true)]
        )
        purgeIfNeeded(
            flag: "jot.didPurgeQwen35Weights",
            label: "Qwen 3.5",
            directories: [hub.appendingPathComponent("models--mlx-community--Qwen3.5-4B-4bit", isDirectory: true)]
        )
        let coreMLLLM = URL.applicationSupportDirectory
            .appendingPathComponent("CoreMLLLM", isDirectory: true)
        purgeIfNeeded(
            flag: "jot.didPurgeEmbeddingGemmaWeights",
            label: "EmbeddingGemma",
            directories: [
                coreMLLLM.appendingPathComponent("embeddinggemma-300m", isDirectory: true),
                coreMLLLM.appendingPathComponent(".embeddinggemma-staging", isDirectory: true),
            ]
        )
    }

    private static func purgeIfNeeded(flag: String, label: String, directories: [URL]) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }

        let fm = FileManager.default
        let present = directories.filter { fm.fileExists(atPath: $0.path) }
        // Flip the gate flag first — see the type doc comment.
        defaults.set(true, forKey: flag)
        guard !present.isEmpty else {
            log.info("\(label, privacy: .public) purge: nothing on disk; flag set")
            return
        }

        Task.detached(priority: .utility) {
            for dir in present {
                do {
                    try FileManager.default.removeItem(at: dir)
                    log.notice("\(label, privacy: .public) weights purged at \(dir.path, privacy: .public)")
                } catch {
                    log.error("\(label, privacy: .public) purge failed at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Resolve the Hugging Face hub cache root the way the MLX clients did:
    /// `HF_HUB_CACHE`, then `HF_HOME/hub`, then the default
    /// `~/Library/Caches/huggingface/hub`.
    private static func hfHubCacheRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        func expanded(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return expanded(hubCache)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return expanded(hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return URL.cachesDirectory
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }
}
