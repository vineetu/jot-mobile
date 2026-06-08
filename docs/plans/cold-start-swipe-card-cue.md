# Cold-Start "Swipe Back" Card Cue — Discovery & Plan

**Status:** ✅ **BUILT** (2026-06-06). Implemented in `RecordingHeroView.swift`.
Awaiting on-device verification before ship.

**What shipped (vs. this plan):**
- New `SwipeBackCardCue` view (in `RecordingHeroView.swift`) — pixel-port of
  `design_handoff_swipe_back_cue/prototype/gestures.css`: two cards (Jot + grey
  "other app") 122×104 r20, 138pt apart; finger + ripple on a 138×5 home bar;
  the 3-beat loop driven by a `TimelineView(.animation)` clock sampling the
  keyframe tracks with the shared `cubic-bezier(0.45,0.02,0.2,1)` easing per
  segment; `repeatForever` (continuous, not play-once); Reduce-Motion static
  end-frame; light/dark; Fraunces "j" via `JotType.frauncesItalic` (already
  bundled — no font work).
- **Replaced** `ColdStartNudgeOverlay` (the dot-on-pill) entirely — deleted.
- **Gating ripped out** (the "unnecessary invisible logic"): no `count < 50`
  cap, no `jot.hero.coldStartNudgeShownCount`, no 6s auto-dismiss, no
  `showColdStartNudge` flag, no `maybeShowColdStartNudge()`. Visibility is now a
  pure derivation: `showsSwipeCue = isColdStartPath && !streamRevealed`.
- **Not dismissible:** `allowsHitTesting(false)` — pure decoration; it loops
  until the transcript reveals. No tap-to-dismiss.
- **Position:** pinned low, ~22pt clearance off the bottom (owner's "¼ inch
  above the bottom"), where the real gesture happens.
- **Controls travel:** `controlsBottomInset` (196 cold-start → 36 normal) lifts
  the transport row to lower-center during the cue window and drops it back on
  reveal. Both the drop and the cue fade-out ride `revealStream()`'s single 0.7s
  curve (everything derives from `streamRevealed`), so the return-to-normal is
  smooth, not a snap.
- Rotating top messages: untouched, and no longer suppressed while the cue shows
  (they coexist — text up top, cue down low).

**Open questions — resolved:** center height = lower-center (controls lifted
196pt, sitting in the empty space above the cue band); transition = single
animated layout value on `streamRevealed` (no matchedGeometry needed);
tap-to-dismiss = removed (loops until reveal); Fraunces = already bundled.

_Original discovery + design notes below, preserved for reference._

---

## 1. What we're building (one line)

Replace the current cold-start "swipe back to your app" coaching hint with a
**full, pixel-perfect, looping two-card iOS app-switch animation**, shown in the
cold-start opening window of the recording hero, laid out so it never collides
with the transport controls.

## 2. Where this lives

- **Design source (the spec):** `Jot/design_handoff_swipe_back_cue/`
  - `README.md` — the full high-fidelity spec (geometry, tokens, the 3-beat
    animation timeline, reduced-motion fallback). **Source of truth.**
  - `prototype/gestures.css` — the actual `@keyframes` timeline
    (`jotCard`, `prevCard`, `touchB`, `rippleB`). **Read this first when porting
    the animation.**
  - `prototype/recording-surface.jsx` — card/finger DOM structure.
  - `prototype/coaching.css` — color tokens (light + dark), surface.
  - `Swipe Back Coaching.html` — open in a browser to preview.
  - `prototype/tweaks-panel.jsx` — prototype-only; **NOT** part of the ship.
- **Target screen:** `Jot/App/Recording/RecordingHeroView.swift` — the
  **cold-start recording surface** (hero shown when the keyboard launches Jot
  just to grab the mic; `intent == .coldStartFromExternalKeyboard`, spec §2.9).

## 3. Why (owner context)

The coaching hint already exists and was a good idea, **but** when shown to a few
non-technical people they were confused about what the dot-sliding-on-a-bar even
was. The two-card animation reproduces the *real* iOS app-switch (your app slides
off right, the previous app slides in from the left), so users copy the gesture
without reading anything. That's the whole reason for the swap.

---

## 4. Current state (verified in code, 2026-06-06)

### What exists and STAYS (do not touch)
- **Rotating top messages** — `RecordingHeroView.heroTopMessages` (line ~197),
  three lines, rendered via `RotatingMessageView` in `heroContentArea`. These are
  the italic-serif lines at the top of the screenshots:
  1. "Recording stays on while you go. Your words land back in that field."
  2. "You don't have to watch this — looking away helps you find the words."
  3. "The thinking happens out loud, not on the screen."
  Owner likes these. **Keep as-is, top of screen.**

### What exists and gets REPLACED
- **`ColdStartNudgeOverlay`** (`RecordingHeroView.swift:1104`) — the current
  coaching widget = a glass card with a headline ("Head back to your app") + a
  **ghost dot sliding left→right along a thin mini home-indicator bar** (the
  "dot on a pill"), alternating with a "tap ‹ Back" pill hint. **This is the
  confusing thing. The two-card cue replaces its content.**

### What does NOT exist yet
- **No two-card animation anywhere in the code.** Grep for
  `AppCard`/`MiniPhone`/`prevCard`/`jotCard`/`appSwitch` = zero hits. The card in
  the owner's screenshot #4 is a **mock** of the desired result (showing the
  clash with the buttons), not running code.

