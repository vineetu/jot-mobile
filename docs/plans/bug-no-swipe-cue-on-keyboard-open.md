# Bug — Keyboard-initiated open sometimes skips the swipe-back card cue

**Status: noted 2026-06-13, not yet diagnosed. Diagnostic-first — do NOT ship a
fix before a captured failing log (per the bug-overconfidence rule).**

## Symptom (owner report, with screenshot)

Tapping **Jot down** in the keyboard from another app opens Jot and recording
starts — but the **swipe-back card cue ("nudge page") never appears**. The hero
goes straight to "Listening…" with the timer running (screenshot: hero at 0:04,
rotating top message visible — "A sharper transcriber takes a second pass…" —
transport controls present, NO card cue at the bottom).

- **Intermittent**: "happens now and then, I don't know when."
- **Pre-existing**: owner explicitly notes this is NOT from the latest build
  (observed before/around 1.0.5 build 119-120 era, likely earlier).
- Recording itself works — this is a missing-cue presentation bug, not a
  capture bug. (Contrast with the separate known bug "keyboard-initiated
  dictation opens Jot but does NOT start recording" — this is its inverse:
  recording starts fine, cue missing.)

## Where to look (orientation, not hypothesis)

- Cue visibility is derived: `showsSwipeCue = isExternalKeyboardLaunch &&
  !streamRevealed` (`RecordingHeroView.swift`); the trigger rename work
  collapsed cold-process `.onAppear` + warm-process `.onChange` presentation
  into `ContentView.presentExternalKeyboardHeroIfPending()` — see
  `docs/plans/cold-start-swipe-card-cue.md`.
- Candidate failure shapes to DISTINGUISH with logs (not to assume):
  1. Hero presented via a different intent path (not
     `.openedFromExternalKeyboard`) on this run → `isExternalKeyboardLaunch`
     false from the start.
  2. `streamRevealed` set early (e.g. a fast first partial / leftover state
     from a prior session) → cue suppressed before it ever rendered.
  3. The pending-hero flag consumed/cleared before presentation on a
     warm-process open.
- The screenshot shows the rotating top message IS present — only the card cue
  is missing — which may narrow which branch rendered.

## Next step

Reproduce with Console attached (or pull Diagnostics): grep
`RECORDING START FROM:` for the run + any hero-intent/presentation logs, and
capture whether `isExternalKeyboardLaunch` was true for that presentation.
One failing log decides between the three shapes above.
