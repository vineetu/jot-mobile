# UI Kit — Setup Wizard

Interactive fork of the finalized onboarding prototype.
Open `index.html`: 7-step flow W1 Welcome → W2 Mic → W3 Keyboard → W4 How it works →
W5 Try it → W6 Warm-hold → W7 Ready. Tweaks panel toggles light/dark, keyboard state,
warm-hold mode (ship defaults: dark-follows-OS, jot mark, in-wizard warm-hold).

Files: `wizard-app.jsx` (state machine), `wizard-ui.jsx` (tokens + shared atoms),
`wizard-panels.jsx`, `wizard-extras.jsx`,
`wizard-keyboard.jsx`, `tweaks-panel.jsx` (prototype harness only).

Authoritative spec: `SPEC.md` in this folder (the original engineering handoff).
