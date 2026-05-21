import Foundation
import os.log

/// User-selectable LLM backend for the AI rewrite path.
///
/// Persisted in App Group defaults under `AppGroup.Keys.aiRewriteProvider` so
/// the keyboard extension can read the same value without a cross-process
/// round-trip. The string raw value is deliberately stable — changing it
/// would silently flip every existing user back to the default.
///
/// - `.qwen35`: **The only provider.** Qwen 3.5 4B (4-bit) via MLX. The
///   chain-of-thought trace is suppressed at the chat-template layer through
///   `additionalContext: ["enable_thinking": false]` — see `Qwen35Client`
///   for the full mechanism.
///
/// The enum is preserved as a single-case enum so the Switch Model picker
/// surface still has something to bind against. A future second backend
/// just adds a case here + a branch in `build(provider:)` /
/// `currentProviderWeightsOnDisk`.
enum LLMProvider: String, Sendable, CaseIterable {
    /// Qwen 3.5 4B (4-bit) via MLX — the only rewrite provider.
    case qwen35 = "qwen35"
}

/// Owns the singleton `LLMClient` for the main app process.
///
/// We treat the factory as a process-wide registry: once a backend is built
/// it stays alive for the lifetime of the app, and the same instance is
/// reused across rewrites so model weights survive between calls. Switching
/// provider evicts the previous client so its memory can be reclaimed before
/// the new one is built.
///
/// The factory itself is `@MainActor` so settings UI and the rewrite call
/// site can read the current provider without an extra actor hop.
@available(iOS 26.0, *)
@MainActor
final class LLMClientFactory {
    static let shared = LLMClientFactory()

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "LLMClientFactory"
    )

    private var cachedClient: (any LLMClient)?
    private var cachedProvider: LLMProvider?

    private init() {}

    /// Currently-selected provider per App Group defaults.
    ///
    /// Legacy / unknown raw values (including `"phi4"` from prior builds)
    /// resolve to the only remaining provider, `.qwen35`. Phi-4 weights
    /// from prior installs are purged by a one-shot migration in
    /// `JotApp` — see `Phi4WeightsPurge` for details.
    var currentProvider: LLMProvider {
        if let raw = AppGroup.defaults.string(forKey: AppGroup.Keys.aiRewriteProvider),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        return .qwen35
    }

    /// Persist a user-initiated provider choice. Settings UI calls this
    /// when the user picks a different model in the Switch model picker.
    /// The next `client()` call will tear down the previous backend and
    /// build the new one.
    func setProvider(_ provider: LLMProvider) {
        AppGroup.defaults.set(provider.rawValue, forKey: AppGroup.Keys.aiRewriteProvider)
        log.info("Persisted provider=\(provider.rawValue, privacy: .public)")
    }

    /// Returns the `LLMClient` matching the currently-selected provider.
    /// Builds a fresh client on the first call or after a provider change.
    func client() -> any LLMClient {
        let provider = currentProvider
        if let cached = cachedClient, cachedProvider == provider {
            return cached
        }
        if let old = cachedClient {
            Task { await old.evict() }
        }
        let fresh = build(provider: provider)
        cachedClient = fresh
        cachedProvider = provider
        log.info("Built LLMClient for provider=\(provider.rawValue, privacy: .public)")
        return fresh
    }

    /// Synchronous "are weights for the current provider on disk?" probe.
    /// Reads the HF cache for the active provider — no network, no model
    /// load. Used by AI Settings and the wizard AI Offer step to suppress
    /// the "Download" CTA when the model is already on-device.
    var currentProviderWeightsOnDisk: Bool {
        switch currentProvider {
        case .qwen35: return Qwen35Client.snapshotPresentOnDisk()
        }
    }

    private func build(provider: LLMProvider) -> any LLMClient {
        switch provider {
        case .qwen35:
            // Qwen 3.5 4B (4-bit) via MLX. The only rewrite backend.
            return Qwen35Client()
        }
    }
}

// MARK: - One-shot Phi-4 weight purge

/// One-shot migration that reclaims disk for upgrading users from prior
/// builds that downloaded Phi-4 mini (~2.4 GB) into the HuggingFace cache.
/// Now that Qwen 3.5 is the sole rewrite backend, those weights are dead
/// disk. Removes the entire `models--mlx-community--Phi-4-mini-instruct-4bit/`
/// directory under the HF cache root, gated by a `UserDefaults` flag so it
/// runs at most once per install.
///
/// Best-effort. Never throws — logs and bails on any FS error.
enum Phi4WeightsPurge {
    static let migrationKey = "jot.didPurgePhi4Weights"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let log = Logger(
            subsystem: "com.vineetu.jot.mobile.Jot",
            category: "phi4-purge"
        )

        let cacheBase = hfHubCacheRoot()
        let phi4Dir = cacheBase
            .appendingPathComponent("models--mlx-community--Phi-4-mini-instruct-4bit", isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: phi4Dir.path) else {
            // Nothing on disk — still flip the flag so we don't poll
            // the filesystem on every cold launch.
            defaults.set(true, forKey: migrationKey)
            log.info("Phi-4 purge: nothing on disk at \(phi4Dir.path, privacy: .public); flag set")
            return
        }

        // Flip the gate flag BEFORE dispatching the delete so a slow
        // detached delete that overlaps a next cold launch doesn't
        // re-attempt deletion.
        defaults.set(true, forKey: migrationKey)

        Task.detached(priority: .utility) {
            let log = Logger(
                subsystem: "com.vineetu.jot.mobile.Jot",
                category: "phi4-purge"
            )
            do {
                try FileManager.default.removeItem(at: phi4Dir)
                log.notice("Phi-4 weights purged at \(phi4Dir.path, privacy: .public)")
            } catch {
                log.error("Phi-4 purge failed at \(phi4Dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolve the HF Hub cache root the same way the previous
    /// `Phi4Client.snapshotPresentOnDisk` did — honors `HF_HUB_CACHE`,
    /// then `HF_HOME/hub`, then falls back to the default
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

// MARK: - LLMProvider display metadata

@available(iOS 26.0, *)
extension LLMProvider {
    /// User-facing display name. Surfaced in Settings model strip, the Switch
    /// model picker, the AI offer wizard step, the transcript-detail
    /// attribution line, the rewrite picker sheet's subline, and the
    /// edit-prompt test sheet footer. Update here to change every surface
    /// at once.
    var displayName: String {
        switch self {
        case .qwen35: return "Qwen 3.5 4B"
        }
    }

    /// User-facing on-disk size string. Surfaced alongside `displayName` in
    /// the same screens — also used for the download CTA copy
    /// ("Download · 2.5 GB"). Qwen 3.5 4B at 4-bit is approximately 2.5 GB.
    var displaySize: String {
        switch self {
        case .qwen35: return "2.5 GB"
        }
    }
}
