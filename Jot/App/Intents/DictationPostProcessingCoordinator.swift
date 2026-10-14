import Foundation
import Observation

/// Shared owner for cancelable post-recording work.
///
/// Both the in-app pill and the Live Activity drive the same singleton so a
/// cancel request always targets the in-flight LLM work regardless of where
/// the user taps.
@MainActor
@Observable
final class DictationPostProcessingCoordinator {
    enum Stage: Sendable, Equatable {
        case idle
        case processing
        case cleaning
    }

    static let shared = DictationPostProcessingCoordinator()

    /// Automatic cleanup (features.md §7.14) holds the paste for at most this
    /// long. Past it the raw transcript pastes and the cleanup keeps running;
    /// `CleanupTimedOut.pending` hands the still-running task to the caller so
    /// the result can still land on the saved note's Rewrite tab.
    static let cleanupPasteWait: Duration = .seconds(20)

    struct CleanupTimedOut: Error {
        let pending: Task<String, Error>
    }

    private(set) var stage: Stage = .idle
    private(set) var isCancellationRequested = false

    private var resolutionTask: Task<CommandResolution, Error>?
    private var cleanupTask: Task<String, Error>?

    private init() {}

    func begin() {
        resolutionTask?.cancel()
        cleanupTask?.cancel()
        resolutionTask = nil
        cleanupTask = nil
        isCancellationRequested = false
        stage = .processing
    }

    func cancel() {
        isCancellationRequested = true
        resolutionTask?.cancel()
        cleanupTask?.cancel()
        stage = .idle
    }

    func finish() {
        resolutionTask = nil
        cleanupTask = nil
        isCancellationRequested = false
        stage = .idle
    }

    func resolveUtterance(new: String, priorTranscript: String?) async throws -> CommandResolution {
        stage = .processing
        let task = Task { @MainActor in
            try await CleanupService().resolveUtterance(
                new: new,
                priorTranscript: priorTranscript
            )
        }
        resolutionTask = task
        defer { resolutionTask = nil }
        return try await task.value
    }

    func clean(transcript: String, settings: CleanupSettings) async throws -> String {
        stage = .cleaning
        let task = Task { @MainActor in
            try await DictationIntentBridge.shared.controller.cleanup(
                transcript: transcript,
                settings: settings
            )
        }
        cleanupTask = task
        defer { cleanupTask = nil }
        // Race the model against the paste-wait cap. Not a task group: a group
        // waits for every child before returning, and `await task.result` on an
        // unstructured task ignores cancellation — so the cap never fired and a
        // slow cleanup held the paste for the full model run. Whichever side
        // finishes first resumes; on timeout `task` keeps running for the
        // background attach.
        let outcome: Result<String, Error> = await withCheckedContinuation { cont in
            let gate = FirstResultGate(cont)
            Task { @MainActor in gate.resume(await task.result) }
            Task { @MainActor in
                try? await Task.sleep(for: Self.cleanupPasteWait)
                gate.resume(.failure(CleanupTimedOut(pending: task)))
            }
        }
        return try outcome.get()
    }
}

/// Resumes a continuation with the first result offered and ignores the rest.
@MainActor
private final class FirstResultGate {
    private var continuation: CheckedContinuation<Result<String, Error>, Never>?
    init(_ continuation: CheckedContinuation<Result<String, Error>, Never>) {
        self.continuation = continuation
    }
    func resume(_ result: Result<String, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
