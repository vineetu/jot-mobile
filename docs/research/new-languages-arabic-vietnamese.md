# New languages (Arabic, Vietnamese, Tagalog) — research, PARKED (owner 2026-09-27: plan later, no build)

Moonshine (latest 0.1.5, Aug 2026): Arabic / Vietnamese / Tagalog exist only as **Tiny** (27M) streaming models
(MIT; ar 15.5 %, vi 9.4 %, tl 14.9 % WER on Moonshine's own panel). Larger Moonshine = English (+ Small de/es/ja) only.
Owner wants best quality, not small models → Moonshine is not the lead option.

Arabic, ranked for iPhone (≤ ~1.5 GB):
1. NVIDIA Nemotron 3.5 ASR Streaming 0.6B — FLEURS ar 12.0–13.2 %, streaming, FluidInference CoreML (~664 MB,
   ANE), OpenMDW-1.1. One model also covers vi, uk, hi, tr… BLOCKER: iOS re-does a 15–20 s load every time
   (known-bugs-and-plans.md) — must be fixed first.
2. NVIDIA stt_ar_fastconformer_hybrid_large_pc (115M, MSA) — FLEURS 5.08 %, CV 7.97 %, offline, CC-BY-4.0; no CoreML
   port (same family as FluidAudio's 110M CTC → likely convertible). Best accuracy for a final pass.
3. Whisper large-v3-turbo (WhisperKit, 632 MB) — large-v3 8.3–16 % FLEURS depending on scorer.
Also measured weaker/too big: Qwen3-ASR (17–26 %), Cohere 2B (18.5 %), Voxtral 4B (>45 %).
Vietnamese: NVIDIA parakeet-ctc-0.6b-Vietnamese 6.86 % FLEURS (no port, gated licence); Qwen3-ASR 1.7B 5.55 %
(heavy); Nemotron 3.5 11–13 %.
Apple: SpeechTranscriber lacks ar/vi (probe, macOS 26); only DictationTranscriber has them (older, no streaming).
Dialects: all of the above are MSA-oriented. Nothing measured on device yet.

## Owner decision (2026-09-27)
Use **Moonshine** for Arabic and the other languages Jot doesn't support today (Vietnamese, Tagalog, + any other
Moonshine language not covered by Parakeet/Apple SpeechTranscriber) — because it actually runs on the phone
(small, ONNX via `moonshine-swift`), unlike Nemotron 3.5's iOS load problem. Next step: a PLAN only (not a build),
after the current Nemotron-diarizer / FluidAudio 0.17.4 work ships. The plan must include an on-device measurement
(Moonshine Arabic vs Apple DictationTranscriber ar_SA) before anything is enabled.
