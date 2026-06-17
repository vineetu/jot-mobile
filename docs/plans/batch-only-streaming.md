# Plan — Rip streaming EOU, batch-only pseudo-streaming

**Size: L.** Status: design / pre-implementation. Owner-driven (12 Jun 2026).
Feasibility prototype + cost measurements in `/tmp/jot-vadbatch`; report at
https://jot-batch-streaming.ideaflow.page. Background research memory:
`memory/project_batch_only_streaming.md`.

## Goal

Delete the separate **streaming EOU 120M** model and the entire live-streaming
inference subsystem. Drive the live preview from the **batch model we already
ship**, by re-transcribing the recent audio on a cadence ("5s intelligent chunks")
and doing **one final full pass on stop**. Net effect:

- **One** speech model instead of two.
- Live preview text becomes **the same quality as the saved transcript**
  (vocabulary rescoring, number normalization, paragraphs) — today's EOU preview
  has none of that, and visibly *changes* when batch overrides it on stop.
- **Less** battery than today (measured below), provided we cap the window.

This is NOT the naive "cut at every silence and concatenate segments" idea — that
was prototyped and rejected (≈9% divergence, word-loss on short clips, seam errors).
See the report. The design below re-transcribes a **trailing window**, so the final
preview *is* a full-file batch result.

## Decision (owner, 2026-06-12) — REVISED after adversarial review + random-sample test

**Pause-driven finalization, with an OVERLAP window (not a hard freeze).** The
adversarial review (below) caught that "finalize the isolated utterance at each
pause and freeze it" is just segment-and-concat — and a 20-random-recording test
confirmed it diverges ~8 % from the final pass on multi-utterance dictations (the
visible "flip" we claim to kill). Revised design:

1. **Pause = the TRIGGER** (when to commit) — a VAD silence is where finalization is
   safe. This part of the owner's call stands; it's clean and self-sizes to speech.
2. **OVERLAP window = HOW to commit** (the fix). Do NOT transcribe the isolated
   utterance. Re-transcribe a **trailing ~15 s window that overlaps into prior
   speech**, and only freeze words that have scrolled safely behind the window.
   Measured divergence: isolated-freeze 4.5 % (8 % on multi-utterance) → **overlap
   1.3 %**.
3. **Do NOT carry decoder state across utterances.** The "obvious" fix (thread one
   `TdtDecoderState` across utterances) was tested and is **worse** (10.9 % mean, up
   to 50 %) — silence-gapped utterances desync the transducer state.
4. **LocalAgreement = v2.** Freeze a word once two consecutive passes agree —
   the principled version of "freeze safely behind the window." Deferred.
5. **15 s cap + 5 s timer = no-pause fallbacks**, and only hard-freeze on a
   *confident* pause (cap-triggered cuts stay volatile so the stop pass corrects
   them without a flip).

## FINAL DIRECTION (owner, 2026-06-12 evening) — 600M-ONLY, hard wall

Supersedes the tier table / auto-select / dual-manager sections below (kept for
history). Owner: *"only support something which is good"* — drop **both** EOU and
the TDT-110M primary; ship **one model, Parakeet 600M v2, for everything** (preview
+ final). Devices below the 600M line get a **hard wall**, not a compat mode.

- **Two lines, deliberately different (owner, final):**
  - **OFFICIAL SUPPORT = iPhone 14 Pro and later.** The only promise Jot makes —
    App Store description, Help, and marketing all say "Requires iPhone 14 Pro or
    later." This is the validated hardware class (A16+); Phase 5 testing commits to
    it and nothing older.
  - **FUNCTIONAL GATE = 6 GB RAM (`physicalMemory ≥ 4.6e9`, i.e. 12 Pro and up)** —
    backward compatibility only. The 12 Pro → 14 Plus band continues to work
    (600M runs on 6 GB) but is **best-effort and unsupported**: issues there get
    "unsupported device," not fixes. No existing user is bricked; no new promise is
    made below 14 Pro.
- **Enforcement is RUNTIME-ONLY.** No App Store Connect setting exists for per-model
  availability; `UIRequiredDeviceCapabilities` cannot be tightened in an update, and
  the only model-tier key (`iphone-performance-gaming-tier`) starts at iPhone 15 Pro.
  So: runtime gate + "Requires iPhone 12 Pro or later" in the App Store description.
- **Gate dictation, not the app.** On <6 GB: recording surfaces (FAB, keyboard
  dictate, wizard W5, Ask mic) show "Dictation requires iPhone 14 Pro or later"
  (the official line — even though the functional gate is 6 GB, the copy promises
  only what we support); the library/transcripts/help remain fully usable —
  existing users' notes stay viewable + exportable (App Review defensibility + no
  data hostage).
- **What this kills:** the tier table, `DeviceCapability` 4-tier resolver,
  wizard auto-select, the Settings model picker entirely, dual-manager (review #2
  F1 — gone), `speechModelVariant` tri-state migration, 110M-vs-600M preview drift.
  The resolver collapses to one boolean: `is600MCapable`.
- **What survives:** the streaming on/off axis ("Live text while dictating" toggle;
  ≥8 GB default on; 6 GB default = Phase 5 thermal/jetsam gate since the preview
  loop now bursts 600M; off-mode = batch-on-stop is the degrade state), the Ask
  exemption + fast cadence, the lean preview path (no vocab rescore per tick — F2),
  the overlap-window design, never-swap-models-mid-session (F5), the universal
  Listening strip state (F6), launch-time backfill of `is600MCapable` +
  `streamingEnabled` into the App Group (F3/F8).
- **Bundle:** 600M (443) + CTC aux for vocab (99, independent of primary — stays) =
  **542 MB ≈ today's 530 MB.** Removing EOU (214) + TDT-110M (217) pays for 600M.
  Sequencing per F7: bundle 600M **in the same release** that deletes EOU + 110M —
  one ≈flat-size step; the interim both-bundled state never ships.
