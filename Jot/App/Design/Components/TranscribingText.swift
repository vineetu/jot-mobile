//
//  TranscribingText.swift
//  Jot
//
//  Batch-preview "still transcribing" tail + paced word-by-word reveal for
//  newly arrived chunks — shared by the recording hero and the keyboard
//  streaming strip.
//

import SwiftUI

/// DIAGNOSTIC (blank live-preview pane): which process this shared view is
/// running in — the keyboard extension (an `.appex` bundle) or the main app.
/// `TranscribingText` ships in BOTH targets, so the `stream-render` probes were
/// previously indistinguishable between the keyboard strip and the hero. Tagging
/// every record with `proc` removes that ambiguity. Computed once.
let streamRenderProc: String =
    Bundle.main.bundleURL.pathExtension == "appex" ? "kbd" : "app"

/// Live-transcript text with a "still transcribing — more is coming" tail and
/// a paced, word-by-word settle-in for newly arrived text.
///
/// The batch preview loop (`PreviewScheduler`) delivers the live transcript in
/// sentence-sized chunks at speech pauses / every ~5s, so a whole clause can
/// land at once and the newest word can LAG the voice by several seconds.
/// Dumping the whole chunk in one go reads as bursty — text sits still, then a
/// paragraph slams in. Two affordances smooth that:
///
/// 1. **Rubber-band word reveal.** New words are NOT shown all at once: they
///    appear ONE WORD AT A TIME, each fading in (translucent → ink). The pace is
///    recomputed per word from the LIVE backlog (`StreamingWordReveal`): far
///    behind → SPRINT to catch up; caught up → a gentle ~speaking-pace trickle a
///    beat behind the voice. So the caption tracks how fast you actually speak
///    and never hoards a growing backlog (the old fixed per-chunk spread fell
///    progressively behind a fast talker). A chunk landing mid-reveal just grows
///    the backlog, which shortens the interval — the flow speeds up, never waits.
/// 2. **Trailing ellipsis.** Three serif dots appended INLINE after the newest
///    revealed word — exactly where the next word will land — stepping through
///    a slow fill cycle (rest → · → ·· → ···, 0.45s/step) so the trailing edge
///    reads "I'm still hearing you, text is catching up". Deliberately slower
///    than a cursor blink: patient, not anxious; an ellipsis, not a spinner.
///
/// The per-word fade is drawn by `SettleRenderer` (`TextRenderer`): only the
/// single currently-arriving word carries `ArrivingTextAttribute`, and it
/// lifts from translucent to ink over the current per-word interval, so it has
/// just about settled when the next word appears (no opacity hop). Position
/// never animates — auto-scroll owns movement.
///
/// The dots inherit the transcript's font (same face, same baseline, they wrap
/// with the line) but render in `dotColor` — call sites pass the surface's
/// chrome color so the tail reads as UI, never as punctuation the user
/// dictated.
///
/// Implementation note: the per-word fade redraws the cached `Text.Layout` via
/// `SettleRenderer` animating `progress`; no attributed-string churn for the
/// fade itself. The reveal pacing and the ellipsis stepping DO rebuild the run
/// (one short run, transcript + three dots) — bounded and cheap, but not
/// zero-rebuild — which is fine inside the 60 MB keyboard appex.
///
/// Used by BOTH live-preview surfaces: the recording hero
/// (`StreamingDictationText`) and the keyboard strip (`StreamingPane`). The
/// keyboard target compiles this file explicitly (see the per-file design
/// sources in `project.yml`), so keep it free of main-app dependencies —
/// pure SwiftUI + Observation, colors injected.
///
/// - `isTranscribing == false` (paused / stopped mic) drops the tail entirely
///   AND reveals any not-yet-shown words instantly — nothing is being captured,
///   so nothing should stay hidden behind a pace timer, and nothing should
///   promise more text.
/// - Reduce Motion renders a static steady ellipsis and an INSTANT reveal (all
///   text at full ink, no pacing, no fade) — the codebase precedent is fully
///   static fallbacks (`SwipeBackCardCue`'s end-frame), so no residual motion.
/// - The tail is decorative chrome — VoiceOver reads the transcript only.
struct TranscribingText: View {
    let text: String
    /// Applied to the WHOLE run (transcript + dots) so the tail shares the
    /// transcript's face and baseline.
    let font: Font
    let textColor: Color
    /// Base color of the tail dots; per-dot opacity does the stepping.
    let dotColor: Color
    /// `true` while the mic is actively capturing and the preview is volatile.
    /// `false` (e.g. paused) hides the tail and snaps the reveal to complete.
    let isTranscribing: Bool
    let reduceMotion: Bool
    /// Letter tracking for the run (the hero uses -0.4; default 0).
    var tracking: CGFloat = 0

