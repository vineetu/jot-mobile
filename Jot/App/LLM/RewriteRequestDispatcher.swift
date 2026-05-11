import Foundation
import UIKit
import os.log

/// Drives a rewrite request handed off from the keyboard via
/// `jot://rewrite?session=<uuid>` URL bounce.
///
/// ## Why this exists (not just `RewriteWithPromptIntent.perform()`)
///
/// The intent was the original surface, but `intent.perform()` called from
/// inside a keyboard extension never gets promoted into the main-app
/// process — `LiveActivityIntent` promotion only fires from
/// `Button(intent:)` inside Live Activity widgets. The keyboard now
/// stashes a `PendingRewriteRequest` in the App Group and opens
/// `jot://rewrite?session=<uuid>`; the main app's `onOpenURL` handler
/// calls `dispatch(sessionID:)` here. Behavior matches the previous
/// in-process intent body.
///
/// ## Lifecycle
///
/// 1. Reads + deletes `AppGroup.pendingRewriteRequest` (verifies session
///    match against the URL parameter).
/// 2. Stamps a fresh `rewriteJobID`, clears prior result/error/cancel slots
///    (per-job reset).
/// 3. Resolves the prompt via `SavedPromptStore`. Bad input → terminal
///    error write + completion notification.
/// 4. Dispatches `LLMClientFactory.shared.client().rewrite(...)`.
/// 5. On success: writes `rewriteResult`, clears `rewriteJobID`, posts
///    the rewrite-completion Darwin notification. Pasteboard handling is
///    the keyboard's responsibility (only on auto-replace fallback).
/// 6. On `CancellationError`: writes `rewriteError = cancelledSentinel`,
///    posts notification.
/// 7. On other error: writes `rewriteError = error.localizedDescription`,
///    posts notification.
@available(iOS 26.0, *)
@MainActor
enum RewriteRequestDispatcher {

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "RewriteRequestDispatcher"
    )

    /// Dispatches the pending rewrite request whose session ID matches
    /// `sessionID` (the value parsed off the URL's `?session=` parameter).
    /// Returns `true` if a request was dispatched (regardless of terminal
    /// outcome), `false` if no matching pending payload was found.
    @discardableResult
    static func dispatch(sessionID: UUID) -> Bool {
        guard let request = AppGroup.pendingRewriteRequest else {
            log.notice("rewrite URL bounce sessionID=\(sessionID, privacy: .public) — no pending request stash; ignoring.")
            return false
        }

        guard request.id == sessionID else {
            log.error(
                "rewrite URL bounce session mismatch — url=\(sessionID, privacy: .public) stash=\(request.id, privacy: .public). Ignoring."
            )
            return false
        }

        // Clear the stash now — the request is being consumed regardless of
        // whether the LLM call succeeds or fails. Leaving it would let a
        // second URL bounce double-fire the same request.
        AppGroup.pendingRewriteRequest = nil

        // Per-job reset (mirrors `RewriteWithPromptIntent.perform()`'s
        // pre-dispatch slot hygiene). `rewriteCancelRequested` in particular
        // must drop to `false` so a stale `true` from a previous user-cancel
        // doesn't trip the polling loop on the new job's first chunk.
        let jobID = UUID()
        AppGroup.rewriteJobID = jobID
        AppGroup.rewriteResult = nil
        AppGroup.rewriteError = nil
        AppGroup.rewriteCancelRequested = false
        AppGroup.rewriteSelectionLength = request.selectionLength

        log.info(
            "rewrite dispatch sessionID=\(sessionID, privacy: .public) jobID=\(jobID, privacy: .public) promptID=\(request.promptID, privacy: .public) selectionUTF16=\(request.selectionLength, privacy: .public)"
        )

        Task { @MainActor in
            await runRewrite(jobID: jobID, request: request)
        }
        return true
    }

    private static func runRewrite(jobID: UUID, request: PendingRewriteRequest) async {
        // Resolve prompt via App Group store. Bad-input cases (non-UUID
        // string, prompt deleted) both fall through to the same
        // "Prompt not found" terminal state.
        guard let uuid = UUID(uuidString: request.promptID),
              let prompt = SavedPromptStore.all().first(where: { $0.id == uuid })
        else {
            writeError("Prompt not found", forJobID: jobID, sessionID: request.id)
            return
        }

        do {
            let client = LLMClientFactory.shared.client()
            let result = try await client.rewrite(
                text: request.selection,
                systemPrompt: prompt.systemPrompt
            )

            // Job-ID guard: a second rewrite may have started while this
            // one was in flight. Only write the terminal slots if we
            // still own the job ID.
            guard AppGroup.rewriteJobID == jobID else {
                log.notice("rewrite jobID=\(jobID, privacy: .public) finished but slot was overwritten; dropping result.")
                return
            }

            // Order matters (plan §5 Step 4b — pass-4 P3-3):
            //   1. Write terminal value (rewriteResult / rewriteError)
            //   2. Write rewriteResultSessionID = request.id (the URL
            //      session UUID, NOT the dispatcher's internal jobID)
            //   3. Clear rewriteJobID
            //   4. Post the live notification
            // The keyboard reads in the reverse order on the drain path,
            // so the resultSessionID must land BEFORE jobID is cleared
            // and BEFORE the notification fires — otherwise the keyboard
            // would observe a "completed" notification with nothing to
            // correlate against and discard the result.
            AppGroup.rewriteResult = result
            AppGroup.rewriteError = nil
            AppGroup.rewriteResultSessionID = request.id
            AppGroup.rewriteJobID = nil

            // Pasteboard handling is the keyboard's responsibility — it
            // writes to the pasteboard ONLY when the strict-equality
            // auto-replace path fails (see
            // `JotKeyboardViewController.applyDrainedRewriteResult`).
            // Writing here unconditionally would clobber the user's
            // clipboard on every successful rewrite, even when
            // auto-replace would otherwise complete cleanly.

            RewriteNotifications.postCompleted()
            log.info(
                "rewrite SUCCESS jobID=\(jobID, privacy: .public) sessionID=\(request.id, privacy: .public) outputChars=\(result.count)"
            )
        } catch is CancellationError {
            guard AppGroup.rewriteJobID == jobID else { return }
            writeError(RewriteNotifications.cancelledSentinel, forJobID: jobID, sessionID: request.id)
            log.info("rewrite CANCELLED jobID=\(jobID, privacy: .public) sessionID=\(request.id, privacy: .public)")
        } catch {
            guard AppGroup.rewriteJobID == jobID else { return }
            writeError(error.localizedDescription, forJobID: jobID, sessionID: request.id)
            log.error(
                "rewrite FAILED jobID=\(jobID, privacy: .public) sessionID=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Terminal-error write path. Order mirrors the success path:
    ///   1. Write the error string
    ///   2. Clear the result slot
    ///   3. Write `rewriteResultSessionID = sessionID` (URL session UUID,
    ///      from `PendingRewriteRequest.id`)
    ///   4. Clear `rewriteJobID`
    ///   5. Post completion notification
    /// The session-ID slot is the keyboard's correlation anchor; it must
    /// land before the job-ID clear and the live notification fire.
    private static func writeError(_ msg: String, forJobID jobID: UUID, sessionID: UUID) {
        guard AppGroup.rewriteJobID == jobID else { return }
        AppGroup.rewriteError = msg
        AppGroup.rewriteResult = nil
        AppGroup.rewriteResultSessionID = sessionID
        AppGroup.rewriteJobID = nil
        RewriteNotifications.postCompleted()
    }
}
