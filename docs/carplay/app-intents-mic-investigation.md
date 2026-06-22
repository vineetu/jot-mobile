# App Intents → Microphone Investigation

**Question:** Does Jot's recording App Intent actually let Siri / the Action Button capture voice, and if not, what's required to fix it? This is the dependency the CarPlay-via-Siri plan (`docs/carplay/discovery.md`) rests on.

**Date:** 2026-06-19. **Verdict up front:** The owner's symptom — "even if Siri launches it, it can't gain access to the microphone" — is **correct and expected behavior**, not a bug we can patch in the current shape. Two compounding problems: (1) the code does **not** conform to `AudioRecordingIntent` despite extensive doc-comments claiming it does, and (2) even a *correct* `AudioRecordingIntent` implementation **cannot start a recording from a cold background** — Apple's current guidance (2025–2026) is that the session must be started while the app is in the foreground, and the intent/Live Activity can only *manage* (pause/resume) an already-running session.

Confidence levels per the house style: **Confirmed** = directly observed in code or stated in an Apple primary source; **Likely** = strong inference; **Possible** = partial evidence; **Unknown** = no evidence.

---

## 1. How the recording intent is wired today

### The three intents

All three dictation-family intents live in `Jot/App/Intents/`:

| Intent | File | Conformance (actual) | `openAppWhenRun` | Registered as AppShortcut? |
|---|---|---|---|---|
| `RecordAndTranscribeIntent` | `RecordAndTranscribeIntent.swift:105` | `: AppIntent` | `false` (`:117`) | **Yes** — primary tile (`JotAppShortcuts.swift:76`) |
| `DictateIntent` | `DictateIntent.swift:82` | `: AppIntent` | `true` (`:98`) | No (`isDiscoverable=false`, `:132`) |
| `TranscribeAudioFileIntent` | `TranscribeAudioFileIntent.swift:71` | `: AppIntent` | `false` | No (file-in/text-out only) |

### CRITICAL FINDING — the `AudioRecordingIntent` conformance is fiction

`RecordAndTranscribeIntent`'s doc-comment (`RecordAndTranscribeIntent.swift:21-26`, repeated at `:53-58`) states the intent conforms to `AudioRecordingIntent`, which "promotes execution into the main-app process and authorises `AVAudioEngine` without foregrounding." `JotAppShortcuts.swift:22` repeats this: *"`openAppWhenRun = false` + `AudioRecordingIntent` conformance gives us the 'no app bounce' target experience."* `TranscriptStore.swift:14` repeats it again.

**The struct declaration is `struct RecordAndTranscribeIntent: AppIntent` — plain `AppIntent`, nothing else** (`RecordAndTranscribeIntent.swift:105`). **Confirmed** by grep: the only occurrences of the token `AudioRecordingIntent` anywhere in the source tree are inside **doc-comments** — never in a type's conformance list (`grep -rn "AudioRecordingIntent" Jot --include="*.swift"`, every hit is a `///` line). The body of `RecordAndTranscribeIntent.swift:60-71` even *admits* this in a later comment ("Conforms to `AppIntent` only … Plain `AppIntent` is what binds today") — so the file **internally contradicts its own header**. The header oversells; the body is honest.

**Consequence:** `RecordAndTranscribeIntent` gets **none** of the `AudioRecordingIntent` runtime treatment. It is a plain `AppIntent` with `openAppWhenRun = false`, which means iOS runs it **out-of-process in the AppIntents extension runtime, in the background, with no audio-session privilege**. (`Confirmed` — see §3.)

### The mechanism the intent actually uses to get the mic

`perform()` (`RecordAndTranscribeIntent.swift:135-156`) reads `DictationIntentBridge.shared.controller` (a lazily-constructed `DictationControllerImpl`, `DictateIntent.swift:336-409`) and calls `controller.startRecording()`. That funnels to `RecordingService.shared.start()` (`DictateIntent.swift:411-416`), which calls `configureSession()` (`RecordingService.swift:1239-1276`):

```swift
try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])  // :1252
try session.setActive(true, options: [])                                          // :1258
```

This is a **direct `AVAudioSession.setActive(true)` from whatever process/state the intent is running in.** There is no Live Activity, no foregrounding, no sanctioned-API handshake. (`Confirmed`.)

### The Live Activity path that the prior research assumed exists has been REMOVED

