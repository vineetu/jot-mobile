# Jot Atlas — visual feature map

An interactive, version-controlled mockup of the **whole app** (iOS app, keyboard, watch, system
surfaces). Browse every screen, **pinpoint** any spot, leave a comment, and **export a JSON change
request** to hand to Claude — so "change this here" is exact, not described.

It is the visual companion to `Jot/features.md` (the WHAT) and `Jot/ARCHITECTURE.md` (the WHERE).
The screenshots are the pixel-perfect truth; the manifest (`atlas.json`) is the join table that ties
each screen back to its `features.md` § and its real `JotDesign` dimensions.

## Run it

Browsers block `fetch()` over `file://`, so serve it:

```bash
cd atlas
python3 -m http.server 8000
# open http://localhost:8000
```

(Or drop the `atlas/` folder on any static host.)

## Workflow

1. **Browse** by surface in the left sidebar, or **By Feature §**, or **Capture Progress**.
2. Open a screen → tick **Pinpoint mode** → click the spot you want to change → a numbered pin drops.
3. Type your comment in the right panel ("make this text smaller", "this card should be blue").
4. Pins persist in your browser (`localStorage`) — they're there when you come back.
5. **Export request** → downloads `jot-atlas-request-<ts>.json`. Send me that file. I open each
   referenced screenshot and locate your pins by their `xPct`/`yPct`, so I see exactly what you mean.

## Adding screenshots

Each screen has a slot in `atlas.json` with an `image` path and `"captured": false`. To fill it:

1. Save the screenshot at the path shown (e.g. `atlas/screens/ios/home-library.png`).
   Filenames are pre-assigned in `atlas.json` — match them.
2. Flip that screen's `"captured"` to `true`.

Folders:
- `screens/ios/` — main iPhone app
- `screens/keyboard/` — Jot keyboard states
- `screens/watch/` — Apple Watch
- `screens/system/` — Shortcuts / Action Button / iOS Settings surfaces

Set `device` in `atlas.json` to the iPhone you screenshot on (so px↔pt math is right).

## The update rule (keep it from rotting)

> When a feature changes a screen's look, re-shoot **just that screen** and drop the new PNG in.
> When a feature is added/removed, add/remove its screen entry in `atlas.json`.

Re-shooting one screen is seconds — that's why this stays current where a hand-coded mockup wouldn't.
Dimensions are **not** copied here; they live in `JotDesign` (Swift) and are surfaced per-screen from
there, so they can't drift.

## What's where

- `index.html` — the engine (single file, vanilla JS, no build step).
- `atlas.json` — the manifest: surfaces → screens → `{ sections[], image, captured, behavior, dimensions[] }`.
- `screens/**` — the screenshots.
