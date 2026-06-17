# Platform / CoreML / OS-Mechanism Research: Faster ANE Specialization & Avoiding Re-Specialization

Angle: Apple-platform levers to make the first-`MLModel(contentsOf:)` ANE device-specialization step faster, or avoid recomputing it after every app update. Researched 2026-06-12, iOS 26 current.

## Confirmed mechanism (the thing we're fighting)

What costs >60s on cold/post-update launch is **CoreML device specialization** (MIL → ANE program), which runs at `MLModel` instantiation, NOT the `.mlpackage`→`.mlmodelc` compile. coremltools docs are explicit: "During instantiation, another compilation occurs for backend device specialization, such as for the Neural Engine (NE), which may take a few seconds or even minutes for large models. This device specialization step creates the final compiled asset ready to be run. This final compiled model is cached so that the expensive device optimization process does not need to run again." (https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)

The specialized asset is **cached keyed on the full filesystem path of the `.mlmodelc` folder**, confirmed both by an Apple DTS engineer and by community testing: "A model cache is reasonably sticky as long as the absolute path of the model (.mlmodelc) stays the same." On app update iOS hands the app a **new Data-container UUID** → the `.mlmodelc` absolute path changes → cache miss → full respecialization. There is **no public API to query cache state** (Apple DTS confirmed, 2025). (https://developer.apple.com/forums/thread/786051, https://developer.apple.com/forums/thread/762866, https://developer.apple.com/forums/thread/771352)

This corroborates everything in our brief. The research below is about what we can actually DO.

---

# TOP 3 MOST PROMISING

## 1. Background re-specialization triggered ON app-update detection (BGContinuedProcessingTask / BGProcessingTask), warming the path-keyed cache before first record

**Mechanism.** The cache invalidates *only* on update (path change), not on normal cold launches. So the expensive event is predictable and rare. Detect "version/build changed since last launch" (compare a persisted build number), and on that first post-update launch kick off a background specialization pass: instantiate each `MLModel` from its final resting path on `.cpuAndNeuralEngine` once. That single instantiation writes the specialized asset into the aned cache keyed on that path; every subsequent load from the same path is the fast ~0.1s path. This is exactly the workaround an Apple DTS engineer recommended verbatim: "If it is an option, I would run the background pre-load only after the app update because it seems like a major reason of the cache invalidation." (https://developer.apple.com/forums/thread/786051)

Two delivery options for the background time:
- **iOS 26 `BGContinuedProcessingTask`** — designed for foreground-initiated work that must finish even if the user backgrounds; shows system progress UI; requires an explicit user action to start (so trigger it the moment the post-update app opens, e.g. tie to "Updating models…" splash). On iOS 26 it can also get **background GPU access** (must add the Background GPU capability in Xcode). (https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask, https://developer.apple.com/videos/play/wwdc2025/227/)
- **`BGProcessingTask`** — classic long-running background slot the OS schedules at an opportune time (often overnight on charger). Good as a *secondary* opportunistic warm so a user who updates overnight wakes to an already-warm cache. (https://developer.apple.com/documentation/backgroundtasks)

**Does it survive an app update?** This is the point — it RUNS *because of* the update and rewrites the cache for the new path. It does NOT survive a *future* update; it must re-run each update. That's acceptable because it moves the cost off the user's first record.

**Critical caveat / what to verify (SPECULATION, flag explicitly):** the brief asks "does the BG-warmed cache survive into foreground?" The path-keyed disk cache (`/var/mobile/Library/Caches/com.apple.aned/...`) is process-independent on-disk state, so in principle a specialization written in a background task is on disk and a later foreground load from the same path should hit it. I could NOT find a source that *explicitly* confirms a background-task-written aned cache is honored by a later foreground load — treat as "Likely" and validate on-device (instrument the second load; see #6). Known risk: CoreML work in the background runs at lower QoS and is reported ~4–5× slower than foreground, and the specialization itself may be throttled or the helper (`aned`) deprioritized — so the warm may take much longer in BG than the 60s you see in FG. Budget for that; `BGContinuedProcessingTask` (user-visible, foreground-adjacent) mitigates the QoS hit better than plain `BGProcessingTask`. (background CoreML 4–5× slower: https://developer.apple.com/videos/play/wwdc2025/227/)

**Effort.** Medium. Build-number-change detection (trivial), wiring a BG task entitlement + handler, and a warm routine that loads each model once. We already have an eager warm-load fallback, so the warm routine largely exists; the new part is gating it to update-events + moving it to a BG task.

**Feasibility-for-us.** HIGH. This is the single most-endorsed, lowest-architectural-risk lever and directly targets "recurs every update." It turns "60s on first record after every update" into "60s of invisible background work right after the update."

**Confidence.** Confirmed that update is the invalidation trigger and that post-update pre-load is Apple's recommended workaround. Likely that BG-written cache is honored in FG (verify). Confirmed BG CoreML is slower.

Sources: https://developer.apple.com/forums/thread/786051 · https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask · https://developer.apple.com/videos/play/wwdc2025/227/ · https://developer.apple.com/forums/thread/762866

## 2. `MLOptimizationHints.specializationStrategy` — pick the strategy that minimizes *specialization* time, and separate first-load from steady-state

**Mechanism.** iOS 18+ exposes `MLModelConfiguration.optimizationHints.specializationStrategy` (coremltools `SpecializationStrategy`). Documented values: `.default` and `.fastPrediction`. coremltools warns that `FastPrediction` "will prefer the prediction latency at the potential cost of **specialization time**, memory footprint, and the disk space usage." (https://apple.github.io/coremltools/docs-guides/source/model-prediction.html, https://developer.apple.com/documentation/coreml/mlmodelconfiguration)

The non-obvious lever for US: we have been implicitly accepting whatever specialization the loader does. Because `.fastPrediction` *increases* specialization time, the `.default` strategy is the one that minimizes the slow step we care about. If FluidAudio (or our config) is requesting `.fastPrediction` we are paying extra first-load time for steady-state latency we may not need on a phone doing short dictations. Worth measuring `.default` vs `.fastPrediction` first-load time on a 12 Pro-class device. This is a config flag, not a rebuild.

**Does it survive an app update?** N/A — it changes *how long* each specialization takes, not whether it recurs. Combine with #1.

**Effort.** Low. Set `config.optimizationHints.specializationStrategy = .default` (or test both) where we build the `MLModelConfiguration` before handing to FluidAudio. Verify FluidAudio lets us pass a configuration (it does — it takes `MLModelConfiguration`).

**Feasibility-for-us.** MEDIUM-HIGH as a cheap multiplier. Won't eliminate the 60s but may shave a meaningful fraction, and it's a one-line experiment. Quantified numbers per-device not published by Apple; measure ourselves.

**Confidence.** Confirmed the API and its time/latency tradeoff direction. Magnitude for Parakeet on iPhone = Unknown until measured.

Sources: https://apple.github.io/coremltools/docs-guides/source/model-prediction.html · https://developer.apple.com/documentation/coreml/mlmodelconfiguration

## 3. "Usable instantly on a cheaper compute unit, swap to ANE in background" bridge

**Mechanism.** The catastrophic specialization cost is specifically the ANE (`ANEF` / `MILCompilerForANE`) path. Forum evidence repeatedly shows `.cpuAndNeuralEngine` / `.all` is what triggers the multi-minute ANE compile, and the standard *workaround people apply to dodge it entirely* is `config.computeUnits = .cpuAndGPU`. (https://developer.apple.com/forums/thread/770530, https://developer.apple.com/forums/thread/709211) GPU/CPU specialization is a different, generally lighter compile. The idea: on a cold/post-update launch, load a `.cpuAndGPU` (or `.cpuOnly`) instance so the user can dictate *now* at reduced speed/quality, while a second `.cpuAndNeuralEngine` instance specializes in the background; hot-swap to the ANE instance once ready (and warm its cache via #1).

**Does it survive an app update?** The ANE instance still respecializes per update; this just hides it behind a working CPU/GPU path instead of a spinner. The CPU/GPU specialization may also be cached per-path and far cheaper to redo.

**Effort.** HIGH. Requires running/holding two model instances, a swap protocol mid-session, and validating CPU/GPU output parity + acceptable RTF on a 12 Pro. Memory pressure is a real concern given our 6GB hard wall and 600M model — two instances may not fit; more realistic for the bundled 110M than the 0.6B.

**Feasibility-for-us.** MEDIUM (LOW for 0.6B due to RAM). Strong UX win if it fits, because it converts "dead 60s" into "slightly slower but live." Quantified CPU-vs-ANE load-time delta for our models is not published — must measure. Note the brief's question "does CPU/GPU specialize faster" = Likely yes (that's why `.cpuAndGPU` is the community escape hatch from the ANE hang), but unquantified.

**Confidence.** Confirmed `.cpuAndGPU` avoids the ANE compile hang. Quantified speedup = Unknown. Memory fit for dual-instance = Possible-to-unlikely for 0.6B.

Sources: https://developer.apple.com/forums/thread/770530 · https://developer.apple.com/forums/thread/709211

---

# OTHER LEVERS (evaluated, lower priority)

## 4. Fixed Application-Support path + symlink to defeat path-keying

**Mechanism.** Cache keys on the absolute `.mlmodelc` path. The brief already rejected copy-to-fixed-Application-Support because the *Data container UUID* changes on update. Confirmed by an unanswered-but-correct forum post: there is NO location consistent across updates — `/var/mobile/Containers/Data/Application/<UUID>/Library/Application Support/` changes UUID every update, so even a relative-stable path is absolute-unstable. (https://developer.apple.com/forums/thread/771352, https://developer.apple.com/forums/thread/786051) A symlink at a hypothetical stable absolute path doesn't help: the app has no writable stable-absolute mount point, and the aned cache appears to resolve the real path anyway.

**Does it survive an app update?** No. Refuted.

**Effort.** Low. **Feasibility-for-us.** LOW — confirms the rejection; don't pursue. **Confidence.** Confirmed negative.

Sources: https://developer.apple.com/forums/thread/771352 · https://developer.apple.com/forums/thread/786051

## 5. Background Assets framework (iOS 26 Managed / essential asset packs)

**Mechanism.** Background Assets downloads + manages assets *before first launch and on overnight app updates*, via an app extension, outside the app lifecycle. iOS 26 adds Managed asset packs (Apple-hosted, system-managed download/update/compression). (https://developer.apple.com/documentation/BackgroundAssets/downloading-essential-assets-in-the-background, https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs) The relevant angle for US is NOT the download (our 110M is bundled, 0.6B is our own download) — it's that the BA **extension runs around update/install time**, which is *exactly* when we need to re-specialize. If a BA extension can host CoreML model instantiation, it could warm the cache at update time without needing the user to even open the app.

**Does it survive an app update?** It runs *at* each update — same model as #1, different scheduler. **SPECULATION (flag):** I found no confirmation that (a) a BA extension is permitted to instantiate CoreML/ANE, or (b) a specialization performed in the *extension's* process is written to a cache the *main app* later reuses. Extensions have separate but related sandboxing; the aned cache is system-level so it *might* be shared, but this is unverified and risky. Also BA is oriented to downloading bytes, not running compute.

**Effort.** HIGH (new extension, entitlements). **Feasibility-for-us.** LOW-MEDIUM, mostly because of the two unknowns above; #1 achieves the same outcome with far less risk. **Confidence.** Mechanism/timing Confirmed; CoreML-in-BA-extension + cross-process cache reuse = Unknown.

Sources: https://developer.apple.com/documentation/BackgroundAssets/downloading-essential-assets-in-the-background · https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs

## 6. `MLComputePlan` — does it precompute/seed the specialization? (NO — it's profiling)

**Mechanism.** `MLComputePlan.load(contentsOf:configuration:)` (iOS 17.4+) surfaces per-op compute-device assignment + estimated cost. It is a **profiling/debugging** API, not a warming API — building a compute plan does NOT produce or seed the runnable specialized ANE asset. Its real value to us is **diagnostic**: use it (and the Core ML instrument in Instruments.app, which shows a "cached" label on the load event) to *verify* our #1/#3 cache hits actually land, and to confirm ops are landing on ANE not falling back. (https://developer.apple.com/videos/play/wwdc2024/10161/, https://developer.apple.com/forums/thread/762866, https://github.com/freedomtan/coreml_modelc_profling)

**Does it survive an app update?** N/A (not a cache). **Effort.** Low (instrumentation). **Feasibility-for-us.** Use as the **verification tool** for the other ideas, not a speedup itself. **Confidence.** Confirmed it's profiling-only.

Sources: https://developer.apple.com/videos/play/wwdc2024/10161/ · https://developer.apple.com/forums/thread/786051 · https://github.com/freedomtan/coreml_modelc_profling

## 7. `MLModelAsset` / async `MLModel.load(asset:)` + `prewarm`

**Mechanism.** `MLModelAsset` (from compiled URL or in-memory) feeds the async `MLModel.load(...)` API. This is about **ergonomics and not blocking the main thread / loading from memory**, not about reducing specialization cost — the same device-specialization still happens on first load. We already load async via FluidAudio. There is no documented `prewarm()` that pre-computes ANE specialization cheaper; "prewarm" in the wild (e.g. WhisperKit `prewarmModels()`) is just "instantiate the models early," i.e. the same first-load cost paid eagerly — which is precisely our existing fallback. (https://github.com/argmaxinc/WhisperKit/issues/171, https://developer.apple.com/videos/play/wwdc2024/10161/)

**Does it survive an app update?** N/A. **Effort.** Low. **Feasibility-for-us.** LOW as a speedup (we already do eager async warm); MLModelAsset's in-memory load is mild plumbing nicety. **Confidence.** Confirmed it's not a specialization shortcut.

Sources: https://developer.apple.com/videos/play/wwdc2024/10161/ · https://github.com/argmaxinc/WhisperKit/issues/171

## 8. iOS 26 / WWDC25 platform changes to ANE compile-caching

**Mechanism.** WWDC25 says "Updates to Core ML will help run advanced generative ML/AI models on device faster and more efficiently," and there's a new faster speech model — but I found **no specific WWDC25/iOS 26 change to the ANE specialization-cache path-keying** behavior. The structural problem (path-keyed cache, no query API, UUID churn on update) is unchanged as of the latest forum discussions in 2025. Note also: AppleInsider reports a **"Core AI" framework expected at WWDC 2026 to succeed Core ML** — worth watching but not actionable now. (https://developer.apple.com/videos/play/wwdc2025/360/, https://developer.apple.com/forums/thread/791086, https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml)

**Does it survive an app update?** N/A. **Effort.** N/A. **Feasibility-for-us.** Informational. **Confidence.** Confirmed no relevant iOS 26 caching fix found; file a Feedback Assistant enhancement request for a "warm cache to path" / "query cache" API (Apple DTS explicitly invites these).

Sources: https://developer.apple.com/videos/play/wwdc2025/360/ · https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml

## 9. Avoid corrupted-cache cliff (defensive, not a speedup)

**Mechanism.** Multiple reports of `.mpsgraphpackage` / `coremldata.bin` corruption causing *persistent* >120s loads or hard load failures across launches (WhisperKit saw ~20% load-failure on some configs). Since there's no API to clear a corrupt cache, our #1 warm routine should wrap loads in failure handling and, on repeated failure, fall back to `.cpuAndGPU` (#3) so a corrupt ANE cache never bricks dictation. (https://developer.apple.com/forums/thread/786051, https://github.com/argmaxinc/WhisperKit/issues/171)

**Effort.** Low. **Feasibility-for-us.** MEDIUM — cheap resilience to bolt onto #1/#3. **Confidence.** Confirmed the failure mode exists.

Sources: https://developer.apple.com/forums/thread/786051 · https://github.com/argmaxinc/WhisperKit/issues/171

---

# Recommended combination

1. **#1 update-gated background warm** (BGContinuedProcessingTask primary + BGProcessingTask opportunistic) — the headline fix; moves the per-update 60s off the first record.
2. **#2 specializationStrategy = .default** — one-line experiment to shrink the specialization itself.
3. **#3 cpuAndGPU bridge** for the bundled 110M (and as the corrupt-cache fallback #9) so dictation is live during any (re)specialization; gate dual-instance carefully under the 6GB wall.
4. **#6 MLComputePlan + Instruments "cached" label** to *verify* the warm actually lands across an update on-device — this is the make-or-break unknown.

Biggest open risk to validate first: whether a **background-task-written** specialization is honored by a later **foreground** load (and how slow BG specialization is under throttling). Test that before building the full BG flow.
