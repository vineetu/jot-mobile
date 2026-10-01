# Vocabulary: evidence-typed pass on iOS (build 313, 2026-09-26)

Adopts jot-shared `6c53328` per the Mac agent's page (jot-vocabulary.vineetu.simple-host.app) and the Windows
handoff (jot-mac-ios-handoff). Step 1 of 2; step 2 = Windows-style TDT decode bias in a FluidAudio fork, then drop CTC
if it measures at least as well.

- `TranscriptionService` batch path: ONE `VocabularyPass.run` per dictation — textual (corrector, every run, not a
  fallback) + acoustic (CTC spotter detections as `.acoustic(score:)`, placed via `WordTimeline` from Parakeet token
  timings; dropped when unaligned). Replaces `ctcTokenRescore` + gate.apply + fallback corrector.
- `CorrectionStore.shared` learning guard (`AppVocabCore.isCommonOriginal`, active language list);
  `migrateCommonOriginalRulesIfNeeded()` on foreground, marked done only on a non-nil result.
- `AskPolicy.select(isCommonOriginal:)`; ranking weakest evidence first comes from the package.
- Settings term rows: visible `VocabularyHygiene` warning (+ "Too short"); the old English watchlist + invisible
  `.help` icon removed.

## Measured on the owner's real data (pulled from the phone, 2026-09-26)
- Ledger: 175 learned rules; the one-time cleanup changes 20 mappings (e.g. cloud→claude code, quinn→Qwen,
  rama→Ramaa, jimmy→Jamy, sri ram→Sriram: every one has an everyday word as the heard form).
- Spelling pass replayed over 5,661 saved English transcripts (317,446 words): 167 applies (0.53 / 1k words),
  2,797 held back. Most are right (codecs→Codex, Quen→qwen, Jamie→Jamy, Vinit→Vineet, JART→Jot, octa→Okta).
  Doubtful ones seen: cloud cover→claude code (6), Cathay→Nathan (4), coder→Codex (2), a DEXA→adelya (2),
  Node.Js→Codex, a GAN→Rungun, clouded→claude.md, Jason→Json. All are recorded, askable and undoable.
  Caveat: saved text already carries earlier corrections; the acoustic half can't be replayed without audio.
- Probe: scratchpad `vocabprobe` (SwiftPM over jot-shared). jot-shared `swift test`: 38 + 8 green.
