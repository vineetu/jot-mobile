# Issue #3 — "Jot down" App Shortcut: "Audio engine failed to start" — Root-Cause Analysis

**Issue:** GitHub #3. The `RecordAndTranscribeIntent` "Jot down" App Shortcut, launched from Spotlight (and by extension the Action Button / Siri), fails with a banner:

> **Jot down a note** — Audio engine failed to start: The operation couldn't be completed. (com.apple.coreaudio…)

**Scope:** Investigation only — no code changed. Confidence levels per house style: **Confirmed** (directly observed in code or stated in an Apple primary source), **Likely** (strong inference), **Possible** (partial evidence), **Unknown** (no evidence).

**Verdict up front:** The owner's *problem* is real and the GitHub-comment diagnosis is *directionally correct on the mechanism but wrong on the prescribed fix (A)*. The failure is the platform privacy gate against starting microphone capture from a non-foreground process. Re-adding `AudioRecordingIntent` (hypothesis A) **will not** fix the Spotlight/cold-launch case — proven below by the authoritative Apple DTS source. The prior internal doc's core conclusion (hypothesis B: you must foreground; `openAppWhenRun = true` is the reliable path) is **correct**, though it slightly over-claims one detail. **Recommended fix: foreground-bounce — register the `openAppWhenRun = true` intent for the Action Button / Spotlight tile.**

---

## 0. AS IMPLEMENTED (2026-06-20)

Shipped fix is **hardened beyond §4's one-line flip**, per the adversarial review
(`issue-3-fix-review.md`): two must-fixes were folded in.
- **M1:** `openAppWhenRun` is deprecated at iOS 26.0 (our floor) → both
  `RecordAndTranscribeIntent` and `DictateIntent` now use
  `static var supportedModes: IntentModes { .foreground(.immediate) }` (SDK-confirmed).
- **M2 (the crux):** the mic-start is NOT called inline in `perform()` (iOS creates
  the foreground *during* `perform()` → inline start races it). The intents' START
  leg sets `DictationIntentBridge.pendingForegroundStart` + posts
  `Notification.Name.jotDictateFromShortcut`; `JotApp` starts via the existing
  scene-active-gated `triggerAutoStart` (in `handleSceneActive` for the
  cold/background launch, and via the notification observer for the
  already-foreground case). STOP leg stays inline (no foreground needed).
- Diagnostic logging added to the `engine.start()` catch (`RecordingService.swift`)
  to capture the CoreAudio domain/code, so a surviving race is detectable on device.
- All misleading `AudioRecordingIntent` doc-comments corrected.
- **On-device residual risk:** `supportedModes` could affect Action-Button binding
  (historically fragile); if the tile fails to bind, revert that property to
  `openAppWhenRun` (functional, deprecated). The deferred-start fix is independent.

## 1. Confirmed root cause

### 1.1 The exact failure point (Confirmed — code)

The banner string `"Audio engine failed to start: …"` is `RecordingError.engineStart` (`RecordingService.swift:30`), thrown at `RecordingService.swift:594` when `try engine.start()` (`:588`) throws.

The call order in `start()` is decisive:

1. `configureSession()` runs first (`RecordingService.swift:549`). It calls `setCategory(.record, .measurement, [.mixWithOthers])` (`:1252`) then `setActive(true)` (`:1258`). **If `setActive` had thrown, the error would be `RecordingError.sessionConfiguration` (`:1274`), not `.engineStart`.** The banner says `.engineStart`, so **`setActive(true)` returned successfully.** (Confirmed.)
2. Mic preflight `hardwareFormat.channelCount > 0 && sampleRate > 0` passes (`:564`) — else `.micUnavailable` (`:567`). So iOS reported a real input bus. (Confirmed.)
3. `AVAudioConverter` constructed OK (`:570`) — else `.converterUnavailable`. (Confirmed.)
4. `engine.prepare(); try engine.start()` (`:587–588`) throws → `.engineStart` (`:594`). (Confirmed.)

So the failure is specifically the **audio unit (AURemoteIO) failing to start the I/O**, *after* the session reports active. This matters: it is the I/O-graph start, not session activation, that CoreAudio refuses.

### 1.2 Why CoreAudio refuses (Confirmed mechanism — Apple DTS + code)

`RecordAndTranscribeIntent` is a **plain `AppIntent` with `openAppWhenRun = false`** (`RecordAndTranscribeIntent.swift:105`, `:117`). When launched from Spotlight / Action Button / Siri, **the app is not foregrounded.** The intent's `perform()` reaches `DictationIntentBridge.shared.controller.startRecording()` → `RecordingService.shared.start()` → `configureSession()` → `engine.start()` **from a non-foreground process state.**

