# Handoff · Jot iOS UX Redesign

## Overview

Jot is a free iOS dictation keyboard. This handoff covers a UX redesign across every primary surface of the app — plus the **new donation prompt + usage stats** feature.

In scope:

- **Recents** — the app's home screen (the list of past dictations)
- **In-app recording** — the screen the user lands on after tapping "Dictate" in the app
- **Settings** — main page, AI sub-page, Rewrite prompt editor, New prompt
- **Setup wizard** — 9 required steps + 2 optional (vocabulary + AI rewrite)
- **App icon**
- **Donation prompt + usage stats** (new feature, full spec below)

Out of scope (already shipped, locked):

- The **keyboard** itself (idle and recording states) — see `keyboard-ref.jsx` for the locked reference per the team's Reference v3 doc. **Do not modify the keyboard chrome.**

## About the design files

The files in `design/` are **design references built in HTML/JSX** — prototypes showing intended look and behavior, not production code to copy directly. Your job is to **recreate these designs in the Jot iOS codebase using its existing SwiftUI/UIKit patterns**.

Open `design/Color Explorations.html` in a browser to see the full design canvas: all screens side-by-side, pan and zoom. Each screen is in its own `.jsx` file (e.g., `screens.jsx` for Recents, `record.jsx` for the recording screen).

## Fidelity

**High-fidelity.** Final colors, typography, spacing, and interactions are specified below. Match pixel-for-pixel within reason. Where the SwiftUI/UIKit equivalent doesn't quite match the HTML rendering, prefer Apple-native materials (`UIVisualEffectView`, `.regularMaterial`, `.thickMaterial`) over hand-rolling blurs — they auto-adapt to dark mode and pressure changes correctly.

---

## Design language

A single visual system, intentionally tight:

### Surfaces

- **Page background** — Comfort gray. Base `#D1D3DA` with a soft wallpaper of radial gradients (blue top-left `rgba(0,122,255,0.18)`, warm bottom-right `rgba(255,200,140,0.16)`, soft blue bottom-center `rgba(180,200,240,0.30)`). Matches the locked iOS-gray keyboard chrome exactly so app and keyboard read as one continuous surface.
- **Cards** — Liquid Glass. `rgba(255,255,255,0.62)` + `backdrop-filter: blur(28px) saturate(200%)`. In SwiftUI: `.regularMaterial`. Subtle hairline border `rgba(0,0,0,0.05)` + soft shadow `0 14px 36px -28px rgba(15,17,28,0.30)` + interior highlight `0 1px 0 rgba(255,255,255,0.7) inset`.
- **Wizard** — same wallpaper as the app. (Cream was rejected. The wallpaper carries the warmth.)

### Color tokens

| Token | Hex / Value | Use |
|---|---|---|
| **Coral** (action) | `#FF6B57` → `#E0533F` (gradient `linear-gradient(180deg, …)`) | Brand actions: Save, Run, +New prompt, Dictate FAB in the app, primary wizard CTA |
| **Blue** (speech) | `#1A8CFF` → `#0064CC` (gradient) | Speech/dictation: keyboard Dictate pill **only**. Do not use elsewhere. |
| **Green** (state) | `#34C759` | "On" toggles, "Ready" / "Always" status pills |
| Page base | `#D1D3DA` | Chrome (matches keyboard) |
| Page text | `#15171C` primary, `rgba(60,60,67,0.65)` secondary, `rgba(60,60,67,0.55)` caption | |
| Card text | `#15171C` primary, `rgba(60,60,67,0.65)` sub | |
| Separator | `rgba(60,60,67,0.10)` | Row dividers inside cards |
| Status red | `#E0173B` (with soft halo `rgba(224,23,59,0.18)`) | Live recording dot |

**Color rules:**

