# Simulator screenshot pipeline

Repeatable capture of **real** Jot simulator screenshots — different personas,
different screens, phone + watch — for marketing videos and the website.

Output lands in [`docs/screens/gallery/`](../../docs/screens/gallery/).

## What it produces

```
docs/screens/gallery/
  journalist/   01-recents-home.png  02-detail.png  03-detail.png
  student/      01-recents-home.png  02-detail.png  03-detail.png
  teacher/      01-recents-home.png  02-detail.png  03-detail.png
  lawyer/       01-recents-home.png  02-detail.png  03-detail.png
  _app/         01-settings.png      02-help.png            (persona-independent)
  _watch/       01-watch-home.png    02-watch-recording.png
```

Each persona's home + transcript-detail screens are driven by that persona's
own dictations, so the Recents list, the rewrite "before/after", and the
action-item output all read as real content for that profession.

## Prerequisites

- A **booted iPhone** simulator with the Jot app installed (`./build.sh`, then
  run the `Jot` scheme to a simulator once).
- For watch shots, a **booted Apple Watch** simulator with the `JotWatch` app.
- [`cliclick`](https://formulae.brew.sh/formula/cliclick) (`brew install cliclick`)
  — used to tap iOS system alerts / header buttons the simulator renders.
- Screen Recording + Accessibility permission for your terminal (so AppleScript
  can position the Simulator window and `cliclick` can tap it).

## Run it

```bash
# All four personas (home + detail screens):
./scripts/screenshots/capture.sh all
# One persona:
./scripts/screenshots/capture.sh journalist

# Persona-independent app screens (Settings, Help):
./scripts/screenshots/capture_static.sh

# Apple Watch (home + recording):
./scripts/screenshots/capture_watch.sh
```

## How it works

1. **Seed** — `seed_persona.py` writes a persona's transcripts straight into the
   simulator's Core Data store (`JotTranscripts.store` in the app group), with
   `createdAt` spread across today / yesterday / last-7-days so the Recents list
   groups naturally. The app regenerates the keyboard history mirror itself on
   next launch. No app code change.
2. **Skip onboarding** — sets `jot.setup.completed` so the setup wizard doesn't
   cover the screenshot.
3. **Navigate** — cold-launch lands on Recents home. Transcript detail is opened
   with the `jot://transcript?id=<uuid>` deep link; `simctl openurl` routes
   custom schemes through an "Open in Jot?" system alert, which `cliclick`
   confirms (one calibrated tap — the alert is centered and content-independent).
   Settings / Help are the home header gear / "?" buttons, also tapped.
4. **Capture** — `xcrun simctl io <udid> screenshot`.

## Adding / editing personas

Drop a JSON file in [`personas/`](personas/). Shape:

```jsonc
{
  "persona": "nurse",            // folder name + label
  "display_name": "Nurse",
  "transcripts": [
    {
      "text": "raw dictation as spoken",
      "cleaned": "optional LLM-rewrite output (shows the Rewrite tab)",
      "instruction": "Articulate",   // or "Action Items", "Email" — the rewrite chip
      "source": "keyboard",           // app | keyboard | watch | shortcut | file
      "duration": 12.3,               // seconds, shown as 0:12
      "days_ago": 0, "time": "09:12", // controls Today/Yesterday/Last-7 grouping
      "feature": true,                // capture a detail screenshot of this one
      "label": "Interview note"       // label printed during capture
    }
  ]
}
```

`feature: true` rows get a deep-linked detail screenshot. Rows with `cleaned`
render the Rewrite tab; rows without show the plain transcript.

## Calibration (if taps miss)

Tapping relies on the Simulator window pinned to a fixed position. The scripts
set the iPhone window to `(40,50)` and the watch to `(800,60)`, then use these
screen-point tap targets (calibrated for iPhone 17 Pro / Apple Watch Ultra 3 on
a Retina display):

| target | script | constant |
|---|---|---|
| "Open in Jot?" → Open | `capture.sh` | `OPEN_TAP=277,541` |
| home gear → Settings | `capture_static.sh` | `GEAR_TAP=382,181` |
| home "?" → Help | `capture_static.sh` | `HELP_TAP=324,181` |
| watch "Jot down" | `capture_watch.sh` | `JOTDOWN_TAP=956,246` |
| watch recording "X" | `capture_watch.sh` | `CANCEL_TAP=835,121` |

To recalibrate for a different device/zoom: pin the window, trigger the target,
`screencapture -R<x>,<y>,<w>,<h>` the window region to see where the button is,
and adjust the `*_TAP` constant. The device→screen map is
`screen = win_origin + device_inset + device_px * scale`, where `scale ≈
window_height_pts / screenshot_px_height`.

## Known limits

- **Dynamic states** (live keyboard dictation, Ask recording/answering) need
  real interaction + on-device models and aren't reliably scriptable in the
  simulator — capture those on a device.
- **Watch sync banners** ("pending sync / Sync stuck?") appear because the watch
  sim isn't paired to the phone sim; they're real but cosmetic for marketing.
- The watch recording shot needs a ~5s settle before `simctl io` (the recording
  transition briefly races screen capture); the script retries.
