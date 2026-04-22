@preconcurrency import AVFoundation
import Foundation
import os.log

@MainActor
@Observable
final class RecordingService {
    enum RecordingError: LocalizedError {
        case alreadyRunning
        case notRunning
        case converterUnavailable
        case sessionConfiguration(Error)
        case engineStart(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A recording is already in progress."
            case .notRunning: return "No recording is in progress."
            case .converterUnavailable: return "Could not build the 16 kHz audio converter."
            case .sessionConfiguration(let error): return "Audio session error: \(error.localizedDescription)"
            case .engineStart(let error): return "Audio engine failed to start: \(error.localizedDescription)"
            }
        }
    }

    /// Process-wide singleton. Both the foreground scene (`JotApp.swift` →
    /// `ContentView`) and the headless intent surface (`DictationControllerImpl`
    /// in `DictateIntent.swift`) MUST read from this one instance.
    ///
    /// ## Why process-wide (not per-surface)
    ///
    /// `AVAudioSession` is a process-global singleton enforced by iOS — there
    /// is exactly one audio session per process, whatever Swift code thinks it
    /// owns. Having two `RecordingService` instances against one session
    /// produces a subtle but real bug: each instance stashes its own
    /// `priorCategory` / `priorMode` / `priorOptions` at `configureSession()`
    /// time for restore-on-stop. If both configure in sequence (e.g. user
    /// records in-app → backgrounds → fires Action Button), the second
    /// instance stashes the ALREADY-MODIFIED session state as its "prior"
    /// and its `restoreSession()` then restores to what the first instance
    /// set, not the true pre-Jot baseline. Session state leaks forward across
    /// dictations.
    ///
    /// Singleton consolidation makes the stash-and-restore pair read and
    /// write the same private slots across every recording call site, so the
    /// "prior" state captured at the start of a record is always the true
    /// baseline — no matter which surface triggered it.
    ///
    /// ## Why pinned `@MainActor`
    ///
    /// `RecordingService` is `@MainActor`-isolated (class-level). Swift 6
    /// strict concurrency requires the static property initializer to match
    /// the actor isolation of the constructed value; the `@MainActor` on
    /// the property itself provides that. Same shape as
    /// `TranscriptionService.shared` — keep them aligned so a future reader
    /// doesn't have to re-derive the reasoning.
    ///
    /// ## What this does NOT force
    ///
    /// Callers that deliberately want a disposable fresh instance (tests,
    /// future SwiftUI previews, one-off capture workflows) are still free to
    /// `RecordingService()`. The singleton is additive, not exclusive.
    @MainActor static let shared = RecordingService()

    private(set) var isRecording: Bool = false

    /// Normalized RMS amplitude (0.0 – 1.0) updated at ~30 Hz while a recording
    /// is active; `nil` when idle. This is the contract the status-pill
    /// waveform reads via `@Environment(RecordingService.self)` so the viz
    /// reflects real mic input instead of a synthetic oscillator.
    ///
    /// Updated from the audio tap via a MainActor hop (`Task { @MainActor … }`);
    /// writes to this property always happen on the MainActor, so Observation's
    /// dirty-tracking stays consistent. Rate-limited upstream by
    /// `AmplitudeGate` — do **not** try to publish per-buffer.
    private(set) var currentAmplitude: Float? = nil

    private let log = Logger(subsystem: "com.jot.mobile.Jot", category: "recording")

    private var engine: AVAudioEngine?
    private var capture: CaptureContext?
    // Array rather than Set because `NSObjectProtocol` isn't Hashable.
    // We only ever iterate to remove — semantics are identical.
    private var observers: [NSObjectProtocol] = []

    // Saved session state so we don't steal config from other apps on stop.
    private var priorCategory: AVAudioSession.Category?
    private var priorMode: AVAudioSession.Mode?
    private var priorOptions: AVAudioSession.CategoryOptions?

    init() {}

    func start() async throws {
        guard !isRecording else { throw RecordingError.alreadyRunning }

        try configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: Self.target) else {
            restoreSession()
            throw RecordingError.converterUnavailable
        }

        let capture = CaptureContext(converter: converter, inputFormat: hardwareFormat, target: Self.target, log: log)

        // Per best-practices §1.2 + §1.3: the tap fires on AVAudioEngine's
        // audio-render thread, not on any actor. `CaptureContext` owns the
        // converter + lock-protected sample buffer (see invariant note on
        // that type at the bottom of this file), so the audio thread stays
        // entirely off-actor and no `MainActor.assumeIsolated` appears in
        // the hot path.
        //
        // **The `@Sendable` annotation below is load-bearing, not cosmetic.**
        //
        // Swift 6 isolation inference: a closure passed to a non-`@Sendable`
        // parameter inherits the enclosing actor's isolation. `start()` is
        // `@MainActor`, and `AVAudioNodeTapBlock` is not `@Sendable` — so by
        // default this closure is silently `@MainActor`-isolated. `@preconcurrency
        // import AVFoundation` suppresses the *diagnostic* about sending a
        // non-Sendable closure into Apple code; it does NOT change the
        // closure's inferred isolation. When the audio-render thread later
        // invokes the closure, Swift 6's runtime runs
        // `swift_task_checkIsolated(MainActor.shared)` at closure entry, which
        // lowers to `dispatch_assert_queue(main_queue)` and traps with
        // "BLOCK was expected to execute on queue" — a crash reproduced on
        // iPhone 17 / iOS 26.2 immediately after `phase → recording`.
        //
        // Marking the closure `@Sendable` breaks isolation inheritance so it's
        // nonisolated at invocation time — which is the contract the audio
        // tap actually needs. The sole captured reference (`capture`) is
        // `@unchecked Sendable` with the invariant documented on `CaptureContext`.
        //
        // The `log.debug` below is a one-shot diagnostic (gated by `tapOnce`)
        // so the next device-console capture records the real queue identity.
        // Expected: an audio-render thread (e.g. `com.apple.coreaudio.AURemoteIO`
        // / `com.apple.audio.IOThread.client`) and NOT the main queue.
        // Deliberately NOT `print`: stdio acquires an internal lock and is not
        // real-time-safe, whereas `os_log` (backing `Logger`) was explicitly
        // designed to be callable from audio callbacks. One-shot so we don't
        // add any per-buffer overhead (buffers fire ~12×/sec at 4096@48kHz).
        // Remove the `TapOnceGate` + the `log.debug` line once verified on-device.
        let tapOnce = TapOnceGate()
        // ~30 Hz refresh: one MainActor hop every ~33 ms. The tap itself fires
        // at hardware buffer cadence (~12 Hz at 4096@48kHz but can exceed 100 Hz
        // at smaller buffers), so gating here avoids flooding the run loop
        // with amplitude updates that Observation would dirty-track redundantly.
        let amplitudeGate = AmplitudeGate(intervalMS: 33)
        let tapLog = log  // local Sendable copy; avoids capturing MainActor `self`
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [capture, tapOnce, amplitudeGate, tapLog, weak self] pcm, _ in
            if tapOnce.fireOnce() {
                tapLog.debug("[recording] first tap callback on \(Thread.current.description, privacy: .public)")
            }
            capture.ingest(pcm)

            // Amplitude publication: compute RMS on the raw hardware buffer
            // (cheap — one sum-of-squares pass over frameLength floats), gate
            // to ~30 Hz, then hop to MainActor to write the @Observable
            // property. `Task { @MainActor in … }` is the sanctioned pattern
            // for audio-thread → MainActor publication (see best-practices §1.3).
            // We capture `self` weakly so the service can deallocate normally;
            // `self` is MainActor-isolated and therefore Sendable, which makes
            // the weak capture legal inside this @Sendable closure.
            if amplitudeGate.shouldFire(), let amp = normalizedAmplitude(pcm) {
                // `self` here is the outer closure's already-weak capture,
                // so it's an `Optional<RecordingService>`. The Task reads it
                // by value; if the service has deallocated by the time the
                // MainActor turn runs, `self?.…` short-circuits harmlessly.
                Task { @MainActor in
                    self?.currentAmplitude = amp
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            restoreSession()
            throw RecordingError.engineStart(error)
        }

        self.engine = engine
        self.capture = capture
        subscribeSystemObservers(engine: engine)
        isRecording = true
        log.info("Recording started at hardware \(Int(hardwareFormat.sampleRate))Hz/\(Int(hardwareFormat.channelCount))ch")
    }

    func stop() async throws -> [Float] {
        // Tolerant of the case where an interruption / route change already
        // tore down the engine internally: the UI still calls stop() and
        // expects whatever samples we collected. Only throw `.notRunning` if
        // we have no capture at all — there was nothing to stop.
        guard let capture else { throw RecordingError.notRunning }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        let samples = capture.drain()

        unsubscribeSystemObservers()
        self.engine = nil
        self.capture = nil
        restoreSession()
        isRecording = false
        currentAmplitude = nil

        let seconds = Double(samples.count) / Self.sampleRate
        log.info("Recording stopped — \(samples.count) samples (~\(seconds, privacy: .public)s)")
        return samples
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        priorCategory = session.category
        priorMode = session.mode
        priorOptions = session.categoryOptions

        do {
            // 2026-04-21 approved fix for the Action Button `AURemoteIO`
            // invalid-state failure: stop asking the background path to bring
            // up a duplex `.playAndRecord` graph when it only needs microphone
            // input. `.record` keeps the no-DSP `.measurement` mode while
            // avoiding the output leg that was implicated in the `what` trace.
            log.info("configureSession — calling setCategory(.record, .measurement, [.mixWithOthers])")
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.mixWithOthers]
            )
            log.info("configureSession — setCategory OK; now calling setActive(true)")
            try session.setActive(true, options: [])
            log.info("configureSession — setActive(true) OK")
        } catch {
            // Explicit NSError diagnostics. `privacy: .public` so the actual
            // domain + code + description survive syslog privacy filtering —
            // we NEED these values to diagnose on-device session-activation
            // failures. The prior "Session activation failed" string is the
            // NSError's localizedDescription; domain/code tell us WHICH
            // AVAudioSessionErrorCode case fired, which is what separates
            // "nonmixable in background" from "invalid option tuple" from
            // "another app holds the session."
            let ns = error as NSError
            log.error(
                "configureSession FAILED — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) localizedDescription=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)"
            )
            throw RecordingError.sessionConfiguration(error)
        }
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()

        // Deactivation and category-restore are logged independently because
        // they have very different severity. `setActive(false)` is the prime
        // suspect for the `com.apple.frontboard.after-life.interrupted`
        // zombie-process bug: if iOS thinks we're still using audio, it holds
        // the process in limbo rather than suspending-then-reaping it, and
        // the next Action Button press surfaces as a cryptic "Operation
        // couldn't be completed." Category restore is cosmetic — if it
        // fails, the next app's session config will overwrite whatever we
        // left anyway. Splitting the logs lets us pattern-match the right
        // one in idevicesyslog. Include NSError `domain` + `code` so we can
        // cross-reference against Apple's `AVFoundationErrorDomain` constants.
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            let ns = error as NSError
            log.error("AVAudioSession.setActive(false) failed — domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public). Session may stay active; process may not suspend cleanly.")
        }

        if let priorCategory, let priorMode, let priorOptions {
            do {
                try session.setCategory(priorCategory, mode: priorMode, options: priorOptions)
            } catch {
                let ns = error as NSError
                log.error("AVAudioSession.setCategory restore failed — domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public).")
            }
        }

        priorCategory = nil
        priorMode = nil
        priorOptions = nil
    }

    /// Aggressively tear down any in-flight recording. Safe to call from any
    /// state; if we're not recording, this still runs the deactivation path
    /// as defense-in-depth (no-op on a non-active session). Never throws;
    /// errors are logged and swallowed.
    ///
    /// This is the hook for scene-disconnect (`scenePhase → .background`)
    /// and hard interruption paths. The user has already decided to leave
    /// the app's foreground — we prioritize a clean AVAudioSession teardown
    /// over preserving half-collected samples, because holding the session
    /// active past scene-disconnect is the suspected cause of the
    /// `com.apple.frontboard.after-life.interrupted` zombie-process state
    /// that breaks subsequent Action Button cold-launches.
    ///
    /// Discards captured samples silently. If the caller needs the samples,
    /// they must call `stop()` on the happy path, not this.
    func forceStop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        unsubscribeSystemObservers()
        self.engine = nil
        self.capture = nil
        restoreSession()
        isRecording = false
        currentAmplitude = nil
        log.info("Force-stop complete (scene-disconnect / hard interruption path).")
    }

    // MARK: - System observers (best-practices §2.3, §2.4, §2.5)

    private func subscribeSystemObservers(engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // Interruption: phone call, Siri, other .playback session. Pre-extract
        // the Sendable `typeRaw` before hopping to MainActor so we don't
        // capture the non-Sendable Notification across the boundary.
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw)
            }
        }

        // Route change: AirPods disconnect, wired headphones pulled, etc.
        // Only `.oldDeviceUnavailable` warrants stopping — the input device
        // we were using is gone, and silent fallback to the internal mic
        // would be a WER disaster the user can't debug.
        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        // Engine configuration change: AirPlay handoff, FaceTime starting,
        // system picking a new sample rate. Our tap would keep firing against
        // a stale input format and CaptureContext would drop every buffer.
        // Stop cleanly; user presses Record again to rebuild.
        let engineConfig = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigChange()
            }
        }

        observers = [interruption, route, engineConfig]
    }

    private func unsubscribeSystemObservers() {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func handleInterruption(typeRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            log.notice("Audio session interrupted — stopping recording")
            internalStop(reason: "interruption")
        case .ended:
            // Per spec: do not auto-resume. User re-presses Record.
            // `.shouldResume` only advises us; we still defer to the user.
            break
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            log.notice("Audio route device went away — stopping recording")
            internalStop(reason: "route change")
        }
        // `.newDeviceAvailable` and friends are ignored: iOS already did the
        // right routing, and interrupting capture on every AirPod reconnect
        // would feel broken.
    }

    private func handleEngineConfigChange() {
        log.notice("Engine configuration changed — stopping recording")
        internalStop(reason: "engine config change")
    }

    /// Tear down the engine and session without draining samples. The
    /// samples remain in `capture` so a subsequent `stop()` call from the
    /// UI can still return whatever we captured before the interruption.
    private func internalStop(reason: String) {
        guard isRecording, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        unsubscribeSystemObservers()
        self.engine = nil
        restoreSession()
        isRecording = false
        currentAmplitude = nil
        log.info("Internal stop (\(reason, privacy: .public)) — samples retained for drain")
    }

    // MARK: - Target format

    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1
    static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
}