### Current body layout (`RecordingHeroView.body`, line ~206)
```
ZStack {
  WallpaperBackground
  VStack(spacing: 0) {
    topBar
    heroContentArea  (maxHeight: .infinity)   // rotating messages OR live stream
    Spacer(minLength: 24)
    bottomControls   (.padding(.bottom, 36))   // Pause · Stop · Trash — pinned BOTTOM
  }
  if showColdStartNudge {                       // current overlay is ABOVE controls
    ColdStartNudgeOverlay(...)
      .padding(.bottom, 130)                    // floats just above the control row
      .frame(maxHeight: .infinity, alignment: .bottom)
      .zIndex(1)
  }
}
```

### Why the nudge isn't showing in the app right now (the gating bug)
`maybeShowColdStartNudge()` (line ~802):
1. Requires `intent == .coldStartFromExternalKeyboard`.
2. **`guard count < 50`** on UserDefaults `jot.hero.coldStartNudgeShownCount` —
   shown at most 50× per app lifetime, then self-suppresses. Owner has exceeded
   50 from testing → **that's why it's invisible.**
3. Even when shown, **`Task.sleep(6)` auto-dismisses it after 6s.**
- Dismissal also happens correctly on stream reveal: `configureStreamReveal()`
  (line ~756) sets `showColdStartNudge = false` at line ~791 when `streamRevealed`.
- Relevant state: `showColdStartNudge` (180), `streamRevealed` (~153),
  `coachingBeatElapsed` (160), `isColdStartPath` (185).

---

## 5. Target design (handoff + owner clarifications)

### The animation (full spec in `design_handoff_swipe_back_cue/README.md`)
- Two app **cards**, 122×104, radius 20, exactly **138pt apart**, move as a locked
  pair by translating in X.
  - **Jot card:** branded soft gradient fill + a small Fraunces-italic **"j"**
    glyph + abstract placeholder bars.
  - **Previous-app card:** neutral grey chrome ("some other app"); same in light
    & dark.
- A **finger contact** (40px circle, blue radial) with a **ripple ring** that
  pulses on press, riding a **home-indicator bar** (138×5).
- **Stage:** ~150pt tall, clipped (`overflow: hidden`).
- **Loop:** 3.4s ÷ 0.8 speed ≈ **4.25s**, easing `cubic-bezier(0.45, 0.02, 0.2, 1)`,
  **repeatForever**. Three beats: (1) Jot card alone, centered, presses down
  (0–18%); (2) finger drags right, Jot slides off right, previous card follows in
  from the left and **fades in at 25%** (18–56%); (3) settle + reset (56–100%).
- **Reduced motion** (`UIAccessibility.isReduceMotionEnabled`): **no animation** —
  show a static end-state (Jot card offset slightly right, previous card slightly
  left, ~70pt apart, finger centered, ripple hidden).
- **Fidelity:** owner confirmed **full pixel-to-pixel**. Port the `gestures.css`
  keyframe timeline to SwiftUI (`TimelineView`/`withAnimation`+`.repeatForever` or
  `Animation.timingCurve`). Map handoff hex tokens to existing design tokens where
  equivalents exist; hex values are the source of truth for this cue.
- **Loop until reveal:** owner — the animation must **keep looping** at the bottom
  until the transcript page is shown. NOT play-once, NOT a 6s timeout.
- **Text-free:** the card cue carries no copy of its own — the motion is the
  message (the reassurance copy already lives at the top).

