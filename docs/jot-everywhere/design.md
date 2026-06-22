# Jot Everywhere — Shared Foundation for "Voice Notes Everywhere"

**Status:** DESIGN / brainstorm only. No product code. Owner gates implementation separately.
**Date:** 2026-06-20
**Author:** design study (agent) + owner brief
**Scope:** Make Jot capture + retrieval reachable from every system surface, built on ONE
shared foundation with thin per-surface adapters — not eight separate features.

**Sizing convention** (from `Jot/known-bugs-and-plans.md`): XS / S / M / L.

**Companion docs (READ ALONGSIDE — do not restate):**
- [`docs/carplay/discovery.md`](../carplay/discovery.md) — the CarPlay capture-first plan. It
  ALREADY requires this foundation (B1 AskEngine + B2 TTS + the recording intent). This doc
  treats those as the SAME shared core so CarPlay + Siri + Shortcuts + Control Center all sit
  on it. See §2 "Alignment with CarPlay."
- [`docs/carplay/issue-3-mic-rootcause.md`](../carplay/issue-3-mic-rootcause.md) — the just-shipped
  fix that makes the foreground recording intent reliable (`supportedModes = .foreground(.immediate)`
  + scene-active-deferred mic start). Every surface that "starts a recording" rides on that fix.

---

## 0. Adversarial review corrections (2026-06-20) — folded in

Independent review (`design-review.md`): **sound enough to build Stage A; 4 corrections required
before they drive build decisions.** None block Stage A.

- **MF-1 (important) — Ask is NOT "Qwen-gated."** It defaults to **Apple Intelligence** at
  runtime (`AskController.pickBackend()` :593-613; `isAvailable` = Apple FM available **OR** Qwen
  on disk, :627-632). The `:22-27` "Qwen-only" doc-comment the design cited is **stale**. So
  Ask-via-Siri's real risk isn't "download Qwen first / cold-MLX timeout" (that's only for users
  who switched to Qwen) — it's mapping `pickBackend()`'s `.none(reason)` cases
  (`appleIntelligenceOff` / `deviceNotEligible` / `modelDownloading` / `qwenNotDownloaded`) each to
  a graceful spoken dialog. **AskEngine must return the availability *reason*, not a bare throw.**
- **MF-2 (important) — Kokoro TTS is download-first, NOT bundled like EmbeddingGemma.**
  FluidAudio's `KokoroAneManager.initialize()` downloads 7 mlmodelcs + vocab + voice pack + G2P
  assets (G2P pinned to `~/.cache`, ignores the `directory:` override). EmbeddingGemma is a true
  bundled `type: folder` with no download. So B2 must be an explicit **work item**: verify all
  Kokoro assets (incl. G2P) bundle + load with **zero network** before claiming the
  "only-feedback-leaves-the-device" invariant; the privacy claim is **conditional** until that
  passes on device. (Promotes Q5 to an A3 blocker.)
- **MF-3 — Broken-Siri-phrase root cause is unproven.** Downgrade the "mid-phrase placeholder
  placement" theory from *Likely* to *Possible*, co-equal with index/donation staleness (no
  authoritative Apple source supports the placement theory). The **fix still stands** (broaden to
  boundary-placed phrases — helps under either hypothesis), but it's a hedge, not a proven cure;
  only an on-device pass + cold reinstall proves it.
- **MF-4 — Multi-phrase risks the Action-Button binding.** The single-phrase choice was a
  deliberate iOS-26.2 daemon-bug mitigation (`JotAppShortcuts.swift:58-65`), and the binding-
  critical `AppShortcut` is Jot's just-fixed primary capture path. Add phrases **incrementally
  (start with 2)**, with **"Action Button tile still binds + records" as the gating acceptance
  test** ranked above Siri hit-rate — not a 6-phrase jump.

Verified-correct by the review: headless text-capture path (`TranscriptStore.append`), AskEngine
*is* cleanly extractable (only `@Observable` progress state is view-coupled), Kokoro package
exists, Control widget triggers the foreground intent **without** hitting the issue-#3 mic gate
(it foregrounds first), and **no schema change** is engaged.

## 1. Overview & owner intent

The owner wants Jot's two core capabilities — **capture** (speak → saved transcript) and
**retrieval** (Ask your notes) — available from every place iOS exposes an app: natural Siri
phrases, parameterized Siri text capture, Ask-by-voice, exactly two Shortcuts actions, and a
Control Center / Lock Screen button. Capture is the flagship; Ask is secondary (per the CarPlay
doc §0). The explicit constraint: build a **shared foundation** with **thin adapters**, so each
new surface is a few-hundred-line wrapper over the same engine — never a parallel pipeline.

This doc identifies five reusable building blocks (B1–B5), shows what already exists vs. what is
net-new (with `file:line`), then maps each of the six surfaces (5 surfaces + a deep-link
round-trip) onto the blocks. It ends with a schema-impact section, a staged plan (foundation
first, shared with CarPlay), and open questions.

---

## 2. Alignment with CarPlay (the overlap is the point)

