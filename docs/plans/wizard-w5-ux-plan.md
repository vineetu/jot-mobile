# Wizard W5 "Try it" — front-end UX plan (pre-warm + device gate)

> ## ⚠️ SUPERSEDED ON UX BY THE CLOUD DESIGN HANDOFF (2026-06-14)
> The hi-fi handoff in [`docs/wizard-w5-tryit/`](../wizard-w5-tryit/README.md) (`README.md` +
> `src/tryit-*.jsx`, mirrored from `~/Downloads/design_handoff_tryit_step`) is now the **source of
> truth for look + behaviour**. Where this older doc disagrees, the handoff wins. The sections below
> stay useful for the **engineering grounding** (force-stop contract, `modelState` signal, device gate,
> file:line citations, Reduce-Motion fallbacks) — read them for *where the code lives*, not for the UX.
>
> **Canonical flow = 6 micro-states, one screen, title "Now try the keyboard" constant:**
> `invite → rise → init(first-time-setup) → stream → stop → done`. Owner-confirmed, with two
> decisions locked 2026-06-14:
>
> 1. **GUIDED TAP, not auto-record.** User taps the *glowing* practice field → Jot keyboard rises →
>    taps the (glowing) **Jot down** pill to start recording. We do NOT auto-start on step entry (that
>    was this older doc's idea; the handoff replaces it). One action at a time.
> 2. **`init` (First-time setup) is CONDITIONAL on `modelState`, NOT a fixed 30–40 s.** We pre-warm at
>    wizard open (`SetupWizardView.onAppear`), so by the time the user taps Jot-down the model is often
>    ready or nearly so. At Jot-down: **check `TranscriptionService.modelState`** — `.ready` → skip
>    `init`, stream immediately; not ready → show `init` for the *residual* wait only. The designer
>    assumed the full cold load because he didn't know about pre-warm; `isFirstRun` in the JSX ≡
>    **`!modelReady`** in our build.
> 3. **`init` pane = "First-time setup" label + ONE pulsing dot + a single Fraunces-italic koan line.
>    NO progress bar, NO waveform, NO %.** (This overrides §3/§7 below, which still describe the old
>    `LoadingPlaceholderText` linear bar — DO NOT use the bar in W5.) NOTE: the proto's `SetupNote`
>    (`tryit-tokens.jsx:115`) HARDCODES the first line *"This is the slow part. It's the only slow
>    part."* — the 5-line `KOAN_LINES` array (`tryit-screen.jsx:5-11`) exists but is NOT wired to
>    rotate. OPEN: actually rotate per-load vs commit to the single line. Also: the decided pane has
>    **NO caption** (the "Only happens once. Keep talking." caption in `MicrocopyCard` is stale; README
>    §99-104 + `SetupNote` render none). `WaveMeter` (`tryit-tokens.jsx:101-108`) is dead — do not wire.
> 4. **"We tidy this up when you stop" shows ONLY while streaming** (`stream`/`stop`). During `init`
>    the pane label stays "First-time setup". Consistent with the streaming-off rule (hide the tidy-up
>    line when there's no live text).
> 5. **Words stream IN THE KEYBOARD PANE, not in the practice field.** The field stays empty (caret)
>    until the final **paste** on Stop (`done`). App/extension split: pane + transport render in the
>    **keyboard extension**; wizard chrome + practice field render in the **containing app**.
> 6. **No auto-advance** — `done` dwells on "It works ✓"; user taps **Continue** themselves (delete the
>    `onAdvance()` poll branch at `TryKeyboardStep.swift:147-150`). (This part of the old doc still holds.)
>
> Still-open / unchanged from §9: device-gate strictness (Q3), gate placement as a pre-W1 takeover (§6).

Status: **DESIGN / UX SPEC** — no implementation code. Builds on the feasibility research in
[`docs/plans/wizard-model-prewarm.md`](wizard-model-prewarm.md) (pre-warm is feasible and already
substantially true via the launch warm; recommended hook = `SetupWizardView.onAppear`,
`SetupWizardView.swift:133`). This doc is the **UX layer on top** of that: what the W5 screen shows,
says, and animates while the model warms and the user dictates — plus the device gate.

Scope: redesign of **W5 (`tryKeyboard`)** in `TryKeyboardStep.swift`, a device-gate screen, and the
pre-warm's *user-facing* surface. The pre-warm engineering (where to call `warmUp()`) is settled in
the prewarm doc and not re-derived here.

---

## 0. Grounding (cited)

- **W5 today** (`TryKeyboardStep.swift:38-156`): static title "Now try the keyboard" + body, a *dead*
  `TextField(text: .constant(""))` (`:107`) that never shows the dictated text, a "Listening for your
  text…" / "Got it" status line (`:53-56`), and a **poll on `ClipboardHandoff.readFresh()`** that
  **auto-advances** to W6 after a 600 ms beat (`:144-150`). Recording is *not* started by this step —
  it's started by the wizard host's keyboard-tap observer (`SetupWizardView.handleKeyboardDictateTapped`,
  `:177-201`) only after the user taps Jot-down in the keyboard.
- **Force-stop-on-leave contract** is implemented twice and must be preserved:
  `SetupWizardView.closeAndComplete()` (`:227-240`) and `TryKeyboardStep.onDisappear` (`:70-101`, incl.
  the 2 s late-flip reaper). Any new auto-record we add **must** be reaped by the same hooks.
- **Loading visual language to reuse** (do not reinvent): `LoadingPlaceholderText`
  (`RecordingHeroView.swift:1082-1145`) = steady italic-serif "Loading [variant]…" headline + the
  calibrated asymptotic `ProgressView(.linear)` paced by `ModelLoadTimekeeper.estimatedSeconds`
  (`ModelLoadTimekeeper.swift:38-61`) + a reassurance line; and `SteppingEllipsis`
  (`TranscribingText.swift:164-214`) = a label trailed by 3 calm stepping dots (0.45 s/step, 1.8 s loop,
  static under Reduce Motion).
- **Live transcript text** to show in the box = `TranscribingText` (`TranscribingText.swift:66-144`),
  the same word-by-word reveal the hero and keyboard strip use.
- **Model readiness signal**: `TranscriptionService.modelState` (`TranscriptionService.swift:95`,
  enum `:31-35` → `.notLoaded / .loading / .ready / .failed`) — `@Observable`, injected into the wizard
  as `transcriptionService` (`SetupWizardView.swift:46`).
- **Device gate source of truth**: `DeviceCapability.is600MCapable` (`DeviceCapability.swift:23-25`,
  `physicalMemory >= 4.6e9`). Owner two-line policy (`:19-22`): **official** support = iPhone 14 Pro+;
  the 12 Pro→14 Plus band is best-effort. The gate **copy** promises only the official line.
- **Tokens** (`JotDesign.swift`): `jotPageInk` (`:663`), `jotPageInkSecondary` (`:672`), `jotInk`
  (`:47`), `jotMute` (`:56`), `jotAccent` (`:38`), `jotSuccessInk` (`:75`), `jotCtaBlue*` (`:641-647`),
  `JotDesign.Surface.key` (`:448`), `JotSemanticIcon.privacyOnDevice[Shaded]` (`:729-732`),
  `Spacing.tileHeroSize` (`:843`); type: `frauncesSemiBold` (`:318`), `frauncesItalicText` (`:330`),
  `displaySerif(_:)` (`:801`). All chrome (back/close) already uses `Surface.key` via `WizardChrome`.
- **Voice rules** (CLAUDE.md + features.md §4.5): instructional, not condescending; light theme default;
  no file/framework names in user copy; one paragraph per idea.

---

## 1. What changes (summary of intent)

| Today | New |
|-------|-----|
| Dead text box, never shows words | Box shows the **live transcript** as words arrive (`TranscribingText`) |
| Recording starts only when user taps Jot-down | **Auto-starts recording on step entry** so it's already capturing when they reach the keyboard |
| No model-loading affordance | **"Warming up" init state** (reuses hero Loading bar + stepping ellipsis) shown only while `modelState != .ready` |
| Auto-advances to W6 on first dictation | **No auto-advance** — dwell on a **success ✓** state, user taps **Continue** themselves |
| User must invent what to say | **5 rotating sample lines** to read aloud |
| (none) | **Device gate** screen for sub-6 GB / pre-14-Pro hardware |

---

## 2. W5 State Machine

Six states. The driver inputs are: `modelState` (`.loading`→`.ready`), whether the **auto-record**
recording is live (`recordingService.isRecording`), whether **live preview text** has arrived (non-empty
`streamingText`), and whether a **final dictation** landed (`ClipboardHandoff.readFresh()` newer than
entry — the existing signal, repurposed from *auto-advance trigger* to *success trigger*).

```
          (step entry: start pre-warm already in flight + auto-record)
                                   │
              ┌────────────────────┴─────────────────────┐
              │ modelState != .ready                       │ modelState == .ready
              ▼                                            ▼
        ┌───────────┐                               ┌──────────────┐
        │ A WARMING │  ──model .ready & no words──▶ │ B READY-WAIT │
        └───────────┘                               └──────────────┘
              │                                            │
              │ first preview words arrive (either state)  │ first preview words arrive
              └──────────────────┬─────────────────────────┘
                                 ▼
                         ┌──────────────┐   final dictation lands
                         │ C CAPTURING  │ ───(handoff fresh)────────▶ ┌────────────┐
                         │  (live text) │                              │ D SUCCESS ✓ │ ──tap──▶ W6
                         └──────────────┘                              └────────────┘
                                 │ no words AND no keyboard tap within ~20s (B/A only)
                                 ▼
                         ┌──────────────┐
                         │ E NUDGE      │ (keyboard-not-opened-yet hint; non-blocking)
                         └──────────────┘
            (any state, model load fails → F ERROR, non-fatal, capture-first still works)
```

State-by-state:

### A — WARMING (model not ready yet)
- **When:** `modelState ∈ {.notLoaded,.loading}` on/after entry. First-time install on a cold launch: ~few
  seconds for the bundled 110M; longer only on a 600M re-run (prewarm doc §4.3, edge E5).
- **On screen:** title + the **init affordance** (reused hero language): steady serif headline
  "Warming up the engine…" + the calibrated `ProgressView(.linear)` bar + the reassurance line. The sample
  card is **already visible** (user can start reading immediately — audio buffers through the load,
  capture-first).
- **Affordance:** Continue button present but **disabled** (see §5). Box region shows the warming card,
  not the dead field.
- **Transitions:** → **B** when `modelState==.ready` and no words yet; → **C** the instant preview words
  arrive (warm finished mid-utterance — see edge §7).

### B — READY-WAITING (model ready, recording live, no words yet)
- **When:** `modelState==.ready`, auto-record running, `streamingText` empty.
- **On screen:** title + body instruction + sample card + a calm `SteppingEllipsis` line
  "Listening …" (replaces today's static "Listening for your text…").
- **Affordance:** Continue **disabled**.
- **Transitions:** → **C** on first words; → **E** if ~20 s pass with no words and no keyboard-tap seen.

### C — CAPTURING (live text)
- **When:** non-empty `streamingText`.
- **On screen:** the box now renders **`TranscribingText`** with the live, word-by-word reveal + stepping
  tail (the same component the hero/keyboard use), in `jotInk` on the `Surface.key`/material box.
- **Affordance:** Continue **disabled** (we still wait for a *finalized* dictation so the success beat is
  honest). Optional: enable Continue here too if the owner prefers (open Q1).
- **Transitions:** → **D** when the finalized handoff lands (user tapped Stop in the keyboard).

### D — SUCCESS ✓ (it worked — DWELL, no auto-advance)
- **When:** fresh `ClipboardHandoff` newer than entry (the existing detection, `:141-143`).
- **On screen:** box freezes on the final transcript (full ink, tail dropped); a green check + line
  "That's it — your words, typed for you." in `jotSuccessInk`. Title may soften to "It works."
- **Affordance:** Continue **enabled** and **emphasised** (full-gradient pill). **The user taps it.**
  No timer fires. This is the whole point of removing auto-advance — let them register what happened.
- **Transitions:** → W6 on tap only.

### E — NUDGE (recording but keyboard not opened yet)
- **When:** in A/B, ~20 s elapsed, still no words and no `keyboardDictateTapped` seen.
- **On screen:** keep the sample card; append one instructional micro-line (NOT a rhetorical scold, per
  the voice rule): "Tap the field, then the globe key, and pick Jot." Mic stays live (capture-first).
- **Affordance:** Continue stays disabled; **"I tried it"** secondary affordance available (see §5) so a
  stuck user is never trapped.
- **Transitions:** → **C** on words; dismisses itself once words flow.

### F — ERROR / TIMEOUT (model failed to load)
- **When:** `modelState==.failed`.
- **On screen:** swap the warming headline for "Hmm — the engine didn't start. You can still continue and
  try dictation from any app." Non-fatal; capture-first means nothing the user said is lost if it recovers.
- **Affordance:** Continue **enabled** (don't trap them in onboarding over a model load); a quiet "Try
  again" retriggers `warmUp()`.
- **Transitions:** → W6 on Continue; → A/B if a retry succeeds.

---

## 3. Layout — ASCII wireframes (tokens named)

Shared frame = `WizardPanel` (`WizardChrome.swift:338`): wallpaper, 7-dot progress row (current=4),
back chevron + close X (both `Surface.key`), bottom CTA + home indicator. Body lives in the scroll slot.

### A — WARMING
```
┌─────────────────────────────────────────────┐
│ ‹            • • • • ● • •              ✕     │  WizardHeader .core(current:4)
│                                               │
│           Now try the keyboard                │  WizardItalicTitle 28 · jotPageInk
│  Tap the field, switch to Jot via the globe,  │  WizardBody 15 · jotPageInkSecondary
│  then tap Jot down.                           │
│                                               │
│  ┌─────────────────────────────────────────┐ │
│  │ Read one aloud:                          │ │  sample card · Surface.key box
│  │  “Today's plan: be brilliant, take a     │ │  line 26 displaySerif · jotPageInk
│  │   nap, repeat.”                          │ │
│  │                              ↻ another    │ │  jotMute 13 · tap to rotate
│  └─────────────────────────────────────────┘ │
│                                               │
│  Warming up the engine…                       │  serif 26 italic · jotPageInkSecondary
│  ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░                     │  ProgressView .linear · jotPageInkSecondary
│  Keep talking — your words are saved and       │  15 · jotPageInkSecondary @0.85
│  appear the moment it's ready.                 │
│                                               │
│              [   Continue   ] (disabled .55)  │  WizardPrimaryButton isDisabled
│                   ──────                       │  WizardHomeIndicator
└─────────────────────────────────────────────┘
```

### B — READY-WAITING (model ready, no words)
Same as A but the warming block is replaced by:
```
│  Listening …                                  │  SteppingEllipsis · jotMute · frauncesItalicText 13
```

### C — CAPTURING (live text in the box)
```
│  ┌─────────────────────────────────────────┐ │
│  │ I just said this whole sentence without   │ │  TranscribingText · jotInk 16 · material+Surface.key
│  │ touching a key …                          │ │  word-by-word reveal + stepping tail
│  └─────────────────────────────────────────┘ │
│  Listening …                                  │  SteppingEllipsis (tail of the live capture)
│              [   Continue   ] (disabled)      │
```
(The live box REPLACES the static reading-card visually once capture begins, or sits directly below it —
open Q2. Recommended: the same box morphs from "read this" prompt → live transcript, one container.)

### D — SUCCESS ✓ (dwell)
```
│              ✓  It works.                      │  jotSuccessInk check + WizardItalicTitle
│  ┌─────────────────────────────────────────┐ │
│  │ I just said this whole sentence without   │ │  final transcript · jotInk · full ink, no tail
│  │ touching a key.                           │ │
│  └─────────────────────────────────────────┘ │
│  That's it — your words, typed for you.       │  jotSuccessInk · frauncesItalicText 13
│                                               │
│              [   Continue   ]  ◀── enabled    │  full jotCtaBlue gradient, emphasised
└─────────────────────────────────────────────┘
```

### Device gate (see §6)
```
┌─────────────────────────────────────────────┐
│                                       ✕       │  close only (no dots, no back)
│                                               │
│              ◇  (privacyOnDevice tile)         │  IconTile · tileHeroSize
│                                               │
│        Jot needs a newer iPhone               │  WizardItalicTitle 32 · jotPageInk
│  Jot's on-device speech engine needs an       │  WizardBody · jotPageInkSecondary
│  iPhone 14 Pro or newer for now. We'll let     │
│  you know when more devices are supported.     │
│                                               │
│              [  Got it  ]                      │  WizardPrimaryButton → dismiss/close
└─────────────────────────────────────────────┘
```

---

## 4. Copy (final, in Jot's voice)

- **Title (A/B/C):** "Now try the keyboard" (unchanged).
- **Body (A/B):** "Tap the field, switch to Jot via the globe key, then tap Jot down."
- **Sample-card lead:** "Read one aloud:" · rotate affordance label "another" (with ↻ glyph).
- **The 5 sample lines** (refined for cadence + read-aloud ease; one clause each, punchy):
  1. "I am awesome — and apparently a fast talker."
  2. "Mary had a little lamb whose fleece was white as snow."
  3. "Remind me to buy coffee, eggs, and a little optimism."
  4. "I just said this whole sentence without touching a key."
  5. "Today's plan: be brilliant, take a nap, repeat."
- **Warming headline (A):** "Warming up the engine…"
- **Warming reassurance (A):** "Keep talking — your words are saved and appear the moment it's ready."
  *(Tightened from the hero's line; instructional, not a nudge.)*
- **Listening line (B/C):** "Listening" + stepping ellipsis.
- **Nudge (E):** "Tap the field, then the globe key, and pick Jot." *(States the how-to; no rhetorical "why
  don't you" — per the voice memory.)*
- **Success title (D):** "It works."
- **Success line (D):** "That's it — your words, typed for you."
- **Error (F):** "Hmm — the engine didn't start. You can still continue and try dictation from any app."
  + quiet "Try again".
- **Continue button:** "Continue" (disabled until D — see §5). Secondary escape: "I tried it" (text button,
  `WizardSecondaryTextButton`) available from E and after a long dwell, so nobody is trapped.
- **Device gate:** title "Jot needs a newer iPhone"; body "Jot's on-device speech engine needs an iPhone 14
  Pro or newer for now. We'll let you know when more devices are supported."; CTA "Got it".

---

## 5. Auto-advance removal + Continue gating

- **Remove** the auto-advance: in `TryKeyboardStep.startPolling` the fresh-handoff branch must **no longer
  call `onAdvance()`** (`:147-150`). It instead flips the step into **state D (success)** and **stops**.
- **Continue gating (recommended):** Continue is **disabled** in A/B/C and **enabled only in D** (after a
  finalized dictation) and **F** (error escape). Rationale: the success dwell is the teaching moment; an
  always-tappable Continue lets users skip past the one "aha" we built the step for. BUT we must never
  *trap* a user whose dictation silently fails →
- **Escape hatch:** a `WizardSecondaryTextButton("I tried it")` appears beneath Continue once the user has
  been on the step a while (e.g. ≥15 s, or in state E). It advances unconditionally. This preserves today's
  manual-skip affordance (`:62`) without it being the primary path.
- **Open Q1:** enable Continue already in **C** (live text present) vs only in **D** (finalized)? Recommend
  **D** for an honest "it worked," but C is defensible if finalization latency annoys testers.

---

## 6. Device-gate placement + copy

**Placement: a launch-time gate, NOT a wizard step.** Reasons:
- The whole app is unusable on sub-bar hardware (batch-only-streaming is 600M-only, hard 6 GB wall per the
  MEMORY note), so gating *inside* the wizard would still let them finish setup into a broken app.
- It should appear **before W1** when `!DeviceCapability.is600MCapable`, as a terminal full-screen takeover
  presented in place of the wizard / home. No progress dots, no back — only a close/"Got it" that
  re-presents the same gate (there's nowhere else to go). It reuses `WizardWallpaper` + `IconTile`
  (`privacyOnDevice`) + `WizardItalicTitle` + `WizardBody` + `WizardPrimaryButton` so it feels native, but
  it is its own screen, not a `SetupStep` case.
- **Copy** promises only the **official** line (14 Pro+), per `DeviceCapability` note `:19-22` — the
  best-effort 12 Pro→14 band is deliberately not advertised. (Open Q3: do we *hard-block* the 12 Pro→14
  band too, or let it through best-effort with a soft warning? The gate boolean is `is600MCapable` ≥4.6e9,
  which *passes* the 12 Pro band — so a literal gate on that boolean would NOT block them. If the product
  wants to block to the official 14 Pro line, the gate needs a stricter predicate than `is600MCapable`.)

---

## 7. Motion

- **Warming bar (A):** reuse `LoadingPlaceholderText`'s exact treatment — steady (non-animating) serif
  headline + `TimelineView(.periodic … 0.05)` driving the asymptotic `fill()` bar tinted
  `jotPageInkSecondary`, paced by `ModelLoadTimekeeper.estimatedSeconds`. The bar is the only motion; the
  real `modelState==.ready` transition snaps it away (never let the bar "complete" on its own).
- **Listening (B/C):** `SteppingEllipsis` — 4-phase, 0.45 s/step, 1.8 s loop, resting dots stay faintly
  visible so layout never pops.
- **Live text (C):** `TranscribingText`'s word-by-word `SettleRenderer` reveal + inline stepping tail.
- **State transitions:** match the wizard's existing `easeInOut(duration: 0.22)` (`SetupWizardView.swift:208`)
  for A→B→C→D crossfades. **D dwell:** a brief ~0.35 s settle (transcript snaps to full ink, check fades
  in) *before* the Continue pill animates from disabled (.55) to full gradient — a deliberate beat so the
  success registers before the CTA invites the tap. No auto-advance timer anywhere.
- **Reduce Motion** (`@Environment(\.accessibilityReduceMotion)`, already read in `SetupWizardView.swift:49`;
  passed to step): `SteppingEllipsis`/`TranscribingText` already fall back to static ellipsis + instant
  reveal; the warming bar keeps a determinate value but drop the per-tick easing; A→D transitions use no
  animation (mirror `advance(to:)`'s `reduceMotion ? nil` pattern).

---

## 8. Edge cases

| # | Case | Handling |
|---|------|----------|
| 1 | **Warm finishes mid-utterance** | A→C directly (skip B): the instant `streamingText` is non-empty, render `TranscribingText`. Capture-first means the buffered audio drains into the box; nothing said during A is lost (prewarm doc E1, `RecordingHeroView.swift:512-528`). |
| 2 | **User finishes reading a line while still in A** | Fine — they keep the recording live; words appear when the model is ready (reassurance line covers this). The success state only arrives on a *finalized* handoff, so an early read just sits as buffered audio. |
| 3 | **Never opens the keyboard** | Auto-record is live but no `keyboardDictateTapped` / no words → state **E** nudge after ~20 s + "I tried it" escape. Never blocks. |
| 4 | **Auto-record + force-stop contract** | The new auto-record (started on W5 entry, see open Q4 on the start hook) MUST be reaped by **both** `closeAndComplete()` (`:232-237`) and `TryKeyboardStep.onDisappear` (`:70-101`) — including the existing 2 s late-flip reaper for the start race. Do not add a start path that bypasses these. Mirror `handleKeyboardDictateTapped`'s `ownsActiveRecording = false` defensive clear (`:193`). |
| 5 | **Model load fails** | State **F**; Continue enabled (don't trap); capture-first keeps any later success possible. |
| 6 | **600M re-run on a 6 GB device** (E5) | Warming state may persist tens of seconds; the calibrated bar + "keep talking" is exactly the affordance for it. No special handling beyond A. |
| 7 | **Reduce Motion** | §7 fallbacks. |
| 8 | **Back-nav into W5 / re-entry** | `enteredAt` resets (`:67`); auto-record should not double-start (guard on `isRecording`, like `start()`'s internal guard `:181-199`). State resets to A/B by current `modelState`. |
| 9 | **Mic permission edge** | W2 already guarantees grant before W5; if somehow denied, auto-record's `start()` throws and is swallowed (mirror `:195-199`) → stays in B with no words → E nudge. |

---

## 9. Open questions for the owner

1. **Continue-enable point:** only after a *finalized* dictation (state D, recommended — honest "it
   worked") or already when *live words* appear (state C)? D risks a 1–2 s finalize wait feeling laggy.
2. **Sample-card vs live-box:** one morphing container (read-prompt → live transcript, recommended) or two
   stacked regions (prompt card stays, live box below)? Affects vertical budget on small devices.
3. **Gate strictness:** block to the *official* 14 Pro+ line (stricter than `is600MCapable`'s ≥4.6e9, which
   passes the 12 Pro→14 best-effort band), or let that band through with a soft "best-effort" note? The
   current boolean would NOT block them.
4. **Auto-record start hook:** start the recording in `TryKeyboardStep.task` (`:66`) on entry — but the
   *keyboard* normally drives `start()` via the host observer (`:177-201`). If W5 auto-starts in the main
   app, confirm the keyboard's Stop pill + cross-process recording-state still bind to it (it should, same
   singleton), and that double-start when the user *also* taps Jot-down is guarded.
5. **Sample-line rotation:** auto-rotate on a timer, rotate only on "↻ another" tap (recommended — user
   controls pace), or show all 5 as a list? Recommend tap-to-rotate, starting on a random line.
6. **Gate dismissal:** is "Got it" a true dead-end (re-presents the gate), or does it drop to a minimal
   read-only home? Recommend dead-end takeover (the app can't function).
