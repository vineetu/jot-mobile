# Vocabulary rescore parallelization — post-stop lag investigation

**Status:** research only (no code change, no deploy). 2026-06-14.
**Question:** after Stop there's a measurable ~3–4 s lag before final text lands, with live preview ON *and* OFF. Owner suspects the vocabulary correction (CTC rescore) runs serially after the main transcribe and could run in parallel. This doc maps the pipeline, confirms the serial CTC pass, quantifies it with measured numbers, analyses the dependency / ANE-contention reality, and ranks fixes.

---

## TL;DR

- **Confirmed:** vocab rescore is a SECOND, separate CoreML model inference (MelSpectrogram + AudioEncoder) run over the **same full audio buffer**, dispatched **strictly after** the TDT transcribe returns. It is NOT cheap text post-processing. The only cheap part is the final merge (`ctcTokenRescore`, pure CPU, ~14 ms).
- **Measured (Mac M-series ANE, FluidAudio pinned rev, 110M):** the CTC spot pass is **~2× the TDT transcribe on short clips and 3–5× on long clips** (it re-chunks at 15 s windows). Means: TDT 139 ms / CTC 273 ms / merge 14 ms on a 2–60 s mix; TDT 183 ms / CTC 632 ms / merge 20 ms on a 20–60 s mix. iPhone ANE is slower and is the device the owner runs (bundled 110M), so these scale into the seconds the owner sees.
- **The CTC inference does NOT depend on the TDT result.** It consumes the raw audio samples. Only the lightweight *merge* needs the TDT `tokenTimings`. So the expensive pass **can be kicked off concurrently with TDT** and the merge run after both finish.
- **But parallelizing buys less than it looks.** Because CTC(B) >> TDT(A), overlapping only hides `min(A,B)` = the smaller TDT pass. Measured: serial 835 ms → overlapped 652 ms on the long-clip set (~22% off the rescore-inclusive wait, not the whole lag). And on a single ANE the two encoders likely **serialize at the hardware level anyway**, eroding even that.
- **Higher-impact levers:** (1) the rescore can't run per-tick on streaming today (deliberately disabled), so the whole CTC cost lands at stop — moving it to a **partial/streaming rescore over already-captured windows during dictation** hides almost all of it; (2) verify the CTC bundle is actually warm at stop (it is *prepared* at launch but check for a cold first-dictation / post-memory-warning reload); (3) shrink B (skip the spot pass when the transcript contains no fuzzy-near vocab candidate).
- **Caveat on "3–4 s":** the rescore is a real and growing chunk, but the measured CTC pass alone is sub-second on Mac. On-device the lag is likely **CTC pass + any cold model/bundle (re)load + the run-loop/paste hops**. Instrument the device before assuming rescore is the *entire* 3–4 s (see "Measure on device").

---

## 1. The post-stop pipeline (cite file:line)

Entry for the in-app/keyboard/FAB stop path is `TranscriptionService.transcribe(samples:)`
(`Jot/App/Transcription/TranscriptionService.swift:327`) → `runInference(on:label:audioDurationSeconds:)` (`:532`). All batch callers funnel here (hero, keyboard URL-bounce, wizard W5, Shortcuts `DictateIntent` at `:428/:455`, Ask at `AskView.swift:815`, rewrite at `RewritePickerSheet.swift:725`).

Inside `runInference` the steps are **strictly sequential**:

| # | Step | file:line | Cost |
|---|------|-----------|------|
| 1 | `ensurePreparing().value` — await TDT model load (no-op if warm) | `:571` | 0 if warm; **30–40 s cold**, or a re-load if evicted by memory warning |
| 2 | `manager.transcribe(samples, decoderState:&state)` — **TDT primary** (preprocessor+encoder+TDT decoder), returns `text` + `tokenTimings` | `:597` | **A** (measured 100–300 ms) |
| 3 | `CorrectionProvenance.shared.clearPending()` | `:619` | trivial |
| 4 | `DiagnosticsLog.record(... vocabularyGate ...)` | `:623` | trivial |
| 5 | **`if VocabularyStore.shared.isEnabled, let timings = result.tokenTimings`** → `VocabularyRescorerHolder.shared.rescore(transcript:tokenTimings:audioSamples:)` | `:633`–`:647` | **B+C** (the vocab pass — see §2) |
| 6 | `ParagraphSegmenter.segment(...)` (needs timings) | `:657` | cheap CPU |
| 7 | `FillerWordCleaner.clean(...)` (regex) | `:666` | cheap CPU |
| 8 | `NumberNormalizer.normalize(...)` (lookup) | `:670` | cheap CPU |
| 9 | return → caller publishes/pastes (`JotApp.swift:1273`, etc.) | — | run-loop + paste hop |

