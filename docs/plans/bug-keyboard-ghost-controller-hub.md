# Plan — Fix keyboard blank live-preview via a process-level streaming hub

**Status:** design → implementation. **Size: M–L.** Owner-approved approach (2026-06-17).
Root-cause fix for the intermittent **blank keyboard live-preview pane**. Supersedes
the surgical theories (stuck-progress / empty-layout / ARC retain cycle), all refuted
by on-device diagnostics (builds 142–143 `stream-render` + `KBD/CTRL` probes).

## Problem

During keyboard dictation the live-preview pane intermittently shows blank even
though the main app is publishing partials and the text reaches keyboard state.

## Confirmed root cause (from on-device traces + architecture investigation)

NOT a render bug and NOT an ARC retain cycle:

- **Ghost controllers.** Device logs show ≥2 `JotKeyboardViewController` instances
  alive at once (`controllerID=22` AND `=25` both "handling partial" for one
  recording), and a controller that loaded 23 min / many dictations earlier and
  **never `deinit`'d**.
- **Why they leak:** the seven Darwin observers are torn down ONLY in
  `viewWillDisappear` (`JotKeyboardViewController.swift:407-413`). iOS does NOT
  reliably call `viewWillDisappear` on an outgoing `UIInputViewController` during
  app-switch / memory pressure / host re-mount. So an OS-retained old controller
  keeps its subscriptions live and keeps firing `refresh*FromProjection()` into
  its **own off-screen** `recordingState`.
- **Why blank:** `recordingState` (`KeyboardRecordingState`, per-controller —
  `:53`) is **session-scoped state wrongly bound to the per-VC lifecycle**. The
  visible host belongs to one controller; a ghost consumes/echoes the feed into a
  different `recordingState`, so the surface you see isn't the one being updated.

There is no code-level retain cycle to "fix": every observer closure uses
`[weak self]`; Darwin observers register `passUnretained`. The defect is
architectural — feed + projection live at the wrong scope.

## Fix — `KeyboardStreamingHub`

A single `@MainActor @Observable` **process-lifetime** object that owns the ONE
set of cross-process subscriptions and the projected streaming/recording state.
Controllers OBSERVE it; they own none of it.

A transient or ghost controller then renders the **same** live state → the blank
is **structurally impossible**, and there is one subscription set so no ghost can
double-consume the feed. Correctness no longer depends on iOS calling teardown
hooks on time (the thing we cannot control).

### The seam — what moves vs stays

**MOVE to the hub (process/session-scoped feed + projection; never touches the proxy):**
- Darwin subscriptions: `streamingPartialChanged`, `streamingLoadingChanged`,
  `pipelinePhaseChanged` (feed-read half only — see split), `warmHoldNudgeChanged`,
  `historyMirrorUpdated`, `correctionAsksReady`. (`appForegroundPong` — TBD in impl;
  it's process-scoped but feeds the dead-app watchdog which is controller-scoped.)
- Projected state today held by `KeyboardRecordingState`: `streamingPartialText`,
  `loadingVariantLabel`, pipeline `phase`/`isRecording`/`isPaused`/`pausedElapsedSeconds`,
  `showWarmHoldNudge`, `historyEntries`, `correctionAsks`.
- `clearStreamingPartialForNewSession` semantics (now global = correct; one true
  session at a time; removes the prior-session-tail-bleed bug). MUST be driven
  explicitly on a new session start (the per-VC model got this "for free" by being
  recreated).

**STAY on the controller (controller-scoped; needs `self` / `textDocumentProxy` / host):**
- All paste/insert (`flushPendingAutoPasteIfPossible`, in-flight-paste window,
  read-back/verify/reconnect-poll), caret moves, selection reads, undo ledger,
  backspace repeat.
- `UIHostingController` + the SwiftUI host tree; `KeyboardViewInputs` (proxy-derived).
- `KeyboardFeedback`; `keyboardActiveHeartbeatTimer`.
- The deadline/watchdog Tasks (`pipelineStaleDeadlineTask`, `pendingLaunchDeadlineTask`,
  `deadAppWatchdogTask`) and the `stopRequestPosted` flag — these end in proxy
  inserts / per-presentation recovery.

### The one delicate split — pipeline-phase observer

`refreshPipelinePhase` today does BOTH: (a) read projection → update phase state
[→ hub], and (b) controller-scoped side-effects: `flushPendingAutoPasteIfPossible`,
arm watchdogs, clear `stopRequestPosted` [→ stays on controller].

Resolution: the hub owns (a) and exposes a phase-change signal; the **active
controller** subscribes a thin hook for (b). Implementation options (decide in impl):
1. Hub holds an `onPhaseChange: ((phase) -> Void)?` callback the current controller
   sets in `viewWillAppear` and clears in `viewWillDisappear`/`deinit`. Simple; the
   "active" controller is the last to set it.
2. Controller keeps its OWN thin `pipelinePhaseChanged` Darwin observer purely for
   the proxy side-effects, while the hub independently owns the phase *state*. Keeps
   subscriptions split by concern; costs one extra (cheap) observer per controller.

Pick (2) if it keeps the paste path provably unchanged (lowest risk to the
verified paste machinery); (1) if we want a single subscription. **This split is
the main correctness risk — review it adversarially.**

## Migration steps

1. Add `Jot/Keyboard/KeyboardStreamingHub.swift` — `@MainActor @Observable`
   singleton owning the feed subscriptions (lazy first-access, process-lifetime,
   never torn down) + the projected state above. Reuse the existing
   `refresh*FromProjection` bodies verbatim (they read AppGroup, mutate state).
2. Repoint `KeyboardView`/`KeyboardRootHostView` to read the hub's state instead
   of a per-controller `recordingState`. (View read-path is already by-reference
   `@Observable`, so this is a source swap, not a re-architecture.)
3. Delete the per-controller `recordingState` + the moved `startObserving*`/`refresh*`.
   Keep a `viewWillAppear` → `hub.refreshNow()` one-shot so a freshly-presented
   controller paints current state immediately.
4. Implement the phase split (above).
5. **Hygiene pass:** add `viewDidDisappear` + `deinit`-time teardown for everything
   that STAYS controller-scoped (observers the controller still owns, timers, tasks),
   so ghost controllers stop burning cycles. Correctness doesn't depend on it.
6. `xcodegen` (new file under `Keyboard/` is auto-picked by the glob), build the
   `JotKeyboard` + `Jot` schemes, adversarial review, owner on-device test, deploy.

## Risks

- **Phase split** (above) — get the seam wrong → double-fire or miss paste flushes.
  Highest risk; adversarial-review the paste path specifically.
- **New-session reset** — the hub must explicitly clear projected state on a fresh
  session start, driven from the controller that handled the start tap, or a new
  presentation shows a prior session's tail.
- **Hub lifetime in an appex** — process death takes the singleton (fine; re-subscribes
  lazily on relaunch). First-access must be `@MainActor` + idempotent.
- **Warm-hold / history / correction-asks consumers** — verify each still reads the
  hub and that the keyboard's nudge/Recents/correction UIs are unaffected.

## Schema impact: NONE

UserDefaults/App-Group reads + an in-process `@Observable` only. No `@Model` types.

## Out of scope

The per-VC paste machinery, the de-erasure host (unchanged), and the streaming
instrumentation (kept until this lands and is verified, then removed separately).
