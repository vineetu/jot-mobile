---
name: jot-design
description: Use this skill to generate well-branded interfaces and assets for Jot (privacy-first iOS voice-dictation app), either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files. Read FEATURES.md to understand what every Jot feature does and how the product should feel before designing anything new.
If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.
If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Non-negotiables when designing for Jot:
- One accent: brand blue (canonical #1A8CFF; gradients #1A8CFF→#0064CC in-app, #2E9BFF→#0E7AE6→#0064CC wizard CTA). **Coral (#FF6B57, `--jot-ai-accent`) marks AI Rewrite surfaces only — never use it anywhere else; new AI features default to blue (Ask Jot is blue).**
- Two type voices: Fraunces for the editorial layer (UPRIGHT SemiBold + period for in-app page titles like "Settings."; *italic* for onboarding titles and anything spoken — transcripts, questions, streaming text); SF Pro/system for chrome and transcript-detail body.
- Dark is the primary appearance; both themes are tokenized (`styles.css`, `[data-theme="light"]`).
- Glass chrome: translucent fills + 0.5px hairline borders + backdrop blur. Backgrounds are layered gradients, never flat.
- No emoji. Honest, calm, second-person copy; titles often end with a period.
- The logo (j + 3-bar waveform tittle) is locked — use `assets/logo/`, never redraw it.
