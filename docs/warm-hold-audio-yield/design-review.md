# Adversarial Review — Warm-Hold Audio Yield design.md

**Reviewer:** adversarial design review (do-not-rubber-stamp pass)
**Date:** 2026-06-20
**Scope reviewed:** `docs/warm-hold-audio-yield/design.md` against current code (`Jot/App/Recording/RecordingService.swift`) and current Apple audio-session docs/forum guidance.

---

## Verdict

**The experiment matrix is SAFE to run on-device as-is — with one correction that must be made to the V1/Path-A resume step before it is treated as the leading candidate.** The doc is unusually honest, its code:line citations are accurate, and the core mechanism claim (mixable `.record` session suppresses the playback interruption that would otherwise yield) is *correct* per Apple's own engineer statements. The reason it is safe to run despite open risk is that the variants are gated behind a hidden `warmYieldVariant` toggle and the dangerous parts (category mutation) are read at `enterWarmHold` time — so V0 (control) and the observe-only variants (V2/V3) carry essentially zero regression risk and can be run first.

**The one thing to fix first:** the design's resume step for V1 (and V4) — "re-add `.mixWithOthers` via `setCategory(...)` on warm-resume" — runs **while Jot is backgrounded**, and dropping `.mixWithOthers` makes the session **non-mixable**, which is the exact precondition for the documented background failure `AVAudioSessionErrorCodeCannotInterruptOthers` / error `561017449` (insufficient priority). The design treats the resume re-`setCategory` as a "measure it" risk; it should be elevated to a **MUST-instrument-and-gate** with an explicit error-path, because if that call throws in the background the warm session is left non-mixable and the *next* dictation's interruption-yield-vs-resume behavior is undefined. This does not block running the matrix — it blocks *shipping* V1/V4 without the error path. Run V0/V2/V3 freely; run V1/V4 only with instrumentation #6 plus a setCategory-failure log and a fallback.

---

## Explicit calls on the two make-or-break questions

### #1 — Does V1 regress the sub-100ms silent keyboard warm-resume? **Confidence: HIGH that the resume PATH is structurally safe; MEDIUM that V1's added setCategory won't perturb it.**

Verified in code:
- The warm branch of `start()` (`RecordingService.swift:539-543`) calls `startFromWarmHold(engine:)` and **returns before** `configureSession()` at `:549`. So warm-resume does **not** re-enter `configureSession` and does **not** call `setActive` — confirmed. ✅
- `startFromWarmHold` (`:639-684`) requires `engine.isRunning, isTapInstalled` (`:640`), keeps the engine + tap **continuously running**, and only builds a fresh `AVAudioConverter` + capture slice. No engine teardown, no session re-activation. ✅

So the **structural** fast path is intact. **BUT** V1 adds work the design glosses:
- V1 requires re-adding `.mixWithOthers` *before resuming* (design §5 Path A, lines 240-244). That is a NEW `setCategory(.record, .measurement, [.mixWithOthers])` call inserted into the warm-resume path that does not exist today. The design says "verify the re-`setCategory` on a running engine doesn't glitch — measure." That is correct but under-stated:
  1. The call happens **in the background** (keyboard-triggered resume while another app is foreground). Background `setCategory` is the documented failure surface (see MUST-FIX 1).
  2. Whether `setCategory` (options only, **no** `setActive`) actually takes effect on an already-active session is itself uncertain — Apple's QA1631 says `setCategory` is "safe regardless of activation state," but multiple forum reports note option changes on an *active* session don't reliably take effect without a `setActive` cycle. If the option silently doesn't apply, the resumed dictation is left **non-mixable** and will fail to come up while another app holds the mic (regressing the original `.micUnavailable` mitigation at `:15-22`).
- **Net:** the resume is not structurally torn down (good), but V1 bolts a background `setCategory` onto the most latency-sensitive path. **Acceptance gate #2 (sub-100ms silent resume) must be measured WITH the option-restore call in place, not the bare path.** Instrumentation #6 is necessary but must also log the setCategory result + the resumed `categoryOptions.rawValue` to prove `.mixWithOthers` actually re-applied.

