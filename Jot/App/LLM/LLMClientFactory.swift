import Foundation
import os.log

/// User-selectable LLM backend for the AI rewrite path.
///
/// Persisted in App Group defaults under `AppGroup.Keys.aiRewriteProvider` so
/// the keyboard extension can read the same value without a cross-process
/// round-trip. The string raw value is deliberately stable — changing it
/// would silently flip every existing user back to the default.
///
/// - `.qwen35`: **Default** provider. Qwen 3.5 4B (4-bit) via MLX. The
///   chain-of-thought trace is suppressed at the chat-template layer through
///   `additionalContext: ["enable_thinking": false]` — see `Qwen35Client`
///   for the full mechanism.
/// - `.phi4`: Alternate provider. Phi-4-mini-instruct-4bit via MLX
///   (grammar-constrained JSON output). Preserved as an opt-in for users
///   who already have it downloaded.
enum LLMProvider: String, Sendable, CaseIterable {
    /// Qwen 3.5 4B (4-bit) via MLX — the **default** rewrite provider.
    case qwen35 = "qwen35"
    /// Phi-4-mini-instruct-4bit via MLX — an alternate, opt-in provider.
    case phi4 = "phi4"
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
    /// ## Default resolution + migration safety
    ///
    /// Existing TestFlight users may have downloaded Phi-4 under the previous
    /// build (when Phi-4 was the only — and therefore default — provider) but
    /// never explicitly persisted a provider key. Auto-flipping those users
    /// to Qwen on the first launch of the new build would force a fresh
    /// ~2.5 GB download for no user-initiated reason. To avoid that:
    ///
    /// - If a provider key IS persisted, honor it (user has explicitly
    ///   chosen, possibly via Settings → Switch model).
    /// - Else, if Phi-4 weights are already on-disk, default to `.phi4` so
    ///   the existing-install experience is unchanged.
    /// - Else (fresh install, no provider key, no Phi-4 weights), default to
    ///   the new product default: `.qwen35`.
    ///
    /// Legacy / unknown raw values (`"gemma"`, `"appleIntelligence"`, etc.)
    /// fall through to the same disk-probe migration so we don't punish a
    /// user with cruft from a removed experimental case.
    var currentProvider: LLMProvider {
        if let raw = AppGroup.defaults.string(forKey: AppGroup.Keys.aiRewriteProvider),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        // No persisted provider — apply migration-safety check.
        if Phi4Client.snapshotPresentOnDisk() {
            return .phi4
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

    private func build(provider: LLMProvider) -> any LLMClient {
        switch provider {
        case .qwen35:
            // Qwen 3.5 4B (4-bit) via MLX. Default since 2026-05.
            return Qwen35Client()
        case .phi4:
            // Phi-4-mini-instruct-4bit via MLX. Once built, weights stay
            // resident until the OS reclaims memory under pressure or the
            // user purges via settings.
            return Phi4Client()
        }
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
        case .phi4: return "Phi-4 mini"
        }
    }

    /// User-facing on-disk size string. Surfaced alongside `displayName` in
    /// the same screens — also used for the download CTA copy
    /// ("Download · 2.5 GB"). Qwen 3.5 4B at 4-bit is approximately 2.5 GB;
    /// Phi-4-mini-instruct-4bit is approximately 2.4 GB.
    var displaySize: String {
        switch self {
        case .qwen35: return "2.5 GB"
        case .phi4: return "2.4 GB"
        }
    }
}