/// One-shot gate for the tap-callback diagnostic log.
///
/// Reference type so the `@Sendable` tap closure can capture it by value (the
/// reference) while still mutating the `fired` flag through the lock. The tap
/// block is invoked serially per AVAudioEngine's contract, so the lock here is
/// defense-in-depth — it also makes the class legitimately `Sendable` without
/// the `@unchecked` escape hatch being required for correctness.
///
/// This exists purely to bound the diagnostic `log.debug` at the top of the
/// tap closure to a single invocation — we want the queue identity confirmed
/// on-device once, without emitting per-buffer (~12/sec at 4096@48kHz) log
/// traffic on the audio-render thread for the lifetime of the recording.
/// Remove alongside the diagnostic once the fix is verified on-device.
private final class TapOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns `true` exactly once; every subsequent call returns `false`.
    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Rate-limiter for audio-thread → MainActor amplitude updates.
///
/// The tap fires at the hardware buffer cadence: ~12 Hz at 4096 frames @
/// 48 kHz, but much higher at smaller buffers some route changes can install.
/// Dispatching a MainActor task per buffer would flood the run loop and burn
/// CPU on Observation dirty-tracking for a viz the user only sees updated at
/// screen refresh. ~30 Hz is plenty for a VU-style waveform and stays under
/// the display refresh rate we care about.
///
/// Serialization: the AVAudioEngine tap contract invokes the block serially,
/// so in practice contention is zero — the lock is defense-in-depth and also
/// makes the class legitimately Sendable without `@unchecked` being required
/// for correctness. `DispatchTime.now().uptimeNanoseconds` is nonblocking and
/// real-time-safe (it's a mach_absolute_time read).
private final class AmplitudeGate: @unchecked Sendable {
    private let intervalNS: UInt64
    private let lock = NSLock()
    private var lastFiredNS: UInt64 = 0

