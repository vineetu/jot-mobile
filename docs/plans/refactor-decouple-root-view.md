# Refactor: decouple the monolithic root view (`ContentView`)

> **Status: PLANNED — still pre-design.** Original seed committed 2026-06-03.
> **Refreshed 2026-06-14** to reconcile with work that landed since the seed
> (batch pseudo-streaming, the vocabulary/correction subsystem, the unified
> cold-start/warm path, wizard W5, and the new cross-process App-Group surface).
> Still needs the full brainstorm → design → design-review pass before any code.
> This doc is the seed + a reality map, **not** the design.

> **How to read the refresh:** the original *Why / Goal / Non-goals / Approach
> options / Sequencing* are still valid and are preserved verbatim below. The new
> material is the **"Current architecture (2026-06-14)"** section — a component and
> cross-process map the design pass must respect — plus refreshed **Constraints /
> assumptions** and a consolidated **Open questions** list. Where the original seed
> made an assumption that has since been overtaken (the in-app paste bug, the model
> lineup), the stale part is marked **SUPERSEDED** rather than deleted, so the
> rationale survives.

---

## Why (the problem, in one line)

`ContentView` is a **~1,266-line god-view** (was 1,244 at seed time) that owns
**~37 pieces of state** and presents **every** screen through itself (home,
transcript Edit, Ask, Settings, Help, hero, wizard — via 3 `navigationDestination`s
+ 3 sheets + a cover). Because the root **observes `recordingService.isRecording`**
(for the home FAB↔"Recording" pill swap + stop animation), any recording-state
change re-evaluates the root's body — and that re-evaluation **cascades into
whatever screen is currently presented**, even though those screens read nothing
about recording.

