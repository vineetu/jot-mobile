# Bug Plan: Keyboard-Initiated Dictation Doesn't Start (Cold Start)

> **Source:** [features.md §14.1](../../Jot/features.md#14-1-keyboard-initiated-dictation-opens-jot-but-does-not-start-recording)
> **Status:** Hypothesis upgraded after adversarial review found my original sanity-check was wrong on two counts. **Confidence: 75%** that the documented hypothesis is essentially right and the original one-line `warmUp()` fix is correct.

---

## Symptom (recap)

User taps Dictate in the Jot keyboard from a host app. Jot is brought to the foreground (recording hero may briefly appear) but recording never actually starts — the timer stays at 0:00 and no audio is captured. The user has to back out and tap the home-screen Dictate FAB to actually record.

**Path:** Cold start only (no warm-hold window active). Especially after model unload (memory warning / first launch after reboot).

## Corrected hypothesis analysis

My original draft dismissed the §14.1 hypothesis by claiming:
1. `triggerAutoStart` already guards on `transcriptionService.modelState == .ready` and defers when not — so the race is covered.
2. `warmUp()` is just a presence check, not load-into-RAM.

Both claims were wrong. Re-reading the code:

### Claim 1 — wrong. The defer is permanent without a model load kick.

`JotApp.swift:424-435` calls `transcriptionService.warmUp()` inside the scene `.task { }` block, gated on `SetupCompletion.isCompleted && modelsOnDisk`. That `.task` only runs after first scene activation.

The `.onOpenURL` handler at `JotApp.swift:280` can fire **before** `.task` body. A cold-launched scene woken by `jot://dictate?session=...` may:

1. Process the URL → call `triggerAutoStart` → guard hits `modelState == .notLoaded` → defer.
2. `.task` block schedules to run.
3. Defer waits for `.onChange(modelState)` to fire.
4. `.task` block runs warmUp **only if** the deferred defer hasn't already triggered a different code path, AND the warmup actually moves modelState to `.ready` while the observer is active.

In the failure case, the deferred defer is **permanent** until the `.task` body actually runs `warmUp()` — but the order is not guaranteed. If `.task` runs before `triggerAutoStart` defers, fine. If after, also fine (the `.onChange` fires). But there's a race where the user's tap consumes the gate (`autoStartConsumed = true`, line 732) and the model never gets explicitly nudged from the deferred path.

The right pattern: when `triggerAutoStart` defers on model-not-ready, **explicitly call `transcriptionService.warmUp()`** to kick the load. Today's defer just hopes the `.task` will do it.

### Claim 2 — wrong. `warmUp()` IS load-into-RAM.

`TranscriptionService.swift:199-208`:
```swift
func warmUp() {
    if standIn != nil { modelState = .ready; return }
    log.info("Parakeet warmUp requested — modelState=...")
    _ = ensurePreparing()
}
```

`ensurePreparing()` kicks the prepare task that flips `modelState` through `.loading → .ready`. This **is** the load-into-RAM. My original plan said it was "presence-only" — wrong.

So the simple one-line fix proposed earlier in the session — call `warmUp()` from the deferred-defer path — actually makes sense. It's not a workaround; it's the missing kick.

## Goal

1. Ship the **one-line `warmUp()` fix** in the deferred path of `triggerAutoStart`.
2. Improve the diagnostic instrumentation around the URL bounce / scene-task / model-state-transition timeline so any residual failure mode is visible.
3. **Required diagnostic step:** repro via Action Button Shortcut (`§10.2`) and compare. If shortcut works while keyboard URL doesn't, the bug is upstream of `RecordingService.start()`. If both fail, the bug is in the recording start path itself. This single test halves the search space before any fix lands.

---

## Diagnostic Plan (Step 1)

### Required before any fix

1. **Re-confirm reproducer.** Restart iPhone, open a host app's text field, tap Jot keyboard's Dictate. Symptom (timer at 0:00) reproduces deterministically per §14.1.
2. **Action Button comparison.** Use the iPhone Action Button (configured to "Start Jot Dictation") to start a dictation under the same cold-start conditions. Does it work?
   - **If yes:** the URL-bounce + `triggerAutoStart` chain is at fault. Fix Path A (below) applies.
   - **If no:** the recording-start path itself fails post-`triggerAutoStart`. Fix Path B applies.

### Instrumentation to add (ship now regardless of fix)

In `JotApp.swift`:

| Where | Log |
|---|---|
| Line 280 `onOpenURL` entry | `cold-launch-url scenePhase=\(scenePhase) modelState=\(modelState)` — captures whether `.task` warmup has run yet. |
| Line 424 inside `.task` body, before `warmUp()` | `scene-task running warmUp; modelState=\(modelState)` — captures the relative timing vs. onOpenURL. |
| Line 781 (defer branch) | Change `logAutoStartGuard("model-ready", ...)` to also include `modelState=\(modelState) reason=\(reason)`. |
| Line 391 `.onChange(modelState)` | Add `newState=\(newState) autoStartPendingModelReady=\(autoStartPendingModelReady)`. |
| `RecordingService.swift` `start()` exit | Log `audioEngine.isRunning currentRecordingStartedAt=...` 50 ms after start to detect "started but engine didn't come up." |
| `DictationActivityCoordinator.start(startedAt:)` | Log timestamp; this drives the elapsed timer the user sees. If the user reports "timer stays at 0:00," this method is the right probe — not `audioEngine.isRunning`. |

The combined instrumentation discriminates three cases:
- Engine started, timer driver started → bug is in audio engine actually capturing. Rare.
- Engine "started" returned but `isRunning == false` → audio session activation failed silently. Investigate `AVAudioSession.setActive` errors.
- `start()` never called → the URL → `triggerAutoStart` → start chain broke. Defer never re-fired.

**Patch size: XS** (~30 min, all logs).

---

## Fix (Step 2)

### Primary fix — kick `warmUp()` from the defer branch. **Size: XS.**

In `JotApp.swift:777-787`:

```swift
guard transcriptionService.modelState == .ready else {
    autoStartPendingModelReady = true
    transcriptionService.warmUp()      // ← NEW: explicit kick of the load
    logAutoStartGuard(
        "model-ready",
        action: "defer",
        reason: "model not ready; queued + warmUp() kicked from \(reason)"
    )
    return
}
```

That single line ensures the load is in flight after we defer — closes the race where `.task` hasn't run yet.

`warmUp()` is idempotent (concurrent calls share one task per the doc comment), so this is safe even if `.task` later calls it again. The `_ = ensurePreparing()` inside `warmUp()` returns the same in-flight task.

### Secondary fix — also call `warmUp()` at the `.task` entry unconditionally. **Size: XS.**

Even outside the cold-launch race, kicking `warmUp()` as the **first** thing the scene's `.task` does (before any other setup) reduces the window where a URL bounce can land on an unloaded model.

### If diagnostic step shows Action Button also fails — Path B. **Size: M.**

The bug isn't in URL handling; it's in `RecordingService.start()` itself. Need to find why the audio engine doesn't actually capture. Likely culprits:
- `AVAudioSession.setActive` returning success but the session being inactive (iOS bug after device reboot).
- `installTap` failing silently because the input format doesn't match what the engine has.
- Some race between `engine.start()` and `setupTransientHandlersIfNeeded()` (audio interruption handlers).

This is harder to diagnose without device access — would need live debugging. Sized M.

---

## Estimated Sizes

- **Diagnostic patch:** XS (~30 min). Ship first.
- **Primary fix (`warmUp()` in defer):** XS (~10 min including verification).
- **Action Button comparison test:** ~5 min for the user.
- **If Path B applies:** M (~1 day).
- **Most likely total path:** **S** end-to-end (~3-4 hours including verification on device).

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#b1--cold-start-dictation-race](./open-questions-deep-dive.md#b1--cold-start-dictation-race).

1. **Has the user successfully reproduced this since the diagnostic build?** The patch needs to ship and the user needs to repro once more to confirm the new logs land. Schedule.
2. **Does the same bug appear in the warm-hold path?** §14.1 says "Cold-start only." Confirm — if the warm-hold path also drops dictations occasionally, the `warmUp()` fix won't help (warm-hold path doesn't go through `triggerAutoStart`).
3. **Action Button result.** Required before any fix.

---

## Cross-Links

- Code: `Jot/App/JotApp.swift:280-353, 391-435, 727-820`, `Jot/App/Recording/RecordingService.swift:200-240`, `Jot/App/Transcription/TranscriptionService.swift:195-208`, `Jot/Keyboard/JotKeyboardViewController.swift:1517-1620`
- Memory: prior session captured the "one-line warmUp() fix" idea — turns out it was right after all.
- Cross-bug: §14.2 (keyboard auto-switch under memory pressure) is independent but shares the URL-bounce → main-app dispatch chain.
- Log discipline: every recording-start site logs `RECORDING START FROM:` per `Jot/CLAUDE.md`.
