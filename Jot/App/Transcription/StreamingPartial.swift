@preconcurrency import AVFoundation
import ActivityKit
import FluidAudio
import Foundation
import os.log

/// Live partial-transcript presenter for the dual-model streaming preview
/// (FluidAudio `StreamingEouAsrManager` Parakeet EOU 120M @ 320ms).
///
/// Bound by `ContentView` to render volatile-then-final dictation text per
/// Apple's HIG (`.secondary` while volatile, `.primary` once batch overrides).
/// The presenter is the UI half of the streaming pipeline; the inference
/// half lives off MainActor in `StreamingTranscriptionEngine` (this file)
/// and the audio-thread fan-out lives in `RecordingService.installTap`.
///
/// ## Why a separate session token from `RecordingService.currentSessionID`
///
/// `RecordingService.currentSessionID` is the dictation pipeline UUID
/// shared with the keyboard via `PendingPasteSession.id` and managed by
/// `adoptSession` / `publishPipelinePhase` — touching it would break v7
/// auto-paste session matching.
///
/// `StreamingPartial.currentSessionID` is a SEPARATE UUID minted per
/// streaming session. It exists solely to drop late partial-transcript
/// callbacks that arrive after `stop()` has already promoted the tail to
/// finalized — without this guard, a late MainActor-queued task would flip
/// `streamingIsVolatile` back to `true` after `.primary` styling has
/// landed. Per dual-model prototype rounds 3-4 verdict.
@MainActor
@Observable
final class StreamingPartial {
    /// Cumulative partial transcript currently rendered to the user.
    /// FluidAudio's EOU manager always emits cumulative (not incremental)
    /// text — each callback replaces this whole field rather than appending.
    private(set) var streamingText: String = ""

    /// `true` while in-flight partials are arriving (render with `.secondary`).
    /// Flips to `false` when `update(text:isFinal:sessionID:)` is called with
    /// `isFinal: true` (typically the post-`finish()` finalization, then the
    /// batch override on top). The batch transition is a separate `reset()`
    /// call — see `RecordingService.stop()` for the ordering.
    private(set) var streamingIsVolatile: Bool = false