    /// Owns the paced-reveal state machine (target text, revealed-word count,
    /// the advance timer, and the per-word fade progress). A reference type so
    /// the advance `Task` has a stable object to drive across body re-renders.
    @State private var reveal = StreamingWordReveal()

    // DIAGNOSTIC (blank live-preview pane): last-logged safety-net signature so
    // the high-signal probe fires once per (instance, textLen) transition, not
    // once per TimelineView tick. `@MainActor`-confined (body runs on the main
    // actor), matching the gating pattern the task asks for on the draw probe.
    @MainActor private static var lastSafetyNetSig = ""

    var body: some View {
        Group {
            if !isTranscribing {
                run(dotOpacities: nil)
            } else if reduceMotion {
                run(dotOpacities: SteppingEllipsis.staticOpacities)
            } else {
                TimelineView(.periodic(from: .now, by: SteppingEllipsis.stepInterval)) { context in
                    run(dotOpacities: SteppingEllipsis.opacities(at: context.date))
                }
            }
        }
        // The per-word fade. Applied OUTSIDE the TimelineView so the renderer's
        // in-flight animation isn't owned by any single tick's subtree; with
        // `progress == 1` it draws everything at full ink (no-op cost).
        .textRenderer(SettleRenderer(progress: reveal.settleProgress,
                                     instanceID: reveal.instanceID))
        // The dots are decorative chrome — assistive tech reads the words.
        .accessibilityLabel(Text(text))
        // `initial: true` so the FIRST chunk (and a re-presented surface with
        // text already on screen) gets the same paced arrival.
        .onChange(of: text, initial: true) { _, newText in
            reveal.sync(text: newText, isTranscribing: isTranscribing, reduceMotion: reduceMotion)
        }
        // Pause/stop must snap any pending words into view; resume re-enables
        // pacing for whatever arrives next. Reduce-Motion flips mid-session
        // (Settings) must also take effect immediately.
        .onChange(of: isTranscribing) { _, _ in
            reveal.sync(text: text, isTranscribing: isTranscribing, reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, _ in
            reveal.sync(text: text, isTranscribing: isTranscribing, reduceMotion: reduceMotion)
        }
        // DIAGNOSTIC (blank live-preview pane): record which instance actually
        // MOUNTS on screen vs the throwaway instances that get constructed but
        // never appear. THE decisive hypothesis-C probe — cross-reference the
        // mounted `instanceID` against `streamRevealSync` (which instance got the
        // text) to see whether the visible view is the one that was fed data.
        .onAppear {
            DiagnosticsLog.record(
                source: "stream-render",
                category: .streamViewLifecycle,
                message: "streamView appear",
                metadata: ["instanceID": String(reveal.instanceID), "proc": streamRenderProc]
            )
        }
        .onDisappear {
            reveal.stop()
            DiagnosticsLog.record(
                source: "stream-render",
                category: .streamViewLifecycle,
                message: "streamView disappear",
                metadata: ["instanceID": String(reveal.instanceID), "proc": streamRenderProc]
            )
        }
    }

    /// Single concatenated `Text` run: settled prefix + the one arriving word +
    /// (optionally) three dots. Concatenation keeps everything IN the line-wrap
    /// flow, so the arriving word and the tail always land right after the last
    /// settled word — an `HStack`-appended caret instead pins to the edge of the
    /// whole text block once lines wrap. The arriving word carries
    /// `ArrivingTextAttribute` so `SettleRenderer` can find it.
    private func run(dotOpacities: [Double]?) -> Text {
        // SAFETY NET: the paced reveal is PURELY cosmetic — the words must
        // always be visible. If the reveal controller has non-empty target text
        // but has produced an empty settled+arriving split (e.g. the async
        // advance loop hasn't run its first iteration yet, or got stranded by a
        // rapid sync/observation race), fall back to drawing the full `text`.
        // Without this, a stalled reveal renders BLANK while the container shows
        // non-empty text — the "Listening… disappears but nothing appears" bug.
        // On the happy path the split covers the whole text, so this is a no-op.
        if reveal.settledText.isEmpty, reveal.arrivingWord.isEmpty, !text.isEmpty {
            // DIAGNOSTIC (blank live-preview pane): the reveal produced an empty
            // settled+arriving split for non-empty text — high-signal evidence
            // of a stranded/stalled reveal (hypothesis A). The fallback below
            // still draws the full text, so this is log-only. `run` is re-
            // evaluated on every TimelineView tick, so gate on a per-(instance,
            // textLen) signature to log the safety-net once per transition
            // rather than once per ~0.45s tick (would flood the ring buffer).
            let safetyNetSig = "\(reveal.instanceID):\(text.count)"
            if Self.lastSafetyNetSig != safetyNetSig {
                Self.lastSafetyNetSig = safetyNetSig
                DiagnosticsLog.record(
                    source: "stream-render",
                    category: .streamRenderSafetyNet,
                    message: "streamRender safetyNet-hit",
                    metadata: [
                        "instanceID": String(reveal.instanceID),
                        "proc": streamRenderProc,
                        "textLen": String(text.count),
                    ]
                )
            }
            var run = Text(text).foregroundStyle(textColor)
            if let dotOpacities {
                run = run + Text(" ")
                for opacity in dotOpacities {
                    run = run + Text(".").foregroundStyle(dotColor.opacity(opacity))
                }
            }
            return run.font(font).tracking(tracking)
        }
        var run = Text(reveal.settledText).foregroundStyle(textColor)
        if !reveal.arrivingWord.isEmpty {
            run = run + Text(reveal.arrivingWord)
                .foregroundStyle(textColor)
                .customAttribute(ArrivingTextAttribute())
        }
        if let dotOpacities {
            run = run + Text(" ")
            for opacity in dotOpacities {
                run = run + Text(".").foregroundStyle(dotColor.opacity(opacity))
            }
        }
        return run
            .font(font)
            .tracking(tracking)
    }
}

// MARK: - Stepping ellipsis (shared dot animation)

/// The calm stepping ellipsis used by BOTH the live-transcript tail
/// (`TranscribingText`, concatenated INLINE into its text run) AND the empty
/// "waiting" placeholders (recording hero + keyboard strip), so the three dots
/// breathe identically the moment a surface appears — alive from second one,
/// quiet (no waveform).
///
/// This view is the standalone form: a leading word/label followed by the
/// three stepping dots, all in one `Text` run so the dots wrap with the label
/// and share its baseline. `TranscribingText` doesn't use this view (it owns a
/// richer run with the per-word `SettleRenderer`) but reads the SAME cadence
/// and opacity stepping from the shared statics here — one source of truth for
/// the dot animation.
///
/// Pure SwiftUI, colors injected — no main-app dependencies, since the keyboard
/// appex compiles this file (see the per-file design sources in `project.yml`).
/// Reduce Motion renders a static steady ellipsis (no `TimelineView`).
struct SteppingEllipsis: View {
    /// Leading text the dots trail (e.g. "Listening"). A single space is
    /// inserted between it and the first dot.
    let leading: String
    let font: Font
    let textColor: Color
    /// Base color of the tail dots; per-dot opacity does the stepping.
    let dotColor: Color
    let reduceMotion: Bool
    var tracking: CGFloat = 0

