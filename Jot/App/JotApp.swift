import SwiftUI
import SwiftData
import os.log
import UIKit

private let lifecycleLog = Logger(subsystem: "com.jot.mobile.Jot", category: "app-lifecycle")

@main
struct JotApp: App {
    @UIApplicationDelegateAdaptor(JotAppDelegate.self) private var appDelegate
    @State private var recordingService: RecordingService
    @State private var transcriptionService: TranscriptionService
    @State private var cleanupService: CleanupService

    init() {
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
        _recordingService = State(initialValue: recording)
        _transcriptionService = State(initialValue: transcription)
        _cleanupService = State(initialValue: cleanup)
        lifecycleLog.info("JotApp init — services constructed (no I/O)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingService)
                .environment(transcriptionService)
                .environment(cleanupService)
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
}
