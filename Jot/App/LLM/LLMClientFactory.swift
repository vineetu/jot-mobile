import Foundation
import os.log

/// User-selectable LLM backend for the AI rewrite path.
///
/// Persisted in App Group defaults under `AppGroup.Keys.aiRewriteProvider` so
/// the keyboard extension (later stage) can read the same value without a
/// cross-process round-trip. String raw values are deliberately stable —
/// changing them would silently flip every existing user back to the default.
enum LLMProvider: String, Sendable, CaseIterable {
    case phi4 = "phi4"
    case appleIntelligence = "appleIntelligence"
}

/// Owns the singleton `LLMClient` for the main app process.
///
/// We treat the factory as a process-wide registry: once a backend is built
/// it stays alive for the lifetime of the app, and the same instance is
/// reused across rewrites so model weights survive between calls. Switching
/// the provider in Settings tears down the old client (calling `evict()` to
/// free MLX memory) and lazily builds the new one on first use.
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

    /// Currently-selected provider per App Group defaults. Falls back to
    /// `.phi4` (the product default) when the key is missing or invalid.
    var currentProvider: LLMProvider {
        if let raw = AppGroup.defaults.string(forKey: AppGroup.Keys.aiRewriteProvider),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        return .phi4
    }

    /// Returns the `LLMClient` matching the currently-selected provider.
    /// Builds a fresh client on the first call or after a provider change.
    func client() -> any LLMClient {
        let provider = currentProvider
        if let cached = cachedClient, cachedProvider == provider {
            return cached
        }
        // Provider changed (or first call). Evict the old client off the
        // MainActor since `evict()` is async; we deliberately don't await it
        // here — the new caller wants the new client immediately. The old
        // client's evict() runs in a detached task and frees MLX memory in
        // the background.
        if let old = cachedClient {
            Task { await old.evict() }
        }
        let fresh = build(provider: provider)
        cachedClient = fresh
        cachedProvider = provider
        log.info("Built LLMClient for provider=\(provider.rawValue, privacy: .public)")
        return fresh
    }

    private func build(provider: LLMProvider) -> any LLMClient {
        switch provider {
        case .phi4:
            return Phi4Client()
        case .appleIntelligence:
            return AppleIntelligenceClient()
        }
    }
}
