# [CLOSED 2026-09-26, build 310 — owner-verified] Warm Hold vs. Reddit — why Reddit's player dies while YouTube/Music survive, and what Willow proves is possible

**Status:** Research only. No code changed. 2026-08-30.

**The complaint (owner):** with warm hold on, Reddit videos will not play until Jot is
force-quit. YouTube plays. Music apps play. A prior investigation concluded "there is no
other way" — but the Willow voice keyboard holds a background mic session and Reddit
still plays, so that conclusion is wrong somewhere.

**One-line diagnosis (hypothesis, needs the §5.1 probe):** Jot's idle warm session is a
*mixable* `.playAndRecord` with a running duplex engine — iOS almost certainly reports it
to other apps as "other audio is playing." YouTube and Music ignore that signal and claim
the route anyway; Reddit's player is famously polite about other people's audio (that's
what its "Quiet Audio Mode" and muted-autoplay session gymnastics are for) and **declines
to start** when it thinks audio is playing that it would stomp. Reddit isn't being blocked
by iOS — Reddit is *choosing* not to play. The fix space is therefore "stop looking like
playing audio while idle," not "yield harder."

---

## 1. Current implementation, precisely (all confirmed, file:line)

### 1.1 Session/engine state at each phase

| Phase | Category / mode / options | setActive | Engine | Where |
|---|---|---|---|---|
| Cold start (capture) | `.record` / `.measurement` / `[.mixWithOthers]` (no-op on `.record`, kept for parity) | `setActive(true)` then **wait for hardware** (`awaitExclusiveInput`, ≤0.5 s) | Built fresh AFTER session settles; tap installed; first-buffer gate | `RecordingService.swift:1770-1780` (configureSession), `:1706-1745` (awaitExclusiveInput), `:1673` (0.5 s bound), `:766` + `:820-838` (cold first-buffer gate, 1.0 s bound `:856`) |
| **Idle warm hold** | **`.playAndRecord` / `.measurement` / `[.mixWithOthers]`**, re-`setActive(true)` so the mixable route actually applies | stays **active** the whole window | **keeps RUNNING with tap installed**; buffers dropped while idle | `enterWarmHold` `:1466-1513`; `makeWarmIdleSessionMixable` `:1568-1591` (swap at `:1575`, re-activate `:1580`); engine-stays-running comment `:1354-1356`; on-throw fallback to non-mixable `.record` `:1585` |
| Warm resume (capture) | swap back to `.record` / `.measurement` / `[.mixWithOthers]`, `setActive(true)`, `awaitExclusiveInput` | active | same engine resumes; fresh slice; **first-buffer confirmation** | `startFromWarmHold` `:857-965` (swap `:880`, re-activate `:891`, exclusive wait `:892`, first-buffer gate `:940-955`); swap previously measured **15–19 ms** (`:873`) |
| Teardown (cool) | restore prior category | `setActive(false, .notifyOthersOnDeactivation)` — this is what un-blocks other apps | engine stopped, tap removed | `exitWarmHold` `:1593-1633` → `fullyTeardownEngine` `:1652-1661` → `restoreSession` `:1798-1830` (deactivate `:1813`) |

### 1.2 Timer, kill switches, publication

- Duration: `warmHoldCooldownDuration()` `:1457-1464`; `AppGroup.warmHoldDurationSeconds`
  default **120 s**, clamped **[60 s, 1800 s]** — the owner's "~30 minutes" is the 1800 s
  ceiling (`Shared/AppGroup.swift:359-370`; enable flag `:330-333`). Snapshot at entry;
  cooldown `Task.sleep` `:1483-1494`.
- Warm state publishes `.warmIdle` + liveness via `PipelinePhaseProjection` `:1515-1538`.
- Gentle releases only: `releaseWarmHold()` `:1639-1642`; Settings kill-switch observer
  `:2494-2501,2614-2618`; interruption `.began` while warm → `exitWarmHold()`
  `:2543-2567` (comment there explicitly says mixable idle means ordinary playback
  *coexists* and only hard interruptions — calls/alarms/Siri — still arrive); route-loss
  `:2572-2584`; engine-config-change with deliberate-swap grace `:2588-2612`; media-services
  reset/lost `:2620+`.
- Background entitlement: `UIBackgroundModes: [audio]` — `Jot/project.yml:253-254`.

### 1.3 What "warm" actually buys (this matters for every option)

