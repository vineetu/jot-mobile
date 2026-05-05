import Foundation
import os.log

#if JOT_APP_HOST

/// Phase-projection-aware dispatch helper for samples that were drained by
/// `RecordingService.internalStop` after an audio-session interruption tore the
/// engine down before the user could call `stopAndTranscribe`.
///
/// Per `tmp/research-warm-resume-design.md` §6.1 (Cut A bug-fix bundle): the
/// pre-existing `internalStop` flipped `isRecording = false` and "retained
/// samples for drain", but the keyboard / intent surfaces had already given up
/// on the recording by the time the user could route a `stop()` to them, so
/// the samples were effectively dropped. This helper auto-drains and runs the
/// post-recording tail (transcribe → publish → ledger) so EVERY entry path
/// recovers from a mid-recording interrupt.
///
/// ## Why this lives in `Shared/` (not in `App/Intents/`)
///
/// The team-lead brief partitioned `App/Intents/DictationPipeline.swift` to
/// other Wave 2 teammates (auto-paste-v7, warm-resume-cutC). This helper has
/// to call `DictationPipeline.completeEndOfRecording` and `DictationController`
/// methods, but it can sit in `Shared/` because both of those types are
/// reachable from the App target. Putting the helper in `Shared/` avoids
/// touching `DictationPipeline.swift` itself, keeping the Wave 2 file
/// partition intact.
///
/// ## Flag ownership contract
///
/// This helper OWNS `RecordingService.shared.isPipelineInFlight` for the
/// dispatch-helper-driven flow (per §6.1.5 #3 of the design doc). The flag is
/// SET on entry to `publishAfterInterruption` BEFORE any await, and is
/// CLEARED on every exit path:
///
///   - Short-capture (<1s) early-return: helper clears explicitly.
///   - `consumePreDrainedSamples` throws (transcription failure): helper
///     clears explicitly.
///   - `completeEndOfRecording` runs: its own defer (in `DictationPipeline.swift`)
///     calls `recording.markPipelineFinished()`, so the helper does NOT
///     double-clear on the pipeline-success or pipeline-throw path.
///
/// `DictationControllerImpl.consumePreDrainedSamples` is documented as
/// NOT-touching `isPipelineInFlight` precisely because of this ownership.
@MainActor
enum RecordingPipelineDispatch {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "interrupt-publish"
    )

    /// Minimum samples required to attempt transcription. Mirrors the
    /// `TranscriptionService.guardAudioLength` floor (1 second at 16 kHz)
    /// — anything shorter would just throw `.audioTooShort` deeper in the
    /// pipeline, and we'd rather discard cleanly with a log than surface a
    /// transcription failure to the user for a recording that was dominated
    /// by the interruption tone itself.
    private static let minSamples: Int = Int(RecordingService.sampleRate)

    /// Drain a partial recording captured by `RecordingService.internalStop`
    /// and route it through the standard end-of-recording pipeline. Called
    /// from a fire-and-forget `Task` spawned by `internalStop` AFTER it has
    /// torn down the engine and audio session.
    ///
    /// Safe to fire-and-forget after `internalStop` returns: `TranscriptionService`
    /// runs inference on a `[Float]` in memory and does NOT re-grab
    /// `AVAudioSession`, so the dispatched Task cannot race iOS's
    /// interruption-handshake teardown. (Verified by grep across
    /// `App/Transcription/` — 0 `AVAudioSession` references at the time of
    /// writing.)
    ///
    /// - Parameters:
    ///   - samples: The PCM 16 kHz / mono / Float32 samples drained from the
    ///     `CaptureContext` BEFORE engine teardown. Pass-by-value Swift array;
    ///     no further coordination with `RecordingService` needed.
    ///   - sessionID: Snapshot of `RecordingService.currentSessionID` taken in
    ///     `internalStop` BEFORE state mutation. May be `nil` if the recording
    ///     was started by a non-keyboard surface that didn't `adoptSession()`.
    ///     Threaded through to `DictationPipeline.completeEndOfRecording` so
    ///     the keyboard's `PendingPasteSession.id` matching still works on
    ///     the published `FreshDictation`.
    ///   - startedAt: Snapshot of `RecordingService.currentRecordingStartedAt`
    ///     taken in `internalStop`. Used by the pipeline to compute persisted
    ///     duration via `stoppedAt - startedAt`.
    static func publishAfterInterruption(
        samples: [Float],
        sessionID: UUID?,
        startedAt: Date
    ) async {
        let recording = RecordingService.shared
        let controller = DictationIntentBridge.shared.controller

        // Take ownership of the pipeline-in-flight flag for this whole flow.
        // Set BEFORE any await so a concurrent `start()` arriving on MainActor
        // (e.g., user taps mic in keyboard between interrupt-end and
        // transcription-completion) sees the flag set and bails with
        // `RecordingError.alreadyRunning`. Cleared on every exit below.
        recording.markPipelineInFlight()

        // Short-capture discard. Floor matches `TranscriptionService.guardAudioLength`
        // — a sub-second buffer would throw `.audioTooShort` if we tried to
        // transcribe it; discard cleanly with a log instead of surfacing that
        // failure to the keyboard's pending-paste flow.
        guard samples.count >= minSamples else {
            logger.info(
                "Partial publish skipped — \(samples.count, privacy: .public) samples (<1s)"
            )
            controller.abortToIdle()
            recording.markPipelineFinished()
            return
        }

        let result: DictationStopResult
        do {
            result = try await controller.consumePreDrainedSamples(samples)
        } catch {
            // Transcription failure. consumePreDrainedSamples's own defer has
            // already cycled currentPhase back to .idle, but we still own the
            // pipeline-in-flight flag because completeEndOfRecording never
            // ran (and therefore its defer didn't clear it).
            logger.error(
                "Partial publish transcription failed: \(error.localizedDescription, privacy: .public)"
            )
            recording.markPipelineFinished()
            return
        }

        do {
            try await DictationPipeline.completeEndOfRecording(
                transcript: result.transcript,
                sessionID: sessionID,
                startedAt: startedAt,
                stoppedAt: result.stoppedAt,
                controller: controller
            )
        } catch {
            // Pipeline-throw path. completeEndOfRecording's defer ALREADY
            // calls recording.markPipelineFinished() (DictationPipeline.swift
            // tail defer), so we MUST NOT double-clear here. Log only.
            logger.error(
                "Partial publish pipeline failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

#endif
