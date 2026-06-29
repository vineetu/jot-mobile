# Multilingual dictation — language-based model selection (mobile)

**Status:** design source of truth. 2026-06-27.

> **STATUS UPDATE (2026-06-27, post-review).** A **Settings-only first pass is
> implemented and builds** (`LanguageChoice` + `AppGroup.transcriptionLanguage` +
> language-aware model resolution in `TranscriptionService` + the v3 script hint +
> an interactive Settings picker), shipping **int8 v3 on every device** for owner
> on-device perf testing. An adversarial review corrected three model-resolution
> errors in the original draft — folded in below:
> 1. **There is no `int4` model id in the SDK.** int4 is a download-time
>    `ParakeetEncoderPrecision` of `.v3` (the `.int8` default is what we ship), not
>    a peer `AsrModelVersion`/`Repo`. The first pass correctly uses `.v3` (int8).
>    See §3.1, §5.4.
> 2. **The "~2 GB resident" premise was wrong** (v3 peak ≈150 MB per FluidAudio
>    `benchmarks.md`), and int4 costs +1.12pp WER for ~14 MB RAM. So the **int4
>    low-RAM tier is dropped for v1** — int8 everywhere until an on-device
>    coexists-with-keyboard measurement justifies otherwise. See §4.
> 3. **The `SpeechModelVariant.displayName` "Loading the English model" re-point
>    was chasing dead code** — that string has zero callers; the keyboard strip
>    uses the language-agnostic `ColdStartCopy`. See §5.6.

**Owner goal:** Let the user pick a **dictation language** in the Setup Wizard and
in Settings. English stays on the bundled Parakeet **v2** (zero download); any
European language downloads Parakeet **v3** once (one multilingual model covering
the whole set). Mirror the **already-shipped Jot Mac app** implementation
(`~/code/jot/`, `docs/language-based-model-selection/design.md`) — the Mac is the
reference; this doc is the mobile adaptation.

> **Confidence protocol.** Code claims are cited `file:line`. Tags: **Confirmed**
> (read directly), **Likely** (strong inference), **Unknown** (no evidence).

---

## 0. TL;DR for a reviewer

1. **The Mac already did this and is the blueprint.** `~/code/jot/Sources/Transcription/LanguageChoice.swift`
   + `ParakeetModelID.swift` + `SetupWizard/Steps/LanguageStep.swift` +
   `Settings/LanguagePickerField.swift`. We port the **shape**, not the code
   (Mac is AppKit-flavoured SwiftUI + a different model stack). **Confirmed.**
2. **Same FluidAudio, same API.** Mobile pins FluidAudio **0.14.7** at the exact
   same revision as Mac (`8048812869b0c7c6fa393e564a4fb6f95126ba23`,
   `Jot.xcodeproj/.../Package.resolved`). So the Mac doc's §2 finding holds
   verbatim: every Parakeet TDT `transcribe(...)` overload takes
   `language: Language? = nil` (a **Latin-vs-Cyrillic script filter**, 19 hint
   cases, v3-only). **Confirmed.**
3. **Mobile's advantage over Mac: English needs no download.** Parakeet v2 ships
   **bundled in the IPA** (`TranscriptionService.swift:307`,
   `features.md §6.1`). English = bundled, instant, offline. Only a non-English
   pick triggers a v3 fetch. This is the core mobile UX win.
4. **Mobile has no Nemotron and (v1) no Japanese / Qwen3.** Nemotron was ripped
   from mobile for being too slow on the iPhone ANE (MEMORY:
   `nemotron_too_slow_for_iphone`). The Mac's Japanese + experimental Qwen3
   languages are **out of scope** for mobile v1 (owner: "all ~25 v3 languages").
   So the mobile map is just two buckets: **English → v2 (bundled)**, **European
   → v3 (download)**.
