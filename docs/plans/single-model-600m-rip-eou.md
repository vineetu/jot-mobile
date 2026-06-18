# Plan — Collapse to a single bundled 600M model; rip EOU; drop 110M as dictation

**Size: L.** Status: design / pre-implementation. Owner-approved (14 Jun 2026).
Builds on `docs/plans/batch-only-streaming.md` (the batch pseudo-streaming
preview that makes EOU dead weight) and `docs/plans/adaptive-vocabulary-correction.md`
(the CTC rescorer that must be preserved). Investigation cited inline with
`file:line` + confidence.

## Goal

One speech model, bundled, instant on first use:

1. **Survivor: Parakeet 0.6B v2** (`parakeet-tdt-0.6b-v2-coreml`, FluidAudio
   `AsrModelVersion.v2`), promoted from an **opt-in ~440 MB download** to a
   **bundled IPA resource**. First dictation is instant + offline.
2. **Remove EOU entirely** — `StreamingTranscriptionService`,
   `StreamingEouAsrManager`, the `parakeet-eou-streaming/320ms/` bundle, the
   `previewSource` engine flag, and the "Preview engine" debug picker. The live
   preview already runs on the batch `PreviewScheduler` path by default
   (verified below) — EOU is the inactive rollback branch.
3. **Drop the 110M (`tdtCtc110m`) as a dictation model.** Remove the
   `parakeet-tdt-ctc-110m/` dictation bundle and the variant enum case. **Keep
   the vocabulary CTC subset** (`parakeet-ctc-110m-coreml/`) — vocabulary
   correction's rescorer depends on it and it is a SEPARATE directory.
4. **Settings:** remove the model selector + variant picker + EOU/preview-engine
   picker. Rename the user-facing "Variant" → **"Language"** (English-only).
5. **Legacy tags:** persisted `AppGroup.speechModelVariant` (`"tdtCtc110m"`,
   `"parakeetV2"`, `"nemotron0_6b"`) all resolve to the single English (600M)
   model.

---

## Verified model-sourcing reality

### Where models physically come from (Q1)

There is **no runtime HuggingFace download for the bundled models and no special
build phase** — the `.mlmodelc` packages are **vendored directly into the repo**
under `Jot/Resources/Models/Parakeet/` and shipped as a **folder reference**
(`project.yml:176-178`, `type: folder` so the asset compiler doesn't flatten /
recompile the CoreML packages). At runtime, FluidAudio's loaders are pointed at
the bundle subtree via `Bundle.main.bundleURL` composition (no download branch).
**Confirmed.**

Current bundle layout (`du -sh`, working tree):

| Dir | Size | Role | FluidAudio loader |
|---|---|---|---|
| `parakeet-tdt-ctc-110m/` | **217 MB** | 110M dictation (default batch) | `AsrModels.load(from:)` via `TranscriptionService.bundledTdtCtc110mDirectory()` (`TranscriptionService.swift:1125-1130`) |
| `parakeet-ctc-110m-coreml/` | **99 MB** | CTC aux for **vocabulary** rescoring | `CtcModels.loadDirect(from:)` via `CtcModelCache.shared` (`CtcModelCache.swift:48-66`) |
| `parakeet-eou-streaming/320ms/` | **214 MB** | EOU 120M live caption | `StreamingEouAsrManager.loadModels(from:)` via `StreamingTranscriptionService.bundledStreamingDirectory()` (`StreamingTranscriptionService.swift:392-399`) |

Also in `Resources/Models/`: `EmbeddingGemma/` (328 MB) — Ask RAG, **unrelated, survives**.

The **600M v2** is the opt-in download. `TranscriptionService.modelDirectory()`
(`TranscriptionService.swift:1104-1113`) routes `.tdtCtc110m` → bundle, anything
else (`.v2`) → `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2)`
= `<AppSupport>/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml/`. The download is
driven by `AsrModels.download(to:version:)` (`TranscriptionService.swift:933`),
gated behind an explicit Settings "Download" tap (4.2.3(ii) consent). **Confirmed.**

### The 600M v2 on disk (Q2, Q6)

