# Speech model slow ONLY after install/update: root cause + update-proof fix

Status: research only (no code changed). Build at time of writing: 1.0.6 (186).
Scope: the bundled Parakeet TDT 0.6B v2 dictation model on 600M-capable devices.

**The exact symptom (owner-confirmed).** The ~60 s slow model load happens in EXACTLY two
cases: (a) fresh install, (b) after an App Store UPDATE. In every other case it is already
**instant** — reopening the app days later AND after a full phone **reboot**. So the
compiled/specialized artifact clearly **persists on disk and survives both process relaunch
and reboot**. An app update is the ONLY thing that invalidates it. This asymmetry is the
crux, and it is what the rest of this doc explains and fixes. This is NOT a generic
per-launch cold-start problem — those paths are already fast.

---

## 0. TL;DR

- **Confirmed root cause, and the reboot-vs-update asymmetry pins it precisely.** Jot loads
  the model's `.mlmodelc` packages straight out of the **app bundle**
  (`Bundle.main.bundleURL/...`, `TranscriptionService.swift:1084`). CoreML's expensive
  on-device step — **ANE device specialization** on first load — is cached on disk **keyed
  by the full filesystem path of the `.mlmodelc` folder** (Apple coremltools, verbatim).
  - A **reboot does NOT move the bundle path** (`/private/var/containers/Bundle/Application/<UUID>/`
    is fixed for the life of an install) → the path-keyed cache still hits → instant. ✓
    matches "reboot is instant."
  - An **app update DOES move the bundle path** (`<UUID>` is reassigned when you install over
    an existing app) → the `.mlmodelc` path changes → cache miss → full re-specialization →
    the ~60 s load. ✓ matches "update is slow."
  - Same logic explains **fresh install** (no cache yet) being slow once.
  This asymmetry **refutes** the RAM-warmth theory (a reboot would kill RAM warmth too, yet
  reboot is instant) and **refutes** "weights re-downloaded each update" (nothing downloads on
  capable devices). The operative cause is narrow: **the compiled/ANE cache is keyed to a
  bundle path that only an update changes.** (§1.4 walks each candidate — bundle path, build
  version, code-signing identity, compile-on-load — against the reboot-survives evidence.)
- **The owner's hypothesis is correct.** Shipping the model inside the bundle is exactly the
  problem — not because the bytes are discarded, but because the bundle's path moves on update
  and that path is the specialization-cache key.
- **The fix:** load the model from a **stable location outside the bundle** (Application
  Support) so its path is constant across updates → the on-disk specialization cache that
  already survives reboot will now also survive updates. This is what Wispr Flow / WhisperKit
  effectively do (model lives outside the per-install bundle; instant after the first
  download, across updates). §4 has the concrete plan: copy the prebuilt `.mlmodelc` once,
  version-gate on bundled-model identity, re-point `modelDirectory()`.
- **The one residual unknown** (settle on-device, not provable from docs): whether iOS evicts
  the specialization cache on an **OS** update regardless of path. Apple gives no API to
  inspect it; WhisperKit reports OS-update eviction. The reboot-survives evidence already
  proves the cache is path-stable across reboot — so a stable path should fix the
  **app-update** case the owner cares about — but an **OS-update** cold start may remain. A
  real device A/B update test (§6) confirms before committing.

---

## 1. Root cause (with code + sources)

### 1.1 Where Jot loads the model from — straight out of the read-only bundle

`TranscriptionService.modelDirectory()` returns the bundled directory on capable devices:

- `Jot/App/Transcription/TranscriptionService.swift:1055` — `modelDirectory()`:
  ```swift
  if DeviceCapability.is600MCapable, let bundled = bundled600mDirectory() {
      return bundled
  }
  return MLModelConfigurationUtils.defaultModelsDirectory(for: selectedRepo)
  ```
