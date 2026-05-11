import Foundation

/// Cross-process state slots that drive the `RewriteWithPromptIntent` lifecycle.
///
/// Lives in a separate file from `Jot/Shared/AppGroup.swift` because the
/// rewrite-state keys are owned by Stage 4 (the LiveActivityIntent + result
/// delivery plumbing) and must merge cleanly with the Stage 3 prompts work
/// that's editing `AppGroup.swift` concurrently. Keeping the additions in an
/// extension file means the orchestrator never has to resolve a textual merge
/// inside the base type.
///
/// ## Lifecycle
///
/// 1. Keyboard taps a saved-prompt row and fires `RewriteWithPromptIntent`.
/// 2. Main-app `perform()` allocates a fresh `rewriteJobID`, clears
///    `rewriteResult`/`rewriteError`/`rewriteCancelRequested`, then dispatches
///    `LLMClientFactory.active.rewrite(...)`.
/// 3. On completion (success, error, or cancellation) the intent writes the
///    terminal value into `rewriteResult` or `rewriteError`, clears
///    `rewriteJobID`, and posts a Darwin notification (see
///    `RewriteNotifications.rewriteCompleted`).
/// 4. The keyboard observes the notification and reads the terminal value.
///
/// ## Cancellation
///
/// The keyboard sets `rewriteCancelRequested = true` when the user dismisses
/// the rewrite UI mid-flight. The Phi-4 client's chunk loop (Stage 1+2) polls
/// this flag between decoded chunks and calls `Task.cancel()` on hit; the
/// intent then converts the resulting `CancellationError` into a
/// `rewriteError = "Cancelled"` write.
///
/// All four properties hop through `AppGroup.defaults`, which is documented as
/// thread-safe but `nonisolated(unsafe)` for Swift 6 strict concurrency in the
/// base type. Reads from the keyboard are off-MainActor; writes from the
/// intent are MainActor — matches the existing access pattern for keys like
/// `aiRewriteEnabled`.
extension AppGroup {

    /// Keys for the rewrite-state slots. Held in a nested `Keys` extension to
    /// mirror the `AppGroup.Keys` style used by the base type.
    enum RewriteKeys {
        static let rewriteJobID = "jot.rewrite.jobID"
        static let rewriteResult = "jot.rewrite.result"
        static let rewriteError = "jot.rewrite.error"
        /// Session UUID of the rewrite whose result/error currently sits in
        /// `rewriteResult` / `rewriteError`. Written by the dispatcher AFTER
        /// the result/error and BEFORE clearing `rewriteJobID` and posting
        /// the live notification, so the keyboard can verify the result it
        /// drains belongs to its pending request. Holds
        /// `PendingRewriteRequest.id` (the URL session UUID), NOT the
        /// dispatcher's internal `jobID`. See plan §5 Step 4 (P3-3).
        static let rewriteResultSessionID = "jot.rewrite.resultSessionID"
        /// JSON-encoded `KeyboardPendingRewriteState` snapshot of the
        /// keyboard's currently-pending rewrite. Written by the keyboard
        /// before URL-bouncing to the main app so correlation state
        /// survives keyboard extension recycle. Cleared by the keyboard
        /// after draining the result or final timeout. See plan §5 Step 4
        /// (P3-2).
        static let keyboardPendingRewriteState = "jot.rewrite.keyboardPending"
        static let rewriteCancelRequested = "jot.rewrite.cancelRequested"
        /// UTF-16 code-unit length of the host's selection at the moment the
        /// keyboard fired the rewrite intent. Stashed by the keyboard so the
        /// completion handler knows how many `proxy.deleteBackward()` calls
        /// to issue before re-inserting the rewritten text. Cleared when the
        /// keyboard drains the result. Stored as `Int` (not `UInt`) because
        /// `Int` is the natural type for `String.utf16.count` and round-trips
        /// cleanly through `UserDefaults` integer encoding.
        static let rewriteSelectionLength = "jot.rewrite.selectionLength"
        /// JSON-encoded `PendingRewriteRequest` stash written by the keyboard
        /// before opening `jot://rewrite?session=<uuid>`. The main app's
        /// `onOpenURL` handler reads, verifies session match, then deletes
        /// the key. See `Jot/Shared/PendingRewriteRequest.swift` for the
        /// encoded shape and rationale (URL-scheme routing replaces the
        /// broken `intent.perform()` direct call from keyboard extensions).
        static let pendingRewriteRequest = "jot.rewrite.pendingRequest"
        /// Transient status string displayed by the keyboard as a banner over
        /// the streaming preview strip when the most recent dictation fell
        /// back from rewrite to raw paste (timeout, model error, etc.).
        /// Written by the main app's pipeline branch; cleared by the keyboard
        /// once the banner has rendered. `nil` means "no banner pending."
        static let lastDictationStatusMessage = "jot.dictation.lastStatusMessage"
    }

