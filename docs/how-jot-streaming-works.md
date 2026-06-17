# How Jot does live dictation streaming (batch pseudo-streaming)

*An internal explainer. Read this to understand the whole live-preview design in
~10 minutes. The authoritative design + decision history is
`docs/plans/batch-only-streaming.md`; this is the distilled "how it actually
works, and why" version, cross-referenced to the shipped code.*

---

## TL;DR — the key insight

Most on-device dictation apps run a **dedicated streaming ASR model** (one trained
to emit partial words low-latency, with an end-of-utterance / "EOU" head) for the
live caption, and then a **separate batch model** for the final saved transcript.
Two models, two code paths, and a visible "flip" when the high-quality batch result
overrides the rough streaming preview on stop.

Jot threw that out. **There is now exactly one speech model.** The live preview is
produced by *re-running the normal batch transcription model on a sliding window of
the most recent audio*, triggered at speech pauses (with a timer and a hard cap as
fallbacks). The result is shown as a *volatile* preview that gets promoted to final
when you stop. We call this **batch pseudo-streaming**.

This deleted the whole streaming subsystem — a separate 120M EOU model, its engine,
its warm-up — and made the live caption the *same quality* as the saved transcript
(same number normalization, paragraphs, etc.), because it literally comes from the
same model.

---

## The pipeline at a glance

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ AUDIO RENDER THREAD (RecordingService tap)                                │
  │   mic → 16 kHz mono Float32 chunks → StreamingBufferQueue.push(chunk)     │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                   │  Sendable [Float], no await on audio thread
                                   ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ PreviewScheduler  (actor, off-MainActor)                                  │
  │                                                                           │
  │   drain(): pop chunks ──► ingest()                                        │
  │              • append to trailing RING (cap + 5s margin)                  │
  │              • per-chunk RMS energy gate → silenceRun / lastSpeechTotal   │
  │              • decide a TRIGGER:  pause > cap > timer                      │
  │                  - pause (≥0.7s silence)  → COMMIT                        │
  │                  - window ≥ 15s           → COMMIT (runaway guard)        │
  │                  - 5s since last tick     → VOLATILE refresh             │
  │                (all gated: speech-in-window + ≥2s since last tick)        │
  │                                                                           │
  │   runTick(window=[windowStart..now]):                                     │
  │       text = TranscriptionService.previewTranscribe(window)  ◄── BATCH    │
  │       commit  → committedText += text ; slide windowStart                 │
  │       volatile→ volatileTail = text   (re-derived next tick)              │
  │       publish committedText (+ volatileTail) to presenter                 │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                   │  await MainActor.run
                                   ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ StreamingPartial  (@MainActor presenter)                                  │
  │   update(text, isFinal:false, sessionID)  — session-token guarded         │
  │   → drives the hero/home UI  AND  mirrors to the App Group                 │
  │   → keyboard extension renders the mirrored string (NEVER runs inference)  │
  └───────────────────────────────────────────────────────────────────────────┘

  ON STOP:
   tearDownStreamingSession(): EOS queue → await drain → quiesce()
        → presenter.applyFinalSnapshot(scheduler.assembledText())   (bridge)
   RecordingService.stop(): TranscriptionService.transcribe(allSamples)  (FULL pass)
        → presenter shows the full-file batch result == the saved transcript
