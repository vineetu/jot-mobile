# Handoff: "Swipe back to your app" coaching cue (Jot · iOS / SwiftUI)

## Overview
When Jot is launched **from the iOS keyboard extension** just to grab the microphone, iOS forces the main app into the foreground. The user is now staring at Jot's recording surface when they'd rather be back in the app they were typing in. iOS can't return them automatically — they must perform the **"swipe right along the home indicator to switch to the previous app"** gesture themselves.

This design adds a **silent, looping animation at the bottom of the recording surface** that *demonstrates that exact gesture*, so the user copies it without having to read anything. The reassurance copy ("Keep talking — Jot's still listening") already lives at the top of the screen, so the cue at the bottom carries **no text of its own** — the motion is the entire message.

The animation reproduces the real iOS app-switch: the current app (Jot) sits alone as a card, and the moment the swipe begins it slides off to the right while the **previous app's card follows in from the left**, both tracking the finger.

## About the Design Files
The files in `prototype/` are **design references authored in HTML/CSS/React** — a prototype communicating the intended look, timing, and behavior. They are **not** production code to drop in.

**The target app is a native iOS app written in Swift / SwiftUI.** The task is to **recreate this cue natively in SwiftUI** using the app's existing recording-surface view, design tokens, and animation conventions — not to embed a WebView. Everything below (geometry, colors, timing curves) is specified so it can be translated directly into SwiftUI (`Canvas`/`ZStack` + `withAnimation` / `Animation.timingCurve` / `.repeatForever`, or a `TimelineView` for the loop).

## Fidelity
**High-fidelity.** Colors, spacing, typography, card geometry, and the full animation timeline are final. Recreate pixel-for-pixel within the existing recording screen, substituting the app's real design tokens where they already exist (see **Design Tokens** for the mapping).

---

## Where this lives
This is the **cold-start recording surface** — the view shown after a keyboard-triggered mic launch (spec §2.9). The cue is **pinned to the bottom of that screen**, below the transport controls. It must:
- Show **every time** the app is foregrounded by the keyboard mic launch (not a one-time onboarding — per the user it repeats each cold start).
- Sit **below** the trash / pause / Stop control row.
- Show **only the gesture animation** — no caption, no recording dot.

Note on sequencing: the **live transcript does not appear immediately**. For roughly the first ~10 seconds the middle of the screen is intentionally empty and only the swipe cue plays. Once that window passes (or the user returns/stops), the transcript UI takes over. The cue is for that opening empty window only.

---

## Screen layout (recording surface, top → bottom)
Authored at iPhone logical size **393 × 852 pt** (iPhone 16 / 15 class). All values below are in points.

| Region | Spec |
|---|---|
| **Status bar** | Standard, height 54. Dynamic Island pill 118×34 centered, top 11. |
| **Back chevron** | 42×42 circle, top-left. Fill `chrome-fill`, 0.5pt border `chrome-bord`. Chevron stroke 2.6, `ink`. Outer padding 60 top / 18 sides. |
| **Reassurance copy** | Padding 22 top / 8 sides. `h1`: Fraunces **italic** 500, 30pt, line-height 1.2, letter-spacing −0.4, color `ink`. Body `p`: SF 15.5pt, line-height 1.5, color `ink-sub`, max-width 300, margin-top 13. Copy: **"Keep talking — Jot's still listening."** / **"You don't have to stay here. Head back to your app; we'll tidy up the text once you stop."** |
| **Flexible spacer** | `flex:1` — keeps the middle empty during the cold-start window. |
| **Transport controls** | Centered row, gap 14, padding 20 top / 4 bottom. Trash (56×56 circle, icon color `red`) · Pause (56×56 circle) · **Stop pill** (flex, max-width 190, height 56, radius 28, blue gradient, white, 700/19pt, with a 16×16 white rounded square + tabular timer `0:08`). Circle buttons: fill `chrome-fill`, 0.5pt `chrome-bord`. |
| **Swipe cue** | Height **150**, full width, `flex:none`. Detailed below. |

---

## The swipe cue (the core deliverable)

