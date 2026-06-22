# Warm-Hold Audio Yield — Design + On-Device Experiment Matrix

**Status:** Design only. No product code changed. The resolution is **empirical** — this
doc's primary job is to turn iOS audio-session uncertainty into a sequence of
device-testable hypotheses the owner can run on a real iPhone in minutes.

**Bug priority:** #1 audio bug.

**Author note on confidence:** Per the project's bug protocol
([[feedback_bug_overconfidence]], [[feedback_reason_from_symptoms_before_instrumenting]]),
this doc is diagnostic-first. Where iOS behavior is uncertain I say so and make it a
labeled experiment, rather than asserting a fix. The simulator **cannot** model any of
this (no real audio HAL arbitration, no second app competing for the route) — every row
in the matrix is device-only.

---

## 1. Confirmed root cause

### 1.1 What warm hold holds

After a clean stop, if warm hold is enabled, `RecordingService` enters warm hold instead
of tearing down:

- `stop()` decides `shouldEnterWarmHold` and calls `enterWarmHold(duration:)`
  — `RecordingService.swift:1085-1106`.
- `enterWarmHold` **requires** a live, tapped, running engine and will not enter otherwise:
  `guard engine.isRunning, isTapInstalled, !isCapturingSlice else { … fully tear down }`
  — `RecordingService.swift:1141-1145`.
- It sets `isWarm = true`, arms a cooldown `Task`, and publishes warm state to the App Group
  — `RecordingService.swift:1151-1173`.
- **Crucially, it never deactivates the AVAudioSession and never tears down the engine.**
  The engine keeps running with the tap installed for the entire warm window.

So during warm hold the process holds:
- An **active** `AVAudioSession` at category `.record`, mode `.measurement`, options
  `[.mixWithOthers]` — set in `configureSession()` at `RecordingService.swift:1262-1268`,
  never changed on stop.
- A **running `AVAudioEngine`** with an **installed input tap** — required by
  `enterWarmHold` (`:1141`) and required again by the warm fast-path
  `startFromWarmHold` (`:639-640`, `guard engine.isRunning, isTapInstalled`).

### 1.2 Why other apps go silent

From Apple's audio-session docs (cited §8): the `.record` category **does not provide an
output route** and, by default, **interrupts/blocks other apps' audio**. Jot mitigates the
*activation* failure with `.mixWithOthers` so `setActive(true)` + `engine.start()` succeed
even when another app holds the mic (see the `.micUnavailable` doc comment,
`RecordingService.swift:15-22`). But `.mixWithOthers` on a **`.record`** session is a
half-measure for *output*: there is still no output route owned by Jot, and the system
treats Jot as the active input-owning session. The observed effect — another app (YouTube,
Voice Memos) cannot start playback while Jot is warm — is consistent with a `.record`
session occupying the audio path with no output leg.

### 1.3 Why Jot never learns they tried (the silent deadlock)

This is the load-bearing finding and the reason the fix is empirical:

- Jot already does the right thing **if** an interruption is delivered: the interruption
  observer (`RecordingService.swift:1715-1724` → `handleInterruption`, `:1778-1796`) calls
  `exitWarmHold()` on `.began` while warm (`:1782-1784`). That is exactly "yield the mic."
- **But `.mixWithOthers` suppresses the interruption.** Per Apple + developer-forum
  consensus (§8): with `.mixWithOthers`, another app starting playback **does not generate
  an interruption** — the OS lets the sessions coexist and only delivers *hard*
  interruptions (calls, alarms, Siri). So the one signal Jot listens for never arrives.

Net: `.mixWithOthers` is doing two contradictory jobs. It is **needed** at activation time
(so Jot can come up while another app holds the mic — `:15-22`), but during the **idle
warm window** it **silences the very interruption** that would let Jot yield. The result is
a deadlock: the other app is blocked from output AND Jot is never told to step aside.

**Confirmed (file:line):** root cause is the combination of `.record` + persistent active
session + `.mixWithOthers` held through the idle warm window. Confidence: **high** on the
code facts; **the OS arbitration outcome (does playback actually start? does any signal
fire?) is what must be measured** — that uncertainty is the whole point of §3.

---

## 2. What must NOT regress

