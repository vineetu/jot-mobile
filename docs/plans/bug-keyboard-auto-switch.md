# Bug Plan: Keyboard Auto-Switches Back to System Keyboard After Stop

> **Source:** [features.md §14.2](../../Jot/features.md#14-2-keyboard-auto-switches-back-to-system-keyboard-after-dictation-stop)
> **Status:** Rare, not yet reliably reproduced. **Confidence in hypothesis: 50%** after adversarial review surfaced an alternate hypothesis (main-app jetsam, not keyboard termination) that the original plan didn't consider.

---

## Symptom (recap)

After the user taps Stop in the Jot keyboard:
- iOS switches the active keyboard back to the previous system keyboard.
- When the user manually switches back to Jot (globe key), the transcript has already been auto-pasted.
- The keyboard is in its normal idle state on return.

**Path:** Rare; not yet reliably reproduced. Both warm-hold and cold paths possibly affected.

## Hypotheses

The original draft considered only **Hypothesis A: keyboard extension terminated**. Adversarial review surfaced **Hypothesis B: main app jetsammed** as an equally plausible alternative.

### A — keyboard ext terminated by iOS under memory pressure (original)

iOS kills the keyboard process while it observes Darwin notifications + App Group state during the transcribe window. iOS falls back to previously-active keyboard while the extension relaunches. Auto-paste lands because the main-app pipeline finishes independently and the v7 paste-deadline machinery resurrects it on next keyboard presentation.

### B — main app jetsammed (added per review)

The main app, NOT the keyboard, dies mid-transcribe. The keyboard observes its main-app heartbeat (`AppGroup.warmHoldHeartbeat` ticks while main app is alive) — if the heartbeat goes stale during a transcribe, the keyboard may see this as a session anomaly. The auto-switch could be iOS's response to a host-app focus-state perturbation caused by the main-app death, not by the keyboard's own death.

The main app is the heavyweight process (loads 110M speech weights, sometimes 2.5 GB rewrite weights). It's the more likely jetsam target.

### How to distinguish

The diagnostic plan must collect signals that disambiguate A vs B. Specifically:

- A: keyboard's `viewDidAppear` shows a stale `lastKeyboardTerminationAt` (or no value) → keyboard was killed.
- B: keyboard's `viewDidAppear` shows a fresh `lastKeyboardTerminationAt` (graceful dismiss) BUT a stale `AppGroup.warmHoldHeartbeat` (main app died) → main app was killed.

## Goal

1. **Disambiguate A vs B** via stronger instrumentation.
2. **Reduce keyboard memory footprint** as defensive mitigation (helps A; harmless if B is the real cause).
3. **Improve resurrection UX** — but with a critical caveat about the §5.10 collapsed-state banner bug.

---

## Diagnostic Plan (Step 1)

### Instrumentation to ship

Both keyboard and main app are instrumented. The "rare, not reproduced" nature means we need durable enough instrumentation that the user can capture and send logs without on-device debugging.

In `JotKeyboardViewController.swift`:

| Where | Log + AppGroup write |
|---|---|
| `viewWillDisappear` | Log + write `AppGroup.lastKeyboardTerminationAt = .now` (best-effort; may not fire on hard kill). Include memory footprint via `mach_task_basic_info` resident_size. |
| `viewDidDisappear` | Same as above (redundant but useful if WillDisappear was preempted). |
| `viewDidAppear` | Log "appeared after gap of \(now - lastKeyboardTerminationAt)s; warmHoldHeartbeat age=\(now - warmHoldHeartbeat)s; my-pid=\(getpid())". A previous-PID mismatch (stored in App Group on previous appear) means a fresh process. |

In `JotApp.swift` (main app):
- `scenePhase` transition handler — log every transition timestamp.
- `applicationWillTerminate` (rarely fires under jetsam) and a periodic heartbeat persist to App Group at 1-second cadence while foregrounded.

### Memory-pressure repro

Try to force the symptom under controlled conditions:

1. **Open Safari with 20+ heavy tabs** → switch to Slack → grant Jot keyboard, dictate a 30-second message, stop. Run 10 trials, expect at least 1 failure if the memory-pressure hypothesis is right.
2. **Background a memory-heavy game** (e.g. Genshin Impact) → repeat. Should increase failure rate.
3. **Cold-start the device, immediately dictate in Jot keyboard from a clean host (Notes)** → contra-test; should NOT fail. If it does, the bug isn't memory-related.

### What the diagnostic tells us

| Captured signal | Conclusion |
|---|---|
| keyboard PID change + stale lastKeyboardTerminationAt + fresh main-app heartbeat | Hypothesis A: keyboard killed. |
| keyboard PID stable + fresh lastKeyboardTerminationAt + stale main-app heartbeat | Hypothesis B: main app killed. |
| Both processes show fresh PIDs after the event | Both got killed; rare but possible. |
| Both stable + nothing stale | Symptom isn't a process termination — something else (iOS keyboard switcher state? a Darwin notification routing issue?). |

**Diagnostic patch size: S** (~3 hours).

---

## Mitigation Plan (Step 2)

### Path A — Reduce keyboard memory footprint. **Size: M.**

Defensive even if Hypothesis B turns out to be the real cause — smaller keyboard never hurts.

| Target | Action | Estimated savings |
|---|---|---|
| Streaming partial text growth | Cap on WRITER side (main app's `AppGroup.streamingPartialText` write) at 8 KB sliding window. Today's write is unbounded. Critical change — the original draft incorrectly placed this on the reader side. | 20-100 KB per long dictation, removed from BOTH keyboard's `recordingState` cache AND main-app process memory. |
| AppGroup re-reads on every keyboard tick | Cache parsed values (donation summary, prompts, recents) with 5-s TTL in keyboard process. | ~5 ms CPU + a few KB allocator churn per tick. |
| Cached SF Symbols + fonts | Audit; SwiftUI glyph caches are mostly automatic but worth checking with Instruments. | Likely small. |
| Darwin notification observers | Audit `JotKeyboardViewController.swift` for orphaned observers from prior presentations. | Likely already clean post-v7 hardening; verify. |

**Critical fix from this work:** the `streamingPartialText` cap must happen at the **main-app writer**, not the keyboard reader. Capping in the keyboard means main-app process memory still grows; capping at the writer means **both processes** stay bounded. The original plan got this backwards.

### Path B — Resurrection UX. **Size: M, NOT S as originally claimed.**

When the keyboard relaunches and the auto-paste already fired during the gap, the user should know the paste worked.

**Critical blocker:** `Jot/CLAUDE.md` §5.10 explicitly documents that "when a status banner fires while the keyboard is in its collapsed state, the keyboard height grows but the render branch stays on the collapsed view (which has no banner slot), so the banner is silently invisible." A resurrection banner would silently no-op for any user whose keyboard happened to be collapsed when the kill happened.

**Two options:**
1. **Fix §5.10 first**, then ship the resurrection banner. Adds significant scope.
2. **Use a non-banner surface** that works in both collapsed and standard states. Options:
   - A small chip in the Recents strip (the just-paste flashes a green border for ~5 s, matching the existing "just now" treatment per the existing v7 `stampJustNowMarker` code) — but recents strip is also hidden in collapsed state.
   - A change to the Dictate button's appearance for ~3 s (a checkmark glyph overlay). Works in both states.

**Recommendation: option 2 (Dictate button overlay).** Smaller scope, no §5.10 dependency.

### Path C — Heart-beat keep-alive. **DROPPED.**

Periodic background work in a keyboard extension is an App Store review risk (4.2.x / 2.5.x). Adversarial review correctly flagged. Drop entirely; revisit only if A + B aren't enough.

### Path D — If Hypothesis B is confirmed: harden the main app. **Size: M-L.**

If logs show main-app jetsam is the cause:

- Reduce main-app memory footprint during transcribe (smaller speech model variant by default, eager unload of rewrite model when not in use).
- Add explicit "transcribing" state that requests `UIBackgroundTaskIdentifier` / `BGProcessingTaskRequest` so iOS gives a stronger grace period.
- Ensure the warm-hold heartbeat cadence doesn't itself add memory churn.

---

## Estimated Sizes

- Step 1 (instrumentation): **S** (~3 hours).
- Step 2 mitigation A (memory footprint reduction): **M** (~1-2 days, mostly writer-side capping + cache TTLs).
- Step 2 mitigation B (resurrection UX via Dictate button overlay): **S** (~3 hours).
- Step 2 mitigation D (if Hypothesis B is real): **M-L** (~2-4 days).
- **Most likely total:** M (~2-3 days end-to-end).

---

## Test Plan

1. **Instrumentation verification.** Force a keyboard dismiss/re-present manually (not a kill). Confirm logs land, PID stays the same, lastKeyboardTerminationAt becomes fresh.
2. **Force kill via Xcode.** Attach to keyboard process, send SIGKILL mid-transcribe. Confirm next viewDidAppear logs a PID change + stale lastKeyboardTerminationAt → hypothesis A signature.
3. **Force jetsam.** Hard to script; use the memory-pressure repro under controlled conditions. Capture logs.
4. **Repro 20 trials** under each memory-pressure scenario (Safari heavy, game in bg, clean). Record failure rate before and after Path A ships. Target: at least 50% reduction.
5. **Resurrection UX verification.** Force a keyboard kill mid-transcribe. Confirm Dictate button shows the checkmark overlay for ~3 s on relaunch.
6. **§5.10 confirmation.** Confirm via test that the existing banner mechanism silently no-ops in collapsed state — validates the decision to use button overlay instead.
7. **VoiceOver.** The button overlay state is announced via accessibility ("Dictation pasted") for ~3 s before reverting.
8. **Memory profiling.** Use Instruments to compare keyboard resident memory before and after Path A. Verify the streaming-text cap shows up as a real reduction.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#b2--keyboard-auto-switch](./open-questions-deep-dive.md#b2--keyboard-auto-switch).

1. **Which host app does the user report this in?** Knowing the host narrows whether it's app-specific (likely Hypothesis B, where the host's behavior interacts with main-app death) or host-agnostic (likely Hypothesis A).
2. **iOS-version specific?** Has the user seen this on iOS 25 too, or only iOS 26?
3. **Confirm hypothesis after first capture.** Once logs land, escalate the right Path. Don't ship Path A + B blindly if Hypothesis B turns out to be the real story.
4. **Resurrection UX — Dictate button checkmark, or something subtler?** Confirm the proposed treatment.

---

## Cross-Links

- Code: `Jot/Keyboard/JotKeyboardViewController.swift` (lifecycle + paste-resurrection), `Jot/Shared/AppGroup.swift` (warmHoldHeartbeat + streamingPartialText), main-app `JotApp.swift` (scenePhase)
- Memory budget constraint: `Jot/CLAUDE.md` (~60 MB keyboard ceiling)
- Blocking: §5.10 collapsed-state banner bug blocks resurrection-banner option in Path B (worked around with button overlay)
- Related bug: §14.1 (cold-start race on start) — both are keyboard ↔ main-app coordination but on different ends.
- Related bug: §14.3 (Slack silent paste) — independent but touches the same paste-resurrection layer.