    init(intervalMS: Double) {
        self.intervalNS = UInt64(intervalMS * 1_000_000)
    }

    /// Returns `true` if at least `intervalMS` has elapsed since the last
    /// `true` return. Updates the internal timestamp on a `true` return so the
    /// caller is the sole source of truth for rate.
    func shouldFire() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        if now &- lastFiredNS >= intervalNS {
            lastFiredNS = now
            return true
        }
        return false
    }
}

/// Compute a display-ready normalized amplitude (0.0 – 1.0) from a raw
/// hardware PCM buffer.
///
/// Returns `nil` when the buffer isn't Float32 non-interleaved (the format
/// AVAudioEngine input delivers on iOS) — the caller skips publication and
/// the viz simply won't update for that frame.
///
/// **Scaling rationale.** Raw linear RMS for real speech sits around
/// 0.03 – 0.2 (−30 to −14 dBFS). Returning raw RMS would leave the pill's
/// waveform barely moving. We apply a mild compression — `sqrt(rms × 4)`
/// clamped to [0, 1] — so that noise floor stays visibly low while normal
/// conversational speech covers the middle-to-upper range. This is simpler
/// than a full dBFS → [0, 1] mapping and gives a VU-meter feel without
/// needing the view layer to understand dB scale.
///
/// Called on the audio-render thread — keep this allocation-free and
/// lock-free. The one buffer read is a pointer walk over `frameLength`
/// floats; no heap allocation, no Objective-C messaging on the hot path.
private func normalizedAmplitude(_ pcm: AVAudioPCMBuffer) -> Float? {
    guard let channelData = pcm.floatChannelData else { return nil }
    let frameLength = Int(pcm.frameLength)
    guard frameLength > 0 else { return 0 }

    let samples = channelData[0]
    var sumSquares: Float = 0
    for i in 0..<frameLength {
        let s = samples[i]
        sumSquares += s * s
    }
    let rms = sqrt(sumSquares / Float(frameLength))
    // Compression curve: sqrt(rms * 4) maps
    //   ambient noise 0.005 → 0.14
    //   quiet speech  0.03  → 0.35
    //   normal speech 0.1   → 0.63
    //   loud speech   0.2   → 0.89
    // Clamped to [0, 1] so the view layer has a bounded contract.
    return min(1.0, max(0.0, sqrt(rms * 4.0)))
}

