import AppIntents
import Foundation
import Observation
import os

/// The Action Button / Shortcuts entry point for Jot.
///
/// Flow:
///   1. First invocation → start mic capture + present Live Activity.
///   2. Second invocation → stop mic, transcribe, (optional) clean up,
///      publish to clipboard, flash "finished" state, end activity.
///
/// ## iOS 26 API lookup notes (see Experiment 4)
///
/// Apple explicitly documents that `AVAudioEngine`-based microphone capture
/// cannot be started from a Shortcuts-invoked intent unless the app is in the
/// foreground.¹ Foregrounding via `supportedModes = .foreground(.immediate)`
/// (the iOS 26 replacement for the deprecated `openAppWhenRun = true`) is
/// necessary BUT not sufficient: iOS creates the foreground *during* `perform()`,
/// so the mic-start is DEFERRED to scene-`.active` via
/// `DictationIntentBridge.pendingForegroundStart` (GitHub issue #3; see
/// `docs/carplay/issue-3-mic-rootcause.md`).
///
/// We deliberately conform to the plain `AppIntent` — *not* the marker
/// protocol `AudioRecordingIntent`. The fundamental reason: `AudioRecordingIntent`
/// does NOT grant cold-background mic start (it requires a live Live Activity,
/// removed from Jot, and only manages a foreground-started session — Apple DTS
/// forums/thread/815725). Re-adding it would NOT fix issue #3. (An earlier
/// iteration also found it made the intent *un-selectable* in the Action Button
/// picker, which is a second, lesser reason.) Since we foreground anyway, plain
/// `AppIntent` is both sufficient and bindable.²
///
/// The pragmatic consequence for Experiment 4: the user *will* see Jot's app
/// come forward for a moment. We don't route the user into any Jot screen;
/// the app just hosts the audio session quietly. After stop, the recording
/// layer is expected to hand back to the previous app (or rely on the user's
/// own back-swipe). That policy lives in the App layer, not here.
///
/// ## Swift 6 / metadata-extractor note
///
/// All metadata statics are `static let` (not `var`). `let` is immutable so
/// there's no concurrency concern, and — critically — the AppIntents metadata
/// processor (`appintentsmetadataprocessor`) parses the declaration form
/// directly: earlier `nonisolated(unsafe) public static var` declarations
/// produced metadata where the intent was *discoverable* but *un-bindable*
/// from the Action Button picker. `static let` is the canonical shape the
/// extractor is known to handle.
///
/// ## iOS 26.2 Action Button "Something went wrong" fix
///
/// On iOS 26.2 the Action Button picker briefly listed "Dictate" but surfaced
/// *"Something went wrong, please try again later"* when the user tapped it
/// to bind. Metadata extract (`extract.actionsdata`) looked structurally
/// correct — title, description, `openAppWhenRun`, `isDiscoverable` all
/// populated — and the intent itself executed correctly when invoked from
/// other surfaces. The failure was therefore located in the Shortcuts
/// daemon's *commit* step for the Action Button binding specifically.
///
/// The shape of the struct has been normalised to the minimum shape that
/// Apple's sample code uses for a parameterless foreground intent:
///
/// - No `public` modifier on the type, statics, `init`, or `perform`. The
///   intent lives in the main app target; `public` is unnecessary and the
///   metadata extractor has historically been sensitive to access-level
///   quirks. Apple's reference samples use bare `struct`/`static`/`func`.
/// - `@available(iOS 17.0, *)` removed: the deployment target is iOS 26.0,
///   so the annotation produced metadata (`introducedVersion: "17.0"`) that
///   served no purpose but added one more dimension for the daemon to
///   validate against. Dropping it avoids that ambiguity.
/// - `parameterSummary` added even though there are no parameters. Apple's
///   docs describe `parameterSummary` as powering the intent's appearance in
///   the Shortcuts editor, Focus Filters, and Widget Configuration UIs. On
///   iOS 26 the Shortcuts binding pipeline appears to render the parameter
///   summary during the commit step — an intent with no declared summary can
///   cause that render to fail and surface the generic "Something went
///   wrong" error to the user. A trivial `Summary("Dictate with …")` tells
///   the system exactly what to draw.
///
/// ---
/// ¹ Apple Developer Forums thread #756507 — "You cannot trigger an audio
///   recording from the Shortcuts app. Your app needs to be in the foreground
///   before the user can start recording audio." (DTS Engineer, 2024)
/// ² Empirically observed on iPhone 15 Pro, iOS 26.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Jot down a note"

    static let description = IntentDescription(
        """
        Press to start recording. Press again to stop. \
        Your speech is transcribed on-device and copied to the clipboard — \
        no network, no accounts.
        """,
        categoryName: "Dictation"
    )

    /// Forcing the app to foreground is required for microphone capture from
    /// a Shortcuts-invoked intent (see class doc). `supportedModes` with
    /// `.foreground(.immediate)` is the iOS 26 replacement for the deprecated
    /// `openAppWhenRun = true` (deprecated at iOS 26.0; our deployment floor).
    /// Foregrounding is necessary BUT not sufficient — the actual mic-start is
    /// deferred to scene-`.active` via `DictationIntentBridge.pendingForegroundStart`
    /// (see `perform()`), because iOS creates the foreground *during* `perform()`.
    static var supportedModes: IntentModes { .foreground(.immediate) }

    /// Intentionally `false`. `DictateIntent` is the dormant legacy fallback:
    /// it stays compiled in the binary but is NOT registered in
    /// `JotAppShortcuts.appShortcuts` and is NOT visible in the Shortcuts
    /// action catalog (`Settings → Shortcuts → Apps → Jot`).
    ///
    /// Apple's AppIntents metadata extractor enforces that every intent
    /// referenced from an `AppShortcut` entry must have `isDiscoverable =
    /// true`. An earlier iteration of this flag + doc asserted the opposite
    /// ("the `AppShortcut` tile is independent of this flag") and produced
    /// a hard build error on Xcode 26.3:
    ///
    ///   *"App Intent 'DictateIntent' must be visible for App Shortcuts use"*
    ///
    /// The "tile without catalog entry" split is therefore not expressible
    /// in the AppIntents API. The user's call was to ship a single clean
    /// Action Button picker rather than carry a second near-duplicate tile
    /// just to keep a legacy binding path alive.
    ///
    /// ## OTA recovery path
    ///
    /// If `RecordAndTranscribeIntent` ever fails to bind on a future iOS
    /// release, the recovery is a one-commit app update:
    ///
    /// 1. Flip this back to `isDiscoverable = true`.
    /// 2. Re-add the `AppShortcut(intent: DictateIntent(), …)` entry to
    ///    `JotAppShortcuts.appShortcuts`.
    /// 3. Ship.
    ///
    /// Apple's metadata extractor will accept the pair because the coupling
    /// is satisfied again. OTA latency (hours-to-days through the update
    /// channel) is cheaper than shipping the two-tile picker to 100% of
    /// users for the 0% case of primary-path failure.
    static let isDiscoverable: Bool = false

    /// Even a parameterless intent declares a parameter summary on iOS 26.
    /// The Shortcuts binding UI renders the summary as the action's body
    /// cell on the configuration screen; without it, iOS 26.2 surfaces a
    /// generic "Something went wrong, please try again later" error when
    /// the user taps to bind the intent to the Action Button.
    ///
    /// Note: `\(.applicationName)` interpolation works in `AppShortcut.phrases`
    /// but *not* inside a `Summary` — `Summary` takes a plain
    /// `LocalizedStringResource` title. Siri and the Action Button label
    /// already get `applicationName` substitution via the phrase string.
    static var parameterSummary: some ParameterSummary {
        Summary("Dictate")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = DictationIntentBridge.shared.controller

        switch controller.currentPhase {
        case .idle:
            // Do NOT start the mic inline — see `DictationIntentBridge.pendingForegroundStart`.
            // Request a foreground-gated start; `JotApp` begins recording via
            // `triggerAutoStart` once the scene is confirmed `.active`.
            DictationIntentBridge.shared.pendingForegroundStart = true
            NotificationCenter.default.post(name: .jotDictateFromShortcut, object: nil)
        case .recording:
            // Stop needs no foreground — the engine is already up. Safe inline.
            try await endDictation(using: controller)
        case .transcribing, .processing, .cleaning:
            return .result()
        }

        return .result()
    }

    // MARK: - Toggle legs

    @MainActor
    private func endDictation(using controller: any DictationController) async throws {
        // Capture `recordingStartedAt` BEFORE anything clears it — we need it
        // to compute the wall-clock duration `DictationPipeline` hands to
        // `TranscriptStore.append`. See the equivalent note in
        // `RecordAndTranscribeIntent.endDictation` for why this lives on
        // the coordinator singleton rather than on the intent struct.
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt ?? Date()

        await DictationActivityCoordinator.shared.update(phase: .transcribing)

        let result = try await controller.stopAndTranscribe()

        // Delegate to the shared pipeline. Must match the
        // `RecordAndTranscribeIntent` call site exactly — "no code-path
        // divergence" is a shipped invariant per the full-v2 brief: users who
        // bind the fallback intent must see identical observable behaviour
        // (clipboard, ledger rows, chained-follow-up classification) as
        // users who bind the primary intent. See `DictationPipeline`.
        try await DictationPipeline.completeEndOfRecording(
            transcript: result.transcript,
            startedAt: startedAt,
            stoppedAt: result.stoppedAt,
            controller: controller,
            retainSamples: result.samples
        )
    }
}

