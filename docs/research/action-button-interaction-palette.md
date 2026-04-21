# Action Button Interaction Palette — iOS 18/26

> Research scope: what's actually possible with iPhone Action Button + 3rd-party AppIntents as of iOS 18 and iOS 26. Source: Apple developer docs, WWDC 24/25 sessions, Apple dev forums, HIG. Written 2026-04-21.

---

## 1. TL;DR

- **Tap-vs-hold split on the Action Button: not possible.** iOS exposes exactly one event per physical actuation — delivered only after the system's press-and-hold threshold elapses. There is no short-press path, no duration parameter on the AppIntent, no developer API to intercept the press itself. Hold duration is fixed by the system and not user-configurable.
- **Giant sheet is avoidable.** It is emitted *only* by Shortcuts' built-in `Record Audio` action. Own the mic inside our own `AudioRecordingIntent` (iOS 18+) and the sheet disappears — we render the pill via a Live Activity instead. The app stays backgrounded.
- **The tap/hold dream needs a second physical gesture:** Back Tap (Accessibility → Back Tap → Double/Triple Tap → Run Shortcut) is the cleanest iPhone-wide option.

---

## 2. Action Button behavior on iOS 26 — definitive

| Question | Answer | Source |
|---|---|---|
| Default invocation | Press-and-hold | [Apple Support — Use and customize the Action button](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios) |
| Hold duration | Fixed by iOS, ~0.5–1.0s with haptic. Not user-configurable, not dev-configurable. | [9to5Mac: Why Apple required press-and-hold](https://9to5mac.com/2023/09/26/iphone-15-pro-action-button-press-and-hold/), [MacRumors forum](https://forums.macrumors.com/threads/can-you-activate-action-button-by-short-pressing-not-long-pressing.2436311/) |
| Short press | No public API. No settings toggle. Apple deliberately rejected short-press to prevent accidental activation (button is physically adjacent to volume up). | 9to5Mac 2023 |
| Double-click / multi-click | Not supported on iPhone Action Button. This is a long-standing feature request. Apple Watch Ultra supports distinct press types via a separate article, but iPhone does not. | [AppleVis: Action Button Behavior Customization](https://www.applevis.com/forum/ios-ipados/action-button-behavior-customization) |
| Press-duration in `AppIntent.perform()` | None. `perform()` receives no press metadata. One event per actuation, period. | [AppIntent docs](https://developer.apple.com/documentation/appintents/appintent) |
| UI shown on invocation | Depends entirely on which Shortcut action runs. Apple's `Record Audio` emits its own full-screen sheet. 3rd-party AppIntents render whatever UI they choose (including no UI). | Apple Community / RoutineHub notes |
| Action hint on press | For **Control Widgets** (iOS 18+) bound via the "Controls" category, the system overlays a verb hint like "Hold to Start" while the button is held. Shown via `.controlWidgetActionHint("Start")`. | [WWDC24 session 10157](https://developer.apple.com/videos/play/wwdc2024/10157/) |
| Works while locked | Yes. AppIntent executes, Live Activity can render on the Lock Screen and Dynamic Island. Mic permission must have been granted earlier (from the app in foreground). | [Apple dev forum: mic from LiveActivity](https://www.hackingwithswift.com/forums/swift/starting-an-audio-recording-liveactivity-with-action-button/29100), [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent) |

**Bottom line on semantics:** on iPhone, the Action Button is a single-bit input. You get told it was pressed. Nothing else.

---

## 3. The three invocation surfaces compared

### A. Direct AppShortcut (via Shortcuts app) — **recommended for Jot**

User flow: Settings → Action Button → Shortcut → pick "Start/Stop Jot" (our `AppShortcut`, auto-registered via `AppShortcutsProvider`). One physical press-and-hold on Action Button runs our `AppIntent.perform()` directly.

- **UI emitted by iOS:** none. We own everything.
- **Process:** If the intent conforms to `AudioRecordingIntent`, `AudioPlaybackIntent`, `LiveActivityIntent`, or `ForegroundContinuableIntent`, the system runs it in the **main app process** — not the app-extension sandbox. Mic + `AVAudioSession` + SwiftData all work. ([Zach Waugh: forcing AppIntent to main-app process](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process))
- **Foreground required?** No. `openAppWhenRun = false` is the default and is the correct choice for a background dictation flow. The app can stay backgrounded; the Live Activity is the UI.
- **Known gotchas:** early iOS 18 betas had a bug where `openAppWhenRun = false` silently dropped `perform()` calls. ([Apple dev forum 760342](https://developer.apple.com/forums/thread/760342)) Verify on current iOS 18.x / iOS 26.0.
- **Pros:** cleanest, closest to macOS Jot's model, avoids the sheet entirely, supports Live Activity as UI.
- **Cons:** user has to discover the binding in Settings → Action Button → Shortcut. Requires shipping the `AppShortcut` in our `AppShortcutsProvider` so the picker lists it.

### B. Shortcut-with-built-in-Record-Audio — **what the user is hitting today. Avoid.**

User flow: the Action Button is bound to a multi-step Shortcut that contains Apple's built-in `Record Audio` action, which then feeds output into `TranscribeAudioFileIntent`.

- **UI emitted by iOS:** the giant "Tap to Finish Recording" system sheet owned by the Shortcuts app. **Not replaceable.** Not themeable. Not dismissible-via-Live-Activity. `Start Recording: Immediately` can auto-start it, but the sheet itself is structurally owned by Shortcuts and cannot be hidden.
- **Process:** Shortcuts runtime, not ours.
- **Why this exists in Jot today:** probably because someone wired the MVP through Shortcuts' action palette instead of exposing our own recording AppIntent.
- **Fix:** stop routing through `Record Audio`. Ship our own intent (Path A).

### C. Control Widget (iOS 18+) — fallback if Path A feels fiddly

User flow: ship a `ControlWidgetButton` or `ControlWidgetToggle` in our widget extension with an `AppIntent` action. User goes Settings → Action Button → Controls → picks our control.

- **UI emitted by iOS:** small action-hint overlay ("Hold to Start") while the button is held. No full-screen sheet. ([WWDC24 10157](https://developer.apple.com/videos/play/wwdc2024/10157/))
- **Process:** Runs in **widget extension** by default. **This is a problem for mic** — the extension sandbox cannot request mic permission and `AVAudioSession` activation fails. ([HWS forum 29100](https://www.hackingwithswift.com/forums/swift/starting-an-audio-recording-liveactivity-with-action-button/29100))
- **Workaround:** If the intent conforms to `LiveActivityIntent` or `AudioRecordingIntent`, iOS promotes execution into the main-app process. Target membership must include both app and widget extension.
- **Interactive snippets cannot run from Control Center bindings.** ([Superwall: iOS 26 interactive snippets](https://superwall.com/blog/app-intents-interactive-snippets-in-ios-26/))
- **Pros:** cleaner "Controls" discoverability, works on Control Center and Lock Screen too (same control = three invocation surfaces from one binding).
- **Cons:** extra target; the extension → main-app promotion has to be gotten exactly right; no meaningful UX gain over Path A for Jot's single-action dictation case.

**Verdict:** Path A for Jot. Path C is worth a second control binding *later* if we want lock-screen parity, but it's additive not substitutive.

---

## 4. Recommended architecture for Jot iOS

### Core mapping (gesture → action)

| Gesture | Surface | Action | Binding |
|---|---|---|---|
| Action Button press-and-hold (1st press) | Our `AppShortcut` → `ToggleDictationIntent` | Start dictation + open Live Activity in Dynamic Island | User binds once in Settings → Action Button → Shortcut |
| Action Button press-and-hold (2nd press, while recording) | Same intent, different state branch | Stop dictation + paste transcript into focused app (via `UIPasteboard` → synthetic paste equivalent on iOS, typically Universal Clipboard + user action) | Same binding; idempotent toggle |
| Back Tap → Double Tap | Accessibility → Back Tap → Run Shortcut | Runs `CommandOnLastTranscriptIntent` — reuses last transcript, prompts LLM rewrite, replaces selection/clipboard | User sets in Settings → Accessibility → Touch → Back Tap |
| Lock-screen / Control Center tile | Control Widget (optional, later) | Same `ToggleDictationIntent` | Auto-available once the control is shipped |

This gives the user the **tap-vs-hold semantic split** they want, just mapped onto two *different physical gestures* instead of trying to split one button into two events (which iOS does not allow). Back Tap is intentionally easy to discover because it appears verbatim in Jot's first-run tour as "set up Back Tap → Double Tap for AI commands".

### Intent protocol conformance (critical)

```swift
struct ToggleDictationIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    static var openAppWhenRun: Bool = false
    // ... perform() starts/stops AVAudioEngine + starts/ends Live Activity
}
```

`AudioRecordingIntent` (iOS 18+) is the magic conformance: it tells iOS "run me in the app process, activate audio session, I need mic". ([AudioRecordingIntent docs](https://developer.apple.com/documentation/appintents/audiorecordingintent)) Combined with `LiveActivityIntent`, the runtime guarantees main-app execution without foregrounding.

### UI: no sheet, ever

- The recording UI lives 100% in a `Live Activity` with compact + expanded Dynamic Island presentations.
- The full app is only opened if the user explicitly taps the Live Activity (deep link to the recording detail / Library).
- The old "Shortcuts Record Audio → giant sheet" flow is removed from every Jot documentation path and sample Shortcut.

### iOS 26 upside (interactive snippets)

`SnippetIntent` can return full SwiftUI views inline — useful for the "command on last transcript" flow. When the user double-taps the back of the phone, our `CommandOnLastTranscriptIntent` can return an interactive snippet with a text field for the instruction, preview of the diff, and a "Replace" button. No app launch needed. ([Superwall post](https://superwall.com/blog/app-intents-interactive-snippets-in-ios-26/), [Nutrient blog](https://www.nutrient.io/blog/wwdc25-snippet-intents/))

iOS 18 fallback: use a Live Activity with push-updated state instead of a snippet.

---

## 5. Open questions (flagged with confidence)

| # | Question | Confidence | Notes |
|---|---|---|---|
| 1 | Does iOS 26 pass press-duration into `AppIntent.perform()` in any new protocol? | **Very likely NO** (85%) | WWDC25 244 + 275 don't mention it; dev forums through April 2026 have no such discussion. |
| 2 | Does Action Button + AppShortcut actually bypass the full-screen sheet? | **Likely YES** (80%) | Sheet is tied specifically to Shortcuts' `Record Audio` action, not to AppShortcut invocation. Need a 5-minute device test to confirm with Jot's intent. |
| 3 | Does `AudioRecordingIntent` work from widget-extension-bound Control Widget binding for Action Button? | **Possibly** (60%) | Docs say conforming to the protocol promotes execution to main-app process. HWS thread hints it's still flaky. Test before shipping Path C. |
| 4 | Can an interactive snippet (iOS 26) render while invoked *from* the Action Button via a Shortcut wrapper? | **Unknown** (40%) | Superwall says snippets can't run from "Control Center widgets" but is ambiguous about Action-Button-via-Shortcut. The Action Button invokes a Shortcut, and Shortcuts *can* host snippets — so it should work. Needs a hardware test. |
| 5 | Are interactive snippets in iOS 26 a viable alternative to Live Activity for the recording pill? | **Uncertain** (50%) | Snippets are transient and tied to the Shortcuts overlay context. Live Activity is the right primitive for "in-progress mic capture visible while user is elsewhere". Snippets are better for the post-capture command flow. |
| 6 | Will iOS 18.x ship the `openAppWhenRun=false` regression fix? | **Likely already fixed** (75%) | The bug was reported in iOS 18.0 betas. Not confirmed on 18.4 or iOS 26.0 but forum chatter has gone quiet. Verify with a release-branch smoke test. |

---

## 6. Sources

### Apple docs
- [App Intents framework overview](https://developer.apple.com/documentation/appintents)
- [AppIntent protocol](https://developer.apple.com/documentation/appintents/appintent)
- [Action button on iPhone and Apple Watch](https://developer.apple.com/documentation/appintents/actionbutton)
- [Responding to the Action button on Apple Watch Ultra](https://developer.apple.com/documentation/appintents/actionbuttonarticle)
- [openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun-7ggw4)
- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)
- [AudioStartingIntent](https://developer.apple.com/documentation/appintents/audiostartingintent)
- [ForegroundContinuableIntent](https://developer.apple.com/documentation/appintents/foregroundcontinuableintent)
- [ActivityKit (Live Activities)](https://developer.apple.com/documentation/activitykit)
- [WidgetKit — Creating controls](https://developer.apple.com/documentation/WidgetKit/Creating-controls-to-perform-actions-across-the-system)
- [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)

### WWDC sessions
- [WWDC24 10157 — Extend your app's controls across the system](https://developer.apple.com/videos/play/wwdc2024/10157/)
- [WWDC25 244 — Get to know App Intents](https://developer.apple.com/videos/play/wwdc2025/244/)
- [WWDC25 275 — Explore new advances in App Intents](https://developer.apple.com/videos/play/wwdc2025/275/)
- [WWDC25 251 — Enhance your app's audio recording capabilities](https://developer.apple.com/videos/play/wwdc2025/251/)
- [WWDC25 253 — Enhancing your camera experience with capture controls](https://developer.apple.com/videos/play/wwdc2025/253/)

### Apple Support / user-facing
- [Use and customize the Action button on iPhone](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios)
- [Adjust how iPhone responds to your touch](https://support.apple.com/en-me/guide/iphone/iph77bcdd132/ios)

### Community writeups
- [9to5Mac — Why Apple required press-and-hold](https://9to5mac.com/2023/09/26/iphone-15-pro-action-button-press-and-hold/)
- [AppleVis — Action Button Behavior Customization](https://www.applevis.com/forum/ios-ipados/action-button-behavior-customization)
- [MacRumors — Activate Action Button by short-press?](https://forums.macrumors.com/threads/can-you-activate-action-button-by-short-pressing-not-long-pressing.2436311/)
- [Rudrank Riyam — Exploring WidgetKit: First Control Widget](https://rudrank.com/exploring-widgetkit-first-control-widget-ios-18-swiftui)
- [createwithswift — Integrating App Intents with Control Action](https://www.createwithswift.com/integrating-app-intents-with-control-action/)
- [onmyway133 — How to open app with Control Widget on iOS 18](https://onmyway133.com/posts/how-to-open-app-with-control-widget-on-ios-18/)
- [Zach Waugh — Forcing an AppIntent to run in the main app process](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process)
- [HackingWithSwift forum — Audio recording LiveActivity with Action Button](https://www.hackingwithswift.com/forums/swift/starting-an-audio-recording-liveactivity-with-action-button/29100)
- [Superwall — App Intents interactive snippets in iOS 26](https://superwall.com/blog/app-intents-interactive-snippets-in-ios-26/)
- [Nutrient — Exploring interactive snippet intents](https://www.nutrient.io/blog/wwdc25-snippet-intents/)
- [DEV — WWDC25 iOS 26 audio recording capabilities](https://dev.to/arshtechpro/wwdc-2025-ios-26-enhance-your-apps-audio-recording-capabilities-h7e)
- [GoodRequest — App Intents tips and tricks](https://www.goodrequest.com/blog/app-intents-tips-and-tricks)

### Apple Developer Forum threads (evidence)
- [760342 — Interactive Live Activity Bug in iOS 18 — perform not called](https://developer.apple.com/forums/thread/760342)
- [756507 — Microphone Recording Fails When Launched from Shortcut](https://developer.apple.com/forums/thread/756507)
- [723623 — Set openAppWhenRun programmatically](https://developer.apple.com/forums/thread/723623)
- [736445 — Cannot Start Audio Playback from Interactive Widget (iOS 17)](https://developer.apple.com/forums/thread/736445)
- [763689 — AppIntent — Widget & ControlWidget](https://developer.apple.com/forums/thread/763689)
