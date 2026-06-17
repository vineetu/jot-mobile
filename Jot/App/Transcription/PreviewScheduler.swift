import Foundation
import os.log

/// Batch-only streaming preview (`docs/plans/batch-only-streaming.md`).
///
/// Consumes the per-slice `StreamingBufferQueue` (16 kHz mono Float32 chunks
/// pushed by the audio-thread tap) and drives the live preview by
/// re-transcribing a trailing window with the batch model. This is the sole
/// live-preview engine.
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
    /// Energy gate: chunk RMS below this is "silence". 0.005 (was 0.008) —
    /// SchedulerSim showed 0.008 mis-tags quiet real speech as silence and
    /// a soft-spoken phrase then never gets ticked into the preview
    /// (control-case deletions 1→9 with the same logic at 0.008).
    /// Adaptive/Silero VAD remains a follow-up (plan Open Q #1).
    private static let silenceRMS: Float = 0.005
    /// Global minimum spacing between ticks: the STRUCTURAL inference
    /// duty-cycle bound (≤ one tick per 2 s regardless of which triggers
    /// fire). This replaces "advance the window on an empty result" as the
    /// runaway protection — SchedulerSim proved advance-on-empty EATS
    /// isolated words (the owner's slow-counting repro: 2–3 numbers dropped
    /// per run; fix = DEL 0 with the full pass as reference).
    private static let minTickSpacingSamples = Int(2.0 * Double(sampleRate))
    /// Don't bother transcribing windows shorter than this (the model
    /// needs ≥1 s; `previewTranscribe` also guards).
    private static let minWindowSamples = Int(1.0 * Double(sampleRate))
    /// First-tick-fast: when NO preview exists yet, fire the first volatile
    /// refresh as soon as the window reaches this (instead of waiting the full
    /// `timerSamples` 5 s). Kills the dead ~5 s wait before any text appears for
    /// a continuous (no-pause) talker; after the first preview lands the normal
    /// 5 s timer cadence resumes. Still ≥ `minTickSpacingSamples` (2 s) so it
    /// can never out-pace the duty-cycle bound.
    private static let firstTickSamples = Int(2.0 * Double(sampleRate))
    /// Trailing ring keeps cap + margin so the window is always available.
    private static let ringCapacity = capSamples + Int(5.0 * Double(sampleRate))
    /// Capture-first hold ceiling: while the (cold) model is loading the ring
    /// grows to retain the whole captured window; this bounds that growth so a
    /// never-ready model (load failure) can't grow it without limit. 60 s
    /// comfortably covers a worst-case cold 600M load on a 6GB device.
    private static let coldHoldCeiling = Int(60.0 * Double(sampleRate))

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
    /// Consecutive commit ticks whose window transcribed to nothing despite
    /// containing speech. Drives the give-up valve (see `runTick`).
    private var emptyRetries = 0
    /// [PREVIEW-DIAG] throttle for the periodic gating snapshot in `ingest`.
    private var lastDiagTotal = 0

    /// Capture-first latch. `false` until the batch model finishes its
    /// (possibly cold, 30-40s+) load; flipped once via a MainActor read of
    /// `TranscriptionService.isPreviewModelReady`. While `false` the scheduler
    /// HOLDS all captured audio (no trim past `windowStartTotal`) and fires NO
    /// ticks — every `previewTranscribe` would return `nil`, and worse, the
    /// cap give-up valve in `runTick` would advance `windowStartTotal` past the
    /// buffered speech, leaving the first cold session's preview permanently
    /// empty (the warm 2nd session works only because it opens already-ready).
    /// On the ready transition the held window drains into the preview on the
    /// next trigger. One-way latch: once `true`, never re-read (cheap hot path).
    private var modelReady = false

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
        // [PREVIEW-DIAG] Routed to the IN-APP Diagnostics log (the stream the
        // owner copies from Help → Diagnostics) — os.log was invisible there.
        DiagnosticsLog.record(
            source: "main-app", category: .streamingPartialReceived,
            message: "preview drain start",
            metadata: ["sid": String(self.sessionID.uuidString.prefix(8))]
        )
        while true {
            switch await queue.popOrEndOfStream() {
            case .samples(let chunk):
                await ingest(chunk)
            case .endOfStream:
                stopped = true
                DiagnosticsLog.record(
                    source: "main-app", category: .streamingPartialReceived,
                    message: "preview drain end",
                    metadata: [
                        "sid": String(self.sessionID.uuidString.prefix(8)),
                        "committedChars": "\(self.committedText.count)",
                    ]
                )
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

    private func ingest(_ chunk: [Float]) async {
        ring.append(contentsOf: chunk)
        totalSamples += chunk.count

        // Capture-first: while the (possibly cold) model is still loading,
        // KEEP the whole captured window — never trim past `windowStartTotal`
        // — so it can drain into the preview the moment the model is ready.
        // The normal trailing-ring trim (cap + 5s margin) resumes once ready.
        if !modelReady {
            modelReady = await MainActor.run { TranscriptionService.shared.isPreviewModelReady }
            if modelReady {
                DiagnosticsLog.record(
                    source: "main-app", category: .streamingPartialReceived,
                    message: "preview model ready — draining held window",
                    metadata: [
                        "sid": String(self.sessionID.uuidString.prefix(8)),
                        "heldSec": "\((totalSamples - windowStartTotal) / Self.sampleRate)s",
                    ]
                )
            }
        }
        let effectiveRingCap = modelReady
            ? Self.ringCapacity
            // Grow to hold windowStart..now (+1s slack) until ready, so the
            // first cold session never loses its early speech to ring eviction.
            // Bounded by `coldHoldCeiling` so a never-ready model (load failure)
            // can't grow the ring without limit — the head silently slides as a
            // normal trailing ring would, no worse than today's behaviour.
            : min(Self.coldHoldCeiling,
                  max(Self.ringCapacity, totalSamples - windowStartTotal + Self.sampleRate))
        if ring.count > effectiveRingCap {
            let drop = ring.count - effectiveRingCap
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
        // Capture-first gate: fire NO ticks until the model is ready. A tick now
        // could only return `nil` (model not loaded), and the cap give-up valve
        // in `runTick` would then advance `windowStartTotal` past the buffered
        // speech — exactly the cold-first-session preview-dead regression. The
        // energy gate above still runs, so `lastSpeechTotal`/`silenceRun` stay
        // correct and the first post-ready trigger sees the right window.
        guard modelReady else { return }
        let windowLen = totalSamples - windowStartTotal
        let speechInWindow = lastSpeechTotal > windowStartTotal

        // [PREVIEW-DIAG] Gating snapshot (in-app log, throttled to 5 s to spare
        // the 100-entry ring) so we can see WHY ticks stop firing on a warm
        // model — `speechInWindow` stuck false (energy gate mis-tagging speech /
        // windowStartTotal runaway), `inFlight` wedged true, or the window never
        // reaching a trigger. In normal operation ticks reset `tickGap`; a
        // growing tickGap with speechInWindow=false is the silent-box signature.
        if totalSamples - lastDiagTotal >= 5 * Self.sampleRate {
            lastDiagTotal = totalSamples
            // DIAGNOSTIC NOISE SILENCED (2026-06-16): the 5s gating snapshot is
            // [main-app] noise that competes with the stream-render records we're
            // using to chase the keyboard blank-pane bug. Re-enable if the
            // silent-box (ticks-stop-firing) signature needs tracing again.
        }

        // Structural duty-cycle bound: no two ticks closer than 2 s,
        // regardless of trigger. Pairs with retry-not-discard in `runTick`
        // (SchedulerSim-validated winner — see plan's Phase-5 findings).
        guard totalSamples - lastTickTotal >= Self.minTickSpacingSamples else { return }
        // The COMMIT triggers (pause > cap) stay gated on `speechInWindow`: their
        // job is to fold audio into the committed prefix, and a pure-silence
        // window must never commit / burn back-to-back full-window passes
        // (review B2). The VOLATILE 5 s timer is intentionally NOT gated (final
        // `else if`): the energy gate mis-tags CONTINUOUS QUIET speech as silence
        // (every chunk RMS < 0.005), which left the preview box EMPTY for the
        // whole recording even though the full-file pass decoded it fine — the
        // EOU engine "always worked" precisely because it had no gate. SchedulerSim
        // (real-quiet ×0.04): current = 0 ticks / empty / 100% DEL; un-gated 5 s
        // timer = 7 ticks / 52 words restored, normal-corpus DEL unchanged, and
        // pure silence bounded to 1 tick / 5 s. First-tick-fast stays gated so a
        // cold pure-silence open can't tick every 2 s. (Adaptive noise-floor VAD
        // is the real long-term fix — plan Open Q #1.)
        if speechInWindow,
           silenceRun >= Self.pauseSilenceSamples,
           !pauseFiredThisRun,
           windowLen >= Self.minWindowSamples {
            pauseFiredThisRun = true
            schedule(.commit)
        } else if speechInWindow, windowLen >= Self.capSamples {
            schedule(.commit)
        } else if committedText.isEmpty, volatileTail.isEmpty,
                  speechInWindow,
                  windowLen >= Self.firstTickSamples {
            // First-tick-fast (~2 s): gated on speech so a quiet/silent cold open
            // doesn't tick every 2 s. Loud cold-start still gets the fast first
            // paint; quiet audio waits for the un-gated 5 s timer below.
            schedule(.volatileRefresh)
        } else if totalSamples - lastTickTotal >= Self.timerSamples,
                  windowLen >= Self.minWindowSamples {
            // UN-GATED volatile refresh — fires regardless of the energy gate so
            // quiet continuous speech still flows into the box. Bounded to 1 tick
            // / 5 s, so pure silence costs at most one no-op decode per 5 s.
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
        // DIAGNOSTIC NOISE SILENCED (2026-06-16): per-tick [main-app] record —
        // the downstream "preview PUBLISH" log already marks every partial that
        // reaches the projection, which is the event we correlate keyboard
        // renders against. Re-enable for preview-pipeline (tick cadence) tracing.

        switch trigger {
        case .commit:
            if let text, !text.isEmpty {
                committedText = Self.join(committedText, text)
                windowStartTotal = max(windowStartTotal, windowEnd)
                emptyRetries = 0
            } else {
                // NEVER advance past speech on an empty result. The original
                // "always advance" (review B2) ate isolated quiet words —
                // SchedulerSim repro: slow counting with pauses dropped 2–3
                // numbers per run; keeping the window and retrying with MORE
                // audio (the next utterance joins and rescues the decode)
                // brought deletions to 0. Runaway is bounded structurally by
                // `minTickSpacingSamples`, not by discarding. Give-up valve:
                // persistent garbage at cap length is skipped (the stop-pass
                // still transcribes that audio for the saved note).
                emptyRetries += 1
                if emptyRetries >= 3, windowEnd - windowStartTotal >= Self.capSamples {
                    log.notice("preview window gave up after \(self.emptyRetries) empty ticks — skipping \(windowEnd - self.windowStartTotal) samples")
                    windowStartTotal = max(windowStartTotal, windowEnd)
                    emptyRetries = 0
                }
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
