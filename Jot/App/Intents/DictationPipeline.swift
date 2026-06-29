import Foundation
import OSLog

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
///   - Calling `stopAndTranscribe()` and feeding the raw transcript + stop
///     timestamp in.
///
/// That split keeps the helper from needing to know about per-intent
/// concerns (cold-launch bridge waits, different `openAppWhenRun` contracts,
/// Live Activity coordinator start-on-begin) while still covering the
/// branchy downstream tail where divergence is actually costly.
/// Outcome of a successful `DictationPipeline.completeEndOfRecording` run.
///
/// Returned so call sites with their own UI side-effects (e.g. the in-app
/// `ContentView` "Copied" toast) can hook off the published transcript
/// without inventing a separate `@Observable` "last-published-id" property.
/// Intent call sites discard this value (the helper is `@discardableResult`)
/// because their UI feedback already runs through App Group projections
/// the keyboard reads from.
///
/// `finalText` is the text placed on the clipboard — cleaned text on the
/// fresh-dictation branch when cleanup was enabled and did not throw, the
/// classifier-transformed text on the command branch, or the raw transcript
/// otherwise. `branch` distinguishes the two resolution outcomes.
struct PublishedTranscriptOutcome: Sendable {
    enum Branch: Sendable {
        case fresh
        case command
    }

    let transcriptID: UUID
    let finalText: String
    let branch: Branch
}

