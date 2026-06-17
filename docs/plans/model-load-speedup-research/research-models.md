# On-Device ASR Model LOADING Speedup — Architecture / Quantization / Runtime Research

Research date: 2026-06-13. Author: research agent. Angle: model architecture, quantization, and alternative runtimes that REDUCE the ANE first-load (device specialization) cost — not just hide it.

## TL;DR of the problem (verified against sources)

CoreML model init has three phases (Apple, *Model Prediction* guide): (1) `.mlpackage`→`.mlmodelc` compile (fast), (2) instantiation under the chosen `computeUnits`, (3) **device specialization** — a second compile that lowers the MIL program to an ANE program. Phase 3 is the slow one: "a few seconds or even minutes for large models." The specialized result is cached on disk, **keyed on the absolute path of the `.mlmodelc` folder**. On app update iOS hands the app a new sandbox UUID, the path changes, the cache misses, and you eat the full specialization again. This matches our situation exactly, and Apple has no public API to inspect or pin that cache (Apple DevForums 786051, 709211).

**Two reframes that change the strategy:**

1. The slow part is almost entirely the **ENCODER**, and almost entirely **ANE specialization**. FluidAudio's own benchmark: encoder cold load = 3361 ms (iPhone 16 Pro Max) / 4396 ms (iPhone 13); decoder + joint + preprocessor together are <250 ms. Warm load is 162 ms. So "minutes" is the 0.6B encoder on *older / lower-RAM* devices (where it also pages against the 6 GB wall), not the 110M model.
2. ANE specialization is the entire cost. The **same model loaded with `.cpuAndGPU` skips phase 3 and loads 9–39× faster** (Apple DevForums 709211, measured). That is the lever almost nobody uses, and it's the basis of the top recommendation.

---

# TOP 3 RECOMMENDATIONS

## 1. Two-tier load: serve first audio on GPU (`.cpuAndGPU`, no specialization) while the ANE model specializes in the background, then swap

**Mechanism.** Load the *same* encoder twice with two `MLModelConfiguration`s. First instance uses `computeUnits = .cpuAndGPU`: this skips ANE device specialization entirely, so it's ready in hundreds of ms instead of seconds–minutes. Start transcribing immediately on GPU. Concurrently, on a background task, load a second instance with `.cpuAndNeuralEngine`/`.all`; when its specialization finishes (and is now cached on disk), atomically swap the live model over to the ANE instance for the rest of the session and all future launches (until the next app update busts the path cache).

**Cold-load impact.** First word available in ~0.2–0.5 s instead of 3–60+ s. This is the single biggest win and it directly attacks the perceived latency rather than hiding it.

**Inference-speed tradeoff vs ANE.** GPU/Metal is the realistic fallback and it's *fine* for a few seconds of audio. Reported figures: Parakeet 110M encoder ≈27 ms for 10 s of audio on Apple GPU (96× faster than CPU) — comfortably real-time on GPU alone. GPU's real cost is memory (MLX-style GPU path ≈2 GB working set vs ≈66 MB on ANE) and battery, which is exactly why you only want GPU for the bridge window, not steady state. For the 0.6B model on a 6 GB device the GPU bridge may be too memory-hungry — there, fall back to the 110M on GPU for the bridge even if the user opted into 0.6B.

**Effort.** Medium. Two configs + a background load + a swap point in the streaming loop. No model re-conversion. FluidAudio loads each component explicitly, so you can set per-component compute units. Watch out: don't hold both encoder instances resident longer than the swap (peak memory).

**Feasibility for us.** High. Pure runtime change, no new model artifacts, works on every device, degrades gracefully.

**Confidence.** High that `.cpuAndGPU` skips specialization and loads far faster (Apple-measured). Medium-high that GPU bridge inference is acceptable for our encoder sizes (Parakeet 110M GPU numbers are strong; 0.6B GPU on a 6 GB phone is the risk — needs an on-device probe).

**Sources.** https://developer.apple.com/forums/thread/709211 · https://apple.github.io/coremltools/docs-guides/source/model-prediction.html · https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/ · https://cactuscompute.com/compare/coreml-vs-mlx

