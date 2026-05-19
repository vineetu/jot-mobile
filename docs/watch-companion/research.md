# Apple Watch companion for Jot — research

> Research artifact only. No production code or `project.yml` was modified.
> Author: research subagent, 2026-05-17.
> Scope: capability survey + recommendation. Not an implementation plan.

Jot today is an iOS-only dictation app (iOS 26+, iPhone 15 Pro+) built around bundled Parakeet TDT-CTC 110M ASR, a 60 MB-ceiling custom keyboard, and a main-app Phi-4-mini rewrite path on MLX. The user's request is to investigate adding an Apple Watch companion, with explicit emphasis on the **iPhone-not-nearby** scenario. The headline answer is "yes it's feasible, but small-scope MVP only — the Watch becomes a capture device that feeds the iPhone's existing pipeline, not a self-contained dictation product."

---

## 1. watchOS recording capability — current state

**Yes, the Apple Watch can record audio independently.** Native on-Watch recording has been supported since **watchOS 4 (2017)**, when `AVAudioRecorder` and `AVAudioEngine` became available inside the WatchKit extension and recording could continue in the background as a foreground-initiated `audio` background mode. Independent watchOS apps (no companion iOS bundle required) have been first-class since watchOS 6, and on watchOS 26 the recommendation is a pure-SwiftUI app target.

- **API:** `AVAudioRecorder` (file-based) or `AVAudioEngine`/`AVAudioInputNode` (buffer-based). Same APIs as iOS.
- **Audio session:** `AVAudioSession.sharedInstance().setCategory(.record, mode: .default)` then `.setActive(true)`. For low-latency live VAD/streaming use `.playAndRecord` with `.mixWithOthers`.
- **Formats:** Mirrors iOS — `kAudioFormatMPEG4AAC`, `kAudioFormatLinearPCM`, Opus also available. Sample rate up to 48 kHz, both mono and stereo. Voice Memos itself uses M4A at ~1 MB/min, which is the realistic target.
- **Memory/CPU:** No published numerical ceiling, but watchOS jetsam is aggressive. The "audio recording session" is explicitly **CPU-limited** per WWDC17 session 216, and must be foreground-initiated; you can't start a recording from a background task.
- **Duration:** No documented hard cap. Voice Memos and Just Press Record report hour-plus sessions in practice. Storage is the real ceiling: Series 10 has 64 GB, but realistic free space is far less, and a 1 MB/min M4A stream means a few thousand minutes max.
- **Background:** Add `audio` to the watch target's `UIBackgroundModes`. Recording started while the app is foreground can continue when the user lowers their wrist, but it **cannot be resumed** from the background after an interruption (phone call, Siri, low-battery throttle) — the system reclaims the audio session aggressively. This is the single biggest watchOS-vs-iOS gap to plan around.
- **Permission:** `NSMicrophoneUsageDescription` must be in the watch app's Info.plist. Practically, devs report including it in both the iPhone and watch Info.plists. There's no separate Watch-specific permission API; the system uses the same TCC flow with a Watch-styled prompt.
- **Battery:** Apple's only published guidance is "use the lowest sample rate you can." Real-world Just Press Record reviews report a continuous 30-minute recording costs ~10–15% battery on a Series 7/8 — non-trivial but acceptable for short captures.