```

The crucial property: **the saved transcript path is unchanged.** `stop()` still
calls `TranscriptionService.transcribe(samples:)` over the *whole* recording. The
streaming work only changes where the *preview* comes from; the note you keep is
byte-identical to before.

---

## 1. Why batch-only beats the old EOU streaming approach

The old design had a dedicated **Parakeet EOU streaming 120M** model
(`StreamingTranscriptionService` / `StreamingTranscriptionEngine`, still present in
`StreamingPartial.swift:243-404` behind the legacy flag). It fired ~5–10 Hz
word-level partial callbacks. Problems:

- **Two models to ship, warm, and maintain.** The EOU bundle is 214 MB on disk
  (plan table) and needs its own warm-up at launch.
- **Preview ≠ final.** The EOU partials had no vocabulary rescoring, no number
  normalization, no paragraphs — so the caption *visibly changed* when the batch
  result landed on stop. Jarring.
- **More code, more cross-process surface, larger IPA.**

The decision (plan, "FINAL DIRECTION", 2026-06-12) went further than just
batch-streaming: **600M-only, one model for everything**, drop both the EOU model
*and* the old TDT-110M primary. Devices below the 6 GB-RAM line (`physicalMemory ≥
4.6e9`, `DeviceCapability.is600MCapable`, `DeviceCapability.swift:23-25`) get a hard
wall on dictation surfaces rather than a degraded model — *"only support something
which is good."*

The honest part (plan, "Cost" section): **battery is NOT the justification.** The
two energy metrics disagree — by inference wall-time the capped batch design *beats*
EOU (12.8–19.4 s vs 32.9 s on a 10.7-min file, because EOU fires ~2000 tiny
inferences and per-call overhead dominates), but by raw model-work EOU is far
lighter (a small model run once vs re-chewing overlapping windows 19–29×). True
on-device energy sits between and must be measured. The real wins are: **one model,
preview == final (no flip), smaller app, far less code.**

---

## 2. The trailing-audio ring + pause-trigger + overlap window

The naive idea — "cut the audio at every silence and concatenate the per-segment
transcripts" — was **prototyped and rejected**. Measured on a 20-random-recording
test (`/tmp/jot-vadbatch`):

| Approach | divergence vs full-file pass |
|---|---|
| isolated pause-freeze (segment-and-concat) | **4.5% mean / 8% on multi-utterance** |
| carried decoder state across utterances | **10.9% (up to 50%)** — *worse* |
| **trailing overlap window** | **1.3%** |

Segment-and-concat brings back exactly the flip we're trying to kill, because an ASR
model decodes a short isolated clip much worse than the same words *with their left
context*. Threading one `TdtDecoderState` across utterances (the "obvious" fix) is
worse still — silence gaps desync the transducer state. The winner: **re-transcribe
a trailing window that overlaps into prior speech**, and only commit (stop
re-transcribing) audio that has scrolled safely behind the window.

How it works in `PreviewScheduler.swift`:

- **Ring buffer.** `ingest()` appends each chunk to `ring`, bounded to
  `ringCapacity = capSamples + 5s margin` (`:75`, `:167-173`). `ring[0]` maps to
  absolute sample index `ringStartTotal`, so window math is all absolute indices.
- **Energy-gate pause detection** (not a model — see limitations). Per chunk it
  computes RMS; below `silenceRMS = 0.005` accumulates `silenceRun`, otherwise
  resets it and stamps `lastSpeechTotal` (`:176-185`). A run ≥ `pauseSilenceSamples`
  (0.7 s, `:52`) is a pause.
- **Trigger priority: pause > cap > timer** (`:202-212`):
  - **Pause → COMMIT.** Re-transcribe `[windowStart..now]` and fold the text into
    the committed prefix; slide `windowStart` to `now`. The window is a completed
    utterance *with its left context*, so finalizing here is the safe, low-divergence
    point.
  - **Cap (window ≥ `capSamples` = 15 s, `:57`) → COMMIT.** The runaway guard, not
    the normal path. The cap sweep (plan) showed pauses normally cut the window at
    ~7.6 s, long before 15 s. 10 s and 15 s cost the same; 15 s is the knee — won't
    force-cut an 11–14 s sentence, snappier than 30 s (112 ms vs 168 ms worst
    refresh).
  - **Timer (5 s since last tick, `timerSamples`, `:54`) → VOLATILE refresh.**
    Re-transcribe the same window but *don't* commit — keeps text flowing for a
    no-pause talker. `pendingTrigger` makes commit outrank volatile if both fire.
- **Two universal gates on every trigger** (`:197-201`):
  - **speech-in-window** (`lastSpeechTotal > windowStartTotal`) — a pure-silence
    window must never run inference (else a long quiet stretch burns back-to-back
    full-window passes; review B2). This uses an index comparison, not a boolean, so
    speech arriving *during* a tick (belonging to the next window) isn't wiped by the
    commit (`:98-103`).
  - **min tick spacing** (`minTickSpacingSamples` = 2 s, `:70`) — the *structural*
    duty-cycle bound: no two ticks closer than 2 s regardless of trigger. This is
    load-bearing for the dropped-words fix (see §4).

Because we re-transcribe a real trailing window, the assembled preview converges to
a full-file batch result rather than a stitched-together one. The window size is a
**preview-smoothness-vs-battery knob only** — it never touches the saved transcript.

---

## 3. The volatile → committed text model (LocalAgreement-style)

`PreviewScheduler` keeps two text fields (`:90-94`):

- `committedText` — text locked at commits. The audio before `windowStartTotal` is
  **never re-transcribed again**.
- `volatileTail` — the last volatile-refresh result for the still-open window;
  re-derived from scratch on the next tick.

On a **commit** tick (`runTick`, `:263-286`): if the window decoded to non-empty
text, append it to `committedText`, slide `windowStartTotal = max(windowStartTotal,
windowEnd)`, clear the volatile tail. On a **volatile** tick: just set
`volatileTail = text`.

What's published to the UI (`:292-300`) is `committedText` on a commit, or
`join(committedText, volatileTail)` on a volatile refresh.

**Important subtlety:** "commit" here is a *text-assembly* concept (stop re-chewing
audio that's already locked in), **not** a visual one. The whole preview stays
visually volatile until the stop-pass promotes it — exactly like the EOU preview did
(`PreviewScheduler.swift:27-31`). This is the principled core of
LocalAgreement-style streaming ("freeze a word once it's safely behind the window");
the doc notes the full two-pass-agreement LocalAgreement v2 is deferred.

**The final promote** (`RecordingService.tearDownStreamingSession`,
`:438-468`). Ordering is exact and load-bearing:

1. `streamingQueue.endOfStream()` — signal the drain loop to exit.
2. `await previewDrainTask?.value` — drain has returned.
3. **`await scheduler.quiesce()`** — *this is the bug-fix fence*
   (`PreviewScheduler.swift:153-156`). An in-flight tick runs as its own `Task`;
   it can survive drain's return. `quiesce()` sets `stopped = true` (disabling any
   reschedule, so no zombie inference starts while the saving pass runs) and awaits
   `tickTask?.value`, so the last window's commit lands *before* we read the text.
   Without it, actor reentrancy lets the read race the commit and silently drop the
   last window's words across a pause.
4. `presenter.clearSession()` then `presenter.applyFinalSnapshot(assembledText())`.
   `assembledText() = join(committedText, volatileTail)` (`:160-162`). This bridges
   the preview to a stable string while the real final pass runs.

Then `RecordingService.stop()` runs the **full-file batch pass** over all samples
and that result (the saved transcript) replaces the preview. `StreamingPartial`'s
per-session UUID (`StreamingPartial.swift:43-47`, `96-100`) drops any late tick
callback from a stale session so it can't flip `streamingIsVolatile` back to `true`
after the promote.

### The lean preview inference path

The preview loop must **not** call the normal `TranscriptionService.transcribe(samples:)`
(`:303`) — that path has an `isTranscribing` busy-throw (would `.busy` when a preview
overlaps the stop pass), fires `CorrectionProvenance.clearPending()` + a diagnostics
write *every call* (would corrupt adaptive-vocab provenance and spam logs ~50×/
session), and rejects sub-1s windows by throwing. So there's a dedicated lean path,
`previewTranscribe(samples:)` (`TranscriptionService.swift:683-710`):

- Rides the already-warm `AsrManager`; returns `nil` (never downloads/loads) if the
  model isn't `.ready` (`:689`), or the window is < 1 s (`:690`).
- Runs a fresh per-call `TdtDecoderState` (`:692-695`) — deliberately *no* carried
  state (tested worse, §2).
- **Text-only quality pipeline:** `ParagraphSegmenter` (needs token timings),
  `FillerWordCleaner`, `NumberNormalizer` (`:700-704`). **No vocabulary rescore** —
  that's a *second* CoreML inference (a CTC spotter over the window audio) plus
  internal provenance/diagnostics writes; running it per tick would double cost and
  corrupt adaptive-vocab state. Consequence: vocab terms may visibly correct when the
  stop-pass lands (sparse, accepted, documented at `:673-678`).
- Returns `nil` instead of throwing — a failed/short tick is silently dropped.

> **Discrepancy with the design doc (code wins):** the plan's Phase-0 spec and
> pseudocode describe the preview pipeline as "paragraphs → number-normalization."
> The shipped `previewTranscribe` *also* runs `FillerWordCleaner.clean`
> (`TranscriptionService.swift:703`) between them. Minor — filler-cleaning is a cheap
> regex pass and keeps preview closer to final — but the doc undersells the pipeline.

---

## 4. The dropped-words bug, and how SchedulerSim caught + fixed it (DEL 3 → 0)

**Symptom (build 121, owner on-device):** slow counting with pauses dropped words
from the live preview — *"silence → word → silence doesn't show up."* The saved note
was nearly complete (full stop-pass unaffected); the loss was preview-only.

**SchedulerSim** (`/tmp/jot-vadbatch`) is an offline NeMo-style *simulated-streaming
validator*: it replays recorded audio through the **exact** `PreviewScheduler` logic
in 0.1 s chunks, then does word-level Substitution/Deletion/Insertion alignment of
the assembled preview against both the full-file pass and known ground truth. Corpus
included slow-counting-with-gaps, quiet variants, isolated words, a real 52 s
control, and silence-spliced real recordings.

| Variant | counting DEL (the bug) | verdict |
|---|---|---|
| current (build 121) | **3/40** | bug reproduced ("six","eight","one" dropped) |
| v1: trim window to speech−0.5 s | **14/40** | REJECTED — Parakeet decodes sub-2s clips terribly; trimming *starves* context |
| **v2: retry-not-discard + 2 s spacing + gate 0.005** | **0/40** | **WINNER** |
| v2 with RMS gate back at 0.008 | 0/40, but real DEL 13 | gate matters — soft speech mis-tagged silence, never ticked |

**Root cause (two parts):**
1. The old logic *advanced the window on an empty commit result*. An isolated quiet
   word sits in a mostly-silent window that decodes to nothing — and advancing past it
   discarded it forever.
2. The RMS gate at 0.008 mis-tagged soft speech as silence, so a quiet phrase never
   registered as speech-in-window and never ticked at all.

**Fix (shipped build 122, `PreviewScheduler.swift:269-285`):** on an empty commit,
**never advance past speech** — keep the window and retry with *more* audio (the next
utterance joins and rescues the decode). Runaway is bounded *structurally* by the 2 s
`minTickSpacingSamples`, not by discarding. A give-up valve (`emptyRetries >= 3` at
cap length, `:280-284`) skips persistent garbage — the stop-pass still transcribes
that audio for the saved note. The gate dropped to **0.005** (`:58-63`).

The lesson, in the code comments and the plan: **the model wants more context, not
less** — and an offline simulated-streaming harness caught the v1 "fix" as a 14/40
*regression* before it could ship.

---

## 5. The gentle settle-in reveal UX

The cadence changed character: EOU's ~320 ms word-ticker became sentence-sized
**chunk drops on pauses / every ~5 s**. Calmer, but the newest visible word can lag
the voice by several seconds, and chunks could *pop* in. `TranscribingText.swift`
covers the gap with two affordances, shared by the hero and the keyboard strip:

1. **Trailing ellipsis** (`:14-23`, `:105-124`). Three serif dots appended *inline*
   right after the newest word — exactly where the next word will land, wrapping with
   the line — stepping through a slow rest → · → ·· → ··· cycle (4 phases × 0.45 s =
   a calm 1.8 s loop, `:91`) driven off the wall clock via `TimelineView`, so it
   animates even when no data is arriving. Reads as "I'm still hearing you, text is
   catching up" — patient, an ellipsis not a spinner.
2. **Settle-in** (`:24-33`, `ingest()` `:199-246`). A landed chunk doesn't snap in at
   full ink. The newly-arrived suffix (a common-prefix diff against what was showing,
   snapped *back* to a word boundary so an opacity seam never splits a word) appears
   translucent and settles to full ink over ~1.8 s (`:96`) with a whisper of blur
   lifting. A volatile *rewrite* of the tail goes through the same path — the changed
   region re-arrives translucent, a soft dip rather than a jarring swap. **Opacity +
   blur only; position never animates** (auto-scroll owns movement).

The settle fade is drawn by a `TextRenderer` (`SettleRenderer`, `:265-298`) animating
a single `progress` value against a layout cached once per chunk — no
attributed-string churn per frame, which matters inside the 60 MB keyboard appex.
Reduce Motion → static steady ellipsis + instant full-ink reveal. The dots are
decorative chrome; VoiceOver reads the transcript only.

---

## 6. Where it's wired into the recording lifecycle

`RecordingService` owns the wiring (`RecordingService.swift`):

- **Start.** A `StreamingBufferQueue` is allocated per slice (`:555`, `:631`); the
  audio tap pushes converted 16 kHz mono `[Float]` into it.
  `kickOffStreamingSession()` (`:341-414`) branches on `AppGroup.previewSource`:
  - `"batch"` → mint a session UUID, build a `PreviewScheduler`, and start its
    `drain()` on a `Task.detached(priority: .userInitiated)` (`:381-391`).
  - else → the legacy EOU `StreamingTranscriptionEngine` path (`:394-413`), default
    until the flag flips.
- **Live-text gate** (`:375-380`). In batch mode, the scheduler only starts if
  `DeviceCapability.liveTextEnabled || ownsActiveRecording`. The
  `ownsActiveRecording` exemption is the owned-input path: **Ask and the voice-prompt
  rewrite use the live preview *as their input field*, not as a preview** — so they
  always stream regardless of the toggle/gate, otherwise their text box is dead.
  Otherwise the queue is `endOfStream()`'d so tap pushes drop and **zero inference
  runs during capture** (the safe baseline / degrade target).
- **Stop.** `tearDownStreamingSession()` (`:438-468`) runs the EOS → drain →
  `quiesce()` → `applyFinalSnapshot()` sequence from §3. Hard-stop / interruption
  paths (`:1416-1443`, `:2013-2037`) do the same quiesce-then-promote on a detached
  task so no zombie tick survives.

`DeviceCapability.liveTextEnabled` (`DeviceCapability.swift:34-40`) resolves a
tri-state setting: explicit `"on"`/`"off"` always wins; `"auto"` follows
`is600MCapable` so a future default change reaches auto users without clobbering a
manual choice.

---

## 7. Honest limitations & tunables

- **Pause detection is a plain energy/RMS gate, not a VAD model.** Deliberate (no
  third model, no App-Store-flagged first-run download). The 0.005 threshold is
  SchedulerSim-tuned but a *static* level — very quiet or very loud-ambient
  environments can mis-classify. A real Silero VAD remains a follow-up
  (`PreviewScheduler.swift:62`, plan Open Q #1).
- **Vocabulary corrections appear only on stop**, not in the live preview (no vocab
  rescore per tick — §3). Accepted, documented.
- **Tunables, all in `PreviewScheduler.swift:48-75`** (Phase-5 on-device knobs):
  `pauseSilenceSamples` 0.7 s, `timerSamples` 5 s, `capSamples` 15 s, `silenceRMS`
  0.005, `minTickSpacingSamples` 2 s, `minWindowSamples` 1 s, `ringCapacity` cap+5 s.
- **Window-head trimming is possible.** If a tick lets the window outgrow the ring
  margin (a >5 s tick), the window head falls off the trailing ring — logged, and a
  *preview-only* loss (the stop pass still has all the audio) (`:252-256`).
- **The saved transcript is always correct** regardless of any preview behavior — it
  is the unchanged full-file batch pass on stop. Every preview compromise above is
  bounded to the live caption.
- **Battery is unproven** — the per-update cost is flat thanks to the cap (worst
  refresh ~112–186 ms from 10 min to 70 min in the plan's sweeps), but whether the
  big-model burst beats the EOU trickle on real ANE energy still needs the Xcode
  Energy gauge (plan, Phase 5).
- **The EOU subsystem still exists in the tree** behind `previewSource` and is only
  deleted once the flag has shipped defaulting to `batch` and proven stable (plan
  Phase 6). A known build-122 regression — the model-loading indicator is wired to
  the EOU path and goes dark in batch mode — is tracked in the plan and must be fixed
  before that deletion.

---

*Files: `Jot/App/Transcription/PreviewScheduler.swift`,
`Jot/App/Transcription/TranscriptionService.swift` (`previewTranscribe`,
`transcribe`), `Jot/App/Transcription/StreamingPartial.swift`,
`Jot/App/Design/Components/TranscribingText.swift`,
`Jot/App/Recording/RecordingService.swift` (`kickOffStreamingSession` /
`tearDownStreamingSession`), `Jot/Shared/DeviceCapability.swift`. Design +
decision history: `docs/plans/batch-only-streaming.md`.*