    /// One fill step. 4 phases × 0.45s = a calm 1.8s loop.
    static let stepInterval: TimeInterval = 0.45

    /// Dot opacities: lit vs resting. The resting dots stay faintly visible so
    /// the tail never pops in/out of layout — only brightness moves.
    static let litOpacity: Double = 0.9
    static let restingOpacity: Double = 0.28
    /// Reduce-Motion static ellipsis: a single steady mid tone.
    static let staticOpacity: Double = 0.55
    static let staticOpacities: [Double] = [staticOpacity, staticOpacity, staticOpacity]

    /// Per-dot opacities for the stepping cycle at a given wall-clock instant.
    /// 4 phases: 0 lit (rest beat) → 1 → 2 → 3 lit, then around. Derived from
    /// the clock so it animates without any data arriving.
    static func opacities(at date: Date) -> [Double] {
        let phase = Int(date.timeIntervalSinceReferenceDate / stepInterval) % 4
        return (0..<3).map { index in index < phase ? litOpacity : restingOpacity }
    }

    var body: some View {
        Group {
            if reduceMotion {
                run(dotOpacities: Self.staticOpacities)
            } else {
                TimelineView(.periodic(from: .now, by: Self.stepInterval)) { context in
                    run(dotOpacities: Self.opacities(at: context.date))
                }
            }
        }
        .accessibilityLabel(Text(leading))
    }