/// Owns the per-capture converter and sample buffer. Lives off the MainActor
/// so the audio tap can convert + append without hopping.
///
/// `@unchecked Sendable` invariant (per best-practices §1.7): only two
/// callers exist — the audio tap (running on an audio-priority thread) and
/// `RecordingService.stop()` / `internalStop` on the MainActor. The tap is
/// removed before `drain()` is called, so converter/storage access never
/// overlaps across threads. Mutable `storage` is additionally guarded by a
/// lock as defense-in-depth. Do not add callers.
private final class CaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let target: AVAudioFormat
    private let log: Logger
    private var storage: [Float] = []

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, target: AVAudioFormat, log: Logger) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.target = target
        self.log = log
    }

    func ingest(_ pcm: AVAudioPCMBuffer) {
        // Drop buffers whose format disagrees with the converter — a route
        // change mid-recording would trigger this, and the engine-config
        // observer on the service will tear down the tap shortly.
        guard pcm.format == inputFormat else { return }

        let ratio = target.sampleRate / pcm.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: estimatedFrames) else {
            return
        }

        var supplied = false
        var err: NSError?
        let status = converter.convert(to: outBuffer, error: &err) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return pcm
        }

        switch status {
        case .error:
            log.error("Conversion error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
            return
        case .haveData, .inputRanDry, .endOfStream:
            break
        @unknown default:
            break
        }

        guard let channelData = outBuffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))

        lock.lock()
        storage.append(contentsOf: samples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let out = storage
        storage = []
        lock.unlock()
        return out
    }
}