### Structure
- A **stage** clipped region: inset `6` top, `0` sides, `30` bottom; `overflow:hidden`.
- A **home-indicator bar** centered at the bottom: 138×5, radius 3, color `rail`, bottom 14.
- Two **app cards**, both 122×104, radius 20, padding 11×12, shadow `0 18px 40px −16px rgba(0,0,0,.5)`. They are absolutely centered (`left:50%`, translateX `-50%` base) and animate by translating in X.
  - **Jot card** ("current app"): branded soft fill.
    - Light: `radial-gradient(120% 80% at 50% −10%, color-mix(blueflat 26%, transparent), transparent 60%)` over `linear-gradient(180deg, color-mix(blueflat 12%, #F4F7FC), #EEF2F9)`; 0.5pt border `card-bord`.
    - Dark: `radial-gradient(120% 80% at 50% −10%, rgba(46,116,196,.55), transparent 60%)` over `linear-gradient(180deg, #1b2c4f, #13203a)`.
    - Innards: top bar with an 18×18 rounded-6 **"j" icon** (blue gradient fill, white Fraunces italic 600 12pt) + a name bar; a header bar (80% width, 13 tall) and two row bars. Use muted `ink-sub` tints.
  - **Previous-app card**: neutral light chrome to read as "some other app." Fill `#F4F6FA`, 0.5pt border `rgba(20,40,80,.10)`. Innards: grey 18×18 icon (`linear-gradient(180deg,#8E97A6,#6E7686)`) + name bar + three row bars (`rgba(20,40,80,.13)`, last row 62% width). This card stays the same in light & dark (a foreign app wouldn't adopt Jot's theme).
- A **finger contact**: 40×40 circle, radial blue fill (`color-mix(blueflat 86%, white)` → `blueflat` → `blue3`), soft glow shadow + inner highlight. A ripple ring (`::after`, inset −9, 2pt border `color-mix(blueflat 55%, transparent)`) pulses on press.

### Card travel distance
`cardWidth (122) + gap (16) = 138 pt`. The two cards are always exactly 138pt apart, so they move as a locked pair.

### Animation timeline
One loop = **3.4s ÷ speed**. Default **speed = 0.8×** ⇒ effective duration ≈ **4.25s**. Shared easing `cubic-bezier(0.45, 0.02, 0.2, 1)`, looping forever. Percentages below are of the loop.

**Beat 1 — Jot alone (0 → 18%)**
- Jot card: fades in (6%) at center, full scale; at 18% it presses down to `scale .93`, **still centered**.
- Previous card: **hidden**, parked at `−138` offset, opacity 0.
- Finger: lands on the home bar at x `−66` (6%), presses to `scale 1.05`, y `−2` (18%). Ripple pulses 6→30%.
- *This is the "only one card" beat the design hinges on — nothing else is visible yet.*

**Beat 2 — the swipe (18% → 56%)**
- Finger drags right: x `−66 → +72`.
- Jot card slides right: translateX `0 → +138` (stays `scale .93`).
- Previous card follows in from the left: translateX `−138 → 0`, and **fades in starting at 25%** (so it only appears *as the drag begins*, never before). Lands centered at 56%, `scale .93`.

**Beat 3 — settle & reset (56% → 100%)**
- Jot card continues to `+180`, `scale .9`, fades out by 66% (exits right).
- Previous card settles: `scale .93 → .96` (70%), then fades out by 82% to reset the loop cleanly.
- Finger releases at 66% (shrinks to `.62`, fades out).
- Loop restarts at Jot-alone.

### Reduced motion
Honor `prefers-reduced-motion` / `UIAccessibility.isReduceMotionEnabled`: **no animation**. Show a static end-state instead — Jot card offset slightly right, previous card offset slightly left (both at `scale .93`, ~70pt apart), finger centered, ripple hidden. This still communicates "two apps, swipe between them" without movement.

---

## Design Tokens
Map these to the app's existing token system where equivalents exist; the hex values are the source of truth for this cue.