Apple's official position (Apple DTS staff engineer, accepted answer, [thread 756507](https://developer.apple.com/forums/thread/756507), June 2024):

> "You cannot trigger an audio recording from the Shortcuts app. Your app needs to be in the foreground before the user can start recording audio."
> "Consider overriding the `openAppWhenRun` property to return `true` … This allows … your app [to be] brought to the foreground when the user intends to record audio."

The reported error in that thread is code **561015905** at `setActive`. Note: per Apple's `AVAudioSession.ErrorCode` mapping, **561015905 = `cannotStartPlaying` ('!pla')**; **`cannotStartRecording` ('!rec') is 561145187** ([Apple docs](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)). The exact code differs by build/route, but the *condition* is the same: the OS denies bringing up a recording I/O for a process that is not in the foreground when capture is initiated.

The most current real-world write-up (a May 2026 dictation-app article, [levelup.gitconnected.com](https://levelup.gitconnected.com/swift-ios-a-better-way-to-make-a-dictation-app-7badd94103e0)) states the gate precisely:

> "[`AudioRecordingIntent`] is **not** a magic permission that lets apps secretly start microphone capture from a cold/background state."
> "you cannot call `setActive(true)` on the audio session from background. However, once the session is activated, you can start/stop the audio engine in the background without reopening the app."

That last clause explains Jot's *specific* `.engineStart` (not `.sessionConfiguration`) symptom: from a background/headless launch the I/O start is the operation iOS is refusing. Whether `setActive` "succeeds" with the I/O blocked, or succeeds and the engine then can't bring up AURemoteIO, the observable result in Jot is the engine-start throw.

**Root cause (Confidence: Confirmed-by-docs; on-device error code Unknown):** Jot attempts to start microphone capture from a process that iOS does not consider foreground (the `openAppWhenRun = false` intent on a Spotlight/Action-Button/Siri launch). iOS's recording-privacy gate refuses to bring up the capture I/O, surfacing as `AVAudioEngine.start()` throwing → `.engineStart`.

---

## 2. Verdict on Hypothesis (A): re-add `AudioRecordingIntent` conformance

**DISPROVEN as a fix for the Spotlight / cold-launch case. (Confidence: Confirmed.)**

The GitHub comment's reasoning — "`AudioRecordingIntent` is the grant for intent-driven background recording; with no foreground and no `AudioRecordingIntent`, capture is unauthorized" — has the **right premise but the wrong conclusion.** `AudioRecordingIntent` is necessary for a no-bounce *managed* recording, but it is **not sufficient to start the mic from a cold background.** Three independent points:

1. **`AudioRecordingIntent` does not grant cold-background recording start.** The dedicated forum thread for exactly this attempt — [815725, "Unable to trigger AudioRecordingIntent from background"](https://developer.apple.com/forums/thread/815725) (answer Feb 2026) — reports the error `Live Activity start failed: … Target is not foreground` and concludes:
   > "Apple strictly prevents apps from initiating an AVAudioSession for recording from a completely backgrounded state."
   > "you cannot start an audio recording from scratch using an intent (like via a Shortcut or the Action Button) if the app isn't already active."
   > "The initial trigger to start the recording must happen in-app. The Live Activity and its Intents can only be used to manage (pause/resume) an already established session, rather than launching a new one from a cold background state."

   *(Caveat on source weight: thread 815725's answer is from a community member "farisdev," **not** Apple DTS. It is strong corroboration, but the authoritative source is the DTS reply in 756507, which prescribes the foreground bounce. They agree.)*

2. **`AudioRecordingIntent` carries a hard Live-Activity contract that Jot cannot currently satisfy.** Apple's docs + multiple sources: when using `AudioRecordingIntent` you **must start and keep a Live Activity alive for the duration of recording, or recording stops.** Jot's entire Live Activity subsystem (ActivityKit, the widget Activity type, and the `NSSupportsLiveActivities` plist key) was deliberately removed (`DictateIntent.swift:496–503`; `NSSupportsLiveActivities` absent from `project.yml` — grep-confirmed). So merely adding `: AudioRecordingIntent` to the struct would fail its own runtime contract immediately.

3. **Even a fully-rebuilt `AudioRecordingIntent` + Live Activity would only buy no-bounce pause/resume of a foreground-started session — not cold start.** Spotlight tapping "Jot down" with the app not active is precisely the cold-start case Apple forbids.

**Conclusion:** Hypothesis A is the wrong fix for issue #3. It would be large effort (re-add the entire Live Activity subsystem) for an outcome that still does not start the mic from Spotlight. The GitHub comment's fix #1 should not be pursued.

---

## 3. Verdict on Hypothesis (B): is `openAppWhenRun = true` foreground bounce actually necessary?

**CONFIRMED necessary for reliable capture. The prior internal doc's core claim is correct; one sub-claim is slightly overstated.**

- **"Cold background can never start the mic" — Confirmed correct** per Apple DTS (756507) and corroborated by 815725 and the May 2026 article. There is **no configuration-only headless path** that starts the mic from Spotlight/Action-Button/Siri when the app is not already foreground. (Confidence: Confirmed.)

- **`openAppWhenRun = true` is Apple's explicitly prescribed solution** (DTS, 756507). `DictateIntent` already implements exactly this (`DictateIntent.swift:98`) and is one registration away from being the bound tile. (Confidence: Confirmed.)

- **Where the prior doc slightly overstates:** it frames the gate as "out-of-process AppIntents extension runtime, no audio privilege" being a *compounding* cause. The process-isolation point is real (a plain `AppIntent` may run out-of-process), but it is **not** the load-bearing reason here. The decisive gate is **foreground-vs-not**, not in-process-vs-out — the May 2026 article confirms that even a correctly in-process `AudioRecordingIntent` cannot call `setActive(true)` from background. So "backgrounded **and** out-of-process — worst possible position" conflates two factors; only the first is determinative. This does not change the prior doc's verdict or recommendation, which stand.

**Conclusion:** Hypothesis B is correct. The foreground bounce is not a band-aid masking a fixable headless path; it is the only path Apple supports for cold mic-start. (It is the genuine root-cause fix given the platform constraint — consistent with the project's "no band-aids" standard, because the *true cause* is the platform gate and foregrounding is the sanctioned way through it.)

---

## 4. Recommended fix

Two viable shapes; I recommend the first and would ship it.

### Option A (SHIP THIS) — Foreground-bounce: bind the `openAppWhenRun = true` intent. Effort S–M.

Mechanism: make the Spotlight/Action-Button/Siri tile resolve to an intent with `openAppWhenRun = true`, so iOS foregrounds Jot before `perform()` runs; the existing `RecordingService.start()` path then succeeds because the app is foreground.

`DictateIntent` is already that intent. The minimal change:
1. Flip `DictateIntent.isDiscoverable` back to `true` (`DictateIntent.swift:132`).
2. Register `DictateIntent` as the `AppShortcut` in `JotAppShortcuts.appShortcuts` (`JotAppShortcuts.swift:76`) **in place of** `RecordAndTranscribeIntent` (or set `RecordAndTranscribeIntent.openAppWhenRun = true` and keep it as the tile — same net effect; choose one to avoid two near-duplicate tiles).

Why it works: `openAppWhenRun = true` brings Jot to the foreground; per Apple DTS this is exactly the precondition the recording-privacy gate requires. (Confidence: Confirmed by 756507.)

Config already in place — **no new entitlement / plist work needed**:
- `NSMicrophoneUsageDescription` — present (`project.yml:194`).
- `UIBackgroundModes: [audio]` — present (`project.yml:195–196`). *(Necessary to keep audio alive while backgrounding mid-recording; it does NOT grant cold-background start, so it is necessary-but-not-the-fix.)*
- No `AudioRecordingIntent` entitlement exists or is needed.

Tradeoff: a visible app-switch flash on every invocation (the **phone** screen bounces into Jot). This is the de-facto industry standard — Wispr Flow accepts the bounce, and Apple imposes it. For CarPlay/driving this is a separate UX judgment (see §5 of `app-intents-mic-investigation.md`), but for the Spotlight bug in issue #3 it is the correct, reliable fix.

**Decision note for the owner:** the simplest single-tile shape is to set `RecordAndTranscribeIntent.openAppWhenRun = true` and leave registration as-is — one-line change, keeps the current tile/phrase. The "swap to DictateIntent" route is equivalent but touches three files. I'd take the one-line `openAppWhenRun` flip on the already-registered intent.

### Option B (do NOT ship for this issue) — Full `AudioRecordingIntent` + Live Activity rebuild. Effort L.

Conform to `AudioRecordingIntent` (+ `LiveActivityIntent`), re-add ActivityKit + widget Activity + `NSSupportsLiveActivities`, start the Live Activity before `setActive`, keep it alive for the recording. **Still cannot cold-start from Spotlight** (§2). Buys only no-bounce pause/resume of a foreground-started session. Wrong outcome for issue #3; large effort. Reject.

---

## 5. What must be verified on a real device

Dev box constraints: I could read all source and Apple docs, but **could not build or run** (no on-device run was performed in this investigation; the simulator cannot model the background-mic privacy gate — it has no real mic and does not enforce the foreground requirement, so a sim run would prove nothing either way).

On-device, after applying Option A:
1. **Spotlight → "Jot down" tile records successfully** (the issue-#3 repro now captures audio). — the primary acceptance test.
2. Same from **Action Button** and **"Hey Siri, New Jot note."**
3. Confirm the **app foregrounds** on invocation (expected with `openAppWhenRun = true`) and hands back sensibly after stop.
4. **(Diagnostic, optional, to close the last Unknown):** before the fix, capture the exact `com.apple.coreaudio` NSError from the `engine.start()` catch on a real Spotlight press. The catch at `:589–595` currently throws `.engineStart(error)` but does **not** log the underlying domain/code (unlike `configureSession`, which logs them at `:1269–1272`). Adding equivalent `domain/code/userInfo` logging in the `engine.start()` catch would convert the root cause from Confirmed-by-docs to Confirmed-on-device. **Not a blocker** — the Apple DTS guidance already determines the fix.

Confidence the fix resolves issue #3: **High** — Apple DTS prescribes exactly this for exactly this symptom, and Jot already has a working `openAppWhenRun = true` implementation.

---

## 6. Doc-comment corrections needed (misleading `AudioRecordingIntent` claims)

These comments assert an `AudioRecordingIntent` "blessed headless path" that the code never implemented and that Apple's rules forbid for cold start. They misled the basis of prior reasoning and should be corrected (the body of `RecordAndTranscribeIntent.swift` already contradicts its own header):

- `RecordAndTranscribeIntent.swift:21–26` — "Conforming to `AudioRecordingIntent` promotes execution into the main-app process and authorises `AVAudioEngine` without foregrounding." The struct conforms to plain `AppIntent` only (`:105`); and even with the conformance, cold-background start is forbidden.
- `RecordAndTranscribeIntent.swift:55–58` — "`AudioRecordingIntent` conformance is what makes this correct: iOS 18+ grants … audio-session activation … so no foregrounding is needed." False per §1–2.
- `RecordAndTranscribeIntent.swift:45–47` — "Retrying the protocol conformance on current iOS 26.2 is what this intent is for." Retrying it will not fix issue #3.
- `JotAppShortcuts.swift:22` — "`openAppWhenRun = false` + `AudioRecordingIntent` conformance gives us the 'no app bounce, Live Activity is the UI' target experience." The conformance is absent and the target experience is unachievable for cold start.
- `Jot/Shared/TranscriptStore.swift:14` — "`RecordAndTranscribeIntent` (Action Button, iOS 18+ `AudioRecordingIntent`)" — same false conformance claim.
- `DictateIntent.swift:21–29` — broadly correct (it honestly uses `openAppWhenRun = true` and explains why), but it cites the Action-Button-binding-filter as the reason for dropping `AudioRecordingIntent`; the **more fundamental** reason is the cold-background prohibition. Worth a one-line note.

---

## Sources

- [Apple Dev Forums 756507 — Microphone Recording Fails When Launched from Shortcut (**Apple DTS**, accepted answer, June 2024)](https://developer.apple.com/forums/thread/756507) — authoritative: "app needs to be in the foreground before the user can start recording audio"; prescribes `openAppWhenRun = true`.
- [Apple Dev Forums 815725 — Unable to trigger AudioRecordingIntent from background (community, Feb 2026)](https://developer.apple.com/forums/thread/815725) — corroborating: cannot start recording from cold background even with `AudioRecordingIntent`; Live Activity intents only manage an existing session.
- [Apple Developer Docs — AVAudioSession.ErrorCode.cannotStartRecording (561145187 / '!rec')](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording) — error-code mapping (note: 561015905 = cannotStartPlaying '!pla', not recording).
- [levelup.gitconnected.com — "A Better Way to Make a Dictation App" (May 2026)](https://levelup.gitconnected.com/swift-ios-a-better-way-to-make-a-dictation-app-7badd94103e0) — current pattern: `AudioRecordingIntent` is "not a magic permission"; cannot `setActive(true)` from background; Live Activity mandatory; uses a conditional foreground-opening two-intent shape.
- Code (this repo): `RecordAndTranscribeIntent.swift:21–26,45–47,55–58,105,117,135–156`; `DictateIntent.swift:82,98,132,496–503`; `JotAppShortcuts.swift:22,76–92`; `RecordingService.swift:30,549,564,570,588,594,1252,1258,1269–1274`; `project.yml:194–196` (no `NSSupportsLiveActivities`).
- Prior internal doc reviewed: `docs/carplay/app-intents-mic-investigation.md` — its central verdict (foreground bounce required) is **confirmed correct**; its "out-of-process compounds the failure" framing is a minor overstatement (foreground, not process-isolation, is the determinative gate).
