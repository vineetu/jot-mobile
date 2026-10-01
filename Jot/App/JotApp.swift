@preconcurrency import AVFAudio
import BackgroundTasks
import Combine
import CoreSpotlight
import Network
import SwiftUI
import SwiftData
import UIKit
import os.log

private let lifecycleLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "app-lifecycle")

/// Minimal `UIApplicationDelegate` — exists ONLY to receive the background
/// URLSession relaunch handoffs for the discretionary model fetches (⚠️REVIEW H1).
/// SwiftUI's `App` lifecycle has no equivalent hook. It routes the completion
/// handler to whichever fetcher owns the session identifier and implements
/// nothing else, so all scene/lifecycle behaviour continues to flow through
/// `JotApp`. Owners today: the Parakeet-upgrade download-on-charge fetch and
/// the unified English model fetch.
final class JotAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        switch identifier {
        case ParakeetModelFetcher.sessionIdentifier:
            ParakeetModelFetcher.shared.handleBackgroundSessionEvents(
                completionHandler: completionHandler
            )
        case UnifiedModelFetcher.sessionIdentifier:
            // Without this the 582 MB unified fetch could COMPLETE while the app
            // is suspended and never be installed — iOS relaunches us precisely
            // to deliver these events, and dropping them strands the download.
            MainActor.assumeIsolated {
                UnifiedModelFetcher.shared.handleBackgroundSessionEvents(
                    completionHandler: completionHandler
                )
            }
        case PunctuationModelFetcher.sessionIdentifier:
            // Same reason as the unified fetch: the punctuation model's download
            // can complete while we are suspended, and dropping the relaunch
            // event strands it half-staged forever.
            MainActor.assumeIsolated {
                PunctuationModelFetcher.shared.handleBackgroundSessionEvents(
                    completionHandler: completionHandler
                )
            }
        default:
            // Not one of ours — release the system immediately so we never strand it.
            completionHandler()
        }
    }
}

@main
struct JotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// App-delegate adaptor whose sole job is the background-URLSession relaunch
    /// handoff (⚠️REVIEW H1, docs/plans/model-externalization-sub-50mb.md §A3).
    /// When the system relaunches Jot in the background to finish the discretionary
    /// EmbeddingGemma download, it hands us the session's completion handler via
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` —
    /// there is no SwiftUI-native hook for this, so a minimal `UIApplicationDelegate`
    /// is required. It implements nothing else, so scene handling is untouched.
    @UIApplicationDelegateAdaptor(JotAppDelegate.self) private var appDelegate
    private let stopRequestObserver: CrossProcessNotification.Observer
    private let cancelRequestObserver: CrossProcessNotification.Observer
    private let warmResumeObserver: CrossProcessNotification.Observer
    /// Applies keyboard ask answers as soon as they're queued (see
    /// `CrossProcessNotification.correctionVerdictQueued`).
    private let correctionVerdictObserver: CrossProcessNotification.Observer
    /// Applies keyboard "Add to Vocabulary" corrections as soon as they're
    /// queued (see `CrossProcessNotification.vocabAddRequested`).
    private let vocabAddObserver: CrossProcessNotification.Observer
    @State private var recordingService: RecordingService
    @State private var transcriptionService: TranscriptionService
    @State private var streamingPartial: StreamingPartial
    @State private var cleanupService: CleanupService
    @State private var setupRerunTrigger: SettingsRerunTrigger
    @State private var keyboardRewriteRouter = KeyboardRewriteRouter()
    /// App-owned navigation source of truth (Step 1 of the root-view
    /// decouple). Additive `@State` injected into the scene alongside the
    /// existing services — it must NOT reorder or gate the launch-serialize
    /// Task or the scene `.task`, and must NOT sit in front of the
    /// `onOpenURL` early-returns. See `docs/decouple-root-view/design.md`.
    @State private var router = Router()
    @State private var showSetupWizard = false
    @State private var setupCompleted = SetupCompletion.isCompleted
    @State private var autoStartConsumed = false
    @State private var autoStartPendingModelReady = false
    @State private var autoStartPendingSetupComplete = false
    @State private var autoStartPendingPipelineFinish = false
    @State private var autoStartPipelineDrainTimeoutTask: Task<Void, Never>?
    @State private var autoStartMicPermissionRequestInFlight = false
    /// One-shot signal that the keyboard opened Jot from another app via a
    /// `jot://dictate*` URL bounce (the only way it can — iOS won't let the
    /// keyboard start the mic, so with no warm mic it foregrounds the app). Set
    /// on EVERY such open, cold OR warm process. ContentView's
    /// `presentExternalKeyboardHeroIfPending` reads + clears this and presents
    /// the Hero with `.openedFromExternalKeyboard`, which surfaces the looping
    /// swipe-back cue. Cleared after one Hero presentation.
    @State private var pendingExternalKeyboardHero: Bool = false
    /// User-facing message for a failed dictate auto-start (mic busy,
    /// session error, etc.) Set from the catch path in `triggerAutoStart`
    /// so the foregrounded main app can show an alert — the existing
    /// `AppGroup.lastDictationStatusMessage` is only read by the keyboard,
    /// so without this the user lands on the home screen with no signal
    /// that the dictation they just tapped didn't actually start.
    @State private var dictateAutoStartError: String?

    private static let warmResumeFallbackNotification = Notification.Name(
        "com.vineetu.jot.mobile.warm-resume-fallback-requested"
    )

