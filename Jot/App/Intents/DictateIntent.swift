import ActivityKit
import AppIntents
import Foundation
import Observation

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
/// foreground.¹ That is solved by `openAppWhenRun = true`: Jot is brought to
/// the foreground for the brief window needed to activate the audio session.
///
/// We deliberately conform to the plain `AppIntent` — *not* the marker
/// protocol `AudioRecordingIntent`. An earlier iteration conformed to
/// `AudioRecordingIntent` on the theory that it would grant background-audio
/// continuation, but that conformance reproducibly caused the intent to be
/// *listed* in Settings → Action Button → Shortcut → Jot yet be
/// *un-selectable* (tapping didn't bind). The working hypothesis after
/// testing: Action Button's binding UI filters the specialized audio intent
/// protocols to apps that actually need to run in the background without a
/// foreground — which isn't us. Since `openAppWhenRun = true` foregrounds
/// Jot anyway, plain `AppIntent` is both sufficient and bindable.²
///
/// The pragmatic consequence for Experiment 4: the user *will* see Jot's app
/// come forward for a moment. The Live Activity (see `JotLiveActivity`) keeps
/// the UI quiet — we don't route the user into any Jot screen; the app just
/// hosts the audio session behind the pill. After stop, the recording layer
/// is expected to hand back to the previous app (or rely on the user's own
/// back-swipe). That policy lives in the App layer, not here.
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
    static let title: LocalizedStringResource = "Dictate with Jot"

    static let description = IntentDescription(
        """
        Press to start recording. Press again to stop. \
        Your speech is transcribed on-device and copied to the clipboard — \
        no network, no accounts.
        """,
        categoryName: "Dictation"
    )

    /// Forcing the app to foreground is required for microphone capture from
    /// a Shortcuts-invoked intent (see class doc). A `false` value here
    /// reliably produces an `AVAudioSession` activation failure the moment
    /// the recording layer tries to install its tap.
    static let openAppWhenRun: Bool = true

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
        // Controller is always non-nil now — the bridge lazy-constructs it on
        // first access. See `DictationIntentBridge` doc for why the earlier
        // register/await dance is gone. No cold-launch race to guard against:
        // in the `openAppWhenRun = true` path the app has already foregrounded
        // by the time `perform()` runs, and in every case the bridge's lazy
        // init runs synchronously inside this actor-hop.
        let controller = DictationIntentBridge.shared.controller

        switch controller.currentPhase {
        case .idle:
            try await beginDictation(using: controller)
        case .recording:
            try await endDictation(using: controller)
        case .transcribing, .processing, .cleaning:
            return .result()
        }

        return .result()
    }

    // MARK: - Toggle legs

    @MainActor
    private func beginDictation(using controller: any DictationController) async throws {
        let startedAt = Date()
        try await controller.startRecording(startedAt: startedAt)
        await DictationActivityCoordinator.shared.start(startedAt: startedAt)
    }

    @MainActor
    private func endDictation(using controller: any DictationController) async throws {
        // Capture `recordingStartedAt` BEFORE anything clears it — we need it
        // to compute the wall-clock duration `DictationPipeline` hands to
        // `TranscriptStore.append`. See the equivalent note in
        // `RecordAndTranscribeIntent.endDictation` for why this lives on
        // the coordinator singleton rather than on the intent struct.
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt ?? Date()

        await DictationActivityCoordinator.shared.update(phase: .transcribing)

        let transcript = try await controller.stopAndTranscribe()

        // Delegate to the shared pipeline. Must match the
        // `RecordAndTranscribeIntent` call site exactly — "no code-path
        // divergence" is a shipped invariant per the full-v2 brief: users who
        // bind the fallback intent must see identical observable behaviour
        // (clipboard, ledger rows, chained-follow-up classification) as
        // users who bind the primary intent. See `DictationPipeline`.
        try await DictationPipeline.completeEndOfRecording(
            transcript: transcript,
            startedAt: startedAt,
            controller: controller
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

    /// Stop capture and return the raw transcript.
    func stopAndTranscribe() async throws -> String

    /// Run cleanup over the transcript using the provided settings.
    func cleanup(transcript: String, settings: CleanupSettings) async throws -> String

    /// Enter the post-transcription follow-up resolution window.
    func beginPostProcessing()

    /// End the post-transcription follow-up resolution window.
    func endPostProcessing()
}

/// The intent's view of runtime state. Separate from
/// `DictationAttributes.Phase` because that's a codable, presentation-layer
/// description — this is a lightweight `idle | in-flight` signal the intent
/// uses solely to decide which toggle leg to run.
enum DictationRuntimePhase: Sendable {
    case idle
    case recording
    case transcribing
    case processing
    case cleaning
}

enum AudioRecordingIntentPreflightError: LocalizedError, Sendable {
    case liveActivitiesDisabled
    case liveActivityRequestFailed(String)
    case liveActivityNotObserved

    var errorDescription: String? {
        switch self {
        case .liveActivitiesDisabled:
            return "Live Activities are turned off for Jot. Turn them on, then try the Action Button again."
        case .liveActivityRequestFailed(let detail):
            return "Jot could not start the recording Live Activity: \(detail)"
        case .liveActivityNotObserved:
            return "Jot could not confirm the recording Live Activity started. Try again."
        }
    }
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

    private init() {
        self.controller = DictationControllerImpl()
    }
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
///   raw transcript and the pipeline takes it from there.
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
        try await recording.start()
        currentPhase = .recording
    }

    func stopAndTranscribe() async throws -> String {
        currentPhase = .transcribing
        // Mark idle on any exit path — success or throw — so a failed
        // transcription doesn't leave the toggle stuck in `.transcribing`
        // and force the user to re-launch the app to clear it.
        defer { currentPhase = .idle }

        let samples = try await recording.stop()
        let transcript = try await TranscriptionService.shared.transcribe(samples: samples)
        return transcript
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

// MARK: - Live Activity coordinator

/// Thin wrapper over `ActivityKit` so the intent's `perform()` reads as a
/// phase machine instead of a procession of `Activity.request`/`update`/`end`
/// calls.
///
/// Scoped `internal` because only the intent drives the pill today. If the
/// recording layer later wants to update the activity directly (e.g. to show
/// a live waveform) we'll promote this to a top-level type.
@MainActor
@Observable
final class DictationActivityCoordinator {
    static let shared = DictationActivityCoordinator()

    private var handle: ActivityHandle?
    private var followUpExpiryTask: Task<Void, Never>?
    private(set) var followUpExpiresAt: Date?
    private(set) var isFollowUpActive = false

    /// Recording-start timestamp, captured on `start(startedAt:)` and cleared
    /// when the activity transitions into the post-dictation follow-up window.
    /// Exposed so the end-of-recording pipeline can
    /// compute a duration for `TranscriptStore.append(...)` without having to
    /// re-derive it from the Live Activity state (which would force us to
    /// pattern-match the `.recording(startedAt:)` associated value and which
    /// has already been replaced with `.transcribing` by the time we need
    /// the duration).
    ///
    /// Unconditionally set/cleared — not gated on the Live Activity handle
    /// actually coming up — so a user on a device where Live Activities are
    /// disabled still gets a recorded duration in the transcript history.
    private(set) var recordingStartedAt: Date?

    private init() {}

    func start(startedAt: Date) async {
        recordingStartedAt = startedAt
        clearFollowUpState()

        let initial = DictationAttributes.ContentState(phase: .recording(startedAt: startedAt))
        let content = ActivityContent(state: initial, staleDate: nil)

        if let handle {
            await handle.update(content)
            return
        }

        do {
            let requested = try Activity.request(
                attributes: DictationAttributes(),
                content: content,
                pushType: nil
            )
            handle = ActivityHandle(activity: requested)
        } catch {
            // `ActivityAuthorizationError.denied` (user disabled Live
            // Activities) or `.unsupported` (iPhone without Dynamic Island on
            // a build that requires it). Recording still works — we just
            // won't have the pill. The App layer's toast system is responsible
            // for surfacing this; the intent shouldn't fail the dictation
            // because the UI chrome couldn't come up.
            handle = nil
        }
    }

    func startForAudioRecordingIntent(startedAt: Date) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw AudioRecordingIntentPreflightError.liveActivitiesDisabled
        }

        recordingStartedAt = startedAt
        clearFollowUpState()

        let initial = DictationAttributes.ContentState(phase: .recording(startedAt: startedAt))
        let content = ActivityContent(state: initial, staleDate: nil)

        if let handle {
            await handle.update(content)
            guard await Self.waitForActivity(id: handle.activity.id) else {
                self.handle = nil
                recordingStartedAt = nil
                throw AudioRecordingIntentPreflightError.liveActivityNotObserved
            }
            return
        }

        let requested: Activity<DictationAttributes>
        do {
            requested = try Activity.request(
                attributes: DictationAttributes(),
                content: content,
                pushType: nil
            )
        } catch {
            recordingStartedAt = nil
            throw AudioRecordingIntentPreflightError.liveActivityRequestFailed(
                error.localizedDescription
            )
        }

        handle = ActivityHandle(activity: requested)

        guard await Self.waitForActivity(id: requested.id) else {
            await requested.end(content, dismissalPolicy: .immediate)
            handle = nil
            recordingStartedAt = nil
            throw AudioRecordingIntentPreflightError.liveActivityNotObserved
        }
    }

    func cancelPendingRecordingStart() async {
        recordingStartedAt = nil
        clearFollowUpState()

        guard let handle else { return }

        let content = ActivityContent(
            state: DictationAttributes.ContentState(phase: .followUp(expiresAt: Date())),
            staleDate: Date()
        )
        await handle.end(content, dismissAt: Date())
        self.handle = nil
    }

    func update(phase: DictationAttributes.Phase) async {
        clearFollowUpState()
        guard let handle else { return }
        let content = ActivityContent(
            state: DictationAttributes.ContentState(phase: phase),
            staleDate: nil
        )
        await handle.update(content)
    }

    /// Transition the activity into the shared follow-up window after a fresh
    /// dictation lands on the clipboard and in the ledger.
    func finish(preview _: String) async {
        recordingStartedAt = nil
        await showFollowUpWindow()
    }

    /// Transition the activity into the shared follow-up window after a
    /// chained command result lands.
    ///
    /// Kept as a separate method (rather than a bool flag on `finish`) so the
    /// pipeline still reads as distinct fresh-vs-command outcomes even though
    /// both outcomes now converge on the same visible `.followUp` state.
    func finishCommand(instruction _: String, preview _: String) async {
        recordingStartedAt = nil
        await showFollowUpWindow()
    }

    private func showFollowUpWindow() async {
        let expiresAt = Date().addingTimeInterval(ChainedFollowUp.freshnessWindow)
        followUpExpiresAt = expiresAt
        isFollowUpActive = true
        scheduleFollowUpExpiry(at: expiresAt)

        guard let handle else { return }
        let content = ActivityContent(
            state: DictationAttributes.ContentState(
                phase: .followUp(expiresAt: expiresAt)
            ),
            staleDate: expiresAt
        )
        await handle.update(content)
    }

    func dismissFollowUpWindow() async {
        let expiresAt = followUpExpiresAt ?? Date()
        clearFollowUpState()

        guard let handle else { return }

        let content = ActivityContent(
            state: DictationAttributes.ContentState(phase: .followUp(expiresAt: expiresAt)),
            staleDate: Date()
        )
        await handle.end(content, dismissAt: Date())
        self.handle = nil
    }

    private func scheduleFollowUpExpiry(at deadline: Date) {
        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task { @MainActor in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }

            let content = ActivityContent(
                state: DictationAttributes.ContentState(phase: .followUp(expiresAt: deadline)),
                staleDate: deadline
            )
            self.followUpExpiresAt = nil
            self.isFollowUpActive = false
            self.followUpExpiryTask = nil
            guard let handle else { return }
            await handle.end(content, dismissAt: Date())
            self.handle = nil
        }
    }

    private func clearFollowUpState() {
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        followUpExpiresAt = nil
        isFollowUpActive = false
    }

    private static func waitForActivity(id: String) async -> Bool {
        for _ in 0..<10 {
            if Activity<DictationAttributes>.activities.contains(where: { $0.id == id }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
}

/// `@unchecked Sendable` wrapper around `Activity<DictationAttributes>`.
///
/// ## Why this exists
///
/// `Activity<Attributes>` is a non-`Sendable` reference type. Every attempt to
/// `await activity.update(...)` from a `@MainActor`-isolated property trips
/// Swift 6's region-based isolation checker with *"sending 'activity' risks
/// causing data races"* — once directly, and a second time when we tried to
/// `sending`-return the handle out of storage so a nonisolated helper could
/// take it.
///
/// ## Why the assertion is sound
///
/// ActivityKit's `update(_:)` and `end(_:dismissalPolicy:)` are documented
/// as callable from any actor: both methods marshal their payload to the
/// ActivityKit daemon out-of-process and own no caller-visible state. There
/// is nothing to race on the Swift side. The type simply isn't *annotated*
/// `Sendable` — so we annotate a box around it, narrowly, with a clear
/// justification.
private struct ActivityHandle: @unchecked Sendable {
    let activity: Activity<DictationAttributes>

    func update(_ content: ActivityContent<DictationAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<DictationAttributes.ContentState>,
        dismissAt: Date
    ) async {
        await activity.end(content, dismissalPolicy: .after(dismissAt))
    }
}

extension AudioRecordingIntentPreflightError: CustomNSError {
    static var errorDomain: String { "Jot.AudioRecordingIntentPreflightError" }

    var errorCode: Int {
        switch self {
        case .liveActivitiesDisabled: return 0
        case .liveActivityRequestFailed: return 1
        case .liveActivityNotObserved: return 2
        }
    }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "Live Activity preflight failed."]
    }
}

extension AudioRecordingIntentPreflightError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .liveActivitiesDisabled:
            return "Turn on Live Activities for Jot to record from the Action Button."
        case .liveActivityRequestFailed:
            return "Jot could not start its recording indicator. Try the Action Button again."
        case .liveActivityNotObserved:
            return "Jot could not confirm the recording indicator started. Try again."
        }
    }
}
