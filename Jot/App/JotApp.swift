@preconcurrency import AVFAudio
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
    @State private var cleanupService: CleanupService
    @State private var setupRerunTrigger: SettingsRerunTrigger
    @State private var showSetupWizard = false
    @State private var setupCompleted = SetupCompletion.isCompleted
    @State private var autoStartConsumed = false
    @State private var autoStartPendingModelReady = false

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
        let cleanup = CleanupService()
        let rerunTrigger = SettingsRerunTrigger.shared
        _recordingService = State(initialValue: recording)
        _transcriptionService = State(initialValue: transcription)
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
        lifecycleLog.info("JotApp init — services constructed (no I/O)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingService)
                .environment(transcriptionService)
                .environment(cleanupService)
                .fullScreenCover(isPresented: $showSetupWizard) {
                    SetupWizardView {
                        setupCompleted = SetupCompletion.isCompleted
                        showSetupWizard = false
                    }
                    .environment(transcriptionService)
                }
                .onAppear {
                    presentSetupIfNeeded()
                }
                .onOpenURL { url in
                    guard url.scheme == "jot" else { return }
                    // Explicit user intent — bypass the once-per-session gate.
                    autoStartConsumed = false
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
                // `warmUp()` is void/non-throwing/idempotent/fire-and-forget:
                // it spawns its own background load, coalesces repeat calls,
                // and surfaces failures later via `modelState` / the next
                // `transcribe(...)`. Re-firing on scene foreground (e.g. after
                // `didReceiveMemoryWarning` evicted the CoreML handle) is
                // cheap defense-in-depth.
                //
                // Cold-launch mirror refresh: regenerates the App Group JSON
                // projection the keyboard reads on `viewWillAppear`. Without
                // this, a fresh install / post-reinstall keyboard would show
                // "No dictations yet" until the next main-app dictation
                // triggered an incremental refresh via `TranscriptStore.append`.
                // Bootstrapping here makes history visible in the keyboard
                // immediately after first launch of the main app.
                .task {
                    transcriptionService.warmUp()
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
                try await recordingService.start()
                lifecycleLog.info("Auto-started recording after \(reason, privacy: .public)")
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

        guard RecordingService.shared.isRecording else {
            publishIdleProjection()
            log.info("Cross-process stop request ignored because no recording is active.")
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
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt
            ?? projection?.startedAt
            ?? Date()

        switch controller.currentPhase {
        case .recording:
            await DictationActivityCoordinator.shared.update(phase: .transcribing)
            let result = try await controller.stopAndTranscribe()
            try await DictationPipeline.completeEndOfRecording(
                transcript: result.transcript,
                startedAt: startedAt,
                stoppedAt: result.stoppedAt,
                controller: controller
            )

        case .idle:
            try await stopStandaloneRecording(startedAt: startedAt, controller: controller)

        case .transcribing, .processing, .cleaning:
            log.notice("Cross-process stop request ignored because dictation pipeline is already active.")
        }
    }

    private func stopStandaloneRecording(
        startedAt: Date,
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
