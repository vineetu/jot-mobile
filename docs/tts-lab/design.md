# TTS Lab — read transcripts aloud (Kokoro), play with voices/accents/languages

## Feature
A hidden, opt-in "lab" that lets the user **play a transcript aloud** in different
**voices, accents, genders, and languages**, fully on-device. Unlocked by a
gesture (no default-on download), it then fetches the Kokoro TTS model and adds a
**"Read aloud ▶"** control + voice picker to the transcript detail pane. For
non-English voices the transcript is **translated on-device first** (Apple
Translation), then spoken by the matching Kokoro voice — so "hear my note in a
French accent" is a 100%-offline loop.

## Owner decisions (locked 2026-06-21)
- **Hidden, opt-in unlock** — mirror the warm-yield 5-tap reveal: in Settings →
  About, tap a row N times → a **"Text-to-Speech (Lab)"** toggle appears. Turning
  it on is what triggers the download. This deliberately sidesteps the
  "download-first" privacy concern (the user explicitly opts in).
- **TTS engine: FluidAudio Kokoro** (`KokoroAneManager`) — already in the resolved
  package (no new dependency), on-device/ANE, same stack as Parakeet. NOT
  `AVSpeechSynthesizer`.
- **Translation: Apple Translation framework** (iOS 18+, `Translator` /
  `.translationTask`) — first-party, on-device CoreML, free, offline after a
  one-time language-pack download. **Fallback:** Apple Foundation Models / Qwen
  (already integrated) via an LLM prompt for any language Apple doesn't cover
  offline.
- **Surface: the transcript detail pane** — a "Read aloud ▶" button + a
  voice/language picker, visible only when the Lab is on AND the model is
  downloaded.

## Feasibility — CONFIRMED (research, not built)
- Kokoro module present: `Sources/FluidAudio/TTS/KokoroAne/KokoroAneManager.swift`
  (FluidAudio `0.14.7`, `project.yml:34`). Voices encode accent+gender: `af_`/`am_`
  = American F/M, `bf_`/`bm_` = British F/M; plus Spanish (`ef`/`em`), French
  (`ff`), Hindi (`hf`), Mandarin (`zf`) variants.
- API:
  ```swift
  let tts = KokoroAneManager(variant: .english)
  try await tts.initialize(preloadVoices: ["af_heart","am_adam","bf_alice","bm_george"]) // download
  tts.setDefaultVoice("bm_george")
  let samples = try await tts.synthesize(text: "…")   // [Float] → AVAudioPlayer
  ```
- Apple Translation: `LanguageAvailability().status(from:to:)` to check a pair +
  prompt the pack download; translate via the SwiftUI `.translationTask` session.

## Pipeline
1. Lab on → pick a voice/language (e.g. "French — Female").
2. If target ≠ English → **Apple Translation** (on-device) → translated text.
   (English voices skip this step entirely.)
3. **Kokoro** synthesize with the matching voice → play via a `.playback` audio
   session.

## Architecture (net-new, all main-app target)
- A thin **`TTSService`** over `KokoroAneManager`: `download(progress:)` /
  `isReady` / `speak(text:voice:) async` / `stop()`, owning a short-lived
  `.playback` `AVAudioSession` that **yields to the recording session** (never
  speaks while the mic is live or warm-held).
- A **`TranslationGateway`** wrapping the Apple Translation session (SwiftUI
  `.translationTask`-driven) + the Apple-FM/Qwen fallback for uncovered pairs.
- The Lab toggle + voice picker state in the App-Group defaults (so it persists);
  the hidden reveal in `SettingsView`/About.

## Constraints / verify-on-build
- **~510 phonemes per utterance** → chunk long transcripts by sentence and play
  back-to-back (or use FluidAudio `PocketTtsSynthesizer` for true long-form).
- **Two user-initiated downloads:** the Kokoro model (~tens of MB) + Apple
  language packs (per language). Both gated behind the Lab opt-in.
- **Audio-session coordination:** TTS playback must not fight the recording /
  warm-hold mic session — gate playback off `RecordingService.isRecording`.
- **Verify:** the exact Kokoro voice-switching mechanism (preload-a-set +
  `setDefaultVoice` vs re-init); and that each Kokoro language (esp. **Hindi**) is
  in Apple Translation's offline set — else use the Apple-FM/Qwen fallback.

## Out of scope (v1)
- SSML, custom lexicon (KokoroAne doesn't support them).
- Speaking Ask answers / capture confirmations aloud (that's the CarPlay/foundation
  B2 use of the same engine — this Lab is the transcript-pane playground only).
