# Out-of-the-Box Research: Killing / Hiding the CoreML ANE First-Load Cost

Date: 2026-06-12. Target: iOS 26. App: Jot (privacy-first, on-device-only; only outbound is user-initiated feedback).

## The cost, restated precisely (so we attack the right thing)

The >60s first-load is **ANE device-specialization**: the second compile that happens at `MLModel(contentsOf:)` instantiation time, where the runtime lowers the MIL program into an ANE-specific program for *this exact silicon*. This is separate from the `.mlmodel -> .mlmodelc` compile we already ship pre-compiled.

Two load-bearing facts, both confirmed by Apple's own coremltools docs:

1. The specialized artifact **is cached**, "so the expensive device optimization process does not need to run again."
2. **The cache entry is keyed on the full filesystem path of the `.mlmodelc` folder.** ([coremltools Model Prediction guide](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html))

And the iOS reality that breaks it: **app update gives the bundle a new sandbox UUID path**, so the cache key no longer matches and specialization reruns every update. (Confirmed: bundle/data containers get new absolute paths on update — [TN2406](https://developer.apple.com/library/ios/technotes/tn2406/_index.html), [Apple forum: cache is sticky only while absolute path is stable](https://developer.apple.com/forums/thread/786051).)

This is **the same pain every on-device-ML iOS app hits** — whisper.cpp users report 20-25s+ "first run on a device" recompiles ([whisper.cpp #2126](https://github.com/ggml-org/whisper.cpp/issues/2126), [#937](https://github.com/ggml-org/whisper.cpp/issues/937)), and Draw Things measured 20-50s CoreML first-loads and ultimately **abandoned full-graph CoreML** because of it ([Draw Things engineering](https://engineering.drawthings.ai/p/making-apple-neural-engine-work-in)).

So the levers are: **(A) make the path stable across updates** (kill it), **(B) pre-pay the specialization at a moment the user isn't waiting** (hide it), **(C) parallelize / overlap it** (shrink it), **(D) make the wait invisible/useful** (product).

---

## RANKED IDEAS (impact x feasibility)

### TIER 1 — Do these

---

### 1. Copy `.mlmodelc` into a stable path AND verify the cache key is path-not-inode (re-test the "rejected" assumption on iOS 26 + App Group)

**Idea.** On first launch, copy the bundled `.mlmodelc` out of the bundle into a path we control that does NOT carry the bundle's update-churned UUID — specifically the **App Group container** (`containerURL(forSecurityApplicationGroupIdentifier:)`), not Application Support. Load the model only ever from that stable path so the specialization cache key never changes across updates.

**Why revisit "copy-to-fixed-path, rejected".** Our prior rejection was "fails across updates" — but that conclusion is right *only if the copy target also moves on update*. Application Support lives under the **data** container, whose absolute path also churns on some update paths. The **App Group** container has a different lifecycle: its URL carries a UUID that is widely reported to **persist across installs/updates** ("the URL for the shared container contains a unique UUID that can remain the same across installs, with files still present" — [Apple forum](https://developer.apple.com/forums/thread/720458)). If the specialization cache is keyed on that stable App-Group absolute path, it survives updates.

**Caveat (must test, do not assume).** There are **iOS 26 reports of App Group containers being *recreated* with data loss on update** ([FB/forum thread 821222](https://developer.apple.com/forums/thread/821222), "85% of affected cases on iOS 26"). So this is not guaranteed — it's the single highest-value *experiment* to run. Also unknown: whether the ANE cache key is the *string path* (then App Group wins) or resolves to a data-container inode (then it churns regardless). Apple docs say "full file system path," which favors us.

**How it hides/kills the cost.** Kills it entirely from update #2 onward — specialize once, ever.
**Survives an update?** That IS the test. Plausibly yes via App Group; needs on-device proof across an actual TestFlight update on a 12 Pro/14.
**Effort.** Low-Med (copy + load-path swap + a 2-build update experiment).
**Feasibility-for-us.** High, fully on-device.
**Confidence.** Medium that it works; **High that it's worth testing first** because the payoff is "the problem disappears."
**Sources.** [coremltools path-keyed cache](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html), [App Group UUID persists](https://developer.apple.com/forums/thread/720458), [iOS 26 App Group recreation risk](https://developer.apple.com/forums/thread/821222), [bundle path churn TN2406](https://developer.apple.com/library/ios/technotes/tn2406/_index.html).

---

### 2. Pre-pay specialization with `BGContinuedProcessingTask` right after onboarding / "Get Started" tap (iOS 26's headline tool for exactly this)

**Idea.** At the end of onboarding (or the moment the model finishes downloading, if downloaded), the user taps a button — and *that tap* legitimately starts a `BGContinuedProcessingTask` that runs the first full ANE specialization + a throwaway warm inference. The system shows its **own progress UI**, and the work **continues even if the user backgrounds the app or locks the screen**. When they later tap record, the model is already specialized -> warm load.

**Why this is the strongest "pre-pay" vector on iOS 26.** From WWDC25 session 227: the task **must be user-initiated** (a button tap qualifies — "always start with an explicit action like a button tap or gesture"), **starts in foreground and continues in background, runs with the screen locked, presents system progress UI, and on iOS/iPadOS 26 can even get background GPU access**. The Journal app uses it for exports. ([WWDC25 227](https://developer.apple.com/videos/play/wwdc2025/227/), [BGContinuedProcessingTask docs](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)). This is precisely "do the compile before first use, with progress, off the critical path."

**Does the warmed cache survive to foreground?** The *disk specialization cache* persists (it's on disk, path-keyed) regardless of process — so even if the in-memory model dies, the next real load is warm. That's the whole point: BGCPT pays the *one-time disk specialization*, and Idea 1 keeps that disk artifact valid across updates. **The two compose: BGCPT pre-pays it, App-Group-path keeps it.**

**Constraints.** Must report progress or it's expired; QoS is lower when backgrounded (boosts on foreground); must be genuinely user-initiated (don't fire it silently — Apple will cancel maintenance-style tasks). One tap during onboarding is the natural hook.
**How it hides the cost.** Moves the 60s out of the record-tap path into a progress-tracked onboarding step the user expects to wait through.
**Survives an update?** The pre-pay must re-run after each update (cache invalidated) UNLESS Idea 1 lands. Detect "specialization missing" on first foreground post-update and re-fire BGCPT.
**Effort.** Med.
**Feasibility-for-us.** High; on-device; iOS 26-only API (we're iOS 26).
**Confidence.** High that the API supports it; Med on UX tuning (re-fire after update).
**Sources.** [WWDC25 227](https://developer.apple.com/videos/play/wwdc2025/227/), [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest).

---

### 3. Overlap specialization with audio capture using a CPU/GPU pass for utterance #1 only, then reconcile to ANE (instant-first-word, on-device)

**Idea.** We already buffer audio during load. Go further: on a cold/just-updated launch, **immediately start a `.cpuAndGPU` load** (which *skips ANE specialization entirely* — no MIL->ANE lowering) and run the *first* utterance on CPU+GPU so the user sees words *now*, while the ANE specialization proceeds in parallel in the background. Once ANE is ready, transparently switch subsequent inference to ANE.

**Why it works.** `.cpuAndGPU` deliberately excludes the Neural Engine, so it does NOT pay the ANE device-specialization tax ([MLComputeUnits.cpuAndGPU](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandgpu), [hollance/neural-engine](https://github.com/hollance/neural-engine/blob/master/docs/is-model-using-ane.md)). It loads far faster (slower per-inference, but available in seconds, not a minute). This is the on-device, privacy-safe analogue of "cloud for the first utterance only" — same product win, zero data leaves the device.

**Parallelism bonus.** Load `.cpuAndGPU` (fast, for immediate use) and kick off `.all`/`.cpuAndNeuralEngine` specialization concurrently via `MLModel.load(contentsOf:configuration:completionHandler:)` ([async load](https://developer.apple.com/documentation/coreml/mlmodel/3600218-load)). Watch memory: two resident copies duplicate weights ([coremltools note](https://apple.github.io/coremltools/source/coremltools.models.html)) — relevant given our 6GB hard wall. May need to load CPU+GPU, run utterance 1, *release*, then specialize ANE.

**How it hides the cost.** First word appears in ~seconds even on a cold/updated install; the 60s ANE compile happens behind a working experience.
**Survives an update?** Yes as a *mitigation* every cold/updated run (it never relies on cache). Best paired with Idea 1 so it's only needed once.
**Effort.** Med-High (dual-path inference + switchover + memory choreography under the 6GB wall).
**Feasibility-for-us.** High conceptually; the memory ceiling is the real constraint — test whether CPU+GPU pass fits alongside, or sequence it.
**Confidence.** High that `.cpuAndGPU` avoids ANE compile; Med that quality/memory of a CPU+GPU first-utterance is acceptable for our 600M model.
**Sources.** [cpuAndGPU](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandgpu), [is-model-using-ane](https://github.com/hollance/neural-engine/blob/master/docs/is-model-using-ane.md), [async load](https://developer.apple.com/documentation/coreml/mlmodel/3600218-load).

---

### TIER 2 — Worth doing / cheap wins

---

### 4. Parallelize specialization across the model's sub-graphs (encoder / decoder / joint) concurrently

**Idea.** Our 600M Parakeet/Conformer pipeline is multiple `.mlmodelc` (encoder, decoder, joint/prediction). Fire `MLModel.load(...completionHandler:)` for all of them **concurrently** so ANECompilerService specializes them in parallel instead of serially, compressing wall-clock first-load.

**How it shrinks the cost.** Three serial 20s compiles -> closer to the longest single one, if ANECompilerService/ANE pipelines them. (Diminishing returns if the ANE compile is itself serialized by the daemon — measure.)
**Survives an update?** It's a per-cold-load speedup; pairs with Idea 1.
**Effort.** Low (we likely already load these; just don't `await` them serially).
**Feasibility-for-us.** High; on-device.
**Confidence.** Med — depends on whether ANECompilerService actually parallelizes; cheap to measure either way. Watch the weight-duplication memory note under our 6GB wall.
**Sources.** [async load API](https://developer.apple.com/documentation/coreml/mlmodel/3600218-load), [multi-function memory duplication](https://apple.github.io/coremltools/source/coremltools.models.html).

---

### 5. Earlier predictive preload signals than the record tap (keyboard mount, foreground, Action Button / Shortcut / widget intent)

**Idea.** We warm on launch. Add *earlier* triggers so the warm/specialize starts before the user can tap record:
- **App foreground / `willEnterForeground`** and **keyboard-extension mount** (keyboard bounces to app — make the bounce *also* signal "start warming the app's model now").
- **App Intent / Action Button / Siri Shortcut / widget tap** that routes to dictation: begin specialization the instant the intent fires, before the UI is even up. App Intents back Action Button, Shortcuts, widgets, Spotlight ([App Intents overview](https://sharpskill.dev/en/blog/ios/app-intents-siri-shortcuts-advanced-ios-automation)).
- **iOS 15+ prewarming**: the OS already pre-launches our process pre-`main` when it predicts use — but UserDefaults/protected files read as defaults during prewarm, so gate model warm on `isProtectedDataAvailable` / `protectedDataDidBecomeAvailable` ([prewarming + protected data](https://framna.com/articles/solving-prewarming), [openradar FB9780579](https://openradar.appspot.com/FB9780579)). Don't *rely* on prewarm, but *opportunistically* warm when it happens and data is available.

**How it hides the cost.** Buys seconds-to-tens-of-seconds of head start; on warm-cache devices this fully hides load.
**Survives an update?** Speedup only; the first post-update specialization still costs (use Ideas 1-3 for that).
**Effort.** Low-Med per signal.
**Feasibility-for-us.** High; on-device.
**Confidence.** High for foreground/keyboard/intent hooks; Med for prewarm (unreliable, guard carefully).
**Sources.** [prewarming](https://framna.com/articles/solving-prewarming), [App Intents/Action Button](https://sharpskill.dev/en/blog/ios/app-intents-siri-shortcuts-advanced-ios-automation), [intent donation](https://developer.apple.com/documentation/) .

---

### 6. Process longevity via the audio background mode we already need for dictation

**Idea.** Keep the app process (and its in-memory specialized model) alive across short gaps so *warm* loads dominate. While an audio session is active the app isn't suspended; for the natural gaps between dictations, a brief audio-session/`beginBackgroundTask` hold can keep the resident model from being torn down, so the next dictation is instant.

**Reality check.** iOS will still reclaim memory under pressure (more aggressively in Low Power Mode), and **silent-audio-to-stay-alive violates App Store guidelines** ([background modes guidance](https://getstream.io/blog/ios-background-modes/)). So this is "extend the warm window legitimately around real dictation," NOT "run forever." We already have a Warm Hold concept — extend its *process-survival* reach, don't abuse it.
**How it hides the cost.** Converts many would-be cold loads into warm loads within a session.
**Survives an update?** N/A (it's about not re-loading, not about specialization cache).
**Effort.** Low-Med.
**Feasibility-for-us.** Med — policy/battery bounded; must stay within legitimate audio use.
**Confidence.** Med.
**Sources.** [background modes / audio keeps app alive](https://getstream.io/blog/ios-background-modes/), [iOS can kill background apps](https://developer.apple.com/forums/thread/696275).

---

### 7. Pre-pay during the model DOWNLOAD via Background Assets (if/when we move the model out of the bundle)

**Idea.** If we ever deliver the model via **Background Assets** (downloads during app install/update, shown as part of the App Store download), schedule the first specialization to run **as the asset lands**, while the user still perceives "app is installing." iOS 26 Managed/Apple-Hosted Background Assets integrate the download into the Home Screen install UX ([Background Assets overview](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs), [iOS 26 BA forum](https://developer.apple.com/forums/thread/803976)).

**How it hides the cost.** Folds specialization into install/update time the user already waits through.
**Survives an update?** The download/extract step recurs per model version; specialization recurs per update unless Idea 1 holds.
**Effort.** High (architectural — move model to BA, downloader extension).
**Feasibility-for-us.** Med — only worth it if we also want OTA model updates / smaller binary; otherwise heavy for this alone.
**Confidence.** Med.
**Sources.** [Apple-Hosted Background Assets](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs), [iOS 26 BA](https://developer.apple.com/forums/thread/803976).

---

### TIER 3 — Wild-but-maybe / mostly refuted (documented so we don't re-chase)

---

### 8. [WILD] Symlink/hardlink the `.mlmodelc` to a stable path to fool the cache key

**Idea.** Create a symlink at a fixed path -> real model, load via the symlink so the cache key is the stable symlink path.
**Verdict — Likely refuted.** The ANE runtime almost certainly **canonicalizes/realpath-resolves** before keying, and the iOS sandbox restricts cross-container links. No source confirms this works; Apple consistently says "full file system path" and the cache empirically dies on update. **Cheap to disprove on-device once** (10 min), then drop it. Mark as a quick falsification experiment, not a plan.
**Confidence.** Low it works. **Source.** [path-keyed cache](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html).

---

### 9. [WILD] Ship a pre-specialized ANE artifact in the bundle

**Idea / Verdict — Refuted, confirmed.** The ANE program is device-/OS-build-specific and the format is **not exposed** for shipping; you cannot precompile for an arbitrary user's silicon+OS. This is *why* whisper.cpp and Draw Things both eat the runtime compile. Already rejected by us; corroborated. **Confidence.** High it's not possible. **Source.** [whisper.cpp first-run](https://github.com/ggml-org/whisper.cpp/issues/2126), [Draw Things](https://engineering.drawthings.ai/p/making-apple-neural-engine-work-in).

---

### 10. [WILD] Keyboard extension shares the main app's warm model cross-process

**Idea / Verdict — Mostly off-table.** Keyboard extensions have a ~60MB ceiling and run no inference (they bounce to the app) — confirmed by our own architecture and the general extension memory-limit literature ([extension memory limits](https://blog.kulman.sk/dealing-with-memory-limits-in-app-extensions/)). The *disk* specialization cache CAN be shared if both processes load from the **same App-Group `.mlmodelc` path** (ties back to Idea 1) — so the keyboard's bounce-to-app benefits from the app having already specialized. But a live in-memory model can't be shared across the process boundary. **Net:** the only cross-process win is shared *disk* cache via a common App-Group path. **Confidence.** High on the constraint; the shared-disk-path angle is the usable piece. **Source.** [extension memory limits](https://blog.kulman.sk/dealing-with-memory-limits-in-app-extensions/).

---

### 11. [OFF-TABLE — privacy] Cloud transcription for the first utterance only

Would perfectly hide first-load, but **violates Jot's on-device-only privacy posture** (only outbound is user-initiated feedback). **Idea 3 (`.cpuAndGPU` first utterance) is the on-device substitute that captures the same product win without sending audio off device.** Documented only to show it was considered and deliberately rejected on principle, not feasibility.

---

### 12. Make the wait useful/invisible (product layer — complements all of the above)

We already have a calibrated asymptotic progress bar (`ModelLoadTimekeeper`/`LoadingPlaceholderText`). Stack product moves on top of the engineering: (a) **capture audio immediately** and replay through the model once warm (we buffer already — extend to "you can start talking now"); (b) move the unavoidable first-specialization into an **onboarding step with BGCPT progress** (Idea 2) so the *first record* is never the slow one; (c) on post-update launch, proactively detect "specialization invalid" and warm/inform **before** the user taps, turning a surprise 60s into an expected, progress-tracked step. The combination — buffer + CPU-first-word + pre-pay-in-onboarding — is what makes the cost *invisible* even on the runs where it's unavoidable.

---

## RECOMMENDED SEQUENCE

1. **Falsify cheaply first (1 day):** symlink test (Idea 8) and, crucially, the **App-Group-stable-path update experiment** (Idea 1) — ship two TestFlight builds and measure whether specialization survives the update. If Idea 1 holds, the recurring-every-update problem is *solved* and everything else becomes a cold-install-only nicety.
2. **Regardless of #1:** implement **CPU+GPU first-utterance overlap** (Idea 3) + **concurrent sub-graph specialization** (Idea 4) — these shrink/hide the cold cost with no cache dependency.
3. **Pre-pay in onboarding with BGContinuedProcessingTask** (Idea 2), re-fired on post-update detection if Idea 1 fails.
4. **Add earlier preload signals** (Idea 5) and **extend process-warm window** (Idea 6) for steady-state instant feel.
5. Background Assets (Idea 7) only if we separately want OTA model delivery.
