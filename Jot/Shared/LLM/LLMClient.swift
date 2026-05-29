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

    /// Free-form generation for Ask mode. Unlike `rewrite`, this is
    /// NOT grammar-constrained — the model emits prose with inline
    /// `[cite: <uuid>]` markers per the system prompt's contract. The
    /// AskController parses the markers into tappable chips.
    ///
    /// Default implementation throws — only the production Qwen client
    /// implements this; test fakes that don't override will surface a
    /// clear "not supported" error rather than silently returning
    /// rewrite output.
    func ask(systemPrompt: String, userPrompt: String) async throws -> String

    /// Streaming variant of `ask`. Yields the **cumulative** answer text as it
    /// generates (each value is the full text so far, not a delta), so the UI
    /// can render the answer token-by-token. The default implementation falls
    /// back to non-streaming `ask` (one final yield); the Qwen client overrides
    /// it with true token streaming.
    func askStreaming(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    func ask(systemPrompt: String, userPrompt: String) async throws -> String {
        throw NSError(
            domain: "com.vineetu.jot.mobile.LLMClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Ask is not supported by this LLM backend."]
        )
    }

    func askStreaming(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await ask(systemPrompt: systemPrompt, userPrompt: userPrompt)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
