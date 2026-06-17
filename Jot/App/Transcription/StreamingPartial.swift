@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.log

/// Live partial-transcript presenter for the batch pseudo-streaming preview.
///
/// Bound by `ContentView` to render volatile-then-final dictation text per
/// Apple's HIG (`.secondary` while volatile, `.primary` once batch overrides).
/// The presenter is the UI half of the streaming pipeline; the inference
/// half lives off MainActor in `PreviewScheduler` (sibling file) which drains
/// the audio-thread-fed `StreamingBufferQueue` and re-transcribes on the batch
/// model. The audio-thread fan-out lives in `RecordingService.installTap`.
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

    /// Committed text from BEFORE the current streaming session, carried
    /// across a Pause/Resume boundary (UX-overhaul round 2 §10.5). When a
    /// recording is paused, `RecordingService` finalizes the live preview and
    /// re-seeds this prefix on resume; subsequent partials from the fresh
    /// streaming session render as `resumePrefix + newPartial` so the user
    /// sees one continuous transcript rather than a restart-from-empty.
    /// Empty for an un-paused recording (the common case), so it's a no-op on
    /// the hot path. Cleared by `beginSession()` / `reset()`.
    private(set) var resumePrefix: String = ""

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
        // A brand-new dictation has no carried-over pause prefix. (Resume
        // re-seeds it via `seedResumePrefix(_:)` AFTER calling beginSession
        // on the fresh streaming engine.)
        resumePrefix = ""
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
            // [PREVIEW-DIAG] In-app log so we can see whether preview ticks are
            // SILENTLY DROPPED on a session-token mismatch — prime suspect for
            // "streams then stops" on a warm model. Remove once diagnosed.
            DiagnosticsLog.record(
                source: "main-app", category: .streamingPartialReceived,
                message: "preview DROP stale token",
                metadata: [
                    "incoming": String(sessionID.uuidString.prefix(8)),
                    "current": currentSessionID.map { String($0.uuidString.prefix(8)) } ?? "nil",
                    "chars": "\(text.count)",
                ]
            )
            return
        }
        // Prepend any committed pause prefix (§10.5) so a resumed dictation
        // reads as one continuous transcript. No-op (empty prefix) on the
        // common un-paused path.
        let joined = Self.join(prefix: resumePrefix, tail: text)
        streamingText = joined
        streamingIsVolatile = !isFinal
        // [PREVIEW-DIAG] In-app log — confirms the partial reached the presenter
        // and was published cross-process to the keyboard. Remove once diagnosed.
        DiagnosticsLog.record(
            source: "main-app", category: .streamingPartialReceived,
            message: "preview PUBLISH",
            metadata: [
                "sid": String(sessionID.uuidString.prefix(8)),
                "chars": "\(joined.count)",
                "final": "\(isFinal)",
            ]
        )
        // Force-publish on `isFinal` so the keyboard's volatile→primary
        // visual handoff isn't dropped by the throttle.
        Self.publishProjection(joined, force: isFinal)
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
        let joined = Self.join(prefix: resumePrefix, tail: text)
        streamingText = joined
        streamingIsVolatile = false
        // Terminal event — bypass the throttle so the final-snapshot text
        // always reaches the keyboard.
        Self.publishProjection(joined, force: true)
    }

    /// Seed the committed pause prefix on resume (UX-overhaul round 2 §10.5).
    /// Called by `RecordingService.resumeRecording()` AFTER the fresh
    /// streaming session's `beginSession()` (which clears `resumePrefix`), so
    /// subsequent partials render `prefix + newPartial`. Immediately shows the
    /// prefix so the strip isn't momentarily blank between resume and the first
    /// new partial.
    func seedResumePrefix(_ prefix: String) {
        resumePrefix = prefix
        streamingText = prefix
        streamingIsVolatile = true
        Self.publishProjection(prefix, force: true)
    }

    /// Join a committed prefix with a live tail, inserting a single separating
    /// space only when neither side already supplies whitespace and both are
    /// non-empty.
    private static func join(prefix: String, tail: String) -> String {
        guard !prefix.isEmpty else { return tail }
        guard !tail.isEmpty else { return prefix }
        let needsSpace = !(prefix.last?.isWhitespace ?? false)
            && !(tail.first?.isWhitespace ?? false)
        return needsSpace ? prefix + " " + tail : prefix + tail
    }

    /// Full reset of UI state. Called by the recording flow once the batch
    /// transcript has overridden the streaming preview.
    func reset() {
        currentSessionID = nil
        streamingText = ""
        streamingIsVolatile = false
        resumePrefix = ""
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
    @MainActor
    private static func publishProjection(_ text: String, force: Bool = false) {
        let now = Date()
        if !force, let last = lastPublishedAt,
           now.timeIntervalSince(last) < publishThrottle {
            return
        }
        lastPublishedAt = now
        // Cap the published text to the last ~8 KB so a long dictation
        // doesn't grow the App Group write (and the keyboard's in-process
        // cached copy) without bound. The keyboard's streaming strip
        // only shows the tail anyway — older content has scrolled off
        // the visible window. Defensive against §14.2 memory-pressure
        // termination (whichever process gets jetsammed); see
        // docs/plans/bug-keyboard-auto-switch.md.
        let capped = Self.cappedForCrossProcess(text)
        AppGroup.defaults.set(capped, forKey: AppGroup.Keys.streamingPartialText)
        CrossProcessNotification.post(name: CrossProcessNotification.streamingPartialChanged)
    }

    /// Trailing-window cap. ~8 KB == one Mach page, comfortable for the
    /// keyboard's 60 MB ceiling at any reasonable dictation length.
    /// Uses `.utf8.count` so emoji-heavy text doesn't blow the byte budget.
    private static func cappedForCrossProcess(_ text: String) -> String {
        let maxBytes = 8 * 1024
        if text.utf8.count <= maxBytes { return text }
        // Drop from the FRONT, keep the tail (newest content the user sees).
        var trimmed = text
        while trimmed.utf8.count > maxBytes, !trimmed.isEmpty {
            trimmed.removeFirst()
        }
        return trimmed
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
