# Voice-clone capture via the shared mic pipeline (no second recorder)

## Problem
The TTS Lab "clone my voice" recorder uses a **separate `AVAudioRecorder`**
(`SampleRecorder` in `VoiceCloneRecorderView.swift`). When **warm-hold** is
active, `RecordingService`'s mic engine is already running on the input — so the
clone recorder is a **second recorder contending for the same mic**. Observed
symptom: a 30 s take is captured as ~0 s ("too short — record at least 8s") and
discarded.

Owner decision (2026-06-21): **reuse the one recording pipeline** for both
dictation and cloning — same mic, same engine, instant start from warm-hold —
instead of a competing recorder.

## NON-NEGOTIABLE invariants (the review must attack these)
- **I1 — Warm-hold is sacred.** Entering warm-hold, the heartbeat task, the
  App-Group keys (`warmHoldExpiresAt`, `warmHoldHeartbeat`), expiry, cooldown,
  and instant-start MUST behave identically after this change. Clone-capture
  must never `forceStop`/`cancel` warm-hold.
- **I2 — Dictation slice/transcription path is byte-for-byte unaffected.**
  `AudioTapRouter.route()`'s slice routing (`capture.ingest` → `streamingQueue`)
  must be unchanged; no added per-buffer cost when not cloning.
- **I3 — Exactly one engine on the mic, ever.** No new contention.
- **I4 — The dictation engine slot (`self.engine`) is never mutated by
  clone-capture.** (See design choice below.)
- **I5 — Concurrency-safe.** The tap thread writes the WAV; the main actor
  starts/stops. No race that writes to a closed file or drops the tail.
- **I6 — "Never force-stop the mic"** (standing rule) — gentle teardown only.
- **I7 — Clone-capture cannot run during an active dictation recording**
  (the clone sheet lives in Settings; guard anyway).

## CHOSEN DESIGN (after adversarial review — 2026-06-21)

Two independent adversarial reviews (warm-hold/lifecycle lens + concurrency lens)
**both rejected reusing the live warm engine** (a tee or any keep-alive). The
fatal problems they verified against the code:
- The warm engine is torn down mid-take by **five** existing paths —
  `handleInterruption`, `handleRouteChange`, `handleEngineConfigChange`,
  `handleWarmHoldDefaultsChange` (all `if isWarm { exitWarmHold() }`), plus the
  warm-idle audio-yield that DELIBERATELY makes the idle session interruptible.
  → WAV truncates → reproduces the exact "30s → too short" bug.
- The warm cooldown is a one-shot `Task.sleep` captured at `enterWarmHold`, NOT a
  re-checked deadline — pushing `warmExpiresAt` out does nothing; a botched
  extension can wedge warm-hold ON forever (keyboard misreads the mic as hot).

**Owner decision: the "Safe: stand warm-hold down + isolated recorder" option.**

### What we actually do (minimal, RecordingService UNTOUCHED)
`SampleRecorder.start()` calls **`RecordingService.shared.releaseWarmHold()`**
FIRST — the exact gentle exit Ask's sheet-close already uses (no-op when not warm;
synchronous; stops the shared engine + `restoreSession()` before returning; never
`forceStop`). That stands the warm engine down so our isolated `AVAudioRecorder`
is the ONLY thing on the mic — honoring the owner's "one recorder, not two" point.
Then we record a 24 kHz mono WAV as before. Duration is measured from the **wall
clock** (record start→stop), never `AVAudioRecorder.currentTime` (unreliable
on-device — the original "too short" misread).

- **No `AudioTapRouter` change** (no `rawTap`) — the hot dictation path is
  byte-for-byte untouched (MF-3 moot).
- **No `cloneEngine`, no tee** — the WAV-close-vs-tap-write race (MF-1) and the
  warm-expiry race (MF-2) are dissolved: there is no shared engine to race.
- **Only interaction with the core: the existing public `releaseWarmHold()`** —
  a proven, already-shipping call path.
- **Trade-off (accepted):** the next dictation after closing the clone sheet
  cold-starts instead of warm-resuming — identical to today's behavior after Ask.
  For a Settings-buried clone (read a 3-sentence script), the spin-up is invisible.

### Re-entrancy / lifecycle (kept from review N1)
`cancelIfRecording()` already runs on `.onDisappear` and Close; the `maxSeconds`
auto-stop and `createVoice` paths stop cleanly. Double-`start()` is guarded by
`guard !isRecording`. No clone engine is left running in the background.

## Format
Tap delivers hardware-format buffers (e.g. 48 kHz, mono input). Write the WAV at
that format; PocketTTS's cloner accepts any sample rate. (Confirm channel count
≤ the cloner's expectation; downmix if stereo.)

## Risk areas the review MUST cover
1. Does the WARM-case warm-hold-keep-alive corrupt any warm-hold invariant (I1)?
   What if warm-hold expires the instant before/after begin? What if the user
   backgrounds the app mid-capture?
2. Is `cloneEngine` (COLD) truly isolated from `self.engine` + observers (I4)?
   Does `subscribeSystemObservers`/interruption handling assume a single engine?
3. Concurrency (I5): tap-thread writes vs main-actor `endCloneCapture` clearing
   `rawTap`/closing the file — any window to write a closed file or drop the tail?
4. Does adding `rawTap` to `route()` add measurable per-buffer cost on the hot
   dictation path (I2)?
5. Interruptions/route changes (calls, AirPods) during clone-capture — does the
   existing observer machinery do something to `self.engine` that breaks the
   clone tee or the WARM engine?
6. Re-entrancy: double `beginCloneCapture`, begin-without-end, dismiss-mid-capture.
