import Foundation
import os.log

/// User-selectable LLM backend for the AI rewrite path.
///
/// Persisted in App Group defaults under `AppGroup.Keys.aiRewriteProvider` so
/// the keyboard extension can read the same value without a cross-process
/// round-trip. The string raw value is deliberately stable — changing it
/// would silently flip every existing user back to the default.
///
/// Currently a single case (`.phi4`). The structure is preserved so future
/// provider work can slot back in without inverting the abstraction.
enum LLMProvider: String, Sendable, CaseIterable {
    /// Phi-4-mini-instruct-4bit via MLX (grammar-constrained JSON output) —
    /// sole rewrite provider. Runs in the main app only; the keyboard
    /// extension URL-bounces to the main app for rewrite calls.
    case phi4 = "phi4"
}

/// Owns the singleton `LLMClient` for the main app process.
///
/// We treat the factory as a process-wide registry: once a backend is built
/// it stays alive for the lifetime of the app, and the same instance is
/// reused across rewrites so model weights survive between calls. With a
/// single provider the cache is effectively a one-shot — but the structure
/// is preserved so future provider work can slot back in.
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

    /// Currently-selected provider per App Group defaults. With only `.phi4`
    /// remaining as a valid case, any non-matching legacy value (`"qwen"`,
    /// `"gemma"`, `"appleIntelligence"`, etc.) falls back to `.phi4`.
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
            // Phi-4-mini-instruct-4bit via MLX. Once built, weights stay
            // resident until the OS reclaims memory under pressure or the
            // user purges via settings.
            return Phi4Client()
        }
    }
}
