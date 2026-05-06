import Foundation

/// Cancel-polling helper for the Phi-4 backend's `rewrite(...)` chunk loop.
///
/// ## Integration boundary
///
/// `Phi4Client` itself is owned by Stage 1+2 of the AI-rewrite work — that
/// implementer is concurrently building the MLX-swift wiring, the
/// constrained-decoding sampler hookup, and the chunk loop that yields
/// decoded tokens until the schema's terminal state. Stage 4 owns the cancel
/// signal but cannot directly modify the chunk loop without conflicting
/// with that work. The integration step (run by the orchestrator after both
/// stages land) injects the polling helper here into the loop.
///
/// ## Why this file ships as a free namespace, not an extension
///
/// At Stage 4 commit time, `Phi4Client` is not yet a defined symbol in the
/// codebase — Stage 1+2 lands it concurrently. Declaring
/// `extension Phi4Client` here would break the build for both stages until
/// the integration step. Instead, the polling helper lives on a
/// stand-alone `Phi4CancelPolling` namespace; the integration step folds
/// it onto `Phi4Client` (either as an extension method or by inlining the
/// `Task.detached` body) once the type exists.
///
/// ## How the polling task works
///
/// `Phi4CancelPolling.observe(parent:)` returns a detached
/// `Task<Void, Never>` that loops on a 50 ms cadence reading
/// `AppGroup.rewriteCancelRequested`. When the flag flips to `true`, it
/// calls `parent.cancel()` on the task handle the chunk loop is running
/// on, which propagates a `CancellationError` out of the next
/// `try Task.checkCancellation()` call inside the loop. The intent's
/// `do/catch` (see `RewriteWithPromptIntent.perform()`) then converts
/// that into the `"Cancelled"` terminal write.
///
/// 50 ms is a deliberate compromise: tight enough that a user's tap on
/// the keyboard's cancel UI feels responsive (next chunk boundary is at
/// most one polling tick away), loose enough that the polling task
/// itself doesn't measurably contend with the inference loop on a tight
/// generation budget.
///
/// ## TODO INTEGRATION
///
/// The orchestrator's integration step must, inside
/// `Phi4Client.rewrite(text:systemPrompt:)`:
///
/// ```swift
/// let parent = Task<Void, Never> { [weak self] in /* placeholder */ }
/// let token = Phi4CancelPolling.observe(parent: parent)
/// defer {
///     token.cancel()
///     parent.cancel()
/// }
/// // ... existing chunk loop, with `try Task.checkCancellation()`
/// //     between decoded chunks ...
/// ```
///
/// The exact wiring depends on how Stage 1+2's chunk loop is shaped. The
/// two non-negotiable invariants are:
///   1. The polling task is torn down on every exit path (success,
///      error, cancel) — leaking it would have it polling the App Group
///      until process death.
///   2. The chunk loop calls `try Task.checkCancellation()` between
///      decoded chunks so the cancel flag actually surfaces as a
///      `CancellationError`.
///
/// All wiring is intentionally *not* done in this file — that requires
/// editing `Phi4Client.swift`, which Stage 1+2 owns.

#if JOT_APP_HOST

/// Stand-alone namespace for the cancel-polling helper. The integration
/// step migrates these into `extension Phi4Client` (or inlines the body)
/// once `Phi4Client` is committed by Stage 1+2.
enum Phi4CancelPolling {

    /// Polling cadence in nanoseconds. 50 ms — see file-doc rationale.
    static let pollIntervalNanos: UInt64 = 50_000_000

    /// Spawn a detached task that polls `AppGroup.rewriteCancelRequested`
    /// on a 50 ms cadence. When the flag flips to `true`, cancels the
    /// supplied `parent` task so the chunk loop's
    /// `try Task.checkCancellation()` call throws `CancellationError`.
    ///
    /// Callers are responsible for cancelling the returned polling
    /// token on every exit path — without that the polling task would
    /// leak past the rewrite's lifetime.
    ///
    /// `@discardableResult` because some integration shapes (e.g.
    /// `withTaskCancellationHandler` capturing the token in the
    /// onCancel closure) don't need a named return.
    ///
    /// Generic over the parent's `Success` / `Failure` so the integration
    /// can pass a `Task<String, Error>` carrying the rewrite result without
    /// an extra wrapper indirection. `Task.cancel()` is non-isolated and
    /// available on every `Task` regardless of generic params.
    @discardableResult
    static func observe<Success: Sendable, Failure: Error>(
        parent: Task<Success, Failure>
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if AppGroup.rewriteCancelRequested {
                    // Reset the flag so a follow-up rewrite doesn't
                    // immediately trip on a stale `true`. The intent's
                    // job-start reset is the primary clear; this is
                    // belt-and-suspenders for the one-tick window
                    // between the parent task receiving the cancel and
                    // the intent's catch clause running.
                    AppGroup.rewriteCancelRequested = false

                    // Cancel the parent. Inside the chunk loop, the
                    // next `try Task.checkCancellation()` call throws
                    // `CancellationError`, which propagates up through
                    // `Phi4Client.rewrite` and lands in the intent's
                    // `catch is CancellationError` branch.
                    parent.cancel()
                    break
                }

                try? await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }
    }
}

#endif
