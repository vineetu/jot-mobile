# Adversarial Design Review — Jot Everywhere (Shared Foundation)

**Reviewing:** `docs/jot-everywhere/design.md` (2026-06-20)
**Reviewer:** adversarial review agent
**Method:** every code claim re-verified against `file:line`; every external claim
re-verified against current Apple docs / DevForums (URLs cited). Confidence levels per
house style: Confirmed / Likely / Possible / Unknown.

---

## Verdict

**The design is sound enough to start building Stage A (the foundation) now.** The three
foundation blocks on the critical path — B3 headless capture, B1 AskEngine, B2 Kokoro TTS —
are all grounded in code/packages that actually exist (verified: `TranscriptStore.append`,
the view-decoupled retrieval helpers, and FluidAudio 0.14.7's `KokoroAneManager` public actor
are all present). The per-surface adapters are honestly scoped as thin wrappers, and the
schema-untouched claim is correct. **However, four claims are wrong or materially overstated
and must be corrected before they drive build decisions** — most importantly the design's
repeated assertion that **Ask is "gated on Qwen weights on disk"** (it is not; Ask defaults to
Apple Intelligence at runtime), and the **Kokoro "same out-of-band bundling as EmbeddingGemma"**
claim (Kokoro is download-first by default and its G2P assets are hardcoded to `~/.cache` —
bundling it is real, unverified work and a privacy-invariant risk if mis-built). Neither blocks
Stage A; both must be fixed in the doc and budgeted before the surfaces that depend on them.

---

## MUST-FIX

### MF-1 — "Ask is gated on Qwen weights on disk" is WRONG; Ask defaults to Apple Intelligence

**Challenged claim:** §6.3 caveat (a): *"Ask is gated on the Qwen weights being on disk
(`AskController.swift:22-27`) — if not downloaded, the intent must return a graceful 'open Jot to
finish setup' dialog"*; and §6.3 (c) + Open Question Q3, which frame Ask-via-Siri's central risk
as *"a cold MLX load is multi-second, so Siri may time out."* Stage B-v repeats "Gate on
Qwen-on-disk."

**Evidence (Confirmed, code):** `AskController.pickBackend()`
(`AskController.swift:593-613`) defaults to **Apple Intelligence**, not Qwen:
```
if AppGroup.askBackend == "qwen" { ... prefer qwen ... }
// Default: Apple Intelligence (no download), fall back to Qwen if off.
if appleAvailable { return .appleFM }
if qwenAvailable { return .qwen }
```
And `AskController.isAvailable` (`:627-632`) returns `true` whenever **either** Apple FM is
available **or** Qwen weights are on disk. The `askBackend` default is the empty/unset string
(`AppGroup.swift:359-361`), i.e. **not** `"qwen"`, so the default path is Apple FM. The
`:22-27` line the design cites is a **stale doc-comment** ("Ask is **Qwen-only**") that the
actual `pickBackend` code contradicts — the design inherited a wrong comment.

**Why it matters:** the entire Ask-via-Siri risk story is mis-aimed. On a default device Apple
FM self-manages its model (no multi-second cold MLX load, no "download Qwen first" gate). The
cold-MLX-timeout worry and the "open Jot to finish setup" fallback only apply to the **minority
of users who explicitly switched Ask to Qwen** in Settings. The real availability gate is
`SystemLanguageModel.default.availability` (Apple Intelligence off / device-not-eligible /
model-still-downloading), which is a *different* failure set than "Qwen not downloaded."

**Concrete fix:** Rewrite §6.3 (a)/(c), Q3, and Stage B-v to: "Ask availability = Apple
Intelligence available **OR** Qwen weights on disk (`AskController.isAvailable`). The intent
must map `pickBackend()`'s `.none(reason)` cases — `appleIntelligenceOff`, `deviceNotEligible`,
`modelDownloading`, `qwenNotDownloaded` — each to a graceful spoken dialog. The cold-MLX-timeout
risk applies **only** when the user has selected the Qwen backend; for the default Apple-FM
path, test Apple FM's own first-call latency against Siri's intent timeout instead." This also
means AskEngine must surface the *reason*, not a bare throw.