    /// Active session token. Updates whose `sessionID` parameter doesn't
    /// match this are dropped on the floor. Cleared by `clearSession()`
    /// BEFORE `streamingManager.finish()` per prototype rounds 3-4.
    private(set) var currentSessionID: UUID?

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "streaming-partial"
    )

    init() {}

    /// Mints a fresh session token and clears any prior partial text. Called
    /// by `RecordingService.start()` BEFORE the streaming engine begins
    /// receiving samples.
    func beginSession() -> UUID {
        let id = UUID()
        currentSessionID = id
        streamingText = ""
        streamingIsVolatile = false
        // Publish an empty projection immediately so a fast re-record never
        // shows the previous session's final text in the keyboard's
        // streaming strip during the brief gap before the first partial
        // arrives. Bypasses the throttle in `publishProjection` since this
        // is a session-start terminal event.
        Self.publishProjection("", force: true)
        return id
    }

    /// Apply a partial-transcript update from the streaming engine.
    /// Drops the update if the supplied `sessionID` doesn't match the active
    /// token — the canonical defense against late MainActor-queued callbacks
    /// from a previous session.
    ///
    /// `isFinal: true` is reserved for the post-`finish()` finalization step
    /// in `RecordingService.stop()`. The subsequent batch-result swap should
    /// go through `reset()` (clears the streaming preview entirely) so the
    /// recorder bar's persistent transcript history takes over the visual
    /// slot.
    func update(text: String, isFinal: Bool, sessionID: UUID) {
        guard currentSessionID == sessionID else {
            log.debug("Dropping partial from stale session \(sessionID, privacy: .public)")
            return
        }
        streamingText = text
        streamingIsVolatile = !isFinal
        // Force-publish on `isFinal` so the keyboard's volatile→primary
        // visual handoff isn't dropped by the throttle.
        Self.publishProjection(text, force: isFinal)
    }

    /// Clears the session token without touching displayed text. Called BEFORE
    /// `streamingManager.finish()` so any in-flight `processBufferedAudio`
    /// emissions arrive after the token is cleared and no-op via the guard
    /// in `update(...)`. Per prototype `DualRecorder.swift:271-291`.
    func clearSession() {
        currentSessionID = nil
    }

    /// Applies the post-`finish()` final-snapshot text to the presenter.
    /// **Bypasses the session-token guard** because by the time this is
    /// called the token has already been cleared by `clearSession()`
    /// (per the prototype rounds-3-4 ordering: clear-then-finish).
    /// Without bypassing the guard, the post-`finish()` text would
    /// never reach the UI.
    ///
    /// Sets `streamingText` and flips `streamingIsVolatile` to `false` so
    /// the UI transitions from `.secondary` to `.primary` for the brief
    /// pre-batch tail. The subsequent `reset()` (called when the batch
    /// transcript overrides the preview) blanks both back to defaults.
    ///
    /// Naming: this is the post-session promote, NOT a partial-callback
    /// update — kept distinct from `update(...)` so call sites read the
    /// intent clearly.
    func applyFinalSnapshot(_ text: String) {
        streamingText = text
        streamingIsVolatile = false
        // Terminal event — bypass the throttle so the final-snapshot text
        // always reaches the keyboard.
        Self.publishProjection(text, force: true)
    }

    /// Full reset of UI state. Called by the recording flow once the batch
    /// transcript has overridden the streaming preview.
    func reset() {
        currentSessionID = nil
        streamingText = ""
        streamingIsVolatile = false
        // Terminal event — bypass throttle so the keyboard always sees the
        // clear-strip transition.
        Self.publishProjection("", force: true)
    }

    /// Tracks the wall-clock time of the last projection publish so the
    /// per-callback rate (FluidAudio fires at 5-10 Hz) gets coalesced down
    /// to ~5 Hz of cross-process IPC. Terminal events (`force: true`)
    /// bypass the throttle so volatile→final UI handoffs and session
    /// boundaries always land.
    ///
    /// Explicitly `@MainActor`: `static` members on a `@MainActor` type are
    /// nonisolated by default in Swift. All current call sites are MainActor
    /// instance methods, but the explicit annotation removes the footgun if
    /// a future refactor reaches for this from an actor-isolated context.
    @MainActor private static var lastPublishedAt: Date?

    /// Throttle window between non-terminal projection publishes. Picked
    /// to land at ~5 Hz — fast enough for a smooth scrolling strip, slow
    /// enough to halve the IPC volume vs. the per-callback FluidAudio rate.
    private static let publishThrottle: TimeInterval = 0.2

    /// Mirrors the partial text into the App Group so the keyboard extension
    /// can render a live caption strip while recording. Empty string clears
    /// the strip on session end / reset. The keyboard observes this via the
    /// `streamingPartialChanged` Darwin notification — exact same shape as
    /// `pipelinePhaseChanged`.
    ///
    /// Non-terminal callers (i.e. `update(...)` with `isFinal: false`) are
    /// throttled to one publish per `publishThrottle` window. The Darwin
    /// notification stays the keyboard's wakeup mechanism; this only
    /// coalesces the wakeup rate so the keyboard isn't woken 5-10 times
    /// per second.
    ///
    /// The same throttle gate also drives the Dynamic Island / lock-screen
    /// `Activity.update(_:)` push for the streaming partial — see
    /// `pushLiveActivityPreview(_:)` below. Sharing the gate means the
    /// keyboard caption strip and the DI center region update on a single
    /// ~5 Hz cadence rather than diverging.
    @MainActor
    private static func publishProjection(_ text: String, force: Bool = false) {
        let now = Date()
        if !force, let last = lastPublishedAt,
           now.timeIntervalSince(last) < publishThrottle {
            return
        }
        lastPublishedAt = now
        AppGroup.defaults.set(text, forKey: AppGroup.Keys.streamingPartialText)
        CrossProcessNotification.post(name: CrossProcessNotification.streamingPartialChanged)
        pushLiveActivityPreview(text)
    }

    /// Pushes the streaming partial text into the running Dynamic Island /
    /// lock-screen Live Activity as `ContentState.lastWordsPreview`. Driven
    /// from `publishProjection` so the throttle and the writer-side
    /// settings gate apply uniformly.
    ///
    /// Per the dynamic-island redesign §8 (partial-transcript display
    /// strategy v1):
    ///
    /// - **§8.2 Settings toggle / writer-side gate.** If
    ///   `AppGroup.liveActivityTranscriptEnabled` is `false`, return
    ///   without calling `Activity.update(_:)`. Structural privacy: the
    ///   text never reaches the widget process so a stale render can't
    ///   briefly leak it. The keyboard caption strip is intentionally on
    ///   a separate code path (App Group write above) and is unaffected.
    /// - **§8.5 Wire protocol.** Take cumulative `streamingText`, split by
    ///   whitespace, take the **last 12 words**, join with spaces, then
    ///   `String.suffix(60)` to right-edge cap at 60 chars. Render side
    ///   does no further truncation.
    /// - **§8.6 Source-of-truth contract.** Live Activity widget bodies do
    ///   NOT re-render on App Group writes, so the widget can't read the
    ///   existing `streamingPartialText` key. Push via `Activity.update`
    ///   with a fresh `ContentState` carrying the existing phase.
    /// - **§8.8 Empty-state contract.** When `text` is empty, push `nil`
    ///   (not `""`) so the widget's `.center` collapses to `EmptyView()`
    ///   rather than rendering an empty placeholder line.
    /// - **Phase guard.** Streaming partials are recording-state-only
    ///   (§8.1). If the activity's current phase is anything other than
    ///   `.recording(...)`, skip the update — the new ContentState would
    ///   otherwise clobber a `transcribing` / `followUp`
    ///   phase that the pipeline transitioned into between this throttle
    ///   tick and the late callback.
    @MainActor
    private static func pushLiveActivityPreview(_ text: String) {
        guard AppGroup.liveActivityTranscriptEnabled else { return }

        let preview = lastWordsPreview(of: text)

        // Move the iteration INSIDE the spawned Task so `Activity` (which
        // is not `Sendable` under Swift 6 strict concurrency) is never
        // captured across actor boundaries. We only capture `preview`
        // (a `Sendable` `String?`); the activity handles are created and
        // consumed within the Task's own actor context. `Activity.update`
        // is callable from any actor per Apple's docs.
        Task {
            for activity in Activity<DictationAttributes>.activities {
                let currentState = activity.content.state
                // Recording-state-only per §8.1. Don't clobber a
                // non-recording phase if a partial-transcript callback
                // lands during the brief window after
                // `RecordingService.stop()` has flipped the activity to
                // `.transcribing`.
                guard case .recording = currentState.phase else { continue }
                let nextState = DictationAttributes.ContentState(
                    phase: currentState.phase,
                    lastWordsPreview: preview
                )
                try? await activity.update(
                    ActivityContent(state: nextState, staleDate: nil)
                )
            }
        }
    }

    /// Computes the §8.5 wire-protocol value: last 12 words of cumulative
    /// streaming text, joined with single spaces, then `String.suffix(60)`
    /// to right-edge cap at 60 chars. Returns `nil` for empty / whitespace-
    /// only input so the writer pushes `nil` (not `""`) into ContentState
    /// per §8.8 empty-state contract.
    ///
    /// `split(omittingEmptySubsequences: true)` collapses runs of
    /// whitespace, so a final word followed by a trailing space (FluidAudio
    /// emits this shape sometimes between segments) doesn't get treated as
    /// an empty 13th word and shift the 12-word window.
    @MainActor
    private static func lastWordsPreview(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = trimmed.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        let tail = words.suffix(12).joined(separator: " ")
        guard !tail.isEmpty else { return nil }
        return String(tail.suffix(60))
    }
}

