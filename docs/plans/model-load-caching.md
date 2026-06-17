# Model-load caching — why the first load after an app update is slow, and what (if anything) we can do

Status: **BRAINSTORM** (research + options, no code). Uncertainty is flagged inline; do not treat any "survives update?" cell as proven until measured on-device.

Author note on confidence: the *mechanism* (sections "Problem" / "Why it recurs") is well-supported by Apple docs + a direct Apple-engineer forum answer (cited). The *fixes* (Options) are partly speculative — in particular whether any of them actually preserve the ANE specialization cache across an update is **unverified** and is exactly what the "What to measure" section exists to settle. Be skeptical: the most-cited "fix" (precompile to a fixed path) may NOT help us, because our slow step is not `.mlpackage→.mlmodelc` compilation — we already ship `.mlmodelc` — and the path that matters still changes on update. See Open Questions.

---

## DIRECT ANSWER — "does non-use alone cause the 45 s cold load, or only update/install?"

**Non-use alone does NOT cause it. Bare time-since-last-open is not a trigger for anything on iOS** — there is no documented time-based, periodic, LRU, or "stale after N days" eviction of either `Library/Caches` in general or the `com.apple.aned` ANE specialization cache in particular. The single documented trigger that *deletes* the ANE cache on the same install is **device storage pressure** (Apple DTS, verbatim: iOS deletes `Library/Caches` "on **rare occasions when the system is very low on disk space**," and only while the app is not running — thread/107071, **Confirmed**). The owner's stated premise ("plenty of free storage") therefore rules out the only same-install eviction path: with ample free space and no update, **day-4 is warm.**

So a real-world "cold after a couple of days of not using it" is almost never *caused by* the non-use. It is one of these, in descending real-world likelihood:

1. **"Offload Unused Apps" was ON and fired** (most likely if the symptom correlates with non-use). This is the one mechanism where non-use is a *factor* — but it is still **storage-gated, not a pure timer**: Apple's own words are "**When you're low on storage**, you can have iPhone automatically remove unused apps while keeping your data" (Apple Support, **Confirmed**). It targets apps you "haven't used recently / opened less frequently" *as the selection criterion*, but only acts when the device is under storage pressure. When it fires it **removes the app binary and re-downloads it on next tap** = effectively a **reinstall → new bundle UUID → new absolute path → guaranteed cold ANE respecialization (full 45 s)**. Documents/data are kept (and the icon shows a cloud badge), so the user perceives "same app, suddenly slow again." This perfectly reproduces "cold after a couple of days." It is ON by default for many users (App Store settings). **This is the prime suspect for a non-use-correlated cold.**
2. **The device hit low storage between sessions** (independent of offload) → iOS purged `Library/Caches/com.apple.aned` while Jot wasn't running → cold respecialize. Storage pressure, not time. Contradicts the owner's "plenty of free storage," so lower likelihood *for this owner* but the general cause.
3. **An app update landed in between** (auto-update over those days) → new bundle path → cold. Easy to mistake for "I just didn't use it." Check the build number.
4. **A reboot happened** — see below: a reboot does NOT clear the on-disk aned cache, so a reboot alone is **not** a cause (only a fresh-process few-seconds cost, not 45 s). Listed only to rule it out.

If the owner reports cold-after-non-use **with genuinely plenty of free storage and no update**, the overwhelmingly likely answer is **#1 (Offload Unused Apps)** — check Settings → Apps → App Store → "Offload Unused Apps," and whether the Home Screen icon ever showed a cloud badge. If that's off too, suspect a silent auto-update (#3) or that "plenty of storage now" doesn't mean "plenty of storage at the moment iOS ran its purge a few days ago" (#2).

---

## Decision table — COLD (full ~45 s ANE respecialization) vs WARM, per trigger

"WARM" here means no full respecialization. It splits into: **warm-in-process** (~1–2 s, model already resident) and **cold-but-cached** = first load of a fresh process with the aned cache still present (a few seconds for file read + graph wire-up, NOT 45 s). Only **COLD** = the full 45 s respecialization.

