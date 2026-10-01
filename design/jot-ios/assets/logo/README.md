# jot — Logo Assets

The **j + waveform** mark for the Jot voice-dictation app. Lowercase stroked *j* with a
confident heavy stem; the tittle (the dot) is a live, asymmetric 3-bar voice waveform kept
light, set a clear gap above the stem. Brand blue. Built to match the app's icon-tile language.

## Files

| File | Use |
|---|---|
| `jot-icon-1024.png` | **iOS app icon**, 1024×1024 — blue gradient tile + white mark, transparent corners (iOS applies its own mask) |
| `jot-icon-1024.svg` | Vector source of the app icon (re-export at any size) |
| `jot-mark-gradient.svg` | The **j+waveform** mark, blue gradient — on light/neutral surfaces |
| `jot-mark-white.svg` | White mark — on the blue brand color or dark surfaces |
| `jot-mark-mono.svg` | Single-color blue (`#1A8CFF`) — flat contexts |
| `jot-wordmark-gradient.svg` | `jot` wordmark, blue gradient |
| `jot-wordmark-white.svg` | `jot` wordmark, white |

All marks are stroke-based with **round caps/joins** — keep `stroke-linecap="round"`.
The stem is **stroke-18** (heavy); the waveform tittle is three **thin** rounded bars at
**stroke-5.4**, centred on the stem and set a clear gap above its cap. The bars are a
**live, asymmetric** waveform — heights **9 · 18 · 13** (left · centre · right) — so it reads as
captured voice, not a stock equalizer. Keep the bars light against the heavy stem (that
contrast is the point) and never let them fuse; they must read as separate bars.

## Colors

```
--jot-blue-light:  #2E9BFF   /* gradient top    */
--jot-blue-mid:    #0E7AE6   /* gradient middle */
--jot-blue:        #0064CC   /* gradient bottom / primary */
--jot-blue-flat:   #1A8CFF   /* mono / single-color */
```

App-icon tile gradient runs `#3AA0FF → #1483F2 → #0064CC` (168°), with a soft white top
sheen and a subtle inner top highlight — matching the coral-sparkle / orange-mic tiles in-app.

## iOS notes

- `jot-icon-1024.png` is ready for the asset catalog (Xcode single-size). It already has
  transparent corners; iOS rounds it to the platform squircle.
- For an iOS 26 "Liquid Glass" icon, drop `jot-icon-1024.png` (or the SVG layers) into Apple's
  **Icon Composer** and let the system add the glass material.
- Mark viewBox: `22 6 72 148`. Wordmark viewBox: `0 0 200 160`.

---

## Paste this to Claude Code

> The jot logo lives in `assets/logo/`.
> - App icon: use `jot-icon-1024.png` in the asset catalog.
> - In-app, use `jot-mark-white.svg` on the blue brand color / dark surfaces and
>   `jot-mark-gradient.svg` on light surfaces. Use `jot-wordmark-*` in the onboarding header / About.
> - Brand blue gradient `#2E9BFF → #0E7AE6 → #0064CC`; flat blue `#1A8CFF`.
> - Keep strokes round-capped; keep the 3 waveform bars visually separate (never fused).
