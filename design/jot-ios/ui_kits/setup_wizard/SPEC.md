# Handoff: Jot — Setup Wizard + Brand Mark

## Overview
The first-run onboarding wizard for **Jot**, a privacy-first voice-dictation app for iPhone
(with a companion Apple Watch app). The wizard walks a new user from welcome → microphone
permission → adding the Jot keyboard with Full Access → explaining the capture flow → a
hands-on "try it" → the optional "keep mic ready" setting → a finished state, then drops into
the app. It also includes the finalized **jot logo / app icon** (j + waveform mark).

The design ships in **light and dark mode** (dark is primary).

## About the Design Files
The files in this bundle are **design references created in HTML/React (via in-browser Babel)** —
a working prototype showing the intended look, copy, and behavior. They are **not production code
to copy directly.** The target app is **native iOS (SwiftUI/UIKit)**; the task is to **recreate
these screens in the iOS codebase** using its established patterns, navigation, and components.
Everything here (measurements, colors, copy, interaction notes) is the source of truth for *what*
to build; *how* to build it should follow the iOS project's conventions.

Open `Jot Wizard (standalone).html` in any browser to interact with the prototype offline. Use the
**Tweaks** panel (toolbar) to toggle light/dark, the keyboard step state, and the warm-hold mode.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, copy, and interactions. Recreate
pixel-accurately within iOS conventions. (The HTML simulates an iPhone bezel + status bar for
presentation only — that chrome is NOT part of the feature; build inside the real device.)

---

## Design Tokens

### Color
```
Brand blue (primary, core app)
  blue-light   #2E9BFF   gradient top
  blue-mid     #0E7AE6   gradient middle / solid
  blue         #0064CC   gradient bottom
  blue-flat    #1A8CFF   mono / accent dot / active dot

App-icon tile gradient   168°  #3AA0FF → #1483F2 → #0064CC

Semantic icon tiles (onboarding hero tiles)
  mic (W2)        #F6A93B → #E8841C   (orange)
  keyboard (W3)   #F4EFE3 → #DBD2BE   (parchment; glyph #3A352A dark / #4A4334 light)
  success (W3/W7) #34C759 → #27A848   (green)

Toggle "on"      #34C759 (iOS green)

CTA pill gradient (blue)  180°  #2E9BFF → #0E7AE6 → #0064CC
CTA glow                  rgba(26,140,255,0.44)
```

### Dark theme
```
ink            #FFFFFF
ink-sub        rgba(233,238,247,0.66)
ink-caption    rgba(233,238,247,0.42)
ink-italic     rgba(233,238,247,0.70)
chrome-fill    rgba(255,255,255,0.08)   chrome-border rgba(255,255,255,0.16)
card           rgba(255,255,255,0.06)   card-border   rgba(255,255,255,0.11)
dot-done       rgba(255,255,255,0.50)   dot-todo      rgba(255,255,255,0.20)
background gradient (radial blue glow top + faint warm bottom + navy vertical):
  radial-gradient(128% 72% at 50% -8%, rgba(64,116,196,0.50), rgba(40,74,128,0.16) 36%, transparent 60%),
  radial-gradient(120% 84% at 88% 112%, rgba(120,72,56,0.20), transparent 52%),
  linear-gradient(177deg, #1b2c4f, #15233c 32%, #0e1827 72%, #0a1019)
```

### Light theme
```
ink            #16181D
ink-sub        rgba(54,62,78,0.70)
ink-caption    rgba(54,62,78,0.48)
chrome-fill    rgba(255,255,255,0.72)   chrome-border rgba(20,30,50,0.08)
card           rgba(255,255,255,0.78)   card-border   rgba(20,30,50,0.07)
background gradient:
  radial-gradient(128% 74% at 50% -8%, rgba(150,184,232,0.62), rgba(150,184,232,0.12) 40%, transparent 62%),
  radial-gradient(120% 84% at 88% 112%, rgba(222,170,150,0.24), transparent 52%),
  linear-gradient(177deg, #E9EEF7, #DEE4EE 44%, #D0D6E0)
```

### Typography
```
Editorial (titles, welcome subtitle):  Fraunces, italic
  W1 title "Welcome to Jot."   ~41px / weight 500 / italic / tracking -0.5px / line-height 1.0
  Other titles (Title cmp)     30–42px / weight 500–600 / italic
  Welcome subtitle             20px / italic / weight 400 / line-height 1.34
Chrome / body / UI:  SF Pro (-apple-system)
  Body copy        18.5px / 400 / line-height ~1.42
  Footnote         12.5px / 400 / line-height 1.42 / ink-caption
  CTA label        19px / 600
  Row title        16–17px / 600
```