/// Off-MainActor consumer that owns the `StreamingEouAsrManager` reference.
///
/// One `StreamingTranscriptionEngine` exists per streaming session; the
/// service-level `StreamingTranscriptionService` (sibling file) maintains
/// the loaded model and hands off the manager into a fresh engine on each
/// `RecordingService.start()`. The engine actor:
///   1. Drains the audio-tap-fed `StreamingBufferQueue` in FIFO order.
///   2. Wraps each `[Float]` chunk into an `AVAudioPCMBuffer` and calls
///      `appendAudio` + `processBufferedAudio` on the FluidAudio actor.
///   3. Routes partial-transcript callbacks to the MainActor `StreamingPartial`
///      presenter, gated by the per-session token.
///
/// Critical: the audio-thread tap NEVER calls into this actor (Sendable
/// `[Float]` payload moves through the queue, not through `await`). The
/// drain task is `Task.detached(priority: .userInitiated)` — never `.high`,
/// which would compete with the audio render thread.
actor StreamingTranscriptionEngine {
    private let manager: any StreamingAsrManager
    private let queue: StreamingBufferQueue
    private let presenter: StreamingPartial
    private let sessionID: UUID

    /// Pre-built target format for buffer materialization. The manager
    /// resamples internally if needed; we hand it 16kHz mono Float32 because
    /// that's what the audio-thread CaptureContext converter already produced.
    private static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "streaming-engine"
    )

    init(
        manager: any StreamingAsrManager,
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID
    ) {
        self.manager = manager
        self.queue = queue
        self.presenter = presenter
        self.sessionID = sessionID
    }

    /// Installs the partial-transcript callback on the FluidAudio manager.
    /// The callback hops to MainActor and routes through the presenter's
    /// session-token-guarded `update(...)`. Captures `sessionID` by value so
    /// late callbacks from a previous engine instance carry their own token
    /// and fail the presenter's guard.
    func installPartialCallback() async {
        let presenter = self.presenter
        let sessionID = self.sessionID
        await manager.setPartialTranscriptCallback { partial in
            Task { @MainActor in
                presenter.update(text: partial, isFinal: false, sessionID: sessionID)
            }
        }
    }

    /// Drain loop. Returns when the queue signals end-of-stream. Single
    /// invocation per engine instance — call sites use the prototype's
    /// `Task.detached(priority: .userInitiated)` shape and `await` the
    /// task's value as part of `stop()` cleanup.
    ///
    /// Errors from `appendAudio` / `processBufferedAudio` are swallowed
    /// (logged at debug). The streaming preview is a UX nicety; failing it
    /// must NOT interrupt the user's dictation flow per spec §3.6.
    /// TODO(metric): emit `streaming.midSessionFailure` per spec §3.6 when
    /// drain step throws — surface failure rate without bothering the user.
    func drain() async {
        while true {
            switch await queue.popOrEndOfStream() {
            case .samples(let pcm):
                let buffer = Self.makeBuffer(from: pcm)
                guard let buffer else { continue }
                do {
                    // Both calls cross the FluidAudio actor boundary; both
                    // require `await`. `appendAudio` is `throws` (not
                    // `async`) on the protocol, but the cross-actor hop is
                    // itself the suspension point — Swift requires `await`
                    // even though the function body is synchronous on the
                    // remote actor.
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                } catch {
                    log.debug(
                        "drain step error — \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .endOfStream:
                return
            }
        }
    }

    /// Final flush after the drain task has returned. Promotes the
    /// streaming preview to `.primary` styling for the brief pre-batch
    /// tail by writing the finalized streaming text directly into the
    /// presenter via `applyFinalSnapshot(_:)` — bypassing the session-
    /// token guard, because the caller intentionally cleared the token via
    /// `presenter.clearSession()` BEFORE calling this method.
    ///
    /// Discards no information: the batch path will overwrite the preview
    /// when its result lands (spec §3.3), but the user gets the
    /// volatile→solid transition in the streaming preview as native polish.
    /// Per prototype `DualRecorder.swift:283-290`.
    func finish() async {
        do {
            let final = try await manager.finish()
            let presenter = self.presenter
            await MainActor.run { presenter.applyFinalSnapshot(final) }
            log.info("streaming finish — chars=\(final.count, privacy: .public)")
        } catch {
            log.error(
                "streaming finish failed — \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Full release of CoreML model references and per-session state per
    /// `StreamingEouAsrManager.swift:428-440`. After this returns, the
    /// manager (and this engine instance) cannot be used until
    /// `loadModels()` runs again on the manager — but the host service's
    /// lifecycle (team-lead Rule 3 cleanup-on-every-stop) is "fresh manager
    /// per session," so no caller will reuse this engine. The engine
    /// reference is dropped immediately after.
    ///
    /// Called from `StreamingTranscriptionService.endSession(engine:)` on
    /// every recording stop (spec §2.1 binding 950 MB peak budget on the
    /// 8GB iPhone 17 base).
    func cleanup() async {
        await manager.cleanup()
    }

    /// Wraps the audio-thread-produced `[Float]` chunk into an
    /// `AVAudioPCMBuffer` of the target 16kHz mono Float32 format. Allocates
    /// fresh — runs OFF the audio thread (on the engine actor) so allocation
    /// is fine. Returns `nil` if the format slot can't be obtained, which
    /// should be vanishingly rare.
    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}

/// FIFO sample queue connecting the audio-render-thread tap to the streaming
/// engine actor's drain task. Single-producer (the tap closure) /
/// single-consumer (the drain task) by construction; `RecordingService` is
/// responsible for never spawning a second drain task against the same queue.
///
/// The tap synchronously pushes already-converted 16kHz mono Float32 sample
/// arrays (NOT `AVAudioPCMBuffer` references — those are owned by
/// `AVAudioEngine` and may not survive past the tap-block return; copying
/// into `[Float]` matches the existing `CaptureContext.ingest` posture).
/// The drain task awaits `popOrEndOfStream`, which suspends until either a
/// sample chunk arrives or `endOfStream()` is signaled by `stop()`.
///
/// `[Float]` is `Sendable`; the queue's `Item` payload therefore needs no
/// `@unchecked` escape hatch even under Swift 6 strict concurrency. The
/// queue itself is `@unchecked Sendable` only for the lock-protected internal
/// state — same pattern as the prototype's `StreamingBufferQueue`.
final class StreamingBufferQueue: @unchecked Sendable {
    enum Item {
        case samples([Float])
        case endOfStream
    }

    private let lock = NSLock()
    private var queue: [[Float]] = []
    private var ended = false
    private var waiter: CheckedContinuation<Item, Never>?

    init() {}

    /// Pushes a sample chunk produced by the audio-tap. Called from the
    /// audio render thread; allocation-free besides growing the queue's
    /// backing array (amortized O(1)).
    func push(_ samples: [Float]) {
        lock.lock()
        // Drop post-EOS pushes. An in-flight tap callback can race with
        // `stop()`'s `endOfStream()`; without this guard the chunk would be
        // appended after the drain task has exited and never consumed.
        if ended {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .samples(samples))
            return
        }
        queue.append(samples)
        lock.unlock()
    }

    /// Signals end-of-stream. Idempotent; subsequent `push` calls drop the
    /// payload. The drain task observes this on its next `popOrEndOfStream`
    /// call (or immediately if already parked).
    func endOfStream() {
        lock.lock()
        ended = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .endOfStream)
            return
        }
        lock.unlock()
    }

    /// Resets the queue for a fresh session. Defense-in-depth resumes any
    /// stranded continuation with `.endOfStream` so we never leak a parked
    /// `CheckedContinuation`. In practice the drain task only spawns AFTER
    /// reset, so no waiter is expected.
    func reset() {
        lock.lock()
        queue.removeAll(keepingCapacity: true)
        ended = false
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .endOfStream)
            return
        }
        lock.unlock()
    }

    /// Drain task's read primitive. Suspends if the queue is empty until
    /// either a chunk arrives or `endOfStream()` is signaled.
    func popOrEndOfStream() async -> Item {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let head = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: .samples(head))
                return
            }
            if ended {
                lock.unlock()
                continuation.resume(returning: .endOfStream)
                return
            }
            self.waiter = continuation
            lock.unlock()
        }
    }
}
