# Handoff: Jot Onboarding — "Now try the keyboard" (Wizard Step 5 of 7)

## Overview
This is the hands-on **"try it" step** of Jot's first-run setup wizard. Jot is a privacy-first
iOS voice-dictation **keyboard**. This step teaches the real dictation interaction for the very
first time, in a guided, one-action-at-a-time way: the user taps a practice field, raises the Jot
keyboard, taps **Jot down**, speaks a few words that stream live *inside the keyboard*, waits
through a one-time model warm-up, taps **Stop**, and watches their words paste into the field — a
clear "it works" moment. They then tap **Continue** themselves (no auto-advance).

It is presented as **6 sequential micro-states** of one screen. The wizard title
("Now try the keyboard") stays constant across all states; only the instruction line, the practice
field, and the keyboard change.

## About the Design Files
The files in this bundle are **design references created in HTML/React (JSX via Babel)** — prototypes
showing intended look and behavior. They are **not production code to copy directly**. The task is to
**recreate these designs in Jot's real codebase** (SwiftUI / UIKit for the iOS app and its keyboard
extension) using its established components, tokens, and patterns. If implementing on another platform,
use that platform's idioms — treat the HTML as the source of truth for *look and behavior*, not structure.

Note on architecture: in the real product the streaming/record UI lives in a **keyboard extension**
(`kb2`), while the wizard chrome and practice field live in the **containing app**. The prototype draws
both in one HTML frame for review; keep that app/extension split in mind when implementing.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, motion, and copy. Recreate pixel-accurately using
the codebase's existing Jot design tokens (see `tokens/colors.css`, `effects.css`, `typography.css` in
the design system — the values are mirrored below). Light **and** dark themes are both specified.

---

## Screens / Views

All states share this **frame**: 390×844 (iPhone logical points), full-bleed layered-gradient
background (never flat), vertical flex column:

```
StatusBar (54h, Dynamic Island)
WizardChrome (back ○ · 7 dots · close ○)   ← step indicator, current = index 4 (the 5th dot)
Content (flex, centered, 26px side padding)
  ├ Title  "Now try the keyboard"  (constant)
  ├ Instruction (changes per state)
  ├ PracticeField (the chat-style input box)
  └ Helper line ("Try saying ‘…’" phrase nudge / "Pasted from Jot ✓")
Keyboard  (states 2–5)   OR   Footer CTA + HomeBar (states 1 & 6)
```

### State 1 — Invite
- **Purpose**: invite the first tap.
- **Instruction**: "Tap the field below, switch to Jot via the globe key, then tap Jot down."
- **PracticeField**: empty, **glowing** — 1.5px accent-blue border, a breathing glow ring
  (`box-shadow 0 0 0 4px rgba(10,132,255,.14)`, 2.2s ease-in-out) and a diagonal sheen sweep
  (translateX −180%→320%, 2.6s). Placeholder text **"Tap to try it"** in accent blue, weight 600.
- **Helper**: a phrase nudge — `Try saying “I believe in myself.”` ("Try saying" muted sans; phrase Fraunces italic).
- **Bottom**: no keyboard. Footer CTA **"I tried it"**, then home indicator.

### State 2 — Jot down (keyboard rises)
- **Instruction**: `Say something out loud — like "I am awesome."` — the example phrase is
  **Fraunces italic**, full-ink; the rest is the muted sans body.
- **PracticeField**: empty with a blinking accent caret. No glow.
- **Helper**: phrase nudge `Try saying “I am awesome.”`
- **Keyboard**: visible, **idle** mode. Frosted info pane reads `Tap Jot down and start talking.`
  ("Jot down" bold). The **Jot down** record pill (mic + label) has an inviting glow
  (`try-dictglow`, 1.7s).

### State 3 — First-time setup (model warm-up, ~30–40s) — FIRST RUN ONLY
- **Purpose**: reassure during the one-time on-device model load, *before any text streams*.
  **Never a progress/fill bar, never a waveform.**
- **Instruction**: "Just the first time, the model needs a moment to load. Keep talking."
- **Helper**: phrase nudge `Try saying “Today is going to be a good day.”`
- **Keyboard**: recording, timer `0:06`. Pane label **"First-time setup"** with its pulsing accent dot
  — **that dot is the ONLY animated element on screen**. Pane body is one line, Fraunces italic:
  **“This is the slow part. It’s the only slow part.”** Nothing else (no headline, no caption, no bars).
- On subsequent runs this state is skipped — streaming begins immediately after Jot down.

### State 4 — Streaming inside the keyboard
- **Instruction**: "Model’s ready — your words stream inside the keyboard, not in the field."
- **PracticeField**: still empty (caret) — words deliberately do NOT appear here yet.
- **Helper**: empty (don’t nag with a suggestion once words are flowing).
- **Keyboard**: **recording** mode, timer `0:14`. Pane label **"We tidy this up when you stop"** with the
  pulsing accent dot (no waveform). Streaming text `I am awesome` in **blue italic serif**
  (`stream` color) with a blinking caret. Transport row: red **trash** ○ · **pause** ○ ·
  **Stop pill with running timer** (accent gradient) · **return** key.