**Exhibit A:** the in-app dictation **dropped-paste** bug. Stopping a keyboard
dictation inside Jot's Edit pane / Feedback field flips `isRecording`, the root
re-runs, the focused text field (a "passenger" in the root's tree) is perturbed and
loses its keyboard connection for a frame, and the paste no-ops. In any *other* app
this never happens — the host doesn't re-render when Jot stops. The bug is a
*symptom* of the shared-observing-root coupling.

This is the SwiftUI version of the Massive-View-Controller anti-pattern. It's an
extremely common drift (SwiftUI nudges you toward piling `@State` on the root;
there's no built-in router/coordinator), and the app shipped ~100 features this
way — but it has hit the complexity wall where the coupling costs more than it
saves.

> **SUPERSEDED context (kept for rationale):** the seed framed this refactor as the
> *follow-on to the in-app dictation paste fix*, predicated on an in-process insert
> bridge (`FocusedFieldInsert`). That whole inline-dictation engine has since been
> **removed** — see `Jot/CLAUDE.md` "DICTATION ARCHITECTURE — unification COMPLETE"
> and `docs/plans/unify-keyboard-dictation.md`. In-Jot keyboard dictation now
> behaves exactly like the keyboard in any other app (record in app → insert into
> the focused field on stop); there is no registration layer and no in-process
> insert bridge left to delete. **What this means for the refactor:** the "delete
> the bridge once the field is isolated" payoff in the original Sequencing section
> is moot (the bridge is already gone). The *coupling* this refactor targets is
> still real — a stop inside a Jot field still flips `isRecording` and still
> re-runs the root body — so the decoupling goal stands on its own; it's just no
> longer gated on, or rewarded by, the paste-bridge deletion.
> **OPEN QUESTION (owner review): with the inline engine removed, is the
> dropped-paste symptom still reproducible on device, or did unification already
> resolve the user-visible bug — leaving this refactor as a pure-hygiene
> "prevent future passenger cascades" effort rather than a bug fix?**

## Goal

Volatile state changes in one surface must **not** re-render unrelated surfaces. A
stop on Home must not touch a field in Settings/Edit/Feedback. Concretely: no screen
should be a "passenger" in another screen's re-evaluation.

## Non-goals

- Not a rewrite. The individual screen views (`SettingsView`, `AskView`,
  `TranscriptDetailView`, …) are **already separate** and stay as-is. This is about
  the **root** that hosts/observes them, not the leaves.
- Not a visual/UX change. Pure structural decoupling; every flow behaves
  identically.
- Not a change to any subsystem *behind* the root — batch pseudo-streaming, the
  vocabulary/correction pipeline, warm-hold, the wizard. Those are mapped below
  only so the design knows what observation they push *through* the root.

---

## Current architecture (2026-06-14) — what the decoupling must account for

The seed predates several subsystems that now flow state through (or alongside) the
root. The design pass must treat this section as the map of "what observes what."
None of these are in scope to change; they define the **volatile reads** that
currently re-run, or could re-run, the root body.

### A. What `ContentView` actually observes / owns today

Confirmed by reading `Jot/App/ContentView.swift`:

- `@Environment(RecordingService.self)` — the load-bearing one. Reads
  `recordingService.isRecording` (FAB↔pill swap, `.animation(value:)`, hero
  teardown `.onChange`) and `recordingService.isPipelineInFlight` (guards in the
  dictate-tap observer). **This is the cascade source the seed named.**
- `@Environment(StreamingPartial.self)` — injected into the tree (`ContentView`
  declares it and seeds a default in previews). This is the live-preview text
  channel. **See section B — the preview *source* changed; the env object is the
  same SwiftUI surface.**
  > **OPEN QUESTION (owner review): does `ContentView`'s body (or only the hero
  > leaf) currently *read* `streamingPartial`'s published text? If the root merely
  > injects it but the hero is the only reader, the preview channel is already
  > leaf-scoped and the design can leave it alone. Confirm on device by
  > instrumenting root-body re-eval during a live preview tick.**
- A `@State` swarm (~37): `navPath`, `searchText`, `semanticSearch`, `askController`
  + `showAskSheet` + `askAvailable`, `showSettings`, `showHelp`,
  `pendingRerunAfterDismiss`, selection-mode set (`isSelectionMode`,
  `selectedTranscriptIDs`, `pendingBulkDeletionIDs`, `pendingCombineIDs`),
  copy/haptic transients, `showRecordingHero` + `heroIntent`, `isWizardPresented`,
  `donationCardVisible`, the dictate-tap observer handle, and the warm-hold-nudge
  pair (`warmHoldNudgeVisible` + its observer).
- **Presentation surface:** 3 `navigationDestination`s (hero via
  `isPresented:$showRecordingHero`; transcript Edit via `for: UUID.self`; keyboard
  rewrite via `for: KeyboardRewriteRouter.KeyboardRewriteTarget.self`), 3 sheets
  (Settings, Help, Ask), and the wizard cover.
- **Cross-process observers installed on the root:** the unified keyboard
  dictate-tap observer (`updateDictateTapObserver`, armed/disarmed on
  `isWizardPresented`) and the warm-hold-nudge observer
  (`CrossProcessNotification.warmHoldNudgeChanged` → `refreshWarmHoldNudge`).

> **OPEN QUESTION (owner review): the warm-hold-nudge mirror (`warmHoldNudgeVisible`
> + observer) and the dictate-tap observer both live on the root today. Are these
> in scope to relocate as part of the decoupling (e.g. into a coordinator or a
> dedicated leaf), or explicitly out of scope? They are "root-resident
> cross-process listeners," which is a different smell than the passenger-cascade
> the seed targets.**

### B. Live preview is now **batch pseudo-streaming**, not EOU streaming

This is the biggest map change since the seed. Per `docs/plans/batch-only-streaming.md`:

- The live preview during a recording is produced by **re-transcribing a trailing
  window with the batch model** (`PreviewScheduler` → `TranscriptionService`'s
  `previewTranscribe(samples:)`), not by a separate streaming model. The scheduler
  consumes the same per-slice 16 kHz mono chunk queue the old engine drained;
  pause = commit trigger, with a 5 s volatile-refresh timer and a 15 s window cap as
  fallbacks; the saved transcript is always the full-file batch pass on **stop**.
- The legacy **EOU 120M streaming engine** (`StreamingTranscriptionService`) is
  **kept only as a rollback**, selected by the `AppGroup.previewSource`
  ("eou" | "batch") A/B flag. Direction is batch-only; EOU is on death row.
- **Preview ticks deliberately do NOT run vocabulary rescore** (it's CTC inference,
  not cheap text — review finding F2). Vocab correction is applied to the **saved**
  transcript on stop, not to preview text.
- **For the refactor this means:** the preview text the root injects via
  `StreamingPartial` is now sourced from `PreviewScheduler`, and ticks can arrive on
  a sub-second cadence. If the root body reads that text, the cascade is *worse*
  than the seed assumed (the seed only worried about the discrete `isRecording`
  flip; preview ticks are continuous). If only the hero reads it, no change.
  Resolving the OPEN QUESTION in section A is therefore load-bearing for scoping.

### C. Vocabulary & correction subsystem (new since seed)

Lives in `Jot/App/Vocabulary/*`, `Jot/Shared/CorrectionBridge.swift`, and the
keyboard's `CorrectionReviewStrip`. Plan: `docs/plans/adaptive-vocabulary-correction.md`.

- **Main-app side:** `VocabularyStore` / `VocabTerm` (the user's terms),
  `VocabularyGate` + `CommonWords` (plausibility filter so common English words
  don't get false-replaced), `VocabularyRescorerHolder` + `CtcModelCache` (the CTC
  aux model — bundled, ~99 MB, **independent of the primary speech model**, runs the
  rescore on the saved transcript), `CorrectionStore` + `CorrectionProvenance` +
  `CorrectionInbox` + `CorrectionReviewModel` (provenance, verdict application,
  review UI in `TranscriptDetailView` via `CorrectionReviewSection`),
  `MarkedTranscriptText` (the marked-up display), `CorrectionAsksPublisher`.
- **Cross-process bridge** (`CorrectionBridge`): after a saved dictation the main
  app **publishes ≤3 "asks"** (highest-value gated words) into the App Group keyed
  by `sessionID`; the keyboard's `CorrectionReviewStrip` shows a post-dictation
  nudge; the keyboard **enqueues verdict events** back; the app drains + applies them
  (`CorrectionInbox`) into provenance + `CorrectionStore`. Notified via
  `CrossProcessNotification.correctionAsksReady`. Keys: `jot.correction.asks`,
  `jot.correction.verdicts` (bridge-local, same App-Group suite).
- **Relevance to the refactor:** this subsystem mostly lives *below* the root —
  the review section is inside `TranscriptDetailView` (a leaf), not the root. The
  refactor risk is the inverse of the seed's: when the **Edit pane** is presented
  and a correction-verdict drain mutates the displayed transcript, the root must
  **not** be in the re-eval path. This is exactly the "passenger in another screen"
  failure mode, just driven by a different state source than recording.
  > **OPEN QUESTION (owner review): is the correction subsystem in scope for the
  > decoupling at all, or is it only listed here as a "don't perturb the Edit pane"
  > constraint the design must verify? It introduces no root-level `@State` today,
  > so the default assumption is: constraint, not in-scope work.**

### D. Cold-start / warm subsystem + wizard W5 + heartbeats

- **Unified warm path:** `TranscriptionService.warmIfNeeded()` is the single
  warm entry point, called from `JotApp` at launch and on scene-active, and from the
  wizard. `ColdStartCopy` owns the "this is the slow part" line + `revealThreshold`
  (2.5 s) so a fast warm load never flashes an affordance; the line is written to
  `AppGroup.streamingLoadingVariantLabel` and rendered by **both** the recording
  hero and the keyboard loading strip. (The variant *label* is model-agnostic —
  "the English model" — see Constraints.)
- **Streaming-loading mirror (cross-process):** `streamingLoadingVariantLabel`,
  `streamingLoadStartedAt`, `streamingLoadEstimateSeconds` let the keyboard render
  the **same** calibrated "Loading…" progress bar the hero shows; change-notified
  via `CrossProcessNotification.streamingLoadingChanged`.
- **Wizard W5** (`Jot/App/SetupWizard/`, the 7-panel W1–W7 flow): W5 is the
  **keyboard try-it** step. The keyboard can't capture audio, so a Dictate-tap in W5
  starts a recording in the **main app**; the wizard owns its own dictate-tap
  observer for the duration (the root *drops* its observer while
  `isWizardPresented`, per `updateDictateTapObserver`). `AppGroup.wizardActive`
  (key `jot.setupWizard.w5Active`) is the cross-process flag set true only while W5
  is on screen. **Wizard contract:** any W5 recording is released gently via
  `recordingService.cancel()` before dismiss (never `forceStop()`).
- **Keyboard-active heartbeat:** `AppGroup.keyboardActiveHeartbeat`
  (`jot.keyboard.active.heartbeat`) — wall-clock `Date` the keyboard writes while
  active (mirror of `appForegroundHeartbeat`), so the app can tell whether the
  keyboard process is live. Paired ping/pong:
  `CrossProcessNotification.keyboardForegroundPing` / `.appForegroundPong`.
- **Relevance to the refactor:** the wizard already correctly **transfers
  observation ownership** off the root while it's up — arguably the closest thing in
  the codebase to the coordinator pattern the seed proposes. The design should study
  this as prior art and make sure any router it introduces keeps the wizard's
  "I own the dictate tap while presented" contract intact.

### E. New cross-process App-Group keys / Darwin notifications (since seed)

The decoupling must not break these contracts (all in `Jot/Shared/AppGroup.swift`
+ `CrossProcessNotification.swift`). Catalogued so the design treats them as fixed
boundaries:

| Surface | Key(s) / Notification | Owner → reader |
| --- | --- | --- |
| Batch-preview A/B | `previewSource` (`jot.preview.source`), `liveTextSetting` (`jot.preview.liveText`) | app ↔ scheduler / DeviceCapability |
| Live preview text | `streamingPartialText` + `streamingPartialChanged` | app → hero/keyboard |
| Loading mirror | `streamingLoadingVariantLabel` / `…LoadStartedAt` / `…LoadEstimateSeconds` + `streamingLoadingChanged` | app → keyboard/hero |
| Wizard W5 | `wizardActive` (`jot.setupWizard.w5Active`) | app ↔ keyboard |
| Keyboard liveness | `keyboardActiveHeartbeat`, `appForegroundHeartbeat` + `keyboardForegroundPing`/`appForegroundPong` | keyboard ↔ app |
| Correction bridge | `jot.correction.asks` / `jot.correction.verdicts` + `correctionAsksReady` | app ↔ keyboard |
| Warm-hold nudge | `warmHoldNudgeShouldShow` / `warmHoldNudgeSuppressed` + `warmHoldNudgeChanged` | app → home (root-resident mirror) |
| Pipeline phase | `pipelinePhase` + `pipelinePhaseChanged` | app → keyboard/watch |

> **OPEN QUESTION (owner review): of these, the only one mirrored into root `@State`
> today is the warm-hold nudge (section A). Should the decoupling design audit ALL
> of these for accidental root-level subscriptions, or trust that the rest already
> terminate in leaves / the keyboard process?**

---

## Approach options (to be weighed in design)

*(Unchanged from seed — still the live menu. Annotations added where the new
architecture sharpens an option.)*

1. **Scope the observation (smallest first step).** Move `ContentView`'s
   `isRecording` reads (FAB/pill swap + `.animation(value:)`) into a small leaf
   subview that observes `isRecording` itself, so a stop re-renders only that leaf.
   May be *necessary-but-not-sufficient* if other volatile reads (the **batch
   preview text** via `StreamingPartial`, pipeline phase, the warm-hold-nudge
   mirror) also re-run the root body — verify on device. **[Refresh note: the
   "other volatile reads" list is now concretely: batch preview ticks (B),
   `isPipelineInFlight`, and the warm-hold-nudge mirror (A).]**
2. **Router / coordinator pattern.** A thin navigation coordinator owns
   presentation; screens are pushed/presented without sharing the home view's body.
   Each screen roots its own observation. **[Refresh note: the wizard's
   own-the-observer-while-presented pattern (D) is local prior art for this.]**
3. **Per-surface roots.** TabView / independent scene roots so screens don't share a
   re-evaluating parent at all.
4. **Move recording observation off the root entirely** — only the small surfaces
   that actually need live recording state subscribe to it.

## Constraints / assumptions (refreshed 2026-06-14)

These are guard-rails for the design pass, not the design.

- **No behavior change.** Every push/sheet/cover flow must behave identically and be
  re-tested per surface on device.
- **Cross-process contracts are frozen boundaries.** The App-Group keys + Darwin
  notifications in section E must keep working across the refactor; the keyboard is
  a separate process and cannot be refactored "along with" the root.
- **The wizard W5 observer-ownership contract** (section D) must survive: while the
  wizard is presented, the root must not also observe the dictate tap.
- **Model lineup — CORRECTED (was stale in the seed era).** The current direction
  (`docs/plans/batch-only-streaming.md` FINAL DIRECTION) is **600M (Parakeet v2,
  English) as the single primary model for everything (preview + final)**. The
  **110M (TDT-CTC) is NOT a user-facing variant** — at most a grandfathered fallback
  consideration for sub-6 GB devices, and the live direction is a **hard wall** at
  the 6 GB line (`DeviceCapability.is600MCapable`, `physicalMemory ≥ 4.6e9`), not a
  compat mode. **The Settings model picker is being removed entirely.** The CTC aux
  model used for vocabulary rescore is a *separate* bundled model and is unrelated to
  this primary-model choice — it stays.
  > **OPEN QUESTION (owner review): the CODE still reflects the OLD lineup —
  > `SpeechModelVariant` is a live two-case enum (`tdtCtc110m` default + `parakeetV2`
  > opt-in) read at every session boundary, and `AppGroup.speechModelVariant`
  > (`jot.speech.modelVariant`) is still persisted/branched-on. So the "600M-only,
  > no picker" direction is DECIDED but NOT yet implemented in this worktree. For
  > this refactor: should the decoupling assume the new (single-model, no-picker)
  > world, the current (two-variant + picker) world, or be written to survive the
  > transition? The picker removal touches `SettingsView`, which the root presents.**
- **Language selection — NEW direction.** Move to **language selection from the UI**
  ("English" available now; European + CJK "coming soon"), with the **model
  auto-selected by device**, rather than exposing model *variants* to the user. The
  user-facing label is the language ("the English model"), never a size/codename.
  > **OPEN QUESTION (owner review): is the UI language selector shipped, in-flight,
  > or purely planned? I found NO `languageSelection` / "coming soon" UI in code
  > (only `displayName` returning "the English model" and English-word vocab
  > helpers). If it's not built yet, this refactor only needs to ensure a future
  > language picker has a clean home below the decoupled root — confirm that's the
  > intended scope.**

## Sequencing

> **SUPERSEDED prereq (kept for rationale):** the seed's prereq was *"the in-app
> dictation paste fix ships first … then we delete the in-process insert bridge."*
> That bridge no longer exists (unification removed the whole inline engine — see
> the SUPERSEDED note under **Why**). The remaining sequencing is just the standard
> design discipline below.

- **Coordinate with the batch-only-streaming and model-picker-removal work.** Both
  touch surfaces the root presents (the hero's preview source; Settings' model
  picker). Decoupling on top of a moving Settings/hero is churn; the design should
  decide whether to land *after* those settle or to scope around them.
  > **OPEN QUESTION (owner review): sequence this refactor BEFORE or AFTER the
  > batch-only-streaming rip + Settings model-picker removal land? They overlap on
  > the hero and Settings surfaces.**
- Then: brainstorm → design (`docs/decouple-root-view/design.md`) → design-review →
  implement with per-surface verification (every push/sheet/cover flow re-tested on
  device).

## Open questions for design

*(Consolidated — includes the seed's originals plus the refresh's. The inline
`> OPEN QUESTION` markers above are the authoritative list; this is the index.)*

1. Which option (1–4), or a staged combination (1 now, 2/3 later)?
2. Does scoping `isRecording` alone stop the cascade, or do the **batch preview
   ticks** / `isPipelineInFlight` / warm-hold-nudge-mirror reads also re-run the
   root? (Instrument the root's body re-eval on a stop AND during a live preview to
   find out.) *(seed Q, sharpened)*
3. **[SUPERSEDED]** ~~Can the in-process insert (`FocusedFieldInsert`) be deleted
   once the field is isolated?~~ — moot; the inline engine and bridge are already
   removed. Replaced by: **is the dropped-paste symptom still reproducible
   post-unification?** (inline marker under **Why**.)
4. Does the root actually *read* `StreamingPartial`'s text, or only inject it?
   (Section A.)
5. Are the root-resident cross-process listeners (warm-hold nudge, dictate tap) in
   scope to relocate? (Section A.)
6. Is the vocabulary/correction subsystem in-scope work, or only a "don't perturb
   the Edit pane" constraint? (Section C.)
7. Should the design audit ALL the App-Group/Darwin subscriptions for accidental
   root subscriptions? (Section E.)
8. Single-model/no-picker world vs current two-variant world vs transition-proof?
   (Constraints — model lineup.)
9. Is the UI language selector shipped/in-flight/planned, and is its only refactor
   relevance "give a future picker a clean home"? (Constraints — language.)
10. Sequence before or after batch-only-streaming + model-picker removal?
    (Sequencing.)
