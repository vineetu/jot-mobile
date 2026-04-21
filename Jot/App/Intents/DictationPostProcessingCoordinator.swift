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
        return try await task.value
    }
}
