# Recording-State Coordination — Rearchitecture Design

**Status:** Design (read-only pass — no code changed). Branch `decouple-root-view`.
**Goal:** Replace the fragmented set of independently-written recording signals with ONE
authoritative, verified, app-owned record that is the keyboard's only source of truth.

This doc is code-grounded (file:line as of this branch) and written for an adversarial review.

---

## 0. Thesis

Recording state today has no single source of truth across the app↔keyboard process boundary.
The keyboard infers "what is happening" by reading **eight** independently-written signals and
combining them with **three** local timers and **several** local flags. Every desync bug
(false-warm no-audio, controls-hang-in-loading, open-app-on-every-stop) is a symptom of the
same root: *two processes each maintain their own model of recording state, and the models drift.*

`PipelinePhaseProjection` was an attempt at a single source of truth — and it is genuinely the
backbone we build on — but it is **not** authoritative today because:

1. It coexists with a parallel warm-hold signalling system (`warmHoldExpiresAt` +
   `warmHoldHeartbeat`) that the keyboard reads *instead of* the projection to make the
   warm-vs-cold decision.
2. Its liveness (`lastUpdatedAt` heartbeat) only runs during a **non-terminal pipeline phase**.
   The warm-idle window — the exact state the keyboard most needs to reason about — is `.idle`
   in the projection but "warm" in a *separate* heartbeat. Two heartbeats, two timers, two
   truths.
3. The keyboard layers its own liveness inference (ping/pong, dead-app watchdog, ghost cleanup)
   on top, because the projection alone can't tell it "is the writer alive *right now*."

The fix is to make the projection (renamed and evolved into a **RecordingRecord**) the *whole*
truth: it covers warm-idle as a first-class state, it carries its own liveness stamp at all
times, and the keyboard mirrors it for **every** decision — warm-vs-cold, UI, and recovery —
deleting its parallel inference.

---

## 1. Current-signal map (the tangle)

### 1.1 Every signal that participates in recording-state inference

| # | Signal | Type | Writer | Reader(s) | How it drifts |
|---|--------|------|--------|-----------|---------------|
| 1 | `pipelinePhase` projection (`PipelinePhaseProjection`) | App Group JSON | App `publishPipelinePhase()` (`RecordingService.swift:1805`) | Keyboard `KeyboardRecordingState`, `deadAppWatchdog` | Only updated on phase transitions + 3s heartbeat **while non-terminal**; warm-idle is `.idle` here. |
| 2 | `pipelinePhase.lastUpdatedAt` | field of #1 | App heartbeat task (`RecordingService.swift:1869`) | `PipelinePhaseProjection.read()` synth-`.failed` (`:94`); keyboard watchdogs (`:2158`) | Heartbeat stops at terminal (`stopHeartbeat`, `:1893`); a dead writer freezes it → 30s synth-failed. |
| 3 | `warmHoldExpiresAt` | App Group Date | `enterWarmHold`/`exitWarmHold` (`:1371`/`:1429`) | Keyboard warm gate (`:2502`); JotApp boot reset | Ghost survives a jetsam (cleared only opportunistically by the keyboard at `:2533`). |
| 4 | `warmHoldHeartbeat` | App Group Date | `warmHeartbeatTask` ~1s (`:1377`) | Keyboard warm gate ≤4s (`:2505`) | A SECOND liveness clock, valid only in warm-idle; its freshness window (4s) differs from #2's (30s) and from ping/pong (120ms). |
| 5 | `engine.isRunning` / `isTapInstalled` | in-process AVFoundation | iOS / `installTap` | `start()` warm branch (`:606`), `enterWarmHold` guards | Reads **stale-true** after a background HAL teardown → false-warm dead engine (Bug 1). |
| 6 | keyboard `stopRequestPosted` | keyboard local `Bool` | keyboard at Stop (`:2604`) | `decideMicTap` (`:2404`), render gate | Cleared only when projection moves off `.recording` (`:2082`); lingers if the Darwin post is dropped (750ms resync is the band-aid). |
| 7 | `keyboardForegroundPing` / `appForegroundPong` | Darwin signals | keyboard / app | keyboard `resolveForegroundThenStart` 120ms (`:2431`) | Pong gated on `applicationState != .background` (`JotApp.swift:98`) → a backgrounded-but-alive app never pongs → keyboard URL-bounces and **opens the app on every stop** (the regression). |
| 8 | `appForegroundHeartbeat` / `isJotAppForeground()` | App Group Date, 2.5s | `JotApp` 1s timer (`:653`) | keyboard warm gate inline-vs-resume (`:2519`), W5 | A third foreground clock, distinct from ping/pong and from #4. |
| 9 | `streamingLoadingVariantLabel` / `streamingLoadStartedAt` / `streamingLoadEstimateSeconds` | App Group | `setBatchKeyboardLoadingLabel` (`:473`) | keyboard loading strip | Cleared on terminal teardown paths; a missed clear leaves a stale "Loading…" into the next warm session. |
| 10 | `streamingPartialText` | App Group String | `StreamingPartial` | keyboard strip mirror | Orthogonal to phase; can show text while phase says `.idle` across a race. |
| 11 | `TerminalSessionLog` | App Group JSON ring | `publishPipelinePhase` terminal (`:1830`) | keyboard pending-paste cleanup | A second terminal channel beside the projection's terminal phase. |
| 12 | `pendingPasteSession` | App Group JSON | keyboard at Stop/cold-start (`:1381`) | keyboard launch-deadline; app `ClipboardHandoff` | Independent 15s deadline timer; UUID-matched to the projection's `sessionID`. |