5. **Low-RAM iPhones get v3 int4.** Owner decision: devices that can't hold the
   600M-class v3 (the same devices that today fall back to the 110M English model
   — iPhone 11, 12/13 non-Pro, SE) route multilingual to **`.tdt_0_6b_v3_int4`**
   (~1.1 GB, lower RAM) instead of being locked out. See §4.
6. **The CTC vocab-boost model already exists on mobile** — `CtcModelCache.shared`
   (`VocabularySettingsView.swift:63`). It is the same model the owner added; no
   new "boost" surface is introduced here. Out of scope, mentioned only so the
   reviewer knows it's not part of this work.

---

## 1. Current mobile state (Confirmed, cited)

### 1.1 Model selection is device-driven, English-only
- `TranscriptionService.selectedVersion` / `selectedRepo`
  (`TranscriptionService.swift:125-134`): capable devices → Parakeet v2
  (bundled), sub-6GB devices → Parakeet TDT-CTC 110M (English, fetched on first
  dictation). Chosen by `DeviceCapability.is600MCapable`, **not** the user.
  **Confirmed.**
- `SpeechModelVariant` (`SpeechModelVariant.swift`) is the "language" seam, but
  is English-only today: `current()` always returns `.english`; `displayName`
  is "the English model". The file's own header says *"future languages are a
  single-file change."* This is the type we extend (or replace — §5.4). **Confirmed.**
- Transcription call sites pass **no** language hint:
  `manager.transcribe(samples, decoderState: &decoderState)`
  (`TranscriptionService.swift:647`, `:805`). **Confirmed.**

### 1.2 Persistence
- `AppGroup.speechModelVariant` → key `jot.speech.modelVariant`
  (`AppGroup.swift:199,418-426`). The cross-process App Group store. **Confirmed.**
- No `jot.transcriptionLanguage` key yet — we add one (§6.3).

### 1.3 Wizard
- 7 panels W1–W7, `SetupStep` enum (`SetupWizardView.swift:291-299`):
  `.welcome .microphone .keyboardInstall .howItWorks .tryKeyboard .warmHold
  .youreReady`. Progress dots derive from the ordered sequence. **Confirmed.**
- The old "Download speech model" wizard step was removed when v2 went bundled
  (`SetupWizardView.swift:286-288`). We are **re-introducing a model-ish step**,
  but framed as *language*, and only downloading for non-English. **Confirmed.**

### 1.4 On-demand download path already exists
- `AsrModels.download(...)` into Application Support, gated by
  `modelsExistOnDiskForSelectedVariant()` with a hard **no-silent-download-before-
  consent** rule (App Store Guideline 4.2.3(ii), `TranscriptionService.swift:914`,
  `:235-242`). The non-English v3 fetch rides this exact path. **Confirmed.**
- `BackupExclusion.excludeFluidAudioModels()` already excludes
  `Library/Application Support/FluidAudio/Models/` from iCloud backup
  (`JotApp.swift:217-226`) — v3/int4 land there too, no new exclusion needed.
  **Likely.**

### 1.5 CTC vocab boost — already present, out of scope
- `CtcModelCache.shared` + `VocabularyRescorerHolder` power custom-vocabulary
  rescoring (`VocabularySettingsView.swift:63-71`, `JotApp.swift:201-203`). Same
  model the Mac wizard offers as an optional "boost"; on mobile it already lives
  behind Settings → Vocabulary. **We do not add a boost section to the language
  step.** **Confirmed.**

---

## 2. The language API (inherited verbatim from Mac §2 — same SDK revision)

Because mobile pins the identical FluidAudio 0.14.7 revision, every finding in
the Mac doc §2 applies without re-verification:

- `transcribe(_:decoderState:language:)` exists; `language` is an optional
  `FluidAudio.Language` (19 cases: `en es fr de it pt ro pl cs sk sl hr bs ru uk
  be bg sr`), each mapped to `.latin` or `.cyrillic`. **Script filter only** — it
  is NOT per-language conditioning (Polish vs Czech are identical to the filter).
- The hint is **silently ignored** for v2 / tdtCtc110m / tdtJa; it only does
  anything on v3.