- `Jot/App/Transcription/TranscriptionService.swift:1084` — `bundled600mDirectory()` composes
  the path **inside the app bundle**:
  ```swift
  let url = Bundle.main.bundleURL
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("Parakeet", isDirectory: true)
      .appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
  ```
- The load call site passes that directory straight to FluidAudio:
  `TranscriptionService.swift:952` — `let models = try await AsrModels.load(from: directory, version: version)`.

On a 600M-capable device (`DeviceCapability.is600MCapable`, threshold
`physicalMemory >= 4_600_000_000` — `Jot/Shared/DeviceCapability.swift:24`) the model is the
bundled 600M and is **always** loaded from `Bundle.main`. There is **no copy** to a stable
location anywhere today (see §2).

The bundled model on disk is **443 MB**:
`Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2/` containing four `.mlmodelc` packages —
`Encoder.mlmodelc`, `JointDecision.mlmodelc`, `Decoder.mlmodelc`, `Preprocessor.mlmodelc`
(measured with `du -sh`). (The folder name has NO `-coreml` suffix — load-bearing, see the
long comment at `TranscriptionService.swift:1072–1083`; that constraint is orthogonal to this
research but must be preserved by any copy logic.)

### 1.2 The load is NOT an `.mlmodel`→`.mlmodelc` recompile — it is ANE specialization

FluidAudio loads each component with `MLModel(contentsOf:)` pointed directly at the
already-compiled `.mlmodelc`:

- `…/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:265` — `let model = try MLModel(contentsOf: modelPath, configuration: config)`
  (inside `loadModelsOnce`, the function `AsrModels.load` calls per component via
  `DownloadUtils.loadModels`).
- `AsrModels.load(from:)` — `…/FluidAudio/.../TDT/AsrModels.swift:228`. It calls
  `DownloadUtils.loadModels(...)` per model file (preprocessor/encoder/decoder/joint), each
  ending in that `MLModel(contentsOf:)`. The compute config defaults to
  `.cpuAndNeuralEngine` (`AsrModels.swift:450–453`, `defaultConfiguration()`).

Because the artifacts shipped are already `.mlmodelc` (not source `.mlmodel`/`.mlpackage`),
the slow part on first load is **not** the model-spec→`.mlmodelc` compile. It is the second,
hardware-specific compile CoreML does at instantiation time: **device (ANE) specialization**.

Apple's own coremltools guide describes this precisely:

> "During instantiation, another compilation occurs for backend device specialization such as
> for the Neural Engine, which may take a few seconds or even minutes for large models. This
> device specialization step creates the final compiled asset … this final compiled model is
> cached so that the expensive device optimization does not need to run again."
> — Core ML Tools, *Model Prediction* guide.

And, decisively for our question:

> "**The cache entry is linked to the full file system path of the `mlmodelc` folder.**"
> — same guide. Their macOS example: reloading the same model from a *changing* temp path
> takes ~15–17 s every time; copying it to a **fixed** location and loading the compiled
> model makes subsequent loads **~0.1 s**.

Sources: https://apple.github.io/coremltools/docs-guides/source/model-prediction.html

### 1.3 The app-bundle path changes on every update → guaranteed cache miss

The app bundle lives at `/private/var/containers/Bundle/Application/<UUID>/Jot.app/…`. The
`<UUID>` is assigned per install, and **updating over an existing install yields a new UUID**
(community-documented; Apple does not contract bundle-path stability across updates — only the
Documents/Library/App-Group containers are contracted as stable).

Therefore: every update moves `Bundle.main.bundleURL`, which moves the `.mlmodelc` path Jot
passes to `MLModel(contentsOf:)`, which (per §1.2) is the **cache key** for ANE
specialization → cache miss → full re-specialization → cold start.

This is also exactly what the team already wrote down in
`Jot/Shared/ColdStartCopy.swift:8–12`:

> "A **cold** load — the first dictation after an App Store / TestFlight update, when the ANE
> specialisation cache (keyed on the app's install path) is invalidated — takes 30–40s."

So the codebase already names the mechanism; this research corroborates it against Apple's
docs and provides the fix's evidence base.

Sources (bundle-path-changes-on-update): https://groups.google.com/g/phonegap/c/a_TCC4TXBwg ,
https://theapplewiki.com/wiki/Filesystem:/private/var/containers/Bundle/Application ,
https://www.magnetforensics.com/blog/ios-tracking-bundle-ids-for-containers-shared-containers-and-plugins/

**Confidence:** Confirmed for the *app-update* case (path-keyed cache + bundle path moves on
update are each independently sourced and consistent with the team's own notes and the
observed 30–40 s symptom). The owner's "ships the whole model each update" framing is
*directionally right* — the operative detail is the moved path invalidating the **compiled
cache**, not the model weights being discarded/re-fetched.

### 1.4 Why reboot survives but update doesn't — candidates discriminated

The owner's evidence is a near-perfect natural experiment. The slow load fires on **fresh
install** and **app update**, but NOT on **app relaunch** or **device reboot**. So the
invalidating event is something that **an update changes but a reboot does not.** Walking each
candidate against that discriminator:

| Candidate cause | Changes on **reboot**? | Changes on **app update**? | Survives reboot per evidence? | Verdict |
|---|---|---|---|---|
| **RAM-resident warm model** | YES (RAM cleared) | YES | No — would be slow after reboot, but reboot is INSTANT | **Refuted** |
| **App bundle path / `<UUID>`** (`Bundle.main.bundleURL`) | **No** (fixed per install) | **YES** (`<UUID>` reassigned) | Yes — matches instant reboot | **CONFIRMED — the cause** |
| **Build/version number** (`CFBundleVersion`) | No | YES | (also stable across reboot) | Possible co-key, but path alone is sufficient & is the documented key |
| **Code-signing identity / cdhash** | No | Usually yes (re-signed build) | (stable across reboot) | Possible co-key; not the documented key; can't be primary since path already explains it |
| **Compile-on-load from bundle each launch** | n/a | n/a | If true, EVERY launch (incl. reboot) would be slow — it isn't | **Refuted** (see below) |
| **OS version** (specialization cache OS-update eviction) | No | No | n/a — orthogonal; only an *OS* update would trigger it | Separate, residual risk (§5.4) |

Two of these are not just "consistent with" but **provably decisive**:

1. **Compile-on-load is refuted by the reboot evidence + the code.** FluidAudio loads
   already-compiled `.mlmodelc` via `MLModel(contentsOf:)` (DownloadUtils.swift:265) — there is
   no `.mlmodel`→`.mlmodelc` compile step on load (the `.mlmodelc` ships prebuilt in the
   bundle, §1.1–1.2). If the slow part were a *recompile from the bundle on every load*, a
   reboot (and every relaunch) would be slow too. They're instant ⇒ the expensive output is
   **cached on disk somewhere update-stable and reboot-stable**, and only re-derived when its
   cache key misses.
2. **The cache key is the path, and only an update moves the path.** Apple documents the
   specialization cache as keyed to the full `.mlmodelc` filesystem path (§1.2). A reboot leaves
   `/private/var/containers/Bundle/Application/<UUID>/Jot.app/Models/.../Encoder.mlmodelc` byte-
   for-byte at the same path ⇒ cache hit ⇒ instant. An update reassigns `<UUID>` ⇒ new path ⇒
   miss ⇒ ~60 s re-specialization. This is the single mechanism that fits BOTH observations with
   no extra assumptions.

Where does the surviving compiled cache physically live? CoreML stores specialized artifacts in
an **OS-managed cache outside the app bundle** (WhisperKit confirms this, §3) — most likely under
the app's `Library/Caches` / a system com.apple.e5rt-style ANE cache. We can't enumerate it (no
API), and we don't need to: the point is it is **keyed by the bundle path of the source
`.mlmodelc`**, so moving that source path (only updates do) orphans the cache entry. Holding the
source path stable (the fix) keeps the key — and therefore the existing reboot-surviving cache —
valid across updates too.

(Note: build-version and signing identity *also* change on most updates, so this experiment alone
can't fully exonerate them as co-keys. But (a) Apple documents the **path** as the key, and (b)
the fix — a stable path — is the correct move regardless of whether version/signature are
secondary keys, because the on-device A/B in §6 will reveal if a stable path alone suffices. If a
stable-path build is STILL slow after update, that would implicate a version/signature co-key and
is exactly what the experiment is designed to catch.)

---

## 2. Does Jot already copy the model anywhere? No.

- The only thing called after a successful load is `ColdStartCopy.markLoadedOnce()`
  (`TranscriptionService.swift:972`), which just sets a `UserDefaults` bool
  (`ColdStartCopy.swift:83`) to choose first-ever vs recurring UI copy. **It does not copy any
  files.**
- On capable devices the model is loaded **in place** from the bundle; on sub-6 GB devices the
  110M is *downloaded* into FluidAudio's Application Support cache
  (`MLModelConfigurationUtils.defaultModelsDirectory(...)`, `modelDirectory()` else-branch,
  `TranscriptionService.swift:1059`). That download path lands in a stable location already —
  so **low-RAM devices likely do NOT suffer the per-update cold start** (their `.mlmodelc`
  path is constant). The problem is specific to the **bundled 600M on capable devices**, which
  is the majority/flagship path.

Confidence: Confirmed (grep of all `ColdStartCopy`/copy/`FileManager` sites in
`TranscriptionService.swift`; no copy of the bundled model exists).

---

## 3. Why Wispr Flow / WhisperKit can be "instant after update"

The reference behavior: **Wispr Flow's** offline model is instant across updates — slow only
once, on the very first download, then instant forever (incl. after app updates). That is the
exact signature of "model lives at a stable path outside the per-install bundle," and it's the
same architecture **WhisperKit (Argmax)** documents.

WhisperKit ships device-agnostic `.mlmodelc` files and **stores them outside the app bundle**
(downloaded into Application Support / a stable model folder), then relies on CoreML's on-disk
specialized cache plus an explicit **prewarm** to do specialization up front. Crucially, because
the model is **downloaded once into a stable location** (not re-shipped inside each app build),
its path never moves on an app update — so the first-download specialization is paid once and
survives every subsequent update. From Argmax's own description (search snippet):

> "Core ML 'specializes' a model automatically during the first time the models are loaded, and
> the resulting 'specialized' model files are cached **on-disk by Core ML outside the app
> bundle**. This cache … is **evicted after every OS update** and if the models are not used for
> extended periods… Apple does not yet provide a third-party API to check whether the cache will
> be hit or is evicted. Argmax built a defensive **prewarm** option to ensure each model
> specialization completes before the app's normal operation."

The mechanism that makes them *instant after an **app** update*: because their `.mlmodelc` lives
at a **stable path** (not in the per-install bundle), an app update does not move it, so the
path-keyed specialization cache is **not** invalidated by the update. They still pay a cold
specialization after an **OS** update (cache evicted) — and they paper over that with prewarm so
the user rarely *notices* it during normal use.

Net: "instant after update" = stable model path (cache survives app updates) **+** prewarm at
launch (hides the residual cold cases). Jot already does the prewarm half (launch warm-up +
`ModelLoadTimekeeper`/`ColdStartCopy` UX) — what it lacks is the **stable path**.

Sources: WhisperKit FAQ/issues — https://deepwiki.com/argmaxinc/whisperkit ,
https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift ,
https://github.com/argmaxinc/WhisperKit/issues/171

Confidence: Likely (the stable-path + prewarm mechanism is well-sourced; the exact claim that a
held-constant path survives an *app* update on iOS is the inferential step the on-device test in
§6 must confirm).

---

## 4. Feasibility of the proposed fix

**Proposed:** on first launch, copy the bundled model to a stable location; thereafter load from
there so the `.mlmodelc` path is constant across app updates.

### 4.1 Does FluidAudio allow loading from an arbitrary URL? YES.

`AsrModels.load(from directory: URL, …)` (`…/TDT/AsrModels.swift:228`) takes any directory URL.
Internally it resolves the repo via `repoPath(from:) = directory.deletingLastPathComponent() +
version.repo.folderName` (`AsrModels.swift:142`, `588`). The only constraint is the one Jot
already honors: the **leaf directory name must equal `Repo.parakeetV2.folderName` =
`parakeet-tdt-0.6b-v2`** (no `-coreml`), so `modelsExist(at:)`/`load(from:)` find the files
(`TranscriptionService.swift:1072–1083`). A stable copy must preserve that leaf name, e.g.
`<AppGroup>/Models/Parakeet/parakeet-tdt-0.6b-v2/{Encoder,Decoder,JointDecision,Preprocessor}.mlmodelc`.

So pointing FluidAudio at a copied location is a **one-line change** to what `modelDirectory()`
returns — no FluidAudio fork needed. (`modelsExistOnDiskForSelectedVariant()`,
`activeDownloadedModelDirectory()`, the orphan-sweep, etc. all derive from `modelDirectory()`,
so they follow automatically — but each must be re-read to confirm none assume the bundle path.)

### 4.1a What to copy — the raw `.mlmodelc`, NOT the compiled/ANE cache

Copy **only the four prebuilt `.mlmodelc` packages** that ship in the bundle (`Encoder`,
`Decoder`, `JointDecision`, `Preprocessor`, + the vocab JSON) to the stable dir. Do **not** try
to copy or relocate CoreML's ANE specialization cache — you can't, and you don't need to:

- The specialization cache is **OS-managed, outside the bundle, with no public API** to read,
  write, move, or pin it (§3). There's nothing in the app sandbox to copy.
- What you control is the **source `.mlmodelc` path**, which is the cache **key** (§1.2). Put the
  source at a stable path and CoreML re-derives (once) and then re-uses its own cache against that
  stable key — exactly the reboot-surviving behavior we already observe, now extended across
  updates.
- Mental model: you are NOT persisting the compiled output; you are **persisting the cache key**
  (the input path) so the OS's own compiled-output cache keeps hitting. The first load from the
  new stable path pays one specialization (unavoidable — it's a new key the first time); every
  load after that, including post-update, hits.

This is why the copy is cheap to reason about: it's just a 443 MB file copy of static assets, with
no dependency on CoreML internals.

### 4.2 Where to copy — App Group container vs Application Support

| | Application Support (app sandbox) | **App Group container** (`group.…`) |
|---|---|---|
| Stable across **app** update? | Yes | Yes |
| Reachable by keyboard extension? | No | Yes |
| Already used by Jot? | Yes (110M cache) | Yes (SwiftData store + history mirror) |
| Backed up to iCloud by default? | Yes (consider excluding) | Yes (consider excluding) |

**Does the keyboard need it?** **No.** The keyboard extension does **not** load the ASR model —
it mirrors the main app's live streaming state cross-process via App Group reads + Darwin
notifications (`Jot/Keyboard/KeyboardStreamingHub.swift:4–5, 121–129`; no `AsrModels`/FluidAudio
references in `Jot/Keyboard/`). Dictation inference runs only in the **main app** process. So the
keyboard argument for App Group does **not** apply here.

**Recommendation: Application Support**, not the App Group container. Rationale: only the main app
needs the path; keeping a 443 MB blob out of the App Group container avoids bloating the
shared/SwiftData-adjacent container and any provisioning-profile-regeneration risk noted for App
Groups. If a future on-device-in-keyboard ASR ever lands, revisit. Either way, set
`isExcludedFromBackup = true` on the copied dir (it's a reproducible copy of a bundled asset —
no reason to bloat iCloud backups by ~0.45 GB).

### 4.3 Sketch

1. Compute `stableDir = applicationSupport/Models/Parakeet/parakeet-tdt-0.6b-v2`.
2. Version-gate the copy on the **bundled model identity**, not app version (see §5).
3. If the gate says "stale or missing": copy `bundled600mDirectory()` → `stableDir` (atomic:
   copy to a temp sibling, then rename), set `isExcludedFromBackup`, write the version marker.
4. `modelDirectory()` returns `stableDir` once the copy is verified present; **fall back to the
   bundle** if the copy is missing/failed (defensive — never block dictation on the copy).
5. First load from `stableDir` still pays one specialization; **every subsequent load — including
   after the next app update — should hit the cache** (the path no longer moved). Prewarm at
   launch (already present) hides that one-time specialization.

---

## 5. Tradeoffs / risks

1. **Disk: ~doubles the model's on-disk footprint.** The bundle copy can't be deleted (it's
   inside the signed `.app`), so the stable copy is *additive*: **+443 MB** (→ ~886 MB for the
   600M model across bundle+copy). On a ~845 MB IPA this is a meaningful bump to installed
   footprint. Mitigations: (a) exclude from iCloud backup; (b) accept it as the cost of fast
   updates (WhisperKit-class apps pay the same); (c) NOT viable: deleting the bundle copy.
   On-device-thinning note: the bundle copy is the install-time source of truth and survives;
   the stable copy is the runtime path.
2. **First-launch copy time.** ~443 MB file copy. On modern NVMe-class iPhone storage this is
   sub-second to a few seconds, but it must be **off the launch critical path** and must not
   block the first dictation — fall back to the bundle if the copy hasn't finished. Do the copy
   on a background task at first launch / first idle, not synchronously in `application(_:didFinishLaunching)`.
3. **When to re-copy (version gating).** Re-copy **only when the bundled model bytes change**,
   not on every app version bump (otherwise you re-pay specialization every release for no
   reason). Key the marker on a **content identity of the bundled model** — e.g. a hash of
   `Preprocessor.mlmodelc/coremldata.bin` + the four package mod-sizes, or a hand-maintained
   "bundled model version" constant bumped only when the weights change. Store the marker next to
   the copy. On mismatch: re-copy (and the next load eats one specialization — expected and
   correct). Pitfall to avoid (per the team's own `feedback_flag_before_work_antipattern`): write
   the version marker **after** the copy + a successful first load, never before, or a crash
   mid-copy leaves a poisoned marker that points at an incomplete model.
4. **The crux unknown — does a stable path actually preserve the ANE cache across an iOS *app*
   update?** Apple documents the cache is **path-keyed** (§1.2) and that it lives outside the
   bundle (§3), which *implies* a constant path survives an app update. But Apple exposes **no
   API** to verify the cache state, and WhisperKit reports the OS **evicts it on every OS
   update** regardless of path. So:
   - Expected to fix: the **app-update** cold start (the owner's actual complaint).
   - Will NOT fix: the **OS-update** cold start, and the **long-idle eviction** cold start.
   - This is not 100% provable from docs — it requires the §6 on-device test. Treat §1–§4 as
     "strong, sourced hypothesis," not "guaranteed win," until that test runs.
5. **FluidAudio version constraint.** Pinned at **0.14.7** (`Package.resolved`). The arbitrary-URL
   load API used here is stable across recent versions, but any FluidAudio bump should re-verify
   `AsrModels.load(from:)` + the `repoPath` leaf-name contract still hold.
6. **Cross-surface consistency.** `modelsExistOnDiskForSelectedVariant()`,
   `activeDownloadedModelDirectory()`, the `.purging-*` orphan sweep, and any Diagnostics/Settings
   "model present" gates all derive from `modelDirectory()`. Re-point is centralized, but each
   must be re-read so none silently assume the bundle path or try to delete the stable copy.

---

## 6. Recommendation

**Worth doing — yes, conditionally.** This directly targets the owner's complaint (slow first
dictation after every app update), it's the same architecture the comparison app uses, FluidAudio
already supports it with no fork, and the change is centralized in `modelDirectory()`. But gate
the rollout on a **real on-device update test**, because the payoff hinges on the one cache-key
behavior docs can't fully prove (§5.4).

**Staged plan:**

1. **Experiment first (cheapest, settles the crux).** Before building the full copy machinery, do
   a minimal on-device A/B:
   - Build A (current): measure cold-load ms after an app update (the `parakeet-load` signpost /
     "Parakeet load end … elapsedMS" log at `TranscriptionService.swift:978`).
   - Build B (throwaway): point `modelDirectory()` at a hand-copied Application Support dir; install,
     load once (pay specialization), then install a *trivially different* build B' over it (new
     bundle UUID) and measure the post-update load. If B' is warm-fast and A is 30–40 s, the fix is
     proven. Also note OS-update behavior if one is available.
2. **If proven, productionize:** background first-launch atomic copy → Application Support, content-
   hash version marker (written post-verify), `isExcludedFromBackup`, bundle fallback,
   re-point `modelDirectory()`, re-audit the derived call sites (§5.6). Keep the existing prewarm +
   `ColdStartCopy` UX as the safety net for the residual OS-update/idle cold cases.
3. **Verify on device:** clean install (copy runs, first dictation pays one specialization, second
   is fast); app update over install (must be fast — the win); model-version bump (re-copies, one
   slow load, then fast); low-storage behavior of the +443 MB copy; confirm low-RAM/110M devices
   are unaffected (they already load from a stable Application Support path).

**Open questions for on-device experiment:**
- Does holding the `.mlmodelc` path constant actually make the post-**app-update** load warm-fast?
  (the crux — §5.4.)
- Magnitude of the residual **OS-update** cold start with the fix in place (unavoidable per
  WhisperKit; quantify so UX can plan around it).
- First-launch copy duration on a representative low-end-but-capable device (e.g. iPhone 12-class).

---

## Appendix — primary evidence

Code:
- `Jot/App/Transcription/TranscriptionService.swift:1055` (`modelDirectory`), `:1084`
  (`bundled600mDirectory`, loads from `Bundle.main`), `:952` (`AsrModels.load(from:)` call),
  `:972` (`markLoadedOnce`, UI-only), `:978` (load-elapsed log/signpost).
- `Jot/Shared/ColdStartCopy.swift:8–12` (team's own statement of the path-keyed ANE-cache cause).
- `Jot/Shared/DeviceCapability.swift:24` (600M threshold).
- `Jot/Keyboard/KeyboardStreamingHub.swift:4–5,121–129` (keyboard mirrors main app; loads no model).
- FluidAudio 0.14.7: `…/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:228` (`load(from:)`),
  `:142,:588` (`repoPath` leaf-name contract); `…/DownloadUtils.swift:265`
  (`MLModel(contentsOf:)` on the prebuilt `.mlmodelc`).
- Bundled model: `Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2/` = 443 MB, 4 `.mlmodelc`.

External:
- Core ML Tools — Model Prediction (path-keyed specialization cache; fixed-path → ~0.1 s):
  https://apple.github.io/coremltools/docs-guides/source/model-prediction.html
- WhisperKit caching/prewarm (cache outside bundle, OS-update eviction, no inspection API):
  https://deepwiki.com/argmaxinc/whisperkit ,
  https://github.com/argmaxinc/WhisperKit/issues/171
- iOS bundle UUID changes on update:
  https://groups.google.com/g/phonegap/c/a_TCC4TXBwg ,
  https://theapplewiki.com/wiki/Filesystem:/private/var/containers/Bundle/Application ,
  https://www.magnetforensics.com/blog/ios-tracking-bundle-ids-for-containers-shared-containers-and-plugins/
- whisper.cpp "first run on a device may take a while" (corroborates first-load specialization):
  https://github.com/ggml-org/whisper.cpp/issues/2126