---

### MF-2 — Kokoro is NOT "the same out-of-band bundling pattern as EmbeddingGemma"; it is download-first

**Challenged claim:** §B2 / A3: *"flag at build, same out-of-band bundling pattern as
EmbeddingGemma"*, and the privacy-invariant assurance that TTS "stays on-device … preserving
the 'only feedback leaves the device' invariant."

**Evidence (Confirmed, package source):** FluidAudio 0.14.7 `KokoroAneManager.initialize()`
(`…/FluidAudio/TTS/KokoroAne/KokoroAneManager.swift:53`) calls `store.loadIfNeeded()` whose
doc-comment is literally *"Download (if missing), load all 7 mlmodelcs + vocab + default voice
pack."* It also fetches **English G2P assets** via `KokoroAneResourceDownloader.ensureG2PAssets`
and `G2PModel.shared.ensureModelsAvailable()`, and the comment notes G2P is **pinned to the
hardcoded cache path** `~/.cache/fluidaudio/Models/kokoro/` — `KokoroAneManager`'s `directory:`
parameter is honoured by the mlmodelc store **but NOT by the shared G2P singleton.**

Contrast with the real EmbeddingGemma precedent (`EmbeddingGemmaService.swift:109-120`): it
resolves `Bundle.main.resourceURL/Models/EmbeddingGemma`, throws `modelNotBundled` if absent,
and **never downloads** — bundled as a `type: folder` reference in `project.yml:176`. That is a
genuinely different pattern from Kokoro's download-first default.

**Why it matters:** (1) If Kokoro is shipped without bundling + a directory override, first use
triggers a network download from HuggingFace — a direct violation of
[[only_outbound_is_feedback]] and an App Review 4.2.3(ii) first-launch-download concern (the
same one `project.yml:174` notes Parakeet was bundled to avoid). (2) Even with a bundled
mlmodelc directory, the **G2P assets are loaded from `~/.cache` and will still download** unless
separately staged there at first run — a subtle gap that "same as EmbeddingGemma" papers over.

**Concrete fix:** Demote B2 bundling from "same pattern, just flag it" to an explicit
**verification + work item** in A3: (a) confirm all 7 mlmodelcs + vocab + the default voice pack
**and** the English G2P assets can be bundled and loaded with **zero network**; (b) verify
whether the G2P hardcoded-`~/.cache` path forces a copy-on-first-launch step (it appears to);
(c) only then commit the bundle-size budget. Keep the privacy-invariant claim **conditional**
("on-device *provided the model is bundled and the downloader is bypassed*") until (a)–(c) pass
on device. This is already gestured at in Q5 — promote it from open-question to A3 blocker.

---

### MF-3 — The Siri-phrase "placement" root cause is rated "Likely" but the evidence only supports "Possible"

**Challenged claim:** §5 cause #1, rated **Likely**: that "New **Jot** note" fails because the
`\(.applicationName)` placeholder is **embedded mid-phrase** rather than at a boundary, and that
"phrases with the app name at the start or end … are markedly more reliable in the field."