- Coral = verbs (actions). Blue = speech. Green = state. Don't mix.
- The Dictate pill in the **keyboard** is blue (locked). The Dictate FAB in the **app** is coral (it's an action; the keyboard one is a speech-trigger pill).
- Toggle "on" color is **always green** (`#34C759`) — Apple convention. Coral toggles were tested and rejected (read as "alert" rather than "enabled").

### Multi-color semantic icons (Settings & Wizard)

Each settings section gets its own colored icon for wayfinding. Use these consistently:

| Category | Color |
|---|---|
| Speech model | `#1A8CFF` (blue) |
| Vocabulary | `#1FCED1` (cyan) |
| AI | `#FF6B57` (coral) |
| Privacy: On-device | `#34C759` (green) |
| Privacy: Full Access | `#7C5CFF` (purple) |
| Privacy: Mic ready | `#FF9A33` (orange) |
| Help & Support | `#1FCED1` (cyan) |
| Re-run wizard | `#1A8CFF` (blue) |
| Send feedback | `#7C5CFF` (purple) |
| Version | `#8B8E96` (slate) |
| **Donations (new)** | `#34C759` (green) |
| Privacy Policy | `#7C5CFF` (purple) |
| Acknowledgements | `#FF4F6B` (pink) |
| Design catalog (debug) | `#FF9A33` (orange) |

Tile is a rounded square (~28% corner radius of tile), with a `linear-gradient(180deg, color 0%, shade(color, -18%) 100%)` fill, `0 1px 0 rgba(255,255,255,0.35) inset` highlight, `0 1px 2px rgba(0,0,0,0.10)` shadow, `0 0 0 0.5px rgba(0,0,0,0.06)` hairline border.

### Typography

- **Display / titles:** New York (system serif), italic, weight 400, large size (44pt for hero titles like "Recents.", "AI.", "Settings."). Letter-spacing `-1.6`.
- **Body:** SF Pro Text / SF Pro Display.
- **Section labels (caps):** SF, weight 700, 11pt, letter-spacing 1.5, uppercase, color `rgba(60,60,67,0.55)`.
- **Row title:** 15pt weight 500, letter-spacing -0.2.
- **Row sub:** 12.5pt, color `rgba(60,60,67,0.65)`.
- **Featured content** (the LATEST entry on Recents, in-app recording transcript, prompt names): serif italic where appropriate. Adds editorial weight.
- **Monospace** (system prompt editor): SF Mono, 12.5pt, line-height 1.6.

### Spacing

- Card padding: 14–18px horizontal, 12–18px vertical.
- Section margin between cards: 14–22px.
- Page horizontal gutter: 14–22px.
- Iconograhy: 30–38px tile in row context, 76–92px in wizard hero.
- Card radius: 18–20.
- Icon tile radius: ~28% of tile size.
- Pill (button) radius: 999.

### Shadows

- Card shadow: `0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)`.
- Floating element shadow (FAB, footer pill): `0 14px 36px -22px rgba(15,17,28,0.35)`.
- Coral CTA glow: `0 4px 12px -2px rgba(255,107,87,0.40)`.

---

## Screens

### 1. Recents (home)

File: `design/screens.jsx` → `RecentsScreenAlive`.

**Layout (top to bottom):**

1. Status bar (54pt pad)
2. Nav row — `Jot` mark + "Jot" label (left), search circle + avatar (right)
3. Hero title — italic serif **"Recents."** (44pt) + date (`Thursday, May 15`) underneath
4. Hero stat card — large `12 min` + " saved today · 47 dictations" + a mini sparkline (coral line, gradient fill underneath)
5. *(Optional)* Donation card — see Donation feature spec below
6. List card — featured "LATEST" entry rendered larger in serif italic, then standard rows below
7. Floating Dictate pill (FAB) — coral gradient, mic icon + "Dictate" label, centered at bottom
8. Tab bar — Recents (active), Vocab, AI, Settings (with serif "AI" label etc.)
9. Home indicator

**Row components:**

- Each row: kind tag ("message" / "long-form" / "email") with a small check glyph, content snippet (2-line clamp), time + duration meta on the right. **No waveform thumbnail — Jot doesn't store audio.**
- Featured "LATEST" entry: same row data shape but rendered with serif italic body (one-line `“quote”` format) on a soft coral-tinted background. Header has uppercase `LATEST · [kind]` on the left and `time · duration` on the right. No play button — there's no audio to play.

**Live dictation state** (when the user backs out of the recording screen mid-dictation):

- **Featured entry mutates in place:**
  - Header label switches from `LATEST` to `● RECORDING` (coral, with a pulsing dot)
  - Right meta switches from `time · duration` to `0:14 · streaming` (coral)
  - Body shows the live transcript streaming in (with blinking coral cursor and no closing quote)
  - Card gains a subtle coral inner-ring (`box-shadow: 0 0 0 0.5px coral33 inset`) so it reads as active
- **FAB mutates in place:**
  - From `🎤 Dictate` to `○ Recording │ 0:14 ↗` (pulsing white dot, divider, monospace timer, small ↗ arrow indicating "tap to return")
  - Soft outer halo around the pill (`0 0 0 6px coral22`) so it reads as live
  - Tap the pill → returns the user to the full recording screen; the recording continues in the background while they're on Recents
- When recording ends, the live entry transitions seamlessly into a normal LATEST entry — same position, same shape, different state.

### 2. In-app recording

File: `design/record.jsx` → `RecordLetter`.

**Layout:**

- Status bar
- Header — *just* a "Cancel" pill on the right. No destination label, no red dot, no pause. Recording state is implicit.
- Transcript card (Liquid Glass plate, 24pt corner radius, hairline white border `rgba(255,255,255,0.4)`)
  - Big serif italic transcript, 26pt, line-height 1.32. No punctuation (raw model stream).
  - Coral blinking cursor at the live insertion point.
  - Live waveform at the bottom of the same card.
- Stop button at the bottom — coral gradient pill (32 corner radius, 64pt tall), contains a `[■]` stop square (white) + the running timer in monospace (`0:14`). **Timer lives in the stop button**, not the header.
- Home indicator

**Wallpaper:** same as Recents, with an additional `rgba(0,122,255,0.06)` blue tint overlay per Reference v3 spec for "recording state."

### 3. Settings (main)

File: `design/settings.jsx` → `SettingsScreen`.

**Layout:** Status bar → Nav (Jot mark + Jot label / Done pill) → Italic serif **"Settings."** (44pt) → sections.

Sections, in order:

1. **Speech model** — Parakeet TDT row (blue icon + "Ready" green status pill) + Variant row → `Parakeet 600M >`. Caption below: "Runs entirely on this iPhone. Audio never leaves the device."
2. **Vocabulary** — Custom terms row (cyan icon, "2 terms · on this iPhone"). Caption.
3. **AI** — Rewrite & prompts row (coral icon, "Phi-4 mini · Unloaded"). Caption: "Titles and tags use the system's built-in AI automatically."
4. **Privacy** — On-device only (green), Full Access (purple), Keep mic ready (orange, with long descriptive multiline body + green toggle). Caption.
5. **About** — Help & Support, Re-run setup wizard, Send feedback, Version `0.8 (1)`, Privacy Policy, Acknowledgements, Design catalog (debug). All with their semantic icons.
6. Centered footer: "Made with care in San Francisco. / No accounts, no cloud, no telemetry."

**With donation feature enabled** (after first dictation):

- Replace the "About" section label with the **stats moment** (see Donation spec).
- Insert a **Donations** row between **Version** and **Privacy Policy** in the About card.

### 4. AI · Your prompts

File: `design/ai.jsx` → `AISettingsScreen`.

**Layout:** Sub-page header (back / "AI" centered / Edit pill) → italic serif **"AI."** (44pt) **+ EXPERIMENTAL chip** beside it (small coral chip, all-caps, weight 700) → one-line description → compact model strip → "YOUR PROMPTS · 2" section label + "Drag to reorder" hint (right) → prompts card → +New prompt dashed card → footer caption.

**Model strip** (one place that says model status, not duplicated):

- 28pt purple wand tile + "Phi-4 mini · 2.4 GB · on-device" + green ready dot + "Ready · audio never leaves your iPhone" sub + "Change" coral link.

**Prompt card** (the key reusable component):

- 36pt icon tile (color per prompt) + serif name + "DEFAULT" tag (if builtin) + description sub + **mini before → after sample** + drag handle.
- The sample: 2-line italic gray *before*, coral arrow + uppercase name label, then the *after* content in clean dark text (can be running text or bulleted list for Bullet points prompt).

### 5. Edit prompt

File: `design/ai.jsx` → `RewritePromptScreen`.

Sheet-style modal:

- Drag handle, then Cancel · "Edit prompt" · **Save** (coral gradient pill).
- Compact header card: icon + serif name + description.
- **Full-bleed system prompt editor** — Liquid Glass card, monospace 12.5pt, char count + "Expand" coral link in the editor toolbar. Blinking coral cursor.
- Slim **"Try this prompt"** footer pill at the bottom — play icon + "Try this prompt" / "on your latest recording — …" + coral "Run" button. **Replaces the giant "Test on a recording" card that was previously there.**

### 6. Edit prompt · Try result (expanded state)

File: `design/ai.jsx` → `RewritePromptResultScreen`.

What happens after tapping **Run** in the Edit prompt screen — the footer pill expands upward into a result panel:

- Coral border + soft outer glow (active state).
- Header strip: "TRY THIS PROMPT · Latest recording, 5:48 PM" + dismiss `×`.
- "BEFORE" label + 3-line italic gray transcript.
- Centered coral arrow + "REWRITE" label + hairline rule + "1.8s" timing.
- "AFTER" label + serif italic result.
- Footer: "Phi-4 mini" meta on left, **Copy** (neutral pill) + **Run again** (coral gradient pill) on right. Both must use `whiteSpace: nowrap` and `flexShrink: 0` or "Run again" wraps.

### 7. New prompt

File: `design/ai.jsx` → `NewPromptScreen`.

Sheet-style modal:

- Drag handle, Cancel · "New prompt" · Save (faded coral, disabled until name + system prompt are filled).
- Header card with the selected icon tile + placeholder "Name your prompt" (italic gray serif) + hint "e.g. Translate to Spanish".
- **Icon picker** — 8 selectable color/icon tiles in a Liquid Glass card; the selected one gets a white-then-color ring + bigger size + soft glow.
- **System prompt editor** — empty with helpful placeholder (`Describe how Jot should transform the selected text. Tip: be specific about voice, length, and what to preserve. Test on a recording before saving.`) + blinking coral cursor.
- Footer: **Start from a template** affordance with 4 template chips (Translate to…, Make it shorter, More formal, Action items) — each chip carries the right icon color so users see what they'd get.

### 8. Setup wizard

File: `design/wizard.jsx`.

12 screens (was 13; W7 "iOS keyboard up" was removed — W8/W9 carry the meaningful moments):

| # | Name | Component |
|---|---|---|
| W1 | Welcome | `W1Welcome` |
| W2 | Speech model installed | `W2Speech` |
| W3 | Jot keyboard detected | `W3Keyboard` |
| W4 | How it works | `W4How` |
| W5 | Try it once (empty) | `W5TryEmpty` |
| W6 | Try it once (result) | `W6TryResult` |
| W7 | Now try the keyboard (Jot keyboard up) | `W8KbJot` |
| W8 | Now try the keyboard (filled, "Can you hear me?") | `W9KbFilled` |
| W9 | Keep mic ready? | `W10Mic` |
| W10 | You're ready | `W11Ready` |
| Optional 1 | Teach Jot some words | `W12Vocab` |
| Optional 2 | Add AI rewrite (with EXPERIMENTAL chip) | `W13AI` |

**Shared chrome:**

- Round back button (left) + 9-dot progress strip (with a horizontal divider before the 2 optional dots) + close × (right). Current step dot is coral, larger.
- Big serif title centered, with optional subtitle and italic hint underneath.
- Centered icon tile when relevant (hero size 76–92pt).
- Full-width coral CTA pill at the bottom + optional secondary text link below ("Skip", "Try again", "I've already done this", "Maybe later").
- Same wallpaper as the app.

**W6 transcript text** (post-dictation): "Testing Jot — looks like it's working." (matches the read-aloud prompt — not the misheard "For a touching, I know from the side." originally in the screenshots).

**W12 vocabulary words** (placeholders, no personal names): list of `Parakeet`, `Phi-4`; input field placeholder `Liquid Glass`. Caption: "You can edit these any time in Settings → Vocabulary."

**W13 EXPERIMENTAL chip** — sits to the right of the "Add AI rewrite" title as a small coral-tinted, all-caps, weight 700 pill.

### 9. App icon

File: `design/logo.jsx`.

**Final mark:**

- **Black Liquid Glass tile** (`#0A0A0C` base + radial top-left specular highlight + bottom vignette + hairline top-edge gleam + faint inner border at radius - 1).
- **Lowercase dotless j** (`ȷ`, Unicode U+0237) in white New York serif, fontSize ≈ 62% of tile.
- **Optical centering**: shift the letterform by `translate(+3% tile size, -6% tile size)` to compensate for the descender hook's leftward curl and the visual-center-below-line-center issue with lowercase j.
- **Coral mic-recording dot** — `#FF6B57`, size 16% of tile, positioned at `top: 16%, left: 46%` so it sits exactly where the natural j's dot would be — **but it's also the live mic light**. One mark, two readings.
- Dot has a radial gradient + halo (`rgba(255,107,87,0.20)` outer ring) + inner highlight.

Render at the iOS sizes: 1024 (App Store), 180 (iPhone @3x), 120 (Spotlight @3x), 87 (Settings @3x), etc. The mark scales cleanly; the dot stays visible at 29pt.

A "Refined · App gray" variant exists for comparison but the **recommendation is black** — it gives the coral dot maximum contrast and stands out on a home screen full of bright icons.

---

## Donation feature (new — full spec)

A non-intrusive way to (a) show the user how much they've gotten out of Jot, and (b) once they're clearly invested, point them at a donations page.

Files:

- `design/donation.jsx` → `DonationHomeCard`, `DonationStats`, `donationIcon`.
- `design/screens.jsx` → `RecentsScreenAlive` now accepts a `donationCard` prop.
- `design/settings.jsx` → `SettingsScreen` now accepts a `showDonation` prop.

### Surface 1 · Home card (Recents)

**Location:** between the hero stat card ("12 min saved today") and the list card.

**Trigger** (all must be true):

1. Cumulative dictation duration ≥ 2 hours
2. ≥ 7 days since the user's first recorded dictation
3. Card not previously dismissed or donated

Show **once**. After dismiss or donate, never re-fire.

**Copy** (final, do not edit without owner approval):

> **Jot is free, and stays free.**
>
> No accounts, no ads, nothing leaves your phone. If it's been useful, the donations page lists charities you can support.
>
> [See donations ↗] (coral pill, left) &nbsp;&nbsp; Not now (text link, right)

**Style:** same Liquid Glass card chrome as the hero/list cards. Title 15.5pt weight 600. Body 13pt regular, `rgba(60,60,67,0.70)`. Card padding 18 18 16. Card margin 0 14 14.

**Actions:**

- **See donations** → open `https://jot.ideaflow.page/donations` in Safari (default browser), mark state as `donated`, animate card out.
- **Not now** → mark state as `dismissed`, animate card out.

Both states are terminal. The card never returns.

**State storage:** UserDefaults key (suggested: `JotDonationCardState`) with values `nil` / `"dismissed"` / `"donated"`.

### Surface 2 · Stats moment (Settings → About)

**Location:** at the top of the About area, replacing the "ABOUT" section label.

**Trigger:** user has completed ≥ 1 dictation. Hidden otherwise.

**Format** — two quiet lines:

> **12 dictations** (serif, weight 500, 17pt, `#15171C`)
> About 5h 22m saved over typing. (sans, 13pt, `rgba(60,60,67,0.65)`)

**Numbers:**

- "12 dictations" — `pluralize(count, "dictation")`.
- "About 5h 22m saved over typing." — `dictationCount * averageTypingTimeMultiplier`. Recommended multiplier: **5×** (i.e., for every minute of dictation, estimate 5 minutes of typing saved). Round to `Nh Mm` format. Use `About` prefix to soften the precision claim.

### Surface 3 · Donations row (Settings → About card)

**Location:** between **Version** and **Privacy Policy** in the About card.

**Always present.** Independent of the home-card trigger.

**Format:** standard settings row — green gift icon (28pt tile) + "Donations" label + `↗` external-link arrow trailing.

**Action:** open `https://jot.ideaflow.page/donations` in Safari. Does not affect the home card state.

### Tone constraints (locked)

- No first-person from the maintainer ("I support…", "causes I care about", anyone's name).
- No guilt framing.
- No "100% goes to causes" claims.
- No flashy counter on the home header — stats stay quiet, in About.
- Apple-native feel (system materials, system fonts, iOS 26 Liquid Glass appropriate).

---

## Locked: the keyboard

`design/keyboard-ref.jsx` is the **reference rendering** of the keyboard per Reference v3. **Do not modify it.** Both states (idle and recording) are already shipped. The app screens are designed to harmonize with this keyboard — the gray base of the app wallpaper matches the keyboard chrome exactly, so there's no visible seam when the keyboard slides up.

Key values from Reference v3 (for context):

- Light chrome: `#D1D3DA` base, gradient `#D5D7DE → #C9CCD3` (matches iOS system bar).
- Dark chrome: `#1F1F22` base, gradient `#25252A → #1A1A1D`.
- Cards (Recents/Streaming) on the keyboard: `.regularMaterial`.
- Recording tint: `rgba(0,122,255,0.06)` light, `rgba(10,132,255,0.10)` dark.
- Recents text: `#3C5A99` light, `#9CB3E5` dark.
- Dictate pill: `#007AFF → #0064CC` gradient (blue) — this is the **only** blue in the app surface. Everywhere else, action = coral.
- Punctuation keys, light: pure white with subtle bottom shadow.
- Return key tint: `rgba(170,190,220,0.55)` light, `rgba(105,110,124,0.7)` dark.

---

## Design files

All in `design/`:

| File | Contents |
|---|---|
| `Color Explorations.html` | Master canvas. Open in a browser to see every screen side-by-side. |
| `app.jsx` | Canvas wiring — defines artboard sections + the Comfort palette tokens. |
| `screens.jsx` | Recents screen (incl. `RecentsScreenAlive` with `donationCard` prop), Wallpaper, JotMark, Avatar, MicIcon. |
| `record.jsx` | In-app recording screen + waveform helpers. |
| `settings.jsx` | Settings main page (with `showDonation` prop), Section, SettingsRow, IconTile, StatusPill, IOSToggle, the icon glyph set G. |
| `ai.jsx` | AI settings, Edit prompt, Try result, New prompt — full AI domain. |
| `donation.jsx` | DonationHomeCard, DonationStats, donationIcon. |
| `wizard.jsx` | All 12 wizard screens + shared WizardFrame chrome. |
| `logo.jsx` | App icon variants — final is `LogoRefined` (black, lowercase ȷ, coral dot, glass). |
| `keyboard-ref.jsx` | **LOCKED.** Keyboard reference per Reference v3. Do not modify. |
| `phone.jsx` | iPhone frame wrapper used by the canvas. |
| `design-canvas.jsx`, `ios-frame.jsx` | Generic canvas + iOS frame components (from starter kit). Not part of the app — purely for the design canvas. |

---

## Implementation notes

- **Target environment:** SwiftUI (iOS 17+). UIKit interop is fine where necessary (e.g., the keyboard extension itself).
- **Materials:** prefer `.regularMaterial` / `.thickMaterial` for the Liquid Glass cards. `UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))` for keyboard chrome (already shipped).
- **Type:** use `Font.system(.title, design: .serif)` for the italic display titles. The HTML uses "New York" / "Iowan Old Style" — these map cleanly to iOS's New York serif system font.
- **Dotless j** in the app icon: include it as a raster export or use SF Symbols / a packaged glyph. The character `ȷ` (U+0237) is in most serif fonts but worth verifying.
- **Animation:** the blinking cursor in the recording screen and prompt editor uses a 1s `steps(2)` opacity blink. Use a `withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true))` opacity tween.
- **Donation card animation** on dismiss: slide up + fade (200ms, ease-out). Cumulative dictation tracking should already exist server-side — the new state to track is just the user's `donationCardState`.

## What to ask the user before building

- Where is cumulative dictation duration currently stored? (UserDefaults? Core Data?)
- Where is "first dictation date" stored?
- Confirm the 5× typing-time multiplier for the "saved over typing" calculation.
- Confirm the donations URL: `https://jot.ideaflow.page/donations`.