Steps 2 and 5 are the only model-inference steps. Step 5 runs **only after** step 2 returns, on the same `await` chain — this is the serial coupling the owner suspects. **Confirmed serial-after-TDT.**

The live-preview path is a *different* function, `previewTranscribe(samples:)` (`:724`), which **deliberately skips the vocab rescore** (`:697` doc comment: "NO vocabulary rescore … a second CoreML inference … running it per tick doubles inference cost and corrupts adaptive-vocab state"). That is why the lag is identical whether preview is ON or OFF: **preview never does the rescore; the saving stop-pass always does.** Preview being on/off changes nothing about the stop-time CTC cost.

---

## 2. What the rescore actually does (it is CTC inference, not text)

`VocabularyRescorerHolder.rescore(...)` (`Jot/App/Vocabulary/VocabularyRescorerHolder.swift:213`):

```
let spotResult = try await spotter.spotKeywordsWithLogProbs(audioSamples:customVocabulary:minScore:)   // :223  ← EXPENSIVE
let output = rescorer.ctcTokenRescore(transcript:tokenTimings:logProbs:frameDuration:)                  // :229  ← cheap CPU
```

- **`spotKeywordsWithLogProbs`** (FluidAudio `CtcKeywordSpotter.swift:110` → `+Inference.swift:12`) runs the CTC stack's **own MelSpectrogram model then AudioEncoder model** over the audio (`computeWithStagedModels`, `+Inference.swift:150`: `melModel.compatPrediction` then `encoderModel.compatPrediction`), producing CTC log-probs `[T,V]`. For audio > `maxModelSamples = 240_000` (= **15 s @ 16 kHz**, `ASRConstants.swift:12`) it **chunks with 2 s overlap and runs the pair per chunk** (`computeLogProbsChunked`, `+Inference.swift:33`). This is the bulk of the post-stop wait. **This is `B`.**
- **`ctcTokenRescore`** (FluidAudio `VocabularyRescorer+TokenRescoring.swift:142`) is a **synchronous, non-async pure-CPU** DP/BK-tree merge of the TDT transcript against the CTC log-probs. **This is `C` — trivial.**

**Inputs / dependency:** `spotKeywordsWithLogProbs` takes **only `audioSamples` + the vocabulary** — it does NOT read `tokenTimings` or the TDT text. `tokenTimings` is consumed solely by the cheap `ctcTokenRescore` merge (and the `VocabularyGate` / `CorrectionProvenance` bookkeeping at `:259`–`:287`). So the dependency is: **B is independent of TDT; only C depends on TDT.**

**Separate models, not shared:** the TDT primary uses `AsrManager.preprocessorModel` + `encoderModel` (FluidAudio `AsrManager.swift:12-13`, loaded from the TDT bundle). The CTC spotter uses a **completely separate** `CtcModels.melSpectrogram` + `.encoder` pair (`CtcModels.swift:37-38`), loaded from `parakeet-ctc-110m-coreml/` (`CtcModelCache.swift:62`). The CTC encoder is **not** reused from the TDT pass — the audio is encoded **twice** (once by each stack). This is the structural reason B is so large.

---

## 3. Measured numbers

Harness target written for this investigation: `/tmp/jot-vadbatch/Sources/RescoreTiming/main.swift` (added to `Package.swift`), times A/B/C separately on real recordings from `~/Library/Application Support/Jot/Recordings` (1843 real clips), 110M, 5-term vocab. **Mac M-series ANE** (NOT iPhone — treat ratios as the portable finding; absolute ms are faster than device).

**2–60 s mix (n=12):**
```
TDT transcribe (A):   139 ms
CTC spot       (B):   273 ms   ← extra wait vocab adds today (serial)
merge          (C):    14 ms
serial total (A+B+C): 425 ms
if B overlapped A:    287 ms   (= max(A,B)+C)
B as % of A:          197%
```