    /// UUID of the in-flight rewrite job. Written by
    /// `RewriteWithPromptIntent.perform()` at the start of a job and cleared
    /// when the job reaches a terminal state. The intent only writes its
    /// terminal result if the slot still matches the job's local UUID at
    /// completion time — that's how we discard a stale job's tail when a new
    /// rewrite has already started.
    ///
    /// Stored as a string-encoded UUID; `nil` means no job is in flight.
    static var rewriteJobID: UUID? {
        get {
            guard let raw = defaults.string(forKey: RewriteKeys.rewriteJobID) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
        set {
            if let value = newValue {
                defaults.set(value.uuidString, forKey: RewriteKeys.rewriteJobID)
            } else {
                defaults.removeObject(forKey: RewriteKeys.rewriteJobID)
            }
        }
    }

    /// Session UUID of the rewrite whose result/error is currently in
    /// `rewriteResult` / `rewriteError`. Set by the dispatcher AFTER writing
    /// the terminal value and BEFORE clearing `rewriteJobID` so the keyboard
    /// can correlate by `PendingRewriteRequest.id` (== URL session UUID).
    /// **Holds the URL session UUID, NOT the dispatcher's internal `jobID`.**
    /// `nil` means no result is currently waiting to be drained.
    static var rewriteResultSessionID: UUID? {
        get {
            guard let raw = defaults.string(forKey: RewriteKeys.rewriteResultSessionID) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
        set {
            if let value = newValue {
                defaults.set(value.uuidString, forKey: RewriteKeys.rewriteResultSessionID)
            } else {
                defaults.removeObject(forKey: RewriteKeys.rewriteResultSessionID)
            }
        }
    }

    /// JSON-encoded snapshot of the keyboard's currently-pending rewrite.
    /// Written before the keyboard URL-bounces into the main app so the
    /// correlation state (sessionID + captured selection text) survives
    /// keyboard extension recycle. The keyboard hydrates from this slot in
    /// `viewWillAppear` if its in-memory mirror is gone, drains the result,
    /// then clears this slot. `nil` means no rewrite is pending.
    static var keyboardPendingRewriteState: KeyboardPendingRewriteState? {
        get {
            guard let data = defaults.data(forKey: RewriteKeys.keyboardPendingRewriteState) else {
                return nil
            }
            return try? JSONDecoder().decode(KeyboardPendingRewriteState.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: RewriteKeys.keyboardPendingRewriteState)
            } else {
                defaults.removeObject(forKey: RewriteKeys.keyboardPendingRewriteState)
            }
        }
    }

    /// The successfully rewritten text, written by the intent on a successful
    /// `LLMClient.rewrite(...)` return. Mutually exclusive with `rewriteError`
    /// — the intent clears one slot before writing the other.
    static var rewriteResult: String? {
        get { defaults.string(forKey: RewriteKeys.rewriteResult) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: RewriteKeys.rewriteResult)
            } else {
                defaults.removeObject(forKey: RewriteKeys.rewriteResult)
            }
        }
    }

    /// Localized error string, written by the intent on failure or
    /// cancellation. Special string `"Cancelled"` indicates a user-initiated
    /// cancel (so the keyboard can suppress the toast). Any other value is a
    /// real error and should surface to the user.
    static var rewriteError: String? {
        get { defaults.string(forKey: RewriteKeys.rewriteError) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: RewriteKeys.rewriteError)
            } else {
                defaults.removeObject(forKey: RewriteKeys.rewriteError)
            }
        }
    }

    /// Cancel flag set by the keyboard when the user dismisses the rewrite
    /// UI mid-flight. Polled by the Phi-4 chunk loop (Stage 1+2). The intent
    /// resets this to `false` at job start so a stale flag from a previous
    /// run doesn't trip the new job.
    ///
    /// Default `false` — `bool(forKey:)` collapses missing into `false`,
    /// which is exactly the desired startup semantics here.
    static var rewriteCancelRequested: Bool {
        get { defaults.bool(forKey: RewriteKeys.rewriteCancelRequested) }
        set { defaults.set(newValue, forKey: RewriteKeys.rewriteCancelRequested) }
    }

    /// UTF-16 length of the host selection captured at intent-fire time.
    /// Used by the keyboard's completion handler to size the
    /// `proxy.deleteBackward()` loop before re-inserting the result.
    /// `nil` means no length has been stashed (no in-flight job, or already
    /// drained). `UserDefaults.integer(forKey:)` returns `0` for missing,
    /// so the accessor checks `object(forKey:)` first to disambiguate.
    static var rewriteSelectionLength: Int? {
        get {
            guard defaults.object(forKey: RewriteKeys.rewriteSelectionLength) != nil else {
                return nil
            }
            return defaults.integer(forKey: RewriteKeys.rewriteSelectionLength)
        }
        set {
            if let value = newValue {
                defaults.set(value, forKey: RewriteKeys.rewriteSelectionLength)
            } else {
                defaults.removeObject(forKey: RewriteKeys.rewriteSelectionLength)
            }
        }
    }

    /// Pending rewrite request handed off from the keyboard via
    /// `jot://rewrite?session=<uuid>`. The keyboard JSON-encodes a
    /// `PendingRewriteRequest` before opening the URL; the main app reads +
    /// deletes here. Returns `nil` if the slot is empty or the payload
    /// fails to decode (shape drift across builds).
    static var pendingRewriteRequest: PendingRewriteRequest? {
        get {
            guard let data = defaults.data(forKey: RewriteKeys.pendingRewriteRequest) else {
                return nil
            }
            return try? JSONDecoder().decode(PendingRewriteRequest.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: RewriteKeys.pendingRewriteRequest)
            } else {
                defaults.removeObject(forKey: RewriteKeys.pendingRewriteRequest)
            }
        }
    }

    /// Transient banner string set by the dictation pipeline when a rewrite
    /// chain falls back to raw paste (Phi-4 timeout, error, etc.). The
    /// keyboard reads it on appearance / on `transcriptReady`, renders an
    /// auto-fading banner over the streaming-preview strip for ~3 seconds,
    /// then clears the slot. `nil` (key absent) means no banner is pending.
    ///
    /// Cancellation cases write `nil` here — the user-initiated cancel is a
    /// silent fallback to raw paste, not a status to surface.
    static var lastDictationStatusMessage: String? {
        get { defaults.string(forKey: RewriteKeys.lastDictationStatusMessage) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: RewriteKeys.lastDictationStatusMessage)
            } else {
                defaults.removeObject(forKey: RewriteKeys.lastDictationStatusMessage)
            }
        }
    }
}