// MARK: - Controller contract

/// What the intent needs from the main app's recording/transcription stack.
///
/// The main app is expected to install a conforming implementation into
/// `DictationIntentBridge` during `application(_:didFinishLaunchingWithOptions:)`.
/// We deliberately keep this protocol minimal — the intent is the *driver* of
/// phase transitions; the controller owns the mic, the model, and the cleanup
/// runtime.
@MainActor
protocol DictationController: AnyObject {
    /// The controller's view of where it is in the dictation lifecycle.
    /// The intent uses this to decide whether a press should start or stop.
    var currentPhase: DictationRuntimePhase { get }

    /// Begin microphone capture. Throws if the session can't activate or the
    /// microphone permission is denied.
    func startRecording(startedAt: Date) async throws

    /// Stop capture and return the raw transcript plus the mic-off timestamp.
    func stopAndTranscribe() async throws -> DictationStopResult

    /// Transcribe samples that were drained externally (typically by
    /// `RecordingService.internalStop` after an audio-session interruption
    /// tore down the engine before the user could call `stopAndTranscribe`).
    /// The caller has already drained the capture; this method ONLY drives the
    /// controller's phase machine through `.transcribing` and runs inference.
    /// Cycles `currentPhase: .recording → .transcribing → .idle` so a follow-up
    /// press doesn't see a stale phase and route into the wrong toggle leg.
    ///
    /// Real protocol requirement (NOT a protocol-extension default) per
    /// `tmp/research-warm-resume-design.md` §6.1.5 #1: the bridge stores
    /// `let controller: any DictationController`, so a default impl in a
    /// protocol extension would dispatch statically and silently bypass any
    /// override on `DictationControllerImpl`. Forcing every conformer to
    /// implement explicitly avoids that footgun.
    func consumePreDrainedSamples(_ samples: [Float]) async throws -> DictationStopResult

