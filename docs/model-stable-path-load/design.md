# Model stable-path load — kill the cold-load after every app update

## Problem
The first dictation after an App Store / TestFlight **update** is cold (~16s for the speech model alone; was ~60s pre-191 due to contention). Reopen/reboot are instant. This repeats on **every** update.

## Root cause (proven, 2026-06-24)
The CoreML/ANE **specialized cache** (`Library/Caches/<bundle-id>/com.apple.e5rt.e5bundlecache`, in the **Data** container) is reused only when the model is loaded from the **same stable file location** whose files aren't replaced by the update. Jot ships all models **inside the app bundle**; an update replaces the bundle (new path + new files) → cache miss → re-specialize.

Probe evidence (`/Users/vsriram/code/ModelUpdateProbe`): a model **downloaded to Application Support** loaded in **328ms (1st) / 136ms (2nd)** even after a clean **delete+reinstall** (which wipes the whole container — more destructive than an update). A throwaway `/tmp` path is still 15s (force-COLD), confirming the cache tracks the stable location, not the container UUID. Reopen-from-stable-path screenshots showed ~150–186ms warm.

## What's bundled today (all load from `Bundle.main`)
| Model | Path today | Resolver | Size |
|---|---|---|---|
| Parakeet TDT 0.6B v2 (speech) | `<Bundle>/Models/Parakeet/parakeet-tdt-0.6b-v2/` | `TranscriptionService.modelDirectory()` (~:1103) | ~443MB |
| CTC 110M (vocab boost) | `<Bundle>/Models/Parakeet/parakeet-ctc-110m-coreml/` | `CtcModelCache.shared.root` (:48) | ~100MB |
| EmbeddingGemma (Ask) | `<Bundle>/Models/EmbeddingGemma/` | `EmbeddingGemmaService.bundledModelDirectory` (~:110) | ~328MB |

Total bundled model data: **~870MB**. CTC vocab is **not** downloaded — it's bundled (stale comment).

## Decision — Option A (copy bundle → Application Support on first launch)
Keep bundling all three (preserves offline-install + zero network ever). On first launch, **copy** the bundled models into a stable Application Support location and load from there forever. Chosen over Option B (don't bundle, download on first launch) because B forces new users to download ~870MB and loses offline-install. Tradeoff accepted: **+~870MB device disk** (the bundled originals can't be deleted from the `.app`, so they become dead weight). Owner: "start with A, prune later" — a future version can swap to download (B) to reclaim the disk.

## Design

### Staging step (the heart of it)
A `ModelStaging.ensureStaged()` run **once at launch, before any model load** (`warmIfNeeded`, vocab prep, embedding prewarm all wait on it — extends the 191 serialize ordering):

```
stagedRoot   = AppSupport/Models           // mirrors <Bundle>/Models structure
bundleRoot   = Bundle.main/Models
markerFile   = AppSupport/Models/.staged-version

func ensureStaged():
    if read(markerFile) == BUNDLED_MODELS_VERSION and allModelsExistAt(stagedRoot):
        return                              // normal launch → no copy, instant
    // first launch, OR the bundled model changed → (re)stage
    copy each subdir bundleRoot/* -> tmpStaging/* (atomic temp)
    verify modelsExist at tmpStaging
    move tmpStaging -> stagedRoot (replacing old)
    write(markerFile, BUNDLED_MODELS_VERSION)   // marker LAST, only after verify
```

- **CRITICAL — the re-copy trigger is the MODEL version, NOT the app build.** `BUNDLED_MODELS_VERSION` is a manual constant in code, bumped **only when we change a bundled model**. If we keyed on `CFBundleVersion`/build number, every app update would re-copy + re-specialize — defeating the entire fix. Normal app updates keep the same `BUNDLED_MODELS_VERSION` → marker matches → no copy → instant.
- **Idempotent / crash-safe:** marker written last, after verify. App killed mid-copy → marker absent/stale → re-stage next launch. Stage into a temp dir then move into place so a partial copy is never loaded.
- **Cost:** the ~870MB copy happens only on first launch and on an actual model-version change (rare). A few seconds of disk I/O; surface it in onboarding ("Setting up your speech model…") and on the migration update.

### Resolver changes (all three point to staged path, with bundle fallback)
```
stagedDir(for: model) = AppSupport/Models/<subpath>
resolve(model):
    if modelsExist(at: stagedDir): return stagedDir     // the fast, update-proof path
    else:                          return bundleDir       // fallback: functional but cold-after-update
```
- `TranscriptionService.modelDirectory()` → staged Parakeet TDT dir (fallback bundle).
- `CtcModelCache.shared.root` → staged `Models/Parakeet` (fallback bundle). Its `ensureRootExists`/`removeCache` stay no-ops; `isCached` checks staged.
- `EmbeddingGemmaService.bundledModelDirectory` → staged `Models/EmbeddingGemma` (fallback bundle).
- The bundle fallback guarantees dictation never breaks if staging fails (disk full, etc.) — it just falls back to today's cold-after-update behavior, never to "no model."

### One-time specialize
The first load from the new staged path specializes once (~15s for Parakeet) then caches → instant forever, including across all future updates. This is the same one-time cost that exists today, just relocated to a stable path.

### Migration (existing users)
Model stays bundled, so **nobody downloads anything.** The update that ships this stages bundle→AppSupport on first launch → one-time ~15s specialize → instant forever after. No flag needed beyond the version marker (which is absent for them → stages once).

## Risks / open questions
- **Disk:** +~870MB per device. Accepted; prune later (→ Option B download).
- **Copy duration on first launch:** ~870MB. Confirm it's tolerable backgrounded; show onboarding progress. Should it block W5 (keyboard test needs the speech model staged first)? → Yes: W5 waits on `ensureStaged()`.
- **Staging location:** `AppSupport/Models` (Data container, survives updates, NOT purgeable — unlike `Library/Caches`). Confirm Application Support (not Caches) so iOS never evicts it.
- **Verify on a real TestFlight update** that the staged path actually stays warm (the probe proves the mechanism; a real Jot update is the final proof).
- **features.md impact:** light/internal. Possibly a one-line note that the model sets up once on first launch/after a model change. No user-facing feature added.

## Implementation plan (no real code — pseudo only above)
1. New `ModelStaging` (Shared or App) with `ensureStaged()` + `BUNDLED_MODELS_VERSION` + staged-path helpers.
2. Wire `ensureStaged()` into launch before the 191 serialize chain; vocab/embedding/W5 wait on it.
3. Repoint the 3 resolvers to staged-with-bundle-fallback.
4. Onboarding/migration progress UI for the one-time copy.
5. Verify: clean install (stages, 1×15s, then instant) + a real TestFlight update (stays instant).
```