**Evidence:** The design's own §5 cause #3 correctly **rules out** the missing-placeholder
cause — Jot's single phrase *does* contain `\(.applicationName)` (`JotAppShortcuts.swift:84`,
verified). But the cited sources for the *placement* theory don't actually establish it. DevForums
712095 ([thread](https://developer.apple.com/forums/thread/712095), re-fetched) is about phrases
with **no placeholder at all** — its fix is "add `\(.applicationName)`," which Jot already has.
A targeted search for "applicationName middle vs end placement reliability" returned **no
authoritative Apple source** comparing placements; results explicitly state "the search results
don't contain specific guidance comparing middle-of-phrase versus end-of-phrase placement."
So the placement theory is plausible folklore, not a documented mechanism.

**Why it matters:** The design is owner-visible and the brief demands #1 be "right (or honestly
marked uncertain)." Presenting placement as **Likely** overstates the evidence. Cause #2
(donation/index staleness, rated Possible) is at least as plausible for the exact "tile works,
voice doesn't" signature — a stale Siri/AppIntents index recognizes the visually-donated tile
but not the spoken phrase, and clears after a launch + reindex.

**Concrete fix:** Downgrade cause #1 to **Possible** and present causes #1 and #2 as
co-equal unproven hypotheses. The *recommended fix* (broaden to multiple boundary-placed
phrases) is still correct and survives the downgrade — it's a cheap hedge that helps under
**either** hypothesis (more phrases = more index surface AND boundary placement). Keep the
honesty caveat already in §5 (good), but make the confidence line read "**Possible**, not
Likely; the only proof is an on-device pass + cold reinstall."

---

### MF-4 — The Action-Button-binding regression risk of multi-phrase is understated

**Challenged claim:** §5 / Surface 1 recommends registering **six phrases** on the
`RecordAndTranscribeIntent` `AppShortcut`, treating the iOS 26.2 multi-phrase daemon bug as
"older, re-verify."

**Evidence (Confirmed, code + issue history):** The single-phrase choice was a **deliberate**
mitigation documented at length in `JotAppShortcuts.swift:58-65` (iOS 26.2 Shortcuts-daemon
commit bug → *"Something went wrong, please try again later"*). Separately,
`issue-3-mic-rootcause.md §0` warns that `supportedModes` "could affect Action-Button binding
(historically fragile)" and that the **primary capture entry point rides on this exact
`AppShortcut`.** The design proposes multiplying the phrase count by 6× on the binding-critical
shortcut **without** a rollback gate.

**Why it matters:** If the multi-phrase daemon bug resurfaces, it doesn't just lose Siri
phrases — it can break the **Action Button tile binding** that is Jot's just-fixed primary
capture path (issue #3). That's a regression on the flagship capability, not a cosmetic Siri
miss. The design mentions falling back to "2-3 phrases" but buries it.

**Concrete fix:** Stage B-i must (a) add phrases **incrementally** (start with 2: one boundary
each end) and **verify Action-Button binding still works after each addition**, not jump to 6;
(b) make "Action Button tile still binds + records" the **gating acceptance test**, ranked above
Siri phrase hit-rate; (c) cite `JotAppShortcuts.swift:58-65` in the change so the next reader
knows the history (the design already says to do this — elevate it to a hard checklist item).

---

## NICE-TO-HAVE

- **NTH-1 — AskEngine extraction is real but the doc could name the *specific* couplings.**
  The design's "headless `answer()`" is achievable (see VERIFIED-2), but the cleanest call-out
  for the implementer: the four reusable pieces (`parseDateScope` is already `static`, so free;
  `retrieveTopK`/`retrieveByDate` are instance methods that touch only
  `ModelContext(JotModelContainer.shared)` + `ChunkStore`/`EmbeddingGemmaService`, no view state;
  `pickBackend`/`buildUserTurn`/`instructionsBlock` are `static`). The **only** genuinely
  view-coupled parts are the `@Observable` progress mutations (`phase`, `segments`, streaming
  `onCumulative`) — a headless caller just drops those and awaits the final string. Worth stating
  so the refactor isn't over-budgeted.

- **NTH-2 — `HelpCorpusIndex` / `ChunkStore` actor isolation for the headless path.** AskEngine
  calling `runHelpLane`'s dependencies (`HelpCorpusIndex.shared.bestCosine`,
  `EmbeddingGemmaService.shared.encode`) is fine, but confirm these are callable off the Ask
  view's `@MainActor` without deadlock when invoked from an intent's `perform()` (also
  `@MainActor`). Likely fine (they're `async`), but call it out as a parity-test item.

- **NTH-3 — `RecordingService` is `.record`, not `.playAndRecord` (TTS-on-phone only).** For the
  *phone* surfaces this is moot (Siri voices the dialog; no app-owned playback). But if C-ii
  ("Jot-voiced Ask on phone" via Kokoro) is ever built, note that
  `RecordingService.swift:1262` sets `.record / .measurement / [.mixWithOthers]`, and the CarPlay
  doc (§7 M4) records that `.playAndRecord` was **removed after an AURemoteIO failure.** Kokoro
  playback needs its own short-lived playback session — already gestured at in B2's
  "owning a short-lived playback `AVAudioSession`," good; just cross-link the M4 history.

- **NTH-4 — Deep-link round-trip privacy.** §6.6's x-callback-url verdict ("feasible but
  low-demand, defer") is sound and honors the privacy invariant (no off-device transmission — the
  text round-trips between local apps via URL). One addition: a third-party caller driving Jot
  capture means **arbitrary apps can trigger the mic-foreground bounce** — note that this is
  user-visible (the bounce + mic indicator) so it's not a silent-capture risk, but the new public
  URL contract should validate/encode the `x-success` scheme to avoid open-redirect-style abuse.

- **NTH-5 — known-bugs-and-plans.md registry.** Per `Jot/CLAUDE.md` and
  [[project_plans_index]], when this leaves design, the broken-Siri-phrase item (a live
  on-device bug) should get a dual entry in `Jot/known-bugs-and-plans.md`, not just live in this
  doc — otherwise it isn't discoverable as a known bug.

---

## VERIFIED CORRECT

- **VC-1 — B3 headless capture path exists and is clean.** `TranscriptStore.append(...)`
  (`TranscriptStore.swift:272`, signature confirmed incl. `id`/`raw`/`cleaned`/`duration`/
  `derivedFrom`/`instruction`) persists with no view. The design's decision to call it
  **directly** and bypass `DictationPipeline.completeEndOfRecording` for a pure-text Siri drop is
  correct: the pipeline's tail does clipboard publish, cross-process keyboard handoff, follow-up
  classification, and stats (`DictationPipeline.swift:151-200`) — all wrong for a headless text
  save. No dedup/session-id assumption is broken because `append` synthesizes a fresh `id` and
  the keyboard only reacts to session IDs it's waiting on (`:193-200`). **Caveat (minor):**
  `TranscriptStore`/`JotModelContainer` are `#if JOT_APP_HOST`-gated (main-app only,
  `TranscriptStore.swift:51`), so `HeadlessCapture` must live in the main-app target — which is
  fine, since AppIntents without a separate extension run in the app process (verified: the only
  app-extensions are `JotKeyboard` and `JotWatchWidgets`, `project.yml:294,519` — no AppIntents
  extension).

- **VC-2 — B1 AskEngine is genuinely extractable.** Verified line-by-line: retrieval
  (`retrieveTopK` `:636`, `retrieveByDate` `:1052`), date parsing (`parseDateScope` `:806`,
  static), backend pick (`pickBackend` `:593`, static), prompt build (`buildUserTurn` `:1082`,
  static), help-route (`bestTranscriptCosine` `:463` + `HelpCorpusIndex`) are **not view-coupled**
  — they read `ModelContext`/`ChunkStore`/embeddings and return values. The `@Observable`
  entanglement is confined to progress mutation (`phase`/`segments`/`onCumulative`,
  `:377-447`). A headless `answer()` awaiting the final string is real work but not blocked by
  hidden view state. The design's "S-M + parity check" sizing is honest. (See MF-1: the engine
  must return the unavailability *reason*, not just text.)