    /// Reset `currentPhase` back to `.idle` without going through the normal
    /// `stopAndTranscribe` defer chain. Called by the interrupt-publish
    /// dispatch path on the short-capture (<1s discard) early-return and on
    /// transcription-failure catch paths so the toggle isn't stuck in
    /// `.recording` after a recovery that didn't go through the standard
    /// stop flow. Idempotent.
    func abortToIdle()

    /// Run cleanup over the transcript using the provided settings.
    func cleanup(transcript: String, settings: CleanupSettings) async throws -> String

    /// Enter the post-transcription follow-up resolution window.
    func beginPostProcessing()

    /// End the post-transcription follow-up resolution window.
    func endPostProcessing()
}

struct DictationStopResult: Sendable {
    let transcript: String
    let stoppedAt: Date
    /// The 16 kHz mono source samples this transcript was produced from, carried
    /// out so the end-of-recording pipeline can retain them for re-transcription
    /// (`RetainedAudioStore`). Empty only if a caller has nothing to retain.
    var samples: [Float] = []
}

/// The intent's view of runtime state. Lightweight `idle | in-flight`
/// signal the intent uses solely to decide which toggle leg to run.
enum DictationRuntimePhase: Sendable {
    case idle
    case recording
    case transcribing
    case processing
    case cleaning
}

