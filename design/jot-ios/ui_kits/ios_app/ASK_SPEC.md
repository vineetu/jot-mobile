# Handoff: Ask Jot (voice-first Q&A over your notes)

## Overview
**Ask Jot** is a Beta feature in the Jot iOS app: natural-language question-answering over the user's
own transcript/note library. The user opens it from a sparkles entry point on the home screen, **speaks a
question**, and Jot streams back a grounded answer with **inline citations** to the specific notes it used.

It is **voice-first**: opening the sheet starts listening immediately (no keyboard). The live transcript
becomes the on-screen hero so the user can look away and just talk. After a short silence the question
auto-sends; the answer then streams in and resolves into a body of text plus a **Sources** list.

This package documents one screen that morphs through a **3-phase lifecycle**: `listening → thinking → answer`.

---

## About the Design Files
The files in `prototype/` are **design references created in HTML/React (via in-browser Babel)** — a
working prototype that demonstrates the intended look, motion, and behavior. **They are not production code
to copy directly.**

The task is to **recreate this design in Jot's existing codebase** (iOS — SwiftUI/UIKit) using its
established patterns, components, colors, and type system. Treat the HTML/JSX as the source of truth for
*layout, spacing, copy, motion, and states* — not for implementation technique. Where this doc names a
hex value or duration, match it; where the app already has an equivalent token/component, prefer the app's.

The prototype runs at a fixed **390 × 844** logical canvas (iPhone 13/14-class) inside a device bezel. Build
responsively against the real safe-area insets.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, motion, and interaction model. Recreate pixel-accurately
using the app's native equivalents. The only deliberately-fake parts are the *data* (sample question, answer
text, and two source notes) and the demo's auto-play timing.

---

## Locked decisions (do not re-introduce options)
The prototype's Tweaks panel once exposed layout/accent/answer variants. These are now **decided**:
- **Input layout:** voice **canvas** (centered transcript hero). The "composer bar" variant is dropped.
- **Answer style:** **typeset** (flowing text, no card wrapper). The "carded" variant is dropped.
- **Accent:** **blue only**. **Never coral / orange anywhere, ever.**
- **Appearance:** support **Light and Dark** only, following the system setting. (The prototype defaults to Dark.)

The only user-facing toggle that remains (Light/Dark) exists so engineering can verify both themes; in
production it should just follow the OS appearance.

---

## Screens / Views

The feature is a single full-height sheet presented over the home screen (sheet top begins ~44pt below the
status bar; corners `40pt 40pt 0 0`). A persistent header sits at the top of the sheet in all phases.

### Header (all phases)
- **Left:** `Done` button — glass pill, height 38, padding 0/17, radius 19, `chromeFill` background with
  `0.5px chromeBord` border + `blur(16px)`. Label: SF, weight 500, 16.5pt, color `ink`. Dismisses the sheet.
- **Center:** two stacked, centered labels:
  - `Ask Jot` — SF, weight 700, 18pt, `ink`, letter-spacing −0.2.
  - `BETA` — SF, weight 700, 9.5pt, letter-spacing 2, color = accent blue `#0E7AE6`.
- Header height 56, pinned near the top of the sheet.

### Status bar (device chrome, above the sheet)
- Time `4:29` left; Dynamic-Island pill centered (contains a green continuity/link glyph `#2AD15F`);
  right cluster = mic glyph + battery.
- **Privacy dot:** a `#E8841C` amber dot (9×9) appears in the right cluster **only while phase === listening**
  (the iOS mic-in-use indicator). It is the *system* indicator — it is NOT a UI accent and is allowed to be
  amber. Everything inside the app remains blue.

---

### Phase 1 — Listening (voice canvas)
Layout: vertical stack filling the sheet under the header. Three zones top→bottom: **hero**, **status**, **dock**.

**Hero (flex: 1, centered, horizontal padding 34):** has two states —
- **Empty (no words yet):** centered column, gap 22:
  - Pulsing sparkle glyph, 34px, accent blue (`askPulse` 2.4s).
  - `What do you want to know?` — Fraunces *italic*, weight 500, 25pt, color `inkSub`.
  - **Rotating spoken-aloud suggestion** — Fraunces *italic* 17pt, color `inkCaption`, wrapped in
    “curly quotes”, cross-fading every 2800ms (`askFade` .5s). These are phrased as things to **say**, not
    tappable buttons. Copy set:
    - “Summarize what I recorded today”
    - “What did I decide about the launch?”
    - “Pull every note that mentions pricing”
    - “What were my action items last week?”
    - “Connect my notes about the redesign”
