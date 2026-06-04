# Jot — Known Bugs & Planned Work

> Companion to **[features.md](features.md)**. This page holds the **bug tracker** and the **plan / roadmap index** — the implementation-level detail (symptoms, hypotheses, plan-doc links, sizes) that is intentionally kept OUT of the feature inventory, which stays user-facing only. `§N.M` references link back into `features.md`.

---

## Sizing convention

Entries below carry a **size** tag using a T-shirt scale:

- **XS** — under 2 hours, single-file trivial change.
- **S** — 2-6 hours, single feature surface, 1-3 files.
- **M** — 1-2 days, multi-file but contained.
- **L** — 3-5 days, multi-component, real design decisions.
- **XL** — over a week, architectural change or new subsystem.

Sizes appear on the Known Bugs below and on aspirational entries that haven't shipped. Already-shipped features don't carry sizes.

---

## Known Bugs (Unresolved)

This section tracks user-facing bugs that are reproduced but not yet fixed. Each entry is a short symptom statement + the reproducer + the current root-cause hypothesis. Entries are removed when a fix lands and ships.

### Keyboard-initiated dictation opens Jot but does not start recording
**Size: S.** **Plan: [docs/plans/bug-cold-start-dictation-race.md](../docs/plans/bug-cold-start-dictation-race.md).** Hypothesis recorded here may not match code reality — see plan for diagnostic-first approach.

**Symptom:** User taps the Dictate pill in the Jot keyboard from a host app. Jot is brought to the foreground (recording hero may briefly appear) but recording never actually starts — the timer stays at 0:00 and no audio is captured. The user has to back out and tap the home-screen Dictate FAB to actually record.

