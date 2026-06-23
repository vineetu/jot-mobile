# TTS Lab — a proper playground (idea capture, NOT scheduled)

Owner direction (2026-06-22): turn the experimental "Text-to-Speech (Lab)" toggle into a **real
dedicated Lab surface** you navigate to from Settings — a place to play with voices, cloning, and
the ideas below — rather than a hidden toggle bolted onto the transcript detail view. Post-release.

Status: **idea capture only.** No design, not scheduled. Confirm scope before building.

## Today (as-built)
- "Text-to-Speech (Lab)" is a hidden Settings toggle; read-aloud + voice cloning are wired into
  `TranscriptDetailView` only when it's on. Built-in voices = Supertonic-3 (fast); cloned voices =
  PocketTTS (FluidAudio). Apple Translation framework is already integrated (`TranslationGateway`)
  and used to translate a transcript before reading it in a non-English voice.

## Idea 1 — Export / download the synthesized audio  (small)
The audio is already produced as a buffer (clones return a 24 kHz WAV `Data`; built-ins are PCM),
and FluidAudio's `PocketTtsManager` exposes `synthesizeToFile()`. So "download the audio" = write
the buffer to a file (WAV/m4a) + a share sheet (Files / Messages / AirDrop). Low effort, clear win.

## Idea 2 — Multilingual clone playback ("hear yourself in another language")  (medium)
PocketTTS is multilingual and — crucially — **voice cloning is language-agnostic** (the clone
encoder `mimi_encoder` lives at the HF repo root, not under a language pack). So a clone embedding
captured in English can drive any language pack. Pipeline (all pieces exist):
> clone (timbre) → translate transcript to target language (Apple Translation, already wired) →
> synthesize translated text through the target language pack + the user's voice embedding →
> the user speaking that language, in their own voice.

- **6 languages:** English, French, German, Italian, Portuguese, Spanish (→ 5 "grew up elsewhere"
  options beyond English). Shipped as 10 packs (most have a 6-layer fast variant + a 24-layer
  higher-quality variant; English 6L-only, French 24L-only). **~550–767 MB per pack.**
- **Download on demand**, one language at a time (one `PocketTtsManager` per language; switching =
  reload). Same opt-in-download pattern as the rewrite model. Do NOT bundle.
- **Important distinction:** this is "you speaking French" (correct French, your timbre), NOT "you
  speaking English with a French accent." Accent-conversion-on-same-language is a separate
  research-grade problem PocketTTS does not do; feeding English to the French pack just mispronounces.
- **Cheap pre-check before designing:** verify on-device that an English-made clone actually sounds
  good driven through a non-English pack. Architecturally intended; confirm empirically first.

## Open questions
- Lab surface: a dedicated screen (voice gallery, clone manager, language picker, export) reached
  from Settings → "Lab". What lives there vs. stays in the transcript view?
- Per-language download UX + storage management (delete packs); honour the privacy/no-network posture.
- Latency: PocketTTS clones already have a noticeable time-to-first-audio (autoregressive + whole-clip
  buffering + per-chunk voice prefill + cold load) — streaming the first frame is the lever
  (separate note; relevant to making the Lab feel good).