/// Process-wide owner of the `DictationController` the intents drive.
///
/// ## Why this is now a lazy singleton instead of a register/await bridge
///
/// **v8 shape:** the bridge held a `weak var controller` that the app layer
/// was expected to populate via `register(controller:)` during
/// `application(_:didFinishLaunchingWithOptions:)`. Intents that fired before
/// that call (cold launch, headless `AudioRecordingIntent` promotion) blocked
/// briefly via `awaitController(timeout:)` until the app caught up.
///
/// **What actually went wrong:** the register call was never wired in the App
/// layer. `JotApp.swift` constructs `RecordingService` / `TranscriptionService` /
/// `CleanupService` as `@State` but nothing in the codebase conforms to
/// `DictationController`, and `DictationIntentBridge.shared.register(controller:)`
/// is not invoked anywhere (grep-verified across the whole repo). Every Action
/// Button press therefore found `controller == nil`, fell through to
/// `awaitController`, and surfaced `TimeoutError` as the user-visible
/// *"DictationIntentBridge timeout error 1"* three seconds later.
///
/// **Why the fix isn't "just wire the register call":** the `AudioRecordingIntent`
/// path launches the main-app process *headless* — no scene, no WindowGroup,
/// no `.task { }` from `ContentView.onAppear`. Only `JotApp.init()` fires. A
/// register call inside `init()` works, but it's fragile: adding a single
/// `@State` service that spawns I/O (AVAudioSession configure, CoreML handle
/// load) from `init()` would block the process bootstrap. Apple's own guidance
/// on headless intents is explicit about keeping `init()` I/O-free.
///
/// A second, structural reason: the intent *doesn't need* anything from the
/// app layer. Everything it needs (`RecordingService`, `TranscriptionService`,
/// `CleanupService`) can be constructed or accessed directly. Gating on a
/// register call was modelling "the main app is the source of truth" where
/// the truth is "the process — whoever owns it — is the source of truth."
/// Headless intent launch IS the process.
///
/// **Current shape:** the bridge lazy-owns a `DictationControllerImpl`. First
/// access constructs it; subsequent accesses return the same instance. Works
/// identically in every launch context:
///   - `openAppWhenRun = false` + `AudioRecordingIntent` — main-app process
///     launches headless, intent's `perform()` hits `shared.controller`,
///     the impl constructs inside the intent's own actor-hop.
///   - `openAppWhenRun = true` (legacy `DictateIntent`) — app foregrounds,
///     `JotApp.init()` fires and constructs its scene state, then intent's
///     `perform()` hits `shared.controller`. Both surfaces read from the
///     same `RecordingService.shared` since v10 (see that class's doc for
///     the two-instance session-state-leak rationale), so the foreground
///     path and the headless path share one `AVAudioSession` prior-state
///     stash. A conflicting in-flight press still surfaces as a clean
///     `RecordingError.alreadyRunning` — the singleton makes that check
///     authoritative rather than racy.
///
/// **Toggle semantics.** Each `perform()` is a fresh intent struct — no
/// instance state to stash "are we recording?" across presses. The bridge's
/// singleton is where `currentPhase` lives: every dictation entry-point intent
/// routes through the same controller, so "press 1 starts, press 2 stops"
/// works across `RecordAndTranscribeIntent`, `DictateIntent`, and
/// `StopDictationIntent` without each intent needing its own state.
@MainActor
final class DictationIntentBridge {
    static let shared = DictationIntentBridge()