- **25-vs-19 gap:** the v3 *model* advertises ~25 European languages; the SDK
  *hint* enum exposes 19. Languages with no hint case (Danish, Dutch, Finnish,
  Greek, Hungarian, Swedish, …) still transcribe via v3 auto-detect — they just
  get no script filter. **Design rule (v1):** surface the union the model
  supports; pass the hint case if one exists, else `nil`. Do not over-promise
  per-language precision in copy. **Confirmed (Mac), inherited.**

**Verification item before implementation (mobile-specific):** confirm the mobile
FluidAudio build vendors the `.v3` and `.v3 int4` `Repo`/`AsrModelVersion` cases
and the `Language` enum at this revision (the resolved checkout is the same, so
**Likely yes**; the implementer greps the checked-out
`SourcePackages/checkouts/FluidAudio/.../AsrModels.swift` to be certain).

---

## 3. The language → (model + hint) mapping (mobile)

Two buckets only (no Nemotron, no JA, no Qwen3 in v1):

| User-facing language | FluidAudio hint | Model | Download? | Notes |
|---|---|---|---|---|
| **English** | none (v2 monolingual) | **Parakeet v2** (`.parakeetV2`) | **No — bundled in IPA** | Instant, offline, the default for an English locale |
| Spanish, French, German, Italian, Portuguese, Romanian | `.es/.fr/.de/.it/.pt/.ro` | **Parakeet v3** | Yes (~461 MB), once | Latin script filter |
| Polish, Czech, Slovak, Slovenian, Croatian, Bosnian | matching case | v3 | Yes | Latin |
| Russian, Ukrainian, Belarusian, Bulgarian, Serbian | matching case | v3 | Yes | **Cyrillic** filter |
| Danish, Dutch, Finnish, Greek, Hungarian, Swedish (+ other v3 langs w/o hint) | `nil` (auto-detect) | v3 | Yes | Works, no script filter |
| **(any European, on a sub-6GB iPhone)** | same hint | **Parakeet v3 int4** (`.tdt_0_6b_v3_int4`, ~1.1 GB) | Yes | Owner decision §4; lower RAM |

- **One v3 download unlocks every European language.** Switching among them later
  is free (no re-download) — only the persisted language + the runtime hint
  change. The int4 device tier downloads the int4 bundle instead.
- The English bundled v2 cannot be deleted (read-only bundle), exactly as today
  (`features.md §6.1`).

### 3.1 Mobile model resolution — two orthogonal axes (corrected)

The original draft modelled int4 as a third *model*. It isn't. The SDK has
exactly `AsrModelVersion = {v2, v3, tdtCtc110m, ctcZhCn, tdtJa}` (vendored
`FluidAudio/.../TDT/AsrModels.swift:5-13`) — **no int4 case**. int4 vs int8 is a
separate **`ParakeetEncoderPrecision`** passed to `download`/`load`
(`AsrModels.swift` ~232/247/485/498; `downloadVariant = (version == .v3) ?
encoderPrecision.rawValue : nil`, default `.int8`). So resolution is two
independent axes:

```
version:   English → .v2 (bundled) | sub-6GB English → .tdtCtc110m | European → .v3
precision: .int8  (v1: always — for .v3; ignored for v2/110m)
```

```
English  → .v2 (bundled), every device                 // no download
European → .v3 + .int8, every device                   // ~461 MB, downloaded once
```

> v1 (first pass) ships `.v3` int8 on **every** device — no `is600MCapable`
> European fork. The int4 precision is **deferred** (§4): it would only ever be a
> `precision` swap within `.v3`, never a different model id.

When the implementation later threads precision, mobile's `download`/`load`/
`modelsExist`/consent paths (which today never pass a precision and rely on the
`.int8` default — §1.4, H3) must accept the resolved `(version, precision)`.

---

## 4. Device-RAM policy — int8 everywhere for v1 (revised post-review)