/// Stashed session UUID parsed off the most recent `jot://dictate?session=<uuid>`
    /// URL. Consumed in `triggerAutoStart` immediately before `recording.start()`
    /// so the upcoming pipeline writes carry the keyboard's session ID. Held on
    /// the App (not consumed by the first `triggerAutoStart` turn) so model-not-
    /// ready retries via `.onChange(of: modelState)` re-read this stash —
    /// surviving the cold-launch race per design §4.2.
    @State private var pendingKeyboardSessionID: UUID?

    /// Repeating Task that refreshes `AppGroup.Keys.appForegroundHeartbeat`
    /// every ~1s while `scenePhase == .active`. Started on scene-active,
    /// cancelled on scene-inactive / background. The keyboard extension
    /// reads the heartbeat freshness to detect "host app == Jot" — see
    /// `AppGroup.isJotAppForeground()` and `JotKeyboardViewController.handleMicCTATap`
    /// for the consumer side.
    @State private var heartbeatTask: Task<Void, Never>?

    init() {
        stopRequestObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.stopRequested
        ) {
            CrossProcessRecordingStopCoordinator.shared.handleStopRequested()
        }

        cancelRequestObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.cancelRequested
        ) {
            CrossProcessRecordingStopCoordinator.shared.handleCancelRequested()
        }

        correctionVerdictObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.correctionVerdictQueued
        ) {
            Task { @MainActor in
                await CorrectionInbox.drain(modelContext: ModelContext(JotModelContainer.shared))
            }
        }

        vocabAddObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.vocabAddRequested
        ) {
            Task { @MainActor in await VocabularyAddInbox.drain() }
        }

        warmResumeObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.warmResumeRequested
        ) {
            Task { @MainActor in
                // Capture the moment we received the keyboard's ping — this
                // is the actual "user pressed Dictate" timestamp for the
                // new recording. Committed to the coordinator on success
                // so the hero's adopt-in-flight path reads a fresh anchor
                // instead of the previous session's stale value (Bug 2).
                let startedAt = Date()
                do {
                    lifecycleLog.notice("RECORDING START FROM: warmResumeObserver (JotApp.init)")
                    // A warm-resumed capture must never carry a stale inline-
                    // ownership flag. `ownsActiveRecording` is set ONLY by Ask's
                    // `InlineDictationSession`; warm-resume calls `start()`
                    // directly (no cold-start cleanup), so a leaked `true` would
                    // survive into this capture and make the keyboard Stop bail
                    // out of `handleStopRequested` before stopping the mic
                    // (the warm-resume "won't stop" regression). Clear it here.
                    RecordingService.shared.ownsActiveRecording = false
                    try await RecordingService.shared.start()
                    // Refresh the coordinator's recording-start timestamp
                    // so the hero adopts THIS recording's start time, not
                    // the previous one's. Without this, the hero's elapsed
                    // timer counts up from a stale anchor (user reported
                    // "26 min" when 3-4 min into the current recording —
                    // root cause: warm-resume successfully started a new
                    // recording but the coordinator's timestamp was never
                    // updated, so the hero adopt path read the previous
                    // recording's start time).
                    await DictationActivityCoordinator.shared.start(startedAt: startedAt)
                    lifecycleLog.info("Warm resume requested from keyboard; recording started")
                } catch {
                    // The warm-resume fast path is fire-and-forget from the
                    // keyboard's side. If start() throws, route back through the
                    // guarded auto-start state machine instead of losing the tap.
                    // The warm RECORD is already reconciled in-process: every
                    // warm-resume failure path inside `start()` calls
                    // `exitWarmHold()` (→ record `.idle`), so there is no stale
                    // warm projection left to clear here (the legacy
                    // `warmHoldExpiresAt`/`warmHoldHeartbeat` keys were removed in B4).
                    let fallbackReason = "warm resume failed: \(Self.describeAutoStartError(error))"
                    lifecycleLog.notice("AUTOSTART: guard=warm-resume-start action=defer reason=\(fallbackReason, privacy: .public)")
                    if case RecordingService.RecordingError.alreadyRunning = error {
                        lifecycleLog.debug("Warm resume fallback continuing after alreadyRunning")
                    } else {
                        lifecycleLog.error("Warm resume requested from keyboard failed: \(Self.describeAutoStartError(error), privacy: .public)")
                    }
                    NotificationCenter.default.post(
                        name: Self.warmResumeFallbackNotification,
                        object: nil,
                        userInfo: ["reason": fallbackReason]
                    )
                }
            }
        }

        lifecycleLog.info("JotApp init — begin")
        // Single process-wide `RecordingService` instance — same reference
        // the `DictationControllerImpl` inside the Action Button / Shortcuts
        // intents already uses. Before v10, ContentView's @State instance
        // and DictationControllerImpl's @Main instance each called
        // `AVAudioSession.sharedInstance().setCategory(.playAndRecord, ...)`
        // and stashed "prior state" for restoration — whichever instance
        // ran second captured the FIRST instance's modifications as "prior,"
        // leaking state forward across dictations. The singleton closes
        // that gap without paying the `warmUp()` cost (this is purely an
        // audio-side consolidation; `TranscriptionService.shared` stays
        // untouched). See `RecordingService.shared` doc for rationale.
        let recording = RecordingService.shared
        // Singleton — shared with `TranscribeAudioFileIntent` so a warm-up
        // in either caller amortizes the Parakeet cold load across both.
        // See `TranscriptionService.shared` doc for rationale.
        let transcription = TranscriptionService.shared
        // Live preview presenter, observed by ContentView. Single instance
        // for the app lifetime — RecordingService.setStreamingPresenter
        // (called below) holds a strong ref and depends on this living for
        // the recorder's full lifetime.
        let streamingPartial = StreamingPartial()
        // Inject the presenter into the recorder so its audio fan-out can
        // drive the live preview. Headless callers (Shortcuts intent etc.)
        // construct via `RecordingService.shared` without going through
        // JotApp; they leave `streamingPresenter == nil` and gracefully
        // skip the streaming pipeline.
        recording.setStreamingPresenter(streamingPartial)
        let cleanup = CleanupService()
        let rerunTrigger = SettingsRerunTrigger.shared
        _recordingService = State(initialValue: recording)
        _transcriptionService = State(initialValue: transcription)
        _streamingPartial = State(initialValue: streamingPartial)
        _cleanupService = State(initialValue: cleanup)
        _setupRerunTrigger = State(initialValue: rerunTrigger)

        // §D (v2 carry-forward, docs/dictation-engine-rework/
        // v2-carry-forward-migration-design.md): resolve the English dictation
        // engine default ONCE, SYNCHRONOUSLY, and as EARLY as possible — before
        // any Task below is scheduled and before the recording subsystem can
        // service a start (Action Button / DictateIntent / cold jot://dictate
        // can begin a recording with no UI). An existing Parakeet user on a
        // capable device is flipped off the global-true Apple default so their
        // first post-update English dictation stays on Parakeet; a new user
        // keeps Apple. Guarded — runs at most once, so a later explicit Settings
        // toggle always wins. Touches only an App-Group value (no schema change).
        V2CarryForwardMigration.resolveEnglishEngineDefaultIfNeeded()

        // One-shot sweep of any orphaned model-purge dirs from prior crashed
        // purges. Detached + best-effort, does not block launch.
        TranscriptionService.sweepOrphanedPurgingDirs()

        // Purge source audio retained past its 3-day window (re-transcription
        // safety net). Best-effort; does not block launch.
        RetainedAudioStore.purgeExpired()

        // Vocabulary boosting: prepare the rescorer at LAUNCH if the user has it
        // enabled. It was previously prepared ONLY while the Vocabulary Settings
        // screen was open — so a cold keyboard-bounced process (which never opens
        // Settings) left `VocabularyRescorerHolder` un-prepared, `rescore()` hit
        // its `guard let spotter…` and returned nil, and EVERY vocab correction
        // silently no-op'd. Best-effort + detached; the rescore path falls back to
        // the raw transcript if this hasn't finished yet.
        // SERIAL cold-load order: Parakeet → vocab CTC → EmbeddingGemma. All
        // three are CoreML models whose loads contend in the shared ANE
        // device-specialization compiler — running any two concurrently 4×'d
        // the cold start (~60s vs ~16s). `.utility` priority isn't enough (the
        // contention is in the ANE compiler, not the scheduler), so we gate each
        // stage behind the previous one and load them strictly one at a time.
        Task { @MainActor in
            // Drain an armed-but-unapplied Parakeet engine switch BEFORE the warm
            // chain reads the engine state — covers a background download that
            // completed while the app was closed (or a switch deferred because a
            // recording was in flight last session). Launch is a safe boundary
            // (nothing is recording yet), so this applies immediately and the warm
            // chain below then warms the right model. No-op unless armed.
            ParakeetModelArrival.applyPendingSwitchIfSafe()

            // Parakeet Unified — the English engine since build 297. The model
            // is per-process state (`state` resets to `.notDownloaded` and the
            // manager is nil in a fresh process), so without this every English
            // dictation after a relaunch would silently run the bundled v2
            // fallback. This ALSO starts the 582 MB download the first time, for
            // a user who has never had it: the fetch is discretionary and
            // Wi-Fi-only, and nothing waits on it. No-op off English, on the
            // Apple engine, and when already prepared.
            //
            // Deliberately placed in this SERIAL cold-load chain rather than
            // concurrently: it is a third CoreML model, and loading CoreML
            // models in parallel contends in the ANE device-specialization
            // compiler (measured 4x cold start — see the note below).
            UnifiedEnglishModel.syncWithRouting()

            // Punctuation / true-casing model (~57 MB). Unlike the fetches
            // above this is unprompted and discretionary: it needs no user
            // action, rides Wi-Fi at a moment the system picks, and simply
            // no-ops in the transcript pipeline until it has landed. Owner call
            // (2026-08-30): download it like the rest rather than bundling it,
            // because bundling would nearly triple the IPA.
            PunctuationModelFetcher.shared.resumeIfPending()

            // Stage 1 → 2: wait for Parakeet, then prepare the vocab rescorer IF
            // the user has it enabled. Done as an `if` (not an early return) so
            // the EmbeddingGemma prewarm below still runs when vocab is disabled.
            await TranscriptionService.shared.awaitWarmSettled()
            if VocabularyStore.shared.isEnabled,
                CtcModelCache.shared.isCached,
                let vocabURL = VocabularyStore.shared.fileURL {
                try? await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: vocabURL)
            }

            // Stage 3 (LAST): pre-warm the MiniLM embedding model so the first
            // dictation doesn't pay the 3–10s cold load tax inline. Kicked only
            // after Parakeet (and vocab, when enabled) have settled, so it never
            // contends with their ANE specialization. `.utility` so it yields to
            // any userInitiated work; `prewarm()` coalesces concurrent callers,
            // so a dictation that races this shares the same in-flight load.
            Task(priority: .utility) {
                // LAST in the chain: warm the NON-selected dictation model(s)
                // (e.g. European v3 while English is active) so a later language
                // switch is instant. Runs after the selected model + vocab,
                // lowest priority, and bails if a recording/
                // transcription is in flight — so it never delays or contends
                // with the model the user's next dictation actually needs.
                await TranscriptionService.shared.warmNonSelectedDictationModelsWhenIdle()

                // TAIL of the serial warm chain: opportunistically prefetch the
                // ~190 MB Nemotron 3 diarizer so Speaker Notes is ready when
                // needed (and delete retired features' files first). Positioned dead-last so it never
                // contends with the dictation model loads above; gated to an
                // unmetered (Wi-Fi) path and skipped while a recording/
                // transcription is in flight (prepareIfNeeded downloads AND loads
                // a CoreML graph, same caveat as the non-selected warm). See
                // docs/plans/speaker-notes-productization.md "Model availability".
                RetiredFeatureCleanup.run()
                // TEMPORARY owner test: load Moonshine English if switched on.
                if MoonshineEnglishTest.isEnabled { MoonshineEnglishTest.shared.prepareIfNeeded() }
                DiarizerModelPrefetch.prefetchWhenOnUnmeteredWiFi()


                // TAIL (order-free): resume an in-flight Parakeet-upgrade
                // download-on-charge fetch. Another OUT-OF-PROCESS background
                // URLSession — no ANE contention, position immaterial. No-op
                // unless `AppGroup.parakeetDownloadPending` is set (this fetch is
                // user-initiated via the nudge, never unprompted); presence-checked
                // + idempotent, so it also recovers a force-quit-cancelled fetch.
                ParakeetModelFetcher.shared.resumeIfPending()
            }
        }

        // B1 launch auto-trigger (⚠️REVIEW B1, docs/plans/model-externalization-
        // sub-50mb.md §A3): an EXISTING vocab user whose CTC scorer isn't on
        // disk — because they skipped Build A, restored from iCloud (models are
        // backup-excluded), or landed on the stripped Build B with
        // `isEnabled` persisted true — would otherwise have vocab boosting
        // silently no-op forever (the warm chain above skips `prepare` on
        // `!isCached`, and `rescore()` returns nil with no spotter). They
        // already CONSENTED to vocab boosting; re-fetching its model completes
        // that choice rather than being a new download decision. Download it
        // unprompted. This is NETWORK work (not ANE), so it runs on its OWN
        // detached task PARALLEL to the serial cold-load chain — it must never
        // serialize behind minutes of model loads. Only the LOAD/prepare AFTER
        // the download respects the chain (we `awaitWarmSettled()` first). In
        // Build A the bundle satisfies `isCached`, so this is a no-op.
        Task.detached(priority: .utility) {
            guard await VocabularyStore.shared.isEnabled,
                  !CtcModelCache.shared.isCached else { return }
            // Wi-Fi-only gate (adversarial review of Build A, HIGH): this is an
            // UNPROMPTED ~99 MB fetch — FluidAudio's DownloadUtils session
            // allows cellular by default, and the plan's invariant #4 ("no
            // silent cellular spend") exempts only user-INITIATED downloads.
            // On an expensive/constrained path, park and retry next launch;
            // the vocab-Settings download row remains the user-initiated
            // any-network escape hatch.
            guard await JotApp.currentPathIsUnmetered() else {
                DiagnosticsLog.record(
                    source: "main-app", category: .modelLoad,
                    message: "vocab CTC auto-download deferred — metered network"
                )
                return
            }
            do {
                _ = try await CtcModelCache.shared.ensureDownloaded()
            } catch {
                // Best-effort — a failed/again-offline fetch retries next launch
                // (presence-checked, no stuck flag). The user can also force it
                // by opening vocab Settings, which shows the same download row.
                return
            }
            // Serialize the ANE load/prepare behind the warm chain so the CTC
            // scorer's CoreML specialization never contends with dictation.
            await TranscriptionService.shared.awaitWarmSettled()
            guard await VocabularyStore.shared.isEnabled,
                  CtcModelCache.shared.isCached,
                  let vocabURL = await VocabularyStore.shared.fileURL else { return }
            try? await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: vocabURL)
        }

        // Per-launch defensive: exclude FluidAudio's downloaded speech-model
        // weights from iCloud Device Backup. The weights live at
        // `Library/Application Support/FluidAudio/Models/` (NOT in Caches/
        // — deliberate, because Application Support is sticky and the OS
        // doesn't evict it under memory pressure). Without this flag, the
        // Parakeet 600M v2 weights (~2 GB on disk after CoreML compilation)
        // get included in the user's iCloud backup. Idempotent: setting an
        // already-set flag is a no-op; the call is also a no-op when the
        // directory doesn't exist (user hasn't downloaded any variant yet).
        BackupExclusion.excludeFluidAudioModels()

        // Per-launch defensive: same recursive backup-exclusion sweep for the
        // 3-day retained source audio (`RetainedAudio/` in the App Group
        // container). `RetainedAudioStore` excludes each file at write time,
        // but write-time-only exclusion is what let the FluidAudio weights leak
        // into iCloud Device Backup in 1.0.2 — so retained audio (which
        // accumulates ~1.9 MB/min for 3 days) gets the identical per-launch
        // re-assert. No-op when nothing has been retained yet. Idempotent.
        BackupExclusion.excludeRetainedAudio()


        // One-shot cleanup: drop any stale `BGTaskRequest`s iOS may still hold
        // for background tasks Jot no longer registers — the pre-build-47 Qwen
        // classifier and the EmbeddingGemma backfill (retired with the move to
        // Core Spotlight retrieval). Specific-identifier cancels + a one-shot
        // guard, so nothing else's pending requests are touched.
        let bgCleanupKey = "jot.didCleanLegacyBGRequests_v2"
        if !UserDefaults.standard.bool(forKey: bgCleanupKey) {
            for identifier in [
                "com.vineetu.jot.mobile.Jot.classify-transcripts",
                "com.vineetu.jot.mobile.Jot.backfill-embeddings",
            ] {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            UserDefaults.standard.set(true, forKey: bgCleanupKey)
        }


        // UserDefaults cleanup: drop residual keys from retired features — the
        // Qwen classifier Lab toggle, the embeddings kill-switch, the Qwen
        // rewrite-provider and Ask-backend selectors. Idempotent —
        // `removeObject` on a missing key is a no-op, so this can stay forever.
        for key in [
            "jot.classifier.enabled",
            "jot.embeddings.enabled",
            "jot.ai.rewriteProvider",
            "jot.ask.backend",
        ] {
            AppGroup.defaults.removeObject(forKey: key)
        }

        // One-shot migration: reclaim ~530 MB of Application Support disk
        // from upgrading users whose pre-bundle (0.9.0/0.9.1) installs had
        // 110M weights cached on disk. Gated by a `UserDefaults` flag so
        // this runs at most once. Does NOT touch the v2 (600M) cache.
        TranscriptionService.sweepLegacyAppSupportWeights()

        // One-shot migration: reclaim ~1.1 GB of Nemotron 0.6B weights
        // (~564 MB for 560ms encoder × possibly two variants if the user
        // tried both 1120ms + 560ms during 1.0.2 22–26 TestFlight). The
        // variant was on-device-tested and ripped because Nemotron on
        // iPhone was 3–5x slower than real-time (10–15s tails after
        // stop). Gated by a `UserDefaults` flag — runs at most once.
        TranscriptionService.sweepNemotronAppSupportWeights()

        // §A carry-forward (docs/plans/model-externalization-sub-50mb.md §A1):
        // copy the TWO bundled models — Parakeet 600M v2 and the CTC 110M
        // vocabulary scorer — into the exact private directories a future
        // stripped build's loaders fall through to, so the eventual bundle
        // strip (Build B) is a zero-download data move. v2 is gated on
        // Parakeet-capable devices; CTC copies on every device (vocab works on
        // all hardware). Each is gated on its bundle still shipping (this build
        // STILL bundles both — NOT the strip). EmbeddingGemma is gone: Ask
        // retrieval is Core Spotlight now.
        // Idempotent presence+verify check every launch, serial + off the main
        // thread, atomic temp→verify→rename; a no-op once complete.
        ModelCarryForward.runAllIfNeeded()

        // One-shot migrations: reclaim the dead weights of every retired
        // model backend — Phi-4 mini (~2.4 GB) and Qwen 3.5 (~2.5 GB) in the
        // HuggingFace cache, EmbeddingGemma (~330 MB) under CoreMLLLM/.
        // Rewrite and Ask run on Apple Foundation Models now; nothing here
        // is needed. Each leg is flag-gated to run at most once per install.
        LegacyModelPurge.runAllIfNeeded()

        // One-shot migration: overwrite the bundled Articulate prompt's
        // copy with the current canonical text (matched by stable UUID).
        // Pre-launch — no production user edits to preserve. Gated by a
        // `UserDefaults` flag so this runs at most once per install.
        SavedPromptStore.migrateArticulatePromptIfNeeded()

        // One-shot migration: insert the new "AI prompt" default into
        // existing users' prompt lists at sortOrder 1 (after Articulate,
        // before Action Items). Gated by `jot.didAddAIPromptDefault`.
        // Fresh installs flow through `seedIfNeeded` which already seeds
        // the full 4-prompt set.
        SavedPromptStore.migrateAddAIPromptIfNeeded()

        // Eager warm-up of the bundled speech models so the wizard's
        // "Try It" panel (W7) doesn't pay the ANE-load + Metal-kernel-JIT
        // tax on the first dictation tap. Both `warmUp()` calls are
        // idempotent — running them once at launch is a no-op if they
        // were already warm, and the scene-activation `.task` block
        // below covers the post-init reload path. Dispatched as
        // non-blocking MainActor tasks so app launch isn't held up while
        // CoreML compiles kernels.
        //
        // App Review 4.2.3(ii) safety: gated on `modelsExistOnDisk` so
        // an un-downloaded opt-in 0.6B v2 variant does NOT silently
        // trigger a first-launch network download. The default Parakeet
        // TDT-CTC 110M and the streaming EOU weights both ship bundled
        // in the IPA, so the gate is constant-true on the default
        // variant — which is the variant that matters for the W7
        // perceived-latency fix. NOT gated on `SetupCompletion` because
        // W7 itself runs DURING setup; gating on completion would defeat
        // the purpose.
        //
        // Failure is internally handled by `warmUp()` (flips
        // `modelState = .failed`); the task body cannot throw.
        // Seed the recent-languages MRU with the active language once, so the
        // first language switch keeps the prior language in the quick-switch list.
        LanguageChoice.seedRecentsIfNeeded()

        let warmTranscription = transcription
        Task(priority: .userInitiated) { @MainActor in
            // Unified warm path: `warmIfNeeded()` owns the on-disk gate
            // (preserves 4.2.3(ii)) + the cold-state check, so the same predicate
            // drives launch, scene-activation, and the wizard.
            warmTranscription.warmIfNeeded()
        }

        // (EmbeddingGemma prewarm now runs LAST in the serial cold-load Task
        // above — Parakeet → vocab → embeddings — so it no longer contends with
        // Parakeet's ANE specialization at cold start.)

        // Reset any leftover non-terminal pipeline-phase projection from a
        // crashed previous launch. Without this reset, the keyboard would
        // observe a stale non-idle phase on first appearance and only recover
        // via the 30s stale-deadline. The pipeline phase is now the SINGLE
        // source of truth for cross-process recording state — `.idle` (or
        // unset) means "no recording in flight"; the keyboard derives
        // `isRecording` from `phase == .recording` rather than reading a
        // separate projection. Per design §4.2.
        // Also clears any leftover warm-hold (`.warmIdle`) record from a crash
        // mid-warm — the record is the single source of truth (warm-hold never
        // auto-activates on cold launch), so `reset()` alone now covers the
        // stale-clear the legacy `warmHoldExpiresAt`-on-launch did before B4.
        PipelinePhaseProjection.reset()
        // Activate the phone-side WatchConnectivity session so the
        // paired watch can transfer audio files in + the iPhone can
        // push top-10 transcripts back. Safe to call even if no watch
        // is paired (WCSession.isSupported() guards inside).
        PhoneSideWCSession.shared.activate()
        lifecycleLog.info("JotApp init — services constructed (no I/O)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                isWizardPresented: showSetupWizard,
                pendingExternalKeyboardHero: $pendingExternalKeyboardHero
            )
                .environment(recordingService)
                .environment(transcriptionService)
                .environment(streamingPartial)
                .environment(cleanupService)
                .environment(keyboardRewriteRouter)
                .environment(router)
.fullScreenCover(isPresented: $showSetupWizard) {
                    SetupWizardView {
                        setupCompleted = SetupCompletion.isCompleted
                        showSetupWizard = false
                    }
                    .environment(transcriptionService)
                    // Phase 6: W5 (keyboard dictation test) wires through the
                    // production `RecordingService.shared` so the user
                    // exercises the same recording path they'll use after
                    // setup. The wizard reads it via `@Environment`.
                    .environment(recordingService)
                    // W5 renders `streamingPartial.streamingText` as the
                    // live preview while recording. Without this injection
                    // the wizard would hit an `@Environment` lookup miss
                    // and crash on read; the production singleton is the
                    // one the recorder's tap is already publishing into,
                    // so the wizard sees the same stream the home surface
                    // does.
                    .environment(streamingPartial)
                }
                .onAppear {
                    presentSetupIfNeeded()
                }
                .alert(
                    "Couldn't start recording",
                    isPresented: Binding(
                        get: { dictateAutoStartError != nil },
                        set: { if !$0 { dictateAutoStartError = nil } }
                    ),
                    presenting: dictateAutoStartError
                ) { _ in
                    Button("OK", role: .cancel) {
                        dictateAutoStartError = nil
                    }
                } message: { message in
                    Text(message)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A note tapped in system Spotlight (Core Spotlight index —
                    // `TranscriptSpotlightIndex`). Same open path as the
                    // keyboard's `jot://transcript` recents tap.
                    guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let id = UUID(uuidString: raw) else { return }
                    keyboardRewriteRouter.setPendingOpenTranscript(id: id, autoRewrite: false)
                }
                .onOpenURL { url in
                    guard url.scheme == "jot" else { return }
                    // `jot://history` — keyboard's "See all" recents-card
                    // header link. Brings the main app to the foreground at
                    // home (where the recents list lives) WITHOUT triggering
                    // dictation auto-start. The app's home view is the
                    // default scene root, so simply returning here is enough
                    // to land the user on the recents list.
                    if url.host == "history" {
                        return
                    }

                    // `jot://transcript?id=<uuid>[&ai=1]` — keyboard's
                    // row-trailing affordance on a recents row. Brings the main
                    // app to the foreground and pushes the transcript detail
                    // view for the given id. No dictation auto-start. Route via
                    // the shared router so ContentView's `.onChange` observer
                    // appends to `navPath`; same bridge the rewrite handoff
                    // uses, just for a "view" instead of a "rewrite" intent.
                    //
                    // `ai=1` (the Apple Intelligence button, features.md §5.2)
                    // additionally asks the detail view to run the rewrite on
                    // arrival (Cleanup prompt on Apple Intelligence) — or, when
                    // the note already has one, to land on the Rewrite tab.
                    if url.host == "transcript" {
                        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let idParam = comps.queryItems?.first(where: { $0.name == "id" })?.value,
                           let id = UUID(uuidString: idParam) {
                            let wantsAI = comps.queryItems?.first(where: { $0.name == "ai" })?.value == "1"
                            keyboardRewriteRouter.setPendingOpenTranscript(id: id, autoRewrite: wantsAI)
                        }
                        return
                    }

                    // `jot://upgrade-engine` — the keyboard's Parakeet-upgrade
                    // nudge "Switch" tap (deferred-engineering follow-up to the
                    // Apple Dictation A/B spike). No dictation auto-start —
                    // just present the upgrade screen.
                    if url.host == "upgrade-engine" {
                        router.showUpgradeEngine = true
                        return
                    }

                    // `jot://vocabulary` — the keyboard's Vocabulary-adoption
                    // nudge "Set up" tap. No dictation auto-start — just
                    // present the Vocabulary settings screen (opt-in; the
                    // user flips the toggle / adds terms there).
                    if url.host == "vocabulary" {
                        router.showVocabularySettings = true
                        return
                    }

// Explicit user intent — bypass the once-per-session gate.
                    autoStartConsumed = false
                    // v7 auto-paste: parse `?session=<uuid>` off the keyboard's
                    // launch URL. Stashed onto App state (not consumed by the
                    // first `triggerAutoStart` turn) so model-not-ready retries
                    // via `.onChange(of: modelState)` re-read this stash and
                    // the session ID survives the cold-launch race. Per design
                    // §4.2.
                    if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let sessionParam = comps.queryItems?.first(where: { $0.name == "session" })?.value,
                       let sid = UUID(uuidString: sessionParam) {
                        pendingKeyboardSessionID = sid
                    }
                    // The keyboard opened Jot from another app (any jot://dictate
                    // open = no warm mic, cold OR warm process). Flag it so
                    // ContentView presents the Hero with the looping swipe-back
                    // cue. One-shot; ContentView clears it after consuming.
                    pendingExternalKeyboardHero = true
                    triggerAutoStart(reason: "url open: \(url.absoluteString)")
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: Self.warmResumeFallbackNotification
                    )
                ) { notification in
                    let fallbackReason = notification.userInfo?["reason"] as? String
                        ?? "warm resume fallback requested"
                    triggerAutoStart(reason: fallbackReason)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .jotDictateFromShortcut)
                ) { _ in
                    // A foreground dictation App Intent's START leg fired. If Jot
                    // is ALREADY foreground, start now — no new scene-`.active`
                    // transition will fire to trigger the deferred path in
                    // `handleSceneActive`. If not active yet, do nothing here:
                    // `handleSceneActive` consumes the pending flag on the next
                    // `.active`. (Issue #3 — start is always scene-active-gated.)
                    guard scenePhase == .active,
                          DictationIntentBridge.shared.pendingForegroundStart else { return }
                    DictationIntentBridge.shared.pendingForegroundStart = false
                    autoStartConsumed = false
                    triggerAutoStart(reason: "app shortcut dictation (already foreground)")
                }
                .onChange(of: setupRerunTrigger.requestID) { _, _ in
                    setupCompleted = false
                    showSetupWizard = true
                }
                .onChange(of: setupCompleted) { _, completed in
                    if completed {
                        if autoStartPendingSetupComplete {
                            autoStartPendingSetupComplete = false
                            lifecycleLog.notice("AUTOSTART: guard=setup action=continue reason=setup completed, retrying")
                            triggerAutoStart(reason: "setup completed, retrying")
                            return
                        }
                        // Land the user on the home view after finishing
                        // setup rather than auto-starting a recording —
                        // dropping straight into the hero record screen
                        // before they've seen the app's home is
                        // disorienting. Marking `autoStartConsumed = true`
                        // also suppresses the once-per-session
                        // scene-activation auto-start so a quick
                        // background/foreground cycle right after setup
                        // doesn't trigger it through the back door.
                        autoStartConsumed = true
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    // `initial: true` fires on first attach so the heartbeat
                    // starts even when the scene is already `.active` before
                    // the modifier wires up — without it, `onChange` would
                    // never fire on initial render and the keyboard's
                    // `isJotAppForeground()` would return false during a cold
                    // W7 entry. Initial-fire on `.active` just kicks the same
                    // flow that would normally fire on transition.
                    if newPhase == .active {
                        handleSceneActive()
                        startForegroundHeartbeat()
                        // M2 (§2.4) — reconcile a session iOS suspended us in the
                        // middle of. Strictly gated on the app's OWN record being
                        // non-idle AND its `liveness` STALE (the suspension gap),
                        // so it can NEVER touch a healthy/just-foregrounded live
                        // recording (those stamp liveness within the window). Same
                        // next-foreground-drain shape as the inboxes below; finalizes
                        // the orphan gently (never forceStop, never an app-wake).
                        recordingService.reconcileOrphanedSessionOnForeground()
                        // Transcribe anything shared into Jot via the share
                        // sheet while we were away. The "Send to Jot" Share
                        // Extension only stages the audio (it can't run
                        // Parakeet); we turn it into a transcript here, on
                        // foreground (Model B — the extension never opened us).
                        PendingShareDrainer.drain()
                        Task { @MainActor in
                            // One-time: drop rules learned for everyday words
                            // before the learning guard existed (no-op once done).
                            await AppVocabCore.migrateCommonOriginalRulesIfNeeded()
                            // One-time: pairs learned from edits before the
                            // vocabulary list became their only home move into
                            // it as sounds-likes (no-op once done).
                            await AppVocabCore.migrateEditLearnedPairsIfNeeded()
                            // Finalize any words the user added to vocabulary
                            // from the keyboard's "..." popover while we were
                            // away (vocab storage is main-app-private; the
                            // keyboard only queues `Correction`s).
                            await VocabularyAddInbox.drain()
                            // Apply any correction verdicts the owner gave in the
                            // keyboard quick-review while Jot was backgrounded.
                            await CorrectionInbox.drain(modelContext: ModelContext(JotModelContainer.shared))
                        }
                    } else if newPhase == .background {
                        // Tear down ONLY on a true background. `.inactive` is
                        // transient — a custom keyboard taking focus, a banner,
                        // Control Center — and Jot is still effectively the
                        // foreground app. Clearing the heartbeat on `.inactive`
                        // made `isJotAppForeground()` read false while the Jot
                        // keyboard was up, so a Dictate tap INSIDE Jot bounced to
                        // the hero instead of recording inline. Keep it alive
                        // through `.inactive`; only `.background` clears it.
                        stopForegroundHeartbeat()
                    }
                    // Intentionally NO forceStop on .background: iOS lets us keep
                    // recording in the background (Info.plist UIBackgroundModes
                    // includes "audio"), and the user expects swipe-back-to-host
                    // to keep the mic live until they explicitly tap stop. The
                    // earlier defensive forceStop on background was killing
                    // legitimate background recordings.
                }
                .onChange(of: transcriptionService.modelState) { _, newState in
                    guard newState == .ready, autoStartPendingModelReady else { return }
                    autoStartPendingModelReady = false
                    lifecycleLog.notice("AUTOSTART: guard=model-ready action=continue reason=model became ready, retrying")
                    triggerAutoStart(reason: "model became ready")
                }
                .onChange(of: recordingService.isPipelineInFlight) { _, inFlight in
                    guard !inFlight, autoStartPendingPipelineFinish else { return }
                    autoStartPipelineDrainTimeoutTask?.cancel()
                    autoStartPipelineDrainTimeoutTask = nil
                    autoStartPendingPipelineFinish = false
                    lifecycleLog.notice("AUTOSTART: guard=pipeline action=continue reason=pipeline drained, retrying")
                    triggerAutoStart(reason: "pipeline drained, retrying")
                }
                // Eager Parakeet preload. `.task` fires on first scene
                // activation — earliest post-init hook without blocking launch,
                // and the ban on I/O inside `JotApp.init()` still holds.
                //
                // `warmUp()` is gated on (a) the user having finished
                // the setup wizard, AND (b) the models being on disk.
                // The default speech model ships bundled in the IPA so
                // (b) is constant-true on the default variant; the gate
                // matters only for the opt-in Parakeet 0.6B v2 variant
                // and is the App-Review-4.2.3(ii)-safe path for that
                // download. If the bundle is somehow missing, the
                // wizard re-presents on next launch.
                //
                // Cold-launch mirror refresh: regenerates the App Group JSON
                // projection the keyboard reads on `viewWillAppear`. Without
                // this, a fresh install / post-reinstall keyboard would show
                // "No dictations yet" until the next main-app dictation
                // triggered an incremental refresh via `TranscriptStore.append`.
                // Bootstrapping here makes history visible in the keyboard
                // immediately after first launch of the main app.
                .task {
                    // Default Parakeet TDT-CTC 110M ships bundled in the
                    // IPA, so `modelsOnDisk` is constant-true on the
                    // default variant. For the 0.6B v2 opt-in variant it
                    // reflects the actual Application Support cache and
                    // gates eager warm-up so an un-downloaded opt-in
                    // doesn't trigger a silent first-launch download
                    // (Guideline 4.2.3(ii)).
                    // Unified warm path: gate on models-on-disk (preserves
                    // 4.2.3(ii)), NOT setup-completion — so the SAME predicate
                    // warms app-open AND the wizard. `warmIfNeeded()` is the one
                    // place that gate lives. (`init()` also warms on cold launch;
                    // this is the scene-attach trigger. Idempotent.)
                    transcriptionService.warmIfNeeded()
                    // Request Speech authorization early so the one-time
                    // permission prompt appears at launch rather than
                    // interrupting the first Apple dictation. On a real device
                    // the Apple engine can't subscribe to a transcription asset
                    // without this grant ("not subscribed to transcription.…").
                    Task { _ = await AppleStreamingSession.ensureSpeechAuthorization() }
                    // Resolve which dictation languages actually work on THIS
                    // device (RULE #1 — never show a language or Parakeet-
                    // download affordance that can't run here) before the
                    // language pickers first render. Cheap + cached; a picker
                    // opened before this completes just awaits its own
                    // `.task` copy of `resolve()` (idempotent).
                    Task { await DictationLanguageAvailability.resolve() }
                    TranscriptHistoryMirror.refresh(
                        from: ModelContext(JotModelContainer.shared)
                    )
                    // Core Spotlight projection of every note (system search +
                    // Ask's retrieval). Detached + version-gated: a no-op on
                    // every launch after the first, or after an index-mapping
                    // bump. Spotlight's own reindex requests route through
                    // `CSSearchableIndex.default().indexDelegate`.
                    CSSearchableIndex.default().indexDelegate = TranscriptSpotlightIndex.shared
                    TranscriptSpotlightIndex.reindexAllIfNeeded()
                    // No language-model pre-warm here: rewrites and Ask run
                    // on Apple Foundation Models, which the system keeps
                    // resident out-of-process.
                }
        }
        // Bind the process-wide SwiftData container into the scene so
        // `@Query` and `@Environment(\.modelContext)` resolve to the same
        // store the headless intents write to. `JotModelContainer.shared`
        // is the single source of truth — see its doc for why we don't use
        // `.modelContainer(for: Transcript.self)` here (headless intents
        // write without a scene, and that flavor of the modifier constructs
        // a per-scene container).
        .modelContainer(JotModelContainer.shared)
    }

    private func presentSetupIfNeeded() {
        setupCompleted = SetupCompletion.isCompleted
        showSetupWizard = !setupCompleted
    }

    /// Starts (or restarts) the foreground heartbeat that publishes a
    /// recent `Date` into `AppGroup.Keys.appForegroundHeartbeat` every
    /// ~1s. The keyboard extension reads this slot to decide whether
    /// the host app is Jot itself — see `AppGroup.isJotAppForeground()`.
    ///
    /// Idempotent: tears down any previous task first so a flapping
    /// `scenePhase` (active → inactive → active) doesn't leak parallel
    /// heartbeat loops. Writes once immediately on start so a keyboard
    /// tap inside W7 sees a fresh heartbeat without waiting up to a full
    /// second for the first loop tick.
    private func startForegroundHeartbeat() {
        heartbeatTask?.cancel()
        // First write happens synchronously here so the heartbeat is
        // already fresh before the first `Task.sleep` returns. Without
        // this, the keyboard's first `isJotAppForeground()` read after
        // the main app foregrounds could miss the 2.5s window on a
        // pathologically-slow first loop iteration.
        AppGroup.defaults.set(
            Date(),
            forKey: AppGroup.Keys.appForegroundHeartbeat
        )
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                // 1s cadence — well inside the 2.5s freshness window
                // `AppGroup.isJotAppForeground()` allows, leaving margin
                // for one missed tick (Task scheduling jitter).
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                AppGroup.defaults.set(
                    Date(),
                    forKey: AppGroup.Keys.appForegroundHeartbeat
                )
            }
        }
    }

    /// Cancels the foreground heartbeat and clears the App Group key so
    /// the keyboard immediately observes "host is not Jot" on the next
    /// `isJotAppForeground()` read. Called on `scenePhase` transitions
    /// out of `.active` (background, inactive).
    private func stopForegroundHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        AppGroup.defaults.removeObject(
            forKey: AppGroup.Keys.appForegroundHeartbeat
        )
    }


    private func handleSceneActive() {
        // A foreground dictation App Intent (RecordAndTranscribeIntent /
        // DictateIntent) requested a start. Now that the scene is confirmed
        // `.active` (the app is genuinely foreground), run it through the
        // scene-gated `triggerAutoStart` path — NOT inline in the intent's
        // `perform()`, which races the foreground transition and fails with
        // CoreAudio "engine failed to start" (GitHub issue #3). `triggerAutoStart`
        // handles setup / mic-permission / model-not-ready (capture-first) itself.
        if DictationIntentBridge.shared.pendingForegroundStart {
            DictationIntentBridge.shared.pendingForegroundStart = false
            autoStartConsumed = false
            triggerAutoStart(reason: "app shortcut dictation (scene active)")
            return
        }

        guard SetupCompletion.isCompleted else {
            setupCompleted = false
            showSetupWizard = true
            return
        }
        setupCompleted = true
        // No auto-start on plain app launch / scene activation. The
        // user explicitly starts a recording by tapping the mic on the
        // home view, or via the keyboard's "Start dictate" handoff
        // (which routes through `.onOpenURL` and calls
        // `triggerAutoStart` directly with its own gate reset — that
        // path is untouched by this change).
    }

    private static func describeAutoStartError(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func logAutoStartGuard(
        _ guardName: String,
        action: String,
        reason: String
    ) {
        lifecycleLog.notice("AUTOSTART: guard=\(guardName, privacy: .public) action=\(action, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func surfaceAutoStartBanner(
        _ message: String,
        guardName: String,
        action: String = "banner",
        reason: String,
        clearPendingIntent: Bool = true
    ) {
        logAutoStartGuard(guardName, action: action, reason: reason)
        AppGroup.lastDictationStatusMessage = message
        if clearPendingIntent {
            pendingKeyboardSessionID = nil
            ClipboardHandoff.clearPendingPasteSession()
        }
    }

    private func queueAutoStartUntilSetupCompletes(reason: String) {
        autoStartPendingSetupComplete = true
        setupCompleted = false
        showSetupWizard = true
        AppGroup.lastDictationStatusMessage = "Finish Jot setup to start dictation"
        logAutoStartGuard(
            "setup",
            action: "defer",
            reason: "setup incomplete; queued pending dictate intent from \(reason)"
        )
    }

    private func requestMicPermissionAndRetry(reason: String) {
        guard !autoStartMicPermissionRequestInFlight else {
            logAutoStartGuard(
                "mic-permission",
                action: "defer",
                reason: "permission request already in flight; keeping pending dictate intent"
            )
            return
        }

        autoStartMicPermissionRequestInFlight = true
        logAutoStartGuard(
            "mic-permission",
            action: "defer",
            reason: "permission undetermined; requesting live microphone permission for \(reason)"
        )

        Task { @MainActor in
            let granted = await AVAudioApplication.requestRecordPermission()
            autoStartMicPermissionRequestInFlight = false
            if granted {
                logAutoStartGuard(
                    "mic-permission",
                    action: "continue",
                    reason: "permission granted, retrying"
                )
                triggerAutoStart(reason: "microphone permission granted, retrying")
            } else {
                surfaceAutoStartBanner(
                    "Turn on mic access for Jot in Settings.",
                    guardName: "mic-permission",
                    action: "deny",
                    reason: "permission denied after request; surfaced settings banner"
                )
            }
        }
    }

    private func deferAutoStartUntilPipelineDrains(reason: String) {
        autoStartPendingPipelineFinish = true
        autoStartPipelineDrainTimeoutTask?.cancel()
        logAutoStartGuard(
            "pipeline",
            action: "defer",
            reason: "pipeline in flight; queued pending dictate intent from \(reason)"
        )

        autoStartPipelineDrainTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }

            guard autoStartPendingPipelineFinish else { return }
            autoStartPipelineDrainTimeoutTask = nil

            if recordingService.isPipelineInFlight {
                autoStartPendingPipelineFinish = false
                surfaceAutoStartBanner(
                    "Still finishing your last dictation - tap again",
                    guardName: "pipeline",
                    action: "banner",
                    reason: "pipeline drain exceeded 5s; cleared pending dictate intent"
                )
            } else {
                autoStartPendingPipelineFinish = false
                logAutoStartGuard(
                    "pipeline",
                    action: "continue",
                    reason: "pipeline drained before timeout, retrying"
                )
                triggerAutoStart(reason: "pipeline drained, retrying")
            }
        }
    }

    private func triggerAutoStart(reason: String) {
        // Consume the session gate FIRST. Even if we bail below
        // (model loading, recording in flight, no permission), this
        // counts as the one-shot for this session — a later
        // resume-from-background must not retry.
        autoStartConsumed = true

        guard SetupCompletion.isCompleted else {
            queueAutoStartUntilSetupCompletes(reason: reason)
            return
        }
        setupCompleted = true

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            requestMicPermissionAndRetry(reason: reason)
            return
        case .denied:
            surfaceAutoStartBanner(
                "Tap to grant mic access in Settings",
                guardName: "mic-permission",
                action: "deny",
                reason: "live permission denied for \(reason)"
            )
            return
        @unknown default:
            surfaceAutoStartBanner(
                "Couldn't check mic access - tap again",
                guardName: "mic-permission",
                action: "banner",
                reason: "unknown live permission state for \(reason)"
            )
            return
        }

        guard !recordingService.isRecording else {
            logAutoStartGuard(
                "isRecording",
                action: "continue",
                reason: "recording already active; tap is already satisfied"
            )
            return
        }
        guard !recordingService.isPipelineInFlight else {
            deferAutoStartUntilPipelineDrains(reason: reason)
            return
        }

        // Capture-first cold start: if the model isn't loaded yet, kick the
        // load but DO NOT wait — start the mic NOW so audio buffers through the
        // (cold) load and nothing said is lost. The model loads in parallel and
        // is awaited at stop time (`runInference` → `ensurePreparing().value`),
        // so the transcript is complete even if the user stops mid-load.
        // Publishing `.recording` immediately also lights up the keyboard's
        // "Loading… keep speaking" strip. `warmUp()` is idempotent (shares one
        // prepare Task), so kicking it here is safe even if the scene `.task`
        // also calls it. (Previously this returned and deferred the start until
        // modelState == .ready, leaving the mic OFF through a ~30s cold load and
        // showing only "Getting ready…" — features.md §14.1 /
        // docs/plans/bug-cold-start-dictation-race.md.)
        if transcriptionService.modelState != .ready {
            transcriptionService.warmUp()
            logAutoStartGuard(
                "model-ready",
                action: "continue",
                reason: "model not ready; capture-first — mic starts now, load kicked in parallel, from \(reason)"
            )
        }

        autoStartPendingModelReady = false

        Task { @MainActor in
            guard !recordingService.isRecording else {
                logAutoStartGuard(
                    "isRecording",
                    action: "continue",
                    reason: "recording became active before start; tap is already satisfied"
                )
                return
            }
            guard !recordingService.isPipelineInFlight else {
                deferAutoStartUntilPipelineDrains(reason: reason)
                return
            }
            do {
                if recordingService.isWarm {
                    logAutoStartGuard(
                        "warm-hold",
                        action: "continue",
                        reason: "warm hold active; preserving hot engine for start"
                    )
                } else {
                    recordingService.forceStop()
                }
                // v7 auto-paste: adopt the keyboard's session UUID (stashed
                // off the launch URL by the `onOpenURL` handler) BEFORE
                // `start()` so the upcoming pipeline writes carry the
                // keyboard's session ID. The published `FreshDictation.sessionID`
                // then matches the keyboard's `PendingPasteSession.id` in
                // `flushPendingAutoPasteIfPossible`. If no session was
                // stashed (e.g., user manually opened jot://dictate from
                // Shortcuts, or a non-keyboard entry point), generate a
                // fresh UUID — degraded but functional: the keyboard's
                // pending (if any) won't match this random UUID and will
                // fall through to the §4.6.G launch-deadline cleanup.
                let sid = pendingKeyboardSessionID ?? UUID()
                pendingKeyboardSessionID = nil
                recordingService.adoptSession(sid)
                let startedAt = Date()

                // 2.5.14 hardening (Cut A §6.3): the Live Activity / Dynamic
                // Island chip is requested BEFORE `recording.start()` activates
                // the audio session, so the system mic indicator and the chip
                // come up paired. Activating the session first would briefly
                // light the orange mic indicator before the chip is rendered;
                // App Review can flag that no-chip window as a 2.5.14
                // disclosure inconsistency.
                //
                // The team-lead brief is explicit on BEFORE-ordering despite
                // the spec sketch (§6.3 line 753-755) showing AFTER. The
                // brief's reasoning (no-chip window) is the controlling one
                // because brief-vs-spec conflict resolves in favor of the brief.
                //
                // Trade-off: if `recording.start()` throws, the activity is
                // orphaned. Caught by the catch block below via
                // `cancelPendingRecordingStart()`, which ends the activity
                // cleanly.
                await DictationActivityCoordinator.shared.start(startedAt: startedAt)
                do {
                    lifecycleLog.notice("RECORDING START FROM: triggerAutoStart reason=\(reason, privacy: .public)")
                    try await startRecordingRetryingColdLaunchMicRace(reason: reason)
                    AppGroup.lastDictationStatusMessage = nil
                    lifecycleLog.info("Auto-started recording after \(reason, privacy: .public) session=\(sid, privacy: .public)")
                } catch {
                    // Recording failed AFTER the LA was requested. Tear down
                    // the orphaned activity so the user doesn't see a chip
                    // with no recording behind it.
                    await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
                    throw error
                }
            } catch {
                lifecycleLog.error("Auto-start recording failed: \(error.localizedDescription, privacy: .public)")
                // Friendly, single-source message — the keyboard banner finally
                // shows the REAL reason (e.g. the mic-busy "another app like a
                // call is using it" copy) instead of the old generic
                // "Couldn't start mic - tap again" that erased which error fired.
                let friendlyMessage = (error as? RecordingService.RecordingError)?.userFacingMessage
                    ?? "Couldn't start recording — try again."
                surfaceAutoStartBanner(
                    friendlyMessage,
                    guardName: "start",
                    action: "banner",
                    reason: "recording start threw: \(Self.describeAutoStartError(error))"
                )
                // Foreground user feedback. The keyboard banner above is read
                // by the keyboard extension on its next presentation; if the
                // user is currently in the main app (e.g. dictate tap just
                // launched us), they need their own surface. The alert in
                // ContentView reads this and clears it on dismiss. Same
                // friendly message so both surfaces match.
                dictateAutoStartError = friendlyMessage
            }
        }
    }

    /// Cold-launch HAL race: when the keyboard's `jot://dictate` URL bounce
    /// wakes a terminated main app, iOS's audio HAL isn't always booted on
    /// the first run of the runloop — `recordingService.start()`'s own
    /// mic-availability preflight (`inputNode.outputFormat(forBus: 0)`
    /// reporting 0 channels / 0 Hz) throws `.micUnavailable`. The old fix was
    /// a single fixed 700ms sleep then one retry — a blind guess that could
    /// still lose the race, and gave up after exactly one more try.
    ///
    /// Instead, poll on the REAL signal: `start()` re-runs that same
    /// preflight against the input node fresh on every call, so retrying
    /// `start()` itself IS checking whether the HAL has come up — there's no
    /// separate "is the mic ready" probe to key off, this is the actual
    /// value. Loop at `coldLaunchMicRetryInterval` up to
    /// `coldLaunchMicRetryCeiling` total, succeeding the instant an attempt
    /// gets past the preflight. The happy path (mic ready immediately) is
    /// unaffected — first attempt returns with zero added delay.
    ///
    /// If the ceiling is hit, `.micUnavailable` propagates out unchanged so
    /// the existing "mic busy" banner still fires for a genuinely
    /// unavailable mic (e.g. another app holding it for a call) — this only
    /// shrinks the false-positive window caused by the cold-launch race.
    private func startRecordingRetryingColdLaunchMicRace(reason: String) async throws {
        let deadline = Date().addingTimeInterval(Self.coldLaunchMicRetryCeiling)
        var attempt = 0
        while true {
            do {
                try await recordingService.start()
                if attempt > 0 {
                    lifecycleLog.notice(
                        "Recording start recovered from micUnavailable after \(attempt) retries (cold-launch HAL race) for \(reason, privacy: .public)"
                    )
                }
                return
            } catch RecordingService.RecordingError.micUnavailable {
                guard Date() < deadline else {
                    lifecycleLog.error(
                        "Recording start still micUnavailable after \(Self.coldLaunchMicRetryCeiling, privacy: .public)s ceiling (\(attempt) retries) for \(reason, privacy: .public); giving up"
                    )
                    throw RecordingService.RecordingError.micUnavailable
                }
                attempt += 1
                try await Task.sleep(nanoseconds: Self.coldLaunchMicRetryIntervalNanos)
            }
        }
    }

    /// Poll cadence for `startRecordingRetryingColdLaunchMicRace`. Short
    /// enough that a HAL boot landing between polls doesn't add perceptible
    /// latency once ready, coarse enough not to spin the run loop on a
    /// prolonged real mic-busy condition.
    private static let coldLaunchMicRetryIntervalNanos: UInt64 = 75_000_000

    /// Ceiling for the same retry loop. Generous beyond any HAL-boot delay
    /// observed on device for a cold-launched app — a genuinely unavailable
    /// mic (call in progress, another app capturing) exhausts this and falls
    /// through to the real "mic busy" error rather than retrying forever.
    private static let coldLaunchMicRetryCeiling: TimeInterval = 2.0

    /// One-shot "is the network unmetered right now" sample for the B1 vocab
    /// CTC auto-download gate. Same rules as `DiarizerModelPrefetch`
    /// (`isExpensive` = cellular/hotspot, `isConstrained` = Low Data Mode),
    /// but one-shot instead of wait-until-satisfied: B1 must not hold a
    /// monitor open across the whole session — if the path is metered NOW it
    /// parks and retries next launch. The monitor lives only until the first
    /// path callback; the lock guards against NWPathMonitor's occasional
    /// rapid double-fire resuming the continuation twice.
    static func currentPathIsUnmetered() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let alreadyResumed = resumed.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyResumed else { return }
                monitor.cancel()
                cont.resume(
                    returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained
                )
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}