### #2 — Will V1 actually deliver the interruption? **Confidence: MEDIUM-HIGH that the mechanism is correct; the per-app outcome is genuinely empirical.**

The design's central claim is **correct and now corroborated by Apple's own engineer**: a session **with** `.mixWithOthers` is "mixable" and **does not get interrupted** when another app plays — mixing is the intended behavior; only **non-mixable** sessions are involved in interruptions (Apple Developer Forums thread 755784, Apple engineer; Audio Session Programming Guide). So dropping `.mixWithOthers` to make the session non-mixable is the *right lever* to make an interruption possible. ✅

**However** — two real caveats the design already half-acknowledges but should sharpen:
- A non-mixable **`.record`** session is an *input* session with **no output leg**. The interruption model is built around output/playback contention. It is **not guaranteed** that a non-mixable *record-only* session receives a `.began` interruption when another app starts *playback* (as opposed to another app starting *recording*). The design's chicken-and-egg note (§3.4) covers this, but the framing "without `.mixWithOthers`, the other app's playback now generates an interruption" (V1 row) is **more confident than the evidence supports**. Recommend softening the table cell to match §3.4's honesty. This is exactly why V0→V1 on-device is the right call — the answer is not knowable from docs.
- For a **mixable competitor (YouTube)**: even after Jot drops `.mixWithOthers`, YouTube being mixable means it may simply coexist/play over Jot rather than interrupt. The design flags this (Open Q1) — good. The verdict for YouTube vs a non-mixable app (Music/Voice Memos) will likely differ, and the matrix correctly tests both.

**Bottom line on #2:** the mechanism is sound and the experiment is the correct way to resolve it. Do not let the V1 table row's confident phrasing ("now generates an interruption") get treated as a fact — it's a hypothesis, ranked correctly as Medium.

---

## MUST-FIX (before V1/V4 are shipped — not before running the matrix)

### MF-1 — Background `setCategory` on a non-mixable session can fail; V1/V4 need an explicit error path + fallback
- **Challenged claim:** §5 Path A (lines 240-244) and Path C (lines 263-269) treat the on-resume / on-entry `setCategory` as a latency risk to "measure," not a failure mode to handle.
- **Evidence:** Apple engineer (forums thread 755784) + thread 725256 + thread 467 (Twilio): changing category / activating a **non-mixable** session **in the background** throws `AVAudioSessionErrorCodeCannotInterruptOthers` and/or error `561017449` (`AVAudioSessionErrorInsufficientPriority`), and a *single* failed background category change has been observed to leave audio routing in a corrupted state (random output port) until the app foregrounds. V1 makes Jot non-mixable precisely while backgrounded, which is the trigger condition.
  - Sources: https://developer.apple.com/forums/thread/755784 · https://developer.apple.com/forums/thread/725256 · https://github.com/twilio/video-quickstart-ios/issues/467
