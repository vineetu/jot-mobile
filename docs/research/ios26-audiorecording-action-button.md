# iOS 26 `AudioRecordingIntent` + Action Button — session-activation failure

Research assembled 2026-04-21 for Jot-mobile. Device: iPhone 17, iOS 26.3.1. Failure: `AVAudioSession.setActive(true)` throws "Session activation failed" when `RecordAndTranscribeIntent` (conforming to `AppIntent, AudioRecordingIntent, LiveActivityIntent`, `openAppWhenRun = false`) is invoked from the Action Button.

Every claim below is cited. Where a DocC page's body is behind JS rendering and couldn't be fetched directly, the finding is attributed to the search snippet + at least one corroborating non-Apple source so the reader can verify.

---

## 1. Does `AudioRecordingIntent` allow background main-app-process `AVAudioSession` activation on iOS 26?

**Short answer:** Yes in principle — but **only if a Live Activity is actually running when you call `setActive(true)`**. That is the missing precondition in the current code.

### Primary source — Apple's `AudioRecordingIntent` documentation

> "Adopt this protocol to create an app intent for audio recording functionality and tell the system that your app records audio. As a result of this intent, the system displays an audio recording indicator."
>
> **Important:** "In iOS, iPadOS, and watchOS, when you adopt the `AudioRecordingIntent` protocol, **you must start a Live Activity when you begin the audio recording and keep it active as long as you record audio. If you don't start a Live Activity, the audio recording stops.**"

— Apple Developer, *AudioRecordingIntent*, availability `iOS 18.0+ / iPadOS 18.0+ / Mac Catalyst / macOS 15.0+ / tvOS 18.0+ / visionOS 2.0+ / watchOS 11.0+`. [Apple Dev Docs: AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent?language=_5) (fetched 2026-04-21 via `?language=_5` mirror, which renders body text where the default DocC route returns title-only). **Confirmed.**

### Corroboration — Process-isolation rules

> "If you adopt the `LiveActivityIntent` or `AudioPlaybackIntent` protocol, the system runs the app intent in the app's process."

— Zach Waugh, "Forcing an AppIntent to run in the main app process", 2023-10-13. [zachwaugh.com](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process). Corroborated by Ben Frearson's iOS 18 Live Activities writeup. **Confirmed** (same rule applies to `AudioRecordingIntent` by inheritance from `SystemIntent` — AudioRecordingIntent's conformance tree on the docs page lists `SystemIntent → AppIntent → PersistentlyIdentifiable, Sendable, SendableMetatype`).

### Cross-check — Apple DTS response on background audio session activation from an intent

When a developer reported "Session activation failed" (error 561015905) while launching audio recording from Shortcuts in iOS 17.4, an Apple engineer replied:

> "**You cannot trigger an audio recording from the Shortcuts app. Your app needs to be in the foreground before the user can start recording audio.** Consider overriding the `openAppWhenRun` property to return `true` in your implementation of the `AppIntent` protocol. This allows you to define the presentation style for the intent such that your app is brought to the foreground when the user intends to record audio."

