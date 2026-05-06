# Jot

> **Speak, and it's written. Speak again, and it's rewritten.**

Native iOS dictation. Tap the mic, speak, and the transcript lands on your clipboard — ready to paste anywhere. Then speak again within 30 seconds to rewrite it with your voice. Entirely on-device. No cloud. No accounts. No telemetry.

## How it works

**1. Tap the mic.** From inside the app, the Dynamic Island, or your Jot keyboard.

**2. Speak naturally.** The pill shows amplitude in real time. No length limits. Cancel any time.

**3. Transcript lands on your clipboard.** Paste it into Messages, Notes, Slack — any app.

**4. (Optional) Speak a follow-up.** Within 30 seconds, say *"make it friendlier"* or *"make it shorter"* and Jot rewrites the previous transcript in place. No typing, no re-speaking from scratch.

## Capabilities

**On-device privacy.** Audio is transcribed locally on the Apple Neural Engine using [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) via [FluidAudio](https://github.com/FluidInference/FluidAudio). Nothing crosses the network. Run Little Snitch — you'll see silence during transcription.

**Voice-driven follow-up.** A 30-second window after every dictation turns your next utterance into a potential rewrite command. An on-device LLM (Apple Foundation Models) classifies *command* vs *new dictation*. A deterministic pre-classifier catches obvious command shapes ("change that to...", "make it...") without an LLM round-trip. No network, no leak.

**Full-access keyboard.** A custom keyboard extension with one-tap paste from your transcript history. Switch to the Jot keyboard from any app, insert a previous transcript without leaving.

**Live Activity + Dynamic Island.** Recording status, transcribing progress, and the 30-second follow-up countdown are visible from any screen on the system. Tap to dismiss the follow-up window without opening the app.

**Transcript history.** Every dictation is saved on-device (SwiftData). Your history stays with you; nothing syncs anywhere.

**Honest UX.** Chrome is monospaced, tracked caps, em-dash wraps. Status is a ghost ledger note, not a toast. The UI reads like a terminal log, not a setup wizard — because one more permission prompt is not a feature.

## Innovations

**Chained follow-up as voice-driven editing.** Most dictation apps hand you raw text. Jot lets you iterate on it by speaking — the 30-second window is an editing mode in disguise. "A second thought" becomes a clean rewrite, classified locally, applied to the previous transcript in place.

**Ledger aesthetic.** Inspired by terminal logs: monospaced fonts, tracked caps for system labels (`READY`, `PROC`, `CLEAN`, `FOLLOW`), em-dash wraps for placeholder voice (`— no entries —`), muted gray hierarchy, amber only for the recording dot.

**Cold-load honesty.** The first transcription after launching Jot takes ~19 seconds to load Parakeet into the Neural Engine. Instead of lying about it, Jot shows a ghost ledger note:

```
WARMING
— first transcription may take ~20s —
```

Reactive to actual model state. Vanishes instantly when the load completes. Subsequent recordings are ~100ms.

## What's coming

### Background model warming

Core ML's ANE-compiled cache persists across app launches and device reboots (per [WWDC23 session 10049](https://developer.apple.com/videos/play/wwdc2023/10049/)). We're building a `BGProcessingTask` that wakes Jot periodically to keep that cache primed — so after the very first use, every cold launch becomes a warm load.

### Action Button (with an honest platform caveat)

The dream: **press the Action Button → mic starts instantly → no app visible → paste the transcript when you're done.** Zero bounce.

**What works today:**

- iOS 18+ `AudioRecordingIntent` promotes the intent's `perform()` into the main app process
- `NSSupportsLiveActivities` declared, Live Activity starts cleanly
- iOS recognizes Jot as actively recording; the audio session activates without foregrounding

**What doesn't (yet):** `AVAudioEngine.start()` fails with OSStatus `'what'` (2003329396 — "invalid state") when the app is `running-active-NotVisible`. The same session configuration succeeds while visible. Same process. Same session ID. The only delta is process visibility.

Apple DTS [thread 65604](https://developer.apple.com/forums/thread/65604) (Quinn "The Eskimo!") confirms the rule:

> *"The audio background support only allows you to continue using an audio session that you created in the foreground; it does not allow you to start a session from the background."*

The limit is at the `AVAudioSession` layer. `AVAudioRecorder` hits the same rule — we researched it. The Action Button path promotes your process and registers you as recording, but Apple doesn't grant a *cold-start* exception.

**Current fallback:** Action Button bound to `DictateIntent` (`openAppWhenRun = true`) briefly bounces the app, records, returns. It works; it's just not zero-bounce.

**Research lanes we're watching:**

- `BGContinuedProcessingTask` (iOS 26+) — foreground-start, background-continue. Might allow a stealth foreground flicker that reads as zero-bounce.
- Pre-established engine — keep a recording-ready session alive across app launches via the audio background mode.
- iOS releases — Apple may ease the restriction in a future version.

We're not shipping a zero-bounce Action Button until it actually works on the current platform. No vapor.

## Tech

Swift 6 · SwiftUI + UIKit interop · SwiftData · [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT 0.6B v3) · Apple Foundation Models · ActivityKit · `AVAudioEngine` + `AVAudioConverter` (16 kHz mono Float32) · Custom keyboard extension with Full Access

## Requirements

- Apple Silicon iPhone (iPhone 15 Pro or later — Apple Intelligence + ANE required)
- iOS 26.0+

## Build

Jot is reproducible from [XcodeGen](https://github.com/yonaskolb/XcodeGen) specs so the Xcode project stays out of git.

```bash
# Fresh checkout: pull the vendored submodule (xgrammar C++ tree) before generating the project.
git submodule update --init --recursive
cd Vendor/mlx-swift-structured && git submodule update --init --recursive && cd -

brew install xcodegen
./build.sh            # regenerate the Xcode project from Jot/project.yml
open Jot/Jot.xcodeproj
```

Then pick a real device (the Simulator doesn't have the Neural Engine, so Parakeet won't run), sign with your Apple ID team, and build.

### Vendored dependencies

`Vendor/mlx-swift-structured/` is a vendored fork of [`mlx-swift-structured`](https://github.com/ml-explore/mlx-swift-structured) with 3.x dep pin bumps and a `tokenizerSource` 2→3 API patch. It pulls in [xgrammar](https://github.com/mlc-ai/xgrammar) as a nested git submodule under `Sources/CMLXStructured/xgrammar`. Fresh checkouts MUST run `git submodule update --init --recursive` inside `Vendor/mlx-swift-structured/` or the build will fail with missing C++ headers.

## Related

- [**Jot for macOS**](https://jot.ideaflow.page) — the desktop sibling: press a hotkey, speak, text appears at your cursor. Same transcription engine, different surface.

## License

TBD