- **Concrete fix:** Wrap every new `setCategory` in V1/V4 (both the warm-entry mutation AND the warm-resume restore) in `do/catch`, log `domain/code/options-after` (extend instrumentation #6 and add the same to #1), and define the fallback: if the entry-time drop of `.mixWithOthers` throws, **abandon the yield experiment for that warm window and stay in V0 behavior** (do not leave the session in an indeterminate state); if the resume-time restore throws, **fall through to a full `configureSession` cold path** rather than resuming a non-mixable session that will hit `.micUnavailable`. Note: the *entry* mutation is less risky than the forum cases because it does **not** call `setActive` — but it still must be caught and logged.

### MF-2 — Verify (don't assume) that options-only `setCategory` actually applies on an active session; otherwise V1 is a no-op
- **Challenged claim:** §5 Path A assumes re-`setCategory(.record,.measurement,[])` on the live active session takes effect immediately (drops `.mixWithOthers`) without a `setActive` cycle.
- **Evidence:** QA1631 says `setCategory` is "safe to call regardless of activation state" but also recommends making preference requests when **not active**; multiple forum reports state option changes on an *active* session are not reliably applied without re-activation. If the drop silently doesn't apply, V1 reproduces V0 (still mixable → no interruption) and you'd wrongly conclude "interruption mechanism doesn't work" when in fact the option never changed.
  - Source: https://developer.apple.com/library/archive/qa/qa1631/_index.html
- **Concrete fix:** In instrumentation #1, after the V1 mutation, **log `session.categoryOptions.rawValue` immediately after the setCategory call** to confirm `.mixWithOthers` (rawValue bit `1`) actually cleared. If it didn't clear, the variant needs a `setActive(false)`→`setCategory`→`setActive(true)` cycle — which would itself yield the mic (arguably fine for V1's goal, but it changes the mechanism and the resume story). This is a 1-line addition to an already-planned log; cheap and decisive.

---

## NICE-TO-HAVE

### NTH-1 — Soften the V1 matrix-row hypothesis to match §3.4's honesty
The V1 row (line 134) says dropping `.mixWithOthers` means the other app's playback "now generates an **interruption** `.began`." §3.4 (lines 176-179) correctly hedges this (record-only, no output leg, chicken-and-egg). Make the table cell consistent — phrase it as "*may* now generate an interruption (record-only session, unverified)" so a reader skimming the table doesn't treat it as established. Confidence the hedge is warranted: HIGH.

### NTH-2 — V3 is correctly predicted to fail; keep it but label it "negative-confirmation only"
Verified: `silenceSecondaryAudioHintNotification` is delivered **only to foreground apps with an active session**, and `secondaryAudioShouldBeSilencedHint` is true **only when a non-mixable other app is playing** (Apple QA1882, fetched directly — quotes below). Jot is **backgrounded** in the test, so V3 will almost certainly never fire. The design already says this (lines 136, 182-183, 298). This is CORRECT. Recommendation: keep V3 only as a one-line cheap negative confirmation; do not invest in tuning it. Quotes confirming:
  - "The notification is **only** sent to registered listeners that are currently in the **foreground** and have **active** audio session."
  - "Will be true when **another application with a non-mixable audio session is playing audio**."
  - Source: https://developer.apple.com/library/archive/qa/qa1882/_index.html

### NTH-3 — V2's `isOtherAudioPlaying` chicken-and-egg is correctly called; add the timing detail
`secondaryAudioShouldBeSilencedHint` reflects non-mixable audio that **is** playing; if Jot's `.record` session is *blocking* the competitor from starting, neither property flips — the design says this (lines 184-186). Correct. One addition: even where it would flip, the property is documented as a thing to check in `applicationDidBecomeActive` (foreground hint), so its background-poll reliability is itself uncertain — worth logging the property's value at warm-entry (already in instrumentation #1) AND noting that a never-flipping poll in V2 is an *expected* negative, not a bug.

### NTH-4 — Add a V4-resume guard symmetric to MF-1
V4 switches to `.playAndRecord` for the idle window and back to `.record/.measurement` on resume. The "switch back" is the constraint-#2 risk the design flags (lines 266-269). Same fix as MF-1: catch + log + fall back to cold `configureSession` if the switch-back throws. Also worth noting V4 changes the engine graph topology (adds an output leg); on a **running** engine, swapping category to/from `.playAndRecord` is more likely than V1's options-only change to trigger an `AVAudioEngineConfigurationChange` — which Jot's own observer (`:1745-1753`, `handleEngineConfigChange` → `exitWarmHold` while warm, `:1814-1817`) would interpret as a reason to **cool the engine**. That means V4 could **self-yield via its own config-change observer** the instant it switches category — which might actually *work* (it yields!) but for a different reason than the design hypothesizes, and it would also fire on the resume switch-back and tear down the warm engine. **Flag this interaction explicitly in V4** — it's a real confound that could make V4 look like it "works" while actually just tripping the existing config-change teardown.

### NTH-5 — Confirm the orange-dot / `isOtherAudioPlaying` snapshot is read on the main actor
Instrumentation #1 reads `session.isOtherAudioPlaying` and `secondaryAudioShouldBeSilencedHint` at `enterWarmHold`. `enterWarmHold` is `@MainActor` (whole class is, `:6`) so this is fine — just confirming no off-actor session read sneaks in for the V2 poll task (the poll Task is `@MainActor` in the existing warmCooldownTask pattern; keep it that way).

---

## VERIFIED CORRECT (challenged and held up)

1. **All file:line citations are accurate.** Spot-checked: `enterWarmHold` guard `:1141`; `startFromWarmHold` guard `:640`; warm branch returns before `configureSession` (`:539-543` vs `:549`); `configureSession` sets `.record/.measurement/[.mixWithOthers]` (`:1262-1266`); interruption handler yields via `exitWarmHold()` while warm (`:1782-1784`); `restoreSession` does `setActive(false, .notifyOthersOnDeactivation)` (`:1303`); `.micUnavailable` rationale (`:15-22`). All confirmed. ✅
2. **The session persists unchanged through the idle warm window** — `enterWarmHold` never calls `setActive`/`setCategory`; engine + tap stay running. Confirmed (`:1132-1174`, no session calls). ✅
3. **The yield path is gentle, never force-stop.** All paths route through `exitWarmHold()` → `fullyTeardownEngine()` → `restoreSession()` (`:1216, :1236-1245, :1288-1321`). No `forceStop`/`discard` in any proposed path. Satisfies [[feedback_never_force_stop]]. ✅
4. **Active recording is not in scope** — every variant is gated on the idle warm window (`isWarm && !isCapturingSlice`); `enterWarmHold` itself guards `!isCapturingSlice` (`:1141`). The idle-vs-active boundary is cleanly detectable via that exact flag. ✅
5. **The core mechanism: mixable session suppresses the interruption.** Corroborated by Apple engineer + Audio Session Programming Guide — only non-mixable sessions participate in interruptions; mixable ones coexist. §1.3 is correct. ✅
6. **`setActive(false, .notifyOthersOnDeactivation)` is the call that lets the blocked app resume.** Correct per Apple docs; it's already in `restoreSession` (`:1303`). The design's claim that the *only* missing piece is *triggering* the yield is accurate — the teardown is already proven. ✅
7. **Schema impact: none.** Confirmed no `@Model` involvement; only a transient `warmYieldVariant` AppGroup key. Matches the schema-discipline carve-out. ✅
8. **Hidden-toggle approach is sound.** Reading `warmYieldVariant` at `enterWarmHold` time means no recompile to switch variants — correct, because the variant only changes what happens *at warm entry / during idle*, and `enterWarmHold` runs fresh on every stop. The one caveat: a variant that mutates category at entry must be matched by its resume-restore reading the **same** variant at resume time (so a mid-window toggle flip doesn't leave entry/resume mismatched). Minor — note it.

---

## On the decision tree (asked directly)

The tree (A interruption > B-notif > B-poll > C) is **decisive and correctly ordered** for "good citizen" cleanliness. Two refinements:
- It should branch on **app class** at each node (mixable YouTube vs non-mixable Music) rather than treating "other app" monolithically — §3.1 already says to run both, but the tree collapses them. A clean outcome is plausibly "V1 works for non-mixable, V4/coexist works for mixable" → a hybrid, not a single winner.
- Path C/V4's "other app plays freely (coexist)" branch should account for NTH-4 (the config-change observer may self-yield) so a "coexist" result isn't misread.

---

## Sources

- Apple Developer Forums 755784 (Apple engineer on mixWithOthers / non-mixable interruption + background activation): https://developer.apple.com/forums/thread/755784
- Apple Developer Forums 725256 (background category change fails iOS 16+, `cannotInterruptOthers`, routing corruption): https://developer.apple.com/forums/thread/725256
- Twilio video-quickstart-ios #467 (`setActive` error 561017449 / insufficient priority): https://github.com/twilio/video-quickstart-ios/issues/467
- Apple QA1631 (setCategory safe regardless of activation, but prefer inactive for preferences): https://developer.apple.com/library/archive/qa/qa1631/_index.html
- Apple QA1882 (silenceSecondaryAudioHint: foreground-only, non-mixable-only): https://developer.apple.com/library/archive/qa/qa1882/_index.html
- Apple Audio Session Programming Guide (mixable vs non-mixable, interruption participation): https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html