Sources: [Audio Recording in watchOS Tutorial — Kodeco](https://www.kodeco.com/345-audio-recording-in-watchos-tutorial/page/2), [Reliable Background Recording on iOS & watchOS — RisingStack](https://blog.risingstack.com/reliable-background-recording-on-ios-watchos/), [Playing Background Audio — Apple Developer](https://developer.apple.com/documentation/WatchKit/playing-background-audio), [The Life of a watchOS App — WWDC17](https://developer.apple.com/videos/play/wwdc2017/216/), [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription).

### Suggested watch-side audio init

```swift
// In WatchAudioCaptureService (NOT shipped — illustrative only)
let session = AVAudioSession.sharedInstance()
try session.setCategory(.record, mode: .measurement, options: [])
try session.setActive(true, options: [])

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,   // ~1 MB/min, ASR-friendly after decode
    AVSampleRateKey: 16_000,               // Parakeet expects 16 kHz — record at source
    AVNumberOfChannelsKey: 1,              // Mono. Mic array on Watch is single-channel anyway.
    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
]
let recorder = try AVAudioRecorder(url: containerURL, settings: settings)
recorder.record()
```

Recording at 16 kHz mono saves both storage and a resample step on the iPhone side before Parakeet inference.

---

## 2. Phone-not-nearby scenarios

This is the core use case in the request and deserves precise treatment.

| Scenario | Behavior |
|---|---|
| **Cellular Watch + active LTE/5G plan** (S4+ cellular, all Ultra, S11/SE3/Ultra3 add 5G) | Watch is fully online. Can stream to the cloud, can sync to iCloud, can route audio uploads via background URL session — but `transferFile` over WatchConnectivity still requires Bluetooth/peer Wi-Fi proximity to the iPhone. So "phone not nearby" with cellular Watch = either (a) cloud transcription, or (b) hold the audio locally and `transferFile` later when paired. |
| **Cellular Watch + cellular plan inactive, phone out of BT range** | Watch is offline. Audio captures locally, queues for `transferFile` when the iPhone is reachable again. |
| **GPS-only Watch, phone out of BT range** | Identical to the inactive-cellular case. Local capture, queued sync. Watch may still attach to a known Wi-Fi (e.g. home), but iCloud sync from the Watch is not user-controllable beyond what Apple's own apps use. |
| **Both reachable** | Real-time `sendMessage` partial-strings + `transferFile` for the full audio (or skip the file transfer entirely and let the iPhone transcribe from a streamed buffer). |

What this means for Jot's specifically-emphasized "iPhone not nearby" path: **the Watch must hold a local outbox and reconcile on next pairing.** Just Press Record and Voice Memos both do exactly this. Sync triggers when both apps are awake, or in the background "as soon as the receiving app launches" — there's no guaranteed background wake of the iPhone host app, but in practice iOS does kick the host briefly when the Watch reports queued transfers.

**Storage exhaustion:** at 16 kHz mono AAC (~0.5 MB/min) a 30-min recording is ~15 MB; the user could comfortably queue dozens. No code-level cap is needed; surface a "Watch storage low" toast if `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` drops below a threshold.

Sources: [Use Apple Watch without iPhone — Apple Support](https://support.apple.com/en-us/108300), [Transferring data with Watch Connectivity — Apple Developer](https://developer.apple.com/documentation/WatchConnectivity/transferring-data-with-watch-connectivity), [WatchConnectivity background reliability discussion — Apple Forums](https://forums.developer.apple.com/thread/43596).

---

## 3. Transcription strategy options

Parakeet TDT-CTC 110M is ~530 MB of `.mlmodelc` plus the model loader (`FluidAudio`). It will not fit on watchOS — the watchOS app bundle ceiling is ~150 MB historically and watchOS jetsam will not tolerate a half-gig model load even if it fit on disk. So the transcription must happen elsewhere.

- **Option A — sync audio to phone, transcribe there.** Simplest path. The Watch records, queues, syncs on next pair, then the iPhone runs the existing Parakeet pipeline and the transcript appears in the Library like any other dictation. Latency from end-of-recording to transcript-visible = `transferFile` queue time (sub-second when phone is awake nearby; minutes-to-hours if phone is asleep/distant) + Parakeet decode (real-time on iPhone 15 Pro). No new transcription stack to maintain. **This is Jot's natural fit.**
- **Option B — on-Watch SFSpeechRecognizer.** SFSpeechRecognizer still ships on watchOS 26 but with the same caveats it has had for years: cloud-dependent for most languages, on-device support is limited and silently degrades. The newer/better SpeechAnalyzer API from WWDC25 (session 277) is **explicitly not available on watchOS** — iOS / macOS / tvOS only. So you'd be locked into the old, partly-cloud API. Also: SFSpeechRecognizer on watchOS over LTE is functional but slow and quality drops vs. Parakeet — and we'd suddenly need network privacy disclosures Jot's "audio never leaves your iPhone" copy explicitly avoids.
- **Option C — hybrid: live SFSpeechRecognizer partials on Watch for instant feedback, Parakeet pass on iPhone post-sync as the source of truth.** Tempting but doubles complexity for marginal UX gain — the Watch screen is too small for live captioning to be the primary deliverable.
- **Option D — tiny on-device model on Watch (Whisper-tiny CoreML quantized).** Whisper-tiny is ~30–75 MB. It would technically fit. Real-time inference on an Apple Watch S10's S10 SiP has never been benchmarked publicly, but anecdotal data from WhisperKit on A-series silicon suggests Whisper-tiny is real-time on iPhone — the Watch would likely be slower than real-time, drain battery hard, and ship a model materially worse than Parakeet. Plus: an entirely separate model pipeline to maintain.

**MVP recommendation: Option A.** It's the only one that doesn't add a second ASR stack to maintain, doesn't compromise the on-device privacy story, and matches Jot's pipeline shape (Watch = mic only, phone = brains). Defer Option C as a v2 "live caption on Watch" enhancement only if user research surfaces it.

Sources: [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/), [Apple's New Speech Framework — Blake Crosley](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer), [SFSpeechRecognizer — Apple Developer](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [WhisperKit by Argmax](https://github.com/argmaxinc/WhisperKit).

---

## 4. Architecture options

- **Companion vs. standalone:** Recommend **paired-but-installable-independently** — a watch app target inside the existing Jot bundle. The Watch app needs the iPhone for transcription, so a true standalone bundle (separate App Store SKU) buys nothing. But declare the watch app as supporting independent install so a user with a cellular Watch can launch and queue captures with no iPhone present.
- **Bundle ID:** Apple's modern (post-watchOS 7) convention is `com.vineetu.jot.mobile.Jot.watchkitapp` for the watch app target. No separate WatchKit extension — modern SwiftUI watchOS apps are a single target. `xcodegen` users in the wild use exactly this `.watchkitapp` suffix. The legacy `watchkit2-extension` type is no longer needed for new apps on watchOS 26.
- **App Group:** **Yes, the watch target must share `group.com.vineetu.jot.mobile.shared`** — but with a critical caveat surfaced in the search: **App Group containers are per-device, not cross-device.** A file written to the App Group on the Watch is invisible to the iPhone's App Group container. App Group on the Watch buys you intra-device sharing (e.g. between a future watch widget extension and the watch app); cross-device payload must go through `WatchConnectivity` or iCloud.
- **Shared code:** The existing `Jot/Shared/` folder is currently compiled into both `Jot` (iOS) and `JotKeyboard` (iOS app-extension). Adding a watch target means a third platform. SwiftUI views and pure-model code in `Shared/` will compile; anything pulling in iOS-only frameworks (`UIKit`, `AppIntents` host APIs, `FoundationModels`) will not. Expect to gate with `#if os(iOS)` / `#if os(watchOS)`. Look at `Shared/Transcript.swift`, `Shared/AppGroup.swift`, `Shared/CrossProcessNotification.swift` — those are the candidates. `Shared/LLM/` and anything FluidAudio-touching must be iOS-fenced.
- **SwiftUI vs. WatchKit extension:** SwiftUI lifecycle (`@main App` + `WindowGroup`) — there's no reason to use the legacy WatchKit extension model for a 2026 greenfield watch app.

### Sketch of the project.yml delta (illustrative, NOT applied)

```yaml
  JotWatch:
    type: application
    platform: watchOS
    deploymentTarget: "26.0"
    sources:
      - path: Watch          # new folder, watch-only Swift files
      - path: Shared         # same shared folder, with os() gates
    info:
      path: Resources/Watch-Info.plist
      properties:
        WKApplication: true                              # SwiftUI watchOS app
        WKCompanionAppBundleIdentifier: com.vineetu.jot.mobile.Jot
        NSMicrophoneUsageDescription: "Jot records on your Watch so you can dictate even when your iPhone isn't nearby. Audio is sent to your iPhone for transcription."
        UIBackgroundModes:
          - audio
    entitlements:
      path: Resources/Watch.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.vineetu.jot.mobile.shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vineetu.jot.mobile.Jot.watchkitapp
        TARGETED_DEVICE_FAMILY: "4"   # watchOS
```

Sources: [xcodegen-sample-watch-app — leogdion/GitHub](https://github.com/leogdion/xcodegen-sample-watch-app/blob/master/project.yml), [Creating independent watchOS apps — Apple Developer](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps), [SwiftData CloudKit on watchOS — Apple Forums](https://developer.apple.com/forums/thread/733397), [App Groups cross-device limitation — Apple Forums](https://developer.apple.com/forums/thread/133251).

---

## 5. UX — how the user starts a recording on Watch

Ranked entry points:

1. **Primary — Complication on the watch face.** One tap from any face. This is exactly how Just Press Record exposes recording and is the watchOS-native equivalent of Jot's iPhone floating Dictate button. Use a `.accessoryCircular` and `.accessoryCorner` complication so it works on Modular, Infograph, and the new watchOS 26 faces.
2. **Secondary — Smart Stack widget.** watchOS 10+ Smart Stack with a single "Start dictating" button. watchOS 26 supports fully interactive widgets, so the button can begin recording without launching the full app. Combine with `RelevanceKit` (new in watchOS 26) to surface the widget when the user historically dictates a lot (e.g. mornings, commute).
3. **Secondary — Action Button (Ultra, Series 9/10+).** Wire a Jot AppIntent so the user can map their Action Button to "Start Jot dictation" via the system Action Button picker.

Defer (v2+):
- **Double Tap** (S9+ accessibility gesture) — only fires when the app is foreground with a `.handGestureShortcut(.primaryAction)` Button, so it's a "stop recording" candidate, not a "start." Wire as the stop control inside the recording view.
- **Siri shortcut / App Shortcut** — AppIntents on watchOS are still nascent; nice-to-have, not MVP-critical.
- **Digital Crown gesture** — no API for arbitrary crown press as a launcher.

Sources: [What's new in watchOS 26 — WWDC25](https://developer.apple.com/videos/play/wwdc2025/334/), [Build widgets for the Smart Stack on Apple Watch — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10029/), [Enabling the double-tap gesture — Apple Developer](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap).

---

## 6. Display during recording

- **Timer + amplitude bar + Stop.** Single-glance UI. Use `TimelineView(.periodic)` for the timer. Skip the live transcript on MVP — there is no on-Watch transcription pipeline in the recommended architecture, so there's nothing to display.
- **Haptics.** Map to Jot's existing iPhone haptic vocabulary so the device-to-device experience feels coherent — `.start` on record start, `.stop` on stop, `.success` on confirmed `transferFile` completion. The Watch uses `WKInterfaceDevice.current().play(_:)` with `WKHapticType` rather than `UIImpactFeedbackGenerator`.
- **Always-on display.** Watch faces dim aggressively on AOD. For an active recording, set the watch app to stay "always on" by adopting `WKExtendedRuntimeSession` for the recording duration — this is the same pattern workout apps use. The display will dim but the recording continues.
- **Storage warning.** Pre-flight available storage at record-start; soft-warn at <50 MB free; hard-block start at <5 MB.

---

## 7. Sync model

**Use `WatchConnectivity` with the right method per payload:**

| Payload | Method | Why |
|---|---|---|
| Final audio file (~MB) | `transferFile(_:metadata:)` | Survives app death, retries automatically, queued in background. Real-world devs report ~30 MB has been transferred without issue; no documented cap, but bandwidth limits in practice. |
| Recording metadata (id, start time, duration, optional voice-command flag) | `metadata:` dict on the `transferFile` call | Bound to the file, arrives atomically. |
| "Watch is currently recording" presence ping | `updateApplicationContext` | Latest-value-wins; iPhone home view can show the live preview row. |
| Settings (warm-hold opt-in, vocabulary, etc., iPhone → Watch) | `updateApplicationContext` | Same. |
| Cancel-by-user signal | `sendMessage` (best-effort, only when both reachable) | Acceptable to drop if peer unreachable — user can also tap Cancel on the Watch. |

```swift
// In WatchSyncCoordinator (NOT shipped)
let metadata: [String: Any] = [
    "id": uuid.uuidString,
    "startedAt": startDate.timeIntervalSince1970,
    "duration": recorder.currentTime,
    "source": "watch"
]
WCSession.default.transferFile(audioFileURL, metadata: metadata)
```

**iPhone-side reception:** implement `session(_:didReceive:)`, copy the file out of the inbox (iOS deletes the inbox file after the delegate call returns), append a `Transcript` row in `TranscriptStore` with `source == .watch`, kick the existing Parakeet pipeline. Reuse the iPhone's existing `TranscriptHistoryMirror` so the new entry shows up in the Library exactly like any iPhone-originated transcript.

**App wake guarantees:** the iOS host app **is** launched by the system when a `transferFile` arrives, even if it isn't running — but only "in a background launch with limited time" (per WWDC15 session 713 and the docs). Transcription should kick off, but if Parakeet takes too long the OS may suspend mid-decode; the design needs an iOS Background Tasks (`BGProcessingTaskRequest`) fallback to finish on next foreground.

**Sync conflicts:** trivial in Jot's model — each `Transcript` has its own UUID, the Watch never modifies an iPhone-originated transcript and vice versa. No merge logic needed.

**CloudKit alternative:** instead of WatchConnectivity, you could put `Transcript` into a CloudKit-backed SwiftData store and let both devices read/write it. This is what Voice Memos effectively does (iCloud Voice Memos toggle). Pros: works even if iPhone never pairs. Cons: requires iCloud account, raw audio over CloudKit is slow and quota-bound, and Jot's current copy promises "audio never leaves your iPhone" — opting into iCloud would break that. Stick with WatchConnectivity for MVP.

Sources: [WCSession transferFile docs](https://developer.apple.com/documentation/watchconnectivity/wcsession/1615667-transferfile), [Size limits for WatchConnectivity — Martin's Tech Journal](https://blog.martinp7r.com/posts/size-limits-for-watchconnectivity-data-transfers/), [Using transferFile and sendMessage — Medium](https://medium.com/@bryan.vernanda/using-transferfile-and-sendmessage-in-watch-connectivity-swiftui-edee23c69286), [There and back again: Data transfer on Apple Watch — WWDC21](https://wwdcnotes.com/documentation/wwdcnotes/wwdc21-10003-there-and-back-again-data-transfer-on-apple-watch/), [WWDC15 session 713 background launch](https://asciiwwdc.com/2015/sessions/713).

---

## 8. Comparable apps

- **Apple Voice Memos on Watch.** Records locally on the Watch (independent of iPhone). Syncs to iPhone/Mac via **iCloud Voice Memos** (toggle in iCloud settings), not via WatchConnectivity. Wi-Fi-required for sync; recordings show up in the iCloud-shared library. Transcription happens on iPhone/Mac post-sync, not on Watch. This is the closest UX template for Jot.
- **Just Press Record.** Was the watchOS poster child. Records standalone, syncs via iCloud to iPhone, transcription runs on iPhone (uses SFSpeechRecognizer afaict). MacStories review highlights: complication launches recording, watchOS 4 enabled "continue in background," "Watch tab" on iPhone dedicated to watch-originated clips. Reviews emphasize **the Watch app's value is not "everything," it's "instant capture from the wrist."** That's the right lens.
- **Otter / Whisper Memos / SuperWhisper.** None ship a notable Watch app as of late-2025 surveys. SuperWhisper is Mac-only. Otter has historically focused on phone/web. There's a gap in the market for AI-quality transcription on Watch.
- **WWDC sample code 2024/2025.** No first-party "record on watch, sync to phone" sample. WWDC25 session 334 ("What's new in watchOS 26") covers Smart Stack widget interactivity, RelevanceKit, and double-tap improvements that are all relevant entry-point material.

Sources: [Just Press Record on App Store](https://apps.apple.com/us/app/just-press-record/id1033342465), [Voice Memos for Apple Watch — Apple Support](https://support.apple.com/guide/watch/voice-memos-apd441786282/watchos), [MacStories — JPR Watch refresh](https://www.macstories.net/reviews/just-press-record-refreshes-its-ios-design-and-adds-powerful-features-to-its-watch-app/), [What's new in watchOS 26 — WWDC25 session 334](https://developer.apple.com/videos/play/wwdc2025/334/).

---

## 9. Specific risks for Jot

- **Warm-hold v3 is iOS-only and stays iOS-only.** The iPhone audio engine has zero awareness of what the Watch is doing. The Watch needs its own simple mic state machine — `idle → recording → stopping → syncing`. No warm-hold on Watch in v1 (battery + complexity unjustified for what is essentially a capture-and-forget surface).
- **FoundationModels.framework: most-likely iOS-only on 26.** Apple's newsroom only lists iOS 26 / iPadOS 26 / macOS 26 for the public Foundation Models framework. WatchOS support is unconfirmed in public docs and almost certainly not present given Watch hardware. Treat it as iOS-only: `CleanupService` (which Jot's main app already uses) runs on the iPhone post-sync, so cleanup of watch-originated transcripts works without changes. No watch-side dependency on FM.
- **Phi-4 / MLX rewrite is unrunnable on Watch.** The 2.4 GB model wouldn't fit and MLX has no watchOS port. Rewrite happens on iPhone after sync, identical to today — user opens the new transcript in Detail, taps Rewrite, runs through the existing pipeline. Watch UI needs no rewrite affordance in v1.
- **No custom keyboard on Watch.** The 60 MB-ceiling Keyboard extension does not have a Watch analog; watchOS keyboards are system-controlled. Watch "paste destination" is via Apple's existing dictation flow into Messages / share extensions on Watch, which the user already has. Jot's watch role is **capture, not paste** — the captured transcript lives in the iPhone Library, the user paste-flows from the iPhone Keyboard as today.
- **SwiftData model sharing.** `Transcript` is currently iPhone-only. Two options: (a) define the model in `Shared/` and conditionally compile watch-side as a stub since the Watch never reads the Library (Watch only writes "I just recorded N seconds, here's the file" via WatchConnectivity, iPhone owns the SwiftData store); (b) make the Watch a true SwiftData participant via CloudKit. Strong recommend **option (a) for MVP** — Watch holds an outbox file + a thin local queue, iPhone is the single source of truth for the Library.
- **`Shared/` compile contamination.** Adding watchOS as a third compile target for `Shared/` will surface every UIKit / iOS-only import that's currently implicit. Budget one focused pass to add `#if os(iOS)` / `#if os(watchOS)` gates, particularly around `AppGroup+Rewrite.swift`, `KeyboardRewriteRouter.swift`, `PipelinePhaseProjection.swift`, and the `LLM/` and `Intents/` subdirectories.
- **Apple Watch audio quality is real-but-modest.** Watch mics are tuned for voice (Siri) and proximity speech. Parakeet handles this well in tests on iPhone speakerphone, but expect a measurable WER bump vs. iPhone-recorded audio. Set user expectation.

---

## 10. Effort estimate / MVP scope

**Honest sizing: 2–3 weeks of focused work for an MVP.** Not days — the watch target, sync coordinator, recording pipeline, and reception/triage on iPhone are all new surface area. Not months — the architecture leans heavily on existing iPhone infrastructure.

### MVP definition

> Tap the Jot complication on the watch face → recording starts immediately with a timer + amplitude readout + Stop button → user taps Stop → audio is queued and `transferFile`'d to the iPhone next time the two are in range → on the iPhone, the new audio is fed through the existing Parakeet pipeline and the transcript appears in the Library with a small "from Watch" badge → the rest of Jot's iPhone flow (rewrite, copy, paste, AI cleanup) works unchanged.

**Capability surface for MVP:**
1. New `JotWatch` SwiftUI target (xcodegen entry, Info.plist, entitlements, AppIcon, sharing the App Group + `Shared/` with os-gates).
2. Complication (`AccessoryCircular`, `AccessoryCorner`) + Smart Stack widget that both deep-link into a "begin recording" route.
3. On-Watch recording view: timer, amplitude bar, Stop, Cancel. `AVAudioRecorder` writing 16 kHz mono AAC to the watch's App Group.
4. `WCSession` plumbing: `transferFile` on stop with metadata; iPhone-side `didReceive` handler that drops into the existing pipeline.
5. iPhone-side Library row badging — recognizable "from Watch" pill on transcripts with `source == .watch`.
6. Pre-flight: mic permission flow, sufficient-storage check, "iPhone unreachable, queued for sync" empty state.

**Explicitly deferred (NOT in MVP):**
- Live on-watch transcription (no SFSpeechRecognizer integration, no Whisper-tiny).
- AI Rewrite on Watch (no MLX, no FM).
- Warm-hold on Watch.
- Multi-slice / chained follow-ups on Watch.
- Search / Library browsing on Watch.
- Settings UI on Watch — settings stay iPhone-managed and sync via `updateApplicationContext`.
- Action Button mapping (defer to v1.1 — needs an AppIntent surface that doesn't exist on Watch yet).
- Double-tap gesture wiring (defer — nice-to-have, not blocking).
- Vocabulary boost / saved prompts on Watch.
- Voice prompt capture on Watch (rewrite-by-voice is an iPhone-only flow).
- iCloud / CloudKit-backed Transcript syncing.

---

## 11. Recommendation

**Build it, but not yet, and only as a minimal capture surface.**

Worth building: the "iPhone not nearby" capture moment is a genuinely differentiated use case that Jot's iPhone-only product cannot serve. Joggers, parents on a walk, people whose phone is charging in the next room — all real Jot personas. The architecture is straightforward because the Watch's role is small: it's a wrist-worn microphone with a Stop button that hands the file to the iPhone, where Jot's actual product lives.

Not yet: Jot is pre-App-Store with no install base. Until the iOS app stabilizes through TestFlight rounds, adding a watch target risks doubling the surface that has to ship working at launch. The "Round 1 on-device bugs" memo from 2026-05-11 is recent. Wait until the iPhone app is steady-state.

Recommended architecture: SwiftUI watchOS 26 app target, paired with iPhone Jot bundle, installable independently, sharing the App Group for intra-device file storage. **Audio captured on Watch, transferred via `WCSession.transferFile`, transcribed on iPhone with the existing Parakeet pipeline.** No on-watch transcription, no on-watch AI. Single primary entry point: complication on the watch face.

Recommended MVP scope: the six-item list in §10. Two-to-three focused weeks of work, no architectural changes to the iPhone app beyond a `WCSessionDelegate` shim and a `from Watch` Library badge.

Biggest open risks: (1) iOS Background Tasks reliability when transcription must run before the host app comes to foreground; (2) Watch battery cost under sustained recording, which is unmeasured for Parakeet's expected 16 kHz mono target; (3) user confusion about "where did my transcript go" if the iPhone isn't paired for hours after a Watch recording — needs explicit Watch UI copy ("queued, will sync when iPhone is nearby") and a `from Watch (synced now)` toast on the iPhone when it lands.

---

## Open questions for user

1. **Timing — wait or proceed?** The recommendation is to defer until the iOS app is steady on TestFlight. Do you want to proceed now anyway (e.g. as a parallel track while iOS QA bugs land), or queue this for after 1.0?
2. **MVP scope cut — agree with §10?** Specifically, are you okay with **no live transcription on Watch** in v1 (Option A only) and **no on-watch rewrite**? Both are tempting and both are big.
3. **Phone-not-nearby fallback behavior.** When the user records on Watch with iPhone unreachable, do you want the Watch to show "queued for transcription, requires your iPhone" (honest, sets expectation), or to do nothing and let the user discover the transcript on the iPhone later (less friction, can surprise)? Pick a copy stance.
4. **App Group vs. CloudKit for the `Transcript` store.** Recommendation is to keep iPhone as the sole SwiftData owner and use WatchConnectivity. This means a transcript recorded on Watch is **gone if the user wipes the Watch before pairing**. Acceptable, or do you want iCloud-backed durability (with the privacy-copy implications)?
5. **Entry-point priority for v1.** Recommended primary = complication. Acceptable, or do you want the Smart Stack widget or Action Button as primary instead? (Implementation cost is similar, but only one should be the "official" launchpad in onboarding copy.)