The earlier research doc (`docs/research/ios26-audiorecording-action-button.md`, §1 / fix #1) hinged on "start the Live Activity first, then `setActive` succeeds." **That path no longer exists in the codebase:**

- `DictationActivityCoordinator.start()` (`DictateIntent.swift:521-524`) is now a **no-op stub** — it sets a timestamp and clears follow-up state. There is **no `ActivityKit` / `Activity.request(...)` call** anywhere in it. The class header (`DictateIntent.swift:496-503`) confirms: *"the entire Live Activity path (ActivityKit, the JotWidget extension … and the `NSSupportsLiveActivities` plist key) has been removed."*
- **`NSSupportsLiveActivities` is absent from `project.yml`** (`Confirmed` — grep returns nothing). Without it no Live Activity can start at all.

So the intent calls `setActive(true)` with **no Live Activity in flight and no plist support for one.** This is the single most decisive fact in this investigation.

### Does Siri even surface this intent?

`JotAppShortcuts.swift:76-92` registers `RecordAndTranscribeIntent` with the phrase `"New \(.applicationName) note"`. So **Siri will match "New Jot note"** and the Action Button picker shows the tile. (`Confirmed`.) What happens when invoked is §2.

---

## 2. Failure mode + ranked root-cause hypotheses

### Observed failure mode

When Siri or the Action Button invokes `RecordAndTranscribeIntent`, the app is **not** brought to the foreground (`openAppWhenRun = false`). The intent runs out-of-process/backgrounded and calls `AVAudioSession.setActive(true)`. iOS **denies microphone activation from the background**, and `setActive` (or, in a correct `AudioRecordingIntent` build, the Live Activity start that precedes it) **throws**. The user gets nothing captured — exactly the owner's symptom. (`Confirmed` mechanism; the *exact* on-device NSError code is still **Unknown** — see H4.)

### Ranked hypotheses

**H1 — Platform privacy rule: you cannot start mic capture from a cold background, even with `AudioRecordingIntent`. (Confidence: Confirmed — this is the root cause.)**

Apple's current, explicit position (Apple Developer Forums thread **815725**, "Unable to trigger AudioRecordingIntent from background"):

> "Apple strictly prevents apps from initiating an AVAudioSession for recording from a completely backgrounded state."
> "Because of these privacy constraints, you cannot start an audio recording from scratch using an intent (like via a Shortcut or the Action Button) if the app isn't already active."
> "The Live Activity and its Intents can only be used to manage (pause/resume) an already established session, rather than launching a new one from a cold background state."

The reported error on that thread is `Live Activity start failed: The operation couldn't be completed. Target is not foreground` — i.e. even the *Live Activity* (the supposed unlock) won't start from the background. This **directly overturns** the optimistic "start the Live Activity first and `setActive` will succeed" conclusion in our older research doc (`ios26-audiorecording-action-button.md` §1, fix #1). That doc reasoned from the *static* DocC clause ("you must start a Live Activity … or recording stops") and inferred the precondition was sufficient; the newer forum guidance shows it is **necessary but not sufficient** — the session still has to have been born in the foreground. ([815725](https://developer.apple.com/forums/thread/815725); corroborated by Apple DTS in [756507](https://developer.apple.com/forums/thread/756507): *"Your app needs to be in the foreground before the user can start recording audio."*)

**H2 — Code does not conform to `AudioRecordingIntent` at all. (Confidence: Confirmed.)**

Even setting H1 aside, the intent is a plain `AppIntent` (`RecordAndTranscribeIntent.swift:105`). A plain `AppIntent` with `openAppWhenRun = false` runs **out-of-process** with no audio privilege. To run in the app's process you must adopt a `SystemIntent` subprotocol (`LiveActivityIntent`, `AudioPlaybackIntent`, or `AudioRecordingIntent`) — none is adopted. So the intent is in the worst possible position: backgrounded **and** out-of-process. (`Confirmed` by conformance grep; process-isolation rule per [Zach Waugh](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process).)

**H3 — The Live Activity precondition for `AudioRecordingIntent` is structurally impossible in the current build. (Confidence: Confirmed.)**

`AudioRecordingIntent`'s own contract requires a running Live Activity for the duration of recording. The Live Activity subsystem (`ActivityKit`, the widget extension Activity type, and `NSSupportsLiveActivities`) was **deliberately ripped out** (`DictateIntent.swift:496-503`; plist grep negative). So even if someone re-added `: AudioRecordingIntent` to the struct tomorrow, it would fail its own runtime contract immediately. (`Confirmed`.)

**H4 — Exact AVAudioSession error code unverified. (Confidence: Unknown — needs on-device log.)**

`configureSession` logs `domain`/`code`/`localizedDescription`/`userInfo` on failure (`RecordingService.swift:1269-1272`). We have never captured the value from an actual Siri/Action-Button-triggered run. Likely `cannotInterruptOthers` (560557684) or a "Target is not foreground" Live-Activity error, but this is the one datum that would convert H1 from Confirmed-by-docs to Confirmed-on-this-device. **This does not change the verdict** — H1 is already confirmed by Apple's own statements — but it would remove all residual doubt.

**Ruled OUT as the cause (so we don't chase them):**

- **Missing `NSMicrophoneUsageDescription`** — present (`project.yml:194`). (`Confirmed` not the cause.)
- **Missing `UIBackgroundModes: [audio]`** — present (`project.yml:195-196`). Note this key governs *continuing* audio while backgrounding; it does **not** grant *starting* mic capture from the background. So its presence is necessary-but-irrelevant to this failure. (`Confirmed` not the cause.)
- **Missing AppIntents entitlement** — Apple documents **no** special entitlement for `AudioRecordingIntent`. (`Likely` not a factor.)
- **Intent not discoverable by Siri** — it is registered and phrase-matched (`JotAppShortcuts.swift:76`). (`Confirmed` not the cause.)

---

## 3. What's required to make Siri / Action-Button-triggered recording actually work

There is **no configuration-only fix.** Apple's privacy model forbids starting the mic from a cold background. Two viable shapes, both requiring real work:

### Option A — Foreground bounce (the Apple-DTS-blessed, reliably-working path)

Make the recording intent foreground the app to acquire the mic. This is what `DictateIntent` already does (`openAppWhenRun = true`, `DictateIntent.swift:98`), and what Apple DTS explicitly prescribes:

> "Consider overriding the `openAppWhenRun` property to return `true` … This allows … your app [to be] brought to the foreground when the user intends to record audio." — Apple DTS, [thread 756507](https://developer.apple.com/forums/thread/756507)

- **Plist/entitlements:** `NSMicrophoneUsageDescription` + `UIBackgroundModes: [audio]` — **both already present.** No new entitlement.
- **AVAudioSession:** the existing `.record / .measurement / [.mixWithOthers]` path works once the app is foreground.
- **Cost:** a visible app-switch flash on every invocation. For CarPlay/Siri this means the **phone** screen bounces into Jot; whether that's acceptable hands-free is a UX call for the CarPlay plan. Shipping apps (Wispr Flow) accept this bounce, and Wispr's docs note iOS 26.4+ now *forces* it even for `AudioRecordingIntent` apps ([Wispr Flow](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone)).

### Option B — Full `AudioRecordingIntent` rebuild (no foreground bounce, but heavy and fragile)

To legitimately use `openAppWhenRun = false` without a bounce, you must rebuild ALL of:

1. **Conform** the intent to `AudioRecordingIntent` (and `LiveActivityIntent` to host stop/pause buttons): `struct RecordAndTranscribeIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent`. (Currently absent.)
2. **Re-add the entire Live Activity subsystem** that was ripped out: `ActivityKit` Activity type, the widget-extension registration, **and `NSSupportsLiveActivities` in `project.yml`** (currently absent). Without a running Live Activity, `AudioRecordingIntent` stops recording by contract.
3. **Start the Live Activity BEFORE `setActive(true)`**, and keep it alive for the whole recording.
4. **AND STILL** — per Apple's 815725 guidance — **the very first start must happen in the foreground.** The Live Activity + intent only let you *pause/resume from the background* a session that was *born foreground*. So Option B **does not actually deliver** cold "Hey Siri, jot down…" capture either. It delivers a no-bounce *toggle* of an already-running session.

**Confidence:** Confirmed that Option B is required for no-bounce; Confirmed (815725) that even Option B cannot start a fresh recording from a cold background. The "no app bounce, Live Activity is the UI" target experience the doc-comments describe (`RecordAndTranscribeIntent.swift:9-11`) is **not achievable on current iOS for a cold start.**

---

## 4. Simulator test results

**What I could verify in the sim:** Nothing load-bearing — and the honest answer is that the simulator **cannot** confirm or deny this failure, so I deliberately did **not** burn build/boot cycles chasing a result it structurally can't produce.

- **Siri voice invocation:** not testable in the simulator (no Siri voice pipeline). (`Confirmed` limitation.)
- **Real microphone capture:** the simulator has no real mic and does not enforce the background-mic privacy gate the way a device does; a sim "success" would prove nothing about device behavior, and a sim "failure" could be a sim artifact. (`Confirmed` limitation.)
- **Action Button:** does not exist in the simulator. (`Confirmed`.)
- **Shortcuts-app invocation in sim:** could in principle launch the intent, but the failure under investigation is specifically the **background AVAudioSession privacy gate**, which the sim does not model. So even a green run would not falsify H1.

**What IS verifiable without any sim run, and was:** the code does not conform to `AudioRecordingIntent` (grep), the Live Activity subsystem is gone (code + plist grep), and `openAppWhenRun = false` (code). These are static facts that fully determine the failure given Apple's documented rules.

**What needs an on-device run to nail down (H4):** the exact `AVAudioSession` NSError code from a real Siri/Action-Button press, captured from `RecordingService.swift:1269-1272` via Console.app / idevicesyslog. This is a nice-to-have for certainty, **not** a blocker for the verdict.

---

## 5. Bottom line for CarPlay

**Is hands-free "Hey Siri, jot down…" capture achievable?**

- **Cold, fully hands-free, zero-glance, no app bounce: No.** (`Confirmed` by Apple.) iOS forbids starting the mic from a cold background regardless of `AudioRecordingIntent`. Any path that begins from "Hey Siri" with the app not already active will fail to capture, by platform design.
- **With a foreground bounce (Option A): Yes, capture works** — but the **phone** visibly switches into Jot to grab the mic. Whether that satisfies the CarPlay "hands-free" bar is a product judgment for the CarPlay plan, not a technical blocker. On iOS 26.4+ Apple *imposes* this bounce even on correct `AudioRecordingIntent` apps, so it is the de-facto standard, not a hack.

**Is the current intent salvageable, or does it need a rebuild?**

- The current `RecordAndTranscribeIntent` is **not salvageable as-advertised.** It is a plain `AppIntent` with `openAppWhenRun = false` and no Live Activity — the exact combination that **cannot** get the mic. The doc-comments describing an `AudioRecordingIntent` "blessed path" are **aspirational fiction**; the code never implemented it and the supporting Live Activity subsystem has since been deleted.
- **Recommended path = Option A (foreground bounce), effort S–M.** Flip the registered Action Button / Siri intent to the `openAppWhenRun = true` shape (`DictateIntent` already implements exactly this and is one flag away from being re-registered — `DictateIntent.swift:118-131` documents the OTA recovery flip). This is the only path that reliably captures audio today. **S** if simply re-registering `DictateIntent` as primary suffices; **M** once you account for routing the foregrounded capture sensibly for a CarPlay/driving context and handing back afterward.
- **Option B (full `AudioRecordingIntent` + Live Activity rebuild) = effort L, and it still does not deliver cold hands-free start.** It only buys a no-bounce pause/resume of a foreground-started session. For CarPlay's "Hey Siri" use case it does not solve the actual requirement, so **L effort for the wrong outcome** — do not pursue it for CarPlay.

**One concrete cleanup regardless of direction:** the `AudioRecordingIntent` claims in `RecordAndTranscribeIntent.swift:21-26/53-58`, `JotAppShortcuts.swift:22`, and `TranscriptStore.swift:14` should be corrected — they will mislead the next reader (they misled the basis of the prior research doc's "fix"). Flagged for the owner; not changed here per the diagnosis-only scope.

---

## Sources

- [Apple Dev Forums 815725 — Unable to trigger AudioRecordingIntent from background](https://developer.apple.com/forums/thread/815725) — the decisive primary source; cold-background mic start is impossible, Live Activity intents only manage an existing session.
- [Apple Dev Forums 756507 — Microphone Recording Fails When Launched from Shortcut (Apple DTS reply)](https://developer.apple.com/forums/thread/756507) — "app needs to be in the foreground before the user can start recording audio"; prescribes `openAppWhenRun = true`.
- [Apple Developer Docs — AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent) — Live Activity required for the duration of recording.
- [Zach Waugh — Forcing an AppIntent to run in the main app process](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process) — process-isolation rule: only `SystemIntent` subprotocols run in-process.
- [Wispr Flow — Action Button setup](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone) — shipping app; iOS 26.4+ forces a foreground app-switch to activate the mic.
- Internal cross-reference: `docs/research/ios26-audiorecording-action-button.md` — prior research whose central "start Live Activity first → setActive succeeds" fix is **superseded** by 815725 (the Live Activity itself fails from background).
- Code (this repo): `Jot/App/Intents/RecordAndTranscribeIntent.swift:21-26,105,117,135-156`; `Jot/App/Intents/DictateIntent.swift:82,98,118-132,411-416,496-524`; `Jot/App/Intents/JotAppShortcuts.swift:22,76-92`; `Jot/App/Recording/RecordingService.swift:1239-1276`; `Jot/project.yml:194-196` (no `NSSupportsLiveActivities`).