// MARK: - Error bridging for Shortcuts / NSError consumers
//
// Shortcuts reports thrown intent errors by rendering the bridged NSError. A
// plain `LocalizedError` enum bridges via Swift's automatic path, which sets
// the domain to the mangled type name AND — more painfully for diagnostics —
// defaults `errorCode` to 0 for every case. The user-facing banner then reads
// as `"<mangled-domain> error 0"` no matter which case actually fired. The
// "Recording error 0" repro on device today is indistinguishable between
// `.alreadyRunning` (race on the toggle), `.engineStart(error)` (AVAudioSession
// conflict with the foreground scene's RecordingService instance), or
// `.converterUnavailable` (hardware format mismatch) — all three render the
// same.
//
// `CustomNSError` locks the error domain + numeric codes so the bridged
// NSError is stable and diagnostic. External tooling (unified log predicates,
// screenshots, user-reported bug IDs) gets a contract it can rely on. Codes
// are assigned to match Swift's default enum-ordinal bridging at the time of
// writing so historical "Recording error N" reports stay interpretable —
// `alreadyRunning = 0` is already the value today, just by accident of being
// the first case; pinning it here makes that value a promise rather than an
// artifact.
//
// `CustomLocalizedStringResourceConvertible` is the AppIntents-era hook: when
// an intent throws, Shortcuts reads this resource instead of the bridged
// `localizedDescription`. `LocalizedError.errorDescription` stays implemented
// as a fallback for non-AppIntents callers (e.g. main-app UI alerts surfacing
// a recording failure).
//
// Mirrors the `TranscriptionService.TranscriptionError` conformances at the
// bottom of `TranscriptionService.swift` — the one departure is that
// `RecordingError`'s user-facing text is phrased as actionable recovery ("Stop
// the current recording before starting another.") rather than a status
// report. Recording failures land on an Action Button press where the user
// has no obvious next step; telling them what to do matters more than telling
// them what happened.