The fix touches the most delicate part of Jot. Hard constraints:

1. **Do not release the mic on stop.** Warm hold + orange dot stay exactly as today. Fast
   re-dictation is the entire point. (Owner intent; [[project_only_outbound_is_feedback]]
   warm-hold framing.)
2. **Keyboard 60-second warm-mic instant-resume must still work.** The keyboard cannot
   touch the mic itself; it remotely triggers the app, which resumes via the warm fast-path
   `startFromWarmHold` — which **requires `engine.isRunning && isTapInstalled`**
   (`RecordingService.swift:639-640`) and **skips `configureSession()`**
   (`start()` warm branch, `:539-545`). Any variant that tears the engine down, or that
   changes category/options in a way that forces a re-`configureSession` on resume, breaks
   silent in-place resume (`keyboard-warm-mic-60s-research.md` §1a: "Silent in-place… the
   streaming caption just starts appearing"). **A variant is only acceptable if warm-resume
   stays sub-100ms and silent.**
3. **NEVER force-stop the mic to yield.** Yielding must go through the gentle
   `exitWarmHold()` path (which calls `fullyTeardownEngine()` → `restoreSession()`,
   `:1236-1245`), exactly as the existing interruption handler does (`:1784`). NEVER
   `forceStop()`/`discard()` ([[feedback_never_force_stop]]).
4. **During ACTIVE recording, keep today's behavior.** Yielding mid-dictation would drop the
   user's words. All new yield behavior is scoped to the **idle warm window only**
   (`isWarm == true && !isCapturingSlice`).
5. **No band-aids.** Fix the real arbitration cause; don't paper over symptoms
   ([[feedback_never_band_aid]]).

---

## 3. ★ ON-DEVICE EXPERIMENT MATRIX (the heart of this doc)

### 3.1 The one user action (identical for every row)

> **A.** Open Jot, dictate one short phrase, **Stop**. Confirm the orange mic dot is ON
> (warm hold active, idle). **Do not re-dictate.**
> **B.** Background Jot (Home). Within the 60s warm window, open **YouTube** (custom audio
> stack, *mixable*) **and**, as a second trial, **Voice Memos** or **Apple Music**
> (system audio, more likely *non-mixable*). Press **Play**.
> **C.** Observe: (1) does the other app's audio actually play? (2) does the orange dot
> turn off? (3) which os_log line(s) fire in Console.app? (4) if you then re-tap Dictate
> in the keyboard within the window, does warm-resume still work silently?

Run B with **both** a mixable app (YouTube) and a non-mixable app (Music/Voice Memos),
because `secondaryAudioShouldBeSilencedHint` only flips for **non-mixable** competitors
(§8) — the two app classes are different experiments.

### 3.2 Variants to try (each = one build or one toggle)

Add a hidden debug toggle (`AppGroup` defaults key, e.g. `warmYieldVariant`) read at
`enterWarmHold` time so all variants live in one build and the owner switches without
recompiling. Each variant changes **only what happens at the moment warm hold is entered
and during the idle window** — never active recording.

| # | Variant (what changes during the IDLE warm window) | Hypothesis | Confidence it fires | Keyboard-resume risk |
|---|---|---|---|---|
| **V0** | **Control.** Exactly today: `.record`/`.measurement`/`[.mixWithOthers]`, active, engine+tap running. | Other app blocked; NO signal fires; dot stays on. (Reproduces the bug.) | n/a (baseline) | none (today's behavior) |
| **V1** | On entering warm, **re-`setCategory(.record, .measurement, [])`** (drop `.mixWithOthers`) while keeping the session active + engine running. On warm-resume, set it back to `[.mixWithOthers]` before/at `startFromWarmHold`. | Without `.mixWithOthers`, the other app's playback attempt now generates an **interruption `.began`** → existing handler yields (`:1782-1784`). **Path A.** | **Medium.** A non-mixable competitor *should* now interrupt us; a mixable one (YouTube) may still just coexist or still be blocked. | **Medium** — must restore option on resume; verify resume stays silent + sub-100ms. Re-`setCategory` on a live session may glitch the running engine — measure. |
| **V2** | Keep V0 config, but **poll `AVAudioSession.sharedInstance().isOtherAudioPlaying` / `.secondaryAudioShouldBeSilencedHint`** on a ~0.5s timer during the idle window; if true → `exitWarmHold()`. | A pollable property flips when another app wants the route, even if no interruption fires. **Path B (poll).** | **Low–Medium.** Docs say `secondaryAudioShouldBeSilencedHint` reflects a **non-mixable** competitor; but if Jot's `.record` session is *blocking* them from starting, the property may never flip (chicken-and-egg). Must measure. | **Low** — no category change; resume untouched. Only risk is a stray poll firing `exitWarmHold` while the user meant to re-dictate. |
| **V3** | Register for **`silenceSecondaryAudioHintNotification`** (`.begin`/`.end`) during warm; on `.begin` → `exitWarmHold()`. | The hint notification fires when another app's **primary** audio starts. **Path B (notif).** | **Low.** Apple docs: this notification is delivered **only to apps in the FOREGROUND** with an active session (§8). Jot is **backgrounded** during the test → likely **never fires**. Logged anyway to confirm the negative. | **Low** — observer only; resume untouched. |
| **V4** | On entering warm, **switch to a mixable, output-bearing config**: `setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])`, keep active + engine running. On resume, switch back to `.record`/`.measurement`. | A `.playAndRecord`+`.mixWithOthers` session **does** let other apps play (it has an output route to share), so the other app is no longer blocked — and *also* makes Jot interruptible by non-mixable apps. Possibly **no yield even needed** for mixable apps (they just play over Jot's silent idle session). **Path C / hybrid.** | **Medium-High** that the other app can now play; **Low-Medium** that any signal fires (it may just coexist). | **High** — `.playAndRecord` changes the graph; switching category back on resume may force engine reconfiguration and break the silent sub-100ms resume. This is the riskiest variant for constraint #2 — measure resume latency carefully. |
| **V5** | **Time-boxed idle probe:** keep V0, but if `isOtherAudioPlaying` is observed true at *any* poll OR a route/interruption fires, yield; combine V1's option-drop **with** V2's poll. | Belt-and-suspenders: drop `.mixWithOthers` (so interruptions can fire) **and** poll (so we catch the silent case). Whichever fires first yields. | Highest aggregate — covers A and B. | Inherits V1's resume risk (option restore) + V2's stray-yield risk. |

### 3.3 Decision tree (run V0 first to confirm repro, then V1–V4)

```
Run V0 (control) → confirm: other app blocked, dot stays on, no signal. (Bug reproduced.)

Run V1 (drop .mixWithOthers while idle):
  ├─ Other app now PLAYS and interruption .began fires → ✅ PATH A (cleanest).
  │     Implement: drop .mixWithOthers on enterWarmHold; existing handler yields;
  │     restore .mixWithOthers on warm-resume. Verify resume still silent/fast.
  └─ Other app still blocked / no interruption → go to V2/V3.

Run V2 (poll isOtherAudioPlaying / secondaryAudioShouldBeSilencedHint):
  ├─ A property flips true when the other app tries to play → ✅ PATH B (poll).
  │     Implement: lightweight poll during idle warm window → exitWarmHold on true.
  └─ Properties never flip (chicken-and-egg confirmed) → go to V3/V4.

Run V3 (silenceSecondaryAudioHint notification):
  ├─ .begin fires even though Jot is backgrounded → ✅ PATH B (notif, cheapest).
  └─ Never fires (expected, foreground-only) → go to V4.

Run V4 (.playAndRecord + .mixWithOthers + defaultToSpeaker while idle):
  ├─ Other app plays freely (coexist) AND warm-resume still silent/fast
  │     → ✅ PATH C: switch config for the idle window; maybe no explicit yield needed.
  │       (If a signal also fires, yield is a bonus.)
  ├─ Other app plays but warm-resume breaks/slows → reject V4 (violates constraint #2);
  │     fall back to best of V1/V2.
  └─ Nothing helps → escalate: warm hold may be fundamentally incompatible with
        "let others play"; consider a SHORTER warm window or yielding on app-background
        (see §5 Path D) and discuss with owner.

If multiple paths work → prefer A (interruption, native, least polling) > B-notif >
B-poll > C. Ship V5 (combined) only if no single mechanism is reliable across app classes.
```

### 3.4 Why each candidate might NOT fire (be honest)

- **Interruption (V1):** other-app playback only interrupts a **non-mixable** session, AND
  only if iOS actually lets the other app *start* (if Jot's `.record` session pre-empts the
  route, the other app may fail to start and thus never trigger anything). Chicken-and-egg
  is real here — measure.
- **`secondaryAudioShouldBeSilencedHint` (V2/V3):** reflects a **non-mixable** competitor;
  YouTube may be mixable and never flip it. And the *notification* (V3) is **foreground-only**
  — Jot is backgrounded in the test, so V3 is expected to fail; we test it to confirm the
  negative cheaply.
- **`isOtherAudioPlaying` (V2):** may read false if the other app is *blocked from starting*
  by Jot's session — the property describes audio that *is* playing, not audio that *wants* to.
- **`.playAndRecord` (V4):** most likely to let others play, but most likely to break the
  silent fast resume. The trade-off is the experiment.

---

## 4. Instrumentation plan

Match the existing style: `os.log` with `log.notice` / `log.error` and `privacy: .public`
on every value (mirrors `configureSession`, `:1261-1282`, and the `[WARM-HOLD-DEBUG]`
lines at `:1133`, `:1197`, `:1219`). Add a stable prefix `[WARM-YIELD]` so the owner can
filter Console.app in one pass (same pattern as `RECORDING START FROM:` in `CLAUDE.md`).

**Where to add (all within `RecordingService.swift`):**

1. **At `enterWarmHold` entry (~:1132):** log the chosen variant + the exact session config
   it is leaving the session in:
   `log.notice("[WARM-YIELD] enterWarmHold variant=\(variant, privacy: .public) cat=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) opts=\(session.categoryOptions.rawValue, privacy: .public) otherAudioPlaying=\(session.isOtherAudioPlaying, privacy: .public) secondaryHint=\(session.secondaryAudioShouldBeSilencedHint, privacy: .public)")`

2. **In `handleInterruption` (~:1778):** already logs; add the type + warm flag explicitly
   and a `[WARM-YIELD]` tag so an interruption-driven yield is unmistakable:
   `log.notice("[WARM-YIELD] interruption type=\(typeRaw, privacy: .public) isWarm=\(self.isWarm, privacy: .public) → \(self.isWarm ? "yield" : "stop", privacy: .public)")`

3. **New `silenceSecondaryAudioHint` observer (V3 only):** log every `.begin`/`.end`:
   `log.notice("[WARM-YIELD] secondaryHint note type=\(typeRaw, privacy: .public) isWarm=\(self.isWarm, privacy: .public)")`

4. **New idle poll (V2/V5 only):** on each tick while `isWarm && !isCapturingSlice`:
   `log.notice("[WARM-YIELD] poll otherAudioPlaying=\(session.isOtherAudioPlaying, privacy: .public) secondaryHint=\(session.secondaryAudioShouldBeSilencedHint, privacy: .public)")`
   (Throttle to ~0.5–1s; do NOT spam.)

5. **At the yield site (wherever `exitWarmHold()` is called for this reason):**
   `log.notice("[WARM-YIELD] yielding mic via exitWarmHold (reason=\(reason, privacy: .public))")` — then the existing `[WARM-HOLD-DEBUG] warm hold exited` line (`:1219`) confirms teardown + `restoreSession()`.

6. **On warm-resume (`startFromWarmHold`, ~:639):** log resume latency to prove constraint
   #2 isn't regressed:
   `log.notice("[WARM-YIELD] warm-resume start cat=\(...) opts=\(...)")` + a signpost/`Date()`
   delta to the first delivered buffer. (Resume latency is the acceptance gate for V1/V4.)

**Reading the run:** filter Console.app on `[WARM-YIELD]`. The single most diagnostic line
is #1 (the config + `isOtherAudioPlaying`/`secondaryHint` snapshot at warm entry) followed
by whether #2/#3/#4 ever fire when the owner presses Play in the other app.

---

## 5. Implementation approaches per likely outcome (prose / pseudocode only)

All paths yield through the **existing gentle** `exitWarmHold()` (`:1200-1222`) →
`fullyTeardownEngine()` → `restoreSession()`. **No `forceStop`.** This is identical to how
the current interruption handler yields (`:1784`), so the teardown is already proven.

### Path A — interruption fires once `.mixWithOthers` is dropped (V1)
- In `enterWarmHold`, after entering warm, re-`setCategory(.record, .measurement, [])` on
  the live session (engine keeps running). Stash that we did so.
- `handleInterruption(.began)` while warm already calls `exitWarmHold()` (`:1782-1784`) —
  **no new yield code needed**, the path already exists.
- **Resume:** in `startFromWarmHold` (or the warm branch of `start()`), before resuming,
  re-add `.mixWithOthers` via `setCategory(.record, .measurement, [.mixWithOthers])` so the
  next dictation keeps today's "can come up while another app holds the mic" behavior
  (`:15-22`). Verify the re-`setCategory` on a running engine doesn't glitch — measure
  (instrumentation #6).
- Risk: dropping `.mixWithOthers` while idle could itself surface a *latent* interruption
  if some other app is *already* playing at warm-entry — that's actually correct (yield),
  but log it (#1 snapshot) so it isn't mistaken for a bug.

### Path B — poll or hint notification (V2 / V3)
- Add a `warmYieldProbeTask` armed in `enterWarmHold`, cancelled in `exitWarmHold` /
  `startFromWarmHold` (alongside the existing `warmCooldownTask` / `warmHeartbeatTask`
  cancellation, `:1202-1205`, `:645-648`).
- Each tick: `if isWarm && !isCapturingSlice && session.isOtherAudioPlaying { yield }`.
- For V3: register the `silenceSecondaryAudioHintNotification` observer in
  `subscribeSystemObservers` (`:1706`) and tear it down in `unsubscribeSystemObservers`
  (`:1772`); on `.begin` while warm → `exitWarmHold()`.
- **Resume:** no category change, so `startFromWarmHold` is untouched — lowest risk to
  constraint #2. Just cancel the probe task on resume.
- Risk: a false-positive poll yielding while the user is mid-thought about re-dictating.
  Mitigate by requiring the property to be true for **two** consecutive ticks before yielding.

### Path C — output-bearing idle config (V4)
- In `enterWarmHold`, `setCategory(.playAndRecord, mode: .default,
  options: [.mixWithOthers, .defaultToSpeaker])`. The other app may now simply play over
  Jot's idle session (no explicit yield required for mixable apps).
- **Resume:** switch back to `.record`/`.measurement`/`[.mixWithOthers]` in
  `startFromWarmHold`. **This is the constraint-#2 risk:** if switching category forces the
  engine to reconfigure, the silent sub-100ms resume breaks. Gate acceptance on measured
  resume latency (#6). If it regresses, reject Path C.

### Path D — fallback if nothing fires (escalation, discuss with owner)
- If no signal reliably fires across app classes, the cleanest "good citizen" move is to
  **yield on Jot backgrounding** when warm-and-idle (scene → background): exit warm hold so
  Jot never holds the route while not foregrounded. This **weakens** the cross-app warm
  feature (re-dictation from another app would cold-start, not warm-resume) — so it's a
  product trade-off for the owner, not an automatic choice. Surface it; don't ship it
  silently. (Note: this contradicts the keyboard-from-another-app warm-resume premise in
  `keyboard-warm-mic-60s-research.md` §1a, so it needs explicit owner sign-off.)

### Yield correctness (all paths)
`exitWarmHold()` already: cancels cooldown/heartbeat tasks, clears `isWarm` + App-Group warm
keys, clears pause state, tears down engine, `restoreSession()`, logs (`:1200-1222`). After
yield, `setActive(false, .notifyOthersOnDeactivation)` inside `restoreSession()` (`:1303`)
is exactly the call that lets the other app's audio resume (§8). **This is already correct —
the only missing piece is *triggering* the yield, which §3 determines empirically.**

---

## 6. What is knowable now vs must be verified on device

**Knowable now (from code + Apple docs — high confidence):**
- The warm session config and that it persists unchanged through the idle window (§1.1).
- That `.record` blocks others' output and `.mixWithOthers` suppresses the interruption that
  would otherwise yield (§1.2–1.3, §8).
- That the gentle yield path (`exitWarmHold` → `restoreSession` → `setActive(false,
  .notifyOthersOnDeactivation)`) is the correct, already-built mechanism to release the route.
- That `silenceSecondaryAudioHintNotification` is **foreground-only** and **non-mixable-only**
  (so V3 is likely a negative in our backgrounded test).

**Must be verified on device (the empirical core — simulator CANNOT model it):**
- Whether dropping `.mixWithOthers` while idle actually lets the other app start AND delivers
  an interruption to Jot (V1 / Path A) — **the key question.**
- Whether `isOtherAudioPlaying` / `secondaryAudioShouldBeSilencedHint` ever flip true while
  Jot's `.record` session is blocking the competitor (chicken-and-egg) (V2).
- Whether `.playAndRecord` lets others play without breaking silent sub-100ms warm-resume (V4).
- Behavior differences between a **mixable** competitor (YouTube) and a **non-mixable** one
  (Apple Music / Voice Memos) — likely different per app class.
- That whichever variant ships does NOT regress the keyboard 60s silent warm-resume
  (constraint #2) — measured via instrumentation #6.

**Why the simulator is useless here:** no real audio HAL, no route arbitration, no second
app contending for the output route. Every claim about "does the other app play / does a
signal fire" is undefined on the simulator and must come from a real iPhone.

---

## 7. Schema impact

**None.** This change touches `AVAudioSession`/`AVAudioEngine` lifecycle and observers only.
No `@Model` types, no SwiftData entities, no App-Group schema changes. The only new App-Group
key is a transient debug variant selector (`warmYieldVariant`) used during experimentation;
it can be removed once a path is chosen and carries no persisted user data. Confirmed: no
existing usage of `isOtherAudioPlaying` / `secondaryAudio*` / `silenceSecondary*` anywhere in
`Jot/` (grep, 2026-06-20), so this is all additive.

---

## 8. Cited Apple references (audio-session API firing conditions)

- **`.record` category blocks other apps' audio by default; needs `.mixWithOthers` to
  coexist; provides no output route** — Apple, *Configuring an Audio Session* / *Audio
  Guidelines by App Type*:
  https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/ConfiguringanAudioSession/ConfiguringanAudioSession.html
- **`.mixWithOthers` suppresses non-hard interruptions** (other-app playback does NOT
  interrupt a mixable session; only calls/alarms do) — Apple, *Responding to Interruptions*
  + developer-forum consensus:
  https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html
- **`silenceSecondaryAudioHintNotification` fires when another app's PRIMARY audio
  starts/stops, only to FOREGROUND apps with an active session; `secondaryAudioShouldBeSilencedHint`
  is true when a NON-MIXABLE other app is playing** — Apple QA1882 + docs:
  https://developer.apple.com/library/archive/qa/qa1882/_index.html ·
  https://developer.apple.com/documentation/avfaudio/avaudiosession/silencesecondaryaudiohintnotification
- **`setActive(false, .notifyOthersOnDeactivation)` is what lets the previously-blocked app
  resume** — Apple, *Activating an Audio Session*:
  https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/ConfiguringanAudioSession/ConfiguringanAudioSession.html

---

## 9. Open questions

1. **Does YouTube use a mixable session?** If yes, V1's interruption may never fire for it
   even after dropping `.mixWithOthers` (two mixable sessions coexist). Test YouTube AND a
   known non-mixable app side by side — they may need different verdicts.
2. **Re-`setCategory` on a live running engine** — does it cause an audible click / a brief
   tap stall? Measure (instrumentation #6) before committing to V1/V4.
3. **Two-consecutive-ticks debounce for V2** — what poll interval balances responsiveness
   (other app should play within ~1s of pressing Play) against false yields? Tune on device.
4. **Path D trade-off** — if escalation is needed, does the owner accept losing
   cross-app warm-resume (re-dictation from another app cold-starts) in exchange for never
   blocking other apps while backgrounded? Owner decision, not an engineering default.
5. **Does the orange dot turn off promptly on yield?** The dot is driven by session
   activity; `restoreSession()`'s `setActive(false)` should clear it — confirm visually in
   the test (column C.2).