- **Words present (live transcript):** the transcript itself is the hero — Fraunces *italic*, weight 500,
  **30pt**, line-height 1.24, letter-spacing −0.4, color `ink`, centered, `text-wrap: pretty`. A blinking
  caret (2.5×28 bar, accent blue, `askCaret` 1s step-end) trails the text.

**Status zone (height 40, centered):**
- While receiving speech: a **Listening** row — pulsing accent dot (9×9, `askPulse` 1.4s) + `Listening`
  (SF 600, 15.5pt, `ink`) + a small reactive **waveform** (7 bars, accent blue, scaleY keyframes `wv1/2/3`).
- After speech pauses: replaced by the **countdown** (see Interactions).

**Dock (bottom, centered, padding 4/0/30, gap 13):**
- **Send-stop button** — ONE control. Circle 60×60. Disabled/empty: subtle fill
  (`rgba(255,255,255,0.10)` dark / `rgba(40,54,82,0.10)` light) with a dimmed up-arrow. Ready (has words):
  blue gradient fill, white up-arrow, glow shadow. **Tapping it both stops dictation and sends.** There is
  no separate stop button.
- **`Type instead`** text button below — keyboard mini-glyph + label (SF 500, 14.5pt, `inkSub`). Switches to
  typing: focuses a textarea (same Fraunces-italic 30pt hero style, `Type your question…` placeholder),
  shows `Voice paused · typing` in the status zone, and discards the in-progress voice transcript. Label
  toggles to `Use voice`.

---

### Phase 2 — Thinking
Layout under header: **Question header** + status + skeleton.

**Question header** (shared with Answer): left column —
- `YOU ASKED` — SF 600, 11pt, letter-spacing 1.4, uppercase, color `inkCaption`.
- The question — Fraunces *italic*, weight 500, 22pt, line-height 1.18, color `ink`.

**Status row** (padding 22/26/0, gap 10): pulsing accent dot (`askPulse` 1.1s) + a cycling status label
(SF 500, 16pt, `inkSub`, cross-fades on change). Steps, in order:
1. `Searching your notes…`
2. `Reading 9 notes…`
3. `Writing your answer…`

**Skeleton:** 4 shimmer lines (heights 15, widths 100/96/88/70%, radius 7) with a left-to-right shimmer
sweep (`askShimmer` 1.3s linear infinite) using `base`/`hi` tints derived from the theme.

---

### Phase 3 — Answer (typeset)
Layout under header: **Question header** (now with an `Ask another` pill on the right) + scrollable answer
region + action dock.

**Question header:** same as Thinking, plus a right-aligned `Ask another` glass pill (height 34,
padding 0/14, radius 17, `chromeFill`+`chromeBord`+blur, label accent blue, SF 600, 14pt). Resets to a
fresh listening session.

**Answer body (scrollable, padding 20/22):** flowing text, **no card** — SF, weight 400, **17.5pt**,
line-height **1.56**, color `ink`, letter-spacing −0.1. Streams in token-by-token (~34–68ms/word) with a
trailing blinking block caret (8×18, accent blue) until complete. Paragraph breaks render as 12px vertical gaps.

**Inline citation chips:** rendered inline at the points the model cited a note. Each chip:
- Inline-flex, baseline-aligned (translateY 1.5), margin 0/1.
- Background `accent.soft` (`rgba(26,140,255,0.20)`), border `0.5px` accent at 25% alpha, radius 7,
  padding 1.5/7/1.5/5.
- A small doc glyph (11px, accent) + label (e.g. `May 29`), SF 600, 12.5pt, accent blue.
- Tapping opens that source note (prototype shows a toast `Opening "May 29" note…`).

**Sources section** (appears once the answer finishes, `askRise` .4s):
- Header row: `SOURCES` (SF 700, 11pt, letter-spacing 1.4, `inkCaption`) + a hairline rule (`cardBord`).
- A list of **source rows**, divided by `0.5px cardBord` hairlines. Each row (padding 11/4): a 30×30 rounded
  tile (radius 9, `accent.soft` bg, accent doc glyph) + a two-line text column (date — SF 600, 14.5pt, `ink`;
  one-line truncated snippet — SF 400, 13pt, `inkSub`) + a right chevron (`inkCaption`). Tapping opens the note.
- Attribution line below, centered: `Answered with Apple Intelligence · 9 notes searched · on-device`
  (SF 400, 13pt, `inkCaption`). This is the model + retrieval-count + privacy disclosure.