The CarPlay plan ([`discovery.md`](../carplay/discovery.md)) already calls for:
- **B1 AskEngine** — `discovery.md` §4.2 "extract a thin `AskEngine.answer(question:)`" from the
  `@Observable`-entangled `AskController`.
- **B2 On-device TTS** — `discovery.md` §1 Stage 1, FluidAudio **Kokoro** (NOT
  `AVSpeechSynthesizer`), voicing "Saved" + concise Ask answers.
- **The foreground recording intent** — the shared mic-start path (now reliable per issue-3).

These are NOT CarPlay-specific. They are the foundation for ALL of "Jot everywhere."
**Sequencing rule of record:** build B1–B3 once, in the main-app target, BEFORE either CarPlay
Stage 2 or any Siri/Shortcuts/Control surface. CarPlay's Stage 1 == this doc's Stage A. Whoever
ships first pays for the foundation; the second surface is then nearly free. Do not let CarPlay
and Siri build two AskEngines or two TTS wrappers.

| Shared block | Needed by | Pays for itself across |
|---|---|---|
| B1 AskEngine | Ask-via-Siri, "find a transcription" Shortcut, CarPlay Ask | 3 surfaces |
| B2 TTS (Kokoro) | Ask-via-Siri (spoken answer), CarPlay "Saved"/answers | 2 surfaces |
| B3 Headless text-capture | Parameterized Siri capture, "jot down" Shortcut | 2 surfaces |
| Recording intent (exists) | Natural Siri phrases, Control widget, Action Button | 3 surfaces |

---

## 3. The shared foundation (B1–B5)

### B1. AskEngine — headless `answer(question:) async -> (text, citations)`

**What exists.** The full RAG pipeline is implemented and view-decoupled at the data layer, but
the orchestrator is `@Observable` and entangled with `AskView`'s lifecycle:
- `LLMClient.ask(systemPrompt:userPrompt:) async throws -> String` — single final answer string,
  non-streaming (`Jot/Shared/LLM/LLMClient.swift:61`; default-throws extension `:72`; streaming
  variant `askStreaming` `:68`, default falls back to one yield `:80`). **Headless callers want
  the non-streaming `ask()`** — no token UI.
- `AskController.ask()` (`Jot/App/Ask/AskController.swift:226`) → enqueues
  `runPipeline(question:)` (`:266`) → retrieval `retrieveTopK(forQuery:k:dateInterval:)`
  (`:636`) using `EmbeddingGemmaService.shared.encode(...)` + `BM25Index` + RRF fusion
  (`:662`–`:689`), plus the product-help auto-route (`:301`–`:315`) and date-scope parsing
  (`:292`). Retrieval and generation are NOT view-coupled — phases are observable state.
- The controller is `@MainActor @Observable` (`:28`–`:30`) and accumulates into `@Observable`
  properties (`segments`, `answerText`, `phase`, `retrievedTranscripts`, `citedIDs` `:51`–`:120`).
  It is gated behind `#if JOT_APP_HOST` (`:1`) — main-app-only (the keyboard's 60 MB ceiling
  forbids MLX; see `Jot/CLAUDE.md`).

**Net-new (S–M).** Extract a thin, view-free `AskEngine` actor/struct in the main-app target:

```
// prose / pseudocode — NOT Swift
AskEngine.answer(question, options) async throws -> AskAnswer
  where AskAnswer = (text: String, citations: [TranscriptRef], corpus: .notes|.help)

  1. parse date scope (reuse AskController.parseDateScope)
  2. help-route check (reuse HelpCorpusIndex.bestCosine vs bestTranscriptCosine)
  3. retrieve  = retrieveTopK(...) | retrieveByDate(...)   (lift the existing private funcs)
  4. if retrieved.count < relevanceFloor -> return .vague sentinel
  5. answer   = LLMClient.ask(systemPrompt: askPrompt, userPrompt: built(question, retrieved))
                 // non-streaming; no @Observable accumulation
  6. parse [cite: uuid] markers -> citations
  7. return (answer, citations, corpus)
```

The cleanest factoring is to **lift the retrieval helpers** (`retrieveTopK`, `retrieveByDate`,
`parseDateScope`, `normalize`, `dot`, the help-route) into a shared, non-`@Observable`
`AskEngine`, and have `AskController` BECOME a thin `@Observable` view-model that calls
`AskEngine` and mirrors progress into its published props for the streaming UI. That keeps the
on-screen Ask experience (token streaming via `askStreaming`) intact while giving every headless
caller a string-in/string-out entry point. **Risk:** `AskController` is genuinely entangled
(per CarPlay §7 "the `AskEngine` extraction is real work, not free") — budget for a careful
refactor + a parity check that the in-app Ask answer is byte-identical before/after.

**A concise-spoken-answer mode** (shorter, plainer, for TTS) is a separate small prompt — see
B2 and Open Question Q4. AskEngine should accept an `answerStyle: .full | .spoken` option.

### B2. On-device TTS — FluidAudio Kokoro