The original §4 gated sub-6GB devices down to int4 "for lower RAM." Two findings
killed that rationale:
- **The "~2 GB resident" premise was wrong.** FluidAudio `benchmarks.md` measures
  v3 **peak RAM ≈139–153 MB** (int4 139, int8 153) — a ~14 MB difference, not the
  ~2 GB the old code comment assumed (`TranscriptionService.swift:116-118`).
- **int4 costs real accuracy.** int8 = **2.64% WER**, int4 = **3.76% WER**
  (+1.12pp, ~42% relative) on LibriSpeech. Trading 42% more errors for ~14 MB is a
  bad deal.

**v1 decision (owner): ship `.v3` int8 on every device; drop the int4 tier and the
`is600MCapable` European fork.** The picker is identical on every device. The
int4 precision stays available in the SDK as a future `precision` swap **iff** an
on-device measurement shows int8 v3 can't sit resident alongside the keyboard host
on a sub-6GB iPhone (11 / 12·13 non-Pro / SE).

> **Still open (device test, §9):** measure int8 v3 resident footprint
> *coexisting with the keyboard host* on a sub-6GB iPhone. The ~150 MB peak
> suggests it fits; if it jetsams, the fix is an int4 **precision** for those
> devices (not a new model), or "English-only there." Not pre-committed.

---

## 5. The new UX

### 5.1 Principles (same as Mac §5.1)
- Pick a **language**, never a model. Model identity only in
  Settings → About/Acknowledgements.
- Default selection = **system locale's language if supported, else English**
  (`LanguageChoice.fromSystemLocale`, ported from Mac).
- One `LanguageChoice` type backs **both** surfaces (wizard W2 + Settings §6.1).

### 5.2 Wizard — new "Language" step (W2, after Welcome)

Insert `case language` into `SetupStep` **right after `.welcome`**, shifting
microphone→W3 … youreReady→W8 (8 dots). New file
`Jot/App/SetupWizard/Steps/LanguageStep.swift`.

Layout (follows the Jot wizard handoff system — see the mockup, §7):
- **Title** (Fraunces italic, 29px): "What language will you speak?"
- **Subtitle** (SF Pro): "Jot transcribes on this iPhone, on the Apple Neural
  Engine. You can change this anytime in Settings."
- **Language picker** — a tappable row opening a searchable list of
  `LanguageChoice.presentationOrder` (alphabetical by English name, native
  endonym as secondary text). Default-selected to system locale.
- **Size/readiness line** under the picker:
  - English → "Built in — ready to use, no download." (the mobile win)
  - European, not yet downloaded → "Downloads a ~461 MB model that runs entirely
    on this iPhone." (or ~1.1 GB on int4 devices)
  - European, downloaded → "Ready — runs entirely on this iPhone." ✓
- **Download control:** for a non-English not-yet-downloaded pick, a **Download**
  button → `ProgressView(value:)` + monospaced "NN%" → "Ready ✓". Reuse the
  existing `AsrModels.download` progress path (§1.4). English shows no button.
- **Footer microcopy:** "Jot picks the on-device model for your language
  automatically. You can switch languages later in Settings." (instructional, not
  condescending — MEMORY `feedback_voice_instructional_not_condescending`.)

**Advance gate:** Continue is enabled when the resolved model is on disk.
- English → **always satisfied** (bundled) — English users tap straight through,
  no download. This is the common path and must feel instant.
- European → satisfied once the v3/int4 download completes. Downloading disables
  Continue (mirrors Mac `LanguageStep.updateChrome`).
- **Skip** allowed (mirrors Mac `showsSkip: true`) → leaves them on the
  system-locale default (English for most), downloadable later in Settings.

**Wizard teardown contract is unaffected** — this step starts no recording (the
W5 try-it is the only recording step), so the "release the mic gently on leave"
contract (`CLAUDE.md` Wizard conventions) doesn't apply here. No new teardown.

### 5.3 Settings — make §6.1 "Language" interactive

