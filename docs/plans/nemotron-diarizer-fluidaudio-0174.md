# Nemotron 3 diarizer + FluidAudio 0.17.4 + TTS removal (build 316, 2026-09-27)

Ported from Jot for Mac @ 1919006 (`docs/speaker-diarization/nemotron-migration.md`). pyannote/VBx, the owner voiceprint
("You" label), `VoiceCloneGuard`, and the whole TTS Lab (+ `AudioSessionArbiter`) removed (owner decisions);
`RetiredFeatureCleanup` deletes their files/keys at launch. FluidAudio 0.15.4 → 0.17.4 (stock; only
`DownloadUtils.ProgressHandler` → `ProgressHandler`). 0.17.4 adds a binary target (NemoTextProcessing.xcframework);
if SwiftPM hangs on `BinaryArtifactsManager.fetch`, seed `~/Library/Caches/org.swift.swiftpm/artifacts/` with the zip
(checksum 5fa8c10d…).

## Measured on the owner's Jot-for-Mac recordings (this Mac, scratchpad probes)
Transcription, 0.15.4 vs 0.17.4, same audio (16 recent English dictations 10–120 s + 2 calls of 10–13 min),
words changed ignoring punctuation/case:
| model | short dictations | long calls |
|---|---|---|
| Parakeet v3 | 6 / 773 (0.8 %) | 241 / 3,852 (6.3 %), 0.17.4 has +153 / −28 words — recovers phrases 0.15.4 dropped |
| Parakeet Unified | 14 / 725 (1.9 %) | 77 / 3,570 (2.2 %), +26 / −26 |
No reference transcripts, so "better/worse" on the long-form differences is not proven; the short-dictation path
(what the keyboard does) is essentially unchanged.

Speaker detection (Nemotron 3 fast128 + the iOS `DiarizationProjection`), Mac, 300–380× real time:
6 calls of 21–38 min → 5 × 2 speakers, 1 × 5 speakers (S3/S2/S1 = 22/13/10 s over the 6 s floor — unverified);
6 solo dictations (34–141 s) → 6 × single speaker. Not yet run on an iPhone.