@MainActor
enum DictationPipeline {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "dictation-pipeline"
    )

    /// Run the chained-follow-up pipeline on `transcript` and then move the
    /// Live Activity into the shared follow-up window.
    ///
    /// Caller invariants:
    ///   - `transcript` is the raw Parakeet output from
    ///     `controller.stopAndTranscribe()` — no pre-cleanup, no trimming.
    ///   - `startedAt` was snapshotted off `DictationActivityCoordinator.shared
    ///     .recordingStartedAt` before any coordinator phase update.
    ///   - `stoppedAt` was captured immediately after `RecordingService.stop()`
    ///     drained samples, so persisted duration excludes transcription,
    ///     follow-up classification, and cleanup latency.
    ///   - `controller` is the main-app dictation controller; the helper
    ///     calls `controller.cleanup(...)` only on the fresh-dictation branch.
    ///   - The caller has already transitioned the activity to `.transcribing`.
    ///     The helper adds `.processing` during follow-up resolution and
    ///     `.cleaning` on fresh-dictation-with-cleanup-enabled.
    ///
    /// The helper owns the post-recording activity transition on both
    /// branches (via `finish` or `finishCommand`) — the caller must not call
    /// either itself.
    ///
    /// Merged in lean-arch consolidation (per `tmp/research-app-architecture.md`
    /// §2.3 + §8 Phase 2): previously the in-app `ContentView.finishTranscription`
    /// ran a parallel post-recording tail (publish → append → toast) that
    /// skipped the chained-follow-up classifier and wrapped cleanup in an
    /// 8-second wall-clock timeout. The in-app path now routes here too,
    /// so it gains chained-follow-up classification (D1) and drops the
    /// outer wall-clock timeout (D2). The return type is non-`Void` (D3)
    /// so the in-app caller's "Copied" toast can hook off the published
    /// transcript ID without a separate `@Observable` property. Intent
    /// call sites discard the return via `@discardableResult`.
    @discardableResult
    /// - Parameter transient: when `true`, run the full publish + terminal-phase
    ///   path (so the keyboard's auto-paste lands and the cross-process projection
    ///   ends the transcription cleanly) but persist NOTHING — no `Transcript`
    ///   row, no follow-up supersession, no usage stats. This is the in-Jot
    ///   keyboard-stop case (unify-keyboard-dictation §3/§4: "stop inside a Jot
    ///   field → paste, no save"). Defaults to `false` so the hero, cold-from-
    ///   another-app, Action Button, DictateIntent and warm-resume callers keep
    ///   saving exactly as before.
    static func completeEndOfRecording(
        transcript: String,
        sessionID: UUID? = nil,
        startedAt: Date,
        stoppedAt: Date,
        controller: any DictationController,
        transient: Bool = false,
        // 16 kHz mono source samples for this recording, retained (keyed to the
        // saved transcript) so the user can re-transcribe later. nil when the
        // caller has no samples to retain (e.g. the keyboard URL-bounce path
        // that only forwards text). Only persisted on the non-transient
        // (transcript-saving) branches — a transient in-Jot stop saves nothing.
        retainSamples: [Float]? = nil
    ) async throws -> PublishedTranscriptOutcome {
        let duration = max(0, stoppedAt.timeIntervalSince(startedAt))
        // Record usage stats up-front, before any cleanup / publish branching.
        // By the time the pipeline runs, the user has finished speaking and
        // the recording duration is real — downstream publish or cleanup
        // failures don't invalidate the fact that they dictated. Both this
        // file's in-app calls and the keyboard's calls flow through here,
        // so the App Group counter sees every successful dictation in one
        // place. Empty transcripts (silent sessions) still count because the
        // duration is meaningful for the "time spent dictating" metric.
        //
        // Transient (in-Jot keyboard stop): skip stats. The user dictated INTO a
        // Jot field — it's treated like the keyboard in any other app where Jot
        // simply pastes; no Transcript is written, so it must not inflate the
        // "time spent dictating" counter either (parity with the inline path's
        // R7: in-field dictation bypasses DictationStats).
        if !transient {
            DictationStats.record(durationSeconds: duration)
        }

        let cleanup = CleanupSettings.load()
        let postProcessing = DictationPostProcessingCoordinator.shared
        let recording = RecordingService.shared

        // v0.4: clear any stale rewrite status banner from a prior dictation
        // so the keyboard doesn't render an outdated message on this
        // dictation's `transcriptReady`. The new branch will write a fresh
        // string (or leave nil on success / Just-Transcribe) before publish.
        AppGroup.lastDictationStatusMessage = nil

        // v7 auto-paste design: every published payload carries a session ID
        // so the keyboard can match it against its `PendingPasteSession.id`.
        // Callers in scope of the v7 wave pass the session ID explicitly;
        // out-of-scope callers (kept untouched in this implementation step)
        // fall back to the RecordingService's current session, or generate
        // a fresh one. A fresh ID never matches any keyboard pending session,
        // so the keyboard correctly ignores in-app dictations.
        let resolvedSessionID = sessionID
            ?? recording.currentSessionID
            ?? UUID()
        if recording.currentSessionID == nil {
            recording.adoptSession(resolvedSessionID)
        }

        controller.beginPostProcessing()
        postProcessing.begin()

        // Session-token-guarded defer. If we unwind before this method's body
        // reaches its terminal `publishPipelinePhase(.idle)`, AND the pipeline
        // is still owned by OUR session (no newer session has taken over),
        // publish `.failed` so the keyboard's terminal cleanup can clear its
        // pending state. The token guard means a defer firing AFTER a NEW
        // session has started a fresh pipeline does NOT clobber the new
        // session's phase.
        var publishedTerminal = false
        defer {
            postProcessing.finish()
            controller.endPostProcessing()
            recording.markPipelineFinished()
            if !publishedTerminal,
               recording.currentSessionID == resolvedSessionID,
               recording.currentPipelinePhase != .idle,
               recording.currentPipelinePhase != .failed {
                recording.publishPipelinePhase(
                    .failed,
                    failureReason: "pipeline-unwound-before-publish"
                )
            }
        }

        // Pull the most recent prior transcript that falls inside the
        // freshness window, but only offer it to the classifier while the
        // follow-up window is still active. Dismissing the UI has to collapse
        // the next utterance back to fresh dictation even if the timestamp is
        // still inside the 30s window.
        //
        // Snapshot `id` + `displayText` into locals here rather than holding
        // the `Transcript` reference across the `await`: we're on `@MainActor`
        // so the model object *is* safe to retain, but the classifier call is
        // an LLM round-trip measured in seconds, and holding a live model
        // reference across that span churns the `ModelContext` that
        // `TranscriptStore.mostRecent` constructs inline. Snapshot-then-release
        // is cheap and keeps the context short-lived.
        let prior = TranscriptStore.mostRecent(within: ChainedFollowUp.freshnessWindow)
        let uiFollowUpActive = DictationActivityCoordinator.shared.isFollowUpActive
        let priorID = uiFollowUpActive ? prior?.id : nil
        let priorText = uiFollowUpActive ? prior?.displayText : nil
        let priorAge = prior.map { Date().timeIntervalSince($0.createdAt) }

        logger.info(
            "follow-up candidate — uiActive=\(uiFollowUpActive, privacy: .public) priorPresent=\(priorText != nil, privacy: .public) priorAge=\(priorAge ?? -1, privacy: .public) transcriptChars=\(transcript.count, privacy: .public)"
        )

        await DictationActivityCoordinator.shared.update(phase: .processing)
        recording.publishPipelinePhase(.processing)

        let resolution: CommandResolution
        do {
            resolution = try await postProcessing.resolveUtterance(
                new: transcript,
                priorTranscript: priorText
            )
        } catch is CancellationError {
            resolution = .freshDictation
        }

        let resolvedAsCommand: Bool
        switch resolution {
        case .freshDictation:
            resolvedAsCommand = false
        case .command:
            resolvedAsCommand = true
        }

        let effectiveResolution: CommandResolution =
            postProcessing.isCancellationRequested ? .freshDictation : resolution
        let tookCommandBranch: Bool
        switch effectiveResolution {
        case .freshDictation:
            tookCommandBranch = false
        case .command:
            tookCommandBranch = true
        }

        logger.info(
            "follow-up resolution — cancelled=\(postProcessing.isCancellationRequested, privacy: .public) resolvedAsCommand=\(resolvedAsCommand, privacy: .public) finalCommandBranch=\(tookCommandBranch, privacy: .public)"
        )

        switch effectiveResolution {
        case .freshDictation:
            // No prior inside the window (or prior+new classified as
            // independent thoughts). Behave exactly as the v6 flat path
            // through clipboard + ledger, then expose the fresh follow-up
            // window instead of a terminal outcome pill.
            //
            // v7 publish-first ordering: derive final text → publish FIRST →
            // append (best-effort, errors logged but don't skip publish) →
            // activity finish → `.idle`. Cleanup throws degrade to raw, so
            // we never silently drop the user's transcript.
            let finalText: String
            let cleanedText: String?
            if cleanup.enabled && !postProcessing.isCancellationRequested {
                await DictationActivityCoordinator.shared.update(phase: .cleaning)
                recording.publishPipelinePhase(.cleaning)
                do {
                    let cleaned = try await postProcessing.clean(
                        transcript: transcript,
                        settings: cleanup
                    )
                    if postProcessing.isCancellationRequested {
                        logger.info("cleanup result discarded after cancellation")
                        // Cancellation falls all the way back to raw —
                        // publishing a half-applied state would be worse
                        // than just giving the user their original words.
                        finalText = transcript
                        cleanedText = nil
                    } else {
                        finalText = cleaned
                        cleanedText = cleaned
                    }
                } catch {
                    // ANY throw — cancellation, model-unavailable, generation-
                    // failure. Degrade to raw. Do not skip publish. The AI
                    // Rewrite cleanup is the more invasive pass — falling
                    // back to raw avoids confusing the user with a
                    // half-rewritten surface.
                    logger.error(
                        "cleanup degraded to raw: \(error.localizedDescription, privacy: .public)"
                    )
                    finalText = transcript
                    cleanedText = nil
                }
            } else {
                // No AI Rewrite cleanup ran — the published text IS the raw
                // text. Lightweight regex filler-word sweep that always runs
                // on every transcript lives downstream of the publish/append
                // surfaces (Detail's Original tab applies it on render).
                finalText = transcript
                cleanedText = nil
            }

            let publishedText = finalText

            let transcriptID = UUID()

            // Single paste path (decouple-root-view Step 4): the in-Jot
            // (transient) stop now flows through the SAME keyboard auto-paste
            // flush as every other host. The keyboard's `.stop` tap always arms a
            // pending paste session before posting `stopRequested`, so this publish
            // carries a session the keyboard's `flushPendingAutoPasteIfPossible`
            // matches and inserts at the cursor. Step 3 isolated the in-app field
            // so it no longer re-mounts on stop, and the keyboard's same-host paste
            // guards were already removed — so the former in-process
            // `FocusedFieldInsert` bridge (and its clear-pending-before-publish
            // skip) is gone. `transient` now ONLY decides save/no-save (the
            // `if !transient` guards below); it no longer forks the delivery path.

            // Ask-before-paste (Thread 2): the keyboard reads the correction asks
            // SYNCHRONOUSLY at flush time to decide whether to hold the paste for a
            // review deck — so the asks DATA must be in the App Group BEFORE the
            // handoff below wakes the keyboard. Commit provenance + stage the asks
            // here, but DO NOT post `correctionAsksReady` yet (it drives the legacy
            // post-paste nudge; firing it pre-paste would race the deck). The ready
            // signal is posted AFTER the handoff (below). Committing here is safe:
            // provenance is keyed by the transcript UUID, not the SwiftData row
            // (idempotent, non-persisting map), so it doesn't need the ledger append
            // (which stays last, Step B). Cost is a filter + context-slice, no
            // inference — it does not meaningfully gate the paste (the user already
            // waited through record→transcribe).
            var asksReadyToSignal = false
            if !transient {
                await CorrectionProvenance.shared.commit(transcriptID: transcriptID)
                asksReadyToSignal = await CorrectionAsksPublisher.publish(
                    transcriptID: transcriptID,
                    sessionID: resolvedSessionID,
                    publishedText: publishedText,
                    signalReady: false)
            }

            // Step A: publish FIRST. The keyboard's auto-paste cares about
            // the publish; the ledger row is a separate concern that must
            // not gate it.
            recording.publishPipelinePhase(.publishing)
            ClipboardHandoff.publish(
                transcript: publishedText,
                sessionID: resolvedSessionID,
                autoCopiedTranscriptID: transcriptID
            )
            DiagnosticsLog.record(
                source: "main-app",
                category: .publishCompleted,
                message: "Published transcript (fresh)",
                metadata: [
                    "sessionID": resolvedSessionID.uuidString,
                    "chars": "\(publishedText.count)",
                    "branch": "fresh"
                ]
            )
            CrossProcessNotification.post(name: CrossProcessNotification.transcriptReady)
            // NOW (after the paste-triggering handoff) signal the asks staged above,
            // so the legacy post-paste nudge can fire — never before the paste.
            if asksReadyToSignal {
                CrossProcessNotification.post(name: CrossProcessNotification.correctionAsksReady)
            }

            // In-Jot (transient) stop: no in-process delivery. The keyboard's
            // auto-paste flush (woken by the `transcriptReady` post above) lands
            // the text at the cursor in Jot's own field, exactly as it does in any
            // other host. "Stop inside Jot = no save" still holds via the
            // `if !transient` guards below.

            updateFollowUpDiscoveryState(
                wasFollowUpUtterance: uiFollowUpActive,
                resolvedAsCommand: false
            )

            // Step B: append to ledger. If THIS throws, log and continue —
            // the publish has already happened and the user's auto-paste
            // will land. Ledger inconsistency is a less-bad failure than
            // silent paste loss. The only user-visible consequence is that
            // the just-pasted dictation won't appear as a chained-follow-up
            // parent on the very next utterance.
            //
            // Transient (in-Jot keyboard stop): publish already pasted into the
            // focused Jot field above; we persist NO Transcript (the save/no-save
            // decision lives at the stop site — Jot foreground → no save).
            if !transient {
                do {
                    try TranscriptStore.append(
                        id: transcriptID,
                        raw: transcript,
                        cleaned: cleanedText,
                        duration: duration,
                        retainAudioSamples: retainSamples
                    )
                    // NOTE: provenance commit + asks staging moved ABOVE the handoff
                    // (ask-before-paste needs them readable when the keyboard wakes).
                    // The ledger append stays here, last, still best-effort: if it
                    // throws, the paste already landed and the asks already published
                    // — a verdict on an ask whose row failed to append is dropped on
                    // drain (CorrectionInbox skips a missing transcript; rare, accepted).
                } catch {
                    logger.error(
                        "ledger append failed; clipboard publish already succeeded: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let preview = String(publishedText.prefix(60))
            await Self.transitionPostPublish(preview: preview)

            recording.publishPipelinePhase(.idle)
            publishedTerminal = true

            return PublishedTranscriptOutcome(
                transcriptID: transcriptID,
                finalText: publishedText,
                branch: .fresh
            )

        case .command(let instruction, let result):
            guard !postProcessing.isCancellationRequested else {
                // Cancellation: publish raw and go `.idle`. Per design §4.6.B
                // `.cancelled` is NOT a phase value — keyboard sees this as
                // a normal completion (CancelPostProcessingIntent's documented
                // contract: "publish the raw transcript as fresh dictation").
                let transcriptID = UUID()

                recording.publishPipelinePhase(.publishing)
                ClipboardHandoff.publish(
                    transcript: transcript,
                    sessionID: resolvedSessionID,
                    autoCopiedTranscriptID: transcriptID
                )
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .publishCompleted,
                    message: "Published transcript (command-cancelled raw)",
                    metadata: [
                        "sessionID": resolvedSessionID.uuidString,
                        "chars": "\(transcript.count)",
                        "branch": "command-cancelled"
                    ]
                )
                CrossProcessNotification.post(name: CrossProcessNotification.transcriptReady)

                updateFollowUpDiscoveryState(
                    wasFollowUpUtterance: uiFollowUpActive,
                    resolvedAsCommand: false
                )

                // Transient (in-Jot keyboard stop): paste, but persist nothing.
                if !transient {
                    do {
                        try TranscriptStore.append(
                            id: transcriptID,
                            raw: transcript,
                            cleaned: nil,
                            duration: duration,
                            retainAudioSamples: retainSamples
                        )
                    } catch {
                        logger.error(
                            "ledger append failed on command-cancelled path; publish already succeeded: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                let preview = String(transcript.prefix(60))
                await Self.transitionPostPublish(preview: preview)

                recording.publishPipelinePhase(.idle)
                publishedTerminal = true

                return PublishedTranscriptOutcome(
                    transcriptID: transcriptID,
                    finalText: transcript,
                    branch: .fresh
                )
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
            //
            // v7 publish-first contract: if persistence (mark/append) throws,
            // degrade to fresh-dictation raw publish so the user always gets
            // their text. The orphaned-supersession concern (parent marked +
            // child append failed) is the existing v6 risk; per design §4.6.A
            // the fully-atomic fix lives in a new TranscriptStore helper that
            // is out of scope for this teammate.
            let transcriptID = UUID()

            do {
                // Transient (in-Jot keyboard stop): publish the transformed
                // command `result` so it pastes into the focused Jot field, but
                // persist NOTHING — do not write the child Transcript and, just
                // as importantly, do NOT mark the prior superseded (a transient
                // in-field dictation must never mutate saved history).
                if !transient {
                    if let priorID {
                        try TranscriptStore.markSuperseded(id: priorID)
                    }

                    try TranscriptStore.append(
                        id: transcriptID,
                        raw: transcript,
                        cleaned: result,
                        duration: duration,
                        derivedFrom: priorID,
                        instruction: instruction
                    )
                }

                updateFollowUpDiscoveryState(
                    wasFollowUpUtterance: uiFollowUpActive,
                    resolvedAsCommand: true
                )

                recording.publishPipelinePhase(.publishing)
                ClipboardHandoff.publish(
                    transcript: result,
                    sessionID: resolvedSessionID,
                    autoCopiedTranscriptID: transcriptID
                )
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .publishCompleted,
                    message: "Published transcript (command result)",
                    metadata: [
                        "sessionID": resolvedSessionID.uuidString,
                        "chars": "\(result.count)",
                        "branch": "command"
                    ]
                )
                CrossProcessNotification.post(name: CrossProcessNotification.transcriptReady)

                let preview = String(result.prefix(60))
                await Self.transitionPostPublish(
                    instruction: instruction,
                    preview: preview
                )

                recording.publishPipelinePhase(.idle)
                publishedTerminal = true

                return PublishedTranscriptOutcome(
                    transcriptID: transcriptID,
                    finalText: result,
                    branch: .command
                )
            } catch {
                // Persistence failed. Roll forward as fresh-dictation: publish
                // RAW so the user gets their text. Do not skip publish.
                logger.error(
                    "command branch persistence failed; degrading to raw fresh-dictation publish: \(error.localizedDescription, privacy: .public)"
                )

                recording.publishPipelinePhase(.publishing)
                ClipboardHandoff.publish(
                    transcript: transcript,
                    sessionID: resolvedSessionID,
                    autoCopiedTranscriptID: transcriptID
                )
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .publishCompleted,
                    message: "Published transcript (command-degraded raw)",
                    metadata: [
                        "sessionID": resolvedSessionID.uuidString,
                        "chars": "\(transcript.count)",
                        "branch": "command-degraded"
                    ]
                )
                CrossProcessNotification.post(name: CrossProcessNotification.transcriptReady)

                updateFollowUpDiscoveryState(
                    wasFollowUpUtterance: uiFollowUpActive,
                    resolvedAsCommand: false
                )

                let preview = String(transcript.prefix(60))
                await Self.transitionPostPublish(preview: preview)

                recording.publishPipelinePhase(.idle)
                publishedTerminal = true

                return PublishedTranscriptOutcome(
                    transcriptID: transcriptID,
                    finalText: transcript,
                    branch: .fresh
                )
            }
        }
    }

    private static func updateFollowUpDiscoveryState(
        wasFollowUpUtterance: Bool,
        resolvedAsCommand: Bool
    ) {
        switch FollowUpDiscoveryStore.state {
        case .dismissed, .learned:
            return
        case .unseen where !wasFollowUpUtterance:
            FollowUpDiscoveryStore.state = .awaitingFirstFollowUp
        case .unseen, .awaitingFirstFollowUp, .awaitingContextAck:
            if wasFollowUpUtterance {
                FollowUpDiscoveryStore.state = resolvedAsCommand ? .learned : .awaitingContextAck
            }
        }
    }

    /// Post-publish Live Activity transition into the 30-second
    /// chained-follow-up window. The fresh-dictation paths (the
    /// `.freshDictation`, cancellation, and command-persistence-failure
    /// branches) call the no-instruction overload; the command-success path
    /// calls the overload that carries the instruction so `finishCommand(...)`
    /// preserves the "Command: <instruction>" outcome rendering.
    private static func transitionPostPublish(preview: String) async {
        await DictationActivityCoordinator.shared.finish(preview: preview)
    }

    private static func transitionPostPublish(instruction: String, preview: String) async {
        await DictationActivityCoordinator.shared.finishCommand(
            instruction: instruction,
            preview: preview
        )
    }

}