| Trigger | Result | Why | Confidence / Source |
|---|---|---|---|
| **Fresh install** | **COLD (45 s)** | No aned cache entry exists yet for this bundle path. | Confirmed — coremltools Model Prediction guide; Apple eng. thread/786051 |
| **App update** (manual or auto) | **COLD (45 s)** | Bundle container UUID changes every update → `.mlmodelc` absolute path changes → path-keyed cache misses → respecialize. | Confirmed — Apple eng. thread/786051 ("on app update the system often gives a new app sandbox directory"); TN2285 |
| **Offload Unused Apps fires, then reopen** | **COLD (45 s)** | Binary removed + re-downloaded = effective reinstall → new bundle UUID → new path → cache miss. Storage-gated, non-use-selected. | Confirmed (reinstall=cold) + Confirmed (storage-gated) — Apple Support "Manage storage"; reinstall mechanism = thread/786051. *Likely* the non-use-correlated culprit. |
| **Low-storage purge of `Library/Caches`** (app not running) | **COLD (45 s)** | iOS deletes `com.apple.aned` contents under storage pressure; next load respecializes from scratch even with same bundle path. | Confirmed — Apple DTS thread/107071 ("very low on disk space," "won't delete while app is running"); thread/652499 |
| **Time-only / pure non-use** (ample free storage, no update, no offload) | **WARM** | No documented time-based / periodic / LRU / TTL eviction of `Library/Caches` or `com.apple.aned`. Bare non-use is not a trigger. | Confirmed-negative — Apple DTS thread/107071 states storage as the *only* trigger; no Apple doc, forum, or coremltools issue documents a time/non-use TTL. (Honest: absence-of-evidence, but the authoritative DTS statement is exhaustive about "the only" trigger.) |
| **Device reboot / power cycle** | **WARM** (cold-but-cached: a few s, not 45 s) | Reboot kills all processes but does **not** wipe `/var/mobile/Library/Caches`; the on-disk aned specialization cache is durable across reboots. First post-reboot load is fresh-process file-read cost only. | Likely — no Apple/forum/coremltools source documents reboot clearing `Library/Caches` or `com.apple.aned`; Caches is on durable storage and only the documented low-disk purge removes it. Not directly proven; measure to confirm. |
| **App killed from RAM (jetsam) / swipe-close, same install** | **WARM** (cold-but-cached: a few s) | Process death only loses the in-RAM resident model; the on-disk aned cache survives, so the next launch reads + wires the graph (seconds) without respecializing. The 45 s only returns when the *specialization cache itself* is gone. | Confirmed — coremltools Model Prediction guide (cache persists on disk, keyed to path); whisper-rs #67 (compiled cache reused across processes within an install) |

**One-line takeaways:**
- The 45 s recurs **only** when the on-disk ANE specialization cache is gone or its path key changed: **install, update, offload-reopen, or a low-storage purge.**
- **Reboot and jetsam do not bring it back** (they cost a few seconds of fresh-process load, not 45 s).
- **Pure non-use with free storage does not bring it back.** If the owner sees it after a few days, the realistic cause ranking is: **Offload Unused Apps (1) → low-storage purge that happened mid-window (2) → silent auto-update (3).** Reboot/jetsam are red herrings.

---

## TL;DR — direct answer to "is a routine day-4 launch cold?"

**Mostly no — but it can be, and the reason is not under our control.** Within a single install (no update), once the model has specialized once, iOS caches the ANE program and later loads are fast (~1–2 s warm in-process; first-of-process "cold-but-cached" loads still cost seconds for the file read + graph wire-up, not the full 45 s respecialization). So a day-4 launch *should* be fast, and usually is.