    private func run(dotOpacities: [Double]) -> Text {
        var run = Text(leading).foregroundStyle(textColor) + Text(" ")
        for opacity in dotOpacities {
            run = run + Text(".").foregroundStyle(dotColor.opacity(opacity))
        }
        return run.font(font).tracking(tracking)
    }
}

// MARK: - Paced word-reveal controller

/// Drives the word-by-word reveal: holds the full `target` text we're revealing
/// toward, how many of its words are currently shown (`revealedCount`), the
/// settled/arriving split the view draws, and the timer `Task` that advances
/// one word at a time. A `@MainActor @Observable` class (not view `@State`
/// fields) because the advance loop is an async `Task` that must mutate this
/// state across many SwiftUI body re-renders — a stable reference object is the
/// clean home for that. Pure Observation + SwiftUI, no main-app deps (the
/// keyboard appex compiles this file).
@MainActor
@Observable
final class StreamingWordReveal {
    /// Words that have finished arriving — drawn at full ink.
    private(set) var settledText: String = ""
    /// The single word currently fading in — drawn translucent → ink by
    /// `SettleRenderer` via `settleProgress`.
    private(set) var arrivingWord: String = ""
    /// 0 (just appeared, translucent) → 1 (settled). The renderer's animatable
    /// input; animated per word over the current `interval`.
    var settleProgress: Double = 1

    // Internal reveal state.
    private var target: String = ""
    /// Index just past the end of each word in `target` (at the following
    /// whitespace, or `endIndex`). Showing `n` words = `target[..<wordEnds[n-1]]`.
    private var wordEnds: [String.Index] = []
    private var revealedCount: Int = 0
    private var task: Task<Void, Never>?

    /// `true` until the first `sync()` after this controller is constructed.
    /// The controller is the view's per-instance `@State`, so iOS tearing down
    /// and recreating the keyboard extension (keyboard switch / app switch) mid-
    /// dictation yields a FRESH instance. The first text that fresh instance
    /// sees at (re)mount is treated as ALREADY-revealed — shown instantly — so
    /// only words arriving AFTER mount animate. Without this, the recreated
    /// controller would re-reveal the entire transcript backlog word-by-word
    /// from word 1 ("restarts from the beginning / keeps scrolling"). A fresh
    /// dictation mounts with EMPTY text, so its first real tick still animates.
    private var isFirstSync = true

    // DIAGNOSTIC (blank live-preview pane): a short incrementing id per
    // constructed instance, so ghost / multiple controllers during one
    // dictation are countable in the device log. `nonisolated(unsafe)` matches
    // the codebase precedent for build-time-only statics; the increment runs
    // once per `init` and a benign race only skips/duplicates an id — it never
    // affects behavior. Avoids Date/UUID per the task constraint.
    nonisolated(unsafe) private static var instanceCounter = 0
    /// This instance's short id, logged on init and on every probe so the
    /// owner can correlate sync/advance/safety-net records to one controller.
    /// `fileprivate` so the `TranscribingText` view's safety-net probe (same
    /// file, different type) can tag its record with the same id.
    fileprivate let instanceID: Int

    /// `nonisolated` so the view's `@State private var reveal = …` default
    /// initializer doesn't require a MainActor hop at construction (all stored
    /// properties have defaults; no isolated work happens here).
    nonisolated init() {
        Self.instanceCounter += 1
        instanceID = Self.instanceCounter
        DiagnosticsLog.record(
            source: "stream-render",
            category: .streamRevealInit,
            message: "streamReveal init",
            metadata: ["instanceID": String(instanceID), "proc": streamRenderProc]
        )
    }

