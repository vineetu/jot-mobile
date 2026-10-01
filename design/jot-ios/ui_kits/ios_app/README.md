# UI Kit — iOS App

Two live screens of the core app, forked from the finalized handoff prototypes:

- `recording.html` — the cold-start **recording surface** with the looping
  "swipe back to your app" coaching cue (deep spec: `RECORDING_SPEC.md`)
- `ask.html` — **Ask Jot**, the voice-first Q&A sheet; auto-plays
  listening → thinking → answer (deep spec: `ASK_SPEC.md`)
- `index.html` — both side-by-side in iframes (the DS-tab card)

No interactive home/library prototype exists yet — but production home-screen
screenshots (light + dark) live in `../../uploads/`, and its verified anatomy is
documented in the root `readme.md` (rotating serif headline, TODAY/LATEST caps,
featured quote, "Jot down" FAB, coral ✦ on rewritten rows).

Both screens support light/dark via their Tweaks panels; production follows the OS.