**What exists.** **No TTS in production today** — full-tree grep finds no `AVSpeechSynthesizer`
/ `AVSpeechUtterance` production hits (the only matches are cosmetic copy + the RMS field
`speechAmplitudeThreshold`). BUT the **FluidAudio package already ships a TTS/Kokoro module** —
confirmed: `FluidAudio` is pinned at `exactVersion: "0.14.7"` (`Jot/project.yml:34`–`36`) and the
checkout contains a `Tests/FluidAudioTests/TTS/` suite (`KokoroAneComputeUnits` presets etc.).
The same package already powers Parakeet ASR + Silero VAD, so TTS stays **on-device, ANE,
same-stack** — preserving the "only feedback leaves the device" invariant
([[only_outbound_is_feedback]]).

**Net-new (M).** A thin `SpokenResponder` (main-app target) over Kokoro: `speak(_:) async` +
`stop()`/interrupt, owning a short-lived playback `AVAudioSession`. Voices the capture "Saved"
confirmation and concise Ask answers. **NOT `AVSpeechSynthesizer`** (owner call; Kokoro is
higher quality + same stack — CarPlay §7 M-fix). Bundle cost: the Kokoro model (~tens of MB) —
flag at build, same out-of-band bundling pattern as EmbeddingGemma (`project.yml` note at the
`CoreMLLLM` ref). **Open risk:** verify the 0.14.7 TTS API surface and model packaging before
committing the bundle-size budget (Q5).

### B3. Headless text-capture path — save a string as a transcript, no UI

**What exists.** The save tail is genuinely headless:
- `TranscriptStore.append(id:raw:cleaned:duration:derivedFrom:instruction:)`
  (`Jot/Shared/TranscriptStore.swift:272`) persists a `Transcript` into the App-Group SwiftData
  store with no SwiftUI view involved.
- `DictationPipeline.completeEndOfRecording(transcript:sessionID:startedAt:stoppedAt:controller:transient:)`
  (`Jot/App/Intents/DictationPipeline.swift:151`) is the shared end-of-recording tail (classify
  → publish → `TranscriptStore.append` `:446`). It is `@MainActor` (`:104`) but view-free.
- The file-transcription intent already proves a headless string→save→return shape:
  `TranscribeAudioFileIntent` (`Jot/App/Intents/TranscribeAudioFileIntent.swift:71`),
  `openAppWhenRun = false` (`:84`), `@Parameter audioFile: IntentFile` (`:91`), returns
  `.result(value:)` (`:163`).

**Net-new (S).** For a string that is ALREADY text (Siri did the STT), we don't need the mic,
the recording controller, or the chained-follow-up classifier. The cleanest path is a small
`HeadlessCapture.save(text:source:)` helper that calls `TranscriptStore.append(...)` **directly**
with `duration: 0` and a synthesized `id` — bypassing `DictationPipeline` entirely (the pipeline's
publish/clipboard/follow-up machinery is for the dictation UX, not a Siri text drop). Decision
note: do NOT route Siri text capture through `completeEndOfRecording` — its clipboard-publish +
keyboard-handoff + follow-up window are wrong for a headless save and would fire cross-process
notifications no one is listening for. Append directly; keep it boring.

### B4. Siri phrase set + AppShortcuts hygiene

Covered in §5 (the broken-phrase root cause + fix) and §6.1 (richer phrases). The "block" here
is really a discipline: ONE `AppShortcutsProvider` (`Jot/App/Intents/JotAppShortcuts.swift:72`),
one phrase per shortcut, every phrase carrying `\(.applicationName)`.

### B5. Control widget — triggers the existing foreground recording intent

**What exists.** The phone has **no Control Center / Lock Screen control today** — the only
WidgetKit extension is the **watch** widget (`JotWatchWidgets`, `project.yml:518`; watch
complications). No `ControlWidget` anywhere in the iOS app. The recording entry point it would
fire already exists and is reliable: `RecordAndTranscribeIntent`
(`Jot/App/Intents/RecordAndTranscribeIntent.swift:47`), `supportedModes = .foreground(.immediate)`
(`:61`), deferred scene-active mic start (`:91`–`:92`).