Today the Settings "Dictation" card has a **non-interactive** "Language" selector
reading "English (the only language today…)" (`features.md §6.1`,
`VocabularySettingsView`/the Dictation settings view). Replace it with an
**interactive** picker bound to the same `LanguageChoice` via the shared store,
plus the same size/readiness line and download/delete affordance for the resolved
model. Wizard and Settings stay in sync because both read/write the one
`jot.transcriptionLanguage` key (§6.3).
- Add a **Delete** affordance for a downloaded European model (frees ~461 MB /
  ~1.1 GB) — but never for English (bundled, undeletable). Mirrors Mac
  `LanguagePickerField`.

### 5.4 New type: `LanguageChoice` (mobile)

New file `Jot/App/Transcription/LanguageChoice.swift`, ported from
`~/code/jot/Sources/Transcription/LanguageChoice.swift` but **trimmed to the
mobile bucket set**: English + the v3 European union. **Drop** the Mac's
`.japanese`, all Qwen3 experimental cases, `qwen3Language`, and `isSpaceless`
(no spaceless scripts in the European set). Keep `displayName` (English —
endonym), `presentationOrder`, `fromSystemLocale`, `fromLanguageCode`,
`fluidAudioLanguage`, and a mobile `modelID()` per §3.1.

Decision: **replace `SpeechModelVariant` with `LanguageChoice`** (the former is
already documented as the "language seam"), OR keep `SpeechModelVariant` as the
device-tier model resolver and layer `LanguageChoice` above it. **Recommend
replace** — one type, fewer resolver sites. **Correction (review M1):**
`SpeechModelVariant.displayName` has **zero callers** outside its own file — the
hero observes `modelState` directly and the keyboard loading strip uses the
language-agnostic `ColdStartCopy` ("Just waking up the model…"). So there is no
"Loading the English model" surface to re-point; a language-named loading label
would be a **new** (optional) affordance, not a regression to guard against. The
first pass left `SpeechModelVariant` in place and added `LanguageChoice` alongside
it (the inert `speechModelVariant` getter, §6.3, is untouched).

```swift
// Sketch — full case list = English + §3 European union.
enum LanguageChoice: String, CaseIterable, Sendable, Identifiable {
    case english
    case spanish, french, german, italian, portuguese, romanian,
         polish, czech, slovak, slovenian, croatian, bosnian,
         russian, ukrainian, belarusian, bulgarian, serbian,
         danish, dutch, finnish, greek, hungarian, swedish

    /// Device-aware. English → bundled v2 (every device). European → v3 on
    /// capable devices, v3 int4 on sub-6GB devices (§3.1, §4).
    func modelID() -> SpeechModelID {
        switch self {
        case .english: return .parakeetV2Bundled
        default:
            return DeviceCapability.is600MCapable ? .parakeetV3 : .parakeetV3Int4
        }
    }

    /// v3-only Latin/Cyrillic script hint; nil for English (v2 ignores it) and
    /// for European langs with no FluidAudio hint case (auto-detect).
    var fluidAudioLanguage: FluidAudio.Language? { /* per §3 table */ }
}
```

### 5.5 Wire the hint at the transcribe call sites
`TranscriptionService.swift:647` and `:805` become
`manager.transcribe(samples, decoderState: &decoderState,
language: activeLanguage.fluidAudioLanguage)`. English/int-tier resolution must
also pick the correct **decoder geometry** — v2 `blankId` and v3 `blankId`
differ; the decoder state must be built from the **active** model's
`fluidAudioVersion`, never a hardcoded version (mirrors Mac §5.5). The mobile
pipeline already derives version from the selected repo; thread the active
`LanguageChoice` → model → version through that same resolver.

### 5.6 Keyboard extension is unaffected
The keyboard never loads an ASR model (60 MB ceiling, `CLAUDE.md`); the **main
app** transcribes and the keyboard reads the result. Language selection lives
entirely in the main app. The only keyboard-visible string is the loading
affordance copy, which is already language-agnostic (`ColdStartCopy`, never names a
model/language — review M1). No model loads in-process; no ceiling risk.