## 2. Trigger ANE specialization eagerly + only on app-update, and pin the model to an app-update-stable path

**Mechanism.** Two parts.
(a) *When* to pay the cost: the cache only dies on app update (new sandbox UUID), not on every launch. So detect "first launch after update" (compare stored build number) and kick the ANE specialization in the background *then*, proactively, before the user records — instead of lazily on first dictation. On all other launches the cache hits and load is ~160 ms. This is exactly the workaround an Apple-leaning dev recommends in DevForums 786051 ("run the background pre-load only after the app update").
(b) *Where* to put the model: the specialization cache is keyed on `.mlmodelc` absolute path. The app *bundle* path changes every update; an Application Support subpath is more stable but the sandbox-root UUID still changes, so naive "copy to fixed path" is unreliable across updates (we already suspected this; DevForums 786051 confirms the sandbox UUID is the culprit, not the relative path). The realistic play is (a) — accept one specialization per update but move it off the critical path — rather than chasing a truly stable absolute path that iOS won't guarantee.

**Cold-load impact.** Eliminates the wait on 95%+ of launches (everything except the post-update one), and on the post-update launch moves it to background/idle time so the user rarely hits it mid-dictation.

**Inference-speed tradeoff vs ANE.** None — you stay on ANE.

**Effort.** Low–medium. Build-number diff + background prewarm task. We reportedly already have a progress-bar/timekeeper; this just changes *when* prewarm fires and adds the update-detection gate.

**Feasibility for us.** High. No model changes. Complements #1 (GPU bridge covers the post-update launch; eager prewarm makes sure it only ever happens once per update).

**Confidence.** High on the cache-per-update model and the background-after-update workaround (Apple DevForums + coremltools docs). Medium that we can't find a genuinely update-stable absolute path — Apple explicitly won't guarantee one.

**Sources.** https://developer.apple.com/forums/thread/786051 · https://apple.github.io/coremltools/docs-guides/source/model-prediction.html · https://developer.apple.com/videos/play/wwdc2023/10049/

## 3. Prefer the 110M as the always-loaded primary; treat 0.6B as a background-promoted upgrade — and re-examine whether int8 is helping or hurting LOAD time

