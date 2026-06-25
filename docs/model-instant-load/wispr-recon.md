# Wispr Flow recon: how is it "instant after an app update"?

**Task:** Reverse-engineer how Wispr Flow avoids the ~16s post-update ANE cold-load
that Jot's bundled FluidAudio Parakeet TDT 0.6B v2 (CoreML, ANE) pays.

**Bottom line (high confidence):** Wispr Flow is **cloud-only**. It does **not** run an
on-device ASR model on iPhone. There is therefore **no ANE specialization to pay** — not
on first install, not after an update, never. The "instant after update" behavior the
owner observes is not a clever cold-load trick; it's the absence of an on-device model.
The transcription latency the owner perceives is a server round-trip (their stated budget:
ASR <200ms + LLM <200ms + network <200ms ≈ 700ms total).

This means **Wispr Flow is the wrong oracle for Jot's specific problem.** Jot is on-device
and private (per memory: "only outbound is the user-initiated feedback POST"). Wispr makes
the opposite architectural choice. We can't copy what they do without abandoning on-device.

---

## 1. What ASR model does Wispr Flow run on-device?

**None on iPhone.** Confirmed cloud-only across many independent sources, including Wispr's
own documentation:

- Wispr Flow Help Center (troubleshooting "No Model Available"): *"Flow requires an internet
  connection for transcription."* No mention anywhere of a local/on-device model, model
  download, or offline mode.
  <https://docs.wisprflow.ai/articles/3155947051-troubleshooting-guide-for-no-model-available-error>
- Wispr "Data Controls" / multiple reviews: transcription **always** occurs in the cloud,
  **even with Privacy Mode on** (Privacy Mode is zero-retention, not on-device).
- When the iOS keyboard loses network it shows an orange triangle and transcription **fails** —
  i.e. there is no on-device fallback model to degrade to.
- Their own engineering post frames the system as *"cloud based speech processing
  infrastructure for 1B users,"* with a *"maximum networking budget of 200ms from anywhere
  around the world with spotty internet connections"* and targets *"E2E ASR inference <200ms,
  E2E LLM inference <200ms."* A networking budget only exists if inference is server-side.
  <https://wisprflow.ai/post/technical-challenges>

What model they run *on the server* is undisclosed and not relevant to Jot — server GPUs
don't ANE-specialize, so their server model's size doesn't inform our cold-load problem.
They describe building *context-conditioned ASR* (conditioned on speaker, surrounding
context, history) — bespoke server models, not an off-the-shelf on-device package.

**Confirmed.** (Multiple independent sources + first-party docs all agree.)

## 2. What runtime/engine?

Server-side, proprietary GPU inference (undisclosed framework). **Not** CoreML/ANE on the
phone, **not** whisper.cpp/GGML on the phone, **not** MLX on the phone. The iOS app is
effectively a thin capture + networking client with a custom keyboard.

**Confirmed** it is server-side; **Unknown** which server framework (and it doesn't matter
for Jot).

## 3. How do they handle the post-update cold start?

They don't have one to handle. No on-device model → no `.mlmodelc` compile → no
ANECompilerService specialization → nothing invalidated by an app-build change. The app
launches instantly because all it has to do on launch is open a mic and a socket.

**Confirmed.**

## 4. What can Jot concretely adopt?

The honest finding: **Wispr's mechanism (cloud ASR) is not adoptable without giving up Jot's
on-device/private guarantee**, which is a core product value (memory:
`project_only_outbound_is_feedback`). So the real question is the *other* half of the brief:
**is the answer "use a smaller on-device model so ANE specialization is sub-second?"**

### Important nuance found during research (re-test our 16s assumption)

The FluidInference Parakeet TDT 0.6B **v3** CoreML package (same family as Jot's v2, same
0.6B size) is published with a **4-bit palettized encoder + fp16 decoder/joint**, ~450 MB
on disk, and its README claims **"~0.2s cold start"** once the `.mlmodelc` cache exists, ANE
at ~402x realtime ("best power/latency balance on iOS").
<https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
<https://github.com/mweinbach/parakeet-coreml-swift>

Two things that may matter for Jot's 16s:
- **Quantization/palettization shrinks the artifact the ANE must specialize.** Jot's v2
  cold load is 16s; a 4-bit-palettized encoder is a materially smaller graph to specialize.
  If Jot's current bundle is fp16/fp32, moving to the palettized v3 encoder could cut the
  one-time specialization substantially. This is the **single most promising lever** because
  it keeps the same model family/accuracy and the same FluidAudio pipeline.
