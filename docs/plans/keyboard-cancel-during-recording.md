# Plan: Cancel Replaces Actions in Keyboard During Recording

> **Status:** Aspirational improvement. Closes a real gap in the keyboard's current control set + unifies abort UX across third-party and in-app dictation paths.
> **Size: XS** (~1-2 hours).

---

## Problem

Today the Jot keyboard's action row exposes three controls (per `features.md §5.6` + §5.4): Minimize, Dictate/Stop, Actions. The Actions popover has 6 operations (Paste, Copy, Undo, Redo, Move up, Move down) — all of which are text-manipulation ops that don't make sense mid-dictation.

Worse: **there's no way to abort a dictation from the keyboard.** Stop commits (saves + auto-pastes). The Hero's Cancel pill (§2.6) is the only abort affordance, but users in the warm-hold path (`§13.2`) never see the Hero. So warm-hold dictations are commit-only from the user's perspective.

This also leaves the in-app dictation plan ([docs/plans/in-app-tap-to-record.md](./in-app-tap-to-record.md)) without a clean abort path — which the user explicitly didn't want to special-case there.

## Goal

Replace the Actions button with a Cancel button while a dictation is actively recording. Return to Actions the moment Stop is tapped.

## Non-Goals

- Not removing any existing functionality.
- Not adding a Cancel option during the Post-Stop "Working" state (§5.5) — Stop is the commit point.
- Not changing the Actions popover contents.
- Not adding Cancel anywhere outside the keyboard's action row (no Hero changes, no new sheets).

---

## Design

### State machine

| Keyboard state | Action row third slot |
|---|---|
| Idle | **Actions** (existing) |
| Recording (audio engine active) | **Cancel** |
| Post-Stop "Working" (transcribe in progress) | **Actions** (immediate revert on Stop tap) |

Once Stop is tapped, Actions returns. User cannot abort during transcription — Stop is the commit point.

### Visuals

- Cancel button: same shape as the existing Actions button (round, action-row sized). Icon: `xmark`. Foreground: red/destructive accent (`Color.jotDestructive` or equivalent).
- Hit area: same as Actions, so users with muscle memory tap the same spot.
- VoiceOver label: "Cancel recording. Discards what you've said so far."

### Cancel semantics

Matches §2.6 (Hero's Cancel pill):
- Stop audio engine.
- Discard partial transcript.
- Do not save to library.
- Do not auto-paste.
- No banner — silent abort. (Matches existing Hero Cancel.)

### Cross-path symmetry

- **Third-party host (cold path):** today, only Stop. After this change, Cancel becomes available without leaving the host.
- **Warm-hold path:** today, only Stop. After this change, Cancel becomes available — closes a real UX gap.
- **In-app dictation:** inherits Cancel automatically. No in-app-specific UI needed.
- **Wizard W5 (keyboard try-it):** Cancel works the same way; if user cancels the try-it, the wizard's "advance on dictation arrival" trigger doesn't fire, and user can try again.

### Implementation outline

| Component | Location | Work |
|---|---|---|
| Conditional render | `Jot/Keyboard/KeyboardView.swift` action row | Single `if recordingState.isRecording` switch on the third button slot. |
| Cancel action wire | `Jot/Keyboard/JotKeyboardViewController.swift` | Call existing `RecordingService.shared.cancel()` (or whatever the Hero's Cancel pill calls). |
| VoiceOver label | `Jot/Keyboard/KeyboardView.swift` | New accessibility label. |
| `features.md §5.6` update | `Jot/features.md` | Document the new lifecycle. |

---

## Edge Cases

- **Cancel tapped during the brief moment between user-Stop and transcribe-start.** Should be inert — at that point the recording is committing. The button has already reverted to Actions per the state table, so this isn't reachable from the UI; but defend against a stale tap via the `recordingState.isRecording` guard in the cancel handler.
- **Cancel tapped during streaming-only state (collapsed keyboard).** Collapsed bar shows Dictate/Stop only per §5.8 — no action-row slot to replace. So the Cancel button isn't visible. User must expand to cancel, or just Stop. Acceptable for v1; document.
- **Cancel tapped during warm-hold (recording active inside warm window).** Recording is real; cancel works as normal. Warm-hold session itself is unaffected (the warm hold continues counting down post-cancel; user can start a new dictation right away).
- **Cancel during chained follow-up window (§2.11).** Recording is real; cancel discards. The chain doesn't form. Subsequent dictation is treated as a fresh entry.

---

## Test Plan

1. **Idle → Actions** button visible in action row.
2. Tap Dictate → enter Recording state → **Cancel** button replaces Actions.
3. Tap Cancel → recording stops, no library entry created, no paste, return to Idle → Actions reappears.
4. Tap Dictate → tap Stop → button immediately reverts to Actions; the transcribe state runs but the user can interact with Actions normally during it.
5. Warm-hold path: start dictation in Slack via Jot keyboard, tap Cancel — no paste lands in Slack, no library entry, warm-hold remains armed.
6. Collapsed keyboard: while collapsed, Cancel is not visible; tapping Stop still works.
7. VoiceOver: Cancel announced with distinct label vs. Actions.
8. Wizard W5: cancel a try-it dictation — wizard doesn't advance; user can retry without re-entering W5.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md). (No questions for this plan — design is self-contained.)

---

## Cross-Links

- Touches: `features.md §5.6` (Actions Popover lifecycle), `§5.4` (Dictate/Stop control), `§2.6` (Cancel semantics)
- Related: [in-app-tap-to-record.md](./in-app-tap-to-record.md) — this plan provides the Cancel affordance the in-app plan no longer needs to invent.
- Code: `Jot/Keyboard/KeyboardView.swift`, `Jot/Keyboard/JotKeyboardViewController.swift`, `RecordingService.cancel()`
