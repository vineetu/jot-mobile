# Instant model load after app update — research

**Question:** First dictation after an App Store / TestFlight *update* takes ~60s
(reopen and reboot are instant). We tried copying the model to a stable
Application Support path so CoreML's compiled/ANE cache would survive the update.
It did NOT help. Why, and what actually fixes it?

**Bottom line up front:** The ~60s is **Apple Neural Engine (ANE) device
specialization**, not source compilation. It is triggered on the *first load of a
model that isn't in CoreML's on-device specialization cache*, and an app update
**invalidates that cache regardless of the file path**, because CoreML keys the
cache on **file metadata (path + modification time + size), not contents** — and
an update rewrites the bundle (and any copy made from it) with fresh metadata.
The stable-path idea was the right instinct but attacks the wrong key. **No app
fully avoids this recompile after an update** — the apps that "get it right"
(WhisperKit/Argmax, SuperWhisper, MacWhisper) *hide* it by running the
specialization as a background **prewarm at app launch** so it's off the
record-button critical path. Jot already calls `warmIfNeeded()` at launch, so the
single highest-value change is to **make that launch prewarm actually win the race
after an update** (and show honest "optimizing…" UI when it can't).

---

## 1. What the 60s actually is (mechanism, from first principles)

CoreML has a **two-stage** pipeline:

1. **Source compilation** — `.mlpackage`/`.mlmodel` → `.mlmodelc` (a compiled
   bundle). This is what `MLModel.compileModel(at:)` does.
2. **Device specialization** — `.mlmodelc` → device/compute-unit-specific assets
   (for ANE: a `.hwx`/E5 "macho" produced by **ANECompilerService**). This is the
   "uncached load (prepare and cache)" path in the Core ML Instrument.

Jot/FluidAudio **already ship precompiled `.mlmodelc`** and load them with
`MLModel(contentsOf:configuration:)` — no `compileModel` call anywhere
(`FluidAudio/DownloadUtils.swift:265`). So stage 1 is already done at build time.
**The 60s is entirely stage 2 (ANE specialization).**

Confirming signatures in the wild: the ANE failure/redo log is literally
*"ANE model load has failed for on-device compiled macho. Must re-compile the
E5 bundle"* (WhisperKit #268). "First run on a device is slow since the ANE
service compiles the Core ML model to a device-specific format; next runs are
faster" — Argmax/whisper.cpp docs.

WWDC23 "Improve Core ML integration with async prediction" (session 10049)
describes the two paths explicitly:
- **Cached load** ("cached") — loads specialized assets from disk cache. Fast.
- **Uncached load** ("prepare and cache") — parses model, segments ops across
  CPU/GPU/ANE, runs **per-compute-device compilation**, writes specialized assets
  to a **purgeable** disk cache. Slow. *"Caching ensures faster subsequent loads."*

**Why only the ANE encoder is slow:** FluidAudio loads the **encoder** with
`.cpuAndNeuralEngine` and the preprocessor with `.cpuOnly`
(`FluidAudio/.../AsrModels.swift:135–137`, `:452`,
`defaultConfiguration → .cpuAndNeuralEngine`). ANE specialization is the
expensive segment; CPU/GPU segments specialize quickly. This is consistent with
"only the first run is slow, and it's the audio encoder."

## 2. Why the cache dies on update but survives reopen/reboot

WWDC23 + Apple Developer Forums: CoreML's specialization cache is invalidated when:
- free disk space runs low (it's **purgeable**),
- an **OS update** occurs,
- **the compiled model is deleted or modified**.

The decisive detail (Apple forums, coremltools issues, ONNX Runtime CoreML EP
docs which mirror the same platform behavior): **CoreML compares file *metadata*
— path, modification time, size — NOT the file *contents* — to decide whether a
load matches a cached specialization.** And the cache key also includes
**`MLModelConfiguration` (compute units etc.)** and **device/OS build**.

Map that onto the three scenarios:

| Scenario | Bundle/file metadata | OS build | Result |
|---|---|---|---|
| **Reopen app** | unchanged | unchanged | cache hit → instant |
| **Reboot device** | unchanged | unchanged | cache hit → instant |
| **App update** | **bundle rewritten → new mtime/size/inode** | unchanged | **cache MISS → 60s respecialize** |
| OS update | (varies) | **changed** | cache miss → respecialize |

This is *exactly* why reopen and reboot are instant but update is not.

**Why the stable Application Support path failed:** moving the file doesn't fix
the metadata key. After an update you must re-populate Application Support from
the new bundle (the old copy is from the previous version), and that copy gets a
**fresh modification date** — so the metadata the cache was keyed on changes,
cache misses, respecialize. Even if you somehow preserved bytes *and* mtime, the
specialized assets themselves live in CoreML's own purgeable cache, which you
don't control and can't pin. The path was never the cache key in the way the
mental model assumed.

> Confidence: **Confirmed** that 60s = ANE specialization and that reopen/reboot
> hit cache while update misses. **Likely** (strong, multi-source but not a single
> Apple doc stating it verbatim for the bundle-update case) that the precise miss
> trigger is the metadata-comparison key changing on update. The behavioral
> evidence (reopen fast / update slow) is fully consistent with it.

## 3. What the apps that "get it right" actually do

**They do not avoid the respecialization. They move it off the critical path.**

- **WhisperKit / Argmax** — ships device-agnostic precompiled `.mlmodelc`
  ("models need to be *specialized* to a user's device chip before use; Core ML
  specializes automatically on first load"). Their fix is **`prewarmModels()`**:
  at a controlled time (app launch / onboarding) load each model sequentially and
  unload immediately, *just to trigger specialization*, so the real first
  transcription is fast. They explicitly accept "first run is slow."
- **whisper.cpp CoreML** — same story: "first run on a device may take a while
  since ANE compiles to a device-specific format; subsequent runs are fast." No
  magic bypass.
- **SuperWhisper / MacWhisper / Wispr Flow** — same platform constraint
  (precompiled mlmodelc + ANE). The polished UX is a **"preparing model…" /
  warming step shown once after install or update**, not an instantaneous first
  use. (Public docs don't claim instant first-use-after-update; they show a
  one-time prep.)

So the industry answer is: **(a) ship precompiled mlmodelc (Jot does), (b)
prewarm at launch to pay specialization in the background (Jot does, partially),
(c) show honest one-time "optimizing for your device" UI for the unavoidable
post-install/post-update case.**

## 4. The single concrete change Jot should try first

**Make the launch prewarm reliably win the race after an update, and prove it.**

Jot already prewarms: `JotApp` scene `.task` → `transcriptionService.warmIfNeeded()`
(`Jot/App/JotApp.swift:612`), plus an `init()` warm and a keyboard-strip
`warmUp()` (`:971`). `warmUp()` is idempotent/coalescing and the load is
fire-and-forget (`TranscriptionService.swift:210–243`). The plumbing is right.

If the first dictation *after update* still eats 60s, it means the user taps
record **before the background specialization finishes** — the warm started, but
the 60s ANE pass is still running, and the record path `await`s the same
in-flight prepare Task. The fix is **not** a new storage trick; it's:

1. **Confirm the warm fires on the update launch and measure how long the ANE
   pass takes there** (instrument — see §5). The existing
   `"Parakeet prepare ... elapsedMS"` logs already capture this
   (`TranscriptionService.swift:982`); `modelsOnDisk=true` + a ~60s `elapsedMS`
   on the post-update launch is the proof.
2. **Ensure the warm is not gated/delayed on update.** Check that
   `warmIfNeeded()`'s gate (`modelsExistOnDiskForSelectedVariant()` +
   state `.notLoaded/.failed`) is satisfied immediately on the update launch for
   the **bundled default** (it should be — bundled = always on disk). If the
   selected variant is the **opt-in 600M** whose files live in Application
   Support, verify the copy/availability survives the update so the gate doesn't
   silently skip warming.
3. **Give the unavoidable case honest UX:** if a record happens while
   `modelState == .loading` on a post-update launch, show a one-time
   "Optimizing speech for your device (one-time, ~1 min)…" state instead of an
   indeterminate spinner. This is what the polished competitors do.

A genuinely *new* lever worth a spike if (1)–(3) aren't enough:
- **Force the prewarm even earlier / more aggressively after an update**: detect
  "build version changed since last launch" (compare `CFBundleVersion` to a
  stored value) and on that first post-update launch, start the warm at the
  absolute earliest hook and surface a visible one-time prep affordance, so the
  ANE pass is already running (or done) by the time the user reaches record.
- **Do NOT** invest further in stable-path/copy-out caching — it cannot survive
  the metadata-key change and is a dead end per §2.

## 5. Exactly what on-device test confirms it

Run on a **real device** (ANE specialization does not happen on Simulator):

1. Install build N from TestFlight. Open app, let it warm, dictate once (warms
   cache). Force-quit.
2. **Reopen** → dictate. Expect instant. (Baseline: cache hit.) Capture the
   `Parakeet prepare end ... elapsedMS=` log — expect small.
3. Upload build N+1 (any trivial change). **Update** via TestFlight.
4. **Critical measurement — launch build N+1 and immediately watch Console.app**
   filtered to subsystem `com.vineetu.jot.mobile.Jot` category `transcription`:
   - Look for `Parakeet warmUp requested` / `Parakeet prepare begin` firing on
     launch (proves the background warm started without a record tap).
   - Then `Parakeet prepare end ... elapsedMS=` — if `elapsedMS ≈ 60000`, that is
     the ANE respecialization, confirmed as happening **in the background warm**,
     not at record time.
   - Cross-check the system log for `ANECompilerService` / "E5 bundle" /
     "prepare and cache" activity during that window (Core ML Instrument's
     "prepare and cache" interval is the authoritative signal).
5. **The decisive A/B:** after the update, (a) tap record *immediately* vs
   (b) wait for `modelState == .ready` then tap. If (b) is instant and (a) eats
   the remaining 60s, the diagnosis is proven: respecialization is unavoidable on
   update, and the only fix is winning/hiding the race (i.e., the launch prewarm +
   honest UI), not a storage change.

If instead the post-update launch shows **no** `prepare begin` until the record
tap, the warm is being skipped/gated on update — fix the gate (§4.2); that would
be the real bug and a much better outcome than 60s.

---

## Sources

External:
- WWDC23 — *Improve Core ML integration with async prediction* (session 10049):
  cached vs uncached load, device specialization, cache invalidation triggers
  (low disk, OS update, model modified). https://developer.apple.com/videos/play/wwdc2023/10049/
- WhisperKit #268 — "ANE model load has failed ... Must re-compile the E5 bundle"
  (ANE specialization signature). https://github.com/argmaxinc/WhisperKit/issues/268
- WhisperKit #171 — `prewarmModels()` purpose/usage. https://github.com/argmaxinc/WhisperKit/issues/171
- whisper.cpp #2126 — "first run on a device may take a while" (ANE
  device-specific compile, subsequent runs fast). https://github.com/ggml-org/whisper.cpp/issues/2126
- Apple Developer Forums (Core ML): purgeable specialization cache keyed on
  model path + configuration; metadata (not contents) comparison; uncached load
  after install. https://developer.apple.com/forums/tags/core-ml
- ONNX Runtime CoreML EP docs (mirrors platform caching semantics: cache under
  model hash, per compute-unit specialization). https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html

Code (this repo / pinned FluidAudio checkout):
- `Jot/App/Transcription/TranscriptionService.swift:210` `warmUp()` (idempotent,
  fire-and-forget) and `:235` `warmIfNeeded()` (the single warm gate);
  `:982` `Parakeet prepare end ... elapsedMS` instrumentation already present.
- `Jot/App/JotApp.swift:612` scene `.task → warmIfNeeded()`; `:971` keyboard-strip
  `warmUp()` — launch prewarm already wired.
- `FluidAudio/.../AsrModels.swift:135–137` encoder = `.cpuAndNeuralEngine`,
  preprocessor = `.cpuOnly`; `:452` default config `.cpuAndNeuralEngine`.
- `FluidAudio/DownloadUtils.swift:265` `MLModel(contentsOf:configuration:)` —
  loads precompiled `.mlmodelc` directly, **no** `compileModel` (so the 60s is
  specialization, not source compilation).