**When it happens:** Cold-start path only (no [warm-hold](features.md#13-2-warm-hold) window active). Observed especially after the speech model has been unloaded (e.g. post-memory-warning or first launch after device reboot). User manually triggering dictation in the same session briefly flashes a "Parakeet loading…" indicator before recording begins, which suggests the keyboard-initiated path may be racing the speech-model ANE-load.

**Current hypothesis:** the `jot://dictate` URL-bounce reaches the main app before the speech model has finished loading into ANE. The recording-start handler proceeds and starts the audio engine, but the streaming session's `loadModels(from:)` fails or hangs, leaving the recording in a half-started state where the engine isn't capturing. Needs trace logs to confirm.

### Keyboard auto-switches back to system keyboard after dictation stop
**Size: M.** **Plan: [docs/plans/bug-keyboard-auto-switch.md](../docs/plans/bug-keyboard-auto-switch.md).** Two hypotheses (keyboard kill vs. main-app jetsam); diagnostic plan disambiguates.

**Symptom:** Rare. After the user taps Stop in the Jot keyboard (the same Dictate pill in its stop state), iOS switches the active keyboard back to the previous system keyboard. When the user manually switches back to Jot via the globe key, the transcript has already been auto-pasted into the host field and the keyboard is in its normal idle state.

**When it happens:** Rare; not yet reliably reproduced. User can supply logs from a capture when it happens next.

**Current hypothesis:** the keyboard extension is being terminated by iOS (memory pressure during transcribe/cleanup) and iOS falls back to the previously-active keyboard while it relaunches. The auto-paste still completes because the main-app pipeline finishes independently and the v7 paste deadline machinery resurrects it on next keyboard presentation. Needs trace logs around the stop → transcribe-complete window to confirm.

### Auto-paste silently fails in some host apps (notably Slack)
**Size: M.** **Plan: [docs/plans/bug-slack-silent-paste.md](../docs/plans/bug-slack-silent-paste.md).** Probe shipped in build 4; plan tightens it (existing `contextGrew` signal is ambiguous on long fields) then ships banner + clipboard fallback.

**Symptom:** Stop a warm-hold dictation while focused on a host app's text field (observed in Slack). The keyboard's `pasteSuccess` event fires in the diagnostics log with the full character count, but no text appears in the host field. The dictated transcript is still stored in Jot's library — only the auto-paste step silently no-ops.

**When it happens:** Warm-hold path (Jot never foregrounded). Most reliably observed with Slack as the host; possibly other apps with custom JS-backed compose fields or draft-autosave systems. Intermittent rather than every time.

**Why `pasteSuccess` is misleading:** `UITextDocumentProxy.insertText(_:)` is a void call — it returns nothing whether the host accepted the insert or not. The "pasteSuccess" log line confirms only that the keyboard *called* the function, not that any text actually landed in the host's text field. The host can silently reject the insert if the proxy is mid-disconnect, if the keyboard isn't the active input view at the moment of call, or if the host's text-input delegate rejects programmatic inserts.

**Current hypothesis:** the host's textDocumentProxy is disconnected (returns `nil` for `documentContextBeforeInput`) at the moment of insert, so iOS no-ops the call silently. Slack's compose field has known unusual focus + draft-autosave behavior that may transiently break the proxy connection. As of build 4 the `pasteSuccess` log now also captures `proxyHadContextBefore` + a before/after context-length delta so the next failure produces actionable signal: if `contextGrew` equals the inserted character count, the host accepted the text; if it's `0` or `-1`, the insert was silently dropped. Once a failure is captured with the new instrumentation, the fix (likely gating insert on `proxyHadContextBefore == true` and posting an error banner otherwise) becomes a one-liner.

### New user-created prompts have no before/after preview in the list
**Size: S.** **Plan: [docs/plans/bug-user-prompt-no-preview.md](../docs/plans/bug-user-prompt-no-preview.md).** Deterministic, ready to implement.

**Symptom:** Each bundled default prompt in [Settings → AI Rewrite](features.md#7-7-saved-prompt-management) (Articulate, AI prompt, Action Items, Email) renders with a mini before→after sample directly inside its row — a representative dictation in italic + the prompt's transformed output below it. When the user creates their own prompt via the "+ New prompt" sheet, the new row appears in the list but **without a before/after sample**; it just shows the icon + name + a one-line preview of the system prompt. Visually inconsistent with the bundled rows and gives the user no quick "is this prompt doing what I expect" cue.

**When it happens:** Every user-created prompt, every time. Not intermittent.

**Why it's there:** The before/after samples for the bundled defaults are hardcoded in `AIRewriteSettingsView.swift` (switch on `prompt.defaultKind`). User-created prompts have no such hardcoded sample — and we don't currently capture the output from the editor's "Try this prompt" footer pill, even though we already have the user dictating a real recording AND running the prompt against it in that flow.

**Plan:** Capture the most recent (before, after) pair produced by the "Try this prompt" footer for each user-created prompt and persist it on the `SavedPrompt` row (or as a separate side-table keyed by id). Render that pair in the list row using the same component path as the bundled defaults. Falls back to the existing "first-line of system prompt" preview when no try-run has happened yet. Deferred for now — capture the bug, fix later.

### Minimize sometimes leaves keyboard at full height with collapsed content inside
**Size: diagnosis-first.** **Plan: [docs/plans/bug-keyboard-minimize-stuck-height.md](../docs/plans/bug-keyboard-minimize-stuck-height.md).** Ten plausible causes enumerated; fix size XS→M depending on which one confirms via the existing `[KB-COLLAPSE-DEBUG]` instrumentation.

**Symptom:** Tapping the Minimize button in the [Jot Keyboard](features.md#5-8-minimize--expand) sometimes swaps the SwiftUI render to the collapsed-bar view (small Stop button centered) but leaves the keyboard's outer frame at full expanded height (~450 pt). User sees the small content floating in a tall empty envelope. Intermittent — not every Minimize tap is affected.

**Workaround that works:** globe-switch to any other keyboard, then globe-switch back to Jot. On re-presentation, the keyboard renders at the correct collapsed 58 pt height.

**This is the opposite failure mode from [§5.10](features.md#5-10-status-banner):** there the height grows but content doesn't; here the content shrinks but height doesn't.

**Current hypotheses (no winner — diagnostic capture pending):** ten candidate causes ranging from system input-view height caching, animation-interruption races on double-tap, status-banner auto-expand collisions, SwiftUI vs UIKit ordering, hosting-controller intrinsic-content-size conflicts, transitions during the tap window, and `UIInputView` size-negotiation timing. The plan explores each path and lists the diagnostic signal that would disambiguate. Fix is not chosen until logs confirm.

### Actions popover regression cluster (Paste, Undo, Move up/down, Dismiss)
**Size: bundled, XS-S.** **Plan: [docs/plans/bug-actions-popover-regressions.md](../docs/plans/bug-actions-popover-regressions.md).** Four bugs in the keyboard's [Actions Popover](features.md#5-6-actions-popover) surface:

- **Paste** doesn't re-read the system clipboard when the popover opens. Stale enabled-state persists across opens until the keyboard re-appears. **Confidence: 90%.** Fix is XS — call `refreshPasteState()` from the Actions button tap.
- **Undo** appears to be missing coverage for Recents-strip tap insertions (and possibly other keyboard-driven inserts). Code reading suggests the path *should* be tracked; needs diagnostic instrumentation before fix. **Confidence: 50%.**
- **Move up / Move down** is moving roughly one line per tap when it previously moved ~one host-visible window (~256–1000 chars). Possible regression introduced during the rename from "Jump to start / end." Needs git history check + per-iteration instrumentation. **Confidence: 40%.**
- **Popover dismiss is unreliable.** Tapping the Actions button again doesn't close it; tapping arbitrary outside areas doesn't close it. User has to tap a specific area (Recents) to dismiss. **Confidence: 60%.** Fix: full-frame `Color.clear` catcher with `.highPriorityGesture` + explicit toggle-close in the Actions button + optional ✕ in the popover top-right.

### In-app dictation duplicates the text on stop (transcript Edit / Feedback fields)
**Size: S. Status: FIX IMPLEMENTED 2026-06-03 — one paste path; compiles; Codex-reviewed; PENDING on-device verify-once.** **Plan: [docs/plans/bug-in-app-dictation-duplicate-paste.md](../docs/plans/bug-in-app-dictation-duplicate-paste.md).** Fix: deleted the keyboard's documentIdentifier/keyboardType same-field guards + the in-process `FocusedFieldInsert` side door (file deleted) → keyboard flush is the sole deliverer everywhere. Gate: in-Jot paste must land exactly once (not zero/two) across Edit/Feedback/W5. Dictating inside Jot's own fields (transcript Edit pane, Feedback) and stopping inserts the text **twice** — only in-app, never into another host. **Root cause (~85%): the keyboard's auto-paste flush AND the main-app in-process `FocusedFieldInsert` both land for one recording.** On-device log of a duplicate run shows, same second: `[keyboard] Inserted transcript into host` (insert #1) + `[main-app] In-Jot transient paste (in-process insert)` (insert #2). It's **intermittent** because the keyboard's flush races the main-app's `clearPendingPasteSession()` (`DictationPipeline.swift:381`, which runs AFTER the publish+phase-flip at `:343-362` that wakes the keyboard's flush in its own process): when the keyboard sees a fresh, session-matching payload it pastes → dup; when it sees a mismatch / no-fresh payload it skips (`SKIP/SESSION` / `SKIP/NONE`) → single, correct. In-app reject-guards (documentIdentifier/nil-context) don't save us — field identity is stable, proxy connected. Fix must close the race deterministically (clear/consume pending BEFORE publish on transient path, or don't publish to clipboard at all on transient, or tag publish as in-process-handled) — keep in-app paste landing EXACTLY once (build 99's in-process insert fixed a *dropped* paste).

### Keyboard-started dictation isn't reflected in the main app's home (shows idle until you tap Dictate)
**Size: diagnosis-first, S.** **Plan: [docs/plans/bug-keyboard-recording-not-shown-in-app.md](../docs/plans/bug-keyboard-recording-not-shown-in-app.md).** Symptoms recorded, NOT fixed. **Rare.** Start a dictation **from the keyboard** → the main app's home shows its **idle** state (the "Dictate" affordance) instead of the live-recording indicator (the "Recording" return pill + live preview row, §2.7 / §1.10). Tapping **Dictate** in the app then does NOT start a new recording — it **reveals/adopts the already-ongoing keyboard-started dictation**. **Cause (investigated 2026-06-03 — NOT by-design):** the home pill is driven by `isLiveRecordingInline` (`ContentView.swift:576-582`), which deliberately shows for **any** live recording and is **not** gated on the 3 hero triggers (the trigger rule governs the full-screen hero push, not the pill). Warm-resume *does* set `isRecording = true` (`RecordingService.swift:558`), and tapping Dictate *adopts* the running session (`RecordingHeroView.swift:703-704`) — proving `isRecording` was already true. So it's a **race / state-propagation gap, warm-hold-specific**: warm-resume starts the recording while Jot is **backgrounded** (`JotKeyboardViewController.swift:1657`), and `isLiveRecordingInline` has **no `scenePhase`-driven refresh**, so the foreground invalidation can be missed until the FAB tap forces a recompute. Secondary suspects: residual `pendingColdStartHeroNudge`/leaked `ownsActiveRecording` (both suppress the pill). Fix space: scenePhase-active recording refresh and/or stuck-flag audit — **don't reintroduce "adopt-unless-vetoed."** Needs on-device repro to confirm.

### Keyboard hangs in a stale "recording" state when the Jot app is killed mid-recording
**Size: S–M. Status: FIX IMPLEMENTED 2026-06-03 — compiles; Codex-reviewed; PENDING on-device test.** Fix: heartbeat 10s→3s + a 5s control-tap watchdog that recovers the keyboard to idle if the projection stays frozen-and-active; tombstone prevents re-present resurrection within the 30s window. Test: kill app mid-recording → Stop/Pause/Cancel recovers ≤5s; happy path unchanged. **Plan: [docs/plans/bug-keyboard-hangs-when-app-killed-mid-recording.md](../docs/plans/bug-keyboard-hangs-when-app-killed-mid-recording.md).** Symptoms recorded, NOT fixed. Mid-recording, iOS kills the **main app** (memory/jetsam); the keyboard keeps rendering a live "recording" UI from stale cross-process `PipelinePhaseProjection` and **hangs** — Stop/Pause/Cancel/Delete post Darwin requests to a dead process that never answers, so the keyboard sits on `stopRequestPosted` forever. Only recovery today is to relaunch Jot by hand. Fix direction (user's ask): on a control tap, verify the app is actually alive (reuse `keyboardForegroundPing`/`appForegroundPong` or heartbeat freshness) with a few-second timeout; on no response, treat as "app not open" — clear the stuck state, reset the keyboard out of the recording view, end/discard cleanly. Don't touch the normal app-alive stop path. **Confidence on hypothesis: ~60% — verify the liveness signal before designing.**

---

## Planned Work & Plans Index

Curated index of plan documents that elaborate aspirational features, deferred engineering work, and unresolved bugs. Each plan has a recommendation, alternatives, edge cases, and a test plan ready to pick up.

### Aspirational (advertised but not yet built)

- **Delete misleading "wand in keyboard" Help copy** — [§7.3](features.md#7-3-ai-rewrite-activation-model) → [docs/plans/keyboard-magic-wand-entry.md](../docs/plans/keyboard-magic-wand-entry.md) — **XS.** A keyboard wand was advertised but never built and will never be built. Plan is a one-line copy edit in Help to drop the false advertising. No new UI.
- **Transcript titles** — [§3.2](features.md#3-2-transcript-metadata), [§7.11](features.md#7-11-ai-settings-copy-discrepancy--titles-and-tags) → [docs/plans/titles-and-tags.md](../docs/plans/titles-and-tags.md) — **XS (recommended path) or M (if build).** Plan recommends path A (delete the §7.11 footnote) until there's user demand. Build path is coupled to SwiftData schema versioning. Tags are explicitly out of scope.
- **Cancel-during-recording in keyboard** — [§5.6](features.md#5-6-actions-popover), [§5.4](features.md#5-4-dictate--stop-control) → [docs/plans/keyboard-cancel-during-recording.md](../docs/plans/keyboard-cancel-during-recording.md) — **XS.** Replaces the Actions button with a Cancel button while a dictation is actively recording. Closes the "no abort from keyboard" gap on warm-hold and in-app paths.
- **Cancel button visual design** — companion to the above → [docs/plans/keyboard-cancel-button-ux.md](../docs/plans/keyboard-cancel-button-ux.md). Treatment B chosen (glass + red `xmark`) with dark-mode opacity mitigations called out at implementation time.

### Deferred engineering (queue in `docs/deferred-engineering.md`)

- **🔜 NEXT PROJECT — Decouple the monolithic root view (`ContentView`)** — [docs/plans/refactor-decouple-root-view.md](../docs/plans/refactor-decouple-root-view.md) — **L–XL.** Committed 2026-06-03 as the first project after the in-app dictation paste fix ships. `ContentView` is a 1,244-line god-view (37 state vars) that observes `isRecording` and presents every screen through itself, so a recording-state change cascades a re-render into whatever screen is presented (the in-app dropped-paste bug is exhibit A). Goal: volatile state in one surface must not re-render unrelated surfaces. Options: scope the observation / router-coordinator / per-surface roots. Needs full brainstorm→design→review. Lets us delete the in-process-insert bridge (if used) and reach a true single paste path.
- **Generic versioned migration system** — [docs/plans/migration-system.md](../docs/plans/migration-system.md) — **M.** Replaces hand-rolled `UserDefaults`-gated migrations with a typed `Migration` protocol supporting synchronous, detached, and always-apply patterns. Crash-recovery via attempt counter + circuit breaker.
- **Unify keyboard dictation (one stop path everywhere)** — [docs/plans/unify-keyboard-dictation.md](../docs/plans/unify-keyboard-dictation.md) — **M.** Delete the custom inline-dictation engine; in-Jot dictation uses the same keyboard stop path as any other app (paste into the focused field, end the transcription cleanly, warm-hold untouched), saving a transcript only when you stop outside Jot. Ask keeps its own session. Supersedes the old "in-app tap-to-record" + "in-app dictation no-save" plans.
- **In-app feature list + forward-only release log** — [docs/plans/feature-catalog-release-log.md](../docs/plans/feature-catalog-release-log.md) — **S.** Static hand-coded SwiftUI list grouped by hero feature. Release log starts forward from the version that ships this feature; no back-fill of past versions. No JSON sidecar, no CI check, no `features.md` sync.
- **Donation milestone re-prompt** — [docs/plans/donation-milestone-card.md](../docs/plans/donation-milestone-card.md) — **S.** Evolves the existing `DonationCard` (`Jot/App/Donation/DonationCard.swift` — already shipping) from a single-shot at 2h into a multi-milestone re-prompt at 2h / 10h / 25h with a 90-day cooldown and a "never ask again" affordance.

### Known bugs

- **Cold-start dictation race** — [docs/plans/bug-cold-start-dictation-race.md](../docs/plans/bug-cold-start-dictation-race.md) — **S.** Diagnostic instrumentation first; primary fix is a one-line `warmUp()` kick in the deferred branch of `triggerAutoStart`.
- **Keyboard auto-switch on stop** — [docs/plans/bug-keyboard-auto-switch.md](../docs/plans/bug-keyboard-auto-switch.md) — **M.** Two hypotheses (keyboard kill vs. main-app jetsam); diagnostic plan disambiguates. Resurrection UX uses a Dictate-button overlay rather than a banner because of the §5.10 collapsed-banner bug.
- **Slack silent paste** — [docs/plans/bug-slack-silent-paste.md](../docs/plans/bug-slack-silent-paste.md) — **M.** Build-4 probe ships; plan tightens it (existing `contextGrew` is ambiguous on long fields) then adds banner + clipboard fallback with `setItems` expiration.
- **User-prompt no preview** — [docs/plans/bug-user-prompt-no-preview.md](../docs/plans/bug-user-prompt-no-preview.md) — **S.** Persist last (before, after) pair from the Try-This footer + render via the same component path as bundled defaults.
- **Minimize leaves keyboard at full height with collapsed content** — [docs/plans/bug-keyboard-minimize-stuck-height.md](../docs/plans/bug-keyboard-minimize-stuck-height.md) — **diagnosis-first.** Ten plausible causes enumerated; existing `[KB-COLLAPSE-DEBUG]` log layer is most of the instrumentation needed. Fix size XS→M depending on which cause confirms.
- **In-app dictation duplicate paste** — [docs/plans/bug-in-app-dictation-duplicate-paste.md](../docs/plans/bug-in-app-dictation-duplicate-paste.md) — **S. CONFIRMED (intermittent race), not fixed.** Dictate inside Jot's own field (transcript Edit / Feedback) → text inserts twice on stop, only in-app. On-device log of a dup run shows, same second: `[keyboard] Inserted transcript into host` + `[main-app] In-Jot transient paste (in-process insert)` = two inserters. Intermittent: keyboard's auto-paste flush races the main-app's `clearPendingPasteSession()` — wins (pastes → dup) or loses (skips → single). Fix must close the race deterministically; keep in-app paste landing exactly once.
- **Keyboard-started dictation not shown in app** — [docs/plans/bug-keyboard-recording-not-shown-in-app.md](../docs/plans/bug-keyboard-recording-not-shown-in-app.md) — **diagnosis-first, S. Rare.** Dictation started from the keyboard doesn't show on the main-app home (renders idle); tapping Dictate surfaces the already-running recording. **Investigated: NOT by-design** — the home pill shows for any live recording; it's a warm-hold-specific render/propagation gap (`isLiveRecordingInline` has no `scenePhase` refresh, recording starts while Jot backgrounded). Symptoms + cause recorded, not fixed.
- **Keyboard hangs when app killed mid-recording** — [docs/plans/bug-keyboard-hangs-when-app-killed-mid-recording.md](../docs/plans/bug-keyboard-hangs-when-app-killed-mid-recording.md) — **diagnosis-first, S–M.** App dies mid-recording (jetsam) → keyboard keeps a zombie "recording" UI on stale state and hangs; Stop/Cancel/Delete go to a dead process. Fix: liveness-check the app on control taps with a few-second timeout, recover as "app not open" if no response. Symptoms recorded, not fixed.
- **Actions popover regression cluster** — [docs/plans/bug-actions-popover-regressions.md](../docs/plans/bug-actions-popover-regressions.md) — **XS-S bundled.** Four bugs: Paste-stale (90% confidence, XS fix), Undo coverage for Recents tap (50% confidence, diagnostic-first), Move up/down regression (40% confidence, git check + diagnostic), and unreliable popover dismiss (60% confidence, XS fix — full-frame catcher + explicit toggle-close + ✕ affordance).

### Index conventions

- Sizes follow the [T-shirt scale](#sizing-convention) at the top.
- Every plan has been adversarial-reviewed; review findings are folded into the corresponding plan doc.
- Plan docs use this template: Problem → Goal → Non-Goals → Design → Implementation outline → Edge cases → Test plan → Open questions → Cross-links.

### Decisions to make

All ~30 open questions across the 10 plans are walked path-by-path in **[docs/plans/open-questions-deep-dive.md](../docs/plans/open-questions-deep-dive.md)**. Each question has alternatives explored, second-order effects, and a recommendation. A TL;DR table at the bottom summarises every recommendation in one screen.