### Spacing / radii
```
Screen horizontal padding   24px
Hero icon tile              104–132px square, radius = 0.245–0.30 × size
App-icon tile               radius 0.245 × size; top sheen overlay; ambient shadow
Card / step group           radius 18px
CTA pill                    height 64px, radius 33px (fully rounded)
Chrome buttons              46px circle (back / close), glassy fill + 0.5px border
Progress dots               7px (active 8px), gap 9px; active = blue #1A8CFF
Toggle (iOS switch)         52×31px, knob 27px
```

---

## Brand Mark / App Icon  (in `jot-logo/`)
Lowercase stroked **j**; the tittle (dot) is a **3-bar voice waveform**. Brand blue.

- **App icon**: `jot-icon-1024.png` (1024², transparent corners — iOS applies its squircle mask).
  Tile = 168° blue gradient `#3AA0FF→#1483F2→#0064CC` + white top sheen + subtle inner top
  highlight; white mark centered. For an iOS 26 *Liquid Glass* icon, run the PNG/SVG through
  Apple's **Icon Composer**.
- **Mark** geometry (viewBox `22 6 72 148`): stem path `M58 52 L58 116 Q58 138 34 138`,
  stroke-width 15, round caps. Waveform tittle: 3 vertical bars at x = 47 / 58 / 69, centered
  at y 24, heights 10 / 18 / 10, bar weight 5.4, round caps. **The 3 bars must stay visually
  separate — never fuse them.**
- Variants: `jot-mark-{gradient,white,mono}.svg`, `jot-wordmark-{gradient,white}.svg`.
- See `jot-logo/README.md` for the per-file usage table.

---

## Screens / Views

The wizard is a horizontal step flow. Header chrome on every step: **[back ‹] · [7 progress dots] · [close ✕]**
(back hidden on W1; close always finishes onboarding). Each step: hero tile → title → body → bottom CTA.

Step order (default, warm-hold in-wizard): **W1 → W2 → W3 → W4 → W5 → W6 → W7** (7 dots).
If warm-hold is set to *contextual*, W6 is removed (6 steps) and the "keep mic ready" prompt
appears in-app after the first dictation instead.

### W1 · Welcome
- **Purpose**: set the tone, start onboarding.
- **Hero**: the jot **app icon** tile (blue, j+waveform), 126px.
- **Title** (Fraunces italic): "Welcome to Jot."
- **Subtitle** (Fraunces italic): "Voice transcription for fast messaging — dictate into any app."
- **CTA**: `Get started` → W2.

### W2 · Microphone permission
- **Hero**: orange mic tile (`#F6A93B→#E8841C`), 128px, white mic glyph.
- **Title**: "Let Jot hear you"
- **Body**: "Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded."
- **CTA**: `Grant microphone` → triggers iOS mic permission, then W3.

### W3 · Add the keyboard  (two states)
- **First-run** (no Jot keyboard yet):
  - Hero: parchment keyboard tile, 104px.
  - Title: "Add the Jot keyboard"
  - Body: "Two quick toggles in Settings let Jot paste your dictation into any app."
  - A 2-step checklist card: ① "Add 'Jot' under Keyboards" ② "Turn on Allow Full Access".
  - CTA: `Open Settings` → opens a simulated iOS **Settings sheet** (slides up): tap **Add**
    next to Jot → an "Allow Full Access" toggle appears → toggle on → **Done** enables.
    Secondary text link: `I've already added it`.
  - On completion the screen flips to the **ready** state.
  - *Native note*: real iOS opens the actual Settings app (App Settings → Keyboards). The
    in-prototype sheet stands in for that; you may deep-link and then detect on return.
- **Ready / returning** (keyboard already added — also what a returning user sees):
  - Hero: green success tile, 120px, check glyph.
  - Title: "Keyboard ready" · Body: "The Jot keyboard is added with Full Access — your dictations can paste into any app."
  - CTA: `Continue` → W4.

### W4 · How it works
- Animated illustration of the capture loop: an Apple keyboard at the bottom, the Jot dictate
  pill, then the app bounces in and a **swipe arrow runs along the bottom home-indicator edge**
  (the iOS "back to your app" gesture). A home-indicator bar is shown at the bottom.
- **Title**: "How it works"
- **Body**: explains: tap the Jot key → dictate → Jot pops up to capture → swipe back to your app.
- **Transparent footnote** (ink-caption, important — keep the honest tone):
  "We'd skip this step if we could. Apple doesn't let keyboards use the mic directly — so Jot
  hops back to capture. If that ever changes, this goes away."
- **CTA**: `Got it` → W5.

### W5 · Try the keyboard  (interactive)
- A sample text field with the prompt to try dictating. CTA `Try it` raises a simulated iOS
  keyboard with a Jot **dictate pill**. Tapping it starts a **streaming dictation animation**
  (words appear one-by-one, italic, with a recording state); stopping commits a final sample
  string into the field. Controls include pause and trash.
  - Sample streamed text (`FINAL_TEXT`): "Running late — traffic on the bridge is backed up past
    the tunnel. I'll be there in about ten minutes."