### The layout (owner-confirmed — "controls travel")
The card cue and the controls must **never overlap**. Solution = they live in
separate horizontal bands, and the **control row moves** depending on the phase:

```
COLD-START WINDOW (no transcript yet)        AFTER TRANSCRIPT REVEALS (normal hero)
┌──────────────────────┐                     ┌──────────────────────┐
│ ‹                    │                     │ ‹                    │
│ rotating text (top)  │                     │ rotating text → fades│
│                      │                     │ ┌──────────────────┐ │
│                      │                     │ │ transcript pane  │ │
│  ▢ Pause Stop Trash  │ ← CONTROLS: CENTER  │ │ (live stream)    │ │
│                      │                     │ └──────────────────┘ │
│   ┌──┐→┌──┐  CARD    │ ← CUE: BOTTOM BAND  │  ▢ Pause Stop Trash  │ ← CONTROLS: BOTTOM
└──────────────────────┘                     └──────────────────────┘
```

- **Cold-start window:** rotating text at top · **controls move to the center** ·
  **card cue in its own band pinned to the bottom** (near the real home indicator,
  where the gesture actually happens — that's why it must be at the bottom, not in
  the empty middle).
- **Transcript appears:** controls **animate back down to the bottom**, card cue is
  removed, transcript pane fills the space → the normal hero we already have.
- So the **control row travels: bottom → center (cold-start) → bottom (on reveal).**
  Card exists only while controls are centered.
- This **flips** the current arrangement: today the overlay floats *above*
  bottom-pinned controls (`.padding(.bottom, 130)`); the new design puts the cue
  *below* the controls by lifting the controls to center.

---

## 6. Work to be done

1. **Build `SwipeBackCardCue` (new SwiftUI view)** — pixel-port the two-card
   animation from `gestures.css`: two cards (Jot + previous), finger + ripple,
   home-indicator bar, 3-beat loop, `repeatForever`, reduced-motion static
   fallback. Light + dark tokens. Bundle/register **Fraunces** for the "j" glyph
   (or substitute the app's existing serif) — verify whether Fraunces is already
   bundled.
2. **Replace `ColdStartNudgeOverlay`'s content** with `SwipeBackCardCue` (remove
   the dot-on-pill swipe demo + its headline/back-pill variants).
3. **Restructure the cold-start bottom layout** so the cue sits in its own bottom
   band and the **controls move to center** during the cold-start window, then
   animate **back to the bottom** on `streamRevealed`. This control-travel
   transition is **new UX we don't have yet** — design it to be **smooth**
   (candidates: a single layout whose control-row offset animates on
   `streamRevealed`, or `matchedGeometryEffect` for the control row between the two
   states; avoid two separate views that pop). Honor reduce-motion.
4. **Fix the gating so the cue ALWAYS shows during the cold-start window:**
   - Remove/neutralize the `count < 50` cap (`jot.hero.coldStartNudgeShownCount`) —
     owner wants it shown every cold start, not capped.
   - Remove the **6s auto-dismiss** (`Task.sleep(6)`). Dismissal must be driven
     **only** by `streamRevealed` (transcript appears), so the cue loops until then.
5. **Leave the rotating top messages untouched.**

---

## 7. Open questions / fine-tunes (decide during build)

- **Exact "center" height** for the control row — true vertical center vs.
  lower-center just above the cue band. (Fine-tune, not a blocker.)
- **Smooth control transition** mechanism — pick `matchedGeometryEffect` vs an
  animated offset/layout. Needs a quick design pass (owner flagged we don't have
  this UX yet).
- **Tap-to-dismiss?** Today the overlay dismisses on tap. With "loop until
  transcript," do we keep an early-dismiss affordance or not? (Lean: no — it just
  loops until the stream reveals.)
- **Fraunces availability** — confirm bundled/registered; else substitute the
  app's serif display face.
- **Reduced-motion** static end-state layout within the new bottom band.
- **Non-cold-start hero unaffected** — the FAB/normal hero has no cue and keeps
  controls at the bottom; only the cold-start path gets the travel behavior.

---

## 8. Constraints / conventions
- Keyboard-extension memory ceiling etc. do **not** apply — this is the main-app
  hero, not the keyboard target.
- After implementation, update `features.md` per `Jot/CLAUDE.md` (cold-start
  recording surface §2.9 area) and add cross-links.
- Reduce-motion + VoiceOver: the current overlay posts an `.announcement` and has
  an accessibility label; preserve an equivalent for the new cue.
