import Foundation

/// Lifecycle status of an `LLMClient` backend.
///
/// - `notReady`: backend has not been initialized; no weights on disk and not
///   loaded into memory. (Used by the Qwen 3.5 backend before first download.)
/// - `downloading(fraction:)`: weights are being fetched from a network source
///   (Hugging Face hub).
/// - `loading`: weights exist locally and are being mapped into memory.
/// - `ready`: backend is loaded and can accept `rewrite(...)` calls.
/// - `evicted`: weights are on disk but the in-memory model has been released
///   to free RAM. A subsequent `warm()` will reload it.
/// - `error(String)`: a fatal error happened on a previous load/inference.
enum LLMClientStatus: Sendable, Equatable {
    case notReady
    case downloading(fraction: Double)
    case loading
    case ready
    case evicted
    case error(String)
}

/// Backend-agnostic contract for the on-device rewrite path.
///
/// Currently the sole conformer is the Qwen 3.5 4B MLX backend. The
/// protocol is kept in place so the settings UI adapter, the
/// dispatcher, and tests can substitute fakes without coupling to the
/// concrete client.
///
/// `AnyObject + Sendable`: clients hold non-`Sendable` model state (MLX
/// containers) behind their own actor or `@MainActor` discipline.
/// Reference identity matters because the singleton wrapper holds `self`
/// internally for lifecycle hooks.
protocol LLMClient: AnyObject, Sendable {
    /// Current lifecycle status. May change asynchronously as background
    /// downloads or evictions complete.
    var status: LLMClientStatus { get async }

    /// Ensure the backend is loaded into memory and ready for `rewrite(...)`.
    /// Idempotent: calling on a `.ready` client is a no-op.
    func warm() async throws

    /// Release in-memory weights. The backend transitions to `.evicted` (if
    /// weights are still on disk) or `.notReady`.
    func evict() async

    /// Run a constrained-decoding rewrite. Returns the rewritten text only,
    /// with no preamble, quoting, or explanation — enforced by the
    /// `Rewrite` JSON schema via grammar-constrained decoding.
    func rewrite(text: String, systemPrompt: String) async throws -> String
}