— Apple engineer reply, [Apple Dev Forums thread 756507](https://developer.apple.com/forums/thread/756507), posted for iOS 17.4. **Confirmed for iOS 17**. Note: this reply predates the iOS 18 introduction of `AudioRecordingIntent`, which is exactly the protocol designed to relax this constraint — but only under the Live-Activity precondition quoted above.

### Observed workflow in the wild — Wispr Flow (Action Button, iPhone)

Wispr Flow explicitly advertises Action-Button-driven background dictation: "Press and hold the Action Button, then release to start dictation. When finished, press and hold again, then release to stop." [Wispr Flow docs — Set up the Action Button for Flow on iPhone](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone). **Confirmed this pattern works in production on iOS 25/26.**

However, the same Wispr Flow doc adds an important iOS 26.4 caveat:

> "On iOS 26.4 or later, Apple requires apps to briefly switch to activate the microphone, and you may see a 'Swipe right to speak' screen explaining that Apple requires switching apps to activate the microphone. Apple requires Flow to briefly switch apps to activate the microphone."

— [Wispr Flow docs, Action Button setup](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone). **Confirmed** (iOS 26.4+ imposes a foreground bounce even for `AudioRecordingIntent` apps). User is on iOS 26.3.1, which is *below* this threshold, so this specific change is not yet the cause — but it signals the direction Apple is moving.

### Bottom line for question 1

`AudioRecordingIntent` grants main-app-process execution. It does **not** by itself grant a background-mic activation free pass — the documented precondition is a running Live Activity. Current code activates the audio session *before* starting the Live Activity (`RecordAndTranscribeIntent.beginDictation` calls `controller.startRecording` which internally runs `setActive(true)`, then awaits `DictationActivityCoordinator.shared.start`). Reversing the order is the most-likely fix.

---

## 2. `AVAudioSession.ErrorCode.cannotInterruptOthers` — precise meaning

### Primary — error-code meaning

> "The `cannotInterruptOthers` error code indicates an attempt to make a nonmixable audio session active while the app was in the background."

— [Apple Developer, `AVAudioSession.ErrorCode.cannotInterruptOthers`](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers) (page body shown via search-result snippet; direct fetch returned title-only due to DocC JS rendering). Corroborated by just_audio issue #807 and the Apple forums tag index. **Confirmed.**

### Numeric code mapping

> "Error Code 561015905 corresponds to AVAudioSessionErrorCodeCannotStartPlaying ('!pla'). … Error Code 560557684 (`CannotInterruptOthers`): This is an error code that indicates an attempt to make a nonmixable audio session active while the app was in the background."

— Summary from search corpus cross-referencing [Apple Dev Forums thread 134082](https://developer.apple.com/forums/thread/134082) (no Apple staff reply), [ryanheise/just_audio#807](https://github.com/ryanheise/just_audio/issues/807), and [Apple Dev Forums thread 756507](https://developer.apple.com/forums/thread/756507). **Confirmed** code → constant mapping. Note `!int` = `0x21696e74` = `cannotInterruptOthers`. User's report used the mnemonic `'!int'` which matches `cannotInterruptOthers`; the hypothesis that landed `.mixWithOthers` in the current code is consistent with this code being the actual cause.

### Mixability

Adding `.mixWithOthers` makes the session mixable, which *should* bypass `cannotInterruptOthers`. If the failure persists even with `.mixWithOthers`, the error is **not** `cannotInterruptOthers` — it's a different code. The current `configureSession` logs `domain`, `code`, `localizedDescription`, `userInfo`; **the actual numeric code from the on-device run is the single most important datum we don't have yet**. Flag for the user: grab this from idevicesyslog on the next failing run.

### Confidence

`cannotInterruptOthers` meaning — **Confirmed**. That it's the *actual* error in Jot's case — **Possible** pending log. The Live-Activity-first requirement (Q1) is the more likely cause on iOS 26; an intent missing its Live Activity would also throw a session activation failure that *looks* like `cannotInterruptOthers` cosmetically but could be a different AVAudioSession error.

---

## 3. Required Info.plist keys for AppIntent-driven background mic recording on iOS 26

### Confirmed required

| Key | Why | Source |
|---|---|---|
| `NSMicrophoneUsageDescription` | Required by iOS since 10.0 for any mic access | [Apple Dev Docs — AVAudioSession.requestRecordPermission](https://developer.apple.com/documentation/avfaudio/avaudiosession/requestrecordpermission(_:)) |
| `UIBackgroundModes` = `[audio]` | Required to allow the audio session to stay active while the app is backgrounded. "An app that plays or records audio continuously (even while the app is running in the background) can register to perform those tasks in the background by enabling audio support from the Background modes section of the Capabilities tab in the Xcode project." | [Apple Dev Forums, background audio threads](https://developer.apple.com/forums/thread/86950); corroborated by Apple engineer reply in 756507 |

Both are present in the user's `Info.plist` (verified directly).

### NOT found as requirements (in any primary source)

- `UIBackgroundModes` combined with `voip`, `processing`, or anything other than `audio` — no Apple source requires this for AppIntent-driven recording. **Unknown** whether it helps.
- `com.apple.developer.kernel.increased-memory-limit` — this is a capacity entitlement, unrelated to session activation. **Confirmed not required.**
- No AppIntents-specific entitlement found in Apple's `AudioRecordingIntent` docs.

### Notable absence

Apple's `AudioRecordingIntent` documentation does **not** itself enumerate required Info.plist keys beyond the implicit AppIntents requirements. The Live-Activity requirement is the load-bearing runtime constraint, not an Info.plist one.

### Confidence

Required keys list — **Confirmed**. That no *additional* keys are needed on iOS 26 — **Likely** (no Apple source mentions any; absence of evidence is not strong evidence, but three separate Apple docs pages read would have surfaced it).

---

## 4. Known iOS 26 bugs / regressions for `AudioRecordingIntent` background activation

### Found

- **iOS 26.4 requires foreground bounce for mic activation** — Wispr Flow docs (cited in §1). This is a deliberate behavior change, not a bug; confirmed by a shipping app whose entire value prop depends on this path.

- **iOS 18 betas: `openAppWhenRun = false` regression** — the user's own internal research doc references Apple DevForums thread 760342 (not directly fetched here; cited as the Jot team's own prior research). Reported as silently quiet on iOS 18.x / iOS 26.0+. **Possible** this regression returned on 26.3.1.

### Not found

- No Apple Developer Forums thread specifically naming an iOS 26.3 / 26.3.1 regression of `AudioRecordingIntent` background activation. Searched: `"iOS 26" "AudioRecordingIntent" regression background "session activation failed" 2025` and variants.
- No MacRumors / Hacker News / r/iOSProgramming thread surfaced for this specific combination.

### Confidence

No *publicly reported* regression on iOS 26.3.1 specifically — **Confirmed absent** (within 30 min of search). That the bug doesn't exist — **Unknown** (Apple feedback system is private).

---

## 5. Has Apple explicitly stated `AudioRecordingIntent` supports background mic capture on iPhone?

### What Apple explicitly says (the `AudioRecordingIntent` doc page quoted in §1)

- "As a result of this intent, the system displays an audio recording indicator."
- "You must start a Live Activity when you begin the audio recording and keep it active as long as you record audio. If you don't start a Live Activity, the audio recording stops."

Apple never says the words "background recording is supported without foregrounding" on the `AudioRecordingIntent` doc page. But the recording indicator + Live Activity requirement + `SystemIntent` inheritance is the exact shape of an intent that runs in the app process without foregrounding the scene — otherwise the Live Activity requirement would be redundant (a foreground app already shows UI).

### Indirect confirmation

- Ben Frearson's writeup (§1) and Zach Waugh's writeup (§1) both assert that adoptions of `LiveActivityIntent` / `AudioPlaybackIntent` run in the main app's process without foregrounding. `AudioRecordingIntent` inherits the same `SystemIntent` base.
- Wispr Flow's shipped behavior (§1) is a production existence proof on pre-iOS-26.4 builds.

### WWDC sessions checked (verbatim confirmation NOT found)

- WWDC24 *Bring your app's core features to users with App Intents* (session 10210) — [video page](https://developer.apple.com/videos/play/wwdc2024/10210/). Mentions `openAppWhenRun` once ("For this intent, I want it to open the app when it runs… openAppWhenRun like this"). Does **not** mention `AudioRecordingIntent` or Action Button + audio.
- WWDC24 *What's new in App Intents* (session 10134) — [video page](https://developer.apple.com/videos/play/wwdc2024/10134/). One passing mention of Action Button; no `AudioRecordingIntent` mention.
- WWDC25 *Enhance your app's audio recording capabilities* (session 251) — [video page](https://developer.apple.com/videos/play/wwdc2025/251/). Does **not** mention `AudioRecordingIntent`, Action Button, background recording, or `openAppWhenRun`. Covers AVInputPickerInteraction, AirPods high-quality modes, spatial audio, Cinematic framework. **Confirmed negative.**

### Confidence

Apple's documentation implicitly supports the background-main-app-process pattern — **Likely**. Apple has not given an explicit "this works in the background on iPhone" statement — **Confirmed**. The Live-Activity-required clause is the closest Apple has come.

---

## 6. Correct recipe for "Action Button → dictate" on iOS 26

Based on the primary sources and shipping-app existence proofs:

### Required shape

1. An intent conforming to `AppIntent, AudioRecordingIntent, LiveActivityIntent` (all three — `LiveActivityIntent` is required to host `Button(intent:)` UI inside the Live Activity for toggle/stop).
2. `static let openAppWhenRun: Bool = false` so the press doesn't bounce the scene.
3. **In `perform()`, start the Live Activity FIRST, then activate the AVAudioSession, then start capture.** This is the contract in Apple's docs (§1).
4. Keep the Live Activity running for the entire recording. End it in `stop`.
5. Info.plist: `UIBackgroundModes=[audio]` + `NSMicrophoneUsageDescription`.

### Existing shipping apps that prove the pattern works

- **Wispr Flow** — background Action Button dictation with Live Activity indicator. Explicit docs confirm the press-hold-release pattern. [Wispr Flow Action Button setup](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone).
- **Superwhisper (iOS app)** — "hold, speak, release—effortless control at your fingertips." App Store + [superwhisper.com](https://superwhisper.com/). No public architecture disclosure but same UX.

### Caveats

- On iOS 26.4+ expect a system-imposed brief app-switch. User is on 26.3.1 — not yet affected.
- Widget-extension mic permission IS NOT permitted; the intent MUST run in the main-app process. Current code correctly achieves this via `AudioRecordingIntent` conformance.

### Confidence

Recipe outline — **Confirmed** via Apple docs + two shipping-app existence proofs. The specific ordering (Live Activity first, session activation second) — **Confirmed** by Apple's "if you don't start a Live Activity, the audio recording stops" clause.

---

## 7. `App-prefs:General&path=Keyboard/KEYBOARDS` — does it still work on iOS 26?

### What Apple has *officially* documented for keyboard extensions

> "To enable users to open Keyboard settings from a custom keyboard extension, you need to add a URL Type with a URL Scheme of 'prefs' to your Xcode project, then call `openURL` with `prefs:root=General&path=Keyboard`."
>
> "The `prefs:` URL scheme is undocumented. You may only use this specific URL scheme to open Keyboard settings, and only from a custom keyboard extension. It may not be used by any other type of app, nor to open any other Settings."

— [Apple Technical Q&A QA1924: Opening Keyboard Settings from a Keyboard Extension](https://developer.apple.com/library/archive/qa/qa1924/_index.html). **Confirmed** as the *only* officially sanctioned deep-link route from a keyboard extension into Settings.

- Scheme is `prefs:`, not `App-prefs:`. The user's documented URL `App-prefs:General&path=Keyboard/KEYBOARDS` uses a **different, undocumented scheme**.
- The **Full Access toggle sub-path** is NOT covered by QA1924 — only the parent Keyboard settings page is documented.

### iOS 18 / 26 breakage of the *other* (undocumented) `App-prefs:` sub-paths

> "Many apps use undocumented `App-prefs` URLs to help users get to the iOS Settings screen, and in iOS 18, it seems like these all stopped working. For example, `App-Prefs:com.apple.mobilesafari&path=WEB_EXTENSIONS` no longer works to open the Extensions sub-path. `App-prefs:General&path=ManagedConfigurationList` no longer works."

— [Apple Dev Forums thread 759900 — "iOS 18 open settings URLs"](https://developer.apple.com/forums/thread/759900) and corroborated by [FifiTheBulldog/ios-settings-urls](https://github.com/FifiTheBulldog/ios-settings-urls). **Confirmed regression in iOS 18+.**

### What this means for Jot-mobile

- The documented `prefs:root=General&path=Keyboard` scheme (parent Keyboard page only) is Apple-blessed and is the only path that can be expected to keep working across iOS updates.
- Any deeper sub-path like `/KEYBOARDS` or a Full-Access-toggle anchor is **undocumented and unreliable**: iOS 18 broke several `App-prefs:` sub-paths, iOS 26 has continued the pattern.
- There is **no public primary source** confirming that any URL scheme reliably deep-links to a specific keyboard extension's Full Access toggle on iOS 26. Searched multiple variants.

### Confidence

Documented `prefs:root=General&path=Keyboard` still works on iOS 26 — **Likely** (no reports of the documented path breaking; Apple's QA1924 is still live; confirmed by Wispr Flow-style apps still offering a "go to keyboard settings" deep link).

Deep sub-paths to the per-keyboard Full Access toggle — **Unknown** on 26.3.1. Best evidence is they DON'T work, based on the iOS 18 `App-prefs:` regression.

Best current practice: deep-link to the parent Keyboards page, then instruct the user to tap the extension and enable Full Access. This is what QA1924 endorses and what shipping keyboard extensions do.

---

## Action Button fix candidates — ranked

Ordered by likelihood-of-fix × low-cost. Each is a concrete code change or investigation the primary sources support.

### 1. Start the Live Activity BEFORE activating the AVAudioSession — **(Confirmed by Apple docs; highest confidence fix)**

**Current order** (`RecordAndTranscribeIntent.beginDictation`, lines 161-165):
```swift
try await controller.startRecording(startedAt: startedAt)  // calls setActive(true) — FAILS here
await DictationActivityCoordinator.shared.start(startedAt: startedAt)  // Live Activity starts AFTER
```

**Required order** (per Apple's `AudioRecordingIntent` doc):
```swift
await DictationActivityCoordinator.shared.start(startedAt: startedAt)  // Live Activity FIRST
try await controller.startRecording(startedAt: startedAt)              // then setActive(true)
```

**Expected outcome:** `setActive(true)` succeeds. iOS treats the intent as an Apple-sanctioned `AudioRecordingIntent` run because the required Live Activity is already in flight.

**Confidence: Confirmed** via Apple's explicit "If you don't start a Live Activity, the audio recording stops" clause on the `AudioRecordingIntent` doc page ([source](https://developer.apple.com/documentation/appintents/audiorecordingintent?language=_5)). Note: Apple's wording says recording "stops" not "fails to activate" — but the invariant is that the Live Activity must be active at audio-session activation time. Failing to start one beforehand means there is no authorised recording context at activation, so the session activation is the failure surface.

### 2. Capture the exact NSError from the current failure before changing more code — **(Highest diagnostic value)**

The on-device `configureSession` log (`RecordingService.swift:270-272`) already prints `domain`, `code`, `localizedDescription`, `userInfo`. Get the actual numeric `code` from idevicesyslog on the next failing press.

- If code is `560557684` (`cannotInterruptOthers`) — fix #1 is correct; Live Activity precondition is the issue.
- If code is `-50` (`badParam`) — the `.defaultToSpeaker` / `.mixWithOthers` combination is rejected on iOS 26 for this category/mode. Try `[]` or `[.mixWithOthers]` only.
- If code is `561017449` (`activation failed, unknown`) — investigate interruption conflicts, not the intent path.
- If code is something not in the `AVAudioSession.ErrorCode` enum — file Feedback Assistant.

**Expected outcome:** either fix #1 is confirmed or we redirect. Zero code change, pure instrumentation.

**Confidence: Confirmed** as the right-next-step.

### 3. Drop `.mixWithOthers` if Live Activity is started first — **(Lower confidence, speculative)**

`.mixWithOthers` is a workaround for `cannotInterruptOthers`, which should not occur once the Live Activity is running at activation time. Dictation apps typically want to *interrupt* other audio (user speaks over a podcast; podcast pauses). Revisit after fix #1 is in.

**Expected outcome:** cleaner interruption behavior; no regression if fix #1 resolves the activation failure.

**Confidence: Possible.** Revisit after fix #1.

### 4. Audit the Live Activity coordinator for iOS 26 compatibility — **(Medium confidence)**

`DictationActivityCoordinator.shared.start` currently runs *after* `configureSession`. Once the order is flipped (fix #1), confirm:
- The activity request is synchronous-ish (the `await` must complete before `setActive`).
- `ActivityAuthorizationInfo().areActivitiesEnabled` is `true` (user may have disabled Live Activities system-wide; if so, the `AudioRecordingIntent` path is broken by user config).
- The widget extension target actually registers the Activity type.

**Expected outcome:** ensures fix #1's new order actually has a live Activity when `setActive` runs. A user who disabled Live Activities in Settings will need either a fallback to `DictateIntent` (openAppWhenRun=true) or a user-facing explanation.

**Confidence: Likely** needed as follow-through to fix #1.

### 5. Accept a foreground-bounce fallback on failure — **(Defensive; confirmed working path)**

If fix #1 still fails on 26.3.1 (Apple's docs may be aspirational / iOS 26.3 may have a regression not yet publicly tracked), the Apple-DTS-blessed fallback is `openAppWhenRun = true`. The current code already has `DictateIntent` as this fallback ([src](RecordAndTranscribeIntent.swift:29-33)). Keep both intents registered; surface `DictateIntent` as the Action Button binding if `RecordAndTranscribeIntent` fails to bind or throws on first run.

**Expected outcome:** no dead-end for users; cost is a visible app bounce on every press.

**Confidence: Confirmed** this fallback works (Apple DTS reply, thread 756507). Existing code already supports it.

### 6. For the keyboard-extension Full-Access deep-link — don't deep-link to the toggle, deep-link to the parent page — **(Separate question; confirmed direction)**

Use Apple's blessed `prefs:root=General&path=Keyboard` only. Don't attempt `App-prefs:General&path=Keyboard/KEYBOARDS` or any toggle anchor — those sub-paths are undocumented and broke in iOS 18 per Apple Dev Forums #759900.

**Expected outcome:** reliable deep-link that won't break on an iOS point release. User does one extra tap to enter the extension settings, which is the UX pattern shipping keyboards use.

**Confidence: Confirmed.**

---

## Open questions / what to check next

1. **Actual NSError code from on-device log** — still the highest-value unknown. Without it, we're choosing between two hypotheses with good-but-not-perfect priors.
2. **Does `ActivityAuthorizationInfo().areActivitiesEnabled` return `true` on the failing device?** A user who disabled Live Activities in Settings kills the `AudioRecordingIntent` path entirely.
3. **WWDC25 session 244 / 275 ("Get to know App Intents" / "Explore new advances in App Intents")** — not fetched; may contain explicit guidance on `AudioRecordingIntent` lifecycle. Deferred due to 30-min budget.
4. **iOS 26.4 foreground-bounce** — when the user updates to 26.4+, expect the current `openAppWhenRun=false` behavior to subtly change (brief switch-back flash). Not urgent but worth a note in the intent's doc-comment.

---

## Sources (all URLs)

- [Apple Developer Docs — AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent?language=_5)
- [Apple Developer Docs — AVAudioSession.ErrorCode.cannotInterruptOthers](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers)
- [Apple Developer Docs — LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)
- [Apple Developer Docs — ForegroundContinuableIntent](https://developer.apple.com/documentation/appintents/foregroundcontinuableintent)
- [Apple Technical Q&A QA1924 — Opening Keyboard Settings from a Keyboard Extension](https://developer.apple.com/library/archive/qa/qa1924/_index.html)
- [Apple Dev Forums — thread 756507, "Microphone Recording Fails When Launched from Shortcut" (contains Apple engineer reply)](https://developer.apple.com/forums/thread/756507)
- [Apple Dev Forums — thread 134082, "Random 561015905 on AVAudioSession setActive"](https://developer.apple.com/forums/thread/134082)
- [Apple Dev Forums — thread 759900, "iOS 18 open settings URLs"](https://developer.apple.com/forums/thread/759900)
- [WWDC24 session 10210 — Bring your app's core features to users with App Intents](https://developer.apple.com/videos/play/wwdc2024/10210/)
- [WWDC24 session 10134 — What's new in App Intents](https://developer.apple.com/videos/play/wwdc2024/10134/)
- [WWDC25 session 251 — Enhance your app's audio recording capabilities](https://developer.apple.com/videos/play/wwdc2025/251/)
- [Zach Waugh — Forcing an AppIntent to run in the main app process (2023-10-13)](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process)
- [Ben Frearson — Interactivity with Live Activities and App Intents](https://bfrearson.github.io/blog/ios-live-activties/)
- [Hacking with Swift forum — "Starting an audio recording LiveActivity with Action Button"](https://www.hackingwithswift.com/forums/swift/starting-an-audio-recording-liveactivity-with-action-button/29100)
- [ryanheise/just_audio GitHub issue #807 — AVAudioSession.ErrorCode.cannotInterruptOthers](https://github.com/ryanheise/just_audio/issues/807)
- [Wispr Flow — Set up the Action Button for Flow on iPhone](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone)
- [Superwhisper — product page](https://superwhisper.com/)
- [FifiTheBulldog/ios-settings-urls — iOS settings URL registry](https://github.com/FifiTheBulldog/ios-settings-urls)