**Mechanism.** Cold-load scales with encoder size and (counterintuitively) with quantization. The 110M encoder specializes in ~3–4.4 s cold; the 0.6B is the one that hits "minutes" on 6 GB devices. If 110M is acceptable for the first utterance, make it the resident default and promote to 0.6B only after a background specialization completes (a model-tier version of #1).

The sharp finding: **int8/8-bit weights can make CoreML LOAD *slower*, not faster.** A developer measured a BERT-large CoreML model going from ~500 ms (fp16) to ~2500 ms (int8) load — a 5× *regression* — because ANE/GPU/CPU compute is natively 16-bit and the 8-bit weights need extra load-time handling/decompression (DevForums 723771). Quantization shrinks *disk/RAM* and can speed *inference* on A17 Pro/M4 via the int8 path, but it is **not** a reliable lever for *specialization/load* time and may hurt it. FluidAudio already ships the Parakeet encoder int8 (652 MB vs 2.44 GB fp16) — great for the 6 GB RAM wall, but it means the int8 encoder is plausibly part of *why* cold load is long, not a fix for it. Worth an A/B: convert an fp16 encoder and measure cold specialization time vs the int8 build on a 6 GB device. If fp16 specializes meaningfully faster and the device has the RAM headroom (it won't on 6 GB), that's a load-time win for higher-RAM devices.

**Cold-load impact.** 110M-primary: first word in seconds even without #1. Re-examining int8: potentially large but *direction is uncertain* — could go either way per device/model.

**Inference tradeoff vs ANE.** 110M has higher WER than 0.6B; promotion path recovers accuracy. fp16 vs int8 affects RAM (decisive on 6 GB) more than inference quality.

**Effort.** 110M-primary: low (config/policy). int8-vs-fp16 A/B: medium (re-convert via coremltools, on-device timing).

**Feasibility for us.** 110M-primary: high, aligns with the existing 600M-only/6 GB-wall thinking. int8 re-examination: medium and exploratory.

**Confidence.** High that cold load scales with encoder size. **Confirmed** that int8 can *increase* load time (one strong measured datapoint; flag as device/model-dependent, verify on our model). Speculative that fp16 would help us given the RAM wall.

**Sources.** https://developer.apple.com/forums/thread/723771 · https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md · https://huggingface.co/aufklarer/Parakeet-TDT-v3-CoreML-INT8 · https://apple.github.io/coremltools/docs-guides/source/opt-quantization-overview.html

---

# FULL FINDINGS BY ANGLE

## A. Does quantization / palettization / int8 / 4-bit reduce ANE specialization TIME?

- **Mechanism.** coremltools `ct.optimize` (palettization 1–8 bit, int8 weight/activation, 4-bit) primarily targets *size, RAM, power, and inference latency* — never advertised as a *load/specialization* optimization.
- **Cold-load impact.** **Likely neutral-to-negative.** Measured 5× load regression fp16→int8 on BERT-large (DevForums 723771); hypothesized cause is native-16-bit compute needing load-time conversion of 8-bit weights. Apple's own docs frame compression benefits as runtime memory/latency, not load.
- **Inference tradeoff vs ANE.** *Positive* on A17 Pro/M4+ via the int8-int8 fast compute path (W8A8, or int8 weights + int8 LUT palettization). On older ANE (pre-A17) int8 mostly buys size/RAM, not speed.
- **Effort.** Low to apply (minutes per coremltools docs), medium to validate load impact on-device.
- **Feasibility for us.** Already int8 on the encoder for the RAM wall — keep it for memory reasons, but do NOT expect it to cut load time; measure whether it's costing us load time.
- **Confidence.** Confirmed it does not reliably reduce load; one strong datapoint shows it increases it. Possible our specific Parakeet encoder behaves differently — verify.
- **Sources.** https://developer.apple.com/forums/thread/723771 · https://apple.github.io/coremltools/docs-guides/source/opt-quantization-overview.html · https://developer.apple.com/videos/play/wwdc2023/10047/ · https://apple.github.io/coremltools/docs-guides/source/opt-joint-compression.html

## B. Fewer / fused vs split subgraphs; lazy-load the first-word subgraph

- **Mechanism.** Splitting a model into separate `.mlmodelc` files (encoder / decoder / joint) is standard and supported (coremltools #427; Stable Diffusion ships UNet/text-encoder/VAE as separate models). FluidAudio already does this — Parakeet is 4 separate components. Each specializes independently, so you can load the cheap ones first and the encoder last/in-background, and you only block on the subgraph the first word needs.
- **Cold-load impact.** Splitting doesn't reduce *total* specialization work, but it lets you (a) parallelize the small components, (b) defer the expensive encoder, and (c) combine with #1 (GPU encoder bridge) and #2 (background encoder specialization). The decoder/joint are already <100 ms each, so the win is mostly "don't let the encoder block startup," which the split enables.
- **Inference tradeoff vs ANE.** Slight per-call cross-model overhead vs one fused graph, negligible for ASR.
- **Effort.** Low — already split. The work is in the load *orchestration*, not the conversion.
- **Feasibility for us.** High; leverages existing structure.
- **Confidence.** High that components specialize independently; Likely that deferring the encoder helps perceived latency. No source claims splitting reduces *total* compile time — flag that.
- **Sources.** https://github.com/apple/coremltools/issues/427 · https://huggingface.co/blog/fast-diffusers-coreml · https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md

## C. Smaller / faster-cold-loading ASR models competitive for English dictation

- **Moonshine (Tiny ≈190 MB, Base ≈400 MB).** Encoder-decoder transformer with RoPE, *no zero-padding* (compute scales with actual audio length) — explicitly built for edge/low-latency. WER beats same-size Whisper; ~5× faster than Whisper on 10 s clips. Designed for live transcription. **Caveat: no first-class CoreML/ANE conversion found** (Keras/Torch/TF/JAX/ONNX). Would need conversion + its own specialization; load-time-on-ANE is unverified. v2 (2026) adds a streaming encoder. Good two-tier *bridge* candidate (small → loads fast) if converted, or run via ONNX/CPU for the first seconds.
  - https://arxiv.org/html/2410.15608v1 · https://arxiv.org/html/2509.02523v1 · https://arxiv.org/html/2602.12241v1 · https://github.com/moonshine-ai/moonshine
- **Parakeet TDT-CTC 110M (we bundle it).** Already the fastest-cold-loading ANE option we have (3–4.4 s encoder cold, <250 ms warm). Best "tier-1" model — see Top #3.
- **distil-whisper / whisper-tiny/base.** Whisper-tiny CoreML encoder loads in seconds and WhisperKit supports tiny/base for older iPhones, but WER is worse than Parakeet 110M for dictation and Whisper's 30 s-window batch shape is awkward for streaming.
- **Cold-load impact.** Smaller encoder ⇒ less specialization ⇒ faster cold load (monotonic in our data). Moonshine-tiny/whisper-tiny could be sub-second-ish *if* converted to ANE; unverified.
- **Inference tradeoff.** All smaller models = higher WER than 0.6B; acceptable only for the bridge window or low-end devices.
- **Effort.** High if introducing a new model (convert, validate WER, integrate). Low if we just lean harder on the 110M we already ship.
- **Feasibility for us.** Lean-on-110M = high. New tiny model = medium/low, only worth it as a bridge.
- **Confidence.** High on 110M; Possible on Moonshine/whisper-tiny ANE load (unverified conversion path) — speculative.
- **Sources.** https://whipscribe.com/tools/whisperkit · https://github.com/argmaxinc/whisperkit

## D. Alternative runtimes and their COLD-LOAD behavior vs CoreML-ANE

The first-run device-compile is **specific to CoreML+ANE**. Every non-CoreML runtime sidesteps it — but also gives up the ANE, which is *why we're fast and power-efficient*. Quantified tradeoff below.

- **MLX (Apple).** Metal/GPU only, **no ANE**, and **macOS/Apple-Silicon only — not shipped for iOS as a general ASR path** (Cactus comparison). No minutes-long device compile (Metal shaders JIT quickly), but for iPhone deployment it's effectively a non-starter and inference would be the GPU path (≈2 GB working set for the encoder). Inference comparison: FluidAudio CoreML 0.19 s vs parakeet-mlx 0.50 s vs mlx-whisper 1.02 s on the same task — CoreML/ANE ~2.6× faster than parakeet-mlx.
  - https://cactuscompute.com/compare/coreml-vs-mlx · https://mlx-framework.org/
- **whisper.cpp / ggml / GGUF.** CPU/Metal by default. Its *optional* CoreML encoder path hits the **exact same** ANE first-run compile ("first run is slow, ANE service compiles to a device-specific format"). Pure-Metal whisper.cpp avoids the compile but loses ANE (≈3× slower than ANE per their own notes) and is Whisper-only. No help for Parakeet.
  - https://github.com/ggml-org/whisper.cpp · https://github.com/ggml-org/whisper.cpp/pull/566
- **ONNX Runtime mobile (CoreML EP).** If `ModelFormat=MLProgram` + `MLComputeUnits=ALL`, it generates CoreML models under the hood and inherits the same ANE specialization + on-disk `.mlmodelc` cache (and a known tmp-cache-buildup bug, issue 26023). With CPU/GPU EP you skip the compile but lose ANE. No structural advantage over native CoreML for our case.
  - https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html · https://github.com/microsoft/onnxruntime/issues/26023
- **TF Lite / LiteRT, ExecuTorch.** ExecuTorch's CoreML backend recommends AOT-compiling to `COMPILED_MODEL`/`.mlmodelc` to cut first-load, but still routes ANE work through CoreML and thus the same specialization (ExecuTorch issue 5718 reports slow CoreML load for quantized models — echoes finding A). LiteRT on iOS uses GPU/CPU delegates, no ANE. Both trade away ANE.
  - https://docs.pytorch.org/executorch/0.7/backends-coreml.html · https://github.com/pytorch/executorch/issues/5718
- **Net:** No runtime gives ANE speed *and* avoids the first-run compile — they're the same thing. The compile is the price of ANE. Off-ANE runtimes are only useful as the *bridge* in the two-tier plan (#1), where GPU/CPU covers the first seconds. Moving steady-state inference off ANE would cost ~2.6× latency (MLX datapoint) plus a large battery/RAM hit (66 MB ANE vs ~2 GB GPU) — not worth it.

## E. Two-tier "tiny-now, big-later" strategy — precedents

- **Strongest precedent is the GPU/ANE split of the same model (#1)**, grounded in Apple's measured 9–39× faster `.cpuAndGPU` load.
- **WhisperKit `prewarmModels()`** is a documented precedent for *deliberately triggering specialization*: it sequentially loads then immediately unloads each model to force the device-specialized compile (and warm the cache) while keeping peak memory low — at a stated "2× load time" cost. That's exactly the background-specialization primitive for #2. (It can also throw on iOS — issue 171 — so test.)
  - https://github.com/argmaxinc/argmax-oss-swift/issues/171 · https://github.com/argmaxinc/whisperkit
- **Whisper-tiny → Whisper-large swap** is a common community pattern for low-latency-first transcription; our 110M→0.6B promotion (Top #3) is the same idea using models we already ship.
- **Cold-load impact / tradeoff / effort / feasibility / confidence:** covered under Top #1 and #3.

## F. "Stateful" / KV-cache loading, warm-resident model across launches

- **Mechanism.** iOS 18+ CoreML *stateful models* (KV-cache as model state) reduce per-step inference cost for autoregressive decoders; they do **not** address encoder *load/specialization*. Keeping the model resident across launches is impossible — iOS reclaims memory and there's no cross-launch process persistence; the only "warmth" that survives is the on-disk specialization cache (which dies on app update). The `specializationStrategy = FastPrediction` hint (iOS 18+) goes the *wrong way* for us: it trades *more* specialization/load time for lower inference latency. We want the **Default** strategy (lower load cost). Verify which FluidAudio sets.
- **Cold-load impact.** Stateful: none on load. FastPrediction: *worse* load — avoid.
- **Inference tradeoff.** Stateful: faster decode. FastPrediction: faster predict but slower load.
- **Effort / feasibility.** Low to check/override the strategy hint; stateful would need model-conversion work for marginal load benefit — skip for load goals.
- **Confidence.** High that FastPrediction increases load time (coremltools docs are explicit); High that no cross-launch warm-resident model exists on iOS.
- **Sources.** https://apple.github.io/coremltools/docs-guides/source/model-prediction.html · https://apple.github.io/coremltools/source/coremltools.models.html

---

# Speculation flags (do not treat as fact)
- Moonshine-tiny / whisper-tiny ANE cold-load being sub-second: **unverified** — no CoreML conversion benchmark found.
- fp16 encoder specializing faster than int8 *for our Parakeet model*: **one analogous datapoint (BERT)**, direction plausible but must be measured on our model/device; and fp16 likely breaks the 6 GB RAM wall anyway.
- 0.6B GPU bridge fitting in RAM on a 6 GB device: **risk** — probe before relying on it; fall back to 110M-on-GPU bridge.

# Suggested on-device experiments (cheap, high-information)
1. Load the encoder with `.cpuAndGPU` vs `.cpuAndNeuralEngine`; log cold vs warm load and first-word latency on an iPhone 12/13 (6 GB). Validates Top #1.
2. Build-number-gated background prewarm; confirm only the post-update launch pays specialization. Validates Top #2.
3. Convert an fp16 Parakeet encoder; time cold specialization vs the int8 build on the same device. Tests finding A / Top #3.
4. Inspect FluidAudio's `MLModelConfiguration` for `specializationStrategy`; ensure it's Default, not FastPrediction.
