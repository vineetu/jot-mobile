import Foundation

/// Cancel-polling helper for any `LLMClient` backend's `rewrite(...)` chunk
/// loop.
///
/// ## Why a shared helper
///
/// `Phi4Client` (MLX) needs cancel polling that reads
/// `AppGroup.rewriteCancelRequested` on a 50 ms cadence and propagates
/// a cancel into the inference task on flag flip. The polling helper
/// is kept backend-agnostic (taking either a parent `Task` or a
/// `requestStop` closure) so that any future provider can reuse the
/// same cadence and flag-reset semantics without re-implementing the
/// loop.
///
/// ## Polling task lifecycle
///
/// `RewriteCancelPolling.observe(parent:)` returns a detached
/// `Task<Void, Never>` that loops on a 50 ms cadence reading
/// `AppGroup.rewriteCancelRequested`. When the flag flips to `true`, it
/// calls `parent.cancel()` — the chunk loop's `try Task.checkCancellation()`
/// (or equivalent) then throws `CancellationError`, which the intent's
/// `catch is CancellationError` branch converts into the `"Cancelled"`
/// terminal write.
///
/// 50 ms is a deliberate compromise: tight enough that a user's tap on
/// the keyboard's cancel UI feels responsive (next chunk boundary is at
/// most one polling tick away), loose enough that the polling task
/// itself doesn't measurably contend with the inference loop on a tight
/// generation budget.
///
/// ## Caller responsibilities
///
/// 1. Tear down the returned polling token on every exit path (success,
///    error, cancel) — leaking it would have it polling the App Group
///    until process death.
/// 2. The chunk loop must call `try Task.checkCancellation()` (or check
///    `Task.isCancelled` and throw) between decoded units so the cancel
///    flag actually surfaces as a `CancellationError`. For backends
///    whose inference primitive doesn't honor Swift Concurrency cancel
///    natively, the closure-based `observe(requestStop:)` variant lets
///    the backend signal its own per-token-loop stop flag instead.
///
#if JOT_APP_HOST

/// Stand-alone namespace for the cancel-polling helper. Backend-agnostic:
/// works for any `LLMClient` whose `rewrite(...)` body wraps the
/// inference loop in an inner `Task<Success, Error>` and calls
/// `try Task.checkCancellation()` between decoded chunks.
enum RewriteCancelPolling {

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
    /// Generic over the parent's `Success` / `Failure` so callers can
    /// pass a `Task<String, Error>` carrying the rewrite result without
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
                    // the backend's `rewrite(...)` and lands in the
                    // intent's `catch is CancellationError` branch.
                    parent.cancel()
                    break
                }

                try? await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }
    }

    /// Closure-based variant for backends whose "request stop" hook
    /// isn't a simple `Task.cancel()`. The supplied `requestStop`
    /// closure runs on the polling task when the cancel flag flips —
    /// the backend implements whatever it needs (flip a `running`
    /// flag the per-token loop checks, signal a continuation, etc.)
    /// inside that closure.
    ///
    /// The polling task still resets `rewriteCancelRequested = false`
    /// after invoking the hook so a stale flag doesn't trip the next
    /// rewrite.
    @discardableResult
    static func observe(
        requestStop: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if AppGroup.rewriteCancelRequested {
                    AppGroup.rewriteCancelRequested = false
                    requestStop()
                    break
                }
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }
    }
}

#endif
