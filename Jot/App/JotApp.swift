@preconcurrency import AVFAudio
import FluidAudio
import SwiftUI
import SwiftData
import os.log
import UIKit

private let lifecycleLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "app-lifecycle")

@main
struct JotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(JotAppDelegate.self) private var appDelegate
    private let stopRequestObserver: CrossProcessNotification.Observer
    @State private var recordingService: RecordingService
    @State private var transcriptionService: TranscriptionService
    @State private var streamingService: StreamingTranscriptionService
    @State private var streamingPartial: StreamingPartial
    @State private var cleanupService: CleanupService
    @State private var setupRerunTrigger: SettingsRerunTrigger
    @State private var showSetupWizard = false
    @State private var setupCompleted = SetupCompletion.isCompleted
    @State private var autoStartConsumed = false
    @State private var autoStartPendingModelReady = false

    /// Stashed session UUID parsed off the most recent `jot://dictate?session=<uuid>`
    /// URL. Consumed in `triggerAutoStart` immediately before `recording.start()`
    /// so the upcoming pipeline writes carry the keyboard's session ID. Held on
    /// the App (not consumed by the first `triggerAutoStart` turn) so model-not-
    /// ready retries via `.onChange(of: modelState)` re-read this stash —
    /// surviving the cold-launch race per design §4.2.
    @State private var pendingKeyboardSessionID: UUID?

    init() {
        stopRequestObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.stopRequested
        ) {
            CrossProcessRecordingStopCoordinator.shared.handleStopRequested()
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
        // Singleton owner of the FluidAudio EOU streaming model used to
        // drive the live partial-transcript preview. Cleanup-on-every-stop
        // policy: no manager retained between sessions; warmUp ensures
        // weights are on disk only. See `StreamingTranscriptionService` doc.
        let streamingService = StreamingTranscriptionService.shared
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
        _streamingService = State(initialValue: streamingService)
        _streamingPartial = State(initialValue: streamingPartial)
        _cleanupService = State(initialValue: cleanup)
        _setupRerunTrigger = State(initialValue: rerunTrigger)
        // One-shot sweep of any orphaned model-purge dirs from prior crashed
        // purges. Detached + best-effort, does not block launch.
        TranscriptionService.sweepOrphanedPurgingDirs()

        // Reset any stale recording-state projection. If the app is launching
        // here, by definition no recording is in flight in this process — so
        // any leftover `isRecording=true` from a previous crashed/killed
        // session must be cleared, otherwise the keyboard mic CTA will route
        // every tap to "stop" instead of opening the app.
        RecordingStateProjection.write(state: RecordingStateProjection(
            isRecording: false,
            startedAt: nil,
            lastUpdatedAt: Date()
        ))
        // v7 auto-paste: clear any leftover non-terminal pipeline-phase
        // projection from a crashed previous launch. Without this reset, the
        // keyboard would observe a stale non-idle phase on first appearance
        // and only recover via the 30s stale-deadline. Per design §4.2.
        PipelinePhaseProjection.reset()
        lifecycleLog.info("JotApp init — services constructed (no I/O)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingService)
                .environment(transcriptionService)
                .environment(streamingService)
                .environment(streamingPartial)
                .environment(cleanupService)
                .fullScreenCover(isPresented: $showSetupWizard) {
                    SetupWizardView {
                        setupCompleted = SetupCompletion.isCompleted
                        showSetupWizard = false
                    }
                    .environment(transcriptionService)
                    .environment(streamingService)
                }
                .onAppear {
                    presentSetupIfNeeded()
                }
                .onOpenURL { url in
                    guard url.scheme == "jot" else { return }
                    // Branch on host: `jot://rewrite` is the keyboard's
                    // saved-prompt rewrite handoff (URL-scheme replacement
                    // for the broken `RewriteWithPromptIntent.perform()`
                    // direct call from the keyboard). Everything else
                    // (`jot://dictate`, plain `jot://`) falls through to the
                    // existing dictation auto-start path.
                    if url.host == "rewrite" {
                        handleRewriteURL(url)
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
                    triggerAutoStart(reason: "url open: \(url.absoluteString)")
                }
                .onChange(of: setupRerunTrigger.requestID) { _, _ in
                    setupCompleted = false
                    showSetupWizard = true
                }
                .onChange(of: setupCompleted) { _, completed in
                    if completed {
                        autoStartConsumed = false   // setup just completed, allow one auto-start
                        triggerAutoStart(reason: "setup completion")
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        handleSceneActive()
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
                    triggerAutoStart(reason: "model became ready")
                }
                // Eager Parakeet preload. `.task` fires on first scene
                // activation — earliest post-init hook without blocking launch,
                // and the ban on I/O inside `JotApp.init()` still holds.
                //
                // `warmUp()` is gated on (a) the user having finished the
                // setup wizard (which is where the explicit "Download speech
                // models (~948 MB)" tap lives), AND (b) the models actually
                // being on disk. Together these guarantee `warmUp()` cannot
                // initiate a silent first-run download — required by App
                // Review Guideline 4.2.3(ii). If models are missing, the
                // wizard re-presents on next launch and re-prompts.
                //
                // Cold-launch mirror refresh: regenerates the App Group JSON
                // projection the keyboard reads on `viewWillAppear`. Without
                // this, a fresh install / post-reinstall keyboard would show
                // "No dictations yet" until the next main-app dictation
                // triggered an incremental refresh via `TranscriptStore.append`.
                // Bootstrapping here makes history visible in the keyboard
                // immediately after first launch of the main app.
                .task {
                    let modelsOnDisk = AsrModels.modelsExist(
                        at: MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2),
                        version: .v2
                    )
                    if SetupCompletion.isCompleted && modelsOnDisk {
                        transcriptionService.warmUp()
                    }
                    // Streaming weights live in a different on-disk location
                    // (FluidAudio's `parakeet-eou-streaming/320ms/` cache);
                    // gated independently. `warmUp()` here is "ensure
                    // weights on disk" — does NOT load into ANE per the
                    // service's cleanup-on-every-stop lifecycle. Same
                    // 4.2.3(ii) gate (setup completed + models on disk):
                    // a fresh install never auto-downloads.
                    if SetupCompletion.isCompleted
                        && StreamingTranscriptionService.modelsExistOnDisk() {
                        streamingService.warmUp()
                    }
                    TranscriptHistoryMirror.refresh(
                        from: ModelContext(JotModelContainer.shared)
                    )
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

    /// Handles `jot://rewrite?session=<uuid>` — the keyboard's URL-scheme
    /// handoff for the saved-prompt rewrite path. Parses the session ID,
    /// hands it to `RewriteRequestDispatcher`, which reads the App Group
    /// stash, dispatches the LLM rewrite, and posts the Darwin completion
    /// notification the keyboard observes.
    ///
    /// This is the URL-scheme replacement for the previous (broken) direct
    /// `RewriteWithPromptIntent.perform()` call from the keyboard process.
    /// See `RewriteRequestDispatcher` for rationale.
    private func handleRewriteURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sessionParam = comps.queryItems?.first(where: { $0.name == "session" })?.value,
              let sessionID = UUID(uuidString: sessionParam)
        else {
            lifecycleLog.error("rewrite URL missing/invalid session param url=\(url.absoluteString, privacy: .public)")
            return
        }
        // `RewriteRequestDispatcher` is `@available(iOS 26.0, *)` — same as
        // the project's deployment floor. No runtime guard needed.
        RewriteRequestDispatcher.dispatch(sessionID: sessionID)
    }

    private func handleSceneActive() {
        guard SetupCompletion.isCompleted else {
            setupCompleted = false
            showSetupWizard = true
            return
        }
        setupCompleted = true
        guard !autoStartConsumed else { return }
        triggerAutoStart(reason: "first scene activation")
    }

    private func triggerAutoStart(reason: String) {
        // Consume the session gate FIRST. Even if we bail below
        // (model loading, recording in flight, no permission), this
        // counts as the one-shot for this session — a later
        // resume-from-background must not retry.
        autoStartConsumed = true

        guard SetupCompletion.isCompleted else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        guard !recordingService.isRecording else { return }
        guard !recordingService.isPipelineInFlight else { return }

        guard transcriptionService.modelState == .ready else {
            // Model not loaded yet. Defer to the modelState .onChange
            // observer — it will call back here when ready.
            autoStartPendingModelReady = true
            lifecycleLog.info("Auto-start deferred — model not ready, reason=\(reason, privacy: .public)")
            return
        }

        autoStartPendingModelReady = false

        Task { @MainActor in
            guard !recordingService.isRecording else { return }
            guard !recordingService.isPipelineInFlight else { return }
            do {
                recordingService.forceStop()
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
                    try await recordingService.start()
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
            }
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

    private func stopAndPublish() async throws {
        let projection = RecordingStateProjection.read()
        let controller = DictationIntentBridge.shared.controller
        let recording = RecordingService.shared
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt
            ?? projection?.startedAt
            ?? Date()

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
                controller: controller
            )

        case .idle:
            recording.adoptSession(resolvedSessionID)
            try await stopStandaloneRecording(
                startedAt: startedAt,
                sessionID: resolvedSessionID,
                controller: controller
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
            log.notice("Cross-process stop request mid-pipeline; keyboard pending session cleared.")
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
        controller: any DictationController
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
                controller: controller
            )
        } catch {
            recording.markPipelineFinished()
            throw error
        }
    }

    private func publishIdleProjection() {
        RecordingStateProjection.write(
            state: RecordingStateProjection(
                isRecording: false,
                startedAt: nil,
                lastUpdatedAt: Date()
            )
        )
        CrossProcessNotification.post(name: CrossProcessNotification.recordingStateChanged)
    }
}