### 1.2 Keyboard local lifecycle state (mirrors that can diverge)

- `stopRequestPosted` (#6 above).
- `deadAppWatchdogTask` — 5s `controlTapLivenessCeiling` armed on every control tap
  (`:2156`), baseline = projection `lastUpdatedAt`; on no-advance + still-active →
  `recoverFromUnresponsiveApp` (`:2198`) which tombstones the frozen session in
  `hub.recoveredZombieFreeze` and resets local UI.
- `pipelineStaleDeadlineTask` — arms off `lastUpdatedAt + 30s + 2s`; re-reads to pick up the
  synth-`.failed`.
- `pendingLaunchDeadlineTask` — 15s cold-launch ceiling tied to `pendingPasteSession`.
- `foregroundPongReceived` / `pendingForegroundPing` — one-shot ping/pong latches.
- `isAutoPasteInsertInFlight`, `inFlightPasteSession*`, `autoPasteAttempted` — paste-delivery
  state (NOT recording-state per se; out of scope but they read the projection's `sessionID`).

### 1.3 The lifecycle end-to-end (both processes)

**Cold start (keyboard, Jot backgrounded):**
keyboard `handleMicCTATap` → warm gate fails (#3/#4) → `decideMicTap` = `.start` →
`resolveForegroundThenStart` posts ping (#7) → 120ms no pong → `startColdViaURLBounce`
writes `pendingPasteSession` (#12) + opens `jot://dictate?session=` →
`JotApp.onOpenURL` stashes `pendingKeyboardSessionID` → `triggerAutoStart` →
`recordingService.adoptSession` + `start()` → `publishPipelinePhase(.recording)` (#1) +
3s heartbeat (#2) → keyboard wakes on `pipelinePhaseChanged`, mirrors `.recording`.

**Warm resume (keyboard, Jot backgrounded, warm window open):**
warm gate passes (#3 future AND #4 ≤4s AND NOT `isJotAppForeground()` #8) → posts
`warmResumeRequested` → `JotApp` observer (`:103`) clears `ownsActiveRecording`, calls
`start()` → warm branch (`:605`) checks `engine.isRunning`/`isTapInstalled` (#5) →
`startFromWarmHold` restores `.mixWithOthers`, **awaits first routed buffer** (`:797`, the
Bug 1 gate) → only then `publishPipelinePhase(.recording)`.

**Stop (keyboard):**
keyboard writes `pendingPasteSession`, sets `stopRequestPosted` (#6), posts `stopRequested`,
arms `deadAppWatchdog` (5s) → `JotApp` `handleStopRequested` (`:1109`): bails if
`ownsActiveRecording`; bails+clears if no pipeline active; else `stopAndPublish` →
`publishPipelinePhase(.transcribing → … → .idle)`. Keyboard clears `stopRequestPosted` when
the projection leaves `.recording` (`:2082`); if the writer is silent, the 5s watchdog recovers.

**Warm-idle window:** projection = `.idle` (#1, heartbeat #2 stopped), warm signalled ONLY by
#3/#4. This is the seam where warm and phase are two separate truths.

---

## 2. Target model — the RecordingRecord

### 2.1 One record, written atomically, app-owned

Evolve `PipelinePhaseProjection` into **`RecordingRecord`** (same App Group key, same
write/read/reset shape, same "Darwin signals only say re-read" contract — so this is an
*evolution*, not a parallel system). It absorbs warm-hold and liveness so there is exactly one
blob to read.

```swift
struct RecordingRecord: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case idle          // nothing in flight, mic cold
        case warmIdle      // post-stop warm-hold window; mic warm, NOT capturing  (was: implicit, signalled by warmHoldExpiresAt)
        case arming        // start requested, engine coming up, first buffer NOT yet confirmed  (NEW — the verified-recording gate state)
        case recording     // VERIFIED live capture (first real buffer confirmed)
        case paused        // sub-state of recording; mic warm, slice gated
        case transcribing  // post-stop tail
        case processing
        case cleaning
        case rewriting
        case publishing
        case failed        // terminal, pre-publish failure
    }

    let state: State
    let sessionID: UUID?
    let recordingStartedAt: Date?   // pause-aware, as today
    let warmExpiresAt: Date?        // non-nil ONLY in .warmIdle; folds in the old warmHoldExpiresAt
    let liveness: Date              // monotonic-ish wall-clock stamp, refreshed on a SINGLE cadence in EVERY non-idle state
    let failureReason: String?
}
```

Key shape changes vs. today's `PipelinePhaseProjection`:

- **`warmIdle` is a first-class state**, carrying `warmExpiresAt` *inside the record*. The
  separate `warmHoldExpiresAt`/`warmHoldHeartbeat` keys (#3/#4) are deleted.
- **`arming`** is the verified-recording gate made explicit (see §2.3).
- **`liveness`** is a single stamp refreshed on ONE cadence in *all* non-`idle` states —
  including `warmIdle`. This is the one heartbeat (replaces #2 *and* #4).

### 2.2 Liveness baked into the record (one heartbeat to rule them all)

Today there are three liveness clocks (#2 pipeline heartbeat, #4 warm heartbeat, #8 foreground
heartbeat) plus a 120ms ping/pong. Collapse to ONE: while the record is in **any** non-`idle`
state, the app refreshes `liveness` every `livenessInterval` (e.g. 1s — fast enough that the
keyboard's freshness windows are generous) on a single owned task. `idle` carries no liveness
(nothing to keep alive; a stale `idle` is still `idle`).

The keyboard reads `state` + `liveness` **together, atomically** (one JSON blob, no torn read).
"Is the writer alive?" = `now − liveness < livenessFresh` (single threshold, e.g. 3–4s). This
is the same question ping/pong asks, answered from the record instead of a round-trip — so
**ping/pong (#7), the foreground heartbeat (#8), and the warm heartbeat (#4) all disappear.**

`read()` keeps the existing dead-writer synthesis but generalized: a non-`idle`, non-terminal
record whose `liveness` is older than `livenessStaleThreshold` reads as `.failed` (recording/
tail states) or as `.idle` (warmIdle — a dead warm writer is simply not warm anymore). Storage
is never mutated by the reader (writer-owns-clears, unchanged).

### 2.3 VERIFIED semantics — `recording` means audio is live

Generalize Bug 1's first-buffer gate into the model as an invariant:

> **The record advertises `recording` only after a real first audio buffer is confirmed for
> the current session.** Between "start requested" and "first buffer confirmed" the record is
> `arming`.

**The concrete cold gate (M1 — this is the load-bearing change).** Today the cold path is
*not* gated: `start()` runs only a channels/sampleRate preflight
(`RecordingService.swift:650-654`) — which misses the stale-HAL case where the bus reads a
plausible format but the engine never delivers a buffer — then publishes `.recording`
immediately after `engine.start()` (`RecordingService.swift:712`), with **no buffer await**.
Only the warm path waits (the first-buffer latch at `RecordingService.swift:797-815`). We
generalize that warm-only latch into ONE unified gate used by BOTH `start()` and
`startFromWarmHold`:

1. `beginSlice` so `AudioTapRouter.route(_:)` is live, then **arm the first-buffer latch BEFORE
   `installTap`/`engine.start()`** (today `installTap` is `:670` and `engine.start()` is `:674`),
   so a buffer that arrives the instant the engine starts can't be missed.
2. Publish **`arming`** (not `recording`) right where `start()` currently publishes `.recording`
   (`:712`).
3. `await awaitFirstRoutedBuffer(timeout:)` — the exact mechanism warm-resume already uses
   (`:839`, `FirstBufferLatch`, `AudioTapRouter.armFirstBufferSignal`). The healthy case resolves
   in a few ms.
4. On first buffer → publish **`recording`**. On timeout → publish **`failed`** + the gentle
   teardown the warm path already does on `warmNoInput` (`clearActiveSliceRouting` +
   `fullyTeardownEngine`, `:804-806`) — never `forceStop` (honours the never-force-stop rule).

One gate, cold + warm, same latch. The keyboard renders `arming` as "starting…" (a brief
spinner, not the live mic-active UI), so it never shows "Listening…" against an engine that
delivers silence. This is **what makes false-warm impossible by construction** — and it now
also closes the cold stale-HAL case the channels/sampleRate preflight misses today.

This makes **false-warm no-audio impossible by construction**: the keyboard's "recording"
UI is reachable only via a record state the app sets *after* confirming a buffer, on every
start path.

### 2.4 The keyboard mirrors the record for ALL THREE decisions

**(a) Warm-vs-cold start decision.** Today: read #3/#4/#8 + 120ms ping/pong. Target: read the
record once.

```
on mic tap, decideStart(record, now):
  fresh = record != nil && now - record.liveness < livenessFresh
  switch (record?.state, fresh):
    .recording/.paused/.arming/<any in-flight>, fresh   -> .stop      (request a stop)
    .warmIdle,  fresh, warmExpiresAt > now               -> .warmResume
    .idle | nil | !fresh                                 -> .cold      (URL bounce)
```

The inline-vs-cold distinction (the only thing ping/pong genuinely decided) becomes: if the
record is `warmIdle`/`recording` and fresh, the app is alive and servicing Darwin — no URL
bounce. "Is Jot the foreground host?" (the W5 wizard inline case) is the ONE residual use of
a foreground signal; keep a *single* `isJotAppForeground()` for **that wizard case only**,
explicitly scoped, not on the hot stop/start path.

**(b) Recording/loading UI.** `KeyboardRecordingState` derives everything from the record:
`isRecording = state ∈ {recording, paused}`; `arming → starting spinner`;
in-flight tail → post-recording spinner; `warmIdle/idle → home`. Loading label keeps using
`streamingLoadingVariantLabel` (#9) — that's a display detail, not recording-state truth — but
could later fold into the record as `state == .arming` + an estimate field.

**(c) Recovery.** "Writer dead" = `record.liveness` stale (single check). The keyboard's
`recoverFromUnresponsiveApp` becomes: on a control tap, if after `livenessFresh` the record is
still non-terminal AND `liveness` hasn't advanced → reset local UI to `idle`. **Same predicate
as the start decision** — no separate ping/pong, no 5s control-tap ceiling distinct from the
heartbeat window. `recoveredZombieFreeze` tombstoning still applies (a dead writer never goes
terminal) but keys off the unified record.

**Genuinely-suspended-app reconciliation (M2 — the orphan must not be silently abandoned).**
"Reset local UI to `idle`" fixes the *keyboard's* view, but a genuinely-suspended (not dead)
app may still hold a live mic and an un-finalized session that the keyboard's local reset does
NOT touch — abandoning it would leak the orange indicator + drop captured audio. The app, not
the keyboard, owns reconciliation, and it does so via state that already exists:

- **Authoritative trigger = the record itself.** On the app's next foreground (`scenePhase →
  .active`, `JotApp.swift:519`), it reads its OWN `RecordingRecord`. If the record is non-`idle`
  with stale `liveness` (i.e. it was suspended mid-session), the app finalizes the orphan: drain
  the open slice through the normal pipeline if samples exist (the `internalStop` /
  `RecordingPipelineDispatch.publishAfterInterruption` path the interruption handler already
  uses, `RecordingService.swift:2415`), else publish a terminal record. This is the same
  next-foreground drain pattern as `PendingShareDrainer` / `VocabularyAddInbox` (`JotApp.swift:
  519+`) — reuse it, don't invent a new one.
- **Paste-side cleanup = existing `pendingPasteSession` + `TerminalSessionLog`.** The keyboard's
  pending paste for the orphaned session is cleaned exactly as today: when the app finalizes it
  writes a `TerminalSessionLog` entry (UUID-matched), and the keyboard's launch/stale-deadline
  consumes it — no new channel.
- **Do NOT reintroduce app-wake on the common path.** A backgrounded-ALIVE app stamps `liveness`
  within the window and advances the record over Darwin fine — it is never classified stale, so
  it is never reconciled and never woken. Reconciliation fires ONLY for the genuinely-stale
  record, and it **prefers the next-foreground drain over an active wake** (an audio-session
  resurrection from a suspended process is fragile and is the very `after-life.interrupted`
  zombie risk `restoreSession` guards against, `RecordingService.swift:1509+`). The mic was
  already lost when iOS suspended us; we finalize the captured audio on return, we don't try to
  resurrect the capture.

### 2.5 Controls are requests that resolve on the app's ack

Stop/Pause/Cancel/Resume stay Darwin signals ("requests"), but resolve **only when the record
advances** to the expected next state (the app's ack), never on a local flag or a local timer
for *correctness*:

- Stop request resolves when `state` leaves `{recording, paused}` (→ `transcribing`/`failed`/`idle`).
- Pause resolves on `→ paused`; Resume on `→ recording`; Cancel on `→ idle`/`warmIdle`.
- `stopRequestPosted` (#6) is **deleted** as a correctness signal. The keyboard's "stop pending"
  UI derives from "I posted a stop AND the record still shows `recording`" — a *view* of the
  record, not an independent flag that can linger.
- **No app-wake on no-ack.** A backgrounded-alive app services Darwin and advances the record
  fine; the keyboard never opens the app on a control path. The only "recovery" is the liveness
  staleness check in §2.4(c), which resets *local UI* — it does not bounce a URL.

This makes **controls-hang-in-loading impossible by construction**: the keyboard's loading/
recording UI is a pure function of the record; once the app advances the record (which a
live backgrounded app always does), the keyboard re-renders. If the app is genuinely dead,
`liveness` goes stale and the same function yields `idle`.

And **open-app-on-every-stop impossible by construction**: there is no ping/pong on the control
path, so "backgrounded" can never be misread as "dead." Liveness is read from the record the
backgrounded app is actively stamping.

---

## 3. How the three bug classes become impossible

| Bug class | Today's cause | Eliminated by |
|-----------|---------------|---------------|
| **False-warm no-audio** | `engine.isRunning` reads stale-true; `.recording` advertised against a dead engine | §2.3 — `recording` is published only after first-buffer confirmation; until then `arming`. Keyboard's live-mic UI is unreachable without a confirmed buffer. |
| **Controls-hang-in-loading** | keyboard loading flag (`stopRequestPosted`) disagrees with app's terminal phase; cleared only on a possibly-dropped notification | §2.5 — UI is a pure function of the record; no independent flag to disagree. Live app advances record → re-render; dead app → stale liveness → idle. |
| **Open-app-on-every-stop** | "no pong" (= backgrounded) misread as "app dead" → URL bounce | §2.4/§2.5 — ping/pong deleted; liveness read from the record the backgrounded-alive app keeps stamping. No app-wake on any control path. |

---

## 4. What collapses vs. what stays

**Deleted:** `warmHoldExpiresAt` (#3), `warmHoldHeartbeat` (#4) + its task, `keyboardForegroundPing`/
`appForegroundPong` (#7) + the gated pong, `appForegroundHeartbeat`/`isJotAppForeground()` on the
hot path (#8 — retained only for W5 wizard), keyboard `stopRequestPosted` as a correctness flag
(#6), the 120ms pong timer, the 5s control-tap ceiling as a *separate* predicate (folds into the
single liveness window).

**Stays / evolves:** `PipelinePhaseProjection` → `RecordingRecord` (#1, the backbone). Single
liveness task (#2 + #4 merged). `pendingPasteSession` + its 15s launch deadline (#12 — that's a
*paste-delivery* deadline, orthogonal to recording-state; keep it but key its proof-of-life off
the record's `sessionID`). `TerminalSessionLog` (#11) — keep as the auto-paste cleanup channel
(could later be derived from terminal records, but out of scope). `streamingLoadingVariantLabel`/
`streamingPartialText` (#9/#10 — display projections, not state truth). The Bug 1 first-buffer
machinery (`awaitFirstRoutedBuffer`, `FirstBufferLatch`, `AudioTapRouter.armFirstBufferSignal`) —
**promoted from a warm-only patch to the universal `arming → recording` gate.**

**How the 199-era stopgaps fold in:**
- *First-buffer gate* (`:797`) → becomes the `arming → recording` transition (§2.3), now on cold too.
- *Terminal-publish on stop-throw/force-stop/internalStop* (`:1302`/`:1715`/`:2372`) → unchanged
  in spirit; they publish a terminal record. The keyboard no longer needs the watchdog to *infer*
  these because liveness + state cover it, but keeping the explicit terminal write is strictly better.
- *Dead-app watchdog* (`:2156`) → simplified to the single liveness-staleness check (§2.4c) for
  the keyboard's LOCAL UI; the genuinely-suspended orphan (held mic / un-finalized session) is
  reconciled app-side on next foreground (§2.4 M2). `recoveredZombieFreeze` tombstone stays.
- *Ghost warm-hold cleanup* (`:2533`) → gone; `warmIdle` with stale liveness simply reads as
  not-warm via `read()`.

---

## 5. Migration (strangler-fig, safe-first, for an away owner on TestFlight)

**Constraint shaping this ordering:** the owner is away and gates on device/TestFlight (sim can't
exercise cross-process); they can install a build and send back device logs, but can't sit in a
tight iterate loop. So the migration is split into **two TestFlight builds**:

- **Build A = SAFE + high-value + evidence-gathering.** Every change is LOW behavior risk: it
  either changes nothing the reader acts on, or it eliminates false-warm (a strict improvement),
  or it only *logs*. Crucially it ships the **shadow decision logging** so the owner's normal use
  produces the evidence we need to de-risk Build B.
- **Build B = the risky reader-flips.** Ships ONLY after Build A's device logs show the shadow
  decision agreed with the live path across real cold/warm/inline/stop sessions on the owner's
  device.

Each lettered step below is independently revertable and leaves the system correct.

### Build A — safe, ships first

**A1 (M3, ship FIRST) — keyboard tolerates the new states as idle.** Before the app ever writes
them, make the keyboard's reader total over unknown/new states. Today
`KeyboardStreamingHub.applyPipelineProjection` switches over the phase enum with NO default arm
(`KeyboardStreamingHub.swift:60,69-88`), so a `warmIdle`/`arming` blob would not be handled.
A1 makes the keyboard treat any state it doesn't yet act on (`warmIdle`, `arming`, future) as
`idle`/home. *Pure reader-tolerance; the app still writes only today's states, so this is a
no-op at runtime until A2 — but it MUST land first so A2's superset write can't surface an
unhandled state.* This is why Step 0 is NOT zero-behavior-change as originally written: writing
`warmIdle` changes what `read()` returns during warm, and the old keyboard didn't handle it.

**A2 — app writes the superset (state incl. `warmIdle`/`arming` + `liveness`) in the same blob.**
App publishes `warmIdle` (with `warmExpiresAt`) at `enterWarmHold`, and stamps `liveness` on a
single 1s task in ALL non-idle states (incl. warmIdle) — *in addition to* the existing
`warmHoldExpiresAt`/`warmHoldHeartbeat`/pipeline-heartbeat (still written, still read). Keyboard
(post-A1) tolerates the new states as idle, so behavior is unchanged; the record now reflects
warm reality. Verify: Diagnostics dump shows `warmIdle`+fresh `liveness` across a warm window.

**A3 (M1) — the unified cold+warm first-buffer `arming → recording` gate.** Implement §2.3:
arm the first-buffer latch before `installTap`/`engine.start()`, publish `arming`, await first
routed buffer, → `recording` on buffer / → `failed` + gentle teardown on timeout, on BOTH
`start()` and `startFromWarmHold`. Keyboard (post-A1) renders `arming` as idle/home for now (it
doesn't yet have the spinner UI — that's N4/Build B), so the only visible change is that a
stale-HAL cold start now fails cleanly instead of advertising a dead "Listening…". **This is the
step that eliminates false-warm, and it is safe to ship early** because it only ever *withholds*
a `recording` the engine can't back. Verify: airplane / mic-busy cold start shows a clean
failure, never a live mic into silence; healthy cold/warm start still records normally.

**A4 (de-risk) — shadow decision logging.** On every mic tap, the keyboard computes
`decideStart(record)` (§2.4a, against the new record) and writes it to `DiagnosticsLog` next to
the decision the OLD path actually executed (warm-gate / ping-pong result). The keyboard still
EXECUTES the old path — the shadow is log-only. Likewise log the shadow recovery verdict on
control taps. Verify: across the owner's real cold / warm-backgrounded / inline-foreground / W5 /
stop-while-backgrounded sessions, the log shows `shadow == live` (and, where they differ, which
input diverged). This is the evidence gate for Build B.

### Build B — the reader-flips, ships only after Build A logs confirm

**B1 (was Step 1, highest risk) — flip warm-vs-cold onto `record.liveness`; delete ping/pong.**
Replace the warm gate (#3/#4) and `resolveForegroundThenStart` (#7) with `decideStart(record)`.
**Gate: ship only after A4's logs show the shadow agreed on the owner's device.** Retain ONE
`isJotAppForeground()` read for the W5/in-Jot foreground case (see §6 / N3). Verify the full
start matrix; stop-while-backgrounded must NOT open the app.

**B2 (N4) — the real `arming` keyboard UI.** Add the `arming` case + starting-spinner to
`KeyboardRecordingState` and a `failed`-mirror for the arming-timeout, wiring through
`KeyboardStreamingHub` (`:34-41` in-flight set, `:60-88` projection apply) and `KeyboardView`
(the mic-CTA states near `:691`/`:756`/`:1155`). Until B2, `arming` rendered as idle (A1); B2
gives it its own "starting…" affordance.

**B3 (was Step 3) — controls resolve on record advance; delete `stopRequestPosted` as a flag.**
Keyboard derives stop-pending UI from the record; recovery uses the single liveness check (§2.4c)
+ the app-side reconciliation (§2.4 M2). Verify: stop/pause/cancel/resume with Jot backgrounded
resolve via record advance; kill the app mid-recording → keyboard resets to idle on the liveness
window (no URL bounce) AND the app finalizes the orphan on next foreground.

**B4 — remove the dead keys.** Delete `warmHoldExpiresAt`/`warmHoldHeartbeat`/ping-pong/
foreground-heartbeat-on-the-hot-path writers + the shadow logging (keep one `isJotAppForeground`
for W5). Final cleanup; verify the full matrix once more.

Each step ships behind no flag (pre-launch migration discipline — no users), but is staged so a
regression is bisectable to one lettered step.

---

## 6. Highest risk + mitigation

**Highest-risk step: B1 (warm-vs-cold decision moves to the record's liveness).** It changes the
routing of *every* keyboard mic tap, and the failure mode is user-visible and severe (tap does
nothing / opens the wrong surface / records inline when it should cold-start). This is precisely
why it is fenced behind Build A's shadow logs: **B1 does not ship until the owner's own device
shows `decideStart(record)` would have matched the live path.** The subtleties the shadow must
clear:

- **Backgrounded-alive liveness latency.** The old 4s warm window deliberately tolerated MainActor
  jitter on a backgrounded app (`JotKeyboardViewController.swift:2491`). The unified `livenessFresh`
  must keep that headroom (≥4s) or a healthy backgrounded warm app gets misclassified as dead and
  cold-starts (slow, not broken). Mitigation: size `livenessFresh` ≥ the worst-case stamp gap the
  A4 shadow logs reveal on the owner's device; keep the writer cadence at 1s.
- **The inline (foreground) case (N3 — accept the trade-off honestly).** Ping/pong's real job was
  "is Jot the foreground host → record inline." The record's `state`+`liveness` answers "app
  alive," NOT "app foreground." So B1 must retain a *single* `isJotAppForeground()` read for the
  W5/in-Jot inline branch (§2.4a) — without it, in-Jot dictation saves transcripts again (the
  exact regression the `JotKeyboardViewController.swift:2508` comment guards). **This is a
  deliberate partial revert:** ping/pong was introduced *because* the 2.5s `isJotAppForeground()`
  heartbeat read was stale-prone; B1 reverts that one branch to the stale-prone read. We accept
  it — it is scoped to the single foreground-host case (not the hot stop/start path), its failure
  mode is bounded (a W5/in-Jot tap mis-routes, recoverable), and removing the whole ping/pong
  tangle is worth it. We do NOT claim this branch is "strictly better" than ping/pong — only that
  the net architecture is.
- **Race at warm-window edge.** A tap as the warm window expires: old code had a ghost-cleanup
  branch. New: `read()` resolves a stale-`warmIdle` to not-warm; a fresh-`warmIdle` with
  `warmExpiresAt < now` routes cold. Deterministic from one blob, no cross-key tear.

Mitigation overall: Build A ships the writes + the false-warm fix + the shadow FIRST and is
verified on the owner's device *before* any reader flips, so by B1 we already have device
evidence the record reflects reality and the new decision agrees.

### 6.1 Nice-to-haves (folded into the plan)

- **N1 — 1s liveness across the full warm window is deliberate and free.** `liveness` ticks every
  1s for the whole ~60s warm-idle window. This is NOT a new cost: it exactly matches today's
  `warmHeartbeatTask` (`RecordingService.swift:1377`, also 1s for the warm window) — the two
  merge into one task. No battery/wake regression vs. shipping behavior.
- **N2 — paused frozen-elapsed math touches `lastUpdatedAt`.** The keyboard freezes the paused
  clock as `lastUpdatedAt − recordingStartedAt` (`KeyboardStreamingHub.swift:79`), paired with the
  app's per-heartbeat re-back-date (`RecordingService.swift:1916`). When the pipeline heartbeat
  cadence merges into the 1s `liveness` (A2), re-verify this freeze still reads correctly off the
  unified stamp — the cadence changes from 3s to 1s, so the re-back-date must move with it.
- **N3 — see the inline-case bullet above** (the accepted stale-read trade-off).
- **N4 — the `arming` keyboard UI is real work**, scheduled as B2: `KeyboardRecordingState` needs
  an `arming` case + spinner + a `failed` mirror for arming-timeout, wired through
  `KeyboardStreamingHub` (`:34-41`, `:60-88`) and `KeyboardView` (`~:691`/`:756`/`:1155`). Until
  B2, A1 renders `arming` as idle so A3 can ship the false-warm fix without blocking on UI.

---

## 7. Maintainability — the documented contract

Add to `ARCHITECTURE.md` (App entry & lifecycle + Keyboard rows) a single invariant block:

> **Recording-state contract.** `RecordingRecord` (App Group, app-owned) is the SOLE truth for
> cross-process recording state. The app is the only writer; it writes atomically and stamps
> `liveness` on one cadence in every non-idle state. The keyboard is read-only and derives
> *every* decision — warm-vs-cold, UI, recovery — from `(state, liveness)`. Darwin notifications
> are signals only ("re-read"), never truth. `recording` is published only after a confirmed
> first audio buffer (`arming` until then). Controls are requests that resolve when the record
> advances; nothing on a control path opens the app. New features that need recording state read
> the record — they MUST NOT add a parallel signal.

This converts "don't add signals to the tangle" from tribal knowledge into a stated rule.

---

## 8. Confidence

**Confidence the model eliminates the desync class: ~85%.** The three named bugs become
impossible *by construction* under §2–3, and the architecture removes the structural cause
(two processes, two models). The residual 15% is concentrated in Step 1's foreground-vs-alive
distinction and liveness-window tuning on real backgrounded processes — both empirical, both
de-risked by the Step-0-writes-first staging. No part of the design requires a capability iOS
doesn't already give us (it's all App Group + Darwin, exactly today's substrate), so there is no
feasibility risk — only tuning and migration-ordering risk.