**The one thing that makes day-4 cold again on the SAME install: iOS purging the ANE specialization cache.** That cache lives in a system **Caches** directory — `/var/mobile/Library/Caches/com.apple.aned/...` (confirmed by coremltools #2247's error log path) — and Apple DTS confirms iOS deletes `Library/Caches` contents **on rare occasions when the device is very low on disk space, while the app is not running, and the app cannot prevent it** (Apple Developer Forums thread/107071, thread/652499). So:

- **First-install:** cold (expected). ✅
- **Post-update:** cold every time — the bundle path changes, so the path-keyed cache always misses (proven mechanism below). ✅ expected, and the main thing to "hide."
- **Routine day-4, same install, plenty of free disk:** **warm/fast.** ✅ The owner's expectation holds.
- **Routine day-4, same install, BUT the device got low on storage between sessions:** **cold again** — iOS evicted `com.apple.aned`. ❌ This is the surprising recurrence, and it is **caused by device storage pressure, not by Jot**. We can't pin the cache (no API, no stable writable path that the ANE compiler keys on), but we *can* make it cheap to re-pay invisibly (eager launch warm + honest UX).

There is also a softer recurrence: a process restart (swipe-close, jetsam, reboot) always pays a "first-load-of-process" cost. Even with the ANE cache *present*, that first load reads ~hundreds of MB of `.mlmodelc` and wires the graph — seconds, not the 45 s respecialization. The 45 s only returns when the *specialization* cache itself is gone (post-update, or aned eviction). The owner's "cold 45 s should NOT recur on day-4" is correct **unless** storage pressure evicted the aned cache.

**Bottom line:** there is no safe way to *guarantee* day-4 is never cold (the eviction is the OS's call and there's no public pin/query API). The realistic engineering is: (1) confirm the common day-4 path is genuinely warm via measurement; (2) make every cold load — first-install, post-update, AND post-eviction — pay itself off at launch in the background behind honest progress, so the user rarely eats it on the record-tap. See Recommendation.

---

## Problem

On the owner's latest iPhone, the **first** model load after a fresh install **or any app update** takes >60s (worse on older devices). After that first load, subsequent loads in the same install are fast (hundreds of ms). Every app update re-triggers the slow first load.

Models in play (all CoreML `.mlmodelc`, run on the ANE):

- **Parakeet TDT-CTC 110M** — bundled in the IPA, default batch dictation.
- **Parakeet TDT 0.6B v2 (600M)** — opt-in, downloaded to Application Support.
- **EOU streaming 120M (320ms)** — bundled in the IPA, drives live partials.
- **EmbeddingGemma** — Ask/RAG (bundled CoreML).

How Jot loads them today (confirmed in repo):

- Batch: `TranscriptionService.modelDirectory()` returns `Bundle.main.bundleURL/Models/Parakeet/parakeet-tdt-ctc-110m` for the bundled 110M variant, else FluidAudio's Application Support dir for the 600M download. → `AsrModels.load(from:)`. `TranscriptionService.swift:962-970`, `:866`.
- Streaming: `StreamingTranscriptionService.bundledStreamingDirectory()` returns `Bundle.main.bundleURL/Models/Parakeet/parakeet-eou-streaming/320ms` → `StreamingEouAsrManager.loadModels(from:)`. `StreamingTranscriptionService.swift:392-397`, `:305`.

**Key fact about FluidAudio's loader:** it loads pre-compiled `.mlmodelc` directly via `MLModel(contentsOf:configuration:)` / `MLModel.load(contentsOf:)` — it **never calls `MLModel.compileModel(at:)` at runtime**. So the `.mlpackage → .mlmodelc` compile (the "usually very fast" step) is already done at build time and is **not** our bottleneck.
- `DownloadUtils.swift:265` — `let model = try MLModel(contentsOf: modelPath, configuration: config)` (modelPath is the `.mlmodelc`).
- `StreamingEouAsrManager.swift:255-262` — `MLModel.load(contentsOf: directory.appendingPathComponent("streaming_encoder.mlmodelc"), ...)` (× encoder/decoder/joint).
- Compute units default to `.cpuAndNeuralEngine`: `MLModelConfigurationUtils.swift:11-18`, `AsrModels.swift:450-461`.

So the >60s is spent **inside `MLModel(contentsOf:)` on first use** — i.e. CoreML's **device-specialization / ANE compilation** step (MIL → ANE program via the ANE compiler), not file-format compilation.

---

## Why it recurs (mechanism)

There are **two** CoreML compile stages (Apple coremltools "Model Prediction" guide, https://apple.github.io/coremltools/docs-guides/source/model-prediction.html):

1. **`.mlpackage` → `.mlmodelc`** — file-format compile. "Usually very fast." We do this at *build* time (Xcode compiles the bundled models), so it costs us ~0 at runtime.
2. **`.mlmodelc` → backend device program (ANE specialization)** — happens *during instantiation* (`MLModel(contentsOf:)`). Apple: "another compilation occurs for backend device specialization, such as for the Neural Engine (NE), which **may take a few seconds or even minutes for large models**." This is our >60s.

The specialization result is cached so it doesn't re-run — **but the cache entry is keyed on the full filesystem path of the `.mlmodelc` folder.** Apple coremltools, same page (verbatim): *"This final compiled model is cached so that the expensive device optimization process does not need to run again. The cache entry is linked to the full file system path of the `mlmodelc` folder."*

Internally this is the `e5rt` / `MLE5ProgramLibrary` / `ANECompilerService` path. Evidence:
- The Espresso/ANE compile entry point is `MLE5ProgramLibraryOnDeviceAOTCompilationImpl createProgramLibraryHandleWithRespecialization:` → `eort_eo_compiler_compile_from_ir_program` (Apple Developer Forums thread/821073).
- The on-disk specialization cache lives under the system aned cache, e.g. observed paths like `/var/mobile/Library/Caches/com.apple.aned/tmp/<bundle-id>/<hash>/<hash>/` (coremltools issue #2247 error log). The hash is derived from model identity **and** path.
- Academic confirmation that ANE programs are cached by composite keys and that a cache miss costs a real `ANECCompile()` (Orion paper, arxiv 2603.06728v1, "Program cache. Compiled programs are cached with composite keys…").

**Why an app update busts it:** on iOS the **app bundle container directory is replaced and its UUID changes on every update/reinstall.** `Bundle.main.bundleURL` is `/var/containers/Bundle/Application/<UUID>/Jot.app/...` and that `<UUID>` is new after an update (Apple TN2285: "the `.app` bundle is completely replaced… the absolute path to the app's container… and thus all files inside it, will change"; File System Programming Guide; SO 25884382). Because we load the bundled models from `Bundle.main.bundleURL`, the `.mlmodelc` **absolute path changes every update → cache key miss → full ANE respecialization.**

**The decisive citation** (Apple engineer, Developer Forums thread/786051, "Is there an API to check if a Core ML compiled model is already cached?", May 2025):
> "A model cache is reasonably sticky as long as the absolute path of the model (`.mlmodelc`) stays same. However, **on app update, the system often gives a new app sandbox directory, which changes the path to the model.** … I would run the background pre-load only after the app update because it seems like a major reason of the cache invalidation."
> Also: **there is no public API to query whether a given `.mlmodelc` is already specialization-cached** (as of iOS 18).

### The nasty caveat that undermines the "obvious" fix

Both the **bundle** container UUID *and* the **data** container UUID change on update (TN2285; SO 25884382 shows `Data/Application/<UUID>` differs build-to-build). `FileManager.url(for: .applicationSupportDirectory)` always resolves to the *current* container, so **files survive** the update — but the **absolute path string still changes** (new `<UUID>`). Since the specialization cache is keyed on the absolute path, **moving the `.mlmodelc` into Application Support does NOT obviously preserve the cache across updates** — the file persists, but its path (and thus the cache key) is new, so CoreML still respecializes. This is the central open question (see Open Questions Q1). The owner's belief that "Application Support persists across updates" is true for *files*; it is **not established** that it preserves the *ANE specialization cache key*.

(There is a same-process "decrypt session" leak failure mode if you keep loading without releasing MLModel — thread/740731 — not our problem, but note it if we add a precompile-then-reload step.)

### Why a routine day-4 launch (same install, no update) can STILL go cold

This is the owner's specific worry, and it has a concrete, evidence-backed cause distinct from the update mechanism above.

The ANE specialization cache lives under **`/var/mobile/Library/Caches/com.apple.aned/...`** — a system *Caches* directory (path shape confirmed by the `ANECCompile(/var/mobile/Library/Caches/com.apple.aned/tmp/<bundle>/<hash>/<hash>/...)` error in coremltools issue #2247). Anything under `Library/Caches` is **purgeable by iOS**:

> Apple DTS (Developer Forums thread/107071): *"If you put stuff in the Caches directory the system is free to delete it when necessary (although it won't delete it while your app is running)."* And: the system deletes Caches *"on rare occasions when the system is very low on disk space."*

So the day-4 cold path is: **between the owner's day-1 and day-4 sessions, the device gets low on storage → iOS purges `Library/Caches` (including `com.apple.aned`) while Jot is not running → day-4's first load is a full ANE respecialization (45 s) even though no update happened and the model `.mlmodelc` is still present.** This is **caused by device-level storage pressure, not by Jot**, and:

- **There is no public API to pin** a `Library/Caches` subtree against purging, and the aned cache is written by the OS's ANE compiler, not by us — so even `isExcludedFromBackup`-style attributes (which only affect backup, not purging) wouldn't apply, and we don't own that directory anyway.
- **There is no public API to query** whether the aned cache is currently populated (Apple engineer, thread/786051) — so Jot can't even *detect* "the cache was evicted" to warn the user proactively.
- **Two sub-cases of "cold on the same install":**
  1. **aned cache evicted (storage pressure):** the real 45 s respecialization. Surprising; rare; OS-driven.
  2. **first load of a fresh process (cache still present):** swipe-close / jetsam / reboot → CoreML reads the `.mlmodelc` and wires the graph but does NOT respecialize. This is seconds, not 45 s. Jot's `ModelLoadTimekeeper` already treats "first load of this process lifetime" as cold (`didLoadThisLaunch`, `:29/:43`) and over-paces it; that's fine but it conflates these two very different costs.

**What this means for the owner's expectation:** "day-4 should be fast" is correct in the common case (enough free disk). The cold 45 s recurring on day-4 is a *symptom of the device being low on storage between sessions* — investigate the device's free space if it's observed. The only thing Jot can do about it is make the re-pay invisible (eager launch warm) and honest (progress UX), not prevent it.

---

## Options

Effort: S = <½ day, M = 1–3 days, L = >3 days / SDK-version-sensitive.
"Survives update?" = does it avoid the >60s ANE respecialization on the first launch *after* an app update? **All Y/?? cells are UNVERIFIED hypotheses to be measured.**

| # | Option | Mechanism | Effort | Survives update? | Risk |
|---|--------|-----------|--------|------------------|------|
| 1 | **Eager warm-load right after update, with honest progress UX** (recommended smallest) | Detect "first launch on new build version" (CFBundleVersion change in UserDefaults/AppGroup) and kick the existing load path immediately in background + show the calibrated bar. Doesn't *eliminate* the compile, *moves* it off the record-tap critical path. | S | **No** (still recompiles) but hides it | Low. Pure UX + scheduling. Interacts with `ModelLoadTimekeeper` cold estimate. |
| 2 | **Copy bundled `.mlmodelc` to a fixed Application Support path once, load from there every launch** | The widely-cited Stable-Diffusion / Felix-Krause pattern: keep the `.mlmodelc` at a stable app-owned path so the cache key is stable. | M | **?? (probably NOT across updates)** | Data-container UUID changes on update → absolute path changes anyway (see caveat). Likely preserves cache across *process launches within one install* (which we already get for free from the bundle), but **not across updates**. ~440 MB×copy disk + iCloud-backup concerns. Measure before believing. |
| 3 | **`BGProcessingTask` to respecialize right after an update, before first record** | Register a background-processing task; on first post-update launch schedule it; it runs the load (= ANE compile) while charging/idle so the user never waits. | M | **No** (compile still happens) but invisible | BG task scheduling is best-effort; iOS may defer for hours. Battery/thermal. Doesn't help if user records before BG runs (fall back to Option 1). |
| 4 | **Warm-load eagerly at app launch (not deferred to record-tap)** — current partial behavior; make it unconditional on first post-update launch | Start `prepare()`/`beginSession warmUp` during splash/home so compile overlaps with the user reading the UI. | S | **No** but hides | Already partly done. Memory pressure if all models load at once (keyboard 60MB ceiling — do NOT do this in the extension). |
| 5 | **`MLModelConfiguration` tuning: `.cpuAndNeuralEngine` vs `.cpuAndGPU`/`.cpuOnly`** | ANE specialization is the slow part; CPU/GPU may compile faster (CLIP-on-ANE anecdote: 97s ANE vs instant CPU — coremltools #1814). Could load on CPU first for fast availability, swap to ANE in background. | M | **No** (per-unit caches, all path-keyed) | Big accuracy/RTF/perf hit if we stay on CPU/GPU. ANE is why Jot is fast at inference. Only viable as a *temporary* "usable now, upgrade silently" bridge. Two loads = more memory. |
| 6 | **Pin/preserve the path: symlink or stable container path** | Try to give CoreML a path that doesn't change across updates (e.g. App Group container? a symlink from a stable name?). | M–L | **?? unknown** | App Group container path **also** UUID-based and changes; symlinks inside bundle are wiped on update. No known stable absolute path on iOS. Probably a dead end — but App Group container persistence-vs-path needs the same measurement as Q1. |
| 7 | **Ship pre-specialized ANE artifact / `compileModel` at build** | Pre-run device specialization and bundle the result. | L | **No** | Not exposed: ANE specialization is device+OS-specific and produced at runtime; there's no supported "ship the ANE program" path. `compileModel(at:)` only does stage-1 (`.mlpackage→.mlmodelc`), which we already do. Dead end for our bottleneck. |
| 8 | **Reduce what must compile: smaller/fewer models, lazy per-surface** | Only specialize the model actually needed (e.g. don't warm 600M and EmbeddingGemma if the user only dictates). | S–M | partial | Doesn't fix recurrence, just shrinks first-load surface. Sensible hygiene regardless. |

Notes:
- Options 1, 3, 4 are **"hide it" not "kill it"** — they accept the recompile and move it off the user's critical path. Given the mechanism + the Apple engineer's own recommendation ("run the background pre-load only after the app update"), this class is the realistic win.
- Options 2, 6, 7 are **"kill it"** attempts that the evidence suggests probably **don't** survive an update on iOS, because there is no stable absolute path and the cache is path-keyed. Worth a single measurement (Q1) before investing.

---

## Recommendation

**Smallest-effort, highest-impact: Option 1 + Option 4 combined.**
On launch, read the stored `CFBundleVersion` from the App Group; if it differs from the running build (or is absent → fresh install), treat this as a *post-update cold load*: immediately and unconditionally kick the existing `prepare()` / `warmUp()` + `beginSession` load in the background and surface the existing **`ModelLoadTimekeeper` calibrated bar** prominently (this is the "first run is slow, here's progress" moment it was built for). Then write the new `CFBundleVersion`. This costs ~½ day, no new entitlements, and matches the Apple engineer's explicit advice. It does **not** reduce the 60s of compute — it guarantees the user sees honest progress and that the compile starts at launch rather than at first record-tap.

**Fuller option: add Option 3 (`BGProcessingTask`) on top.** After a post-update launch, also schedule a background-processing task so that if the user *backgrounds* the app before recording, iOS can run the specialization while idle/charging, and the next foreground record-tap is warm. Falls back to Option 1's foreground bar if BG never ran. ~1–3 days incl. entitlement + scheduling + testing that the BG-warmed cache is actually reused in the foreground (Q1/Q2).

**Do NOT** start by building Option 2/6/7 — the evidence says they likely won't survive an update, and they're the expensive ones. Gate any investment behind the Q1 measurement.

### Interaction with `ModelLoadTimekeeper`
`ModelLoadTimekeeper.swift` already models exactly this world: it keeps **separate cold and warm** estimates per variant (`coldKey`/`warmKey`, `:31-32`), picks cold on the first load of a *process lifetime* via the in-memory `didLoadThisLaunch` flag (`:29`, `:43-49`), and EMA-smooths warm. Its doc comment (`:17-21`) already states the cold case is "first load after launch / reinstall / iOS evicting the ANE cache." Two adjustments any fix should make:
1. **Add an explicit "post-update" signal.** Today cold-vs-warm is purely per-process; it can't tell a normal cold launch (cache present, fast-ish) from a post-update cold launch (cache busted, very slow). A `CFBundleVersion`-changed flag would let the timekeeper pick a *much larger* cold estimate only when the cache was actually invalidated, instead of over-pacing every cold launch. Right now `estimatedSeconds` guesses `warm × 6` or a flat 12s default (`:46`) — fine as a fallback, but a post-update bucket would be more honest.
2. Whatever scheme moves the load to launch/BG must still call `ModelLoadTimekeeper.record(...)` so the per-device estimate stays calibrated.

---

## UX follow-up — rotate the cold-load line during a single long load (capture, do not build)

During a genuine 45 s cold load the affordance currently shows **one static line** for the whole duration, which feels frozen. The owner wants it to feel alive — e.g. **rotate the displayed line every ~10 s** through several lines across a *single* long load.

Current behavior (confirmed in `ColdStartCopy.swift`):
- `recurringLines` is already a 3-entry array (`:43-47`), and `beginningLine()` (`:72-79`) advances a persisted rotation index — but it advances **once per load** (so consecutive *separate* cold loads show different lines), **not** within one long load. The string is written once into `AppGroup.streamingLoadingVariantLabel` at load start and the keyboard strip + recording hero render it verbatim; nothing re-reads it on a timer.
- `firstEverLine` (the "This is the slow part" koan) is wizard-W5-only (gated on `AppGroup.wizardActive`) and must stay single, non-rotating — you only see it once. **Do not rotate the koan.**

Sketch of the follow-up (NOT to build now):
- Drive a ~10 s timer (in the hero / keyboard strip view, or a shared ticker) that, while a load has been running past `revealThreshold` (2.5 s) and is still not `.ready`, advances through `recurringLines` and updates the rendered string. Cross-process surfaces (keyboard) would need the rotation to be either time-derived from a shared start timestamp in the App Group, or each surface ticks its own timer off the same array — keep it deterministic so app + keyboard don't show different lines mid-load.
- Respect reduce-motion / keep it a text swap, not animation, to stay within the keyboard's constraints.
- Net: same total wait, but the line changing every ~10 s signals "still working" instead of "stuck." Pure presentation; no effect on load time or the caching mechanism above.

---

## What to measure (on-device, not simulator — ANE compile is hardware-real)

1. **Q1 — the decisive experiment.** Load a bundled model, log the wall-clock of `MLModel(contentsOf:)`. Then (a) relaunch (same install) → expect fast (warm). (b) Install a new build (bump `CFBundleVersion`, keep models bundled at the same *relative* bundle path) → time first load. (c) Repeat (b) but loading from a copy in Application Support (Option 2). **Compare:** does Application Support's first-post-update load beat the bundle's? If both are equally slow, Option 2 is dead and we commit to "hide it" (Options 1/3/4). Capture `URL.path` each time to *prove* the absolute path changed across the update (it should).
2. **Q2 — does BG-warmed cache survive into foreground?** Run the load in a `BGProcessingTask`, then foreground and time the record-tap load. Must be warm (~hundreds of ms) for Option 3 to be worth it. Watch for the system evicting the cache between BG and foreground.
3. **Per-model breakdown.** Time each `.mlmodelc` (encoder/decoder/joint for EOU; preprocessor/encoder/decoder/joint for batch) separately — the existing per-component load loop makes this easy. Find which one dominates the 60s (likely the encoder).
4. **Compute-unit cost (Option 5 viability).** Time the same model at `.cpuAndNeuralEngine` vs `.cpuOnly` vs `.cpuAndGPU` first-load. If CPU first-load is seconds vs ANE's minute, a "CPU-now, ANE-later" bridge becomes attractive.
5. **Inspect the aned cache.** On a jailbroken/dev device or via Instruments, watch `/var/mobile/Library/Caches/com.apple.aned/...` populate on first load and confirm whether the entry's hash path changes after an update (coremltools #2247 shows the path shape).
6. **Cold vs post-update vs warm spread** across at least 2 device generations (owner's latest + one older) to set `ModelLoadTimekeeper` cold/post-update estimates honestly.

Use the existing `os_signpost` intervals already in `TranscriptionService` (`parakeet-load`, `parakeet-prepare`, `:759`, `:860`) in Instruments — they bracket exactly the right window.

---

## Open questions

- **Q1 (blocking everything in the "kill it" column):** Does keeping the `.mlmodelc` at a fixed Application Support path actually preserve the ANE specialization cache across an app **update**? Evidence says **probably not** (the absolute path still changes because the data-container UUID changes on update), but this is the single fact that decides whether Option 2 is worth anything. **Measure before building.**
- Is the specialization cache keyed on *absolute path*, or on path *relative to* the container, or on a content hash? Apple's wording is "full file system path," which argues absolute — but Apple has changed CoreML cache behavior across OS versions, so confirm on current iOS.
- Does iOS ever **migrate/relocate** the aned cache entry when it migrates the data container on update? (If it did, Option 2 would work — but the forum answer implies it doesn't.)
- ~~Can a routine day-4 launch (same install, no update) go cold?~~ **RESOLVED (above):** yes, but only when iOS purges `Library/Caches/com.apple.aned` under device-wide storage pressure between sessions — confirmed-purgeable, no pin/query API. Caused by device storage, not Jot. Remaining sub-question to *measure*: on the owner's device with normal free space, is the typical day-4 first-of-process load genuinely warm (seconds) and not 45 s? (Expected yes; Q1/Q3 instrumentation answers it.)
- ~~Is there TIME-BASED / non-use eviction of the cache independent of storage?~~ **RESOLVED (see Direct Answer + Decision Table above):** **No.** No documented time/periodic/LRU/TTL eviction of `Library/Caches` or `com.apple.aned`; Apple DTS names storage pressure as the only trigger (thread/107071). **Reboot does NOT clear the aned cache** (durable storage; only the low-disk purge removes it) — so reboot is a few-seconds fresh-process cost, not 45 s. **Offload Unused Apps** *is* the one non-use-*correlated* path, but it is **storage-gated** ("when you're low on storage…", Apple Support), and when it fires it acts as a **reinstall → new bundle path → guaranteed COLD**. So a non-use-correlated cold is really "offload fired" or "a purge/update happened mid-window," not bare time. One **on-device caveat to watch**: App Group / data-container persistence is NOT guaranteed across offload+iCloud-restore (forum thread/95343) — relevant only if a launch-warm scheme stores its `CFBundleVersion` flag in the App Group, which could be wiped by an offload cycle and falsely read as "fresh install."
- For the **600M opt-in** (already in Application Support): does it *already* respecialize every update? If so it's the same bug, and Option 2 gives it nothing — confirms the caveat.
- **EmbeddingGemma** — is it ANE or CPU/GPU? If CPU, its first-load cost has a different (likely smaller) profile and may not need this at all. Not yet inspected here.
- Keyboard extension: its loading strip is still indeterminate (per MEMORY). It has a 60MB ceiling and must not eagerly warm heavy models — any launch-warm scheme must be **main-app only**. The keyboard bounces inference via deep link, so it shouldn't be specializing these models at all; confirm.
- Does `allowLowPrecisionAccumulationOnGPU = true` (`MLModelConfigurationUtils.swift:15`) affect specialization time? Probably GPU-only; irrelevant on ANE — but cheap to A/B.
- iOS 26.4 has a known `.mlpackage` load *hang* regression in AOT respecialization (thread/821073). We ship `.mlmodelc` so we likely dodge it, but any precompile-at-runtime option (we have none today) would walk into it. Keep `.mlmodelc`-only.

---

## Sources

- Apple coremltools, "Model Prediction" (two-stage compile; "cache entry is linked to the full file system path of the `mlmodelc` folder"): https://apple.github.io/coremltools/docs-guides/source/model-prediction.html
- Apple Developer Forums, "Is there an API to check if a Core ML compiled model is already cached?" (Apple-engineer answer: path-keyed, update changes sandbox dir, no query API, pre-load after update): https://developer.apple.com/forums/thread/786051
- Apple Developer Docs, `compileModel(at:)` (stage-1 only) + "Downloading and Compiling a Model on the User's Device" (Application Support permanent-location pattern; backup caveats): https://developer.apple.com/documentation/coreml/mlmodel/compilemodel(at:)-6442s , https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device
- Apple TN2285 "Testing iOS App Updates" + File System Programming Guide (bundle replaced + container path changes on update; bundle is read-only/signed): https://developer.apple.com/library/archive/technotes/tn2285/_index.html
- Apple Developer Forums, "CoreML MLE5ProgramLibrary AOT recompilation" (e5rt/MLE5ProgramLibrary respecialization path; cache invalidated by OS update): https://developer.apple.com/forums/thread/821073
- coremltools issue #2247 (E5RT / ANECCompile, aned cache path shape — `/var/mobile/Library/Caches/com.apple.aned/tmp/<bundle>/<hash>/<hash>/`): https://github.com/apple/coremltools/issues/2247
- Apple Developer Forums thread/107071 (DTS: `Library/Caches` is purged under low disk space, never while app is running, app cannot prevent it; use `Application Support` for files you must keep): https://developer.apple.com/forums/thread/107071
- Apple Developer Forums thread/652499 ("How to avoid system purging URLCache on low disk space" — same purge semantics): https://developer.apple.com/forums/thread/652499
- coremltools issue #1814 (ANE first-load minutes vs CPU instant): https://github.com/apple/coremltools/issues/1814
- Orion paper (ANE compile-then-dispatch, composite-key program cache): https://arxiv.org/html/2603.06728v1
- Felix Krause, "Safely distribute ML models OTA" (compile-then-move-to-permanent pattern): https://krausefx.com/blog/safely-distribute-new-machine-learning-models-to-millions-of-iphones-over-the-air
- whisper-rs #67 (compiled `.mlmodelc` cache reused across processes within an install): https://github.com/tazz4843/whisper-rs/issues/67
- Apple Support, "Manage storage on iPhone" — **Offload Unused Apps is storage-gated**: "When you're low on storage, you can have iPhone automatically remove unused apps while keeping your data… the app icon stays on your Home Screen with a cloud symbol — tap it to reinstall": https://support.apple.com/guide/iphone/manage-storage-on-iphone-iph47c931112/ios
- Apple Developer Forums thread/757691 ("Library/Caches for app groups: automatically deleted when needed?" — same low-storage purge semantics apply to app-group Caches): https://developer.apple.com/forums/thread/757691
- Apple Developer Forums thread/95343 ("AppGroup data of offloaded apps lost after restoring from iCloud backup" — App Group container is NOT guaranteed to survive offload + iCloud restore): https://developer.apple.com/forums/thread/95343
- Apple Community thread/254887240 ("Offload Unused App function" — confirms offload removes binary, keeps data, redownloads on tap): https://discussions.apple.com/thread/254887240

### Repo references
- `Jot/App/Transcription/ModelLoadTimekeeper.swift` (cold/warm calibrated bar; doc comment :17-21; `estimatedSeconds` :38-51; `record` :56-66)
- `Jot/App/Transcription/TranscriptionService.swift` (`modelDirectory()` :962-970; bundled 110M dir :983-988; `AsrModels.load(from:)` :866; signposts :759/:860)
- `Jot/App/Transcription/StreamingTranscriptionService.swift` (`bundledStreamingDirectory()` :392-397; `loadModels(from:)` call :305)
- FluidAudio checkout: `…/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/`
  - `DownloadUtils.swift:265` — `MLModel(contentsOf:configuration:)` (loads `.mlmodelc`, no `compileModel`)
  - `ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift:255-262` — `MLModel.load(contentsOf: …mlmodelc)`
  - `Shared/MLModelConfigurationUtils.swift:11-18` — default `computeUnits = .cpuAndNeuralEngine`, `allowLowPrecisionAccumulationOnGPU = true`; `:25-35` Application Support dir
  - `ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:228-345` `load(...)`, `:450-461` default config — never calls `compileModel`