**Action dock (bottom, padding 10/18/28, gap 11, `askRise` .4s):**
- **`Ask another`** — primary pill, flex:1, height 54, radius 27, blue gradient fill, white, SF 600, 17pt,
  sparkle glyph + label, glow shadow. Resets to listening.
- **Copy** — 54×54 glass circle (`chromeFill`+`chromeBord`+blur). Copies the answer; swaps glyph to a blue
  checkmark for ~1.4s on success.

---

## Interactions & Behavior

**Open → Listening.** Opening the sheet immediately enters `listening` with the mic active (privacy dot on).
Empty hero shows the prompt + rotating suggestions until the first words arrive.

**Live transcription.** As speech is recognized, words fill the hero in real time with a trailing caret; the
status row shows `Listening` + waveform. (The prototype fakes this by streaming a sample sentence word-by-word.)

**5-second silence auto-send.** When the user stops speaking (prototype: when the sample sentence finishes),
a **countdown** replaces the Listening row: a 32px ring (track + accent-blue progress arc, `stroke-dashoffset`
animating over 1s steps) with the remaining seconds (5→1) centered, beside the label
`Sending — keep talking to add more`. At 0 it auto-sends. **Speaking again cancels** the countdown and returns
to Listening. (Production: reset the timer on any new speech energy / recognized words.)

**Send (manual or auto).** Stops the mic, transitions to `thinking`. The send-stop button is the only commit
affordance; auto-send and the button do the same thing.

**Thinking → Answer.** Cycle the three status steps (~850ms, ~900ms apart in the prototype), then begin
streaming the answer. Real timing should track actual retrieval + model latency, not fixed delays.

**Answer streaming.** Tokens appear progressively with a caret; citation chips appear at their inline
positions. When the last token lands, reveal the Sources section + action dock together.

**Type instead.** `Type instead` switches to a focused textarea (canceling voice + countdown and clearing the
voice transcript); `Use voice` switches back. Send button enables when the field is non-empty.

**Done.** Dismisses the sheet (in the prototype it simply resets the demo).

**Citation / source tap.** Opens the referenced note. (Prototype: toast.)

**Reduced motion:** pulses, shimmer, waveform, and streaming should degrade to static end-states under
`prefers-reduced-motion` / iOS Reduce Motion — show the resolved transcript/answer without the animated build.

---