    /// Rubber-band reveal pacing. The per-word interval is recomputed LIVE from
    /// the current backlog (`pending` = words not yet shown) on every word — NOT
    /// a fixed per-chunk spread — so the reveal tracks how fast words actually
    /// arrive and never hoards a growing backlog:
    ///   interval = clamp(catchUpWindow / pending, minInterval, maxInterval)
    /// - Big backlog (fast talker, or a big chunk just landed) → tiny interval →
    ///   SPRINT to catch up (drains ~`catchUpWindow` worth of words at the floor).
    /// - Caught up (1–2 words trailing) → `maxInterval`: a gentle, ~speaking-pace
    ///   trickle a beat behind the voice.
    /// `sync` still snaps fully current on pause/stop. Owner ask: match speaking
    /// speed (a touch slower), never the old slow "catching up forever" drip.
    private static let catchUpWindow: TimeInterval = 1.0
    /// Sprint floor — fastest per-word reveal when far behind (~25 words/s).
    private static let minInterval: TimeInterval = 0.04
    /// Gentle ceiling — trailing-edge pace once caught up (~7.7 words/s, just
    /// under typical fast speech so it reads as "keeping pace," not a dump).
    private static let maxInterval: TimeInterval = 0.13

    /// Live per-word interval from the current backlog (the rubber-band).
    private func currentInterval() -> TimeInterval {
        let pending = max(wordEnds.count - revealedCount, 1)
        return min(max(Self.catchUpWindow / Double(pending),
                       Self.minInterval), Self.maxInterval)
    }

    /// Reconcile with a fresh `text` / lifecycle flag. Called from the view's
    /// `onChange` handlers (text, isTranscribing, reduceMotion).
    func sync(text: String, isTranscribing: Bool, reduceMotion: Bool) {
        // DIAGNOSTIC: snapshot the pre-call first-sync flag so the probe can
        // report which branch a given call took.
        let firstSyncBefore = isFirstSync

        // Instant-reveal paths: Reduce Motion (no animation at all) or capture
        // ended (paused/stopped — never leave words hidden behind the timer).
        guard isTranscribing, !reduceMotion else {
            task?.cancel()
            task = nil
            target = text
            wordEnds = Self.computeWordEnds(text)
            revealedCount = wordEnds.count
            settledText = text
            arrivingWord = ""
            snapProgress(1)
            logSync(path: "guard-instant", textLen: text.count,
                    firstSyncBefore: firstSyncBefore)
            return
        }

        // First sync after (re)mount while actively transcribing: treat whatever
        // text already exists as already-revealed — show it instantly and
        // animate only words that arrive AFTER. iOS recreating the keyboard
        // extension mid-dictation makes a fresh controller; without this it
        // would re-reveal the whole backlog word-by-word from word 1 (the
        // "restarts / keeps scrolling" bug). A fresh dictation mounts with empty
        // text, so this no-ops there and the first real tick animates normally.
        if isFirstSync {
            isFirstSync = false
            if !text.isEmpty {
                task?.cancel()
                task = nil
                target = text
                wordEnds = Self.computeWordEnds(text)
                revealedCount = wordEnds.count
                settledText = text
                arrivingWord = ""
                snapProgress(1)
                logSync(path: "firstSync-instant", textLen: text.count,
                        firstSyncBefore: firstSyncBefore)
                return
            }
        }

        guard text != target else {
            logSync(path: text.isEmpty ? "early-return-empty" : "early-return-same",
                    textLen: text.count, firstSyncBefore: firstSyncBefore)
            return
        }

        // Preserve already-revealed words across an append OR a volatile tail
        // rewrite: keep only the words fully inside the common character prefix;
        // a reworded tail backs `revealedCount` up so it re-reveals.
        let safeWords = Self.commonWordCount(old: target, new: text)
        target = text
        wordEnds = Self.computeWordEnds(text)
        revealedCount = min(revealedCount, safeWords, wordEnds.count)
        // Paint the FIRST word synchronously when starting from nothing, so the
        // very first chunk never shows a blank frame while the async advance
        // loop is still being scheduled (the main actor is busy during active
        // recording — the loop's first iteration can be delayed). The loop then
        // paces the remaining words. Without this the reveal could sit blank on
        // the first cold partial until the loop finally ran.
        if revealedCount == 0, !wordEnds.isEmpty {
            revealedCount = 1
        }
        rebuildSplit()
        // No per-chunk interval here anymore — the loop recomputes it per word
        // from the live backlog (`currentInterval`), so a chunk that grows the
        // backlog mid-reveal automatically speeds the reveal up (rubber-band).
        startLoopIfNeeded()
        logSync(path: "append", textLen: text.count,
                firstSyncBefore: firstSyncBefore)
    }

