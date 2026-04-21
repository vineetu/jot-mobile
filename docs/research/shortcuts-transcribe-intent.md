# Shortcuts "Transcribe Audio with Jot" intent — architecture research

**Target:** iOS 26+, Jot (jot-mobile), FluidAudio/Parakeet on-device.
**Goal:** A Shortcuts action `Transcribe Audio with Jot` that accepts an audio file (from the built-in `Record Audio` action) and returns a transcript string, so users can chain it in a shortcut bound to the Action Button and never leave Messages / wherever they are.

---

## 1. TL;DR

**Viable.** Ship a plain `AppIntent` with `openAppWhenRun = false`, `@Parameter var audio: IntentFile`, returning `some IntentResult & ReturnsValue<String>`, compiled into the **main app target** (no new extension target). iOS headless-launches the Jot process without bringing up any scene; the intent runs in-process; Parakeet loads from the app's Application Support; transcript is returned synchronously to Shortcuts, which hands it to `Copy to Clipboard`. User never leaves Messages. **Do NOT** use an AppIntents Extension — Parakeet's ~1.25 GB model will not survive extension memory caps.

---

## 2. The exact intent shape

```swift
import AppIntents
import Foundation
import UniformTypeIdentifiers

struct TranscribeAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio with Jot"

    static let description = IntentDescription(
        """
        Transcribe an audio file on-device using Parakeet. \
        Returns the cleaned transcript as text. \
        Fully local — nothing leaves your iPhone.
        """,
        categoryName: "Dictation"
    )

    /// KEY INVARIANT: we do NOT want to foreground Jot. The user is in
    /// Messages / Notes / wherever — the whole point of this action is to
    /// stay out of their way. iOS will launch Jot as a *headless background
    /// process* (no scenes) to run this intent if Jot isn't already running.
    static let openAppWhenRun: Bool = false

    static let isDiscoverable: Bool = true

    /// Required on iOS 26.2+ — without it, Shortcuts' action catalog has been
    /// observed to surface "Something went wrong" at bind time (see
    /// DictateIntent's doc comment for the original diagnosis).
    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$audio) with Jot")
    }

    /// `supportedContentTypes` restricts what Shortcuts will plumb into the
    /// parameter. `public.audio` accepts m4a/AAC (what the built-in
    /// `Record Audio` action emits), .wav, .mp3, .caf — anything AVAudioFile
    /// can decode. If we later discover a format that decoder chokes on
    /// we can narrow this.
    @Parameter(
        title: "Audio",
        description: "Audio file to transcribe.",
        supportedContentTypes: [.audio]
    )
    var audio: IntentFile

    /// Optional — lets a power-user toggle the LLM cleanup pass from the
    /// Shortcuts editor. Default mirrors app-level CleanupSettings.
    @Parameter(title: "Clean up transcript", default: false)
    var cleanup: Bool

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // IntentFile gives us either `.fileURL` (when backed by a file on
        // disk) or `.data` (when Shortcuts handed us an in-memory blob).
        // AVAudioFile needs a URL, so we normalise by writing any in-memory
        // blob to a temp file before decoding.
        let sourceURL = try await materialize(audio)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // Runs on the @MainActor TranscriptionService. Parakeet wants
        // 16 kHz mono Float32 — helper performs AVAudioFile → AVAudioConverter
        // → [Float] inside the service (see §5 Integration plan).
        let transcript = try await ParakeetFileTranscriber.shared
            .transcribe(fileURL: sourceURL)

        let finalText: String
        if cleanup {
            finalText = try await TransformClient.shared
                .clean(transcript: transcript)
        } else {
            finalText = transcript
        }

        return .result(value: finalText)
    }

    private func materialize(_ file: IntentFile) async throws -> URL {
        if let url = file.fileURL { return url }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(file.filename.pathExtension.isEmpty
                ? "m4a"
                : file.filename.pathExtension)
        try file.data.write(to: temp, options: .atomic)
        return temp
    }
}
```

And the `AppShortcut` registration (so users see a default tile without building a shortcut by hand):

