import Foundation

/// Cross-process payload that hands a rewrite request from the keyboard
/// extension to the main app via `jot://rewrite?session=<uuid>`.
///
/// Mirrors the `PendingPasteSession` pattern: the keyboard generates a fresh
/// `id`, JSON-encodes this struct into App Group `UserDefaults` under
/// `AppGroup.Keys.pendingRewriteRequest`, then opens the URL. The main app's
/// `onOpenURL` handler reads + decodes the payload, verifies the session ID
/// matches the URL parameter, and dispatches the rewrite through
/// `LLMClientFactory.shared.client()`.
///
/// We replaced the previous `RewriteWithPromptIntent.perform()` direct call
/// with this URL-scheme handoff because in-process `intent.perform()` calls
/// from a keyboard extension never get promoted into the main-app process —
/// the keyboard compiles the `#else` stub body, so the real
/// `#if JOT_APP_HOST` body never runs. `LiveActivityIntent` promotion only
/// fires from `Button(intent:)` inside Live Activity widgets. URL-scheme
/// routing is the same pattern the dictation flow uses
/// (`jot://dictate?session=...`).
struct PendingRewriteRequest: Codable, Sendable, Equatable {
    /// Session UUID that round-trips through the `?session=` URL query param.
    /// The main app refuses to dispatch a request whose stored session ID
    /// doesn't match the URL parameter — guards against stale stash payloads.
    let id: UUID

    /// String-encoded UUID of the saved prompt to apply. The main app looks
    /// the prompt up via `SavedPromptStore.all()`. Bad-input cases (non-UUID
    /// string, prompt deleted) surface the same "Prompt not found" error as
    /// the original intent path.
    let promptID: String

    /// Raw selected text from the host app at intent-fire time. Not trimmed
    /// or pre-cleaned — the LLM sees exactly what the user selected.
    let selection: String

    /// UTF-16 code-unit length of the host's selection captured at fire
    /// time. The keyboard's auto-paste completion handler uses this to size
    /// its `proxy.deleteBackward()` loop before re-inserting the result.
    /// Stored alongside the request so the main app can write it back into
    /// `AppGroup.rewriteSelectionLength` (the slot the keyboard's existing
    /// completion path reads).
    let selectionLength: Int

    /// Wall-clock timestamp at fire time. Currently unused by the dispatch
    /// path but useful for diagnostic logs and future stale-payload cleanup.
    let createdAt: Date
}