    /// DIAGNOSTIC (blank live-preview pane): one record at the end of each
    /// `sync(...)` recording the path taken + the resulting split/progress.
    /// Bounded per dictation; no per-frame noise. Reports state AFTER the call
    /// mutated it (except `firstSyncBefore`, snapshotted at entry).
    private func logSync(path: String, textLen: Int, firstSyncBefore: Bool) {
        DiagnosticsLog.record(
            source: "stream-render",
            category: .streamRevealSync,
            message: "streamReveal sync \(path)",
            metadata: [
                "instanceID": String(instanceID),
                "proc": streamRenderProc,
                "path": path,
                "textLen": String(textLen),
                "firstSyncBefore": String(firstSyncBefore),
                "revealedCount": String(revealedCount),
                "settledLen": String(settledText.count),
                "arrivingLen": String(arrivingWord.count),
                "settleProgress": String(format: "%.2f", settleProgress),
            ]
        )
    }

    /// Stop the advance timer (view disappeared). Idempotent.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Rebuild the settled/arriving split for the current `revealedCount`
    /// WITHOUT a fade — used after a target swap (the shown words didn't newly
    /// arrive, they were already on screen).
    private func rebuildSplit() {
        guard revealedCount > 0 else {
            settledText = ""
            arrivingWord = ""
            return
        }
        let settledEnd = revealedCount >= 2 ? wordEnds[revealedCount - 2] : target.startIndex
        settledText = String(target[..<settledEnd])
        arrivingWord = String(target[settledEnd..<wordEnds[revealedCount - 1]])
        snapProgress(1)
    }

    /// Reveal one more word: promote the current arriving word into the settled
    /// prefix, make the next word the arriving one, and restart its fade.
    private func advance(fade: TimeInterval) {
        guard revealedCount < wordEnds.count else { return }
        revealedCount += 1
        let settledEnd = revealedCount >= 2 ? wordEnds[revealedCount - 2] : target.startIndex
        settledText = String(target[..<settledEnd])
        arrivingWord = String(target[settledEnd..<wordEnds[revealedCount - 1]])
        // Snap to 0 without animation, then ease to 1 over `fade` (the gap until
        // the next word) so the word has just about settled when the next lands.
        snapProgress(0)
        withAnimation(.easeOut(duration: fade)) { settleProgress = 1 }
        // DIAGNOSTIC (blank live-preview pane): one record per advanced word —
        // bounded by word count. Confirms the split is actually progressing.
        DiagnosticsLog.record(
            source: "stream-render",
            category: .streamRevealAdvance,
            message: "streamReveal advance",
            metadata: [
                "instanceID": String(instanceID),
                "proc": streamRenderProc,
                "revealedCount": String(revealedCount),
                "fade": String(format: "%.3f", fade),
                "settledLen": String(settledText.count),
                "arrivingLen": String(arrivingWord.count),
            ]
        )
    }

    /// Start the advance loop if one isn't already running and there are words
    /// left to reveal. A single long-lived loop reads `revealedCount` /
    /// `wordEnds` / `interval` fresh each iteration, so a chunk that arrives
    /// mid-reveal just extends the target — no second loop, no restart.
    private func startLoopIfNeeded() {
        guard task == nil, revealedCount < wordEnds.count else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.revealedCount < self.wordEnds.count {
                // Recompute from the LIVE backlog each word: the more behind, the
                // shorter the gap (sprint); near-caught-up → gentle ceiling.
                let dt = self.currentInterval()
                self.advance(fade: dt)
                try? await Task.sleep(for: .seconds(dt))
            }
            self.task = nil
        }
    }