- **VC-3 — B2 TTS package exists.** FluidAudio is pinned `exactVersion: "0.14.7"`
  (`project.yml:36`); the checkout is at tag `v0.14.7`
  (revision `8048812869b0…`, matches `Package.resolved`); `Sources/FluidAudio/TTS/` contains
  `KokoroAne`, `PocketTTS`, `StyleTTS2`, `Magpie`; `KokoroAneManager` is a `public actor` with
  `synthesize(...)`. The "FluidAudio ships TTS, same stack" claim is **Confirmed.** (Bundling it
  is the open risk — MF-2.)

- **VC-4 — B5 Control widget feasibility.** Confirmed against Apple sources: a
  `ControlWidgetButton` opens the parent app when its `AppIntent` is in the **main app target**,
  uses `openAppWhenRun = true`, and returns `some IntentResult & OpensIntent` (DevForums
  [764212](https://developer.apple.com/forums/thread/764212) accepted answer: *"your
  LaunchAppIntent must be included in main target"*; corroborated by WWDC24 10157). Critically,
  this **does NOT hit the issue-#3 background-mic gate**: the control *opens* (foregrounds) the
  app, then the existing scene-active deferred mic start runs — exactly the issue-3 fix path
  (`RecordAndTranscribeIntent.swift:91-92`). iOS 18+ floor is satisfied (Jot targets 26.0,
  `project.yml:5`). Effort "M" (new WidgetKit ext) is honest.

- **VC-5 — Schema untouched.** Confirmed: every capture surface routes through the existing
  `TranscriptStore.append` → current `Transcript` schema; no `@Model` field/entity changes. Per
  `Jot/CLAUDE.md` schema rules, no new `JotSchemaVN`/`MigrationStage` is engaged. The doc's
  flagged future exception (capture-source provenance → `.lightweight` V(N+1)) is correctly
  scoped **out**. **Confirmed.**

- **VC-6 — Foundation/issue-3 alignment.** The intent shape the design leans on is real and
  current: `RecordAndTranscribeIntent` uses `supportedModes = .foreground(.immediate)`
  (`:61`) with deferred scene-active start (`:91-92`), matching `issue-3-mic-rootcause.md §0`.
  The design correctly treats the recording intent as "exists + reliable" and builds the control
  + Siri phrases on it rather than inventing new mic plumbing.

- **VC-7 — Surface 2 headless / no-mic claim.** Correct: a parameterized
  `@Parameter text` intent with `openAppWhenRun = false` (or its 26.0 `supportedModes`
  equivalent) never starts the mic — Siri did the STT — so it sidesteps the issue-3 gate
  entirely. The design's caveat that parameterized intents are the *least reliable* Siri surface
  (expect the two-turn `requestValueDialog` flow) is a fair, well-cited expectation-set.

---

## Explicit calls requested by the brief

- **#1 (Siri phrase fix correctness):** The **diagnosis is partially mis-rated** (MF-3): the
  missing-placeholder cause is correctly ruled out, but the mid-phrase-placement cause is
  presented as "Likely" without authoritative support — downgrade to "Possible," co-equal with
  index-staleness. The **recommended fix (broaden to boundary-placed phrases) is sound** and
  helps under any hypothesis — but ship it **incrementally with Action-Button-binding as the
  gating test** (MF-4), not as a 6-phrase jump. Honest bottom line: the fix is a reasonable
  hedge, the root cause remains unproven, and only an on-device pass + cold reinstall proves it.

- **#2 (AskEngine extractability):** **Confirmed extractable** (VC-2). The retrieval, date,
  backend-pick, and prompt-build helpers are already view-free; the only coupling is `@Observable`
  progress state, which a headless caller drops. The one substantive correction is MF-1: the
  engine must expose the **availability reason** (Apple-FM-off / device-ineligible /
  model-downloading / Qwen-not-downloaded), because Ask is **not** Qwen-gated by default — it
  defaults to Apple Intelligence. Size "S-M + parity check" is honest.
