# DualModelPrototype

Standalone iOS prototype to validate dual-model ANE concurrency on iPhone 17.

## Purpose

Loads BOTH FluidAudio CoreML models simultaneously and exercises them in parallel from a single audio stream:

- **Streaming model:** Parakeet EOU 120M @ 320 ms chunk size (`StreamingEouAsrManager`) — for live ghost-text display during recording.
- **Batch model:** Parakeet TDT 0.6B v2 (`AsrManager`, `AsrModelVersion.v2`, `Repo.parakeetV2`) — for the high-quality final transcript.

Open question this prototype answers: can iOS 26 / iPhone 17 actually run two CoreML models concurrently on the Apple Neural Engine, or does the system serialize them under the hood? Memory + thermal observations are also part of the validation.

## Setup

```sh
cd /Users/vsriram/code/jot-mobile/prototypes/dual-model-prototype
xcodegen
open DualModelPrototype.xcodeproj
```

The project pins `FluidAudio` 0.13.6 (matches Jot main app) and uses Vineet's personal team `8VB2ULDN22`. Bundle ID: `com.vineetu.jot.mobile.dualmodelprototype`.

## Run

1. Pick **iPhone 17** as the run destination (physical device).
2. ⌘R to build + install + launch.
3. Grant the microphone permission prompt on first launch (it triggers via `NSMicrophoneUsageDescription`).
4. Wait for the status line to show **Idle** — both models are downloaded + loaded. The big record button stays disabled until then. Cold first launch will download:
   - Parakeet TDT 0.6B v2 weights (~443 MB)
   - Parakeet EOU 120M @ 320 ms weights (~66 MB)
5. Tap the blue mic button → speak (e.g. dictate a paragraph for ~30 s).
6. While speaking, the **Streaming** text area fills in live. Cumulative partials from the EOU manager are shown italic / dimmed (`.secondary`) until end-of-utterance promotes them.
7. Tap the red stop button to finish.
8. The status line goes to **Transcribing…**, then **Done in 1.42s** (or whatever the elapsed wall clock was). The **Final** text area fills with the v2 batch result.

## What to look for during testing

- **Both models loaded successfully.** Record button enables. Status hits **Idle** without an error message.
- **Streaming text updates live** during recording, no audio glitches in the captured samples.
- **Final v2 result is more accurate** than the streaming preview — proves both models actually ran (otherwise we might be silently falling back to a single model).
- **Memory usage at peak:** stay under **700 MB**. Use Xcode → Debug navigator → Memory gauge, or attach Instruments → Allocations. Combined model footprint per Subagent C's research: ~443 MB (batch) + ~66 MB (streaming) ≈ 509 MB resident.
- **Battery / thermal:** record a continuous **60 s** monologue. Note any device heating, battery drop, or thermal throttling banner. iPhone 17 should handle this comfortably; if it doesn't, that's a finding.
- **ANE concurrency check:** the streaming partial-transcript callback should fire at ~3 Hz (320 ms chunks) WHILE the batch model is queued idle. After stop, the batch path should run quickly (<1× real-time). If streaming partials hang while batch is loading or the device sounds overloaded, ANE may be serializing — flag this.

## Known limitations

- No UI polish (single screen, plain Text views, no haptics).
- No error recovery — if a model fails to load, you see the error and have to relaunch.
- No save-transcript, no history, no copy button. Transcripts disappear when you stop the next recording.
- No locale / language picker. Hardcoded model variants.
- Streaming text contract is the FluidAudio EOU "always-cumulative" branch from the research doc §6: each partial callback replaces the entire volatile tail; finalization happens once at `stop()` time. This is intentionally the minimum-viable adapter, not the Apple `SpeechTranscriber` incremental-results path.
- No App Group / cross-process IPC. This is a single-app harness; the keyboard extension's eventual integration is out of scope.

## What this prototype actually validates (and doesn't)

**Does validate:**
- Both Parakeet TDT 0.6B v2 and Parakeet EOU 120M @ 320ms can be **loaded and warm-resident in the same process** on iPhone 17 / iOS 26.
- Streaming model produces partials at ~3 Hz (320 ms chunks) during recording.
- Batch model can transcribe the full captured audio at end of session.
- Memory headroom: ~509 MB (~443 + ~66) is well within iPhone 17 base 8 GB RAM.

**Does NOT validate:**
- **Simultaneous ANE inference.** This prototype runs the streaming model DURING recording and the batch model AFTER `stop()` returns. They never inference concurrently. To prove ANE concurrency in the strict sense, a separate experiment would need to trigger periodic batch transcription on accumulated samples while streaming is still active — which is OUT OF SCOPE because the production Jot UX never does that either (streaming → finalize → batch is the actual flow).
- Background recording behavior (the prototype doesn't enable AppDelegate / Live Activity).
- App-Group cross-process integration with a keyboard extension.

## QA1715 caveats

The audio tap callback in `DualRecorder.swift` does work that real-time audio render threads should ideally avoid: allocates an output `AVAudioPCMBuffer` per buffer, copies samples into a `[Float]` array, runs `AVAudioConverter.convert`, and acquires an `NSLock`. For a validation harness this is acceptable; production code should:

1. Reuse a pre-allocated converted-buffer pool (no per-tap allocation).
2. Move conversion off the render thread via a lock-protected ring of raw `pcm` buffers + a separate Task that converts and dispatches.
3. Avoid any Objective-C runtime work on the render thread.

See Apple Tech Note QA1715 + TN3136 for the formal contract.

## File map

```
DualModelPrototype/
├── project.yml                         # xcodegen config (iOS 26, Swift 6 strict)
├── DualModelPrototype/
│   ├── DualModelPrototypeApp.swift     # @main, WindowGroup { ContentView() }
│   ├── ContentView.swift               # the single screen
│   ├── DualRecorder.swift              # audio capture + dual-model dispatch
│   ├── Info.plist                      # generated by xcodegen from project.yml
│   └── Assets.xcassets/                # AppIcon placeholder
└── README.md                           # you are here
```
