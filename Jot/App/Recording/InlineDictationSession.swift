import Foundation
import Observation

// ============================================================================
// ℹ️ Ask is the SOLE user — transition complete.
// (see docs/plans/unify-keyboard-dictation.md)
// ----------------------------------------------------------------------------
// The inline-dictation registration layer (InlineDictationReceiver) and its use
// by Edit / Feedback / Wizard have been REMOVED. Those surfaces now take the
// normal keyboard stop path (record in-app, insert on stop). This type survives
// because **Ask** still drives it directly. So:
//   • Do NOT delete this type — Ask depends on it.
//   • Do NOT add new callers outside Ask.
// Note the `finalize()` vs `discard()` split below (stop()=warm-hold-preserving
// vs forceStop()=mic-release) — warm-hold is untouched.
// ============================================================================

/// Reusable lifecycle for **inline** (in-field) dictation — the pattern Ask Jot
/// pioneered. Ask is now its sole user; the implementation captures the four
/// fragile invariants once (ux-overhaul-round2.md §9 R4):
///
///   1. `await` the in-flight `start()` before stop/discard — cancelling it
///      mid-bring-up races the engine and leaks a live recording.
///   2. call `markPipelineFinished()` by hand after `stop()` — inline dictation
///      bypasses RecordingService's normal post-stop pipeline, so the
///      pipeline-in-flight latch is never released otherwise and the next
///      dictate throws "a recording is already in progress".
///   3. clear ownership on EVERY exit incl. the error path — else the home view
///      never re-adopts normal recording behaviour.
///   4. use `forceStop()` (not `cancel()`) on discard — so the mic is fully
///      released and doesn't linger in warm-hold after the surface is dismissed.
///
/// Two terminals, both reusable across surfaces:
///   - ``finalize()`` → stop, transcribe, return the text for the caller to
///     insert at the cursor. (Explicit Stop, or a "save my words" exit.)
///   - ``discard()`` → forceStop, drop the audio, no text. (Any dismiss/abandon:
///     Ask sheet-close, wizard dismiss, Edit back-out without stopping.)
///
/// Inline dictation **never** saves a `Transcript` (it pastes into a field) and
/// does **not** count toward `DictationStats` — both by design (decision #3, R7).
/// The live partial-text binding (insert-at-cursor) is the caller's job; this
/// type owns only the start→stop→transcribe lifecycle and the ownership flag.
@MainActor
@Observable
final class InlineDictationSession {
    /// True between `start()` and a terminal. Drives the caller's mic UI.
    private(set) var isDictating = false

    private let recordingService: RecordingService
    private let transcribe: (_ samples: [Float]) async throws -> String

    /// The in-flight `start()` task, awaited before any terminal (invariant 1).
    private var task: Task<Void, Never>?

    init(
        recordingService: RecordingService = .shared,
        transcribe: @escaping (_ samples: [Float]) async throws -> String
    ) {
        self.recordingService = recordingService
        self.transcribe = transcribe
    }

    /// Begin dictation. No-op if a recording is already in progress (the inline
    /// mic should be disabled while `recordingService.isPipelineInFlight` to
    /// avoid a silent no-op during a prior dictation's tail — caller's job, R6).
    func start() {
        guard !recordingService.isRecording, !isDictating else { return }
        isDictating = true
        // Claim ownership BEFORE start() so the home view's hero-adoption guards
        // never snatch this recording into a full-screen hero.
        recordingService.ownsActiveRecording = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recordingService.start()
            } catch {
                self.isDictating = false
                self.recordingService.ownsActiveRecording = false
            }
        }
    }

    /// Stop, transcribe, and return the trimmed text for insertion — or `nil`
    /// if nothing was captured / transcription failed / the result was empty.
    @discardableResult
    func finalize() async -> String? {
        guard isDictating else { return nil }
        isDictating = false
        let pending = task
        task = nil
        _ = await pending?.result // invariant 1
        do {
            let samples = try await recordingService.stop()
            recordingService.markPipelineFinished()  // invariant 2
            recordingService.ownsActiveRecording = false // invariant 3
            // `stop()` published `.transcribing`, but inline dictation never
            // runs the cross-process pipeline that would advance the phase to a
            // terminal — `markPipelineFinished()` only clears the in-flight
            // latch, it does NOT publish a phase. On the keyboard-in-Jot path
            // (R5) the keyboard is the active surface observing this projection,
            // so without a terminal write its mic CTA stays stuck in the
            // transcribing/in-flight state until the 30s heartbeat-stale path
            // synthesizes `.failed`. Publish `.idle` so the CTA resets promptly.
            // (Inline saves no transcript and has no pending-paste session the
            // keyboard matches against, so the terminal write is side-effect-free
            // beyond resetting the phase.)
            recordingService.publishPipelinePhase(.idle)
            let text = try await transcribe(samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            // stop() failed (its own catch already released the latch) or
            // transcription threw — release defensively so the recorder is never
            // wedged for the next dictation.
            recordingService.markPipelineFinished()
            recordingService.ownsActiveRecording = false
            recordingService.publishPipelinePhase(.idle)
            return nil
        }
    }

    /// Discard the recording without transcribing — the dismiss/abandon path.
    /// `forceStop()` drops the audio and fully releases the mic (no warm-hold
    /// re-entry); it never calls `stop()`, so no pipeline latch is set.
    func discard() {
        let pending = task
        task = nil
        guard isDictating else {
            // Nothing live, but ensure ownership can't be left stuck.
            recordingService.ownsActiveRecording = false
            return
        }
        isDictating = false
        Task { [weak self] in
            guard let self else { return }
            _ = await pending?.result // invariant 1
            self.recordingService.forceStop() // invariant 4
            self.recordingService.ownsActiveRecording = false
        }
    }
}