**20–60 s mix (n=8), where CTC chunking dominates:**
```
TDT transcribe (A):   183 ms
CTC spot       (B):   632 ms   ← grows with chunk count
merge          (C):    20 ms
serial total (A+B+C): 835 ms
if B overlapped A:    652 ms   (~22% saved)
B as % of A:          346%
```

Per-clip highlights (chunks = ceil(dur/15 s)): a 46.3 s clip → A=238 ms, **B=1008 ms** (4 chunks); 32.6 s → A=160 ms, B=757 ms (3 chunks). **B scales ~linearly with duration / chunk count; A grows much more slowly.** So the longer the dictation, the more the rescore dominates the post-stop wait — and the less overlap helps (because B already dwarfs A).

**Reading across to iPhone:** the owner runs the bundled 110M on iPhone ANE, materially slower than this Mac. If the same B/A≈2–3.5× ratio holds and the absolute scale is, say, 3–5× the Mac, a 20–40 s dictation's CTC pass alone plausibly reaches **1.5–3 s** — consistent with the reported 3–4 s, *with the remainder being the run-loop/paste hop and any cold (re)load*. Confirm on device before attributing the entire 3–4 s to B (see §6).

---

## 4. Can it run in parallel? Dependency + ANE-contention analysis

**Dependency:** YES, B can be hoisted to run concurrently with A. B needs only the audio (already in hand at Stop). Only C needs A's `tokenTimings`. Structurally:

```
let audio = samples
async let tdt = manager.transcribe(audio, decoderState:&state)   // A
async let spot = spotter.spotKeywordsWithLogProbs(audio, vocab)   // B  (independent)
let (txt, timings) = (await tdt.text, await tdt.tokenTimings)
let logProbs = await spot.logProbs
let merged = rescorer.ctcTokenRescore(txt, timings, logProbs, …)  // C  (after both)
```

The actor topology already allows this: `AsrManager` is its own actor; `CtcKeywordSpotter` is a `Sendable struct` and `VocabularyRescorerHolder` is a *separate* actor — they do **not** share a mailbox, so Swift-level concurrency is free. (Note the `inout TdtDecoderState` would need a local copy, trivial.)