**Brand blue**
- `blue1 #2E9BFF`, `blue2 #0E7AE6`, `blue3 #0064CC`, `blueflat #1A8CFF`
- `blue-grad` = `linear-gradient(180deg, #2E9BFF 0%, #0E7AE6 54%, #0064CC 100%)`
- `glow` = `rgba(26,140,255,0.44)` · `blue-soft` = `rgba(26,140,255,0.20)`
- `red #FF5B4D` (trash icon)

**Dark theme (default app appearance)**
- `ink #FFFFFF` · `ink-sub rgba(233,238,247,0.66)` · `ink-cap rgba(233,238,247,0.42)`
- `chrome-fill rgba(255,255,255,0.08)` · `chrome-bord rgba(255,255,255,0.16)`
- `card rgba(255,255,255,0.06)` · `card-bord rgba(255,255,255,0.11)` · `rail rgba(233,238,247,0.30)`
- Screen bg: layered radial highlights over `linear-gradient(177deg, #1b2c4f, #15233c, #0e1827, #0a1019)` (see `coaching.css` `.screen.dark`).

**Light theme**
- `ink #10151F` · `ink-sub rgba(22,32,52,0.62)` · `ink-cap rgba(22,32,52,0.40)`
- `chrome-fill rgba(255,255,255,0.72)` · `chrome-bord rgba(20,40,80,0.12)`
- `card rgba(255,255,255,0.66)` · `card-bord rgba(20,40,80,0.10)` · `rail rgba(22,32,52,0.26)`
- Screen bg: radial highlights over `linear-gradient(177deg, #EEF2F9, #E2E8F1, #D4DAE4)` (see `.screen.light`).

**Typography**
- Display/serif: **Fraunces**, italic, weight 500 (titles) / 600 (the card "j" glyph). iOS: register Fraunces or substitute the app's existing serif display face.
- Body/UI: **SF Pro Text / SF Pro Display** (system).

**Geometry**
- Card 122×104, radius 20, gap 16 (⇒ 138 travel). Finger 40 dia. Home bar 138×5 radius 3. Stage height 150.
- Control circles 56 dia / radius 28. Back chevron 42 dia.

**Motion**
- Loop 3.4s ÷ speed (default 0.8× ⇒ 4.25s), easing `cubic-bezier(0.45, 0.02, 0.2, 1)`, repeat forever. Key fade-in moment for the previous card: **25%** of the loop.

---

## Interactions & Behavior
- The cue is **non-interactive decoration** — it does not capture touches. The real iOS swipe is performed by the user on the actual home indicator; this is purely a demonstration.
- The transport controls (trash / pause / Stop) are the live recording controls and keep their real behavior; the Stop pill shows the running timer (`mm:ss`, tabular figures).
- Recording continues uninterrupted while this screen is shown and after the user swipes away — the cue exists precisely to tell them that's safe.

## State
- `theme: .dark | .light` — follows the app's appearance setting.
- `gestureSpeed` — playback multiplier; **0.8 default**. (Exposed only as a design tweak; ship the default unless product wants it tunable.)
- Optional: a flag for whether the cold-start empty window is still active (drives showing the cue vs. the transcript).

## Assets
- No raster assets. All shapes/icons are vector (SF Symbols equivalents: `chevron.left`, `pause.fill`, `trash`, `stop.fill`, plus the status-bar glyphs). The card contents are abstract placeholder bars, not real screenshots.
- **Fraunces** font file required if not already bundled.

## Files (in `prototype/`)
- `Swipe Back Coaching.html` — entry point; mounts the recording surface, handles theme + the 393×852 scaling, exposes the speed/theme tweaks.
- `coaching.css` — tokens (light & dark), status bar, recording surface, transport controls.
- `gestures.css` — **the cue**: card geometry, finger, home bar, and the full `@keyframes` timeline (`jotCard`, `prevCard`, `touchB`, `rippleB`) + reduced-motion fallback. This is the file to read first when porting the animation.
- `recording-surface.jsx` — React markup for the surface + `SwipeCue` component (card/finger structure).
- `tweaks-panel.jsx` — prototype-only tweak controls; **not** part of the shipped design.

### How to preview
Open `Swipe Back Coaching.html` in a browser. Toggle the Tweaks panel for theme (dark/light) and gesture speed.
