# Bug: keyboard-started dictation isn't reflected in the main app's home (shows idle until you tap Dictate)

> **Status: SYMPTOMS ONLY — recorded for later, NOT fixed.** (Captured 2026-06-03.)
> Intermittent / rare. Read-only investigation kicked off in parallel; cause TBD.

## Symptom (user-reported, on device — rare)

A dictation is **started from the keyboard.** But the **main app's home does NOT show
that a recording is in progress** — it renders its idle state (the "Dictate" affordance,
as if you could start a fresh dictation), instead of the live-recording indicator
(the "Recording" return pill + live preview row described in features.md §2.7 / §1.10).

Then, when the user taps **Dictate** in the main app, it does **not** start a new
recording — it **reveals / adopts the already-ongoing keyboard-started dictation** (shows
the current in-progress dictation).

So: keyboard starts a recording → main-app home looks idle → tap Dictate in the app →
it surfaces the recording that was already running. The home should have reflected the
in-progress recording but didn't.

The user reports this happens **very rarely** ("very rarely I hit this state").

## Cause (read-only investigation, 2026-06-03 — corrected the initial guess)

**It is NOT a by-design gap.** The initial hypothesis (source-based hero routing
intentionally ignores keyboard-started recordings on home) is **wrong** — verified against
code. The home's "Recording" pill is driven by `ContentView.isLiveRecordingInline`
(`ContentView.swift:576-582`), which is **deliberately NOT gated on the 3 hero triggers**
and shows for **any** live recording regardless of how it started (explicit comment,
`ContentView.swift:557-561`). The "3 triggers / nothing adopts `isRecording`" rule governs
the full-screen **hero push**, not the home pill. Warm-resume *does* flip the main-app
singleton's `isRecording = true` (`RecordingService.swift:558`, via the `warmResumeObserver`
at `JotApp.swift:96-149,116`). And tapping Dictate adopts the running session via
`RecordingHeroView.swift:703-704` (`if isRecording { adoptInFlightRecording() }`) — which
*proves* `isRecording` was already true at tap time. So the home rendered idle during a
window where the pill *should* have shown.

**Most likely cause: a backgrounded-scene render/invalidation gap (warm-hold-specific).**
Warm-resume starts the recording while **Jot is backgrounded** (the keyboard only posts
`warmResumeRequested` when `!isJotAppForeground`, `JotKeyboardViewController.swift:1657`). A
backgrounded scene doesn't render, and `isLiveRecordingInline` has **no `scenePhase`-driven
refresh** — the two `.onChange(of: scenePhase)` hooks (`ContentView.swift:543-548`) only
touch the donation card + warm-hold nudge, nothing recording-state. So if SwiftUI didn't
register the `isRecording` dependency while the body was unevaluated (backgrounded), the
invalidation is missed until some *other* state change forces a recompute — e.g. the FAB
tap. Matches "rare/intermittent" and "tapping Dictate is what surfaces it."

**Secondary suspects (lower confidence):** a residual `pendingColdStartHeroNudge == true`
or a leaked `ownsActiveRecording == true` — both appear in `isLiveRecordingInline`'s
negative guards (`ContentView.swift:578,581`) and would suppress the pill; both are known
intermittent-leak offenders (multiple sites defensively clear `ownsActiveRecording` before
`start()`).

**Fix space (NOT decided — implementation, out of scope for this record):** (a) add a
`scenePhase == .active` recording-state refresh/invalidation in `ContentView`; and/or (b)
audit the two suppression flags for stuck-true on the warm-resume entry. **Do NOT
reintroduce "adopt-unless-vetoed."** Distinguishing (a) from the stuck-flag suspects needs
an on-device repro with state instrumentation (`RECORDING START FROM: warmResumeObserver`).

## Scope guardrails for whoever implements this

- Confirm whether this is **by-design** (source-based routing intentionally ignores
  keyboard-started recordings on home) vs. a **race** before changing anything — the
  source-based routing was a deliberate redesign; don't naively re-introduce
  "adopt-unless-vetoed."
- Minor / low-priority per the user. Record-only for now.

## Exact trigger conditions (deeper code trace, 2026-06-03) — DO NOT FIX until on-device repro confirms which

Two reachable mechanisms. **Not yet 101% certain which one(s) fire** — needs an on-device repro
that logs the four `isLiveRecordingInline` terms. Do not fix before that.

**Candidate 1 — stuck `pendingColdStartHeroNudge` (code-provable; LEAD).** The pill is suppressed
while `pendingColdStartHeroNudge == true` (`ContentView.swift:581`). That flag is cleared in ONLY
two places — `onAppear` (`:490-496`) and `onChange` (`:519-524`) — and **both clears are guarded by
`!showRecordingHero && !isWizardPresented`.** So if a cold `jot://dictate` keyboard start sets the
flag **while a hero is already presented (`showRecordingHero == true`) or the wizard is up**, the
`onChange` guard hits its `else { return }`, the flag is **never cleared**, and it stays `true`.
From then on `isLiveRecordingInline` is forced `false` for EVERY later recording — so a subsequent
**keyboard warm-resume** recording shows idle home / no pill; tapping Dictate opens the hero and
adopts the running session. Matches the symptom + "rare" (needs the cold signal to coincide with a
hero/wizard already up). The stuck flag persists until app relaunch or a home `onAppear` that itself
passes the `!showRecordingHero && !isWizardPresented` guard.

**Candidate 2 — SwiftUI foreground render-gap (timing; not statically provable).** Warm-resume flips
`isRecording` true while Jot is backgrounded (`JotApp.swift:96-149`); the only `scenePhase == .active`
handler (`ContentView.swift:543-548`) refreshes donation card + warm-hold nudge, NOT recording state.
If the home body's `isRecording` dependency wasn't registered while backgrounded, the pill
invalidation is missed until another redraw (the Dictate tap). `@Observable` should normally handle
this — hence unprovable from static reading.

**Path to 101% (diagnostic, NOT a fix):** log the four `isLiveRecordingInline` terms
(`isRecording`, `ownsActiveRecording`, `showRecordingHero`, `pendingColdStartHeroNudge`) at the moment
home renders idle during a live keyboard recording (and the warm-resume start, already logged as
`RECORDING START FROM: warmResumeObserver`). The "wrong" term identifies the mechanism. Note:
`ownsActiveRecording` is explicitly cleared by warm-resume at `JotApp.swift:115`, so it's the LEAST
likely suspect for the warm-resume path. **Fix space stays deferred until a repro names the flag.**

## Investigation — DONE (findings folded into "Cause" above)

Read-only investigation completed 2026-06-03. Verdict: **race / state-propagation gap, NOT
by-design**; **warm-hold-specific** (only the warm-resume path records without foregrounding
Jot). Confidence: home-pill-is-not-trigger-gated and warm-resume-sets-`isRecording` are
**Confirmed** in code; the backgrounded-scene render-gap as the specific trigger is
**Likely** but needs an on-device repro to separate from the two stuck-flag suspects.