## State Management
State the screen needs:
- `phase`: `'listening' | 'thinking' | 'answer'`.
- `transcript`: string — the live/typed question text.
- `typing`: bool — voice vs keyboard input mode.
- `countdown`: number | null — seconds remaining in the silence auto-send (null = not counting).
- `thinkStep`: 0–2 — index into the thinking status steps.
- answer stream progress: how many answer tokens are revealed; `done` derived when all are shown.
- transient UI: `copied` (Copy confirmation), `toast` (note-open feedback).
- A run/session id to cancel stale timers when the user resets, types, or re-asks (the prototype uses a
  `runId` ref guard — important so old setTimeout/interval callbacks don't fire after a reset).

**Data requirements (production):** speech recognition stream; a retrieval call over the note library
(returns matched notes + count "9 notes searched"); a grounded generation call that yields answer text with
citation anchors mapping spans → source notes; each source = `{ date/title, snippet, noteId }`.

---

## Design Tokens

**Accent — blue (the only accent):**
- Gradient: `linear-gradient(180deg, #2E9BFF 0%, #0E7AE6 54%, #0064CC 100%)`
- Solid: `#0E7AE6` · Dot: `#1A8CFF` · Glow: `rgba(26,140,255,0.44)` · Soft: `rgba(26,140,255,0.20)`
- **Coral `#F0593D` is explicitly forbidden in this feature.**

**System indicator:** mic privacy dot `#E8841C`; status-bar continuity glyph `#2AD15F` (battery fill too).
These are OS chrome, not app accent.

**Theme — Dark:**
- ink `#FFFFFF` · inkSub `rgba(233,238,247,0.66)` · inkCaption `rgba(233,238,247,0.42)`
- chromeFill `rgba(255,255,255,0.08)` · chromeBord `rgba(255,255,255,0.16)` · chromeGlyph `rgba(255,255,255,0.86)`
- card `rgba(255,255,255,0.06)` · cardBord `rgba(255,255,255,0.11)` · fieldFill `rgba(255,255,255,0.045)` · fieldBord `rgba(255,255,255,0.14)`
- Sheet bg (layered): `radial-gradient(128% 72% at 50% -8%, rgba(64,116,196,0.50) 0%, rgba(40,74,128,0.16) 36%, rgba(18,30,52,0) 60%), radial-gradient(120% 84% at 88% 112%, rgba(120,72,56,0.20) 0%, rgba(120,72,56,0) 52%), linear-gradient(177deg, #1b2c4f 0%, #15233c 32%, #0e1827 72%, #0a1019 100%)`

**Theme — Light:**
- ink `#16181D` · inkSub `rgba(54,62,78,0.70)` · inkCaption `rgba(54,62,78,0.48)`
- chromeFill `rgba(255,255,255,0.72)` · chromeBord `rgba(20,30,50,0.08)` · chromeGlyph `#3A4252`
- card `rgba(255,255,255,0.78)` · cardBord `rgba(20,30,50,0.07)` · fieldFill `rgba(255,255,255,0.60)` · fieldBord `rgba(20,30,50,0.12)`
- Sheet bg (layered): `radial-gradient(128% 74% at 50% -8%, rgba(150,184,232,0.62) 0%, rgba(150,184,232,0.12) 40%, rgba(150,184,232,0) 62%), radial-gradient(120% 84% at 88% 112%, rgba(222,170,150,0.24) 0%, rgba(222,170,150,0) 52%), linear-gradient(177deg, #E9EEF7 0%, #DEE4EE 44%, #D0D6E0 100%)`

> Note: the warm/peach radial in both sheet backgrounds is a very low-alpha ambient wash, not an accent —
> it must never read as orange UI. If in doubt, drop it and keep the blue + neutral gradient.

**Typography:**
- Display/quotes/question: **Fraunces** (serif), *italic* for prompts/questions/transcript. Sizes used:
  hero transcript 30, empty-prompt 25, question header 22, suggestions 17.
- UI/body/answer: **SF Pro Text** / system (`-apple-system`). Answer body 17.5/1.56; labels 11–16.5.

**Radii:** sheet 40 (top); glass pills 17–19; send button 30 (60px circle) / 22 (44px); chips 7;
source tile 9; cards/fields 20–26.

**Shadows:** send-button glow `0 8px 22px -5px <glow>` + inset top highlight; primary CTA
`0 8px 24px -6px <glow>`; toast `0 12px 30px -8px rgba(0,0,0,0.5)`.

**Key animations:** `askPulse` (dot/sparkle breathe), `askCaret` (1s step-end blink), `askShimmer` (1.3s
skeleton sweep), `askFade`/`askRise` (.4–.5s reveals), `wv1/wv2/wv3` (waveform bar scaleY). Definitions are
in `prototype/Jot Ask.html` `<style>`.

---

## Assets
No raster assets — everything is inline SVG / CSS. Glyphs to recreate with the app's icon set or SF Symbols:
- Sparkle (Ask Jot mark) — see `Sparkle` in `wizard-ui.jsx`. (SF Symbol `sparkles` is a close stand-in.)
- Up-arrow (send), document, chevron-right, copy, checkmark, keyboard-mini, mic, battery, continuity-link —
  defined in `ask-ui.jsx` / `ask-app.jsx`. Prefer SF Symbols equivalents.
- Fonts: **Fraunces** (Google Fonts) for display; system SF Pro for UI.

---

## Files
In `prototype/`:
- `Jot Ask.html` — entry point: fonts, keyframes, device frame mount, script load order.
- `ask-app.jsx` — device frame, status bar, **lifecycle state machine**, sample data, theme/locked-value wiring.
- `ask-states.jsx` — the three phase views: `ListeningCanvas`, `ThinkingView`, `AnswerView`, plus
  `CountdownRing`, `QuestionHeader` (and `ListeningComposer`, which is the **dropped** variant — ignore it).
- `ask-ui.jsx` — shared atoms: header chrome, `Waveform`, `SendStop`, `SuggestionLine`, `CitationChip`, `SourceRow`, glyphs.
- `wizard-ui.jsx` — `jotTheme(dark)` token source + `Sparkle`/serif/system font constants (shared with other Jot screens). **ACCENTS includes a coral ramp used by other screens — do not use it here.**
- `tweaks-panel.jsx` — prototype-only tweak harness (Light/Dark toggle). **Not part of the product;** omit from implementation.

To run the prototype: open `Jot Ask.html` in a browser (it auto-plays the listening → thinking → answer loop).