### State 5 — Stop glows
- **Instruction**: "Tap Stop when you're done, and Jot pastes it into the field."
- **Keyboard**: recording, timer `0:20`. Pane shows the **full** line `I am awesome at this.`
  After a few seconds the **Stop pill glows** (`try-stopglow`, 1.5s) to invite the tap.

### State 6 — It works ✓
- **Instruction**: "That's the whole loop — your words landed in the field."
- **PracticeField**: now **filled** with `I am awesome at this.` (full ink, no glow/caret).
- **Helper**: **"Pasted from Jot"** with a small accent check — the success moment.
- **Bottom**: no keyboard. Footer CTA **"Continue"** (user taps it themselves — no auto-advance).

---

## First-time setup pane (State 3) — single decided design
The pane content during the one-time model warm-up. (Earlier A/B waveform options were cut.)
- Pane label **"First-time setup"** with a pulsing accent dot — **the only animated element on screen**.
- One line, Fraunces italic, full ink: **“This is the slow part. It’s the only slow part.”**
- **No** waveform, **no** fill/progress bar, **no** percentage, **no** secondary caption. The wry line
  carries the reassurance; the instruction line above the field handles the “keep talking” intent.

## Field helper — phrase suggestions
While the practice field is still empty (states 1–3), the helper line under it nudges the user with a
friendly phrase to try, in the form `Try saying “…”` ("Try saying" in muted sans, the phrase in
Fraunces italic). Rotate / randomize from this set:
  1. “I am awesome.”
  2. “I believe in myself.”
  3. “Today is going to be a good day.”
  4. “I’ve got this.”
  5. “Hello from my new keyboard.”
Once words are streaming (states 4–5) the helper is empty — don’t nag. On success (state 6) it becomes
**“Pasted from Jot ✓”**.

---

## Interactions & Behavior
- **Tap practice field (S1)** → raise Jot keyboard, advance to S2. Stop the glow/sheen.
- **Tap "Jot down" (S2)** → enter recording. **First run only**: while the on-device model loads
  (~30–40s), show the **First-time setup** pane (S3) — no text yet, user keeps talking.
- **Model ready** → begin live transcription into the keyboard pane (S4 streaming). Subsequent runs
  skip S3 and go straight from Jot down to streaming.
- **Stop pill (S5→S6)** → finalize transcription, **paste** the text into the practice field, show
  success helper, swap keyboard for the Continue CTA (S6).
- **Continue (S6)** → advance the wizard to step 6. **No auto-advance** anywhere.
- **Trash** discards the in-progress dictation; **pause** holds the recording.
- **Theme**: a light/dark switch flips every surface (prototype-only control; production follows the
  system appearance).

### Motion (all gated behind `prefers-reduced-motion: no-preference`)
| Name | What | Duration / easing |
|---|---|---|
| Field invite glow | breathing ring on practice field | 2.2s ease-in-out, infinite |
| Field sheen | diagonal highlight sweep | 2.6s ease-in-out, infinite |
| Jot-down glow | record pill invite | 1.7s ease-in-out, infinite |
| Stop glow | stop pill invite | 1.5s ease-in-out, infinite |
| Caret | text cursor blink | 1s steps(1), infinite |
| Recording dot | pane label pulse | 1.3s ease-in-out, infinite |

**Motion rule:** during First-time setup the pulsing pane dot is the ONLY moving element — there is no
waveform anywhere in the design. (Earlier waveform meters were removed deliberately; moving bars next
to a blinking dot read as too busy.)

## State Management
- `state`: `'invite' | 'rise' | 'init' | 'stream' | 'stop' | 'done'` — the micro-step, in this order
  (note: `init` / first-time setup precedes `stream`).
- `theme`: `'light' | 'dark'`.
- `isFirstRun`: boolean — gates whether the `init` (warm-up) state is shown at all.
- `transcript`: the live/finalized string streaming in the keyboard pane.
- `elapsed`: recording timer (mm:ss, tabular numerals).
- Triggers: field tap, Jot-down tap, model-ready event, Stop tap, Continue tap.

---

## Design Tokens
Mirrored from the Jot design system (`tokens/colors.css`, `effects.css`). Accent is a **single blue**
`#1A8CFF` family; coral is decorative only and not used here. The full per-theme map is in
`src/tryit-tokens.jsx` → `tok(theme)`. Key values:

### Colors — Light
| Token | Value |
|---|---|
| Screen bg | layered: `radial-gradient(128% 74% at 50% -8%, rgba(150,184,232,.62), …)` over `linear-gradient(177deg, #E9EEF7, #DEE4EE 44%, #D0D6E0)` |
| Ink / sub / caption | `#16181D` / `rgba(54,62,78,.70)` / `rgba(54,62,78,.48)` |
| Italic (spoken/helper) | `rgba(54,62,78,.62)` |
| Practice field fill / border | `rgba(255,255,255,.62)` / `rgba(20,30,50,.12)` |
| Chrome glass fill / border / glyph | `rgba(255,255,255,.72)` / `rgba(20,30,50,.08)` / `#3A4252` |
| Step dots: current / done / todo | `#1A8CFF` / `rgba(54,62,78,.42)` / `rgba(54,62,78,.18)` |
| Keyboard top→bottom | `#D5D7DE` → `#C9CCD3` |
| Keyboard accent | `#007AFF` |
| Stream text | `#3C5A99` |
| Pane glass / key fill / key ink | `rgba(255,255,255,.80)` / `#FFFFFF` / `#1C1C1E` |