Found at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2/`
(downloaded by a prior run), **443 MB**:

| File | Size |
|---|---|
| `Encoder.mlmodelc` | 425 MB |
| `Decoder.mlmodelc` | 14 MB |
| `JointDecision.mlmodelc` | 3.3 MB |
| `Preprocessor.mlmodelc` | 332 KB |
| `parakeet_vocab.json` | 20 KB |
| `config.json` | 3 B |

**Confirmed.** Note the folder name on disk is `parakeet-tdt-0.6b-v2` but
FluidAudio's `Repo.parakeetV2.folderName` returns `parakeet-tdt-0.6b-v2-coreml`
(`ModelNames.swift:63`) — the **canonical bundle folder name must be
`parakeet-tdt-0.6b-v2-coreml`** so `repoPath(from:version:)`
(`AsrModels.swift:142-145`) resolves it. v2 uses a **split frontend**
(separate `Encoder`, not the 110M's fused `Preprocessor`):
`version.hasFusedEncoder == false` for `.v2` (`AsrModels.swift:26-31`). Required
file set for v2 load: `Preprocessor.mlmodelc`, `Encoder.mlmodelc`,
`Decoder.mlmodelc`, `JointDecision.mlmodelc`, `parakeet_vocab.json`
(`ModelNames.ASR.requiredModels`, `ModelNames.swift:336-341` + vocab) — matches
the on-disk set exactly. **Confirmed.**

### How v2 gets bundled (Q2)

`AsrModels.load(from:version:)` already accepts a directory URL and reads the
`.mlmodelc` packages straight from it — **identical mechanism to the bundled
110M**, no API change in FluidAudio. To bundle v2:

1. **Vendor the files into the repo** at
   `Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2-coreml/` (copy the 5
   files from the App Support cache; rename the folder to the `-coreml` form).
   They ride the existing `Resources/Models` folder reference — **no new
   `project.yml` source entry needed**, just files added under the referenced
   dir. **Confirmed** the folder-reference mechanism covers arbitrary
   subdirectories (`project.yml:176-178`).
2. **`modelDirectory()`** (`TranscriptionService.swift:1104`) — collapse to
   always return the bundled v2 dir; delete the App-Support fallback for the
   primary path (keep a defensive nil-guard).
3. **`bundledTdtCtc110mDirectory()`** → replace with a
   `bundled600mDirectory()` pointing at `parakeet-tdt-0.6b-v2-coreml`.
4. `selectedVersion` → always `.v2`; `selectedRepo` → always `.parakeetV2`.

On-disk add: **~443 MB**. No download/copy build phase required.

### Vocabulary CTC preservation (Q3)

The vocabulary rescorer is **independent of the dictation model** and reads only
from `parakeet-ctc-110m-coreml/` via `CtcModelCache.shared`
(`CtcModelCache.swift:48-66`). Required files, traced through FluidAudio:

- `CtcModels.loadDirect(from:)` reads **`MelSpectrogram.mlmodelc`**
  (`CtcModels.swift:82`), **`AudioEncoder.mlmodelc`** (`CtcModels.swift:99`),
  **`vocab.json`** (`CtcModels.swift:288`).
- `CtcTokenizer.load(from:)` reads **`tokenizer.json`**
  (`CtcTokenizer.swift:40`), called by `VocabularyRescorerHolder`
  (`VocabularyRescorerHolder.swift:154`); `VocabularyRescorer.create(...)` is
  passed `ctcModelDirectory: cache.directory` (`VocabularyRescorerHolder.swift:219`).

**Minimal keep-set** (`parakeet-ctc-110m-coreml/`, ~98 MB):
`AudioEncoder.mlmodelc` (97 MB), `MelSpectrogram.mlmodelc` (584 KB),
`vocab.json` (16 KB), `tokenizer.json` (352 KB).
**`CtcHead.mlmodelc` (1 MB) is NOT read** by `loadDirect` or the rescorer —
the only reference is a doc-comment (`CtcModelCache.swift:32`). It can be
dropped (1 MB saving) or left in place harmlessly. **Confirmed.**

**Are dictation-110M and vocab-CTC the same files? NO.** They are two distinct
directories with different file names: dictation `parakeet-tdt-ctc-110m/` has
`Preprocessor` / `Decoder` / `JointDecision` / `parakeet_vocab.json`; vocab
`parakeet-ctc-110m-coreml/` has `MelSpectrogram` / `AudioEncoder` / `CtcHead` /
`vocab.json` / `tokenizer.json`. **Dropping the dictation 110M does not touch the
vocab CTC bundle.** **Confirmed.**

### Live preview — batch vs EOU (Q4, the load-bearing question)

**The live preview is served by the batch `PreviewScheduler` path by default,
NOT by EOU.** The engine is chosen per-recording by `AppGroup.previewSource`
(`RecordingService.swift:379`): `"batch"` → `PreviewScheduler` re-transcribe
loop on the batch model; `"eou"` → `StreamingTranscriptionService` /
`StreamingEouAsrManager`. **The default is `"batch"`** — the getter returns
`"batch"` for any unknown/unset value AND for the literal `"batch"`, with `"eou"`
reachable only if explicitly persisted (`AppGroup.swift:416-425`).
`ARCHITECTURE.md:89,107` documents the same: `"eou"` is "the rollback, exposed in
Settings as the Preview engine picker." **Confirmed.**

Therefore on build 139's default behavior, the preview "pacing every time" the
owner observed is the `PreviewScheduler` re-transcribe (the trailing-window batch
pass, `PreviewScheduler.swift:374` → `TranscriptionService.previewTranscribe`).
**Removing EOU is a pure dead-code + dead-asset cleanup for default users.** The
only behavior change is for a device where the owner had manually flipped the
debug picker to `"eou"` — that rollback path disappears (intended).

Preview inference path: `PreviewScheduler.runTick` → `previewTranscribe(samples:)`
(`TranscriptionService.swift:812`) runs the SAME batch `AsrManager`, applies
paragraphs + filler + number normalization, and **deliberately NOT vocabulary**
(`TranscriptionService.swift:826-828`). Vocab rescoring is CTC inference (cost),
applied only on the stop-pass `transcribe(samples:)`. **Confirmed** — this matches
the memory note "no vocab on preview ticks."

**`StreamingPartial` is a SURVIVOR** — it is the shared presenter used by BOTH
the batch scheduler (`RecordingService.swift:385-389`,
`PreviewScheduler.swift:421`) and the EOU engine. Only its EOU-coupled consumer
class (`StreamingTranscriptionEngine`, the off-MainActor EOU drain at the bottom
of `StreamingPartial.swift:265`) goes; the presenter itself stays.

**Preview-break risk flagged:** none for default users. The one path that would
"blank" is if any code still wrote `previewSource = "eou"`; after the rip that
branch (`RecordingService.swift:418-437`) and the Settings picker
(`SettingsView.swift:391-417`) are deleted, so it's unreachable. The shared
keyboard preview plumbing (`streamingPartialChanged`/`streamingLoadingChanged`
notifications, `streamingPartialText`/`streamingLoading*` AppGroup keys) is
engine-agnostic and **survives**.

---

## KEEP vs REMOVE map

### KEEP (do not touch)
- `Jot/Resources/Models/Parakeet/parakeet-ctc-110m-coreml/` — vocab CTC
  (minimal set: `AudioEncoder` + `MelSpectrogram` + `vocab.json` + `tokenizer.json`).
- `Jot/App/Vocabulary/*` — `CtcModelCache`, `VocabularyRescorerHolder`,
  `CtcKeywordSpotter`, gate/store/provenance. Unchanged (still point at
  `parakeet-ctc-110m-coreml`).
- `Jot/App/Transcription/StreamingPartial.swift` — the presenter (survivor);
  remove only the EOU-coupled `StreamingTranscriptionEngine` consumer at the tail.
- `Jot/App/Transcription/PreviewScheduler.swift` — the batch preview engine.
- `Resources/Models/EmbeddingGemma/` — Ask RAG.
- Shared preview plumbing: `streamingPartialText`, `streamingLoading*` AppGroup
  keys; `streamingPartialChanged`/`streamingLoadingChanged` notifications.

### REMOVE
- **Assets:** `parakeet-eou-streaming/` (214 MB), `parakeet-tdt-ctc-110m/`
  (217 MB). Optionally `parakeet-ctc-110m-coreml/CtcHead.mlmodelc` (1 MB, unused).
- **Files:** `Jot/App/Transcription/StreamingTranscriptionService.swift`
  (whole file — `StreamingTranscriptionService` + the EOU `bundledStreamingDirectory`
  / `modelsExistOnDisk`).
- **`SpeechModelVariant.swift`:** collapse the enum to a single case (or rename
  to a `Language` concept). Drop `.tdtCtc110m`; `.parakeetV2` (or a new
  `.english`) is the sole case; `displayName` already returns "the English model".
- **`TranscriptionService.swift`:** `selectedVersion`/`selectedRepo` → constant
  `.v2`/`.parakeetV2`; `modelDirectory()` → bundled-v2 only;
  `bundledTdtCtc110mDirectory()` → `bundled600mDirectory()`; drop the
  tdtCtc110m-specific branch at `:291` and the bundled-110M comments.
- **`RecordingService.swift:379-437`:** delete the `else` EOU branch + the
  `streamingEngine`/`streamingDrainTask` fields and their teardown; keep the
  `"batch"` body as the unconditional path.
- **`SettingsView.swift`:** delete `SpeechModelVariantPicker` (`:982-1067+`), the
  "Variant" NavigationLink row (`:309-335`), `previewSourceDebugRow`
  (`:391-417`) + its `previewSourceFlag` state/onChange (`:34,68,91-92`); rename
  the "SPEECH MODEL" card label / "Variant" → "Language"; simplify
  `speechModelDisplayName`/`speechModelLocationCopy`/`speechModelFooter` to the
  single bundled 600M ("On your iPhone · about 440 MB"); drop the `streamingService`
  env dependency (`:7,990`) and the `StreamingTranscriptionService.modelsExistOnDisk()`
  conjunct in `speechModelInstalled` (`:451-453`).
- **`JotApp.swift`:** drop `streamingService` state (`:23`), its env injections
  (`:364,374`), and the EOU warm block (`:317-319`).
- **`AppGroup.swift`:** remove `previewSource` key (`:160,416-425`); make
  `speechModelVariant` resolve every legacy tag to the single model.
- **`CrossProcessNotification.swift`:** no EOU-exclusive members — the
  `streaming*` notifications are shared and survive; only update the doc-comment
  that attributes them to `StreamingTranscriptionService`.
- Other EOU references to clean: `AskView.swift`, `RewritePickerSheet.swift`,
  `SetupWizardView.swift`, `ContentView.swift`, `ModelLoadTimekeeper.swift`,
  `RecordingHeroView.swift` (the `previewSource == "batch"` checks become
  unconditional, e.g. `RecordingHeroView.swift:517`).

### Settings / enum / legacy-tag handling (Q5)

Two allowlist switches both default to the OLD model and **both must be flipped**
to the single English/600M model (per the "check legacy guards when reviving"
rule):
1. `AppGroup.speechModelVariant` getter (`AppGroup.swift:392-403`) — change the
   `default:` (and collapse the allowlist) so `"tdtCtc110m"`, `"parakeetV2"`,
   `"nemotron0_6b"`, unset → the single model tag.
2. `SpeechModelVariant.current()` (`SpeechModelVariant.swift:34-36`) — fallback
   to the sole case.

A pre-launch migration is **not required** (the getters normalize on read), and
per the "pre-launch migrations — no flags" rule there are no live users to
migrate. **Schema impact: NONE.** No `@Model` fields/entities touched —
`speechModelVariant`/`previewSource` are `UserDefaults` (App Group), not
SwiftData. State the "Schema impact: N" explicitly in the change.

---

## Size accounting (Q6)

| Change | Δ |
|---|---|
| Remove `parakeet-eou-streaming/` | **−214 MB** |
| Remove `parakeet-tdt-ctc-110m/` (110M dictation) | **−217 MB** |
| (Optional) remove `CtcHead.mlmodelc` | −1 MB |
| Add `parakeet-tdt-0.6b-v2-coreml/` (600M) | **+443 MB** |
| **Net on-disk delta** | **≈ +12 MB** (≈ +11 MB with CtcHead dropped) |

So the uncompressed resource footprint is roughly flat (~+12 MB). The
**compressed IPA / App Store download delta** will differ (CoreML weight
compressibility varies); measure the archived IPA before/after. The 600M v2
Encoder is 425 MB of largely int8 weights.

---

## Risks & ordering (Q7)

### Risks
1. **App Store OTA cellular cap (~200 MB).** The IPA already ships ~530 MB of
   Parakeet + 328 MB EmbeddingGemma, so it is **already far over the cellular
   limit** — this change does not newly cross it, but the app remains Wi-Fi-only
   for download. No regression; note it but it's not introduced here.
   *(Possible — verify current App Store Connect size class.)*
2. **600M folder-name mismatch.** Must vendor as
   `parakeet-tdt-0.6b-v2-coreml` (the `-coreml` suffix), not the App-Support
   `parakeet-tdt-0.6b-v2`, or `AsrModels.repoPath` won't resolve. **Confirmed risk.**
3. **600M RAM wall.** Per memory: 600M is ~2 GB resident; hard wall at 6 GB RAM
   (12 Pro / 14+). Bundling makes the model present on every device, but the
   runtime load must still be gated on dictation surfaces (the existing wall).
   Verify the wall logic survives the rip (it's in the device-capability gate,
   not EOU). *(Likely intact — confirm.)*
4. **Vocab CTC accidental deletion.** The dictation `parakeet-tdt-ctc-110m/`
   and vocab `parakeet-ctc-110m-coreml/` have confusingly similar names. Delete
   ONLY the former. **Confirmed distinct.**
5. **Removing the rollback.** Ripping EOU removes the on-device `"eou"`
   fallback. Acceptable per owner (batch validated through builds 120-139), but
   it's a one-way door — land it only after the owner confirms batch on-device.
6. **Cold 600M load latency for preview.** `PreviewScheduler` already handles a
   cold 30-40s+ load via the capture-first latch (`PreviewScheduler.swift:123-133`),
   so making 600M the only model doesn't introduce a new blank-preview path.

### Ordered implementation sequence
1. **Vendor the 600M** into `Resources/Models/Parakeet/parakeet-tdt-0.6b-v2-coreml/`;
   point `modelDirectory()`/`bundled600mDirectory()` at it; force
   `selectedVersion`/`selectedRepo` to v2. Verify dictation works on-device with
   the bundled 600M (no download). *(Lowest-risk, value-delivering first step.)*
2. **Flip both legacy-tag switches** (`AppGroup.speechModelVariant`,
   `SpeechModelVariant.current()`) to the single model.
3. **Rip EOU:** delete `StreamingTranscriptionService.swift`, the EOU branch in
   `RecordingService`, `JotApp` wiring, `previewSource` key + Settings picker;
   make the batch path unconditional. Remove the `parakeet-eou-streaming/` asset.
4. **Drop 110M dictation:** remove the enum case, the bundled-110M dir, the
   tdtCtc110m branches. Leave `parakeet-ctc-110m-coreml/` (vocab) untouched.
   Run a vocabulary-correction recording to confirm the rescorer still loads.
5. **Settings UI:** remove the model selector + variant picker; rename
   "Variant" → "Language"; simplify the card copy.
6. **Regenerate** (`xcodegen` from `Jot/`), compile, and **wait for the owner's
   on-device test** (dictation + live preview + vocab correction) before
   commit/ship.

### Open items to verify during implementation
- Confirm `parakeet_vocab.json` (v2) is the file the v2 load expects under the
  `-coreml` folder name (it is `ModelNames.ASR.vocabularyFile`,
  `ModelNames.swift:322`). **Likely.**
- Re-measure the **archived IPA** size delta (compressed), not just `du`.
- Grep for any remaining `tdtCtc110m` / `parakeetV2` string literals across the
  keyboard target + tests after the enum collapse.