---

## 6. Files, keys, migration

### 6.1 New files
- `Jot/App/Transcription/LanguageChoice.swift` (§5.4).
- `Jot/App/SetupWizard/Steps/LanguageStep.swift` (§5.2).
- (mockup) `docs/multilingual-dictation/mockup/` — HTML/JSX handoff (§7).

### 6.2 Edited files
- `Jot/App/SetupWizard/SetupWizardView.swift` — add `.language` to `SetupStep`
  after `.welcome`; render `LanguageStep`; dots auto-update.
- `Jot/App/Transcription/TranscriptionService.swift` — resolve model+version from
  the active `LanguageChoice` (replacing the device-only `selectedVersion`/
  `selectedRepo` for the European case); pass `language:` at `:647`/`:805`;
  re-point `modelsExistOnDiskForSelectedVariant()` to the resolved model.
- `Jot/Shared/AppGroup.swift` — add `transcriptionLanguage` key + accessor
  (§6.3), mirroring `speechModelVariant`.
- The Settings "Dictation" card view — make the Language row interactive (§5.3).
- `Jot/features.md` §6.1 (+ §13 / §12.3 cross-links) — language picker, multi-
  language, per-device size (§8).
- `Jot/known-bugs-and-plans.md` — index entry pointing here.

### 6.3 Keys
| Key | Status | Notes |
|---|---|---|
| `jot.speech.modelVariant` | **PRESERVE** | Legacy device-tier model tag; readers keep working. |
| `jot.transcriptionLanguage` | **ADD** | Raw `LanguageChoice`. The new source of truth for *language*. |
| `jot.transcriptionLanguage.migrated` | **ADD** | One-shot migration sentinel. |