**ANE contention — the catch:** both passes are CoreML graphs configured `cpuAndNeuralEngine` (TDT via FluidAudio's `AsrModels` config; CTC explicitly `MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)`, `CtcModels.swift:251`). The Apple Neural Engine is a **single shared coprocessor with one command queue**; concurrent `MLModel.prediction` calls from two graphs are **serialized by the ANE scheduler**, not run in true parallel. So "parallel" at the Swift level largely collapses back to serial at the hardware level — the OS interleaves but does not double throughput. Realistic upside of naive overlap ≈ the small slice where one pass is on CPU pre/post-processing while the other is on ANE, i.e. *less* than the `max(A,B)+C` arithmetic suggests. The measured `max(A,B)+C` (652 ms vs 835 ms) is already only ~22% on long clips; real ANE-contended overlap will be smaller.

**Conclusion:** parallelizing the CTC inference with TDT is *correct and safe* but **low payoff** given (a) B >> A so overlap hides only the small A, and (b) ANE serialization erodes even that. It is not the lever that removes 3–4 s.

---

## 5. Recommendations (ranked by impact / effort / risk)

### R1 — Streaming/partial rescore during dictation (HIGH impact, MED effort, MED risk)
The entire CTC cost lands at Stop only because preview deliberately omits it (`TranscriptionService.swift:697`). The audio is captured incrementally; the CTC spotter already **chunks at 15 s windows internally**. Run the spot pass on each *completed* 15 s window *during* dictation (on a low-priority task, latest-window-wins, never on the saving path), cache the per-window log-probs, and at Stop only spot the final (in-progress) window + run the cheap merge. This hides ~all of B behind the dictation itself. **Impact:** removes the dominant, duration-scaling cost — the longer the dictation (where the pain is worst) the bigger the win. **Risks:** (a) doubles ANE load *during* dictation (contends with the preview re-transcribe loop — must be lower priority and gated to when preview isn't mid-tick); (b) adaptive-vocab provenance (`CorrectionProvenance`, `VocabularyGate`) is built for one whole-transcript pass — partial passes need careful provenance/merge reconciliation (the same reason it was disabled per-tick in `:697`); (c) battery. **Mitigation:** only pre-spot *sealed* windows, never re-spot, and keep the single final merge whole-transcript. This is the only option that plausibly closes most of the gap.

### R2 — Confirm CTC bundle is warm at Stop; warm it earlier if not (HIGH-if-cold impact, LOW effort, LOW risk)
`VocabularyRescorerHolder.prepare(...)` IS already called at launch when vocab is enabled (`JotApp.swift:205-211`, gated on `VocabularyStore.isEnabled && CtcModelCache.shared.isCached`). BUT:
- It is **best-effort detached** — on a cold keyboard-bounced or just-launched process the first dictation can hit `rescore()` before `prepare()` finished; the `guard let spotter…` returns nil and that *first* dictation silently skips vocab (no extra wait, but also no correction).
- The memory-warning handler (`TranscriptionService.swift:1429`) evicts the **TDT manager** but does **not** evict `VocabularyRescorerHolder` — so CTC stays warm across memory warnings (good). However, the *first* `spotKeywordsWithLogProbs` after a fresh load still pays CoreML graph specialization/first-run cost on ANE (a one-time per-process tax not captured in my warm means).
**Action:** add a one-shot tiny warm-up *inference* (spot a ~1 s silence buffer) right after `prepare()` to pay the ANE first-run specialization off the hot path; and verify on device (via the existing signposts) that the first real dictation isn't paying a cold spotter load. **Low risk, cheap, and removes a possible large one-time chunk of the 3–4 s on the very first dictation.**

### R3 — Parallelize CTC inference with TDT (LOW impact, LOW effort, LOW risk)
The `async let` hoist in §4. Safe and clean, but ANE serialization + B>>A means ~10–22% off the rescore-inclusive wait at best, and only on longer clips. **Do it as a cheap incremental win, but do not expect it to fix the reported lag.** Best combined with R1 (parallelize the *final-window* spot with the final TDT decode).

### R4 — Skip the spot pass when no vocab term is plausibly present (MED impact, MED effort, MED risk)
B runs unconditionally whenever vocab is enabled and timings exist, even when the transcript contains nothing close to any vocab term. A cheap pre-filter (fuzzy string distance of each vocab term's surface form against the TDT transcript tokens, CPU-only) could skip `spotKeywordsWithLogProbs` entirely on the majority of dictations that mention no custom term. **Impact:** removes B on the common case. **Risk:** a too-tight filter drops real corrections (the whole point of CTC-WS is acoustic, not textual, matching — a badly-misheard term may not be textually near). Needs tuning against the adaptive-vocab corpus. Medium confidence.

### R5 — Shrink B structurally (LOW priority, HIGH effort)
The duplicate-encoder waste (§2) is the root cost: the audio is mel+encoded twice. FluidAudio's `spotKeywordsFromLogProbs` (`CtcKeywordSpotter.swift:191`) and `applyLogSoftmax` (`:268`) exist precisely so a **unified preprocessor that exports CTC logits alongside encoder features** could feed the spotter without a second encoder pass. That would require the TDT model export to also emit a CTC head's logits (the bundled 110M *is* a hybrid TDT+CTC model — `CtcHead.mlmodelc` is fetched but, per `TranscriptionService.swift:246-255`, the app's biasing uses the *separate* CtcModels stack). Reusing the primary encoder's CTC head would roughly **halve B**. High effort (FluidAudio/model-export change, likely a fork) — park it, but it's the principled fix.

---

## 6. Measure on device before committing

My numbers are Mac ANE. Before building anything, confirm the device split with the **existing signposts** already in the code:
- `signposter.beginInterval("transcribe-inference")` wraps step 2 only (`TranscriptionService.swift:581/605`) — that's A.
- There is **no signpost around the rescore (step 5)** today. Add one transient `OSSignpost` (or a `DiagnosticsLog` timing) around the `VocabularyRescorerHolder.shared.rescore(...)` call (`:633`) to capture B+C on device, and one around `ensurePreparing().value` (`:571`) to catch a cold/evicted reload. Run a 30–40 s dictation with vocab ON and OFF on the owner's iPhone and read Instruments / Diagnostics. That isolates: cold load vs A vs B vs the paste hop — and tells you whether R1/R2 or something else (a cold TDT reload at `:571`, or a paste-side delay in `JotApp.swift:1273`) owns the 3–4 s.

---

## 7. Files cited

- `Jot/App/Transcription/TranscriptionService.swift` — `transcribe(samples:)` `:327`; `runInference` `:532`; TDT `:597`; rescore call `:633`; preview (no-vocab) `:697`/`:724`; cold-load wait `:571`; memory eviction (TDT only) `:1429`.
- `Jot/App/Vocabulary/VocabularyRescorerHolder.swift` — `rescore` `:213`; spot `:223`; merge `:229`; prepare/load `:86`.
- `Jot/App/Vocabulary/CtcModelCache.swift` — bundled CTC load `:88`; coalescing coordinator `:11`.
- `Jot/App/JotApp.swift` — launch-time `prepare(...)` `:205`; publish `:1273`.
- FluidAudio (pinned rev `50aa071…`): `CtcKeywordSpotter.swift:110`, `CtcKeywordSpotter+Inference.swift:12/33/150`, `CtcModels.swift:37/76/251`, `VocabularyRescorer+TokenRescoring.swift:142`, `AsrManager.swift:12`, `ASRConstants.swift:12`.
- Harness: `/tmp/jot-vadbatch/Sources/RescoreTiming/main.swift` (this investigation).
```
```

---

## Empirical parallel-vs-serial test (measured)

**Date:** 2026-06-14. **Harness:** `/tmp/jot-vadbatch/Sources/ParallelTest/main.swift` (new target). **Machine:** this Mac's ANE — *not* the iPhone (see caveat). Both passes are the **real FluidAudio inferences** the app uses: A = `AsrManager.transcribe` (TDT mel+encoder+decoder), B = `CtcKeywordSpotter.spotKeywordsWithLogProbs` (CTC mel+encoder over the same audio). 110M, 5-term vocab.

**Method.** Per clip, per compute-unit setting: 7 iterations, **first discarded as warm-up**, report **medians**.
- `T_serial` = `await A` then `await B` (today's app order).
- `T_concurrent` = `async let A; async let B; await both` — A on the `AsrManager` actor, B on the `CtcKeywordSpotter` (separate Sendable struct), so the two CoreML graphs run as genuinely independent concurrent tasks (the exact topology §4 proposes; TDT decoder state deep-copied per task).
- Verdict knob: `T_concurrent ≈ max(A,B)` ⇒ overlap WON; `T_concurrent ≈ T_serial (≈ A+B)` ⇒ ANE/CPU serialized, parallel no help. "overlap realized %" = how far `T_concurrent` moved from `T_serial` toward `max(A,B)` (100% = fully overlapped).

### Clips

| clip | duration | chunks (ceil dur/15s) |
|---|---|---|
| `1215B531` | 29.8 s | 2 |
| `8CA31EBB` | 30.1 s | 3 |
| `2CE6EB87` | 292.1 s (~5 min) | 20 |
| `AF37A7D7` | 345.6 s (~5.8 min) | 24 |

### Results — medians

**`.cpuAndNeuralEngine` (the real app config):**

| clip | A (TDT) | B (CTC) | max(A,B) | T_serial | T_concurrent | saved | overlap realized |
|---|---|---|---|---|---|---|---|
| `1215B531` 29.8 s | 136 ms | 507 ms | 507 ms | **644 ms** | **537 ms** | 107 ms (17%) | 78% |
| `8CA31EBB` 30.1 s | 152 ms | 540 ms | 540 ms | **695 ms** | **551 ms** | 144 ms (21%) | 93% |
| `2CE6EB87` 292 s | 852 ms | 4190 ms | 4190 ms | **4997 ms** | **4256 ms** | 741 ms (15%) | 92% |
| `AF37A7D7` 346 s | 1015 ms | 4881 ms | 4881 ms | **5844 ms** | **4944 ms** | 900 ms (15%) | 93% |

**`.cpuOnly` (no ANE — isolates whether contention is ANE-specific):**

| clip | A (TDT) | B (CTC) | max(A,B) | T_serial | T_concurrent | saved | overlap realized |
|---|---|---|---|---|---|---|---|
| `1215B531` 29.8 s | 144 ms | 628 ms | 628 ms | **774 ms** | **660 ms** | 114 ms (15%) | 78% |
| `8CA31EBB` 30.1 s | 163 ms | 679 ms | 679 ms | **861 ms** | **666 ms** | 195 ms (23%) | 100% |
| `2CE6EB87` 292 s | 1249 ms | 4965 ms | 4965 ms | **6240 ms** | **5162 ms** | 1079 ms (17%) | 85% |
| `AF37A7D7` 346 s | 1494 ms | 6353 ms | 6353 ms | **8167 ms** | **6506 ms** | 1661 ms (20%) | 92% |

(Two independent full runs; numbers above are representative and were stable run-to-run — overlap-realized consistently 78–100%, savings 15–23%.)

### Verdict — what the numbers say

1. **Concurrency DOES reduce post-stop wall-clock — and the ANE does NOT serialize the two graphs.** This **refutes the §4 hypothesis** that "concurrent `MLModel.prediction` calls are serialized by the ANE scheduler so parallel collapses back to serial." Empirically `T_concurrent` lands at **78–100% of the way to `max(A,B)`** — i.e. the smaller TDT pass (A) is almost entirely hidden behind the CTC pass (B). If the ANE serialized, `T_concurrent` would have stayed at `T_serial` (overlap ≈ 0%); it didn't, on a tight, repeatable margin.

2. **But the §4/§R3 "low payoff" CONCLUSION still holds — for the OTHER reason it gave.** Because **B ≫ A** (CTC is 3.5–5× the TDT pass), overlapping can only ever hide A. So the realized saving is **15–23% off the rescore-inclusive wait**, ≈ `min(A,B)`: ~110–195 ms on a 30 s clip, ~0.7–1.7 s on a 5 min clip. Parallel is a real, free, *bounded* win — not the lever that removes the reported 3–4 s lag.

3. **The overlap is NOT ANE-specific.** cpuOnly shows the **same** 78–100% overlap / 15–23% savings pattern as cpuAndNeuralEngine. So whatever overlap exists comes from genuine concurrent execution (ANE command-queue pipelining and/or CPU-side mel/pre-post work running while the other pass is on the coprocessor), and it is present on both backends. There is **no ANE-specific serialization penalty** visible here that cpuOnly avoids — both backends parallelize about equally well, ANE is just faster in absolute terms on long clips.

### Caveats (must read)

- **Mac ANE ≠ iPhone ANE.** This ran on this Mac's Neural Engine. The iPhone ANE is a different, smaller coprocessor with its own scheduler and memory bandwidth; concurrent-graph behavior **may differ on device** — it is *plausible* the iPhone ANE serializes more than the Mac does (smaller queue / less headroom for two live graphs), which would erode the measured 78–100% overlap toward 0%. **Do not promise the on-device saving from these numbers.** To settle it on-device, instrument the proposed `async let` path behind a debug flag and read the realized overlap on the owner's iPhone (the §6 signpost work).
- **This is the inference only.** It does not include the cheap merge C (~14–20 ms, CPU, must run after both regardless) nor any cold model (re)load, run-loop, or paste hop — those are unaffected by parallelizing A‖B and remain the larger suspects for the full 3–4 s (§5 R1/R2).
- **Bounded by B≫A by construction.** The win is `~min(A,B)`. It grows in absolute ms with clip length (because A grows), but as a *fraction* it stays ~15–23% because B grows alongside. It will never approach 50%.

### One-line answer
**Yes — parallelizing the CTC rescore with the TDT transcribe does help, but only by ~15–23% of the rescore-inclusive wait (≈ the smaller TDT pass: ~0.1 s on a 30 s clip, ~0.7–1.7 s on a 5 min clip). The Mac ANE does NOT serialize the two graphs (overlap realized 78–100%, same on cpuOnly), so the prior "ANE serializes → no help" claim is refuted; but the "low payoff" verdict stands because the CTC pass dwarfs the TDT pass. iPhone ANE behavior may differ — verify on device before relying on it.**

### Files
- Harness: `/tmp/jot-vadbatch/Sources/ParallelTest/main.swift` (this empirical test). Run: `swift build -c release --product ParallelTest && ./.build/release/ParallelTest --clips <a.wav>,<b.wav> --iters 7`.
