# TTS ⇄ Recording audio-session coordination

**Status:** design (do not implement yet)
**Owner:** audio subsystem
**Bug class:** shared `AVAudioSession` mutated by two uncoordinated subsystems → dictation intermittently fails after a read-aloud.

---

## 0. TL;DR

There is exactly one `AVAudioSession` per process (iOS-enforced). Two subsystems
mutate it and run their own `AVAudioEngine` graphs **with zero awareness of each
other**:

- **Read-aloud / TTS Lab** (`TTSService`) takes a `.playback` session and runs a
  player-node engine.
- **Dictation** (`RecordingService`) takes a `.record` session and runs a tap
  engine (with warm-hold keeping it idle-running).

`TTSService.speak()` guards *one* direction only — it refuses to start while the
mic is live. The **reverse** direction is unguarded: when TTS is mid-playback (or
its teardown hasn't completed) and a recording starts, `RecordingService.start()`
reconfigures the shared session to `.record` and starts its tap engine **while
TTS's `.playback` engine + session are still alive**. The two engines collide on
the one session and dictation captures silence / fails to start.

**Recommended fix:** a thin **`AudioSessionArbiter`** (one file, `@MainActor`)
that both subsystems notify on acquire/release, exposing a single
`yieldForRecording()` entry the recorder calls **before** `configureSession()`.
TTS registers a yield handler that stops its *own* playback (its existing
`stop()`), and nothing else. The arbiter is a **notifier/registry**, not a new
owner of category transitions — `RecordingService` and `TTSService` keep their
exact current session calls. This makes the yield a **genuine no-op when TTS is
idle** (no handler registered → nothing happens → warm-hold untouched) and adds
**zero work to the dictation hot path** (one MainActor call at start only).

---

## 1. Current ownership map — who mutates the shared `AVAudioSession`

Verified against code. Every site that calls `setCategory` / `setActive` or runs
an `AVAudioEngine`:

### 1.1 `RecordingService` (`Jot/App/Recording/RecordingService.swift`) — the `.record` owner

| Site | What it does | `file:line` |
|---|---|---|
| `configureSession()` | `setCategory(.record, .measurement, [.mixWithOthers])` then `setActive(true)`; stashes `priorCategory/Mode/Options` first | `1365`–`1402` (set at `1378`/`1384`) |
| `start()` | cold path → `configureSession()`, builds `AVAudioEngine`, installs tap, `engine.start()` | `576`–`699` (`configureSession()` at `611`) |
| `startFromWarmHold()` | warm path → `setCategory(.record, .measurement, [.mixWithOthers])` (restore mix), reuses the already-running engine/tap; **no `setActive`** | `701`–`763` (`setCategory` at `719`) |
| `dropMixWithOthersForWarmIdle()` | at warm entry → `setCategory(.record, .measurement, [])` (options-only, drops `.mixWithOthers` so another app's playback delivers an interruption) | `1306`–`1314` (`setCategory` at `1309`) |
| `restoreSession()` | `setActive(false, [.notifyOthersOnDeactivation])` + restore stashed prior category | `1404`–`1437` |
| `enterWarmHold()` | keeps engine **running idle** (tap installed, slice ended); arms cooldown; calls `dropMixWithOthersForWarmIdle()` | `1211`–`1261` |
| `handleInterruption(.began)` | warm → `exitWarmHold()` (yields mic); active → `internalStop()` | `1894`–`1917` |

Key invariant (already in this file's doc-comment at `87`–`124`): one process-wide
singleton `RecordingService.shared`, because the stash/restore of prior session
state must read/write the same slots across every surface.

### 1.2 `TTSService` (`Jot/App/TTS/TTSService.swift`) — the `.playback` owner

| Site | What it does | `file:line` |
|---|---|---|
| `activatePlaybackSession()` | `setCategory(.playback, .spokenAudio, [.duckOthers])` + `setActive(true)` | `529`–`533` (set at `531`/`532`) |
| `speak()` | guards `!RecordingService.shared.isRecording` at entry **and between chunks**; builds its own `AVAudioEngine` + `AVAudioPlayerNode`, activates playback session, synth+play loop | `346`–`454` (mic guard `350`, between-chunk re-check `408`) |
| `play()` | `engine.connect/prepare/start`, schedules buffer, `player.play()` | `469`–`499` (`engine.start()` `482`) |
| `deactivatePlaybackSession()` | `setActive(false, [.notifyOthersOnDeactivation])`; deliberately does **not** restore a "prior" category | `539`–`542` |
| `stop()` | bumps generation, `teardownEngine()`, `deactivatePlaybackSession()` | `459`–`464` |

Note `TTSService` **never stashes a prior category** and explicitly comments that
"if another Jot subsystem needs the mic next, it reconfigures the category from
scratch (RecordingService always sets `.record` on start)" (`535`–`538`). That
comment encodes the *intended* contract — but it only holds if TTS has finished
`stop()`-ing before the recorder configures. The bug is precisely that nothing
enforces that ordering.

### 1.3 `VoiceCloneRecorderView` (`Jot/App/TTS/VoiceCloneRecorderView.swift`) — clone-sample recorder

| Site | What it does | `file:line` |
|---|---|---|
| `record()` | `releaseWarmHold()` **first**, then `setCategory(.record, .default)` + `setActive(true)`, runs an `AVAudioRecorder` | `356`–`388` (`releaseWarmHold()` `364`, session `366`–`368`) |
| `stop()` / `cancelIfRecording()` | `setActive(false, [.notifyOthersOnDeactivation])` | `404`, `413` |

This surface **already coordinates** — it calls `RecordingService.shared.releaseWarmHold()`
before grabbing the session (project memory: *TTS Lab playback + voice clone*).
It is the precedent for the "yield before you take the session" pattern this
design generalizes. It is not the bug locus, but the arbiter should subsume its
ad-hoc `releaseWarmHold()` so all three subsystems share one protocol.

### 1.4 Ask — records, never plays

`AskView` drives capture through `InlineDictationSession` → `RecordingService`
(`AskView.swift:812`) and calls `recordingService.releaseWarmHold()` on
sheet-close (`AskView.swift:135`). **Ask does not call `TTSService` and plays no
audio** (grep: no `.speak(` / `TTSService` references in `App/Ask/`). So Ask is
purely a `RecordingService` client and needs no TTS-specific coordination — it is
covered by whatever protocol the recorder follows.

### 1.5 Summary — the three session-mutating actors

```
                 AVAudioSession.sharedInstance()  (one per process)
                 ┌──────────────┬──────────────────────┐
   .record  ◄────┤RecordingService│  .playback ◄────────┤ TTSService     │
   (+ warm idle) │  (singleton)  │  (.duckOthers)        │  (singleton)   │
                 └──────────────┴───────────────────────┘
                 .record ◄── VoiceCloneRecorderView (AVAudioRecorder)
                              already yields via releaseWarmHold()
```

Only **TTSService → RecordingService** is uncoordinated. That is the entire bug
surface.

---

## 2. The conflict — why TTS playback collides with a subsequent record (and why it's a race)

### 2.1 The two repros

1. **Cross-app (confirmed on-device):** play a voice (~18s) → switch to another
   app's Jot keyboard → tap Dictate. The keyboard remote-controls the main app to
   start a (cold or warm) recording while TTS's `.playback` engine + session are
   still alive. Diagnostics showed TTS `engine started` with **no `speak done`**
   before the keyboard's `sessionStarted` — TTS never yielded.

2. **In-app (same root cause):** in a transcript, tap Read-aloud, then tap the FAB
   to dictate before playback finishes. `startReadAloud` runs `speak()` on a
   detached `ttsReadTask` (`TranscriptDetailView.swift:509`–`528`); the FAB calls
   `RecordingService.start()`. No code on the record-start path tells TTS to stop.

### 2.2 Mechanism

`TTSService.speak()` only guards the mic-is-already-live direction (`350`,
`408`). Recording start does the inverse mutation with **no symmetric guard**:

- `RecordingService.start()` → `configureSession()` flips the **shared** session
  from `.playback` to `.record` and `setActive(true)` (`1378`/`1384`) while:
  - TTS's `AVAudioEngine` + `AVAudioPlayerNode` are still attached and (often)
    running (`play()` started them, `482`), and
  - TTS's `speak()` loop is still iterating chunks or awaiting a
    `.dataPlayedBack` continuation (`490`–`498`).

Two engines now hold render resources against one session whose category just
changed out from under the playback engine. The record engine's `inputNode`
can come up as 0ch/0Hz (the same failure `start()` already screens for at
`626`–`630` and surfaces as `.micUnavailable`), or `engine.start()` throws, or the
tap delivers silence. Result: **dictation intermittently fails.**

### 2.3 Why it's a race (intermittent, not deterministic)

The outcome depends on *where* the TTS `speak()` task is when the record-start
lands:

- **Between chunks / mid-synthesis:** TTS isn't holding the player render path at
  that instant → record may win → dictation succeeds. (This is why it's
  intermittent and easy to mistake for "fixed".)
- **Mid-playback (engine running, awaiting `.dataPlayedBack`):** TTS holds the
  active playback graph against the session the recorder just reconfigured →
  collision → dictation fails.
- **After `speak()` finished but before its generation-guarded teardown ran**
  (the `defer`/`if generation == speakGeneration` window, `371`–`373`,
  `448`–`453`): session still `.playback`/active.

Because both subsystems are `@MainActor`, they don't corrupt memory — but the
*ordering* of "record reconfigures session" vs "TTS engine still rendering" is
nondeterministic across the ~18s playback, which is exactly the
single-on-device-log-is-one-run-of-a-race caveat
(memory: *intermittent bug needs multiple repros*). A single "it worked" run does
**not** falsify the collision.

---

## 3. The right design

### 3.1 Design options considered

**(a) Central `AudioSessionCoordinator` that owns ALL category transitions.**
Both subsystems stop calling `setCategory`/`setActive` directly; every transition
goes through one arbiter with a priority model (record > playback). *Cleanest in
theory.* **Rejected** as the primary mechanism: it forces a rewrite of
`RecordingService`'s session plumbing — `configureSession`/`restoreSession`/the
warm-idle `dropMixWithOthersForWarmIdle`/`startFromWarmHold` mix-restore are
months of hardened, on-device-tuned state with subtle ordering and
`.mixWithOthers` semantics tied to the warm-hold interruption-yield. Moving those
calls behind a coordinator is high blast-radius for the sacred path the task
forbids us to disturb, and buys nothing the narrower protocol doesn't.

**(b) "Playback yields to recording" protocol — TTS observes a
recording-will-start signal and tears its own playback down.** The recorder emits
"I am about to take the mic"; TTS (and any future player) responds by stopping
*itself* with its own teardown. *Minimal, asymmetric, matches the real
dependency* (record is the higher-priority, latency-sensitive path; playback is
the disposable one). **Recommended**, refined below into a tiny arbiter so the
signal is one well-named call rather than another raw Darwin/NotificationCenter
string.

**(c) TTS handles `AVAudioSession.interruptionNotification` + app-background.**
Rely on iOS to interrupt TTS when the recorder activates `.record`. **Rejected as
the mechanism, kept as defense-in-depth.** Whether `.record` activation reliably
delivers a `.began` interruption to the in-process `.playback` engine is exactly
the kind of iOS-version-dependent behavior the warm-hold yield code already treats
as *advisory* — `RecordingService` itself doesn't trust interruptions to be
symmetric (it drops `.mixWithOthers` specifically to *provoke* an interruption for
the other-app case). We should not hinge dictation reliability on an
interruption that may not fire for a same-process player. (TTS adding an
interruption observer that calls its own `stop()` is a fine cheap backstop, but
not the contract.)

### 3.2 Recommended: `AudioSessionArbiter` (option b, as a thin registry)

A single new `@MainActor` type, e.g. `Jot/App/Recording/AudioSessionArbiter.swift`
(co-located with the recorder, which is the privileged client):

```
@MainActor
final class AudioSessionArbiter {
    static let shared = AudioSessionArbiter()

    // A playback subsystem registers a *yield* closure: "stop yourself, now."
    // Registration is the proof-of-ownership. No registrant ⇒ no-op.
    private var playbackYield: (() -> Void)?
    private var playbackOwnerLabel: String?

    func registerPlayback(label: String, yield: @escaping () -> Void) { … }
    func resignPlayback(label: String) { … }   // clears only if still owner

    /// Called by RecordingService BEFORE it configures the .record session.
    /// Synchronously runs the registered playback yield (if any), so by the
    /// time the recorder touches the shared session, no playback engine is
    /// alive. Genuine no-op when nothing is registered.
    func yieldForRecording() { playbackYield?() ; … }
}
```

**Wiring:**

- **`TTSService.speak()`** — on entry (right after the existing mic guard, before
  `activatePlaybackSession()`), call
  `AudioSessionArbiter.shared.registerPlayback(label: "tts") { [weak self] in self?.stop() }`.
  In `stop()` (and the `speak()` completion teardown), call
  `resignPlayback(label: "tts")`. The yield closure is **exactly TTS's existing
  `stop()`** — bump generation, `teardownEngine()`, `deactivatePlaybackSession()`
  (`459`–`464`). No new teardown logic; we are only making the recorder able to
  *trigger* it.

- **`RecordingService`** — add **one** call:
  `AudioSessionArbiter.shared.yieldForRecording()` at the very top of `start()`
  (before the `isWarm` branch, so it covers cold **and** warm resume), i.e. just
  after the `guard !isRecording` at `577`. This is the only recorder change.

- **`VoiceCloneRecorderView.record()`** — optionally route its existing
  pre-record `releaseWarmHold()` (`364`) through the same arbiter call for
  symmetry, so a future second player is also yielded. Not required for the bug;
  noted so the arbiter is the single chokepoint.

**Why a registry and not a bare notification:** the *presence of a registrant* is
the ownership signal. `yieldForRecording()` does literally nothing unless a
playback subsystem has an active registration — which is the property that makes
it provably safe for warm-hold (§4). A raw `NotificationCenter`/Darwin post would
fan out to a TTS observer that would then have to self-check "am I actually
playing?", reintroducing the same is-it-safe question the registry answers
structurally.

### 3.3 Ordering guarantee

`yieldForRecording()` is **synchronous** and runs *before* any session mutation in
`start()`. TTS's `stop()` is itself synchronous (`teardownEngine()` +
`deactivatePlaybackSession()` are synchronous; only the chunk *loop* is async, and
the generation bump makes it bail at its next checkpoint `405`/`408`/`429`). So
the sequence is deterministic:

```
RecordingService.start()
  └─ AudioSessionArbiter.yieldForRecording()
       └─ TTSService.stop()   // gen++, engine torn down, .playback deactivated
  └─ (isWarm? startFromWarmHold : configureSession)  // now safe: no playback engine
```

The in-flight `speak()` task, when it next reaches a generation check, observes
`generation != speakGeneration` and breaks without re-activating anything; its own
`if generation == speakGeneration` teardown guard (`449`) means it won't
double-deactivate the session the recorder now owns.

---

## 4. Warm-hold safety argument (the sacred constraint)

The task's two hard traps and how the design avoids each:

### 4.1 "Do not blindly `setActive(false)` when TTS isn't playing"

The design **never calls `setActive(false)` from the arbiter or from
`yieldForRecording()`**. The only deactivation that can happen is *inside TTS's
own `stop()`* (`deactivatePlaybackSession()`), and that closure is invoked **only
if TTS registered it**. TTS registers **only** inside `speak()` and resigns on
`stop()`/completion. Therefore:

- **TTS not playing (idle) ⇒ no registrant ⇒ `yieldForRecording()` is a pure
  no-op.** No `setActive(false)`, no `setCategory`, nothing. The recorder proceeds
  straight into its existing `configureSession()`/`startFromWarmHold()` path
  exactly as today.
- A warm-held / active record session is **never** touched by the arbiter, because
  `RecordingService` never registers a playback yield — it is a *caller* of
  `yieldForRecording()`, not a registrant. There is no code path by which the
  arbiter can deactivate a record session.

This is the structural "genuine no-op when TTS isn't the current audio owner"
property the task demands: ownership = an active registration, and only the
registrant's own teardown runs.

### 4.2 "Do not add per-buffer cost or new locks to the dictation hot path"

- `yieldForRecording()` is called **once**, at `start()` entry — not per buffer,
  not in the tap, not in `route(_:)`. The audio tap (`installTap` `1040`–`1072`,
  `AudioTapRouter.route` `2325`–`2339`) is **untouched**.
- The arbiter is `@MainActor`-confined; `start()` is already `@MainActor`. No new
  lock, no cross-thread synchronization, no atomics. The registry is a single
  optional closure read/written on the main actor.
- Warm-resume latency: `startFromWarmHold` is measured at 15–19ms; the added work
  when TTS *is* playing is one synchronous `TTSService.stop()` (engine stop +
  `setActive(false)`), which only runs in the collision case we are fixing — and
  when TTS is idle (the overwhelming common case) it is a single nil-closure check
  (~nanoseconds). **Zero regression to the warm-resume happy path.**

### 4.3 Interaction with warm-hold's own interruption yield

Warm-hold's mic-yield to *other apps* (drop `.mixWithOthers` → provoke
`interruptionNotification` → `exitWarmHold`, `1289`–`1314` / `1898`–`1905`) is
**orthogonal** and untouched: that path concerns *another process* taking the mic,
not in-process TTS. The arbiter only mediates in-process TTS↔record. We add no new
interruption handling to `RecordingService`; its `handleInterruption` stays
byte-for-byte the same.

---

## 5. Coverage — does it fix both repros?

| Repro | Fixed? | Why |
|---|---|---|
| **Cross-app** (play → leave → keyboard Dictate) | ✅ | Keyboard remote-controls the main app's `RecordingService.start()`. The new `yieldForRecording()` at `start()` entry runs TTS's `stop()` before `configureSession`/`startFromWarmHold`, so no `.playback` engine survives into the record path. Covers cold **and** warm (call is before the `isWarm` branch). |
| **In-app** (Read-aloud → FAB Dictate without leaving) | ✅ | FAB → `RecordingService.start()` → same `yieldForRecording()`. The detached `ttsReadTask`/`speak()` loop is generation-bumped by `stop()` and bails at its next checkpoint. |
| **Voice-prompt rewrite / Ask mic while TTS playing** | ✅ | Both go through `RecordingService.start()` (Ask via `InlineDictationSession`, voice-prompt via `VoicePromptCapture`), so both inherit the yield. |
| **TTS started while mic live** (reverse direction) | ✅ already | Unchanged — `speak()` keeps its `!isRecording` guard (`350`). The arbiter is additive, not a replacement for that guard. |

---

## 6. Invariants / risks for the reviewer to attack

1. **Synchrony of `TTSService.stop()`.** The safety argument assumes `stop()`
   fully relinquishes the session synchronously before `configureSession` runs.
   Verify `teardownEngine()` (`513`–`521`) + `deactivatePlaybackSession()`
   (`539`–`542`) have no async tail that lets the `.playback` engine outlive the
   call. (They appear synchronous; confirm `engine.stop()`/`detach` don't defer.)

2. **Generation-guard double-deactivate.** When the recorder yields TTS, the
   in-flight `speak()` task may *also* reach its completion teardown
   (`448`–`453`). Confirm the `if generation == speakGeneration` guard prevents a
   second `deactivatePlaybackSession()` that could fire `setActive(false)` *after*
   the recorder has activated `.record` — which would be the exact "blindly
   deactivate the record session" trap, just relocated into TTS. The generation
   bump in `stop()` should make this guard false, but this is the highest-risk
   interaction and must be traced.

3. **Re-entrancy.** `yieldForRecording()` → `TTSService.stop()` → `resignPlayback`
   mutates the registry while the arbiter is mid-call. Ensure `stop()`'s
   `resignPlayback` doesn't deadlock or clobber a registration the recorder is
   about to need (it shouldn't — recorder never registers).

4. **Registration leak.** If `speak()` registers but an early-return / throw skips
   `resignPlayback`, a stale yield closure lingers and a later `start()` would call
   a `stop()` on an already-idle TTS (harmless no-op, but confirm `stop()` is
   idempotent — it is: gen bump + teardown of nil engine). Prefer `defer`-based
   resign in `speak()`.

5. **Should the arbiter own category transitions after all?** If a future third
   audio subsystem appears (e.g. a notification chime, audio scrubbing in the TTS
   Lab), option (a) becomes more attractive. Reviewer should decide whether to
   build the registry now in a shape that can *grow* into a full coordinator
   (priority queue of claims) vs. keep it deliberately minimal. Recommendation:
   minimal now, but name/shape it so (a) is a non-breaking extension.

6. **VoiceClone double-yield.** If we route `VoiceCloneRecorderView` through the
   arbiter too, confirm its existing `releaseWarmHold()` + the arbiter call don't
   double-tear-down. (It records via `AVAudioRecorder`, not `RecordingService`, so
   it would *call* `yieldForRecording()` itself — verify it isn't also a
   registrant.)

7. **No features.md behavior change.** This is a correctness fix to an existing
   advertised contract ("TTS always yields to recording", features.md §13.2 /
   TTSService doc-comment `41`–`44`). No new user-facing behavior; features.md
   likely needs no edit, but the §13.2 "Yielding the mic" paragraph could gain a
   one-line note that read-aloud also yields to a new dictation. Reviewer to
   decide if that crosses the user-visible threshold.

---

## 7. Open questions

- **Q1.** Is `TTSService.stop()` provably synchronous w.r.t. session release? (risk
  #1) — needs a close read of `AVAudioEngine.stop()` semantics; if any teardown is
  deferred, the arbiter's yield may need to `setActive`-fence or the recorder may
  need a one-runloop hop (à la the keyboard proxy re-sync) before `configureSession`.
- **Q2.** Do we fold `VoiceCloneRecorderView` into the arbiter now (single
  chokepoint) or leave its working `releaseWarmHold()` alone (smaller diff)?
- **Q3.** Build the registry as a minimal single-yield now, or as a
  growable priority-claim coordinator (option a shape) to future-proof? (risk #5)
- **Q4.** Should TTS *also* add a cheap `interruptionNotification` observer that
  calls its own `stop()`, as belt-and-suspenders for any path that takes the
  session without going through `RecordingService.start()` (e.g. a future direct
  `AVAudioRecorder` caller)? Low cost, strictly additive.
</content>
