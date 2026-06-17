# Wizard model pre-warm — start the speech-model load at wizard start so it's warm by W5

Status: **BRAINSTORM / RESEARCH + DESIGN** (no code change). Pseudo-code only. Confidence and unverified assumptions flagged inline per the analysis protocol.

**Goal (as stated):** start loading the speech model the moment the setup wizard begins, so it is fully warm (ANE-specialized) by the time the user reaches the **W5 "Now try the keyboard"** step.

**Lead answer (full reasoning in [Timing analysis](#timing-analysis-does-it-fit)):**
- For the **default new-install variant (bundled Parakeet TDT-CTC 110M)** the answer is **YES, comfortably** — and in fact *it is already warmed today*. `JotApp.init()` already fires `transcription.warmUp()` at process launch, ungated on setup completion (`JotApp.swift:309-315`). The 110M encoder cold-specializes in ~3–4.4 s (research-models.md:11) vs a W1→W5 traversal budget of **~30–70 s**. The model is warm long before W5.
- For the **opt-in Parakeet 600M v2 variant** the answer is **NO on first selection** — but this case **cannot occur during the first-run wizard**: 600M is a Settings-only download that a brand-new user has not made, so `SpeechModelVariant.current()` is `.tdtCtc110m` throughout onboarding. 600M only matters on a *re-run* of the wizard by a user who already opted in (edge case E5).
- **Single recommended hook:** add an eager `warmUp()` of **both** services in `SetupWizardView.onAppear` (the wizard's existing top-level `.onAppear`, `SetupWizardView.swift:133`), targeting the **injected `transcriptionService` / `streamingService` environment instances** — which the real app wires to `TranscriptionService.shared` / `StreamingTranscriptionService.shared` (`JotApp.swift:372-373`), the same instances W5's dictation uses. This is a **belt-and-suspenders** add: it makes the wizard's warm intent explicit and independent of the launch-path warm (which could be skipped on a warm-process re-run), and it is idempotent so it never double-loads.

---

## Part 1 — Wizard flow map

### Real flow (W1→W7)

The wizard is a 7-case `SetupStep` enum machine in `SetupWizardView.swift:250-258`, rendered through a `switch` (`:78-132`). Forward navigation is `advance(to:)` (`:203-212`, pushes history); back is `goBack()` (`:218-223`). The container installs ONE app-lifetime artifact in its `.onAppear` (`:133-149`): a Darwin observer for `keyboardDictateTapped`.

| Step | Case | File | What it does | What advances it | Notes |
|------|------|------|--------------|------------------|-------|
| **W1** | `.welcome` | `WelcomeStep.swift` | Brand mark + one-line value prop + "Get started" | Tap **Get started** | No back; first step. |
| **W2** | `.microphone` | `MicStep.swift` | Requests mic permission (`AVAudioApplication.requestRecordPermission`). Auto-advances if already granted (`:60-68`) | Tap **Grant microphone** → grant; or auto-advance | iOS permission sheet adds a beat. |
| **W3** | `.keyboardInstall` | `KeyboardInstallStep.swift` | Deep-links to System Settings to add the Jot keyboard + Full Access; auto-detects install via `UITextInputMode.activeInputModes` (`:145-153`) | Tap **Continue** (after install detected) or **I've already added it** | **Biggest time sink** — user leaves to Settings, toggles two switches, returns. Tens of seconds. |
| **W4** | `.howItWorks` | `HowItWorksStep.swift` + `HowItWorksScene.swift` | A looping ~13 s 4-step animation teaching the capture flow | Tap **Got it** | User often watches ≥1 loop. |
| **W5** | `.tryKeyboard` | `TryKeyboardStep.swift` | **The target.** "Now try the keyboard." User taps the field, switches to Jot keyboard, taps Dictate. Recording runs **in the main app** (foreground), result pastes into the wizard field. Polls `ClipboardHandoff.readFresh()` at 750 ms (`:133-155`) and auto-advances. | Fresh dictation detected, or tap **I tried it** | This is where the load cost would bite if unwarmed. |
| **W6** | `.warmHold` | `WarmHoldStep.swift` | Warm-hold opt-in toggle → writes `AppGroup.warmHoldEnabled` (`:42`) | Tap **Continue** | — |
| **W7** | `.youreReady` | `YoureReadyStep.swift` | Success screen + Apple Watch card. **Terminal.** | Tap **Start jotting.** → `closeAndComplete()` | `SetupCompletion.markCompleted()` (`SetupWizardView.swift:238`). |

The doc-comments in `SetupWizardView.swift:1-33`, `:243-258`, `KeyboardInstallStep.swift:5`, `HowItWorksStep.swift:5`, `YoureReadyStep.swift:5-12` confirm the retirements: the old **W3 "Download speech model"** panel and the old in-app **try-it** panel were both removed.

### What the retired download step means for WHERE the model comes from

The standalone "Download speech model" panel was retired because **the default model now ships bundled in the IPA** (`SetupWizardView.swift:13-18`, App Review 4.2.3(ii)). Concretely:
- **Default variant = Parakeet TDT-CTC 110M, bundled.** `TranscriptionService.modelDirectory()` resolves it to `Bundle.main.bundleURL/Models/Parakeet/parakeet-tdt-ctc-110m` (`TranscriptionService.swift:972-998`). No download — the weights are on disk from install.
- **Streaming EOU 320 ms = bundled too** (`StreamingTranscriptionService.swift:42-43`).
- **Parakeet 600M v2 = the ONLY downloaded variant**, and only via an explicit Settings tap (`SpeechModelVariant.swift:27-30`; `SettingsView.swift:1008` writes `AppGroup.speechModelVariant`). It lands in Application Support, not the bundle.

**Consequence for pre-warm:** during the first-run wizard the warm target is always the bundled 110M, which is **already on disk** — so pre-warm only has to pay the **ANE specialization** cost, never a download. This is the whole reason the timing fits (see Part 4).

### Injection — who the wizard's services actually are (the critical question)

`SetupWizardView` reads three services from the environment (`SetupWizardView.swift:46-48`): `transcriptionService`, `streamingService`, `recordingService`.

- **Preview only** injects FRESH instances: `.environment(TranscriptionService())` / `.environment(StreamingTranscriptionService())` (`SetupWizardView.swift:262-263`). **These are NOT what the real app uses** — they exist solely so the `#Preview` doesn't crash on an environment-lookup miss.
- **The real app** presents the wizard inside `JotApp`'s `.fullScreenCover` and injects the **process singletons**: `.environment(transcriptionService)` / `.environment(streamingService)` / `.environment(recordingService)` (`JotApp.swift:367-387`), where those `@State` values were initialized to `TranscriptionService.shared` / `StreamingTranscriptionService.shared` / `RecordingService.shared` (`JotApp.swift:165-191`).

**Therefore the wizard's injected `transcriptionService` IS `TranscriptionService.shared` — the exact instance W5's dictation runs through.** Warming the injected instance is *not* wasted; it warms the same `AsrManager` W5 will use. (Verified: W5's recording is started by `SetupWizardView.handleKeyboardDictateTapped()` → `recordingService.start()` / `RecordingService.shared.start()` (`:177-201`), and `RecordingService.start()` → `kickOffStreamingSession()` → `TranscriptionService.shared.warmUp()` (`RecordingService.swift:401`), and the stop-pass transcribes via `TranscriptionService.shared.transcribe(...)` — all the same singleton.)

### Time budget (W1 → reaching W5)

These are realistic human-pace estimates for a *new* user (no prior keyboard install). They are **not measured** — flag as estimates; confirm on-device (Open Questions).

| Step | User action | Realistic dwell |
|------|-------------|-----------------|
| W1 Welcome | Read one line, tap | 3–6 s |
| W2 Mic | Read, tap Grant, dismiss iOS permission alert | 4–10 s |
| W3 Keyboard install | Leave to Settings, add keyboard, toggle Full Access, return | **20–45 s** (dominant) |
| W4 How it works | Watch ≥1 loop of the 13 s animation, tap Got it | 6–15 s |
| **Arrive at W5** | — | — |
| **Total W1→W5** | | **~33–76 s** (call it ~30 s floor for a fast racer who already had the keyboard installed and skips, ~70 s typical) |

The 110M ANE specialization (~3–4.4 s cold) fits inside even the **fast-racer floor** many times over. Only a pathological "skip everything in <5 s with a cold cache on a very old device" beats it — handled as edge case E1.

---

## Part 2 — Model-load cost recap (what "loaded" costs)

### The load path

`warmUp()` (`TranscriptionService.swift:199-208`) → `ensurePreparing()` (`:714-731`, returns the single in-flight `Task` — coalescing/idempotent) → `loadOrFail()` (`:733-948`). For the bundled 110M, `modelsOnDisk` is true (`:757`), so the `.downloading` branch is skipped and it goes straight to `.loading` → `AsrModels.load(from:)` → `AsrManager().loadModels()` → `modelState = .ready` (`:858-872`). States: `.notLoaded → .loading → .ready` (no `.downloading` for the bundled variant).

`previewTranscribe` (`:683-710`) is **passive**: `guard let manager, modelState == .ready else { return nil }` (`:689`) — it never triggers a load. So if the model isn't warm when W5's preview ticks fire, the live preview is simply blank until the manager exists; it does NOT itself kick the load. (The load is kicked by `RecordingService.kickOffStreamingSession`'s `warmUp()` at `RecordingService.swift:401`, but that only fires *when W5 starts recording* — i.e. too late to be "warm by W5".)

### Where the cost actually is

Per the prior research (model-load-caching.md, research-platform.md:7-9, research-models.md:7-11):
- The slow step is **CoreML ANE device specialization** at `MLModel(contentsOf:)` instantiation — NOT `.mlpackage→.mlmodelc` compile (that's done at build time; we ship `.mlmodelc`).
- It is **dominated by the ENCODER**. FluidAudio benchmark: encoder cold load = **3361 ms (16 Pro Max) / 4396 ms (iPhone 13)**; decoder + joint + preprocessor together <250 ms; warm load 162 ms (research-models.md:11). So for the **110M** the "cold load" is **~3–4.4 s**, not "minutes."
- "Tens of seconds → minutes" applies to the **600M encoder on 6 GB devices** (research-models.md:11), where it also pages against the 6 GB wall.
- The specialization cache is **keyed on the absolute path of the `.mlmodelc` folder**; an app update churns the sandbox UUID → path changes → cache miss → full respecialization (research-platform.md:9, model-load-caching.md:48-52). So the *expensive* cold case is "first launch after an app update" — which, for a first-run wizard, is also "first launch ever."

### `ModelLoadTimekeeper` estimates

`ModelLoadTimekeeper.estimatedSeconds` (`ModelLoadTimekeeper.swift:38-61`) defaults the **cold** estimate to **46 s** (`:53`) with a 75 s ceiling (`:60`) when there's no prior sample. That 46 s is a *generous pacing default for the calibrated bar*, deliberately large so a post-update 600M respecialization doesn't rush the bar. It is **not** a measurement of the 110M cold load (which is the ~3–4.4 s figure). The bar never completes on the estimate; the real `.ready` transition snaps it done (`:14-15`). After the first real load, `ModelLoadTimekeeper.record` (`:66-76`) calibrates per-device.

### Where `warmUp()` is called today

| Site | File:line | Gate | Fires during wizard? |
|------|-----------|------|----------------------|
| App launch (init) | `JotApp.swift:309-320` | `modelsExistOnDiskForSelectedVariant()` only — **NOT** setup-gated (comment `:298-308` says it must run DURING setup for W5/W7) | **YES** (cold launch into wizard) |
| Scene `.task` foreground | `JotApp.swift:573-594` | `SetupCompletion.isCompleted` **AND** modelsOnDisk | **NO** (gated out during wizard) |
| Recording start | `RecordingService.swift:401` | inside `kickOffStreamingSession` | only when W5 *records* (too late to be "warm by W5") |
| Settings | `SettingsView.swift:1061,1092-1093` | n/a | only if user is in Settings |

**Confirmed:** the wizard itself issues **no `warmUp()` call** today (grep of `Jot/App/SetupWizard/` returns zero `warmUp` / `modelState` / `LoadingPlaceholder` references). It relies entirely on the launch-path warm (`JotApp.swift:309-315`) having fired. That is true on a cold first launch — but is a **silent dependency**, and is bypassed on a warm-process wizard re-run (E5).

---

## Part 3 — Cross-reference to prior research (not re-derived)

This doc is the concrete *wizard application* of the "pre-pay specialization during onboarding" idea already in the research set. Relevant findings:

- **research-outofbox.md:45-59 (Idea 2)** — "Pre-pay specialization with `BGContinuedProcessingTask` right after onboarding / 'Get Started' tap." Calls out that a button tap legitimately starts a `BGContinuedProcessingTask` (iOS 26), which shows system progress and continues if backgrounded. **This doc is the lighter-weight precursor:** for the *bundled 110M* we do not need BGCPT at all (the cost is ~4 s, not 60 s) — a plain eager `warmUp()` at wizard start suffices. BGCPT is reserved for the genuinely expensive *600M / post-update* case (future work, E5).
- **research-models.md:11, :18-30 (encoder dominates; CPU-first-word `.cpuAndGPU` swap)** — the encoder is the cost; `.cpuAndGPU` skips ANE specialization and loads 9–39× faster, usable as an instant-first-word bridge. **Not needed for the wizard 110M case** (already fast), but is the fallback lever if a future build makes 600M the onboarding default.
- **model-load-caching.md:48-56, research-platform.md:9 (path-keyed cache, update busts it)** — confirms the cold cost recurs per app update; the wizard pre-warm only helps the *current* launch, it does not make future warms free. Aligns with "hide it, don't kill it."
- **research-platform.md:17-35 (BGProcessingTask / BGContinuedProcessingTask, update-gated)** and **research-outofbox.md:97-109 (earlier triggers: intent/keyboard/prewarm hooks)** — broader pre-warm vectors; the wizard `.onAppear` hook here is one specific "earlier trigger."
- **model-load-caching.md:69-72, research-models.md:42 (6 GB wall, dual-instance memory)** — any 600M-during-wizard warm must respect the 6 GB hard wall; co-resident models + wizard UI risk jetsam. Reinforces "don't warm 600M during onboarding."

The decisive prior fact this doc rests on: **the bundled 110M is already on disk and its cold specialization is single-digit seconds** — so for the default install the pre-warm "fits" trivially. The hard cases in the research (60 s, BGCPT, App-Group-stable-path) are about 600M and post-update, which the first-run wizard does not hit.

---

## Part 4 — Design of the pre-warm

### 4.1 WHERE to hook, and WHAT to call

**Recommended hook: `SetupWizardView`'s existing top-level `.onAppear` (`SetupWizardView.swift:133`).** Add an eager warm of both services there.

```
// SetupWizardView.body .onAppear  (pseudo-code — NOT Swift)
.onAppear {
    install keyboardDictateTapped observer   // existing
    prewarmSpeechModelsForWizard()           // NEW
}

func prewarmSpeechModelsForWizard() {
    // Target the INJECTED env instances == the process singletons the
    // real app passes (JotApp.swift:372-373). Warming these warms the
    // exact AsrManager W5's dictation will run on.
    //
    // Gate exactly like JotApp.init's launch warm (JotApp.swift:311-319):
    // only if the selected variant's weights are already on disk, so we
    // never trigger a silent first-launch 600M download (App Review 4.2.3(ii)).
    if TranscriptionService.modelsExistOnDiskForSelectedVariant() {
        Task(priority: .userInitiated) { @MainActor in
            transcriptionService.warmUp()      // injected == .shared
        }
    }
    if StreamingTranscriptionService.modelsExistOnDisk() {
        Task(priority: .userInitiated) { @MainActor in
            streamingService.warmUp()          // injected == .shared
        }
    }
}
```

**Why the container `.onAppear`, not `WelcomeStep.onAppear`:**
- It fires at wizard *presentation*, the earliest possible moment ("the moment the setup wizard begins") — strictly ≥ the W1 dwell ahead of W5.
- It is the same place the existing Darwin observer is installed, so it's the natural lifecycle seam.
- `WelcomeStep` has no `.onAppear` today and is re-created on every back-nav to W1; the container `.onAppear` is single-shot per presentation.

**Why `warmUp()` on the injected instance, not a wizard-local instance or a direct `TranscriptionService.shared`:**
- The injected instance *is* the singleton in the real app (Part 1), so it's correct. Calling `TranscriptionService.shared.warmUp()` directly would also work and be equivalent in production, but reading from the environment keeps the wizard honest about its dependency and keeps `#Preview` (fresh instance) from warming a real model.
- A wizard-LOCAL fresh instance would be the **bug to avoid**: it would specialize a throwaway `AsrManager` that W5 never uses → wasted compute + double memory.

**Idempotency / no double-load:** `warmUp()` → `ensurePreparing()` returns the single in-flight task (`TranscriptionService.swift:714-718`); a completed load short-circuits in `loadOrFail` (`manager != nil` early return, `:741-745`). So this call is a **no-op if `JotApp.init` already warmed** — it never starts a second specialization. This is why the add is safe as belt-and-suspenders.

### 4.2 Which model to warm

- **The device-selected variant**, resolved via `SpeechModelVariant.current()` (`SpeechModelVariant.swift:34-36`) inside `modelsExistOnDiskForSelectedVariant()`. For a new install this is always `.tdtCtc110m` (bundled).
- **Important correction to the brief's framing:** there is **NO RAM-based auto-selection of the batch variant.** `DeviceCapability.is600MCapable` (`DeviceCapability.swift:23-25`) gates only **`liveTextEnabled`** (the streaming preview), `:34-40` — it does **not** pick the 600M batch model. The batch variant is purely the persisted `AppGroup.speechModelVariant` string, defaulting to 110M. (Grep confirms `is600MCapable` has exactly one consumer: `liveTextEnabled`.) So "warm the RAM-selected variant" reduces, in onboarding, to "warm the bundled 110M."
- **On-disk first?** Yes — gated by `modelsExistOnDiskForSelectedVariant()` (`TranscriptionService.swift:1012-1014`), constant-true for the bundled 110M. We never await/trigger a download in the wizard; if a future build made 600M the onboarding default it would NOT be on disk and the gate would (correctly) skip the warm rather than fire a silent download.
- **Also warm streaming EOU** (bundled) so W5's live-text preview strip can render while recording (it's a cheap presence-check warm, `StreamingTranscriptionService.swift:42-43`). Gate on `StreamingTranscriptionService.modelsExistOnDisk()` to mirror the launch path.

### 4.3 Timing analysis (does it fit?)

**Bundled 110M (default, every first-run wizard):**
- Cost to be "warm": ~3–4.4 s ANE specialization (research-models.md:11), on disk already (no download).
- Budget W1→W5: ~30–76 s (Part 1 table).
- **Verdict: fits with a 7–17× margin.** Even the fast-racer floor (~30 s) dwarfs it. And in practice `JotApp.init`'s launch warm (`:309-315`) already started it before W1 even rendered — the wizard hook just guarantees/re-affirms it.

**600M v2 (only on a wizard re-run by an opted-in user — E5):**
- Cost: tens of seconds → minutes on 6 GB devices (research-models.md:11), already on disk (the user downloaded it earlier), so no download — but full ANE respecialization if this is the first load this process lifetime / post-update.
- Budget: same ~30–76 s.
- **Verdict: may NOT fit** on older 6 GB hardware. Fallback below.

**Fallback when the warm hasn't finished by W5:** W5 today shows **no loading bar** (confirmed: `TryKeyboardStep.swift` renders only the TextField + a polled "Listening for your text…" label; no `modelState` observation). The loading affordance lives on the **hero** and the **keyboard strip**, not in the wizard. When W5 records, `RecordingService.kickOffStreamingSession` calls `warmUp()` + `beginBatchLoadLabelMirror()` (`RecordingService.swift:401-402`) which drives the keyboard strip's "Loading [variant]…" — and the **capture-first** design means the mic starts immediately and audio buffers through a cold load, so nothing said is lost (`JotApp.swift:926-945`). So even in the worst case the user can talk; the transcript just lands a few seconds later. **Optional enhancement (only if E5 matters):** observe `transcriptionService.modelState` in `TryKeyboardStep` and show the existing calibrated bar / a "Getting Jot ready…" line while `!= .ready`. Recommend deferring this unless on-device testing shows a real 600M-re-run pain.

### 4.4 Edge cases

| # | Edge case | Behavior / handling |
|---|-----------|---------------------|
| **E1** | User races W1→W5 faster than the load (had keyboard pre-installed, skips W3/W4) | 110M load is ~4 s and was kicked at launch *and* at wizard `.onAppear`; only beatable on a very old device + a sub-5 s sprint. Capture-first at W5 covers it (mic starts, audio buffers, transcript completes after load). No data loss. |
| **E2** | Model evicted between warm and W5 (memory warning) | `handleMemoryWarning` drops `manager` + `prepareTask`, `modelState=.notLoaded` (`TranscriptionService.swift:1385-1416`) — but only if `!isTranscribing`. After eviction, W5's `kickOffStreamingSession`→`warmUp()` (`RecordingService.swift:401`) re-loads. The wizard `.onAppear` warm doesn't re-fire (single-shot), but the recording-start warm is the safety net. Acceptable. |
| **E3** | W5 keyboard test runs in the MAIN app (foreground) | Confirmed: the keyboard can't capture audio; W5's Dictate tap posts `keyboardDictateTapped`, the wizard host's observer (`SetupWizardView.swift:144-201`) starts `RecordingService.shared.start()` in the **foreground main app**. So the warm model is in-process and the dictation is instant. (This is also why the heartbeat/foreground-pong path matters — `JotApp.swift:85-96`.) |
| **E4** | 6 GB wall — warming 110M while wizard UI + other models resident | 110M int8 encoder is ~66 MB ANE-resident (research-models.md:24); streaming EOU is small; EmbeddingGemma prewarm (`JotApp.swift:329-331`) is `.utility` and small. Co-resident with the wizard's SwiftUI is well under the wall. **Do NOT** add 600M warming here — that's the case that risks jetsam. |
| **E5** | Wizard re-run (Settings → re-run) by a user who already opted into 600M | `SettingsRerunTrigger.requestRerun()` (`SetupState.swift:28-31`) resets completion and re-presents (`JotApp.swift:474-477`). On a *warm process*, `JotApp.init`'s launch warm does NOT re-run (init only runs once per process) — so without the wizard `.onAppear` hook the model might not be warming at all on a re-run. **This is the strongest argument for the wizard hook:** it makes the warm fire on every presentation, re-run included. For 600M specifically the warm may not finish by W5 → see 4.3 fallback (capture-first + optional bar). |
| **E6** | Reduce-Motion / old devices | Pre-warm is orthogonal to motion. On old devices the 110M cold load is at the high end (~4.4 s on iPhone 13) — still well within budget. No special handling. |
| **E7** | Wizard dismissed mid-warm | `closeAndComplete` force-stops any *recording* (`SetupWizardView.swift:227-240`), but a model *load* is a detached idempotent task that simply completes and leaves the singleton warm for the home view — desirable, not a leak. No teardown needed. |
| **E8** | `#Preview` warms a real model | Avoided: preview injects fresh `TranscriptionService()` instances (`:262-263`) and on-simulator `loadOrFail` bypasses real load (`TranscriptionService.swift:734-739`) / `warmUp` is satisfied by the stand-in (`:200-204`). No real ANE work in preview/sim. |

### 4.5 Interaction with the W5 try-it

- W5 fires dictation via the keyboard's Dictate-tap → `keyboardDictateTapped` Darwin notification → `SetupWizardView.handleKeyboardDictateTapped()` (`:177-201`), which clears `ownsActiveRecording` and calls `recordingService.start()`. Auto-advance is driven by `TryKeyboardStep`'s `ClipboardHandoff.readFresh()` polling (`:133-155`), not by the observer.
- **Does a warm model make it instant?** Yes for the *transcription/paste* latency: with `modelState == .ready`, the stop-pass `transcribe(...)` skips the `ensurePreparing().value` wait (`TranscriptionService.swift:547`) and runs inference directly (RTF well under 1× for short utterances). The live-text preview also renders during capture because `previewTranscribe` finds a ready manager (`:689`). Without the warm, the *first word* still appears (capture-first), but the final transcript lands a few seconds later while the load completes — functional, just not instant. The pre-warm converts "works, slightly delayed" into "instant," which is exactly the W5 demo polish the goal asks for.

---

## Recommendation

**Add one idempotent eager warm in `SetupWizardView`'s existing `.onAppear` (`SetupWizardView.swift:133`), targeting the injected `transcriptionService` + `streamingService` (== the process singletons), gated on `modelsExistOnDiskForSelectedVariant()` / `modelsExistOnDisk()` exactly like the launch path.** Pseudo-code in §4.1.

- **For the default bundled 110M (every real first-run): the model is warm by W5 with a large margin** (~4 s load vs ~30–76 s budget) — and is *already* warmed at launch today; the wizard hook makes that guarantee explicit and re-run-safe.
- **Do NOT warm 600M during onboarding** (6 GB wall, E4) and do not add a download trigger (4.2.3(ii)); the gate handles this for free.
- **Defer** the W5 loading-bar enhancement and any `BGContinuedProcessingTask` 600M pre-pay (research-outofbox.md Idea 2) unless on-device testing shows a real 600M-re-run pain at W5 (E5).
- Net change: ~10 lines in one file, no entitlements, no schema impact, no new subsystem. **Schema impact: none** (no `@Model` types touched).

This is intentionally the smallest correct change. The brief's premise ("start loading the moment the wizard begins") is *already substantially true via the launch warm*; the recommended hook closes the warm-process-re-run gap and documents the intent at the wizard layer.

---

## Open questions to confirm on-device

1. **Measured W1→W5 dwell** for a real new user (no keyboard installed) vs a fast racer — confirm the ~30 s floor holds and the 110M load always beats it. (Estimates only above.)
2. **110M cold specialization on Jot's oldest supported device** — is it really ≤4.4 s, or higher on, say, an iPhone 12-class 6 GB device after a fresh install? Pull the `parakeet-load` signpost (`TranscriptionService.swift:860`) / `ModelLoadTimekeeper.record` value on first launch.
3. **E5 (600M re-run):** does the warm finish by W5 on a 6 GB device, or does the user hit a cold 600M respecialization at W5? If painful, decide between (a) the W5 loading-bar enhancement, (b) forcing the wizard to warm only 110M even when 600M is selected, or (c) BGCPT.
4. **E2 frequency:** does iOS fire a memory warning during the wizard often enough to evict between the `.onAppear` warm and W5? If yes, the recording-start re-warm covers it, but worth confirming the strip shows the loading state cleanly in that case.
5. **Does `JotApp.init`'s launch warm actually beat the wizard `.onAppear`?** If init's warm is already in-flight, the wizard call is a pure no-op (coalesced) — confirm via the `Parakeet prepare reuse` log line (`TranscriptionService.swift:716`). Establishes that the wizard hook adds zero cost on the common path.
