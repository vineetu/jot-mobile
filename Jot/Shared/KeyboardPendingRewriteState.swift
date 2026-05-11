import Foundation

/// Snapshot of the keyboard's currently-pending rewrite request.
///
/// Written by the keyboard extension to `AppGroup.keyboardPendingRewriteState`
/// **before** opening the `jot://rewrite?session=<uuid>` URL so the
/// correlation state survives keyboard extension recycle. iOS may recycle
/// the keyboard extension during the URL bounce; without this AppGroup
/// snapshot, in-memory pending state would be lost and the keyboard would
/// be unable to match the dispatcher's result back to its captured
/// selection on the next `viewWillAppear`.
///
/// ## Lifecycle
///
/// 1. Keyboard captures the selected text + UTF-16 length, allocates a
///    fresh session UUID (== `PendingRewriteRequest.id` == URL session
///    UUID), and writes both `pendingRewriteRequest` and
///    `keyboardPendingRewriteState` to AppGroup.
/// 2. Keyboard opens `jot://rewrite?session=<uuid>` via the responder-chain
///    `UIApplication.open(_:)` workaround.
/// 3. Main-app dispatcher processes the rewrite, on completion writes
///    `rewriteResult` (or `rewriteError`), then sets
///    `rewriteResultSessionID = request.id` before clearing `rewriteJobID`.
/// 4. Keyboard's `viewWillAppear` hydrates from
///    `keyboardPendingRewriteState` if the in-memory mirror is `nil`
///    (extension recycle case), then matches the drained
///    `rewriteResultSessionID` against `sessionID`.
/// 5. On match, keyboard runs the safe-replacement gate (strict text
///    equality vs `selectionText`), inserts the rewritten text, and
///    clears `keyboardPendingRewriteState`.
///
/// ## Why `Codable`
///
/// `UserDefaults` only stores property-list types directly. JSON-encoding
/// the struct gives us a forward-compatible binary blob the keyboard can
/// decode safely across builds — if a field is added later, decoding an
/// older blob still succeeds via `Codable`'s default-init semantics.
///
/// ## Why `selectionText` is captured here, not just length
///
/// Pass-4 P3-1: the safe-replacement gate must compare the live selection
/// to the **exact captured text**, not just to its length. Same-length-
/// but-different-text is a real failure mode (user moves cursor and
/// re-selects something else of the same length); without strict text
/// equality, auto-replace would silently overwrite the wrong selection.
struct KeyboardPendingRewriteState: Codable, Sendable, Equatable {
    /// Session UUID. Equals `PendingRewriteRequest.id` and the
    /// `?session=<uuid>` query parameter on the URL bounce.
    let sessionID: UUID

    /// The selected host text captured at the moment the keyboard fired
    /// the rewrite. Used by the safe-replacement gate to verify the live
    /// selection still matches before issuing `deleteBackward()` /
    /// `insertText()`. Strict equality only — length-only fallback is
    /// unsafe (see plan §5 Step 4e).
    let selectionText: String

    /// UTF-16 code-unit length of `selectionText`. Diagnostic field
    /// logged for telemetry when the gate falls back to pasteboard;
    /// **NOT** used as a fallback gate.
    let selectionLength: Int

    /// Wall-clock timestamp when the keyboard wrote this snapshot.
    /// Used by the keyboard's 60 s live-timeout banner so the elapsed
    /// time persists across extension recycle.
    let startedAt: Date
}