    private func snapProgress(_ value: Double) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { settleProgress = value }
    }

    /// Index just past the end of each whitespace-delimited word. `ends[k]` is
    /// the position right after word `k+1` (at its trailing whitespace, or
    /// `endIndex`). O(n) single character walk.
    private static func computeWordEnds(_ s: String) -> [String.Index] {
        var ends: [String.Index] = []
        var prevNonWS = false
        var i = s.startIndex
        while i < s.endIndex {
            let isWS = s[i].isWhitespace
            if isWS, prevNonWS { ends.append(i) }
            prevNonWS = !isWS
            s.formIndex(after: &i)
        }
        if prevNonWS { ends.append(s.endIndex) }
        return ends
    }

    /// Number of whole words shared as a leading prefix by `old` and `new` —
    /// a word counts only if its end boundary falls inside the common character
    /// prefix, so a word straddling the divergence point is re-revealed.
    private static func commonWordCount(old: String, new: String) -> Int {
        var a = old.startIndex
        var b = new.startIndex
        while a < old.endIndex, b < new.endIndex, old[a] == new[b] {
            old.formIndex(after: &a)
            new.formIndex(after: &b)
        }
        var count = 0
        for end in computeWordEnds(new) {
            if end <= b { count += 1 } else { break }
        }
        return count
    }
}

// MARK: - Settle renderer

/// Marks the single newly-arrived (still settling) word of the live-transcript
/// run so `SettleRenderer` can pick it out of the text layout.
private struct ArrivingTextAttribute: TextAttribute {}

/// Draws the live-transcript run, lifting the `ArrivingTextAttribute` region
/// from translucent (~35% ink, faintly blurred) to full ink as `progress`
/// goes 0 → 1. Everything else — settled text and the ellipsis dots — draws
/// untouched, so the dots keep their own stepping and each new word visibly
/// "dries" into the page in front of them.
///
/// Why a `TextRenderer` and not per-frame run rebuilding: the layout is
/// computed once per text change and SwiftUI animates `progress` through
/// `Animatable`, calling `draw` against the CACHED layout — no attributed-
/// string churn per frame, which matters inside the keyboard appex.
private struct SettleRenderer: TextRenderer, Animatable {
    /// 0 = just arrived (translucent), 1 = fully settled (plain draw).
    var progress: Double

    /// DIAGNOSTIC (blank live-preview pane): the owning reveal's instance id, so
    /// the draw probe can name WHICH instance owns the visible pixels.
    var instanceID: Int = -1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Opacity of a word the instant it arrives — readable immediately, but
    /// clearly lighter than settled ink.
    private static let arrivalOpacity: Double = 0.35
    /// The "whisper of blur" at arrival; fully lifted by settle's end. Kept
    /// tiny so the 14pt keyboard text never reads smeared.
    private static let arrivalBlurRadius: CGFloat = 0.8

    // DIAGNOSTIC (blank live-preview pane): `draw` runs every frame, so we must
    // NOT log unconditionally. We gate on a per-(instance, lineCount, runCount)
    // signature so the per-frame / per-progress-tick path stays silent and we
    // log only when an instance's drawn geometry CHANGES. `nonisolated(unsafe)`
    // because `draw` is nonisolated — the worst a race does is log a transition
    // twice; no behavior depends on it.
    nonisolated(unsafe) private static var lastDrawSig = ""

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var lineCount = 0
        var runCount = 0
        for line in layout {
            lineCount += 1
            for run in line {
                runCount += 1
                if progress < 1, run[ArrivingTextAttribute.self] != nil {
                    var settling = context
                    settling.opacity = Self.arrivalOpacity
                        + (1 - Self.arrivalOpacity) * progress
                    settling.addFilter(
                        .blur(radius: Self.arrivalBlurRadius * (1 - progress))
                    )
                    settling.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
        // Record WHICH instance owns the visible pixels and how much it drew —
        // the decisive probe. If the instance SwiftUI keeps on screen draws 0
        // runs (empty layout, hypothesis B) while a sibling holds the text, or a
        // mounted instance never draws at all, this names it. Gated per
        // (instance, lines, runs) so the happy path stays quiet.
        let sig = "\(instanceID):\(lineCount):\(runCount)"
        if Self.lastDrawSig != sig {
            Self.lastDrawSig = sig
            DiagnosticsLog.record(
                source: "stream-render",
                category: lineCount == 0 ? .streamRenderEmptyLayout : .streamRenderDraw,
                message: lineCount == 0 ? "streamRender draw-emptyLayout" : "streamRender draw",
                metadata: [
                    "instanceID": String(instanceID),
                    "proc": streamRenderProc,
                    "lines": String(lineCount),
                    "runs": String(runCount),
                    "progress": String(format: "%.2f", progress),
                ]
            )
        }
    }
}