- **Existing small-device users** (App Store can't stop offering them the app): they
  keep working on their installed version; updating gives them library-only + the
  wall. Accepted by owner.

## Design

### The cadence: pause is the trigger; timer + cap are fallbacks

While recording (warm-hold already captures continuously), accumulate 16 kHz mono
samples. **A VAD silence (~0.6–1.0 s) is the trigger**: it finalizes everything up to
the pause and starts a fresh volatile window. Two fallbacks handle the no-pause case:

- **5 s timer** — if no pause has fired in 5 s, refresh the volatile window anyway so
  a continuous talker still sees text land ("if there's no pause, nothing shows up").
  The timer resets on every update; a pause always pre-empts it.
- **15 s cap** — the hard ceiling on the volatile window (see below). Bounds the
  worst case when someone speaks 15 s straight.

### The cap: re-transcribe only the trailing window (~15 s), pause is the real boundary

The cap is a **runaway ceiling, not the normal window** — the real finalize trigger
is the **pause**. Each preview re-transcribe runs the batch model on
**`samples[max(lastFinalize, now-CAP) … now]`**, where `lastFinalize` is the most
recent committed pause. Text older than that is **finalized and frozen** (a completed
sentence the model already locked in) and rendered solid; the trailing window is
**volatile** and re-rendered each update. This is Apple SpeechAnalyzer's
volatile→finalized contract.

**Cap = 15 s (measured), not 30.** Sweeping the cap on the 10.7-min file (pauses
every ~7.6 s, so the window usually only reaches ~8 s):

| Cap | compute (pause-driven) | worst refresh |
|---|---|---|
| 10 s | 8.1 s | 111 ms |
| **15 s** | **8.0 s** | **112 ms** |
| 20 s | 11.0 s | 143 ms |
| 30 s | 12.7 s | 168 ms |

10 s and 15 s **cost the same** — pauses cut the window before either cap binds; cost
only climbs at 20 s+. 15 s is the knee: same cost as 10 s but won't force-cut an
11–14 s sentence, and snappier than 30 (112 vs 168 ms). 30 s paid +60 % compute for
context the final pass redoes anyway. The adaptive version (v2) finalizes at pauses
and freezes a word once it agrees across two consecutive passes (LocalAgreement),
using the 15 s cap only as the no-pause guard. **Note: window size affects ONLY the
live preview — the saved transcript is the full-file pass on stop — so this is a
preview-smoothness-vs-battery knob, safe to keep small.**

Pseudocode (lives in the main app, off the audio thread):

```
onAudioTap(samples):           # audio render thread — just buffers
    ring.append(convertTo16kMono(samples))
    pauseDetector.feed(samples)

scheduler loop (off-thread):
    wait until pauseDetector.silence(>=0.7s) OR timer>=5s
    window = ring.trailing(30s)
    text   = batch.transcribe(window)         # existing AsrManager path
    preview = finalizedPrefix + qualityPipeline(text)   # vocab/ITN/paragraphs
    StreamingPartial.update(preview)          # mirrors to keyboard via App Group
    advance finalizedPrefix when window slides past committed audio

onStop():
    final = TranscriptionService.transcribe(samples)   # UNCHANGED full-file path
    # = vocab + paragraphs + number-normalization → saved transcript
    StreamingPartial.applyFinalSnapshot(final)
```

The final transcript path is **literally unchanged** — `onStop()` calls today's
`TranscriptionService.transcribe(samples:)`. So accuracy of the saved note is
**identical to today**; only the *preview source* changes.

### Where the model runs (keyboard constraint)

The keyboard extension has a ~60 MB ceiling and **must not run inference**. It
doesn't today — `StreamingPartial.publishProjection` mirrors the preview string
into the App Group and the keyboard renders it. That stays exactly the same: the
re-transcribe runs in the **main app**, the keyboard just displays the mirrored
text. No keyboard-side change beyond what already exists.

### Keyboard blast radius (the keyboard strip is the PRIMARY live surface)

For keyboard-initiated dictation the hero is a **transient screen** — its swipe-back
card cue exists to send the user *back to the host app*. The user then dictates
watching the **keyboard strip**, with Jot running **backgrounded**. Implications:

1. **Surface inversion.** The strip, not the hero, is the main live-text surface for
   this flow (the hero's streaming panel matters for in-app FAB dictations only).
   Design/validate the strip experience first. With streaming off + user lingering in
   Jot, the hero shows waveform/timer + the swipe-back cue — which reads *better*
   without streaming text competing for attention.
2. **Cadence character change.** EOU's ~320 ms word-ticker (throttled ~5 Hz IPC)
   becomes sentence-sized **chunk drops on pauses/5 s**. Calmer, but a feel change —
   validate on-device; consider a brief reveal animation so chunks don't pop.
3. **Background jetsam — the sharpest new risk.** In this flow the preview loop runs
   while **backgrounded**, where jetsam thresholds are much lower. Riskiest combo:
   high tier → 600M preview → backgrounded → re-transcribe every pause. Aggravates
   the known bug *"keyboard hangs in stale recording state when the app is killed
   mid-recording."* **Mitigation: demote preview to 110M (or suspend the preview
   loop) while backgrounded** — the strip is the only viewer then and 110M is fine
   for a glanceable strip; re-promote on foreground. Phase 5 must test backgrounded
   memory pressure explicitly.
4. **Stop→paste latency unchanged in every mode** — auto-paste has always waited for
   the batch result; streaming was never the paste source. On/off/tier changes
   nothing the keyboard user actually waits on.
5. **Less IPC** — ~5 Hz wakeups drop to one per pause/5 s; strictly good for the
   keyboard budget.
6. **Listening strip state is UNIVERSAL, not off-mode-only (review #2 F6):** with the
   new cadence every recording opens with up to ~5 s of no text (EOU's instant ticker
   is gone), so "recording, no text yet" is the first state of *every* keyboard
   dictation. Build it once, unconditionally. Scope correction: the level pulse
   mostly **exists** — the strip already renders amplitude-reactive `WaveformBars`
   off `AmplitudeProjection` (~10 Hz App Group channel) — so this is copy + state
   branching ("Listening… 0:12"), not new plumbing. (Also: that amplitude channel
   keeps running regardless, so the "less IPC" win is the text channel only — modest,
   not "strictly good.") Stop shows the existing transcribing state
   (calibrated-progress parity is a noted follow-up).

### Keyboard flow with streaming OFF — end-to-end (the safest configuration)

1. Host app → Dictate → URL-bounce opens Jot (unchanged).
2. Hero: waveform + timer + swipe-back cue. The cue **loops the whole recording**
   (no stream reveal until stop) — correct: its message is "go back."
3. User swipes back; Jot backgrounds, keeps recording.
4. Strip shows **"Listening… 0:12" + level pulse** (must be built — today the
   streaming text IS the indicator). Keyboard already knows state via
   `pipelinePhaseChanged`; elapsed timer runs locally off the phase transition.
5. Stop → existing transcribing state → batch pass in main app.
6. **Auto-paste lands at exactly the same moment as streaming-on** (paste always
   waited for batch; the caption was never the paste source).

**Net:** user loses only the glanceable caption. And the **background-jetsam risk
vanishes** — a backgrounded Jot is only buffering audio (no model resident, no ANE
bursts), making this *more* robust than even today's EOU flow. Alignment: the weakest
devices (min tier, off by default) get the most fragile flow (keyboard/backgrounded)
in its most robust configuration — the tiering de-risks exactly the flow that breaks
worst on them.

**Caveat:** wizard **W5 keyboard test** rides this same path — its copy needs a
streaming-off variant ("you'll see Listening — your text pastes when you stop") if it
currently promises live words.

## Cost — measured on real audio (NOT estimated)

Harness `/tmp/jot-vadbatch` (LongTest), Parakeet TDT **0.6B v2 (600M)** on this Mac,
on a **10.7-minute** real recording (`D7C39BBF…`, 84 natural pauses):

| # | Approach | Inference compute | Effective RTF | Worst single update | vs EOU |
|---|---|---|---|---|---|
| ① | Full batch, one pass on stop | **1.7 s** | 0.0026 | — | 0.04× |
| ③ | **Re-transcribe, capped 30 s (pause)** | **12.8 s** | 0.020 | **165 ms** | **0.34×** |
| ④ | **Timer 5 s + cap 30 s (no-pause fix)** | **19.6 s** | 0.031 | **174 ms** | **0.51×** |
| ⑤ | EOU streaming 120M (today) | 32.9 s | 0.052 | — | 1.00× |
| ② | Re-transcribe, **uncapped** | 72.3 s | 0.113 | 1623 ms | 2.20× |

Per-approach battery ledger (same run): inference wall-time, process CPU-seconds,
and **model-work** = audio-seconds pushed × model size, normalized to EOU=1×:

| Approach | wall-time | CPU-s | model-work (×EOU) |
|---|---|---|---|
| ① full-on-stop 600M | 1.7 s | 3.6 | 0.05× |
| ③ capped-30s pause 600M | 12.8 s | 15.6 | 19× |
| ④ timer-5s capped 600M | 19.4 s | 23.5 | 29× |
| ⑤ EOU stream 120M (today) | 32.9 s | 19.6 | 1× |
| ② uncapped pause 600M | 72.3 s | 149.2 | 213× |

Peak RAM 570 MB (600M model; the bundled 110M is much smaller).

**Read-out — battery is genuinely ambiguous, do NOT claim a clean win:**

- **The two metrics disagree.** By **inference wall-time** the capped designs *beat*
  EOU (12.8–19.4 s vs 32.9 s) — EOU fires ~2 000 tiny per-chunk inferences and the
  per-call overhead piles up. By **raw model-work** EOU is far *lighter* (a small
  120M model run once; re-transcribing overlapping 30 s windows re-chews audio
  ~19–29×). True on-device energy sits between these and depends on ANE power draw
  for a big-model burst vs a small-model trickle — **measure with Xcode's Energy
  gauge before claiming a saving.**
- **Apples-to-apples fix:** on iPhone the preview should run on the **bundled 110M**
  (same size class as EOU's 120M), which makes the model-work comparison fair and
  likely tips it favorable. The 600M numbers above are the pessimistic case.
- **The cap is load-bearing.** Uncapped is O(n²) — re-decodes the whole growing
  buffer every pause (72 s, 42.8× a single pass, 1.6 s lag, **149 s CPU**, 213× the
  model-work). The 30 s cap bounds every update to ≤30 s → 169 ms worst-case, flat
  regardless of dictation length.
- A whole-file batch is so cheap (1.7 s for 10.7 min, RTF 0.0026) that *post-stop*
  latency was never the real problem on a fast device.

**Therefore the justification for switching is NOT battery.** It is: one model
instead of two, preview text that equals the final transcript (vocab/numbers/
paragraphs, no jarring flip on stop), a smaller IPA, and far less code. Battery is,
at best, neutral-to-slightly-better with the 110M and the cap — to be confirmed
on-device.

### Scale check — 70-minute recording (confirms the cap linearizes cost)

Same harness, the longest file in the library (`03BDF623…`, 70.1 min, 535 pauses):

| Approach | inference time | RTF | worst refresh | vs EOU |
|---|---|---|---|---|
| ① full-on-stop 600M | 11.0 s | 0.0026 | — | 0.05× |
| ③ capped-30s pause | 86.6 s | **0.0206** | 186 ms | 0.40× |
| ④ timer-5s capped | 136.3 s | 0.0324 | 317 ms | 0.62× |
| ⑤ EOU 120M (today) | 218.1 s | 0.0519 | — | 1.00× |

Capped RTF is **flat vs the 10.7-min run** (0.0206 vs 0.0200) and worst refresh stays
~186 ms — a 6.5× longer recording did not raise per-update cost. The vs-EOU ratios
are identical at both scales (capped ≈0.40×, timer ≈0.60× by wall-time; 19–30× by
model-work). Uncapped at 70 min was not run — it would take ~2.5 h, which is the point.

### iPhone caveat (must measure on-device)

All numbers above are this Mac. iPhone ANE is slower. The bundled default on iPhone
is the **TDT-CTC 110M**, *not* the 600M (which is a +440 MB opt-in download). Plan:

- Run the live re-transcribe on the **bundled 110M** (cheaper, already shipped). The
  600M opt-in users get the same flow at higher compute.
- Re-measure ③/④ effective RTF on a real iPhone before committing the 5 s timer
  cadence and 30 s cap; tune the cap down if RTF approaches 1.0.

## What gets deleted

- `Jot/App/Transcription/StreamingTranscriptionService.swift` (EOU service singleton).
- `StreamingTranscriptionEngine` + the EOU drain loop in
  `StreamingPartial.swift` (the off-MainActor consumer half).
- All `StreamingEouAsrManager` usage; the **EOU 320ms model bundle** drops out of the
  IPA (smaller app).
- ~~`ModelLoadTimekeeper.swift`~~ — **KEEP** (review verified it's shared with the
  batch `TranscriptionService` load timing, not EOU-specific).
- The dual-model warm-up in `JotApp` (one fewer model to warm).
- `RecordingService` streaming wiring: `beginSession/endSession`, `streamingEngine`,
  the `StreamingBufferQueue` push/drain (replaced by the ring buffer + scheduler).

## What stays

- **`StreamingPartial`** (the presenter + App Group mirroring + throttle) — only its
  *source* changes from EOU partials to batch re-transcribes.
- **`TranscriptionService.transcribe(samples:)`** and the quality pipeline — reused
  for the **final pass only**. The preview loop must NOT call it verbatim (review
  B3): its `isTranscribing` guard throws `.busy` when a preview overlaps the stop
  pass, and it fires `CorrectionProvenance.clearPending()` + a `DiagnosticsLog`
  write **every call** (would corrupt adaptive-vocab provenance + spam logs ~50×/
  session), plus the 1 s `audioTooShort` guard rejects short windows. → extract a
  **lean inner inference path** (no provenance/diagnostics/busy-throw, own serial
  queue) for the preview cadence.
- Warm-hold, keyboard mirroring, the recording hero, paste flow — untouched.

## Model packaging & preview model — SUPERSEDED by FINAL DIRECTION (600M-only)

> The sections from here through "Automatic model selection" reflect the earlier
> two-model tiering and are kept for history; the 600M-only decision above replaces
> them. Still-valid pieces are restated in FINAL DIRECTION.

### (historical) Model packaging & preview model (decided earlier 2026-06-12)

**Owner decision: Option A — bundle 110M *and* 600M; remove EOU only after the
batch-streaming flag ships (Phase 6).** Preview uses the **same model as the final**
(whichever variant is selected in Settings), so preview converges exactly to final.

### Measured on-disk model sizes (uncompressed)

| Model | Size | Disposition |
|---|---|---|
| `parakeet-eou-streaming` (EOU 120M) | **214 MB** | **remove** (Phase 6, after streaming ships) |
| `parakeet-tdt-ctc-110m` (default) | 217 MB | keep (light default) |
| `parakeet-ctc-110m-coreml` (CTC aux, vocab biasing) | 99 MB | keep (used regardless of primary) |
| `parakeet-tdt-0.6b-v2` (600M) | **443 MB** | **bundle** (was download-only) |
| `silero-vad` | ~1 MB | bundle if we use Silero for pause detection |

**IPA Parakeet bundle deltas:**

| State | Parakeet bundle | Δ vs today (530 MB) |
|---|---|---|
| Today (110M + CTC + EOU) | 530 MB | — |
| Interim (add 600M, EOU still in) | 973 MB | +443 MB |
| **End state (110M + CTC + 600M, EOU gone)** | **759 MB** | **+229 MB** |

So the net feature cost is **+229 MB** (600M added 443, EOU removed 214).

**Sequencing revision (review #2 F7, recommended):** do NOT ship the 973 MB interim.
Keep 600M as the existing download-on-demand through the flag phase (zero work —
`modelDirectory()` already routes v2 to App Support), and **bundle 600M in the same
release that deletes EOU** — one +229 MB step; the both-bundled state never ships;
existing users pay one update delta instead of two. End state identical to Option A.
Noted tradeoff (unchanged from Option A): low/min-tier devices store 443 MB of 600M
they never load — acceptable per owner; revisit with device-class asset slicing only
if App Store size feedback demands it.

### Mechanics (low-risk)

- `Jot/Resources/Models/` is **gitignored** (out-of-band), so bundling 600M is a local
  copy of the 443 MB weights into `Resources/Models/Parakeet/`, **not** a git commit.
- `project.yml` already ships `Resources/Models` as a **folder reference** — anything
  dropped under it auto-bundles. No project.yml edit needed to add the weights.
- **Code change required:** `TranscriptionService.modelDirectory()` currently routes
  the 600M (v2) variant to the App Support **download** path; point it at the bundled
  directory (mirror the 110M `bundledTdtCtc110mDirectory()` pattern) so the 600M
  variant loads from the bundle with no first-run download.

### Automatic model selection — no user choice (DECIDED 2026-06-12)

The user must never see a model picker. At **first launch (wizard)** the app
auto-selects the speech model by **device RAM** and stores it as the default
`speechModelVariant`; both models are bundled (Option A) so selection is instant, no
download. The Settings picker remains only as a hidden power-user override.

**Why RAM, not chip:** 600M is ~2 GB resident at inference; jetsam (a crash) is the
hard limit, and that's RAM-bound. A RAM gate is also **future-proof** — every new
iPhone is 8 GB+, so it auto-qualifies with no device-ID table to maintain (a
chip-generation table would break on each unreleased device).

```swift
// Wizard first-launch, once:
let ram = ProcessInfo.processInfo.physicalMemory
let tier: SpeechTier = ram >= 8_000_000_000 ? .high      // 8GB: 15 Pro, 16, 17…
                     : ram >= 5_000_000_000 ? .mid       // 6GB: 12 Pro–15, 14 Pro ✓
                     :                        .low        // ≤4GB: 13, 12, 11, SE…
```

Device frontier (owner baseline: iPhone 14 Pro = 6 GB, confirmed working):

| 600M-capable (≥6 GB) | 110M only (≤4 GB) |
|---|---|
| 16/Plus/Pro/Max (8) · 15 Pro/Max (8) | 13 / 13 mini (4) |
| 15/Plus (6) · 14 Pro/Max (6) · 14/Plus (6) | 12 / 12 mini (4) |
| 13 Pro/Max (6) · 12 Pro/Max (6) | SE 2/3 · 11 series (3–4) |

**Tiering with the streaming on/off axis** (the re-transcribe loop runs the model
repeatedly *during* capture — sustained, heavier than today's single batch-on-stop
burst). The smallest devices simply **turn streaming off** — no inference during
capture, just batch-on-stop (the classic dictation flow, the safe baseline):

| Tier | RAM | Streaming | Preview model | Final pass (saved) |
|---|---|---|---|---|
| high | ≥8 GB | on | 600M | 600M |
| mid | 6 GB | on | **110M** (cheap bursts) | **600M** (full quality) |
| low | 4 GB (incl. iPhone 11 series) | on*(Phase 5 gate)* | 110M | 110M |
| min | ≤3 GB (X/XR era) | **off** | — (waveform/timer only) | 110M |

**Mid tier = dual-resident (review #2 F1).** Today's 600M opt-in user *already*
records with 600M resident (warmed at launch); residency is not the new cost —
**repeated preview bursts** are. So mid tier keeps 600M warm exactly as today (the
stop pass is instant — "paste timing unchanged" holds) and loads the 110M alongside
for the cheap preview bursts. This requires explicit **dual-manager** support
(Phase 0) and a **measured co-resident peak on a 6 GB device** as a Phase 5 gate;
fallback if it fails = drop the split (mid previews on 600M or goes streaming-off
while backgrounded).

The min tier runs **zero inference during dictation capture** (Ask still streams —
see the Ask exemption; phrasing per review #2 F4). Low tier's streaming-on default
is a Phase 5 decision: start **off** in the A/B build and promote if 110M-loop
thermals on A12/A13-era ANEs are clean. All boundaries promote/demote on measured
RTF/thermal/jetsam, not assumptions.

### One resolver + a user override

All of the above collapses to a single source of truth:

```swift
struct SpeechCapability { var streamingEnabled: Bool; var previewModel: Variant; var savedModel: Variant }
enum DeviceCapability {
    static func resolve() -> SpeechCapability {       // reads physicalMemory once
        // THRESHOLDS (review #2 F3): physicalMemory reports BELOW nominal
        // (kernel carve-out). 8 GiB nominal = 8.59e9; a "≥8e9" check could drop
        // every 8 GB device into mid tier. Uniform-margin thresholds instead;
        // calibrate against real values via the Diagnostics physicalMemory log.
        let ram = ProcessInfo.processInfo.physicalMemory
        if ram >= 7_000_000_000 { return .init(streamingEnabled: true,  previewModel: .v2,   savedModel: .v2) }
        if ram >= 4_600_000_000 { return .init(streamingEnabled: true,  previewModel: .ctc110, savedModel: .v2) }
        if ram >= 3_300_000_000 { return .init(streamingEnabled: true,  previewModel: .ctc110, savedModel: .ctc110) }
        return                          .init(streamingEnabled: false, previewModel: .ctc110, savedModel: .ctc110)
    }
}
```

**Pre-work (do now, costs nothing):** log `physicalMemory` into Help → Diagnostics so
real per-device values accumulate before thresholds are locked (owner's 14 Pro gives
the 6 GB data point). **Backfill (review #2 F3):** the resolved defaults are written
at **launch** when absent — not wizard-only, which would never reach existing
installs already past the wizard.

Every consumer (wizard, `RecordingService`, Settings) reads this — no scattered
device checks. The wizard writes the resolved defaults once at first launch.

**User-facing override — "Live text while dictating" (Settings):** a switch defaulting
to `streamingEnabled` from the resolver, but user-overridable. It is a **semi-separate,
independently shippable feature**:
- The "off" path is the safe baseline (today's flow minus the EOU preview), so it can
  land **before** the streaming work as the fallback everything degrades to.
- Doubles as a **battery/heat saver** for any device — no inference during capture is
  the lowest-power mode — not just a small-device default.
- min-tier default is off; a power user can force it on (at their own risk), and a
  big-phone user can force it off to save battery.

### What "streaming off" concretely means (per surface)

**Definition:** the toggle controls exactly one thing — whether any inference runs
*during* capture. Off = recorder only buffers audio; the batch stop-pass produces the
text. The saved transcript is **bit-identical** on/off (display+power setting, never a
quality setting — that invariant is what makes it safe to expose).

Four live-text consumers exist (verified); they do NOT all get the same treatment:

| Surface | Streaming off behavior |
|---|---|
| Recording hero (`RecordingHeroView`) | Audio-reactive waveform + timer during capture; reveal fires **once at stop** with final text. NOTE: today's `revealStream()` is partial-driven — must also fire on final-only. Swipe-back cue loops until that reveal (unchanged logic). |
| Keyboard strip | Needs a NEW explicit "Listening… 0:12" state (today the streaming text IS the recording indicator). Keyboard already observes `pipelinePhaseChanged` separately from the text mirror, so state is known — the strip UI for "recording, no text" must be built. Add a level-reactive pulse for mic reassurance. |
| Home live row (`LiveStreamingRow`) | Waveform/timer, same as hero. |
| **Ask voice input** | **EXEMPT — always streams.** `AskView` fills the question field from `streamingPartial.streamingText` as you speak (AskView.swift:113) — live text is the *input mechanism*, not a preview; off = dictating into a dead box. Ask queries are short (5–15 s) so cost is trivially bounded even on min tier. The toggle governs dictation-capture surfaces only. |

**Untouched by the toggle:** warm hold, auto-paste, transcript saving, vocab/
paragraphs/ITN, Ask retrieval, model tiering (independent axis).

**The two real UX costs + mitigations:**
1. **Perceived latency moves to the stop** (with streaming on, the user is already
   reading text when they stop). Mitigation: the calibrated stop-wait progress
   treatment already exists (`ModelLoadTimekeeper`/`LoadingPlaceholderText`, build 108).
2. **Loss of "is it hearing me" reassurance** — live text doubles as mic confirmation.
   The waveform must visibly react to voice; the keyboard strip needs a level pulse.

**Toggle mechanics:**
- **Tri-state `auto | on | off`** (not boolean): `auto` follows the device tier, so a
  future tier-table revision updates auto users while an explicit user choice is never
  clobbered.
- **Takes effect on next recording start** (same convention as the model picker) —
  no mid-session teardown.
- Settings copy sells the benefit: *"Live text while dictating — turning off saves
  battery."*
- The off-path is also the **failure degrade target** for streaming (preview model
  load failure, thermal pressure) — building it first means streaming fails into a
  designed state, not a broken one.

### The 600M RAM caveat (load-bearing for on-device gates)

`project.yml` notes Parakeet 600M is **~2 GB resident** at inference (vs 110M's far
smaller footprint). The re-transcribe loop bursts the model repeatedly *during*
capture — a sustained ~2 GB profile on older iPhones raises jetsam + thermal risk
(this is why 600M was opt-in originally; cf. Nemotron, ripped for iPhone RTF). So if
a user selects 600M, the **preview path inherits that RAM cost on every refresh** —
Phase 5 must measure 600M-preview memory + thermal on an older device, and the cap
(≤15 s window) is what keeps the per-refresh allocation bounded. If 600M-preview is
too heavy on-device, fall back to "preview on 110M, final on selected model" (the old
Option B) — preview won't exactly match final, but it stays cheap.

## Open questions / decisions

1. **Pause detector = a third model (review M1).** FluidAudio's Silero VAD
   (`segmentSpeech`) **already ships in the pinned 0.14.7** (no pin bump needed — my
   earlier note was wrong), BUT `VadManager.init` loads a CoreML model and
   **downloads it if absent**. So "one model" is really "one ASR + a tiny Silero
   VAD," and we must **bundle the Silero weights** (App Review 4.2.3(ii): no silent
   first-run download) or use a cheap energy-threshold gate (no model). Decision
   needed; if energy-gate, validate it on the pathological inputs in #4.
2. **Cap value** (15 s recommended from the sweep above) and **timer cadence** (5 s
   default) — tune on-device. The cap is the no-pause guard; the pause is the primary
   finalize trigger.
3. **Finalization boundary** — as the ~15 s overlap window slides, commit the text
   that fell out. Need a stable word-level commit (avoid re-flicker); token timings
   from the batch result give clean cut points. (v2: LocalAgreement — commit on
   two-pass agreement instead of position.)
4. **Vocabulary/ITN on every preview vs only final** — running the full pipeline each
   update is cheap (regex + lookup) and keeps preview==final; default to running it.

## Schema impact

None. No `@Model` changes; this is inference-path only.

## Implementation plan

Phased so each step is independently shippable and reversible. Behind a build flag
`previewSource = eou | batch` (default `eou` until the on-device gates in Phase 5
pass). The EOU subsystem is **not deleted** until the flag has shipped defaulting to
`batch` and proven stable (Phase 6).

### Phase 0 — Lean preview inference path (no behavior change)
The preview loop must NOT call `TranscriptionService.transcribe(samples:)` (review
B3). Add a dedicated lean path:
- New `PreviewTranscriber` (or `TranscriptionService.transcribePreview(samples:) async -> String?`):
  calls `manager.transcribe(samples, decoderState:)` on a loaded `AsrManager`, then
  the **text-only pipeline: paragraphs → number-normalization. NO vocabulary rescore
  on preview ticks (review #2 F2):** `VocabularyRescorerHolder.rescore` is a second
  CoreML inference (CTC spotter over the window audio,
  VocabularyRescorerHolder.swift:223) AND records correction provenance + diagnostics
  *internally* (:284, :239) — running it per tick doubles inference cost and corrupts
  adaptive-vocab provenance. Honest consequence: vocab terms may visibly correct on
  stop (sparse, acceptable; documented). **Omit** `CorrectionProvenance.clearPending()`
  and `DiagnosticsLog.record(...)` (stop-pass only). Returns `nil` (not throw) for
  windows < ~0.7 s instead of the `audioTooShort` throw.
- **Dual-manager support (review #2 F1):** `PreviewTranscriber` owns its own
  `AsrManager` whose variant may differ from the final-pass manager (mid tier: 110M
  preview alongside the warm 600M). Lifecycle: load at recording start, release on
  stop (mirrors today's EOU per-session shape); the final-pass manager keeps today's
  warm-at-launch lifecycle untouched.
- Its own serial guard (an actor or a dedicated single-flight) so overlapping preview
  ticks coalesce to "latest wins" rather than throwing `.busy`; never blocks the stop
  pass.
- Files: `Jot/App/Transcription/PreviewTranscriber.swift` (new),
  `TranscriptionService.swift` (expose the shared `AsrManager` or a `runInferenceRaw`).
- Test: unit-assert no provenance mutation, no diagnostics write, sub-second window
  returns `nil`, normal window returns text.

### Phase 1 — Pause detector + ring buffer + scheduler (main app)
- **Pause detector.** Decide per Open-Q #1. v1 default: a cheap **energy-threshold
  gate** (no model, no bundle) fed by the existing audio tap; emits `pauseDetected`
  on ≥0.6–1.0 s below threshold. (Alternative: bundle Silero + `VadManager`
  streaming — heavier, defer unless the energy gate misfires on Phase 5 pathological
  inputs.)
- **Ring buffer.** Accumulate the tap's 16 kHz mono Float32 into a bounded ring in
  `RecordingService` (replaces the EOU `StreamingBufferQueue` push/drain). Keep the
  whole recording for the stop pass; the preview reads a trailing slice.
- **Scheduler** (off-MainActor task): fire a preview re-transcribe when
  `pauseDetected` **or** a 5 s timer elapses (timer resets each update). Window =
  trailing **~15 s overlap** ending at `now` (NOT the isolated utterance — review B1).
  Commit/freeze words that have scrolled safely behind the window; keep cap-cut
  (timer-forced) text **volatile** — only hard-freeze on a confident pause (review
  M2). Do **not** carry decoder state across windows (tested worse).
- **Background-aware — never swap models mid-session (review #2 F5):** model
  demotion on backgrounding is the worst option (the load IS a spike at the
  lowest-jetsam moment; 110M↔600M text differences recreate the visible flip on
  every fg/bg transition). Rule: the session keeps its preview model; if Phase 5
  shows background pressure, **suspend the loop** while backgrounded → the strip
  degrades to the Listening state (a designed fallback). Re-resume on foreground.
- **Session-purpose-aware start (review #2 F4):** the scheduler start must know the
  capture's purpose — **Ask captures always stream** (the toggle and min-tier governs
  dictation captures only), and Ask uses a **faster cadence** (~1.5–2 s timer;
  queries are 5–15 s, cost trivially bounded) so a fluent 6-second question isn't a
  dead box for 5 s.
- Files: `RecordingService.swift` (ring + scheduler wiring),
  `PreviewScheduler.swift` (new), `PauseDetector.swift` (new).

### Phase 2 — Point the preview presenter at the new source
- `StreamingPartial.update(text:isFinal:sessionID:)` is fed by the scheduler instead
  of `StreamingTranscriptionEngine`. Everything downstream (throttle, App Group
  mirroring, keyboard strip) is **unchanged** — the keyboard still just renders the
  mirrored string and runs no inference.
- Gate the source on `previewSource`: `eou` → today's engine; `batch` → the scheduler.
- **Streaming OFF path** (`SpeechCapability.streamingEnabled == false`, or the user
  toggle): do not start the scheduler at all. The preview panel shows a
  waveform/timer + "Transcribing…" on stop; only the Phase 3 batch-on-stop runs. This
  is the safe baseline and the lowest-power mode — it should be the first thing built
  (everything degrades to it) and can ship independently.

### Phase 3 — Final pass on stop (unchanged path)
- `RecordingService.stop()` already calls `TranscriptionService.transcribe(samples:)`
  for the saved transcript. Keep it verbatim. After it returns,
  `StreamingPartial.applyFinalSnapshot(final)` so the preview converges to the saved
  note. The cap/overlap never touches the saved transcript.

### Phase 4 — Device resolver, wizard auto-select, settings toggle
- **`DeviceCapability.resolve()`** (new, one place): reads `physicalMemory` → returns
  `{ streamingEnabled, previewModel, savedModel }` (the tier table above). All
  consumers read this — no scattered device checks.
- **Wizard first-launch** (`SetupWizardView` / first-run hook): write the resolved
  defaults once (`speechModelVariant` = `savedModel`, `previewModel`,
  `streamingEnabled`). Invisible to the user. Idempotent but guard so a manual user
  override isn't clobbered.
- **Settings toggle "Live text while dictating"** — defaults to
  `streamingEnabled` from the resolver, user-overridable (off = battery saver / safe
  baseline; on = force-enable on a small device at own risk). Semi-separate feature;
  the off-path can ship before the streaming work.
- The Settings model-variant picker stays as a hidden power-user **override** of the
  auto-selected `savedModel`. Optionally surface `previewSource` in a debug menu for
  the Phase 5 A/B.
- **Key design (review #2 F8):** `speechModelVariant` gets the same tri-state
  treatment as the toggle — store `"auto"` and resolve at read (or add a
  `speechModelVariantSource` key) — otherwise a future tier-table fix can never reach
  auto users, and "don't clobber a manual override" is unimplementable (today's key
  has no provenance bit). `previewModel` + `streamingEnabled` live in the **App
  Group** (the keyboard strip branches its recording UI on streaming state; W5 copy
  variant needs it). Verified non-issue: the AppGroup getter already recognizes
  `"parakeetV2"` (AppGroup.swift:326-337) — no fallback-rewrite risk.

### Phase 5 — On-device validation (gates before flipping the default)
Measure on a real iPhone (oldest supported), 110M:
- **Divergence:** preview-vs-final on a multi-utterance dictation (target < ~2 %,
  per the overlap result).
- **Thermal + energy:** Xcode Energy gauge over a 10-min continuous dictation; watch
  `ProcessInfo.thermalState` for throttling (review M3).
- **Final-pass RTF** at 1 / 10 / 40 / 70 min (review B2) — confirm post-stop wait is
  acceptable; it's today's behavior but unmeasured.
- **Pathological inputs** (review #4): continuous no-pause 40 s; noisy/music
  background; < 2 s clips; false-pause mid-word. Confirm graceful degradation (cap +
  timer fallbacks, volatile-not-frozen on forced cuts).
- **Gate to flip default → `batch`:** divergence < 2 %, no sustained thermal
  throttle, final-pass wait within today's envelope.

### Phase 6 — Delete the EOU subsystem (follow-up, after the flag ships on `batch`)
- Remove `StreamingTranscriptionService`, `StreamingTranscriptionEngine`,
  `StreamingBufferQueue` drain, the EOU warm-up in `JotApp`, and **the EOU 320 ms
  model bundle** from the IPA (smaller app). Keep `StreamingPartial`,
  `TranscriptionService`, `ModelLoadTimekeeper` (shared).
- Remove the `previewSource` flag once `batch` is the only path.

### Sequencing notes
- Phases 0–4 land together behind the flag (no user-visible change at default `eou`).
- Phase 5 is the real work — on-device measurement is load-bearing for the go/no-go.
- Phase 6 is irreversible; only after a shipped build has defaulted to `batch`.

## KNOWN REGRESSION — model-loading indicator gone in batch mode (BACKLOG, build 122)

**Status: backlog, must fix before Phase 6 / EOU deletion.** Owner-reported on
build 122.

**Symptom:** During the slow first model-load after an app update (the >1 min
cold ANE compile — see `model-load-caching.md`), neither the hero nor the keyboard
strip shows the "Loading [model]…" progress affordance any more. The surface sits
on a dead "Listening…" for the whole load; recording is live but no text and no
loading signal.

**Root cause (verified in code):** the loading affordance is driven entirely by the
EOU path. The hero gates on `streamingService.sessionLoadState == .loading`
(`RecordingHeroView.swift:503`); the keyboard strip paces its bar off the
`streamingLoadStartedAt` / `streamingLoadEstimateSeconds` App Group keys — both set
ONLY by `StreamingTranscriptionService.beginSession` (`:114-127`). In batch mode
`kickOffStreamingSession` branches to `PreviewScheduler` BEFORE
`StreamingTranscriptionService.beginSession` runs, so `sessionLoadState` stays
`.idle` and the keys stay nil → `isLoadingModel` is always false. Meanwhile
`previewTranscribe` returns nil until `TranscriptionService.modelState == .ready`,
so nothing shows during the load.

**Owner spec for the fix (deliberately simpler than the old calibrated bar):**
- Drop `ModelLoadTimekeeper`'s per-device calibration — it was the old bug: it paced
  off measured load time, but warm loads are ~instant, so after an update it raced
  the bar to ~100% then stalled for the real cold minute.
- Replace with a FLAT pace: show a moving indicator for a fixed window, **45 s
  default**, that keeps advancing (eases toward but never claims 100%).
- The moment real transcript text appears (model ready → first preview/words),
  **hand off straight to the text** — don't wait out the 45 s.

**Fix shape (M):** drive the loading affordance off the BATCH model state in batch
mode — `TranscriptionService.modelState` (`.notLoaded`/`.loading` → show; `.ready`
→ hand off). Publish the same two App Group keys from `TranscriptionService`'s load
path (start = load begins, clear = `.ready`) so the keyboard strip lights up too,
with a fixed 45 s estimate instead of `ModelLoadTimekeeper.estimatedSeconds`. Both
surfaces, plus the timekeeper simplification. Interacts with `model-load-caching.md`
(if the compiled model is cached across updates the slow load shrinks, but the
indicator is still needed as the honest fallback).

## Phase-5 findings — build 121 on-device + SchedulerSim (2026-06-13)

**Owner repro (build 121, on-device):** slow counting with pauses → words dropped
from the live preview ("silence → word → silence doesn't show up"). Saved note
nearly complete (the full stop-pass is unaffected) — the loss is in the preview.

**SchedulerSim** (`/tmp/jot-vadbatch`, NeMo-style simulated streaming: replay
through the EXACT scheduler logic in 0.1 s chunks, word-level S/D/I alignment vs
full-pass + known truth; corpus = say(1) slow-counting w/ gaps + quiet variants +
isolated-words + real 52 s control + silence-spliced real):

| Variant | counting DEL (the bug) | real DEL | verdict |
|---|---|---|---|
| current (121) | 3/40 | 3 | bug reproduced ("six","eight","one" dropped) |
| v1: trim window to speech−0.5 s | **14/40** | — | REJECTED — Parakeet decodes sub-2 s clips terribly; trimming starves context |
| v2: retry-not-discard + 2 s spacing + gate 0.005 | **0/40** | 5 | **WINNER** |
| v2 minus zero-pad | 0/40 | 5 | padding does nothing — dropped from fix |
| v2 with gate back at 0.008 | 0/40 | **13** | gate matters: a quiet phrase never registers → never ticked |

**Root cause (two-part):** (1) the B2 "advance window on empty result" discarded
isolated quiet words whose silence-heavy window decoded to nothing; (2) RMS gate
0.008 mis-tagged soft speech as silence so it never ticked. **Fix (in
`PreviewScheduler`, build 122):** never advance past speech on an empty commit —
retry with MORE audio (the next utterance joining rescues the decode); runaway
bounded structurally by a **2 s global min tick spacing** (+ give-up valve: 3
empties at cap length → skip); gate **0.005**. Lesson: the model wants more
context, not less — and offline simulated-streaming caught v1 as a regression
before it shipped.

**UX affordance (same build):** `TranscribingText` — stepping serif ellipsis
concatenated into the transcript text run (wraps with the line, lands where the
next word will appear; ~1.8 s cycle; Reduce-Motion static fallback; hidden while
paused) on hero + keyboard strip, replacing the keyboard's misplaced blinking
caret.

## Adversarial review + random-sample test (2026-06-12)

Independent skeptical review of this plan, plus a 20-random-recording empirical test
(`/tmp/jot-vadbatch` PauseTest). Findings, filtered:

- **B1 (BLOCKER, resolved by revision)** — "pause-freeze = segment-concat → the flip
  returns." **Confirmed on data:** isolated pause-freeze diverges 4.5 % mean / 8 % on
  multi-utterance dictations from the final pass. **Carried decoder state is WORSE**
  (10.9 %, refuted). **Overlap window fixes it (1.3 %).** → design revised to
  pause-trigger + overlap-window (see Decision above).
- **B3 (MAJOR, accepted)** — preview loop can't reuse `transcribe(samples:)` verbatim
  (`isTranscribing` busy-throw + per-call `clearPending()`/diagnostics + 1 s guard).
  → lean inner inference path. (See "What stays".)
- **M1 (accepted)** — VAD is a third (downloadable) CoreML model; bundle Silero or
  energy-gate. (See Open Q #1.)
- **M2 (accepted)** — only hard-freeze on a *confident* pause; cap-cuts stay volatile.
- **M3 (accepted, already a TODO)** — measure thermal + energy on-device; sustained
  ANE bursts while the mic runs is a new load profile EOU never created.
- **m1 (verified, reassuring)** — nothing consumes EOU's end-of-utterance signal
  beyond preview rendering; warm-hold auto-stop is timer-based (RecordingService
  `warmCooldownTask`). Deletion is behaviorally safe.
- **B2 (noted, pushed back)** — iPhone final-pass-on-stop cost is worth measuring,
  but it is **today's behavior** (the app already does a full batch pass on stop),
  not a new contradiction this design introduces. Measure 110M RTF at 1/10/40/70 min.

## Adversarial review #2 (2026-06-12) — tiering / packaging / toggle material

Second independent review targeting the post-review-1 additions. Findings, filtered
(fixes folded into the sections above):

- **F1 (BLOCKER, resolved)** — mid tier (110M preview / 600M final) was unsupported:
  one process-lifetime `AsrManager` exists; both naive builds broke a claim (600M
  co-resident defeats the RAM rationale / 600M load-at-stop costs 12–40 s with no
  progress signal, falsifying "paste unchanged" — worst in the backgrounded keyboard
  flow). **Resolution: dual-resident** — 600M stays warm as today (residency was
  never the new cost; bursts were), 110M is a second per-session preview manager.
  Phase 0 dual-manager + Phase 5 co-resident 6 GB gate.
- **F2 (BLOCKER, accepted)** — "vocab on every tick is cheap" was wrong: rescore =
  CTC CoreML inference over window audio + provenance/diagnostics writes *inside*
  the rescorer (VocabularyRescorerHolder.swift:223/284/239). Preview now runs
  ITN+paragraphs only; vocab terms may correct on stop (sparse, documented).
- **F3 (MAJOR, accepted)** — RAM thresholds had inconsistent/near-zero margins
  (8 GiB nominal = 8.59e9; reported < nominal → `≥8e9` could demote every 8 GB
  device). Now uniform-margin (7.0/4.6/3.3e9) + Diagnostics `physicalMemory` logging
  before locking + **launch-time backfill** (wizard-only write never reaches existing
  installs).
- **F4 (MAJOR, accepted)** — Ask exemption needed session-purpose-aware scheduler
  start + an Ask-specific faster cadence (~1.5–2 s) or a 6-second question is a dead
  box for 5 s. "Min tier = zero inference during capture" rephrased to *dictation*
  capture.
- **F5 (MAJOR, accepted — reviewer's alternative)** — background model-demotion was
  the worst option (load spike at lowest-jetsam moment + visible 110M↔600M flip per
  fg/bg). Rule: never swap models mid-session; suspend the loop under pressure →
  Listening state.
- **F6 (accepted)** — Listening strip state is the **universal** first-~5 s state of
  every recording (not off-mode UI); level pulse already exists
  (`AmplitudeProjection` ~10 Hz + `WaveformBars`) → scope down; "less IPC" claim
  softened (amplitude channel persists).
- **F7 (accepted, owner may veto)** — don't ship the 973 MB interim: 600M stays
  download-on-demand through the flag phase, bundles in the EOU-deletion release
  (one +229 MB step, same end state).
- **F8/F9 (accepted)** — `speechModelVariant` needs `auto` provenance (else tier
  fixes never reach auto users); `previewModel`/`streamingEnabled` are App Group
  keys; iPhone 11 series corrected to 4 GB/low; low tier's streaming-on default is
  now a Phase 5 gate (start off, promote on clean thermals).

## Related

- Report: https://jot-batch-streaming.ideaflow.page
- Prior spike: `~/code/jot/streaming-test/RESEARCH.md` (sliding-window TDT: 15.6%
  divergence, ~5 s TTFT — rejected).
- ITN side-finding: FluidAudio's `TextNormalizer` is a native-NeMo no-op on iOS;
  the manual `NumberNormalizer` (1181 lines) is load-bearing. Keep it.
- CLAUDE.md "DICTATION ARCHITECTURE" + `features.md` §3 (transcription).