@MainActor
private final class CrossProcessRecordingStopCoordinator {
    static let shared = CrossProcessRecordingStopCoordinator()

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "cross-process-recording")
    private var stopTask: Task<Void, Never>?

    private init() {}

    func handleStopRequested() {
        guard stopTask == nil else {
            log.notice("Cross-process stop request ignored because stop is already in flight.")
            return
        }

        // Ask owns this recording via its own `InlineDictationSession`. The
        // keyboard cannot tell Ask's inline session from a capture —
        // `RecordingService.start()` publishes `.recording` for both, so the
        // keyboard's second tap posts `stopRequested` either way. Discriminate
        // here on the in-process ownership flag: an Ask stop finalizes inside
        // Ask (no saved Transcript) — never run the capture pipeline. We just
        // bail before the saving path and clear the keyboard's pending paste so
        // it doesn't hang waiting for a publish that won't come. (In-Jot keyboard
        // taps now take the NORMAL capture path and do NOT set this flag, so
        // they fall through to the saving path below like any other app.)
        if RecordingService.shared.ownsActiveRecording {
            ClipboardHandoff.clearPendingPasteSession()
            log.info("Cross-process stop: inline session owns the recording — finalizing inline, no transcript saved.")
            return
        }

        // v7 auto-paste (per design §4.2 round-2 BLOCKER #4 closure): widen
        // the guard to `(isRecording || isPipelineInFlight)` so the duplicate-
        // stop branch ALSO runs while transcription/cleaning is still in
        // flight (after `stop()` drained samples but before
        // `markPipelineFinished` has been called). With the v6 `isRecording`-
        // only guard, a keyboard tap arriving during the in-flight tail
        // would silently overwrite the App Group's `pendingPasteSession` and
        // never get cleared — the keyboard's NEW pending would hang until
        // the §4.6.G launch-deadline (15s) cleanup fires.
        //
        // The "no pipeline at all" branch must clear the keyboard's NEW
        // pending: the user just wrote a fresh PendingPasteSession expecting
        // a stop-and-paste, but there's no pipeline running for it to attach
        // to and no incoming publish to match. Clearing here is decisive
        // and avoids the 15s hang.
        let recording = RecordingService.shared
        let pipelineActive = recording.isRecording || recording.isPipelineInFlight

        guard pipelineActive else {
            ClipboardHandoff.clearPendingPasteSession()
            publishIdleProjection()
            log.info("Cross-process stop request: no pipeline active; cleared keyboard pending session.")
            return
        }

        stopTask = Task { @MainActor in
            defer { stopTask = nil }

            do {
                try await stopAndPublish()
            } catch {
                RecordingService.shared.markPipelineFinished()
                publishIdleProjection()
                log.error("Cross-process stop request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Keyboard-initiated cancel. Discards the partial transcript and
    /// clears the keyboard's pending paste session so no auto-paste lands.
    /// Uses `RecordingService.cancel()` (not `forceStop`) so the warm-hold
    /// session is preserved — user's mental model is "redo my last
    /// dictation," so the mic stays hot for the next tap.
    func handleCancelRequested() {
        let recording = RecordingService.shared
        // Don't fight a stop that's already in flight — if user tapped
        // Stop then Cancel rapidly, stop wins (the transcript is already
        // being processed). If neither is active, just clear pending and
        // publish idle.
        guard recording.isRecording else {
            ClipboardHandoff.clearPendingPasteSession()
            publishIdleProjection()
            log.info("Cross-process cancel request: no active recording; cleared keyboard pending session.")
            return
        }

        ClipboardHandoff.clearPendingPasteSession()
        Task { @MainActor in
            await recording.cancel()
            // Terminal-publish backstop (controls-hang fix): `cancel()` publishes
            // `.idle` on its happy path, but its early-return guards
            // (`isStopInFlight`, no active slice) can return WITHOUT publishing —
            // which would leave the keyboard waiting forever for a terminal phase.
            // Re-publishing `.idle` here is idempotent on the happy path (already
            // idle) and closes those no-publish holes. The keyboard observes the
            // terminal and flips out of loading.
            if recording.currentPipelinePhase != .idle {
                recording.publishPipelinePhase(.idle)
            }
        }
        log.info("Cross-process cancel: dispatched RecordingService.cancel() — samples discarded, warm-hold preserved if enabled.")
    }

    private func stopAndPublish() async throws {
        let projection = PipelinePhaseProjection.read()
        let controller = DictationIntentBridge.shared.controller
        let recording = RecordingService.shared
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt
            ?? projection?.recordingStartedAt
            ?? Date()

        // unify-keyboard-dictation §3/§4 — the save/no-save discriminator lives
        // HERE, at the keyboard stop site, not at the recording's birth. This
        // method runs ONLY for keyboard-initiated stops (the hero stops by
        // calling `completeEndOfRecording` directly — `RecordingHeroView` — and
        // never reaches this coordinator). So:
        //   • Jot main app ACTIVE at stop  → the user is dictating INTO a Jot
        //     field (Feedback / transcript edit / settings); paste, but write NO
        //     Transcript → `transient = true`.
        //   • Otherwise (.inactive / .background) → cold dictation from ANOTHER
        //     app; paste AND save exactly as today → `transient = false`.
        // We gate on `.active` SPECIFICALLY (not `!= .background`) to make data
        // loss impossible: a cold-from-another-app stop can reach Jot while it is
        // mid-transition / briefly `.inactive`, and treating `.inactive` as
        // transient would DROP that transcript. `.active` is only ever true when a
        // Jot field is the live foreground host, so cold stops never read it and
        // always save. Worst case is the SAFE direction — a Jot-field stop during a
        // rare `.inactive` blip saves a spurious transcript rather than losing one.
        // The hero never funnels through here, so its save is untouched.
        let jotActiveAtStop = UIApplication.shared.applicationState == .active
        log.info("Cross-process stop: jotActiveAtStop=\(jotActiveAtStop, privacy: .public) → transient(no-save)=\(jotActiveAtStop, privacy: .public)")

        // v7 auto-paste: peek the keyboard's pending paste session synchronously
        // at task entry into a local. A subsequent keyboard tap that overwrites
        // the App Group key cannot affect this in-flight stop. Adoption is
        // gated to `.recording` / `.idle` only — when the pipeline is already
        // mid-flight (`.transcribing` / `.processing` / `.cleaning`), we MUST
        // NOT silently re-target the in-flight publish to the keyboard's NEW
        // session ID; that's the cross-session race we're trying to close.
        // Per design §4.2.
        let keyboardPending = readPendingPasteSession()
        let resolvedSessionID: UUID = keyboardPending?.id
            ?? recording.currentSessionID
            ?? UUID()

        DiagnosticsLog.record(
            source: "main-app",
            category: .publishResolved,
            message: "Resolved session ID before publish",
            metadata: [
                "resolvedSessionID": resolvedSessionID.uuidString,
                "keyboardPendingSessionID": keyboardPending?.id.uuidString ?? "<nil>",
                "currentSessionID": recording.currentSessionID?.uuidString ?? "<nil>",
                "controllerPhase": String(describing: controller.currentPhase)
            ]
        )

        switch controller.currentPhase {
        case .recording:
            recording.adoptSession(resolvedSessionID)
            await DictationActivityCoordinator.shared.update(phase: .transcribing)
            let result = try await controller.stopAndTranscribe()
            try await DictationPipeline.completeEndOfRecording(
                transcript: result.transcript,
                sessionID: resolvedSessionID,
                startedAt: startedAt,
                stoppedAt: result.stoppedAt,
                controller: controller,
                transient: jotActiveAtStop,
                retainSamples: result.samples
            )

        case .idle:
            recording.adoptSession(resolvedSessionID)
            try await stopStandaloneRecording(
                startedAt: startedAt,
                sessionID: resolvedSessionID,
                controller: controller,
                transient: jotActiveAtStop
            )

        case .transcribing, .processing, .cleaning:
            // v7 auto-paste (per design §4.2 round-2 BLOCKER #4 closure):
            // pipeline is mid-flight from an OLDER session. We MUST NOT call
            // `adoptSession` here — that would re-target the in-flight
            // publish to the keyboard's NEW session ID and cause the very
            // cross-session race v7 is closing. The keyboard's NEW pending
            // can't attach to this in-flight pipeline (the OLDER publish
            // carries its own session ID and won't match the NEW pending),
            // so clear pending decisively. The user effectively sees: "tap
            // was ignored; nothing pasted; finish in-flight pipeline first."
            ClipboardHandoff.clearPendingPasteSession()
            // Terminal-publish guarantee (controls-hang fix): we deliberately do
            // NOT publish a terminal here. A LIVE older pipeline owns this
            // projection (`.transcribing/.processing/.cleaning`) and will publish
            // its own terminal (`.idle`/`.failed`) on completion — clobbering it
            // with `.idle` now would kill a genuinely-running pipeline. The
            // keyboard does not hang in this branch: it already cleared
            // `stopRequestPosted` the moment it observed the non-`.recording`
            // in-flight phase, and the live pipeline keeps stamping heartbeats so
            // the dead-app watchdog correctly stands down. The terminal the
            // keyboard ultimately observes is the in-flight pipeline's own.
            log.notice("Cross-process stop request mid-pipeline; keyboard pending session cleared (live pipeline owns terminal).")
        }
    }

    /// Reads the keyboard's pending paste session record. Mirror of the
    /// keyboard-side helper in `JotKeyboardViewController` so the App can
    /// match by UUID without depending on a Codable shape that lives in the
    /// other target.
    private func readPendingPasteSession() -> PendingPasteSession? {
        guard let data = AppGroup.defaults.data(
            forKey: AppGroup.Keys.pendingPasteSession
        ) else { return nil }
        return try? JSONDecoder().decode(PendingPasteSession.self, from: data)
    }

    private func stopStandaloneRecording(
        startedAt: Date,
        sessionID: UUID,
        controller: any DictationController,
        transient: Bool = false
    ) async throws {
        let recording = RecordingService.shared
        guard recording.isRecording else {
            publishIdleProjection()
            return
        }

        let samples = try await recording.stop()
        let stoppedAt = Date()

        do {
            let transcript = try await TranscriptionService.shared.transcribe(samples: samples)
            try await DictationPipeline.completeEndOfRecording(
                transcript: transcript,
                sessionID: sessionID,
                startedAt: startedAt,
                stoppedAt: stoppedAt,
                controller: controller,
                transient: transient,
                // Retain this recording's 16 kHz mono audio (keyed to the saved
                // transcript) so it can be re-transcribed within the 3-day window.
                retainSamples: samples
            )
        } catch {
            // Transcription threw (e.g. `audioTooShort`) BEFORE the post-transcript
            // pipeline ran, so nothing published a terminal cross-process phase —
            // the projection stays at `.transcribing` and the keyboard sits on
            // "working" forever, looping `pasteSkipNoPayload` (stuck-keyboard bug).
            // Publish `.failed` (carries the session adopted at start) so the
            // keyboard's terminal cleanup clears its pending paste session and the
            // user can re-dictate from the keyboard instead of opening the app.
            DiagnosticsLog.record(
                source: "main-app", category: .recordingOutcome,
                message: "dictation failed",
                metadata: ["reason": error.localizedDescription]
            )
            recording.publishPipelinePhase(.failed, failureReason: "transcribe-throw")
            recording.markPipelineFinished()
            throw error
        }
    }

    private func publishIdleProjection() {
        // Single source of truth: pipeline phase. Routing through the
        // `RecordingService` helper keeps the in-process `currentPipelinePhase`,
        // the App Group projection, the heartbeat task lifecycle, and the
        // Darwin notification post in lock-step.
        RecordingService.shared.publishPipelinePhase(.idle)
    }
}