- **NOT model load.** Model warm-up is a separate axis (`TranscriptionService.warmIfNeeded`,
  `ModelLoadTimekeeper` — capture-first architecture starts the mic immediately and awaits
  the model at stop; `ARCHITECTURE.md:61`).
- **The dominant value is the iOS background-start prohibition.** iOS will not let an app
  *start* microphone capture from the background; a keyboard extension can never touch the
  mic at all. The keyboard's instant cross-app dictation works only because the app already
  holds an ACTIVE capturing session it can resume in place (Darwin-notification trigger →
  `startFromWarmHold`, "silent in-place, sub-100ms" — `Jot/tmp/keyboard-warm-mic-60s-research.md`
  §1a, §2; Willow's help center states the same Apple rule for their product).
  **Any option that fully deactivates the session while idle kills the feature** — the
  background resume would need a fresh record-activation from background, which iOS denies.
- Secondary value: skipping session config + hardware acquisition (category swap 15–19 ms
  measured; exclusive-input wait ≤500 ms; cold path additionally rebuilds the engine).

### 1.4 Interaction with the build-289 capture fix

The 289 fix ("first recording captures nothing") lives entirely on the **capture-entry
paths**: `awaitExclusiveInput` after every swap to exclusive `.record` (`:1706-1745`,
`:880-892`) plus the first-buffer gates (`:820-838`, `:940-955`). It does not constrain
the *idle* configuration at all — every option in §4 keeps those guarantees untouched
because they only change what the session/engine look like **between** captures.

---

## 2. Why Reddit specifically

### 2.1 What Reddit's player is known to do (KNOWN, sourced)

- Reddit's iOS app has a long, documented history of *audio-session politeness logic*
  around other apps' audio: muted autoplay that must not kill background music, a
  **"Quiet Audio Mode"** setting, and years of bugs where scrolling videos paused
  Spotify/Apple Music — i.e., the app actively senses and reacts to other audio rather
  than blindly claiming the route.
  [DroidWin: Reddit pauses third-party music players](https://droidwin.com/fix-reddit-app-pauses-music-in-third-party-music-players/),
  [EasyFixPro: Reddit keeps pausing my music](https://easyfixpro.com/reddit-keeps-pausing-my-music/),
  [Dextrava: Reddit sound not working / Quiet Audio Mode](https://dextrava.com/fixed-reddit-sound-not-working/).
- The standard iOS inline-video pattern (WebKit implements it this way and Reddit-family
  clients mirror it): **muted playing video holds Ambient/no session; the unmute moment is
  when a real `MediaPlayback` (non-mixable `.playback`) claim happens** —
  [WebKit commit: AudioSession category tracking for muted→unmuted media](https://github.com/philn/WebKit/commit/0b6f4e7703f54fb929fd7a17b7d5eb56c8325e7d).
- Best available window into "Reddit-client" logic: the Apollo-Reborn client **gates its
  audio-session claims on `isOtherAudioPlaying`** — "with music playing, a muted video's
  System PiP is skipped rather than pausing the music, and the claim is re-checked once
  audio goes idle" — [Apollo-Reborn PR #569](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/569).
  This is the pattern: *check `isOtherAudioPlaying` → if true, don't play / stay muted /
  defer.*

### 2.2 What Jot's idle warm session looks like to Reddit (INFERRED, testable)

- Jot idles as an **active `.playAndRecord` session with a running duplex AVAudioEngine**
  (§1.1). `.playAndRecord` owns an output leg; a running engine renders (silent) output
  continuously.
- `AVAudioSession.isOtherAudioPlaying` in *another* app is known to read true for
  surprisingly passive sessions — Apple even shipped a bug where the system's own
  **Sound Recognition** input listener flipped it true device-wide
  ([FB13297689](https://github.com/feedback-assistant/reports/issues/438)). An active
  mixable `.playAndRecord` session with running I/O is therefore very likely to read as
  "other audio playing" to Reddit. **This is the single most load-bearing unverified claim
  in this doc → §5.1 probe.**
- `secondaryAudioShouldBeSilencedHint` is documented to flip **only for a non-mixable
  competitor** ([Apple docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/secondaryaudioshouldbesilencedhint)),
  so Jot's *mixable* session should NOT set it — which is why the hypothesis centers on
  `isOtherAudioPlaying`, the cruder signal.

### 2.3 Why YouTube and Music survive (KNOWN semantics + inference)

Apple's contract: a **mixable** session neither interrupts nor is interrupted by ordinary
playback; a **non-mixable** activation interrupts *other non-mixable* sessions
([mixWithOthers docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers),
[Audio Session Programming Guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html)).
So when Music/YouTube activate non-mixably, Jot's mixable idle session simply coexists —
no interruption is delivered to Jot (matching the `:2546-2556` comment), Jot keeps warm,
and their audio plays. They play **because they don't ask whether anyone else is playing —
they just activate.** Reddit asks first. That asymmetry — OS arbitration says yes, app
policy says no — is exactly the observed YouTube-yes/Reddit-no split, and no
OS-level-denial theory (e.g. `AVAudioSessionErrorCodeInsufficientPriority` `'!pri'`
[docs](https://developer.apple.com/documentation/coreaudiotypes/2962796-anonymous/avaudiosessionerrorcodeinsufficientpriority))
explains it, because an OS denial would hit Music too. (Kept as fallback hypothesis H2 in
§5.2 anyway — label: POSSIBLE.)

### 2.4 Failure-mode taxonomy (for the experiment matrix)

- **H1 (LIKELY, primary):** Reddit reads `isOtherAudioPlaying == true` (caused by Jot's
  idle session) and its player defers/refuses/stays paused. Predicts: probe app shows
  `true`; Reddit muted-inline may still scroll-play but unmuted/fullscreen refuses.
- **H2 (POSSIBLE, fallback):** Reddit's non-mixable activation is denied by iOS because
  another app holds an *active input* in the background ('!pri'/`cannotInterruptOthers`
  family), and Reddit swallows the error where YouTube/Music retry or pre-own the route.
- **H3 (UNLIKELY):** `secondaryAudioShouldBeSilencedHint`-driven pause — ruled out on
  paper (mixable sessions don't set it), verify incidentally via the probe.

---

## 3. How Willow can do it (what we verified, what we infer)

**Verified from Willow's public docs** ([taken-back-to-app article](https://help.willowvoice.com/en/articles/12855752-why-am-i-taken-back-to-the-willow-ios-app-before-i-can-dictate),
[yellow-indicator article](https://help.willowvoice.com/en/articles/12855770-why-do-i-see-the-yellow-microphone-indicator-or-floating-island-that-says-on-when-i-use-willow-on-ios)):

- Willow faces the **identical Apple constraint** ("Apple does not allow any third-party
  app or keyboard to start using the microphone in the background unless the app is active
  first") and solves it the same shape as Jot: foreground once → start a background mic
  session → keyboard works everywhere while it lives. Yellow indicator/live-activity stays
  on the whole time; configurable 30 s–2 h timeout (per their App Store dev replies —
  see `Jot/tmp/keyboard-warm-mic-60s-research.md` §2a for sourcing caveats).
- So Willow is NOT doing anything Jot can't: same entitlement, same activation gate, same
  persistent session. **The difference must be in the idle-state session/IO configuration**
  — which they don't document. Candidates, ranked by plausibility:

| # | Candidate Willow difference | Plausibility | Why it would spare Reddit | Jot analog |
|---|---|---|---|---|
| a | **I/O not running while idle** — session active, engine/recorder paused between dictations (indicator can lag/persist; their "session" framing is about the *window*, not literal continuous capture) | High | No output rendering → other apps likely see `isOtherAudioPlaying == false` | Option B (§4) — `engine.pause()` idle, the ORIGINAL Cut C design (`keyboard-warm-mic-60s-research.md` §1: "Cut C — real warm hold via `engine.pause()` while keeping AVAudioSession active"); Jot's shipped code diverged by keeping the engine running |
| b | Input-only graph (AVAudioRecorder/AURemoteIO input-only), no output leg even in category | Medium | Nothing renders; less likely to register as "playing" | Partially reachable: keep `.playAndRecord` category but ensure no render; or `.record` idle (loses mixability — pre-223 regression risk) |
| c | Different mode/options (`.default` vs `.measurement`, `.duckOthers`, voice-processing) | Low-Medium | Unclear; arbitration is category-level | Cheap rows in the §5 matrix |
| d | iOS 17+ `AVAudioApplication.setInputMuted(true)` while idle | Low-Medium | Signals "not capturing"; system may relax how the session is advertised ([setInputMuted](https://developer.apple.com/documentation/avfaudio/avaudioapplication/setinputmuted(_:)), [overrideMutedMicrophoneInterruption](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/overridemutedmicrophoneinterruption)) | Option C (§4) |

Per-candidate scorecard against Jot's three invariants (instant start; 289 guarantees;
never force-stop): **(a)** preserves all three — session stays active so background resume
is legal, resume adds one `engine.start()` (~10–50 ms hypothesis, ibid.), and the 289
exclusive-wait + first-buffer gates still run unchanged; **(b)** same, minus the
`.record`-idle sub-variant which re-blocks everyone (pre-223 behavior — rejected);
**(c)/(d)** change nothing structural, pure config toggles. A "configured-but-inactive"
variant (activate only at capture) fails invariant 1 outright — background activation for
record is denied (§1.3) — and can be dismissed without a device test.

---

## 4. Options, ranked

**Option A — Probe-first diagnosis (do this first, half a day).** Build a 20-line SwiftUI
probe app (scratch project, NOT in Jot) that displays `isOtherAudioPlaying` +
`secondaryAudioShouldBeSilencedHint` + `currentRoute` once per second. Run the §5.1 matrix.
No product risk; converts H1 from "likely" to "confirmed" and tells us which idle variant
actually clears the signal. *Latency risk: none. 289 risk: none.*

**Option B — pause the engine during idle warm (RECOMMENDED fix candidate).** In
`enterWarmHold`, after `makeWarmIdleSessionMixable()`, call `engine.pause()`; in
`startFromWarmHold`, after the category swap + `awaitExclusiveInput`, call `try engine.start()`
before the first-buffer wait (and relax the `engine.isRunning` entry guards to accept
paused-with-tap). Session stays ACTIVE (background resume stays legal); tap stays
installed. This is literally the original locked Cut C design that the implementation
drifted from. *Latency risk: low (+~10–50 ms hypothesized, measured by the existing
resume instrumentation; the 15–19 ms swap dominates today). 289 risk: low —
`awaitExclusiveInput` and the first-buffer gate remain the acceptance gates, and a paused
engine that fails to restart falls into the existing `warmNoInput` → cold-start fallback.
Never-force-stop: untouched. Open risks to measure: does the orange indicator turn off
while paused (owner may see that as a feature; App Review framing changes), and does
`engine.pause()` in background survive 30 min without the HAL reclaiming the unit
(media-services observers `:2620+` already cover the death case).*

**Option C — iOS 17 input-mute during idle warm.** `AVAudioApplication.shared.setInputMuted(true)`
on warm entry, `false` on resume; optionally `.overrideMutedMicrophoneInterruption`.
Orthogonal to B; one extra matrix row. *All risks: near zero to try; effect on Reddit
unknown (undocumented arbitration effect) — pure experiment.*

**Option D — idle config tweaks (mode `.default`, drop `.measurement`, try
`.playback`+`.mixWithOthers` idle).** Only if A shows the signal follows mode/options
rather than running I/O. `.playback` idle would force an engine rebuild on resume
(input leg vanishes) — probably violates the sub-100 ms silent resume; measure before
accepting. *Latency risk: medium-high for the `.playback` row.*

**Option E — accept + document (fallback).** If nothing clears Reddit's check while I/O
must run, this is a Reddit-app-policy limitation; document it in the warm-hold Settings
copy ("some video apps pause while the mic is held") and keep the 223 behavior. The prior
"there is no other way" conclusion is only true if B, C, and D all fail — which nothing
yet shows.

Rejected: reverting to non-mixable `.record` idle (re-blocks YouTube/Music — the 223 bug);
polling-and-yield on `isOtherAudioPlaying` (Reddit never starts, so the property never
flips — the chicken-and-egg already identified in `docs/warm-hold-audio-yield/design.md`
§3.4); full deactivation while idle (kills background resume, §1.3).

---

## 5. Minimal device experiments

### 5.1 THE experiment (decides H1, ~1 hour with the probe app)

Probe app on screen (Split View not needed — foreground the probe, Jot in background),
read `isOtherAudioPlaying`:

| Jot state | Predicted (H1) |
|---|---|
| No warm hold | false |
| Warm idle, current config (`.playAndRecord`+mix, engine running) | **true** ← the money row |
| Warm idle + `engine.pause()` (Option B, debug toggle) | false |
| Warm idle + input muted (Option C) | ? |
| Actively capturing (`.record` exclusive) | true (expected, fine) |

If the money row reads **true** and the Option-B row reads **false**, H1 + fix are both
confirmed before touching Reddit at all. If the money row reads **false**, H1 dies:
promote H2 and go straight to §5.2.

### 5.2 Reddit confirmation matrix (after 5.1, ~30 min)

{Jot: off / warm-current / warm-B / warm-C} × {Reddit: inline muted scroll / unmuted tap /
fullscreen with sound} → does it play, and does Jot's warm survive (check
`DiagnosticsLog` for the interruption/`exitWarmHold` lines `:2555`, `:1628`). Also record
one control row each for YouTube and Apple Music — including whether warm SURVIVES them
(the mixable-coexistence claim in `:2546-2556` is itself unverified telemetry-wise).

### 5.3 Regression gates for whichever variant wins

Existing instrumentation already covers them: resume latency + "first buffer confirmed"
(`:964`), `waited for exclusive mic` diagnostics (`:1719-1734`), cold-fallback counters
(`warmNoInput` path). Acceptance: silent in-place resume, no new cold-fallbacks, 289
diagnostics quiet, orange-indicator behavior explicitly observed and reported to owner.

---

## 6. Sources

Code: `Jot/App/Recording/RecordingService.swift`, `Jot/Shared/AppGroup.swift`,
`Jot/project.yml`, `docs/warm-hold-audio-yield/design.md` (+ `design-review.md`),
`Jot/tmp/keyboard-warm-mic-60s-research.md`, `Jot/ARCHITECTURE.md` §2.1/§13.2.

Web (key): [Willow: why taken back to app](https://help.willowvoice.com/en/articles/12855752-why-am-i-taken-back-to-the-willow-ios-app-before-i-can-dictate) ·
[Willow: yellow indicator](https://help.willowvoice.com/en/articles/12855770-why-do-i-see-the-yellow-microphone-indicator-or-floating-island-that-says-on-when-i-use-willow-on-ios) ·
[Apollo-Reborn PR #569 (Reddit-client session-claim gating)](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/569) ·
[WebKit muted-media session category commit](https://github.com/philn/WebKit/commit/0b6f4e7703f54fb929fd7a17b7d5eb56c8325e7d) ·
[FB13297689 isOtherAudioPlaying false-positive from input listener](https://github.com/feedback-assistant/reports/issues/438) ·
[Apple: mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) ·
[Apple: secondaryAudioShouldBeSilencedHint](https://developer.apple.com/documentation/avfaudio/avaudiosession/secondaryaudioshouldbesilencedhint) ·
[Apple: insufficientPriority](https://developer.apple.com/documentation/coreaudiotypes/2962796-anonymous/avaudiosessionerrorcodeinsufficientpriority) ·
[Apple: setInputMuted](https://developer.apple.com/documentation/avfaudio/avaudioapplication/setinputmuted(_:)) ·
[Apple: Audio Session Programming Guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html) ·
[DroidWin: Reddit pauses music](https://droidwin.com/fix-reddit-app-pauses-music-in-third-party-music-players/) ·
[EasyFixPro: Reddit pausing music](https://easyfixpro.com/reddit-keeps-pausing-my-music/) ·
[Dextrava: Quiet Audio Mode](https://dextrava.com/fixed-reddit-sound-not-working/) ·
[TechCrunch on Willow](https://techcrunch.com/2025/11/12/willows-voice-keyboard-lets-you-type-across-all-your-ios-apps-and-actually-edit-what-you-said)


## Status update (2026-08-31)

Both experiment artifacts are BUILT (uncommitted): the probe app at `~/code/AudioCoexistProbe` (reads `isOtherAudioPlaying` + silence hint 1/sec without activating its own session) and the hidden Settings toggle "Pause engine while warm (debug)" (5-tap Version reveal, key `debug.warmHoldEnginePause`, applies from the NEXT warm window) wired through `RecordingService.enterWarmHold`/`startFromWarmHold`. The matrix is runnable end-to-end on the owner's phone.

## Status update (2026-09-26, build 309)

In-app test switch shipped: Settings → Privacy → Keep mic ready → **Idle mode (test)** (`AppGroup.warmIdleVariant`,
`WarmIdleVariant` in `Shared/AppGroup.swift`). Variants: A current · B `.default` mode · C input muted
(`AVAudioApplication.setInputMuted`) · D default+muted · E engine paused · F default+paused. Applied in
`RecordingService.enterWarmHold` / `makeWarmIdleSessionMixable` / `applyWarmIdleVariant`; paused engines restart in
`startFromWarmHold` (early first-buffer arm), mutes are cleared on resume, teardown and cold `configureSession`.
Help → Diagnostics **WARM** lines: entered, resume OK (ms), resume FAILED → cold, ended (reason — "interrupted by
another app" is the Reddit signal), and "Jot was frozen Ns" (1 s liveness tick gap > 5 s = iOS suspended the app,
the risk for E/F). The standalone WarmMicLab probe (scratchpad) also exists. Research round: iOS 27 SDK adds no
background-mic or keyboard-mic path; competitors (Wispr, Willow, open-source keyboards) all idle a running
`.playAndRecord` engine, mostly in `.default` mode.

## ROOT CAUSE (2026-09-26, from the device's audiomxd log) — fixed in build 310

The 309 idle variants all failed for one reason: **the idle swap never happened.** After a keyboard dictation Jot
is in the background, and iOS refuses to change an active session's category there:
`Warm-hold mixable (.playAndRecord) failed — OSStatus 560557684` (`'!int'`, cannotInterruptOthers); audiomxd:
`Re-setting audioCategory to 'Record' ... because BeginInterruption returned an error`. The fallback left an
**exclusive `.record` session** (`[Record/Measurement] [NonMixable]`) for the whole warm window; Reddit's player
(`MediaPlayback/Default [Mixable]`) goes silent next to it. H1 in §2 was wrong: nothing was ever mixable in the
background. Willow's session in the same log: `PlayAndRecord_NoBluetooth_DefaultToSpeaker / Default [Mixable]`,
set once in the foreground, never swapped.

Fix (310): one shared session for capture AND idle — `RecordingService.applySharedSessionConfig`
(`.playAndRecord` / `.measurement` / `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]`), applied by
`configureSession` whenever the start is in the foreground; warm entry and warm resume then change nothing.
A start that begins in the background (Action Button) keeps the legacy exclusive `.record` path (2026-04-21
AURemoteIO fix) and its warm window logs "EXCLUSIVE". The 309 test switch was removed. Behaviour change:
other apps' audio keeps playing during dictation (it used to be interrupted).

How the log was obtained: `sudo log collect --device-udid <udid> --last 45m` over the CoreDevice (Wi-Fi) pairing,
then `log show … | grep audiomxd | grep -E "cmsSetIsActive|cmsSetAudioCategory|BeginInterruption"`.

## Regression + fix (2026-09-30, build 321)
Owner: Reddit silent again on 320. Device log: the keyboard's URL-bounce cold start ran `configureSession` while the
scene was still activating (UIKit "Deactivation reasons" pending at 12:36:24.068) → `applicationState == .inactive`
→ the 310 gate (`== .active`) took the legacy exclusive `.record` path (audiomxd: `set audioCategory to 'Record'` at
.135), and every warm entry's mixable swap then failed '!int' as before. Fix: shared session whenever
`applicationState != .background`. Lesson: 310 was verified only with a recording started while Jot was already open.

## Independent review + structural fix (2026-09-30, build 322)
Review (Opus agent) enumerated every recording start path. Remaining ways to hold an EXCLUSIVE warm window after 321:
H1 warm-resume failure → cold `configureSession` while backgrounded → legacy `.record`; H2 cold-launch mic-race retries
(75 ms × 2 s) crossing into background after a quick swipe-back; M2 `.inactive` on the way to background; M3 a
foreground shared-config throw. Also found: the "held mode" was logged nowhere readable (H3).
Fix (one rule, not per-path patches): `enterWarmHold` never holds an exclusive session — if `!sessionIsShared` and the
shared swap fails, it releases the mic (`fullyTeardownEngine`) and logs "Mic released after dictation — couldn't share
audio…" to Diagnostics; `makeWarmIdleSessionMixable` no longer falls back to `.record`. Cost: the next keyboard tap
after such a dictation opens Jot (foreground → shared). "recording stopped" Diagnostics now carries `sharedAudio`.
Per-build check: after a keyboard cold start + warm resume, Help → Diagnostics "recording stopped" must show
sharedAudio=true; device-log grep for "Re-setting audioCategory to 'Record'" / "[Record/Measurement] [NonMixable]"
must be empty during a warm window.