    /// Strongly owned, lazy-constructed on first access. Non-optional — every
    /// call site that previously unwrapped `controller` (e.g. `guard let
    /// controller = ...`) can now access it unconditionally.
    ///
    /// Kept as `any DictationController` rather than the concrete
    /// `DictationControllerImpl` so the existing intent code keeps working
    /// against the protocol and the impl type stays substitutable in tests.
    let controller: any DictationController

    /// Set by a foreground dictation intent's START leg
    /// (`RecordAndTranscribeIntent` / `DictateIntent`) to request that the app
    /// begin recording once it is confirmed **foreground/active** — instead of
    /// starting the mic inline in `perform()`.
    ///
    /// **Why:** iOS launches an App Intent into the *background* and creates the
    /// foreground *during* `perform()` (Apple DTS, forums/thread/769924), so an
    /// inline `RecordingService.start()` races the foreground transition and
    /// intermittently fails with CoreAudio "engine failed to start" (GitHub
    /// issue #3). `JotApp` consumes this flag on scene-`.active` and routes
    /// through `triggerAutoStart` — the same scene-active-gated path the
    /// keyboard's `jot://dictate` bounce already uses reliably.
    var pendingForegroundStart = false

    private init() {
        self.controller = DictationControllerImpl()
    }
}

extension Notification.Name {
    /// Posted by a foreground dictation intent's START leg after setting
    /// `DictationIntentBridge.shared.pendingForegroundStart`. Lets `JotApp`
    /// start *immediately* when the app is ALREADY foreground (no new
    /// scene-`.active` transition will fire to trigger the deferred path).
    static let jotDictateFromShortcut = Notification.Name("jot.dictateFromShortcut")
}

/// Process-wide implementation of `DictationController`.
///
/// ## What it owns
///
/// - A reference to `RecordingService.shared` — process-wide singleton since
///   v10, shared with the foreground scene's `@State`. See that class's doc
///   for the two-instance `AVAudioSession` prior-state stash collision that
///   motivated the consolidation.
/// - Access to `TranscriptionService.shared` (process-wide singleton, warm-
///   model reuse across app and intent surfaces — see that class's doc).
/// - Its own `CleanupService` (stateless — per-call construction matches the
///   convention in `TranscribeAudioFileIntent.runCleanupTolerantly`).
/// - Phase state (`currentPhase`) that intents read to decide start vs stop.
///
/// ## What it doesn't do
///
/// - Any end-of-recording tail work. The shared pipeline
///   (`DictationPipeline.completeEndOfRecording`) owns the
///   chained-follow-up classification, clipboard publish, ledger append, and
///   Live Activity finish. The controller's `stopAndTranscribe()` returns the
///   raw transcript plus mic-off timestamp and the pipeline takes it from there.
/// - Live Activity updates during recording. The
///   `DictationActivityCoordinator` singleton owns the pill. The intent's
///   `perform()` wires the two together — keeping both out of this class.
///
/// ## Concurrency
///
/// `@MainActor` because `RecordingService`, `TranscriptionService`, and
/// `CleanupService` are all `@MainActor`, and because `currentPhase` must be
/// read synchronously from `perform()` to branch before any `await`.
@MainActor
final class DictationControllerImpl: DictationController {
    private(set) var currentPhase: DictationRuntimePhase = .idle