### Colors — Dark
| Token | Value |
|---|---|
| Screen bg | layered navy-glow: `radial-gradient(128% 72% at 50% -8%, rgba(64,116,196,.50), …)` over `linear-gradient(177deg, #1b2c4f, #15233c 32%, #0e1827 72%, #0a1019)` |
| Ink / sub / caption | `#FFFFFF` / `rgba(233,238,247,.66)` / `rgba(233,238,247,.42)` |
| Practice field fill / border | `rgba(255,255,255,.05)` / `rgba(255,255,255,.14)` |
| Chrome glass fill / border / glyph | `rgba(255,255,255,.08)` / `rgba(255,255,255,.16)` / `rgba(255,255,255,.86)` |
| Step dots: current / done / todo | `#1A8CFF` / `rgba(255,255,255,.50)` / `rgba(255,255,255,.20)` |
| Keyboard top→bottom | `#25252A` → `#1A1A1D` |
| Keyboard accent | `#0A84FF` |
| Stream text | `#9CB3E5` |
| Pane glass / key fill / key ink | `rgba(70,72,82,.62)` / `rgba(110,114,126,.42)` / `rgba(255,255,255,.92)` |

### Shared
| Token | Value |
|---|---|
| Accent (brand) | `#1A8CFF` |
| CTA gradient (3-stop) | `linear-gradient(180deg, #2E9BFF 0%, #0E7AE6 54%, #0064CC 100%)` |
| CTA glow | `rgba(26,140,255,.44)` |
| Record red / dot | `#FF3B30` / `#E0173B` |
| Success | `#34C759` (light ink `#1B8E3E`) |

### Typography
| Role | Font | Size / weight / spacing |
|---|---|---|
| Title | **Fraunces**, *italic*, optical sizing on | 29px / 500 / −0.5px, line-height 1.05, single line |
| Spoken example, streaming text, koan, helper italic | **Fraunces**, *italic* | 16–18px |
| Body / instruction | SF Pro Text (`-apple-system`) | 17px / 400 / line-height 1.42 |
| Field text / placeholder | SF Pro Text | 16.5px (placeholder 600 when glowing) |
| Keyboard pill label | SF Pro Text | 18px / 600 |
| Stop timer | SF Pro Text, tabular-nums | 18px / 600 |
| Helper / caption | SF Pro Text | 13–14px |

**Rule:** Fraunces italic is reserved for *spoken* / editorial voice (title, the example phrase,
streaming transcript, koan, "Listening…"). All UI labels are SF Pro.

### Spacing / Radius
- Frame side padding 26px. Practice field min-height 104px, radius 18px, padding 16–18px.
- Chrome circles 46px, radius 23px. Step dots 6.5–7.5px. Keyboard pane radius 16px, margin 10px.
- Record/Stop pill height 50px, radius 25px. CTA height 62px, radius 31px.
- Hairlines are 0.5px. Home indicator 134×5px.

## Assets
No raster assets. All glyphs are inline SVG (mic, stop square, pause, trash, return, backspace,
globe, ellipsis, chevron, check, close) defined in `src/tryit-tokens.jsx`. The "j" brand badge is a
gradient circle with a Fraunces-italic "j". Fonts: **Fraunces** (Google Fonts) + system SF Pro.

## Files
- `Jot Try-It Step.html` — entry; loads React 18 + Babel, defines the design-canvas layout, the
  light/dark toggle, and all keyframes/animation CSS.
- `src/tryit-tokens.jsx` — `tok(theme)` token map (light + dark), all SVG glyphs, and the first-time
  setup note (`SetupNote`, text-only — no waveform).
- `src/tryit-wizard.jsx` — wizard shell: frame, status bar, chrome (back · dots · close), editorial
  type, the practice field, helper line, CTA, home bar.
- `src/tryit-keyboard.jsx` — the production Jot keyboard (`JotKeyboard`): idle "Jot down" pill and
  recording transport (trash · pause · Stop+timer · return), plus the frosted `KbPane`.
- `src/tryit-screen.jsx` — the `TryItScreen` state machine wiring all 6 states, plus `MicrocopyCard`.
- `src/design-canvas.jsx` — pan/zoom presentation scaffold (prototype only; not part of the feature).

## Reference: Jot design system
Colors/effects/typography tokens live in the design system under `tokens/` (`colors.css`,
`effects.css`, `typography.css`) and the keyboard/keyboard-extension patterns under
`ui_kits/setup_wizard/` and `ui_kits/ios_app/`. Use those real tokens/components when implementing.
