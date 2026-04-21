import Foundation

/// End-of-recording tail shared across the three dictation *entry-point*
/// intents: `RecordAndTranscribeIntent`, `DictateIntent`, and
/// `StopDictationIntent`.
///
/// ## Why this helper exists (and why it didn't, until now)
///
/// The earlier v6 pipeline did one thing — cleanup (if enabled) → publish →
/// append → finish. Three intents running that same sequence was just enough
/// duplication to be visually annoying but not enough to earn a helper: the
/// per-site preamble (cold-launch bridge wait, idempotency guard, startedAt
/// capture) already dictated file-level structure, and factoring would have
/// traded one kind of coupling (duplicated bodies) for another (a shared
/// helper that each new divergence would have to route around).
///
/// The v7 chained-follow-up amendment changes the math. The end-of-recording
/// tail now runs:
///
///  1. Pull the most recent transcript inside the freshness window.
///  2. Snapshot its text + id.
///  3. Call `CleanupService.resolveUtterance(new:, priorTranscript:)`.
///  4. Branch on `.freshDictation` vs `.command(instruction:, result:)`.
///  5. For fresh: optionally run cleanup (with a `.cleaning` phase transition),
///     publish, append flat.
///  6. For command: skip cleanup (classifier owns the transform atomically),
///     publish the transformed prior, mark prior superseded, append with
///     `derivedFrom` + `instruction`.
///  7. Transition the Live Activity into the shared 30-second follow-up
///     window so the user sees that a command can be spoken next.
///
/// That's a meaningful chunk of branching logic with multiple preconditions
/// (prior freshness), a state machine (ledger supersession is order-sensitive
/// relative to the new append), and two parallel Live Activity terminations.
/// Replicating it verbatim three times makes "change the pipeline shape" a
/// three-site edit with non-trivial risk of divergent bugs across intents —
/// exactly the invariant ("no code-path divergence across transcription
/// entry points") the full-v2 brief locked in.
///
/// Factoring is now net-positive: a single pipeline shape means the three
/// intents remain observably identical downstream of `stopAndTranscribe()`
/// by construction, not by audit.
///
/// ## Why `TranscribeAudioFileIntent` doesn't call this helper
///
/// `TranscribeAudioFileIntent` is a *composable Shortcuts step* (Record Audio →
/// Transcribe → Send Message), not a dictation entry point. It:
///   - Returns the transcript via `.result(value:)` for the next Shortcut
///     step, rather than publishing to the clipboard.
///   - Has no Live Activity — the file transcription runs headless inside the
///     Shortcuts runtime.
///   - Has no "I just spoke and will keep speaking" ergonomic that makes
///     chained-follow-up semantically coherent. The 30-second freshness window
///     is a human-reach-to-rephrase measure against the last voice
///     interaction — it has no meaning for an asynchronous file-in Shortcut.
///
/// Silently transforming a Shortcut's `.result(value:)` into "a re-render of
/// the user's last dictation, sent down a chain that knows nothing about
/// that prior context" would be a correctness bug, not a feature. The file
/// path therefore continues to call `TranscriptStore.append(raw:, cleaned:)`
/// directly with no follow-up classification. A user who wants chained-
/// follow-up composes it out of the dictation entry points.
///
/// ## Boundary of responsibility
///
/// The helper runs strictly after `DictationController.stopAndTranscribe()`
/// returns. Each intent remains responsible for:
///   - Looking up its controller via `DictationIntentBridge.shared.controller`.
///   - Running its idempotency guard on `currentPhase`.
///   - Capturing `recordingStartedAt` off the coordinator before `finish`
///     clears it.
///   - Calling `stopAndTranscribe()` and feeding the raw transcript in.
///
/// That split keeps the helper from needing to know about per-intent
/// concerns (cold-launch bridge waits, different `openAppWhenRun` contracts,
/// Live Activity coordinator start-on-begin) while still covering the
/// branchy downstream tail where divergence is actually costly.
@MainActor
enum DictationPipeline {
    /// Run the chained-follow-up pipeline on `transcript` and then move the
    /// Live Activity into the shared follow-up window.
    ///
    /// Caller invariants:
    ///   - `transcript` is the raw Parakeet output from
    ///     `controller.stopAndTranscribe()` — no pre-cleanup, no trimming.
    ///   - `startedAt` was snapshotted off `DictationActivityCoordinator.shared
    ///     .recordingStartedAt` before any coordinator phase update, so the
    ///     wall-clock duration reflects "mic-on" rather than "mic-off".
    ///   - `controller` is the main-app dictation controller; the helper
    ///     calls `controller.cleanup(...)` only on the fresh-dictation branch.
    ///   - The caller has already transitioned the activity to `.transcribing`.
    ///     The helper adds `.processing` during follow-up resolution and
    ///     `.cleaning` on fresh-dictation-with-cleanup-enabled.
    ///
    /// The helper owns the post-recording activity transition on both
    /// branches (via `finish` or `finishCommand`) — the caller must not call
    /// either itself.
    static func completeEndOfRecording(
        transcript: String,
        startedAt: Date,
        controller: any DictationController
    ) async throws {
        let cleanup = CleanupSettings.load()
        let postProcessing = DictationPostProcessingCoordinator.shared

        controller.beginPostProcessing()
        postProcessing.begin()
        defer {
            postProcessing.finish()
            controller.endPostProcessing()
        }

        // Pull the most recent prior transcript that falls inside the
        // freshness window. `TranscriptStore.mostRecent(within:)` returns
        // `nil` when the store is empty or the newest row is older than the
        // window, so `priorText == nil` is the clean "no follow-up candidate"
        // signal that `CleanupService.resolveUtterance` short-circuits on.
        //
        // Snapshot `id` + `displayText` into locals here rather than holding
        // the `Transcript` reference across the `await`: we're on `@MainActor`
        // so the model object *is* safe to retain, but the classifier call is
        // an LLM round-trip measured in seconds, and holding a live model
        // reference across that span churns the `ModelContext` that
        // `TranscriptStore.mostRecent` constructs inline. Snapshot-then-release
        // is cheap and keeps the context short-lived.
        let prior = TranscriptStore.mostRecent(within: ChainedFollowUp.freshnessWindow)
        let priorID = prior?.id
        let priorText = prior?.displayText

        await DictationActivityCoordinator.shared.update(phase: .processing)

        let resolution: CommandResolution
        do {
            resolution = try await postProcessing.resolveUtterance(
                new: transcript,
                priorTranscript: priorText
            )
        } catch is CancellationError {
            resolution = .freshDictation
        }

        let duration = Date().timeIntervalSince(startedAt)
        let effectiveResolution: CommandResolution =
            postProcessing.isCancellationRequested ? .freshDictation : resolution

        switch effectiveResolution {
        case .freshDictation:
            // No prior inside the window (or prior+new classified as
            // independent thoughts). Behave exactly as the v6 flat path
            // through clipboard + ledger, then expose the fresh follow-up
            // window instead of a terminal outcome pill.
            let finalText: String
            let cleanedText: String?
            if cleanup.enabled && !postProcessing.isCancellationRequested {
                await DictationActivityCoordinator.shared.update(phase: .cleaning)
                do {
                    finalText = try await postProcessing.clean(
                        transcript: transcript,
                        settings: cleanup
                    )
                    cleanedText = finalText
                } catch is CancellationError {
                    finalText = transcript
                    cleanedText = nil
                }
            } else {
                finalText = transcript
                cleanedText = nil
            }

            ClipboardHandoff.publish(transcript: finalText)

            TranscriptStore.append(
                raw: transcript,
                cleaned: cleanedText,
                duration: duration
            )

            let preview = String(finalText.prefix(60))
            await DictationActivityCoordinator.shared.finish(preview: preview)

        case .command(let instruction, let result):
            guard !postProcessing.isCancellationRequested else {
                ClipboardHandoff.publish(transcript: transcript)

                TranscriptStore.append(
                    raw: transcript,
                    cleaned: nil,
                    duration: duration
                )

                let preview = String(transcript.prefix(60))
                await DictationActivityCoordinator.shared.finish(preview: preview)
                return
            }

            // Classifier recognised the new utterance as a command against
            // the prior transcript. `result` is the transformed prior
            // (cleanup + command applied atomically in a single LLM
            // round-trip inside `resolveUtterance` — see that method's doc).
            // The controller's `.cleanup(...)` pathway is therefore skipped:
            // a second cleanup pass would either no-op (already clean) or
            // undo the classifier's stylistic intent.
            //
            // Ordering: `markSuperseded` BEFORE `append` is a **cross-file
            // contract** with the keyboard history mirror, not a local polish
            // detail. `TranscriptHistoryMirror+SwiftData.swift` filters its
            // fetch with `#Predicate { $0.supersededAt == nil }` so superseded
            // rows never enter the keyboard's 20-row history budget. The
            // mirror refresh happens inside `TranscriptStore.append(...)` —
            // so by the time the child insert triggers that refresh, the
            // prior row MUST already be flagged. Flipping the order would
            // briefly keep the prior visible in the keyboard mirror until
            // the next write-triggered refresh (which could be minutes
            // later, or never, if this is the final dictation of the
            // session).
            //
            // If a future rollback-safe pattern forces the flip (child
            // insert must succeed before parent is marked), the restoration
            // path is either (a) a second explicit mirror refresh after
            // `markSuperseded`, or (b) doing the mark inside the mirror
            // writer itself. Don't flip without one of those in place.
            // See `TranscriptHistoryMirror+SwiftData.swift` for the
            // equivalent note from the mirror side of the contract.
            ClipboardHandoff.publish(transcript: result)

            if let priorID {
                TranscriptStore.markSuperseded(id: priorID)
            }

            TranscriptStore.append(
                raw: transcript,
                cleaned: result,
                duration: duration,
                derivedFrom: priorID,
                instruction: instruction
            )

            let preview = String(result.prefix(60))
            await DictationActivityCoordinator.shared.finishCommand(
                instruction: instruction,
                preview: preview
            )
        }
    }
}