    private let recording: RecordingService
    private let cleanupService: CleanupService

    init() {
        // v10 consolidation: single process-wide `RecordingService` instance
        // shared with the foreground scene (`JotApp.swift` → `ContentView`).
        // Two-instance coexistence used to be documented as a
        // cleanliness-not-correctness issue because `AVAudioSession` is the
        // global arbiter — what team-lead's post-ANE-leak audit uncovered is
        // that it's actually a correctness issue: each instance stashes its
        // own `priorCategory`/`priorMode`/`priorOptions` for restore, so the
        // second-to-configure stashes the already-modified state and restores
        // to that instead of the true pre-Jot baseline. See
        // `RecordingService.shared` doc for the full rationale.
        //
        // `CleanupService` stays per-instance: it's a thin stateless wrapper
        // around FoundationModels + the Apple Foundation Models prompt, with
        // no shared resource to coordinate around. Constructing fresh is
        // cheaper than reasoning about the singleton lifecycle.
        self.recording = RecordingService.shared
        self.cleanupService = CleanupService()
    }

    func startRecording(startedAt: Date) async throws {
        Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "dictation-intent")
            .notice("RECORDING START FROM: DictateIntent.startRecording (Shortcuts / Action Button)")
        try await recording.start()
        currentPhase = .recording
    }

    func stopAndTranscribe() async throws -> DictationStopResult {
        currentPhase = .transcribing
        // Mark idle on any exit path — success or throw — so a failed
        // transcription doesn't leave the toggle stuck in `.transcribing`
        // and force the user to re-launch the app to clear it.
        defer { currentPhase = .idle }

        let samples = try await recording.stop()
        let stoppedAt = Date()
        do {
            let transcript = try await TranscriptionService.shared.transcribe(samples: samples)
            return DictationStopResult(transcript: transcript, stoppedAt: stoppedAt, samples: samples)
        } catch {
            // Transcription threw (e.g. `audioTooShort`) before any terminal
            // cross-process phase was published. The in-process `defer` above
            // resets THIS controller's phase, but the keyboard reads the
            // cross-process projection — which is stuck at `.transcribing`. Publish
            // `.failed` (carries the adopted session ID) so the keyboard's terminal
            // cleanup clears its pending paste session and exits "working".
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

    /// Phase-machine entry for samples that were drained externally by
    /// `RecordingService.internalStop` after an audio-session interruption tore
    /// the engine down before the user could call `stopAndTranscribe`. We do
    /// NOT call `recording.stop()` here — the engine is already gone.
    ///
    /// **Flag ownership.** Unlike `stopAndTranscribe` (which owns the
    /// `isPipelineInFlight` lifecycle because IT called `recording.stop()` to
    /// set the flag), this method does NOT touch `isPipelineInFlight`. The
    /// `RecordingPipelineDispatch.publishAfterInterruption` helper that drives
    /// this method owns the flag end-to-end (per `tmp/research-warm-resume-design.md`
    /// §6.1.5 #3). Adding `markPipelineFinished()` here would create dual
    /// ownership and become a foot-gun for a future change that moves the
    /// flag-set point. The defer below is the entire phase-machine contract
    /// this method is responsible for: cycle `.transcribing → .idle` on both
    /// success and re-thrown failure.
    func consumePreDrainedSamples(_ samples: [Float]) async throws -> DictationStopResult {
        currentPhase = .transcribing
        defer { currentPhase = .idle }
        let stoppedAt = Date()
        let transcript = try await TranscriptionService.shared.transcribe(samples: samples)
        return DictationStopResult(transcript: transcript, stoppedAt: stoppedAt, samples: samples)
    }

    /// Phase-only reset for the dispatch helper's short-capture (<1s discard)
    /// early-return path. Idempotent. Does NOT clear any `RecordingService`
    /// state (`isPipelineInFlight`, `currentSessionID`, etc.) — the dispatch
    /// helper owns those side-effects on the abort paths.
    func abortToIdle() {
        currentPhase = .idle
    }

    func cleanup(transcript: String, settings: CleanupSettings) async throws -> String {
        currentPhase = .cleaning
        defer { currentPhase = .idle }

        return try await cleanupService.clean(
            transcript: transcript,
            instructions: settings.instructions
        )
    }

    func beginPostProcessing() {
        currentPhase = .processing
    }

    func endPostProcessing() {
        currentPhase = .idle
    }
}

// MARK: - Dictation lifecycle coordinator
//
// Owns the in-app bookkeeping the dictation pipeline needs:
// `recordingStartedAt` (consumed by `TranscriptStore.append` for duration),
// `isFollowUpActive` / `followUpExpiresAt` (consumed by `DictationPipeline`
// to gate chained-command classification), and the follow-up expiry task
// that flips `isFollowUpActive` back to `false` after the freshness window
// elapses.
//
// As of the Dynamic Island ghost-pill fix the entire Live Activity path
// (ActivityKit, the JotWidget extension, the DictationAttributes codable
// shape, the StopDictationIntent / DismissFollowUpIntent /
// CancelPostProcessingIntent surfaces, and the `NSSupportsLiveActivities`
// plist key) has been removed. The keyboard reads dictation state from App
// Group projections (PipelinePhaseProjection, FreshDictation) — those
// projections never observed Live Activity content state, so the only
// thing this coordinator needs to keep tracking is the recording-start
// timestamp + follow-up window state above.
@MainActor
@Observable
final class DictationActivityCoordinator {
    static let shared = DictationActivityCoordinator()

    private var followUpExpiryTask: Task<Void, Never>?
    private(set) var followUpExpiresAt: Date?
    private(set) var isFollowUpActive = false

    /// Recording-start timestamp, captured on `start(startedAt:)` and cleared
    /// when the dictation transitions into the post-dictation follow-up
    /// window. Read by the end-of-recording pipeline to compute a duration
    /// for `TranscriptStore.append(...)`.
    private(set) var recordingStartedAt: Date?

    private init() {}

    func start(startedAt: Date) async {
        recordingStartedAt = startedAt
        clearFollowUpState()
    }

    func cancelPendingRecordingStart() async {
        recordingStartedAt = nil
        clearFollowUpState()
    }

    func update(phase _: DictationRuntimePhase) async {
        clearFollowUpState()
    }

    /// Transition into the shared follow-up window after a fresh dictation
    /// lands on the clipboard and in the ledger.
    func finish(preview _: String) async {
        recordingStartedAt = nil
        await showFollowUpWindow()
    }

    /// Transition into the shared follow-up window after a chained command
    /// result lands.
    ///
    /// Kept as a separate method (rather than a bool flag on `finish`) so the
    /// pipeline still reads as distinct fresh-vs-command outcomes.
    func finishCommand(instruction _: String, preview _: String) async {
        recordingStartedAt = nil
        await showFollowUpWindow()
    }

    private func showFollowUpWindow() async {
        let expiresAt = Date().addingTimeInterval(ChainedFollowUp.freshnessWindow)
        followUpExpiresAt = expiresAt
        isFollowUpActive = true
        scheduleFollowUpExpiry(at: expiresAt)
    }

    func dismissFollowUpWindow() async {
        clearFollowUpState()
    }

    private func scheduleFollowUpExpiry(at deadline: Date) {
        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task { @MainActor in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }

            self.followUpExpiresAt = nil
            self.isFollowUpActive = false
            self.followUpExpiryTask = nil
        }
    }

    private func clearFollowUpState() {
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        followUpExpiresAt = nil
        isFollowUpActive = false
    }
}
