# Bug: keyboard hangs in a stale "recording" state when the Jot app is killed mid-recording

> **Status: FIX IMPLEMENTED (2026-06-03) — compiles clean; Codex-reviewed; PENDING on-device test.**
> Approach: heartbeat lowered 10s→3s (`PipelinePhaseProjection`); on each control tap (stop/cancel/
> pause/resume) the keyboard arms a 5s watchdog — if the shared projection's `lastUpdatedAt` hasn't
> advanced AND it's still `.recording`/`.paused`, recover the keyboard to idle. A live app (even
> backgrounded) stamps within 3s, so it never false-fires. Codex review fixes folded in: (a) a
> session tombstone so a keyboard dismiss/re-present within the 30s window can't resurrect the
> zombie from the still-`.recording` projection; (b) recover only when the projection is still
> *active* (don't fire on a terminal phase + clear a valid pending paste). **On-device test:** kill
> the app mid-recording → tap Stop/Pause/Cancel → recovers ≤5s (multiple repros); dismiss+re-present
> within 30s stays idle; app-alive happy path unchanged + auto-paste still lands.

## Symptom (user-reported, on device)

During an active recording, iOS kills the Jot **main app** (memory-pressure /
jetsam — e.g. the user switched away, or the system reclaimed memory). The Jot
**keyboard extension** does **not** detect that the app is gone:

- The keyboard keeps rendering a live "recording" state — it looks like it's
  still working, driven by **stale cross-process state** that nobody updated to a
  terminal because the app died while live.
- The keyboard **hangs**: tapping **Stop / Pause / Cancel / Delete** does nothing,
  because the process that would handle those Darwin requests is no longer
  running. There's no response and no recovery.
- The only way out today is to **manually re-open Jot**.

So: app dies mid-recording → keyboard is stuck in a zombie "recording" UI with no
working controls until the user relaunches the app by hand.

## Why it happens (hypothesis — verify before fixing)

The keyboard derives "is recording" from the App Group `PipelinePhaseProjection`
/ streaming state, and drives Stop/Pause/Cancel/Delete by **posting Darwin
notifications** (`stopRequested`, `pauseRequested`, `cancelRequested`) that the
**main app** observes and acts on. When the app is killed:

- The projection is left at its last value (`.recording`) — never written to a
  terminal phase, because the writer (the app) is dead. The keyboard trusts it.
- A posted `stopRequested` (etc.) has **no live observer**, so nothing happens and
  the keyboard sits on `stopRequestPosted` waiting for a confirmation that will
  never come.

There IS a heartbeat/stale mechanism in the codebase (warm-hold heartbeat; a ~30s
stale-projection path that synthesizes `.failed`) — too slow / not wired to the
control taps for this case. Confirm what liveness signal exists before designing.

## Desired behavior / fix direction (the user's ask — for later)

When the user acts on the recording **from the keyboard** (Stop / Pause / Cancel /
Delete), the keyboard must **not blindly trust the stale recording state**. It
should **verify the main app is actually alive** before assuming the action will
be handled:

1. On the control tap, ping the app for liveness (reuse the existing
   `keyboardForegroundPing` / `appForegroundPong` round-trip, or the heartbeat
   freshness) **with a short timeout — a few seconds.**
2. If the app **responds in time** → behave exactly as today (post the Darwin
   request; the app handles it). No change to the happy path.
3. If the app **does NOT respond** within the timeout → treat it as **"app not
   open / dead"**: recover gracefully on the keyboard side —
   - clear the stuck recording / `stopRequestPosted` state,
   - reset the keyboard UI out of the zombie "recording" view (back to idle),
   - end/discard the orphaned recording cleanly (no hang, no waiting on a dead
     process),
   so the user is never stranded needing to relaunch Jot manually.

## Scope guardrails for whoever implements this

- Do NOT change the warm-hold / cold-start flow or the normal (app-alive) stop
  path — only add the dead-app fallback.
- The liveness check must be cheap and only run on the control taps (don't poll).
- Test: start a recording from the keyboard, kill the Jot app (Xcode "kill" or
  jetsam), then tap Stop/Pause/Delete from the keyboard — it must recover within a
  few seconds instead of hanging.

---

## Fix plan (DECIDED 2026-06-03)

> Status: APPROACH DECIDED. This section is the implementation spec. The
> symptoms/hypothesis above are unchanged and remain the source of "why".
> Plan only — no code has been written.

### Problem

(See [Symptom](#symptom-user-reported-on-device) and [Why it happens](#why-it-happens-hypothesis--verify-before-fixing)
above.) When iOS jetsams the Jot **main app** mid-recording, the keyboard's
recording UI is driven by a `PipelinePhaseProjection` frozen at `.recording`,
and the Stop / Pause / Cancel / Delete controls post Darwin notifications whose
**only observers live in the dead main app**. The keyboard hangs in a zombie
"recording" state until the ~30s stale-projection path eventually synthesizes
`.failed` — or until the user manually relaunches Jot. The user currently waits
~30s; the goal is to collapse that to a near-instant (≤5s) local recovery.

Confirmed by reading the code:

- Keyboard recording state flows `PipelinePhaseProjection.read()` →
  `recordingState.applyPipelineProjection(_:)` (`JotKeyboardViewController.swift:1338-1339`),
  where `isRecording` derives from `phase == .recording` / `.paused`
  (`JotKeyboardViewController.swift:2085-2100`). A dead writer leaves the blob at
  `.recording`.
- `read()` only age-gates a non-terminal projection to a synthetic `.failed`
  once `age > heartbeatStaleThreshold (30s)` (`PipelinePhaseProjection.swift:52-53,74-85`).
  That is the 30s wait.
- Stop / Cancel / Pause / Resume all just post a Darwin notification
  (`JotKeyboardViewController.swift:1744`, `:505`, `:516`, `:525`); the observers
  are in the main app — `JotApp.swift:71-94` (stop/cancel/ping) and
  `RecordingService.swift:283-303` (pause/resume) — all gone when the app is dead.

### Decided approach

On a **control tap** (Stop / Pause / Cancel / Delete) while the keyboard believes
it is recording, do not blindly trust the stale projection. First verify the main
app is alive via the existing ping/pong primitive, then branch:

1. **Ping the app for liveness** by reusing `keyboardForegroundPing` →
   `appForegroundPong` (`CrossProcessNotification.swift:126,129`; keyboard send/
   resolve modeled on `resolveForegroundThenStart()` `JotKeyboardViewController.swift:1563-1580`;
   app pongs only when not backgrounded `JotApp.swift:83-94`). This round-trip is
   ~120ms (`foregroundPongTimeout` `JotKeyboardViewController.swift:113`).
2. **Alive (pong received within window)** → behave **exactly as today**: post the
   corresponding Darwin request and let the app handle it. The happy path is 100%
   untouched.
3. **Dead (no pong within the ceiling, corroborated — see decision rule)** → recover
   locally on the keyboard side: fire the **existing synthetic-`.failed` recovery
   early** rather than waiting ~32s for the stale path. Concretely, apply a
   terminal projection through the normal channel (`refreshPipelinePhase()` /
   `applyPipelineProjection(nil-or-synthetic-.failed)`), which resets `isRecording`,
   clears pending paste, and runs the failed-cleanup branch — the same teardown the
   30s stale path already performs via `pipelineStaleDeadlineTask`
   (`JotKeyboardViewController.swift:1366-1385`). Detection is near-instant; **5s is
   the absolute ceiling** the user should ever wait.

Reuse, not new plumbing: the ping/pong handshake and the synthetic-`.failed`
recovery already exist and are battle-tested. The fix is to wire the existing
liveness check in front of the control taps, and to trigger the existing recovery
early when it fails.

### Recommended decision rule (errs safe)

The verdict must resolve within the 5s ceiling but must **strongly avoid a
false-positive "dead"** (which would destroy a live recording — see
[False-positive safety](#false-positive-safety-first-class-constraint)). Recommended
rule, evaluated on the control tap:

1. Snapshot `projectionAtTap = PipelinePhaseProjection.read()` and its
   `lastUpdatedAt`. Post `keyboardForegroundPing` with a fresh nonce (mirroring the
   `pendingForegroundPing` nonce pattern at `JotKeyboardViewController.swift:1564-1573`
   so a superseding tap cancels the older resolution).
2. Wait `foregroundPongTimeout` (~120ms). If a pong arrives → **ALIVE** → happy path,
   immediately post the real Darwin request. Done.
3. If no pong in the first window, send **one retry ping** and wait one more short
   window (~120ms). A pong on the retry → **ALIVE** → happy path. (The retry absorbs
   a single coalesced/dropped Darwin round-trip without escalating to teardown.)
4. If still no pong, require **corroboration** before declaring dead: also check the
   projection-heartbeat freshness. A genuinely alive recorder refreshes
   `lastUpdatedAt` every 10s (`PipelinePhaseProjection.swift:52`), so the keyboard
   re-reads the projection and only proceeds toward "dead" if the heartbeat is also
   not fresh. Recommended freshness window: heartbeat age **≥ ~11s** (one missed
   10s beat + jitter) treated as "stale", consistent with the conservative-threshold
   precedent (warm-resume uses 4s vs 2.5s for the 1s heartbeat — see safety section).
   If the projection heartbeat IS still fresh (< ~11s old) despite the pong miss,
   **do not tear down** — the app is plausibly alive but momentarily unresponsive
   (busy ANE); fall back to today's behavior (post the Darwin request) and let the
   30s stale path act as the ultimate backstop.
5. **Hard ceiling:** the entire verdict must complete within **5s**. In practice the
   two ping windows + a projection re-read resolve in well under 1s; the 5s is a
   defensive upper bound. If for any reason the verdict has not resolved by 5s and no
   pong was ever seen, recover (consistent with corroboration already having failed).

Net effect: declare dead only when **(a)** two ping windows produced no pong AND
**(b)** the projection heartbeat is also stale. Either signal alone is insufficient.
This keeps a single 120ms miss on a live-but-busy app from destroying audio, while
still recovering within the ceiling when the app is truly gone.

### Exact change points

All in `Jot/Keyboard/JotKeyboardViewController.swift` unless noted. The pattern:
add a single `verifyLivenessThenAct(onAlive:onDead:)` helper (built on the existing
`resolveForegroundThenStart()` shape, `:1563-1580`) and route each control handler
through it.

- **Stop** — `handleMicCTATap()` `.stop` case (`:1722-1762`). Today it
  `beginPendingPasteSession()` (`:1732`), sets `stopRequestPosted = true` (`:1742`),
  `renderRootView()`, posts `stopRequested` (`:1744`), and schedules a 750ms resync
  (`:1754-1761`). Wrap this: `onAlive` runs the existing body verbatim; `onDead`
  runs the local recovery (below) instead of posting `stopRequested`. (Defer the
  `beginPendingPasteSession()` until `onAlive`, or clear it in `onDead`, so a dead
  verdict does not leave a pending session armed.)
- **Cancel** — `handleCancelRecording()` (`:503-506`). `onAlive` → post
  `cancelRequested` as today; `onDead` → local recovery (cancel == discard, so this
  is the natural recovery anyway).
- **Pause** — `handlePauseRecording()` (`:514-517`). `onAlive` → post
  `pauseRequested`; `onDead` → local recovery (cannot pause a dead recording; tear
  down the zombie instead).
- **Resume** — `handleResumeRecording()` (`:523-526`). Same wrapping for symmetry —
  a resume tap against a dead app should also recover rather than hang.
- **Delete** — in this recording-control context "Delete" maps to the discard/cancel
  action (`forceStop` + discard via `cancelRequested`); there is **no separate
  `deleteRequested` notification** (the keyboard's `deleteBackward` paths at
  `:1453,:1501` are text backspace, unrelated). Route the recording-delete control
  through the same wrapper as Cancel. **Open question flagged below** to confirm
  which on-screen control the CEO labels "Delete".

**Local recovery routine (`onDead`) — exact state to reset:**

1. Reset the projection through the **normal channel**, never by writing the App
   Group blob from the keyboard (writer-owns-clears invariant —
   `PipelinePhaseProjection.swift:64,90-93`). Call
   `recordingState.applyPipelineProjection(nil)` (or re-run `refreshPipelinePhase()`
   after the synthetic path), which flips `isRecording`/`isPaused` false
   (`:2077-2105`).
2. `stopRequestPosted = false` (`:203`) — otherwise the speak button stays
   `.disabled`. (Note today this is only cleared in `refreshPipelinePhase()` at
   `:1348-1349` when the projection moves off `.recording`, which never happens on a
   dead app — so `onDead` must clear it explicitly.)
3. Clear the pending-paste session if armed — `clearPendingPasteSession()`
   (`:922-926`), which also cancels `pendingLaunchDeadlineTask`.
4. Clear streaming partial + loading — `clearStreamingPartialForNewSession()`
   (`:1253-1256`) and reset the loading variant label.
5. Cancel `pipelineStaleDeadlineTask` and `pendingLaunchDeadlineTask` so they do not
   double-fire after recovery (`:1367-1368`, `:924-925`).
6. `renderRootView()` to repaint idle chrome.

Reuse note: steps 1, 3, 4, 5 are exactly what the existing 30s stale path does via
`refreshPipelinePhase()` → `armOrCancelStaleDeadline` + `flushPendingAutoPasteIfPossible`.
The cleanest implementation makes `onDead` invoke that same recovery entry point
(so the teardown stays in one place) plus the explicit `stopRequestPosted = false`.

### Survives keyboard dismiss / re-present

The recovery tasks are torn down in `viewWillDisappear` (`:289-302`) and re-armed in
`viewWillAppear` (`:260-287`). Because the local recovery routes through the same
projection-driven path, a dismiss mid-verdict is safe: on re-present, `viewWillAppear`
calls `refreshPipelinePhase()` (`:270`) and `rearmLaunchDeadlineIfPending()` (`:282`),
which re-evaluate the projection. To make the dead verdict durable across a recycle,
prefer driving recovery through the projection/age path so a re-presented keyboard
re-derives "not recording" rather than depending on in-memory flags that reset on
recycle. The verdict's nonce (`pendingForegroundPing`-style) must be re-checked on
resolution so a verdict whose keyboard was dismissed simply no-ops.

### What stays untouched

- Normal **app-alive** Stop / Pause / Cancel / Resume / Delete — unchanged (the
  `onAlive` branch is the existing body verbatim).
- Warm-hold flow and the warm-resume fast-path ghost check (`:1618-1643`) — unchanged.
- Cold-start ping/pong **START** routing (`resolveForegroundThenStart()` `:1563-1580`,
  `decideMicTap().start` `:1714-1720`) — unchanged; the new helper is a sibling, not a
  rewrite.
- `pendingLaunchDeadlineTask` (15s launch deadline) and `pipelineStaleDeadlineTask`
  (30s stale backstop) — kept as backstops; the fix fires recovery *earlier*, it does
  not remove these.
- Liveness check is cheap and runs **only on the control taps** — no polling, no timer.

### False-positive safety (first-class constraint)

**A wrong "app is dead" verdict on a slow-but-alive recording would tear down a LIVE
recording and LOSE the user's audio.** This is strictly worse than a slightly slow
cleanup. The codebase already encodes this lesson: the warm-resume ghost check
deliberately uses a **4s** heartbeat threshold instead of 2.5s precisely because
"false-positive jetsam classification is worse than a slightly delayed ghost-cleanup"
(`JotKeyboardViewController.swift:1629-1633`).

Mitigations baked into the decision rule above:

- **Two ping windows, not one.** A single 120ms coalesced/dropped Darwin round-trip
  cannot trip a teardown; a retry is required.
- **Corroboration required.** Declare dead only when the pong miss is *joined by* a
  stale projection heartbeat (age ≥ ~11s). A live-but-busy recorder keeps stamping
  `lastUpdatedAt` every 10s (`PipelinePhaseProjection.swift:52`); a fresh heartbeat
  vetoes the dead verdict and falls back to today's behavior.
- **Backstop preserved.** Even if the rule refuses to declare dead (fresh heartbeat
  but no pong), the existing 30s stale path still recovers — we never regress to a
  permanent hang; worst case is today's behavior.

The 5s ceiling is an *upper* bound on patience, not a license to trip early — the
corroboration gate is what makes early recovery safe.

### Schema impact

**None.** This change touches only cross-process **notification** plumbing
(ping/pong) and the **`PipelinePhaseProjection`** App Group blob *as read by the
keyboard via the existing channel*. No `@Model` fields added/removed/renamed, no new
`@Model` entities, no `JotSchemaVN` change, no `MigrationStage`. The projection is a
JSON blob in `UserDefaults`, not SwiftData.

### Test plan (on-device)

Per project memory, **intermittent states need MULTIPLE repros** — run each
kill-mid-recording case several times; a single "recovered" or "hung" snapshot is one
run of a race, not the whole bug.

1. **Dead-app Stop.** Start a recording from the keyboard, kill the main app (Xcode
   stop / induce jetsam) mid-recording, tap **Stop** → keyboard recovers to idle in
   **≤5s** (target sub-second), not ~30s. No zombie "recording" chrome, no stuck
   disabled speak button. Repeat ≥3×.
2. **Dead-app Pause / Cancel / Delete.** Same kill, then tap each control → each
   recovers cleanly to idle within the ceiling. Repeat each ≥3×.
3. **Happy path unchanged (app alive).** App foregrounded/backgrounded-but-alive:
   Stop → transcript finalizes and **auto-paste still lands at the cursor**; Pause →
   Resume works; Cancel discards. Verify the ping/pong adds no perceptible latency.
4. **Slow-but-alive must NOT be killed.** Force a busy main app (heavy ANE /
   rewrite load) so heartbeats stretch to 11–29s between beats while the recording is
   genuinely live; tap Stop → must route to the alive path (or fall back to the
   backstop), and must **never** tear down the live recording / lose audio. Run
   multiple times.
5. **Warm-hold + cold-start untouched.** Re-run a warm-resume mic tap and a cold
   keyboard Dictate start — both behave exactly as before.
6. **Dismiss / re-present mid-recovery.** Kill the app, tap Stop, then dismiss the
   keyboard (switch input mode) during the verdict and re-present → recovery still
   completes; keyboard shows idle, not a stale recording.

### Risks

- **Latency on the happy path.** Adding a ping wait before every control tap adds up
  to ~120ms (or ~240ms with a retry) before the Darwin request posts. Mitigation: on
  the *first* pong the request fires immediately (no retry), so the alive case is
  ~120ms worst-case — imperceptible, matching the existing start handshake budget.
- **Coalesced Darwin posts.** Darwin notifications coalesce; the ping nonce + a single
  retry handle a dropped round-trip, but tune retry timing on-device.
- **Heartbeat-cadence mismatch.** The projection heartbeat is 10s
  (`PipelinePhaseProjection.swift:52`), coarser than the warm-hold 1s heartbeat used
  by the ghost check. The ~11s freshness window is the analog; validate on-device that
  a healthy busy recorder never exceeds it long enough to combine with a pong miss.
- **Pending-paste cleanup on a dead Stop.** Stop arms a pending-paste session before
  the verdict (`:1732`); a dead verdict must clear it (step 3) or risk a stray paste
  on the next launch. Cover in test 1.

### Open questions (genuine)

1. **"Delete" control identity.** There is no `deleteRequested` notification; the
   recording-discard action is Cancel/`forceStop`. Confirm with the CEO which
   on-screen control is labeled "Delete" so it routes through the right handler
   (assumed: it == the Cancel/discard control).
2. **Retry count / windows.** Recommended one retry of ~120ms each. Is a single retry
   enough on-device, or should the window widen slightly (e.g. 150–200ms) to absorb
   MainActor scheduling jitter on a backgrounded keyboard host? Tune empirically.
3. **Heartbeat freshness threshold.** ~11s proposed (one 10s beat + jitter). Confirm
   against real busy-ANE traces that a healthy recorder's beat never drifts past it
   simultaneously with a pong miss.