- The "~0.2s cold start" figure is the *cached* path (subsequent runs), **not** the
  post-update first run. The README explicitly does **not** disclose first-run ANE
  specialization time or whether app-update invalidates the cache — so do not take 0.2s as a
  post-update number. (Matches our prior finding: cache is keyed on path + build; updates
  invalidate it. This is a known CoreML pain point — whisper.cpp issue #2126, and reports of
  multi-minute uncached ANE loads for larger encoders.)

### Ranked options for Jot

1. **Switch the bundled artifact to the 4-bit-palettized Parakeet v3 encoder (or
   re-export v2 with palettization).** Same family, same FluidAudio path, near-zero accuracy
   risk, smaller graph → faster one-time ANE specialization. *Effort: low-med. Likelihood of
   meaningfully cutting the 16s: medium-high.* **This is the one concrete change to try
   first.** Must be measured on-device post-update, not in sim (per memory, sim can't model
   ANE specialization).

2. **Split the encoder into smaller sub-encoders** (the documented whisper.cpp workaround
   for exactly this — "divide the encoder into smaller encoders"). Reduces per-graph
   specialization cost. *Effort: high (re-export/surgery on the CoreML graph). Likelihood:
   medium.* Real but invasive.

3. **Background/deferred prewarm UX, not a real fix.** Kick off the model load immediately
   on launch behind a determinate-feeling progress UI (Jot already has `ModelLoadTimekeeper`
   + calibrated bar, memory `project_model_load_progress`). Doesn't remove the 16s, hides it.
   *Effort: low. Likelihood of removing the tax: zero — it's cosmetic.* Already partly done.

4. **Genuinely smaller on-device model (sub-0.6B):** e.g. Parakeet "Realtime 120M"
   (~150 MB) class, Moonshine, Whisper-tiny/base. A ~120-150M encoder specializes far faster
   than 600M, plausibly sub-2s and imperceptible. *Effort: high (new model integration +
   accuracy regression testing + ITN/vocab pipeline re-validation — note memory: Jot's ITN
   NumberNormalizer and vocab-rescore are load-bearing and tied to the current model).
   Likelihood of fixing cold-load: high; risk to accuracy: real.* This is the literal
   "smaller model = sub-second specialize" answer, but it's the biggest change and trades
   away accuracy that 0.6B v2 was specifically chosen for.

5. **Move ASR off the ANE to GPU/Metal or MLX** (no ANECompilerService step). RULED OUT by
   the team already (ANE is most power-efficient for transcription). Worth noting MLX avoids
   the ANE-compile entirely, but FluidInference themselves abandoned MLX-on-iOS for Parakeet
   *because* their goal was ANE, and MLX-Swift has Metal-shader packaging pitfalls. *Not
   recommended.*

6. **Copy Wispr = go cloud.** Removes the problem entirely but breaks Jot's on-device/private
   positioning. *Not recommended* unless the product strategy changes.

### Corroboration from comparable apps
- MacWhisper / Aiko / Superwhisper / OpenWhispr-class apps all run on-device Whisper or
  Parakeet via CoreML/whisper.cpp and **do** hit the same first-run ANE compile tax; the
  community workarounds are exactly (1)/(2)/(4) above plus "use GPU encoder to dodge ANE
  compile." None of them are "instant after update" the way Wispr is, precisely because they
  *are* on-device. This reinforces that Wispr's instant-ness comes from being cloud, not from
  a cold-load trick.
  - whisper.cpp issue #2126 (first-run compile, no caching across some setups):
    <https://github.com/ggml-org/whisper.cpp/issues/2126>
  - swift-parakeet-mlx (why they left MLX for CoreML/ANE):
    <https://github.com/FluidInference/swift-parakeet-mlx>

---

## Confidence summary
- **Wispr Flow is cloud-only, no on-device iPhone ASR model: Confirmed** (first-party docs +
  many independent reviews + their engineering post's networking budget).
- **Therefore it has no ANE cold-load to avoid: Confirmed** (logical consequence).
- **Best lever for Jot = palettized/4-bit v3 encoder to shrink the specialized graph:
  Likely** (mechanism is sound; the *magnitude* of the 16s reduction is unmeasured — needs an
  on-device post-update test).
- **Smaller sub-0.6B model would make specialization imperceptible: Likely**, but with a
  **real accuracy/pipeline-revalidation cost**.

## Sources
- https://docs.wisprflow.ai/articles/3155947051-troubleshooting-guide-for-no-model-available-error
- https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors
- https://wisprflow.ai/post/technical-challenges
- https://en.wikipedia.org/wiki/Wispr_Flow
- https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- https://github.com/mweinbach/parakeet-coreml-swift
- https://github.com/FluidInference/swift-parakeet-mlx
- https://github.com/ggml-org/whisper.cpp/issues/2126
- https://www.getvoibe.com/resources/wispr-flow-vs-superwhisper/
- https://voicescriber.com/wispr-flow-alternative-offline