extension RecordingService.RecordingError: CustomNSError {
    /// Public error domain. Treat as API — logs / screenshots / bug reports
    /// reference it. Renames require migration.
    public static var errorDomain: String { "Jot.RecordingService.RecordingError" }

    /// Stable numeric codes. Table is the public contract; do NOT renumber.
    /// - 0: `alreadyRunning`
    /// - 1: `notRunning`
    /// - 2: `converterUnavailable`
    /// - 3: `sessionConfiguration(Error)`
    /// - 4: `engineStart(Error)`
    public var errorCode: Int {
        switch self {
        case .alreadyRunning: return 0
        case .notRunning: return 1
        case .converterUnavailable: return 2
        case .sessionConfiguration: return 3
        case .engineStart: return 4
        }
    }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "Recording error."]
    }
}

extension RecordingService.RecordingError: CustomLocalizedStringResourceConvertible {
    /// Rendered by Shortcuts / AppIntents surfaces when an intent's
    /// `perform()` throws. Keep strings user-facing and actionable — the
    /// recipient is someone looking at an opaque Shortcut failure banner on
    /// an Action Button press, with no obvious "what do I do next" affordance.
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .alreadyRunning:
            return "Jot is already recording. Stop the current recording before starting another."
        case .notRunning:
            return "No Jot recording is in progress."
        case .converterUnavailable:
            return "Jot could not prepare the 16 kHz audio converter. Restart the app and try again."
        case .sessionConfiguration(let error):
            return "Audio session could not be configured: \(error.localizedDescription)"
        case .engineStart(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        }
    }
}