**Net-new (M).** A new **iOS WidgetKit extension target** (separate from the watch one) hosting a
`ControlWidget` with a single `ControlWidgetButton` whose `AppIntent` foregrounds Jot and starts a
recording. **Critical implementation fact (Apple-confirmed):** the control's `AppIntent` must be
in (or shared with) the MAIN app target, and must use `openAppWhenRun = true` returning
`some IntentResult & OpensIntent`, to actually bring the app forward
([Apple DevForums 764212](https://developer.apple.com/forums/thread/764212)). Jot's recording
intent already has the foreground shape — so the control can simply launch
`RecordAndTranscribeIntent` (or a tiny `LaunchJotCaptureIntent` wrapper that sets
`pendingForegroundStart` and posts `.jotDictateFromShortcut`, exactly as the intent's `perform()`
does today at `RecordAndTranscribeIntent.swift:91`–`92`). No new mic plumbing — it reuses the
issue-3 scene-active path.

---

## 4. Net-new summary (foundation)

| Block | Exists | Net-new | Effort |
|---|---|---|---|
| B1 AskEngine | full RAG pipeline, view-entangled (`AskController.swift:226,266,636`) | extract view-free engine + `.spoken` style option | **S–M** |
| B2 TTS Kokoro | FluidAudio 0.14.7 ships TTS (`project.yml:34`); none wired | `SpokenResponder` + Kokoro model bundle | **M** |
| B3 Headless capture | `TranscriptStore.append` (`:272`), file-intent pattern (`:163`) | `HeadlessCapture.save(text:)` (direct append) | **S** |
| B4 Phrase hygiene | one provider, one phrase (`JotAppShortcuts.swift:76`) | add natural phrases (§6.1) | **XS–S** |
| B5 Control widget | watch widget only; recording intent reliable | new iOS WidgetKit ext + `ControlWidget` | **M** |

---

## 5. The broken Siri phrase — root cause + fix

**Symptom (owner, on device):** "Hey Siri, New Jot note" → *"I don't see an app for that"*, even
though the Spotlight tile works and the intent is registered.

**What's registered.** `JotAppShortcuts.appShortcuts` (`JotAppShortcuts.swift:73`) registers ONE
`AppShortcut` for `RecordAndTranscribeIntent` with a single phrase `"New \(.applicationName) note"`
(`:84`), `shortTitle: "Jot down"` (`:86`). The display name is `Jot` (`project.yml:182`), so the
spoken phrase resolves to **"New Jot note"** with the app name embedded mid-phrase.

**Root-cause assessment (confidence levels per house style):**

1. **Most likely — `.applicationName` placement + Siri's app-name disambiguation (Likely).**
   That the **Spotlight tile works but Siri fails with "I don't see an app for that"** is the
   classic signature of a phrase Siri's *speech* matcher can't bind to the app, even though the
   *visual* shortcut is indexed. Apple's guidance and the DevForums consensus
   ([thread 712095](https://developer.apple.com/forums/thread/712095),
   [WWDC23 "Spotlight your app with App Shortcuts"](https://developer.apple.com/videos/play/wwdc2023/10102/))
   is that every phrase **must** contain `\(.applicationName)` AND that Siri keys off the
   recognized app name to route the utterance. Two compounding factors here:
   - The placeholder is **embedded inside** the phrase ("New **Jot** note") rather than at a
     natural boundary ("Jot, new note" / "New note in Jot"). Siri parses "New Jot note" as one
     blob; if its ASR mis-segments "Jot" (a short, uncommon word) the whole phrase fails to bind
     and you get "I don't see an app for that." Phrases with the app name at the **start or end**
     ("…in Jot", "Jot …") are markedly more reliable in the field.
   - **Only one phrase is registered.** With a single rigid template, any ASR variance ("a new
     Jot note", "new Jot", "make a Jot note") misses entirely. (The current single-phrase choice
     was a *deliberate* iOS 26.2 mitigation — `JotAppShortcuts.swift:58`–`65` — for a
     Shortcuts-daemon commit bug with multi-phrase entries. That tradeoff is what's now costing
     recognition.)

2. **Possible — donation/indexing staleness (Possible).** `AppShortcut` phrases are indexed by
   the on-device AppIntents metadata extractor at install and re-donated as the app runs. If the
   app hasn't been launched since an update, or the Shortcuts/Siri index is stale, phrases can be
   silently unrecognized while the (separately indexed) Spotlight tile still shows. This is
   intermittent and clears after a launch + reindex — consistent with "tile works, voice
   doesn't." (Per [[feedback_intermittent_bug_needs_multiple_repros]], treat a single failed
   utterance as one run, not proof — but the structural phrase issue (1) is the higher-confidence
   cause and worth fixing regardless.)

3. **Ruled out — bad display name (Confirmed not the cause).** `CFBundleDisplayName: Jot`
   (`project.yml:182`) is clean and short; the placeholder resolves correctly. The metadata
   validator requires the placeholder and it's present (`:79`–`:84`), so the build-time
   extraction is not rejecting the phrase.

**Recommended fix (XS–S):** broaden the phrase set with **app-name-anchored, boundary-placed**
variants and accept the multi-phrase risk now that the iOS 26.2 daemon bug is older (re-verify on
device). Concretely, register multiple phrases for the recording shortcut:
- `"New note in \(.applicationName)"`  (app name at END — most reliable)
- `"\(.applicationName) new note"`     (app name at START)
- `"Jot down in \(.applicationName)"`
- `"Take a note in \(.applicationName)"`
- `"Start dictating in \(.applicationName)"`
- keep `"New \(.applicationName) note"` for back-compat.

This directly also satisfies **owner ask #1's "richer/natural phrases"** (§6.1) — the fix and the
feature are the same change. **Must verify on device** (Spotlight tile + each spoken phrase), and
**re-test the iOS 26.2 multi-phrase daemon bug** the single-phrase choice was guarding against —
if it resurfaces, fall back to the 2–3 most natural phrases. Cite the doc-comment rationale at
`JotAppShortcuts.swift:58`–`65` so the next reader knows why multi-phrase was risky.

> Honesty caveat: Siri phrase recognition is empirically flaky and version-dependent; no source
> gives a guaranteed fix. The above raises the hit-rate substantially but the only proof is an
> on-device pass across phrasings and a cold reinstall. Confidence the broadened set fixes the
> symptom: **Likely**, not Confirmed.

---

## 6. Per-surface adapters

Each surface is a thin wrapper over B1–B5. "Adapter effort" excludes the foundation it sits on.

### 6.1 Surface 1 — Richer/natural Siri phrases → existing recording intent

- **Blocks:** B4 (+ the existing `RecordAndTranscribeIntent`).
- **What:** add the natural phrases from §5 to the existing `AppShortcut`
  (`JotAppShortcuts.swift:76`). "Jot down" / "Jot this down" / "Take a note" / "Start dictating",
  each carrying `\(.applicationName)`. This is BOTH the broken-phrase fix AND owner ask #1.
- **Constraint:** this opens the **foreground recording** intent — a visible app-bounce, not
  eyes-free, and Siri may refuse custom intents while in CarPlay/driving (CarPlay §6 Q5). Fine
  for the phone.
- **Adapter effort:** **XS–S.** Verify on device.

### 6.2 Surface 2 — Short parameterized text capture via Siri (headless save)

- **Blocks:** B3 (+ a new parameterized intent).
- **What:** "Hey Siri, jot down buy oat milk." Siri does the STT and hands Jot a **string**; Jot
  saves it HEADLESSLY — no mic, no app bounce. A new intent:

```
// prose / pseudocode
struct JotDownTextIntent: AppIntent {
  static title = "Jot down"
  static openAppWhenRun = false          // headless — no foreground, no mic
  @Parameter(requestValueDialog: "What should I jot down?") var text: String
  static parameterSummary = Summary("Jot down \(\.$text)")
  func perform() async -> some IntentResult & ProvidesDialog {
    HeadlessCapture.save(text: text, source: .siriText)   // B3: direct TranscriptStore.append
    return .result(dialog: "Saved.")     // Siri reads it back; no app TTS needed here
  }
}
```

- **Why this is distinct from Surface 1:** here Siri already has text, so there is **no mic
  privacy gate** (issue-3) — `openAppWhenRun = false`, fully headless, no bounce. This is the one
  surface that gives true hands-free capture on the phone.
- **Hard limit (cite to owner):** Siri's parameter-dictation is capped at SHORT utterances
  (single field, short dictation) — this is for quick notes only. **Long dictation stays on the
  foreground recording intent** (Surface 1). Keep BOTH; they are not redundant.
- **Apple caveat:** parameterized App Intent phrases are the *least* reliable Siri surface —
  parameter recognition is inconsistent ([DevForums 782605, 759909]). Expect the
  "ask-for-the-value" fallback dialog (`requestValueDialog`) to be the common path rather than
  one-shot "jot down X." Design for the two-turn flow as the norm.
- **Adapter effort:** **S** (intent + register a phrase like `"Jot down in \(.applicationName)"`
  bound to `$text`). Net-new beyond B3: just the intent.

### 6.3 Surface 3 — Ask via Siri (spoken/returned answer)

- **Blocks:** B1 (AskEngine) + B2 (TTS, optional — see below).
- **What:** "Ask Jot what I said about the Henderson deal."

```
// prose / pseudocode
struct AskJotIntent: AppIntent {
  static title = "Ask Jot"
  static openAppWhenRun = false                 // headless Q&A; no mic needed (Siri STT)
  @Parameter(requestValueDialog: "What do you want to ask?") var question: String
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let a = try await AskEngine.answer(question, style: .spoken)   // B1
    return .result(dialog: IntentDialog(a.text))  // Siri SPEAKS the dialog — free TTS
  }
}
```

- **TTS decision:** in the **Siri** path, Siri reads the `IntentDialog` aloud for free — so B2
  (Kokoro) is **NOT required** here. B2 is required for CarPlay (template owns the spoken
  response). So Ask-via-Siri can ship on B1 alone; wire Kokoro only if the owner wants Jot's own
  voice on the phone. (CarPlay §4.2 makes the same observation.)
- **Caveats:** (a) Ask is gated on the Qwen weights being on disk (`AskController.swift:22`–`27`)
  — if not downloaded, the intent must return a graceful "open Jot to finish setup" dialog rather
  than failing. (b) Answers can be long; the `.spoken` style (B1) must produce a concise summary
  (Q4). (c) Running Qwen/MLX from an App Intent: the intent must execute **in-process in the main
  app** (MLX can't load in the out-of-process AppIntents extension, and never in the keyboard —
  `Jot/CLAUDE.md` 60 MB rule). Verify the intent runs in the app process or set
  `openAppWhenRun` appropriately; a cold MLX load is multi-second, so Siri may time out — **test
  the cold-Qwen latency against Siri's intent timeout** (real risk; flag).
- **Adapter effort:** **S** on top of B1 (the intent). The cost is B1 itself.

### 6.4 Surface 4 — Exactly TWO Shortcuts actions

Owner was explicit: **two** new actions — one to **jot down** (capture), one to **find a
transcription** (retrieve). The existing `TranscribeAudioFileIntent` (file→text) stays; these are
additive.

- **Action A — "Jot down" (capture).** Reuse the SAME intent as Surface 2 (`JotDownTextIntent`,
  B3). With `isDiscoverable = true` it appears as a Shortcuts action with a `text` input, so users
  chain it ("Get text → Jot down"). One intent serves both Siri-text-capture and the Shortcut.
  **Adapter effort: XS** (it's the Surface-2 intent, just discoverable).
- **Action B — "Find a transcription" (retrieve).** New intent over B1:

```
// prose / pseudocode
struct FindTranscriptionIntent: AppIntent {
  static title = "Find a transcription"
  static openAppWhenRun = false
  @Parameter var query: String
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let a = try await AskEngine.answer(query, style: .full)   // B1 — same engine
    return .result(value: a.text)        // returns a string for the next Shortcut step
  }
}
```
  Decision: "find a transcription" = the **Ask/retrieval engine** returning a synthesized answer
  string (most useful for chaining), NOT a raw transcript list. If the owner wants raw matches
  instead, a lighter variant returns the top-K transcript display texts via the existing
  `retrieveTopK` (`AskController.swift:636`) without the LLM step — cheaper, no Qwen dependency.
  **Recommend the lighter raw-retrieval variant for the Shortcut** (no multi-second MLX load
  inside Shortcuts; deterministic; chainable), and reserve LLM synthesis for the Ask-by-voice
  surface. Confirm with owner (Q3).
  **Adapter effort: S** (intent + decide synthesis-vs-raw).
- **Net:** exactly two new visible Shortcuts actions, both thin over B1/B3. Don't register more.

### 6.5 Surface 5 — Control Center / Lock Screen control

- **Blocks:** B5 (+ existing recording intent).
- **What:** a one-tap Jot button in Control Center / Lock Screen that foregrounds Jot and starts a
  recording (the phone has none today; watch has complications).

```
// prose / pseudocode  (new iOS WidgetKit extension target)
struct JotCaptureControl: ControlWidget {
  body = StaticControlConfiguration(kind: "com.vineetu.jot.capture") {
    ControlWidgetButton(action: LaunchJotCaptureIntent()) {   // intent shared with main app
      Label("Jot", systemImage: "waveform.badge.mic")
    }
  }
}
// LaunchJotCaptureIntent: openAppWhenRun = true; perform() sets
// DictationIntentBridge.pendingForegroundStart + posts .jotDictateFromShortcut
// (identical to RecordAndTranscribeIntent.perform() :91-92) -> issue-3 scene-active start.
```

- **Apple-confirmed requirements** ([DevForums 764212](https://developer.apple.com/forums/thread/764212),
  [WWDC24 "Extend your app's controls across the system"](https://developer.apple.com/videos/play/wwdc2024/10157/)):
  the control's `AppIntent` must be in/shared-with the **main app target** and use
  `openAppWhenRun = true` + `OpensIntent` to foreground the app. Jot's recording intent already
  has exactly this shape — so B5 is mostly target/manifest plumbing, not new mic logic.
- **iOS floor:** Control widgets are **iOS 18+**; Jot targets iOS 26.0 (`project.yml:5`) — no
  floor problem.
- **Constraint:** like Surface 1, this is foreground capture (visible bounce), not headless.
  That's correct here — a Control Center tap that opens Jot to record is the expected UX.
- **Adapter effort:** **M** (new WidgetKit extension target in `project.yml` + the control + a
  shared launch intent). The extension is small (no MLX — it only fires an intent).

### 6.6 Deep-link voice-to-text round-trip for OTHER apps (owner question)

**Question:** can a 3rd-party app invoke Jot for voice→text and get the text BACK without the
keyboard? Today `jot://dictate` is **one-way** — `JotApp.onOpenURL` (`JotApp.swift:391`) parses
`jot://dictate?session=<uuid>` and triggers `triggerAutoStart` (`:449`); it opens Jot and records
but never returns text to a caller. (`jot://rewrite|history|transcript` are also one-way handoffs,
`:399`–`:428`.)

**Options assessed:**

| Option | Mechanism | Returns text? | Effort | UX caveat |
|---|---|---|---|---|
| **x-callback-url** | caller passes `?x-success=callerscheme://...`; Jot appends `&text=...` and opens it after save | **Yes** | **M** | Two visible app-switches (caller→Jot→caller). Caller must register a URL scheme + handle the return. The de-facto standard for this ([spec](https://x-callback-url.com/specification/)). |
| **Clipboard handoff** | Jot records, puts text on the pasteboard, caller reads it | Indirectly | **XS** (Jot already publishes to clipboard — `DictationPipeline` `ClipboardHandoff.publish` `:387`) | No automatic return to caller; user manually switches back + pastes. iOS 16+ shows a paste-permission prompt. Lossy, not a true round-trip. |
| **Share sheet** | Jot finishes, presents share sheet with the text | Indirectly | **S** | User picks the target app manually; not programmatic; wrong direction (Jot→somewhere, not back to a specific caller). |
| **App Intent return value** | the OTHER app calls Jot's intent via Shortcuts and reads `.result(value:)` | Yes, but only inside Shortcuts | already exists (`TranscribeAudioFileIntent` `:163`) | Not a direct app→app call; requires the caller to be a Shortcut, not arbitrary code. And capture needs the mic → foreground bounce anyway. |

**Recommendation:** **x-callback-url is the only real "get the text back" round-trip** for an
arbitrary third-party app, and it's a clean, well-specified extension of Jot's existing
`onOpenURL` router (`JotApp.swift:391`). Implement `jot://x-callback-url/dictate?x-success=...&x-source=...`:
parse `x-success`/`x-error`/`x-cancel` alongside the existing `session` parse (`:439`–`:443`),
stash the success URL, and after the recording's `completeEndOfRecording` save, open
`x-success?text=<percent-encoded transcript>`. **Effort M.** Caveats to set with the owner:
(a) the caller must adopt x-callback-url (most third-party apps don't — this is niche, mostly
power-user / automation-app territory like Drafts/Shortcuts); (b) two visible app-switches and a
mic bounce (unavoidable — issue-3); (c) it's a new public URL contract to support forever.
**Rule out** clipboard/share as the *primary* answer (neither is a true programmatic round-trip),
but clipboard already works today as a manual fallback at zero cost.

**Honest verdict:** technically feasible and clean, but **low-demand**. Recommend documenting it
as a deferred/optional surface unless the owner has a concrete consumer in mind — the five system
surfaces above serve far more users per unit effort.

---

## 7. Schema impact

Per the `Jot/CLAUDE.md` "Schema impact" rule:

- **Does any of this add/remove/rename `@Model` fields or add new `@Model` entities?** **NO.**
- Every capture surface persists through the EXISTING `TranscriptStore.append(...)`
  (`TranscriptStore.swift:272`) → the current `Transcript` schema. Retrieval reads existing
  `Transcript` + `Chunk` rows. TTS, Control widget, Siri phrases, and the deep-link round-trip
  touch no model types.
- **No new `JotSchemaVN` file, no `MigrationStage`.** The frozen-schema discipline
  (`check-schema-frozen.sh`) is not engaged by this work.
- *Possible future exception (not in this design):* if a surface needs to record its **source**
  (e.g. "captured via Siri" vs "via keyboard") for analytics, that's a new optional `Transcript`
  field → would require `JotSchemaV(N+1)` + a `.lightweight` stage. Out of scope; flag only if
  the owner wants provenance. Confidence schema is untouched: **Confirmed** for the designed
  surfaces.

---

## 8. Staged plan (foundation first — shared with CarPlay)

Pseudocode/prose only. Ordered by value/effort; foundation precedes surfaces. **Stage A == CarPlay
`discovery.md` Stage 1** — build it once.

### Stage A — Shared foundation (no entitlement, useful on phone + CarPlay)
- **A1. B3 HeadlessCapture (S).** `HeadlessCapture.save(text:source:)` → direct
  `TranscriptStore.append`. Unblocks the cheapest, highest-value surface (parameterized Siri
  capture) and the "jot down" Shortcut.
- **A2. B1 AskEngine (S–M).** Extract view-free `AskEngine.answer(question:style:)` from
  `AskController`; add `.spoken` concise mode; parity-check the in-app Ask answer. Unblocks
  Ask-by-Siri, "find a transcription," and CarPlay Ask.
- **A3. B2 SpokenResponder / Kokoro (M).** Only needed for CarPlay + (optionally) Jot-voiced Ask
  on phone. Verify the FluidAudio 0.14.7 TTS API + model bundle size first (Q5). Can lag A1/A2 if
  the first surfaces shipped are Siri (which uses Siri's own voice).

### Stage B — Phone surfaces, ranked by value/effort (no entitlement)
1. **B-i. Fix Siri phrases + richer phrases (XS–S)** [Surface 1 + the broken-phrase fix]. Highest
   value, lowest cost, addresses a known on-device failure. Verify on device; re-test the iOS 26.2
   multi-phrase daemon bug.
2. **B-ii. Parameterized Siri text capture (S)** [Surface 2, on A1]. The only true hands-free
   phone capture; headless, no bounce.
3. **B-iii. Two Shortcuts actions (XS + S)** [Surface 4, on A1 + B1]. "Jot down" reuses the
   Surface-2 intent; "Find a transcription" recommended as light raw-retrieval (no MLX in
   Shortcuts).
4. **B-iv. Control Center / Lock Screen control (M)** [Surface 5, on B5]. New WidgetKit ext; fires
   the existing recording intent.
5. **B-v. Ask via Siri (S, on A2)** [Surface 3]. Ships on B1; Siri voices the dialog (no Kokoro
   needed). Gate on Qwen-on-disk + test cold-load vs Siri timeout.

### Stage C — Optional / deferred
- **C-i. x-callback-url round-trip (M)** [Surface 6]. Build only if a concrete third-party
  consumer is identified; otherwise document as deferred.
- **C-ii. Jot-voiced Ask on phone (wire B2 into Surface 3)** — optional polish.
- **C-iii. CarPlay Stage 2** — per `discovery.md`; sits on Stage A. Entitlement-gated (long pole;
  request day one).

**Why this order:** B-i is a near-free fix to a live bug. B-ii/B-iii deliver real
"capture/retrieve everywhere" on the smallest foundation (A1, no TTS, no entitlement). B-iv adds
the most-discoverable surface. Ask-by-voice and CarPlay come once their heavier deps (B1 polish,
TTS, entitlement) land.

---

## 9. Open questions for the owner

1. **Foreground-bounce acceptable on Control Center + Siri capture (Surface 1, 5)?** Both visibly
   open Jot to record (issue-3 mic gate — unavoidable). Only Surface 2 (Siri text) is truly
   headless. Confirm that's the right split.
2. **"Find a transcription" Shortcut — synthesized answer or raw matches?** Recommend **raw top-K
   retrieval** (no MLX inside Shortcuts, deterministic, chainable). LLM synthesis stays on
   Ask-by-voice. Confirm.
3. **Ask-via-Siri cold-Qwen latency.** Multi-second MLX load may exceed Siri's intent timeout.
   Acceptable to require the model be pre-warmed (i.e. Ask-by-Siri only reliable after the user
   has opened Ask once), or should it fall back to "open Jot"? Needs on-device timing.
4. **Concise spoken-answer prompt.** B1 needs a `.spoken` style (shorter, plainer than the
   on-screen answer). Approve a separate small prompt?
5. **TTS bundle budget.** Kokoro adds ~tens of MB. Confirm the FluidAudio 0.14.7 TTS API + model
   packaging before committing (shared cost with CarPlay). If phone-Ask uses Siri's voice and
   CarPlay slips, B2 can be deferred.
6. **Do we want capture-source provenance** ("via Siri" / "via Control Center") on `Transcript`?
   That's the ONLY thing that would touch the schema (a `.lightweight` V(N+1) field). Default: no.
7. **x-callback-url demand.** Any concrete third-party consumer? If not, defer Surface 6.

---

## References

App Shortcuts / Siri phrase recognition + parameterized intents:
- WWDC23 — *Spotlight your app with App Shortcuts* — https://developer.apple.com/videos/play/wwdc2023/10102/
- Apple DevForums 712095 — AppShortcutsProvider phrases not recognized by Siri — https://developer.apple.com/forums/thread/712095
- Apple DevForums 769029 — placeholders / app name in phrases — https://developer.apple.com/forums/thread/769029
- Apple DevForums 782605, 759909 — parameter recognition inconsistency — https://developer.apple.com/forums/thread/782605 , https://developer.apple.com/forums/thread/759909

iOS 18 Control widgets:
- WWDC24 — *Extend your app's controls across the system* — https://developer.apple.com/videos/play/wwdc2024/10157/
- Apple DevForums 764212 — ControlWidget opening the app (LaunchAppIntent in main target + openAppWhenRun) — https://developer.apple.com/forums/thread/764212

x-callback-url:
- Specification — https://x-callback-url.com/specification/
- Apple Support — Use x-callback-url with Shortcuts — https://support.apple.com/guide/shortcuts/use-x-callback-url-apdcd7f20a6f/ios

Mic privacy gate / foreground intent (companion):
- `docs/carplay/issue-3-mic-rootcause.md` (Apple DTS forums/thread/756507, 815725)

Jot source (claims grounded in `file:line`):
- `Jot/App/Intents/JotAppShortcuts.swift:72,73,76,84,86,58-65` (single provider, one phrase)
- `Jot/App/Intents/RecordAndTranscribeIntent.swift:47,61,67,91-92` (foreground recording intent)
- `Jot/App/Intents/TranscribeAudioFileIntent.swift:71,84,91,163` (headless string-in/out pattern)
- `Jot/App/Intents/DictationPipeline.swift:104,151,387,446` (headless save tail)
- `Jot/Shared/TranscriptStore.swift:272` (`append`)
- `Jot/Shared/LLM/LLMClient.swift:61,68,72,80` (non-streaming `ask`)
- `Jot/App/Ask/AskController.swift:1,22-27,28-30,226,266,636,662-689,301-315,292` (Ask pipeline)
- `Jot/App/JotApp.swift:391,399-428,439-443,449` (`onOpenURL` router, one-way today)
- `Jot/project.yml:5,34-36,182,518` (iOS 26.0 floor, FluidAudio 0.14.7, display name "Jot", watch-only widget)
- TTS in FluidAudio 0.14.7: `build/dd/SourcePackages/checkouts/FluidAudio/Tests/FluidAudioTests/TTS/` (Kokoro)
</content>
</invoke>