```swift
// in JotAppShortcuts.swift
AppShortcut(
    intent: TranscribeAudioIntent(),
    phrases: [
        "Transcribe audio with \(.applicationName)"
    ],
    shortTitle: "Transcribe Audio",
    systemImageName: "waveform"
)
```

---

## 3. Process model

**Where the code runs:** in the **main Jot app process** (not an extension).

Empirically documented behavior (per Zach Waugh writeup; cross-referenced against Apple's AppIntent docs and Apple forum threads):

| State of Jot when intent fires | Where intent runs |
|---|---|
| Jot already foreground or background-suspended | Existing Jot process resumes, intent runs in-process |
| Jot not running | iOS **headless-launches Jot** as a background process **without instantiating any scene**, intent runs in-process |

Headless launch means `application(_:didFinishLaunchingWithOptions:)` is invoked but `UIWindowScene` lifecycle is not — our root SwiftUI view hierarchy is not constructed. The `TranscriptionService` singleton can still be constructed from `AppDelegate` (or lazily on first use), and Parakeet's model files — which live at `Application Support/Jot/Models/Parakeet/...` in Jot's normal container — are reachable because we ARE the Jot process.

**No AppIntents Extension needed.** AppIntents Extensions are a separate target type, a separate lightweight process, with substantially tighter memory caps (historically ~50–120 MB for the process, which is fine for a small DB query but nowhere near Parakeet's ~1.25 GB model). Apple's guidance at WWDC'24 was to move intents to an extension "for best performance" for *small* intents; large-model ML workloads are the explicit anti-pattern. We stay in the main app target.

**Cold start cost:** On a cold invocation (Jot not in memory), we eat process launch (~200 ms) + FluidAudio `AsrModels.load` (~1.5–3 s on iPhone 15 Pro for the CoreML Parakeet bundle) on first transcription. On a warm invocation (process still alive from a prior run), the model is already loaded and we pay only inference time (fraction of real-time on the ANE).

**Can we keep the model hot between invocations?** Not reliably. iOS will reap the backgrounded Jot process on its own schedule; we have no first-party way to pin it. Mitigations:
- Load the Parakeet model **lazily inside `TranscriptionService`** (which we already do). That way, every invocation after the first within the same process lifetime is warm.
- Do NOT try to share the model with an extension via XPC / Darwin notifications — extensions don't have enough memory to host it, and if the main app is alive the extension can't reach into its process anyway.
- Accept the cold-start cost. A 3-second first transcription for a typical user who presses the Action Button once every several minutes is fine.

**Concurrency:** `AppIntent.perform()` runs on an arbitrary queue by default. Our `TranscriptionService` is `@MainActor`, so the file-transcription helper must hop to `@MainActor` internally. We do NOT annotate `TranscribeAudioIntent` itself with `@MainActor` — that's unnecessary and has historically made intents un-bindable on Action Button.

**Memory:** 1.25 GB model in the main app process is well inside the ~1.5–3 GB jetsam ceiling modern iPhones grant apps. Parakeet working-set during inference is another ~150 MB — still fine. The existing memory-warning observer in `TranscriptionService` correctly evicts the model under pressure; for a Shortcuts-invoked process that might only live for 30 s, this path is mostly irrelevant (iOS reaps us before we hit a pressure signal).

**Execution time cap:** AppIntents invoked from Shortcuts with `openAppWhenRun = false` have a historical execution budget of roughly 30 s (same cap as iOS's headless-app background task). For a 15-s voice note this is safely under budget (decode ~100 ms, cold load ~3 s, inference sub-real-time on ANE → well under 10 s total). For a 10-minute lecture we'd be over. **Do not advertise this as a long-form transcription action**; if users chain it against long audio we need to add a warning in the IntentDescription or split the work across `ForegroundContinuableIntent` (which re-routes to the full foreground process and gets the normal ~30 min background-task budget).

---

## 4. Build changes required

**No new target.** Add the intent file(s) to the existing `Jot` app target.

### project.yml delta

The `Jot` target already includes `- path: App` and `- sdk: AppIntents.framework`. The new file `App/Intents/TranscribeAudioIntent.swift` is picked up automatically because `createIntermediateGroups: true` is set and App is a source path. **No project.yml change required** unless we want a new subdirectory group. (One optional hygiene change: add a `App/Intents/Transcription/` subfolder to separate dictation-style intents from file-transform intents.)

**Entitlements:** no change. `group.com.jot.mobile.shared` is already on the main app — the new intent doesn't need a different group.

**Info.plist:** no change. `NSMicrophoneUsageDescription` is only relevant for `DictateIntent` (live mic). The new intent decodes a file someone else recorded, so no mic-permission prompt is triggered when it runs.

**UIBackgroundModes:** already has `audio`. Not strictly required for file-decode (AVAudioFile reads a file without an active audio session), but harmless. Leave as-is.

### Code changes

1. **`App/Intents/TranscribeAudioIntent.swift`** — new file, shape in §2 above.
2. **`App/Intents/JotAppShortcuts.swift`** — append a second `AppShortcut` registration.
3. **`App/Transcription/TranscriptionService.swift`** (or new `App/Transcription/ParakeetFileTranscriber.swift`) — add a `transcribe(fileURL:)` helper. This is where the `parakeet-file-engineer` agent should focus. Shape:
   ```swift
   @MainActor
   final class ParakeetFileTranscriber {
       static let shared = ParakeetFileTranscriber()
       func transcribe(fileURL: URL) async throws -> String {
           let samples = try await decodeTo16kMonoFloat(fileURL: fileURL)
           return try await TranscriptionService.shared.transcribe(samples: samples)
       }
       // AVAudioFile → AVAudioConverter → [Float] helper
   }
   ```
4. **`App/JotApp.swift` / `AppDelegate`** — verify that `TranscriptionService.shared.prepare()` is called from `didFinishLaunchingWithOptions` (not from a SwiftUI `.task` modifier on a view, because headless launches skip scene construction). This is likely already correct — verify during integration.

---

## 5. Integration plan

Ordered, each step is a discrete commit/PR:

1. **Extract `ParakeetFileTranscriber`** — pull the Parakeet-wants-16kHz-mono-Float32 contract out of `TranscriptionService` into a helper that accepts a file URL. Uses `AVAudioFile` + `AVAudioConverter`. Write unit tests with a fixture .m4a recorded at 48 kHz stereo (real iOS Record-Audio output) to verify the converter path end-to-end. Keep the mic-path in `TranscriptionService.transcribe(samples:)` intact.
2. **Unblock FluidAudio / Xcode 26 module resolution** — the current `TranscriptionService` is a STUB because of an Xcode 26 explicit-modules build failure resolving the `FluidAudio` SPM dep. This blocks real transcription entirely. The parakeet-file-engineer agent should treat fixing this as prerequisite, not as part of this feature. If it's still blocked, ship the stub path plumbed end-to-end and flip one flag when the dep lands.
3. **Build `TranscribeAudioIntent`** — exact shape in §2 above. Add to `App/Intents/`.
4. **Register in `JotAppShortcuts`** — second `AppShortcut` entry, `shortTitle: "Transcribe Audio"`, `systemImageName: "waveform"`. Keep to a single phrase per intent (per the hard-won lesson in `JotAppShortcuts.swift` docstring).
5. **Launch-path hygiene** — in `JotApp.init` / `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, ensure `TranscriptionService.shared.prepare()` is called unconditionally (not gated on scene creation). This lets headless-launched processes start the model download/load eagerly instead of lazily on first inference.
6. **Manual verification**:
   1. Install on-device. Launch Jot once foregrounded so the model downloads.
   2. Open Shortcuts.app → `+` → New Shortcut → add `Record Audio` → add `Transcribe Audio with Jot` → add `Copy to Clipboard`.
   3. Run the shortcut from inside Shortcuts: confirm transcript appears on clipboard.
   4. Force-kill Jot in the app switcher. Re-run the shortcut from Shortcuts. Confirm transcript still appears — this validates headless-launch works.
   5. Bind the shortcut to Action Button (Settings → Action Button → Shortcut → pick the shortcut, NOT the raw intent). Press Action Button from inside Messages. Confirm: Messages stays foreground, mic indicator appears (from Record Audio), user speaks + taps stop, transcript lands on clipboard, user pastes.
7. **Action Button binding gotcha** — when building the Shortcut, bind the *shortcut*, not the raw `TranscribeAudioIntent`. Action Button supports binding a single intent directly, but our flow requires the built-in `Record Audio` as step 1, which can only be expressed as a multi-action shortcut. The user selects "Shortcut" as the Action Button type and picks the shortcut they built.
8. **Announce to intent-widget-engineer-2** — if that agent is building the intent side of this in parallel, they should use §2 as the spec verbatim and diverge only on field names/titles.

---

## 6. Risks

Ordered by severity. Each either blocks shipping or needs an experimental build to resolve.

1. **FluidAudio / Xcode 26 module-dep failure is still unresolved.** `TranscriptionService.swift` currently returns a stub string. Until this is fixed, `TranscribeAudioIntent` can be plumbed end-to-end but will return `"[stub] Parakeet disabled …"`. *Blocker for actual transcription.* Validate: run `swift build` against current `project.yml`, confirm FluidAudio resolves; if not, pursue the re-enable path documented in TranscriptionService.swift's header block before shipping.
2. **Headless-launch execution budget (~30 s).** For audio clips longer than roughly 30 seconds, cold-start + model-load + inference may exceed the background AppIntent budget and iOS will kill the process mid-transcription. Validate with a 60 s test clip; if it fails, conform to `ForegroundContinuableIntent` so the intent can hand off to the full foreground app when it needs more time (trades zero-friction UX for a brief Jot appearance on long clips).
3. **IntentFile format compatibility.** Shortcuts' built-in `Record Audio` outputs a standard m4a/AAC file — likely 44.1 kHz stereo based on Apple's generic iOS audio-recording defaults. AVAudioFile decodes this fine, and AVAudioConverter handles resample + channel-mix to 16 kHz mono Float32. *Low risk*, but validate with a real Shortcut-recorded file as a test fixture before shipping — don't just test with a hand-crafted 16 kHz mono wav.
4. **Action Button picker "Something went wrong" regression.** iOS 26.2 surfaced this error for `DictateIntent` until we (a) dropped `@available(iOS 17.0, *)`, (b) removed `public`, and (c) added a `parameterSummary`. Apply all three lessons to `TranscribeAudioIntent` from the start — the shape in §2 already does. If the picker still chokes on the new intent, suspect the `supportedContentTypes: [.audio]` value and experiment with `[UTType.audio]`, `[UTType.mpeg4Audio]`, or a string-based `supportedTypeIdentifiers`.
5. **Shortcuts metadata cache.** Shortcuts caches action metadata aggressively. If v1 ships with a broken shape, users may see the old bad metadata even after they install a fix. Recovery path: uninstall and reinstall the app, or long-press the action in a shortcut and choose "Reload" (exists on iOS 26+). Build+test aggressively on a dev device — the release path has real cost if we get the shape wrong.
6. **AppShortcutsProvider coupling.** Apple forum thread 707890 documents that intents in a separate target without proper `AppShortcutsProvider` registration can fail with `LNActionForAutoShortcutPhraseFetchError Code=1`. Our intents live in the main app target and are registered via `JotAppShortcuts`, so we're clear, but keep in mind if a future refactor tries to move intents to a framework — don't.
7. **Network check from a privacy-conscious user with Little Snitch-equivalent.** This intent should make zero network calls on the happy path. The existing `CleanupSettings` LLM path does call out — when `cleanup = true`, document prominently that LLM cleanup routes through whatever endpoint is configured. Default the new `cleanup` parameter to `false` so a user toggling this on for the first time makes an explicit choice.

---

## 7. Sources

### Apple first-party
- [AppIntent protocol](https://developer.apple.com/documentation/appintents/appintent) — reference for core protocol conformance.
- [IntentFile](https://developer.apple.com/documentation/appintents/intentfile) — file parameter type with `fileURL`, `data`, and `supportedTypeIdentifiers` affordances.
- [openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun-7ggw4) — "tells the system to consider the app intent even if its app is not in the foreground."
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) / [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) — what Apple's own built-in Transcribe-Audio action uses under the hood.
- [WWDC24 session 10210 — Bring your app's core features to users with App Intents](https://developer.apple.com/videos/play/wwdc2024/10210/) — the "field guide" reference.
- [WWDC24 session 10134 — What's new in App Intents](https://developer.apple.com/videos/play/wwdc2024/10134/) — covers extension bundles and framework entity support.
- [WWDC25 session 277 — SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) — Apple's on-device transcription pipeline.
- [UTType.audio](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/audio) / [UTType.mpeg4Audio](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/mpeg4audio) — supportedContentTypes candidates.

### Community & forum
- [Forcing an AppIntent to run in the main app process — Zach Waugh](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process) — authoritative writeup of the widget-vs-app process rules and the three protocols (`LiveActivityIntent`, `AudioPlaybackIntent`, `ForegroundContinuableIntent`) that pin execution to the main app process.
- [Apple Forums 707890 — App Intent in separate target does not work](https://developer.apple.com/forums/thread/707890) — cautionary tale on framework/extension-only intent placements.
- [Apple Forums 759160 — AppIntents don't show up in Shortcuts app when in SPM](https://developer.apple.com/forums/thread/759160) — "AppIntents code must be compiled directly into the app or extension (not through a package)."
- [Getting Started With App Intents — Use Your Loaf](https://useyourloaf.com/blog/getting-started-with-app-intents/) — baseline Swift patterns + the "shortcut launches app in background" default-behavior note.
- [Matthew Cassinelli WWDC'24 App Intents roundup](https://matthewcassinelli.com/roundup-of-app-intents-developer-sessions-from-wwdc24/) — session-by-session index.
- [WWDC22 session 10032 — Dive into App Intents (WWDCNotes)](https://www.wwdcnotes.com/notes/wwdc22/10032/) — original AppIntents design philosophy.
- [App Intents Field Guide for iOS Developers — Superwall](https://superwall.com/blog/an-app-intents-field-guide-for-ios-developers/) — comprehensive practitioner reference.
- [Feedback-assistant issue 425 — linkd fails to extract metadata for AppIntentsPackage in app extension](https://github.com/feedback-assistant/reports/issues/425) — metadata-extractor fragility when moving intents out of the app target.

### Internal (this repo)
- `Jot/App/Intents/DictateIntent.swift` — lessons on iOS 26.2 Action Button binding requirements (`parameterSummary`, no `public`, no `@available(iOS 17.0, *)`), which apply identically to the new intent.
- `Jot/App/Intents/JotAppShortcuts.swift` — single-phrase-per-AppShortcut lesson.
- `Jot/App/Transcription/TranscriptionService.swift` — current stub state + the re-enable path for the real FluidAudio implementation when the Xcode 26 dep issue resolves.

---

## Appendix: What Apple's built-in Transcribe Audio does

iOS 26's Shortcuts app ships a first-party `Transcribe Audio` action. Community reports and Apple's own framing at WWDC'25 indicate it uses `SpeechAnalyzer` + `SpeechTranscriber` on-device, running in the Shortcuts runtime without foregrounding any app (it has no "app" — it's a system action). Our shape deliberately mirrors its signature: audio-file input, string output, no-app-foreground. The only practical difference is our transcription engine (Parakeet TDT) is packaged inside our app, not provided by the system — which is why we need Jot to headless-launch whereas Apple's action has no such requirement.

Apple's action is a useful baseline: if a user already uses the Apple action in a shortcut, swapping in ours should be a one-drag operation — they shouldn't have to rebuild the shortcut around us.