- Once the user has tried it, CTA becomes `I tried it` → W6 (or W7 if contextual).
- *Native note*: this is a teaching simulation. In the app the actual system keyboard + Jot
  keyboard extension handle this.

### W6 · Keep the mic ready  (default ON; omitted in contextual mode)
- **Hero**: orange mic tile, 116px.
- **Title**: "Keep the mic ready"
- **Body**: "After you dictate, Jot stays ready for two minutes — so your next dictation starts
  instantly, without hopping back to the app. Nothing is recorded until you tap Dictate."
- **Toggle row** (card): label "Keep mic ready", iOS green switch, **default ON**.
- **CTA**: `Continue` → W7.
- **Mechanic to implement**: after a dictation session ends, hold the mic session alive for
  **~2 minutes** so a follow-up dictation skips the app round-trip; release automatically after.
  This is NOT always-on background listening. Setting also lives in app Settings (opt-out).

### W7 · You're ready  (+ Apple Watch "one more thing")
- **Hero**: green success tile, 112px, check glyph.
- **Title**: "You're ready." · **Body**: "Jot works now — start dictating in any app, any time."
- **Watch card** (one card below): small watch glyph (blue) + "It's on your wrist, too" +
  "Caught an idea without your phone? Tap the Jot complication and speak — it syncs back automatically."
- **CTA**: `Start dictating` → finishes, enters the app.

---

## Interactions & Behavior
- **Navigation**: linear next/back; `close` (✕) and finishing the last step both call `finish()`
  → transitions from `wizard` view to the `app` view.
- **Progress dots**: reflect current index out of `total`; active dot is blue and slightly larger.
- **W3 sheet**: bottom sheet slide-up (transform translateY, ~0.42s cubic-bezier(.32,.72,0,1));
  "Done" disabled until both *Added* and *Full Access* are true.
- **W4**: looping illustrative animation; the swipe arrow + home bar communicate the OS gesture.
  Gate entrance animations on reduced-motion and show end-state for static/PDF.
- **W5**: streaming text uses ~120–135ms per word; recording/paused/trash states; floating CTA
  sits above the measured keyboard height.
- **Warm-hold contextual prompt**: if warm-hold mode = contextual, after finishing, a prompt
  appears in-app ~950ms after the first dictation, offering to keep the mic ready.
- **Light/dark**: all tokens swap via theme; honor the OS appearance setting.

## State Management
State variables in the prototype (`wizard-app.jsx`) — map to native equivalents:
- `view` (`wizard` | `app`), `step` (index), `total` (derived from warm-hold mode)
- `warmOn` (bool, default true) — the keep-mic-ready setting
- `kbAdded` / `kbSheet` — keyboard-added + settings-sheet open
- W5: `kbUp, kbMode, rec, paused, stream, field, tried`
- `promptOn` — contextual warm-hold prompt visibility
- Config (Tweaks, become product decisions, not user settings):
  `appearance` (dark/light), `brandMark` (jot/sparkle — ship **jot**),
  `kbDetected` (firstrun/returning), `warmHold` (inwizard/contextual — ship **inwizard**)

## Assets
- `jot-logo/` — finalized app icon (1024 PNG + SVG), mark (gradient/white/mono SVG), wordmark
  (gradient/white SVG), and a README usage table. All original to this project.
- Fonts: **Fraunces** (editorial, italic) and **SF Pro** (system). Fraunces is loaded from Google
  Fonts in the prototype; use the licensed/system equivalents in-app.
- No third-party imagery; all glyphs are inline SVG (mic, keyboard, check, watch, sparkle).

## Files
| File | What it is |
|---|---|
| `Jot Wizard.html` | Prototype entry (loads the JSX modules + tweaks panel) |
| `Jot Wizard (standalone).html` | Self-contained offline build — open this to interact |
| `wizard-app.jsx` | App shell: state machine, step router, scaling, faux-app, Tweaks defaults |
| `wizard-ui.jsx` | Tokens (`jotTheme`), brand mark (`JotWaveMark`), `AppIcon`, glyphs, `HeroTile`, chrome, `Title/Body/Cta`, progress dots |
| `wizard-panels.jsx` | Panels W1, W2, W3, W4, W5, W7 |
| `wizard-extras.jsx` | W6 warm-hold, the contextual prompt, the simulated iOS Settings sheet |
| `wizard-keyboard.jsx` | Simulated iOS / Jot keyboard for W5 |
| `tweaks-panel.jsx` | Prototype-only tweak controls (not part of the product) |
| `jot-logo/` | Logo + app-icon asset pack (+ its own README) |

> Note: the iPhone bezel, status bar, and home indicator in the prototype are presentation
> scaffolding — not part of the feature. Build the screens inside the real device UI.
