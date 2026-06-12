import Foundation
import os.log

/// Batch-only streaming preview (`docs/plans/batch-only-streaming.md`).
///
/// Consumes the per-slice `StreamingBufferQueue` — the SAME 16 kHz mono
/// Float32 chunks the EOU engine drains today (tap untouched) — and drives
/// the live preview by re-transcribing a trailing window with the batch
/// model. Selected by `AppGroup.previewSource == "batch"`; the EOU engine
/// remains the default until the flag flips.
///
/// ## Cadence (plan: pause is the trigger; timer + cap are fallbacks)
///
/// - **Pause** (energy gate, ~0.7 s below threshold): COMMIT — transcribe
///   the window `[lastCommit … now]` and fold it into the committed prefix.
///   Finalizing at a pause is safe: the window is a completed utterance
///   *with* its left context (overlap design — never an isolated slice;
///   adversarial review B1: isolated-utterance freezing measured ~8 %
///   divergence vs the final pass, overlap ~1.3 %).
/// - **Timer** (5 s without any trigger): VOLATILE refresh — same window,
///   but the text is not committed, so the next tick re-derives it. This is
///   what keeps text flowing for a no-pause talker.
/// - **Cap** (window ≥ 15 s): COMMIT + slide, the runaway guard. The cap
///   sweep showed pauses normally cut the window long before 15 s
///   (~7.6 s apart on real recordings), so this rarely fires.
///
/// "Commit" here is a TEXT-ASSEMBLY concept (stop re-transcribing audio
/// that's already locked), not a visual one — the whole preview stays
/// visually volatile until the stop-pass promotes it, exactly like the EOU
/// preview today. The saved transcript is always the full-file batch pass
/// on stop; nothing here touches it.
///
/// ## Concurrency shape
///
/// One `PreviewScheduler` per recording slice (mirrors
/// `StreamingTranscriptionEngine`'s lifecycle). The drain loop ingests
/// chunks; ticks run as actor-isolated awaits — ingestion interleaves at
/// the suspension point (actor reentrancy), which is safe because ticks
/// are single-flight (`inFlight` + `pendingTrigger` = latest-wins
/// coalescing) and commits use indices captured before the await.
actor PreviewScheduler {

    enum Trigger {
        case volatileRefresh   // timer: re-derive volatile tail
        case commit            // pause or cap: fold window into prefix
    }

    // MARK: Tunables (plan §cadence; revisit in Phase 5 on-device)

    private static let sampleRate = 16_000
    /// Silence run that counts as a pause (plan: 0.6–1.0 s band).
    private static let pauseSilenceSamples = Int(0.7 * Double(sampleRate))
    /// Volatile-refresh fallback when no pause fires.
    private static let timerSamples = Int(5.0 * Double(sampleRate))
    /// Runaway window guard (measured knee — same cost as 10 s, doesn't
    /// clip 11–14 s sentences; see plan's cap sweep).
    private static let capSamples = Int(15.0 * Double(sampleRate))
    /// Energy gate: chunk RMS below this is "silence". Conservative
    /// absolute floor. The gate only *schedules* re-transcribes — a missed
    /// pause falls back to the timer; a false pause costs one extra tick —
    /// so precision is not safety-critical. Adaptive/Silero VAD is a
    /// follow-up (plan Open Q #1).
    private static let silenceRMS: Float = 0.008
    /// Don't bother transcribing windows shorter than this (the model
    /// needs ≥1 s; `previewTranscribe` also guards).
    private static let minWindowSamples = Int(1.0 * Double(sampleRate))
    /// Trailing ring keeps cap + margin so the window is always available.
    private static let ringCapacity = capSamples + Int(5.0 * Double(sampleRate))

    // MARK: State

    private let queue: StreamingBufferQueue
    private let presenter: StreamingPartial
    private let sessionID: UUID

    /// Trailing audio. `ring[0]` is absolute sample index `ringStartTotal`.
    private var ring: [Float] = []
    private var ringStartTotal = 0
    private var totalSamples = 0

    /// Text locked at commits — audio before `windowStartTotal` is never
    /// re-transcribed again.
    private var committedText = ""
    /// Last published volatile tail (so the final promote shows the full
    /// assembled text even if it lands between ticks).
    private var volatileTail = ""
    private var windowStartTotal = 0

    private var silenceRun = 0
    private var pauseFiredThisRun = false
    /// Absolute sample index of the most recent above-threshold chunk.
    /// "Has speech arrived in the current window" = `lastSpeechTotal >
    /// windowStartTotal` — an index comparison rather than a boolean so
    /// speech that lands DURING a tick (belonging to the next window)
    /// isn't wiped by the commit (review minor #1).
    private var lastSpeechTotal = -1
    private var lastTickTotal = 0

    private var inFlight = false
    private var pendingTrigger: Trigger?
    /// Set when the recording stopped (end-of-stream). Gates trigger
    /// scheduling and the deferred reschedule so no zombie inference can
    /// start after stop (review M1).
    private var stopped = false
    /// In-flight tick task — awaited by `quiesce()` so teardown reads
    /// `assembledText()` only after the last tick has committed.
    private var tickTask: Task<Void, Never>?

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "preview-scheduler"
    )

    init(queue: StreamingBufferQueue, presenter: StreamingPartial, sessionID: UUID) {
        self.queue = queue
        self.presenter = presenter
        self.sessionID = sessionID
    }

    // MARK: Drain loop

    /// Runs until the queue signals end-of-stream (recording stop). The
    /// caller (`RecordingService.tearDownStreamingSession`) then clears the
    /// presenter's session token and promotes `assembledText()` — same
    /// ordering contract as the EOU engine's `finish()`.
    func drain() async {
        while true {
            switch await queue.popOrEndOfStream() {
            case .samples(let chunk):
                ingest(chunk)
            case .endOfStream:
                stopped = true
                return
            }
        }
    }

    /// Quiesce after drain returns: blocks until the in-flight tick (if
    /// any) finishes, with rescheduling disabled via `stopped`. Teardown
    /// MUST call this before `assembledText()` — otherwise actor
    /// reentrancy lets the read run before the last tick commits its
    /// window's text, silently dropping words across a pause (review M1).
    func quiesce() async {
        stopped = true
        await tickTask?.value
    }

    /// Committed prefix + last volatile tail — what the stop path promotes
    /// via `applyFinalSnapshot` before the batch result replaces it.
    func assembledText() -> String {
        Self.join(committedText, volatileTail)
    }

    // MARK: Ingestion + triggers

    private func ingest(_ chunk: [Float]) {
        ring.append(contentsOf: chunk)
        totalSamples += chunk.count
        if ring.count > Self.ringCapacity {
            let drop = ring.count - Self.ringCapacity
            ring.removeFirst(drop)
            ringStartTotal += drop
        }

        // Energy gate.
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        if rms < Self.silenceRMS {
            silenceRun += chunk.count
        } else {
            silenceRun = 0
            pauseFiredThisRun = false
            lastSpeechTotal = totalSamples
        }

        guard !stopped else { return }
        let windowLen = totalSamples - windowStartTotal
        let speechInWindow = lastSpeechTotal > windowStartTotal

        // Trigger priority: pause > cap > timer. One pause fire per
        // silence run (flag resets when speech resumes). EVERY trigger is
        // gated on speech-in-window: a pure-silence window must never run
        // inference (review B2 — without this, a >15 s silent stretch hits
        // the cap on every chunk and burns back-to-back full-window batch
        // passes for as long as the user stays quiet).
        guard speechInWindow else { return }
        if silenceRun >= Self.pauseSilenceSamples,
           !pauseFiredThisRun,
           windowLen >= Self.minWindowSamples {
            pauseFiredThisRun = true
            schedule(.commit)
        } else if windowLen >= Self.capSamples {
            schedule(.commit)
        } else if totalSamples - lastTickTotal >= Self.timerSamples,
                  windowLen >= Self.minWindowSamples {
            schedule(.volatileRefresh)
        }
    }

    /// Latest-wins coalescing: never more than one tick in flight; a
    /// trigger arriving mid-tick is remembered (commit outranks volatile)
    /// and fired once the current tick returns.
    private func schedule(_ trigger: Trigger) {
        guard !stopped else { return }
        lastTickTotal = totalSamples
        if inFlight {
            if case .commit = trigger { pendingTrigger = .commit }
            else if pendingTrigger == nil { pendingTrigger = .volatileRefresh }
            return
        }
        inFlight = true
        let windowStart = windowStartTotal
        let windowEnd = totalSamples
        tickTask = Task { await self.runTick(trigger, windowStart: windowStart, windowEnd: windowEnd) }
    }

    private func runTick(_ trigger: Trigger, windowStart: Int, windowEnd: Int) async {
        defer {
            inFlight = false
            // No reschedule after stop (review M1 — a pending trigger must
            // not start a zombie inference while the saving stop-pass runs).
            if !stopped, let next = pendingTrigger {
                pendingTrigger = nil
                schedule(next)
            }
        }

        // Snapshot the window out of the ring (indices are absolute).
        let lo = max(windowStart - ringStartTotal, 0)
        let hi = min(windowEnd - ringStartTotal, ring.count)
        guard hi > lo else {
            // Degenerate window (fully trimmed); advance on commit so the
            // cap can't re-fire on the same dead range.
            if case .commit = trigger { windowStartTotal = max(windowStartTotal, windowEnd) }
            return
        }
        if windowStart - ringStartTotal < 0 {
            // Window head fell off the trailing ring (a >5 s tick let the
            // window outgrow the margin). Preview-only loss; log it.
            log.notice("preview window head trimmed — windowStart=\(windowStart) ringStart=\(self.ringStartTotal)")
        }
        let window = Array(ring[lo..<hi])

        // MainActor hop for the lean inference path; heavy work runs on the
        // FluidAudio actor, MainActor only orchestrates.
        let text = await TranscriptionService.shared.previewTranscribe(samples: window)

        switch trigger {
        case .commit:
            // ALWAYS advance the window on a commit — even when the text
            // came back empty/nil (silence, model not ready). Without this
            // a 15 s window that transcribes to nothing keeps satisfying
            // the cap trigger forever = back-to-back full-window inference
            // on silence (review B2). Committing "nothing" loses nothing:
            // the saved transcript is the full-file stop-pass.
            windowStartTotal = max(windowStartTotal, windowEnd)
            if let text, !text.isEmpty {
                committedText = Self.join(committedText, text)
            }
            volatileTail = ""
        case .volatileRefresh:
            guard let text, !text.isEmpty else { return }
            volatileTail = text
        }

        let display = trigger == .commit
            ? committedText
            : Self.join(committedText, volatileTail)
        guard !display.isEmpty else { return }
        let presenter = self.presenter
        let sessionID = self.sessionID
        await MainActor.run {
            presenter.update(text: display, isFinal: false, sessionID: sessionID)
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let lhs = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return lhs + " " + rhs
    }
}