### 6.4 Migration (no silent clobber)
Mobile is simpler than Mac (no stored per-model choice to grandfather — model is
device-derived, not user-chosen). One-shot, guarded by
`jot.transcriptionLanguage.migrated`, run unconditionally at launch (per MEMORY
`feedback_prelaunch_migrations`, "no users yet → run every launch, flip the flag
**after** success" `feedback_flag_before_work_antipattern`):
- Absent `jot.transcriptionLanguage` → seed from **system locale** (§5.1).
  English resolves to bundled v2 (no download); a non-English locale seeds that
  language but **does not auto-download** (consent gate §1.4) — the model fetches
  only when the user reaches the wizard step / Settings and taps Download, or on
  first dictation in that language.
- No existing-user model to clobber — the device-tier English path is unchanged
  for everyone who never picks a non-English language.

### 6.5 Schema impact (required by `CLAUDE.md`)
- Add/remove/rename `@Model` fields or entities? **No.** The language choice lives
  in App Group `UserDefaults`, not SwiftData. **No `JotSchemaVN` bump, no
  `MigrationStage`.** Transcript records are unaffected (a transcript does not
  store its source language in v1 — flag as a possible future field, out of
  scope).

---

## 7. Mockup (the "specific look")

Built in the established **Jot wizard handoff style** (HTML/React via Babel, the
`docs/wizard-w5-tryit/` convention): 390×844 frame, layered-gradient background,
`WizardChrome` (back ○ · dots · close ○), Fraunces-italic title, SF Pro body,
single blue `#1A8CFF` accent, **light + dark**. File:
`docs/multilingual-dictation/mockup/language-step.html` (self-contained, opens in
a browser). It renders the step's key states:
1. **English selected** — "Built in — ready to use, no download.", Continue active.
2. **Language list open** — searchable, English-name + native endonym rows.
3. **French selected, not downloaded** — "Downloads a ~461 MB model…", Download button.
4. **Downloading** — progress bar + "47%", Continue disabled.
5. **Ready** — "Ready ✓", Continue active.

It is a **look-and-behavior reference**, recreated natively in SwiftUI using real
Jot design tokens — not code to copy (same note as the W5 handoff README).

---

## 8. Ship checklist (per `CLAUDE.md`)
- [ ] `features.md §6.1` — rewrite the "Language (non-interactive)" line into an
      interactive language picker; note per-device size, English-bundled-no-
      download, one-v3-unlocks-all-European. Add cross-links to §13.1
      (on-device), §12.3 (download failure).
- [ ] `features.md §12.3 / §5.x` — non-English download-failure surface (reuses
      the existing speech-model fetch-failure path, `features.md:569`).
- [ ] `known-bugs-and-plans.md` — dual entry → this doc.
- [ ] `ARCHITECTURE.md` — only if a new subsystem/boundary is introduced; this
      reuses existing transcription + wizard subsystems, so **likely a single
      row touch** (the `LanguageChoice` resolver as the new SoT for language).
- [ ] About → Acknowledgements — confirm/extend the model-name surface so the
      v3 attribution appears (`AcknowledgementsView.swift:73` already lists v2).
- [ ] Device test matrix: capable device (v3 461 MB) + sub-6GB device (v3 int4
      1.1 GB) + English-only (no download). On-device per MEMORY
      `feedback_wait_for_on_device_test`.

---

## 9. Risks / open questions (attack these in review)
1. **int8 v3 resident footprint on a sub-6GB iPhone (the only real RAM question).**
   v1 ships int8 v3 everywhere (§4); the open item is whether it sits resident
   alongside the keyboard host on an iPhone 11 / SE without jetsam. `benchmarks.md`
   peak ≈153 MB suggests yes. If not, fix is an int4 **precision** for those
   devices (not a new model) or English-only there. **The first-pass build is the
   vehicle for this measurement** — owner is testing on-device now. (Medium;
   downgraded from High — the old int4-premise risk is deleted, §4.)
2. **Activating the script hint is a behavior change** (today `nil` is passed;
   first pass now passes it for European). Could regress mixed-language edge cases
   (a German speaker quoting an English brand). Needs runtime on-device
   verification (MEMORY: audio-capture changes need device runtime checks, not
   just compile). (Medium-High — **owner is verifying this now**.)
3. **Post-processing chain on v3 (new, review-adjacent).** Mobile runs its
   cleanup chain (number/filler normalization) on the batch transcript; the Mac
   deliberately **skips** that for v3 (it emits clean cased/punctuated text
   natively and the regex pass can regress casing — `jot/features.md §30`). The
   first pass does NOT yet gate the chain off for v3. If non-English output looks
   over-normalized, gate the chain on `LanguageChoice.current.isEnglish`. (Medium
   — first thing to check from the owner's perf report.)
4. **Live preview language mismatch — likely a NON-issue on mobile (review M4
   resolved).** Mac's preview used a *separate English EOU streaming model*, so a
   non-English preview was English-tuned. Mobile uses **batch-pseudo-streaming**
   (the same v3 weights re-run over a trailing window — MEMORY
   `batch_only_streaming`), and the first pass passes the script hint at the
   preview call site too (`:805`), so the preview is the **same model + same
   language** as the final. Decision: **accept as-is for v1**; verify on-device
   that the French preview isn't visibly English. (Low.)
5. **25-vs-19 hint gap** surfaces languages with no script filter (§2). Low — they
   still transcribe via auto-detect; just don't over-promise in copy.
6. **Wizard length** grows W7→W8. Confirm the owner is fine adding a step (the
   step is skippable and instant for English users). (Low.)
7. **Default = system locale vs always English?** §5.1 proposes system-locale.
   For an English-majority audience this means most users get the instant bundled
   path; a non-English-locale user is seeded to their language but not
   auto-downloaded. Confirm. (Low.)

---

## 10. Out of scope (v1)
- Japanese, Mandarin/Cantonese/Vietnamese, and all other Mac Qwen3 experimental
  languages (separate models/engines).
- Nemotron (ripped from mobile).
- An Advanced raw-model picker.
- Per-language post-processing / ITN profiles.
- Storing a transcript's source language on the `@Model` record.
- Localizing the **app UI** into the chosen language (dictation only).
