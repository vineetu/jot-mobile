# Refactor: decouple the monolithic root view (`ContentView`)

> **Status: PLANNED — the next project after the in-app dictation paste fix ships.**
> (Committed 2026-06-03.) Needs the full brainstorm → design → design-review pass before
> any code. This doc is the seed, not the design.

## Why (the problem, in one line)

`ContentView` is a **1,244-line god-view** that owns **37 pieces of state** and presents
**every** screen through itself (home, transcript Edit, Ask, Settings, Help, hero, wizard —
via 3 `navigationDestination`s + 3 sheets + a cover). Because the root **observes
`recordingService.isRecording`** (for the home FAB↔"Recording" pill swap + stop animation),
any recording-state change re-evaluates the root's body — and that re-evaluation **cascades
into whatever screen is currently presented**, even though those screens read nothing about
recording.

**Exhibit A:** the in-app dictation **dropped-paste** bug. Stopping a keyboard dictation
inside Jot's Edit pane / Feedback field flips `isRecording`, the root re-runs, the focused
text field (a "passenger" in the root's tree) is perturbed and loses its keyboard connection
for a frame, and the paste no-ops. In any *other* app this never happens — the host doesn't
re-render when Jot stops. The bug is a *symptom* of the shared-observing-root coupling.

This is the SwiftUI version of the Massive-View-Controller anti-pattern. It's an extremely
common drift (SwiftUI nudges you toward piling `@State` on the root; there's no built-in
router/coordinator), and the app shipped ~100 features this way — but it has hit the
complexity wall where the coupling costs more than it saves.

## Goal

Volatile state changes in one surface must **not** re-render unrelated surfaces. A stop on
Home must not touch a field in Settings/Edit/Feedback. Concretely: no screen should be a
"passenger" in another screen's re-evaluation.

## Non-goals

- Not a rewrite. The individual screen views (`SettingsView`, `AskView`,
  `TranscriptDetailView`, …) are **already separate** and stay as-is. This is about the
  **root** that hosts/observes them, not the leaves.
- Not a visual/UX change. Pure structural decoupling; every flow behaves identically.

## Approach options (to be weighed in design)

1. **Scope the observation (smallest first step).** Move `ContentView`'s `isRecording` reads
   (FAB/pill swap + `.animation(value:)`) into a small leaf subview that observes
   `isRecording` itself, so a stop re-renders only that leaf. May be *necessary-but-not-
   sufficient* if other volatile reads (streaming preview, pipeline phase) also re-run the
   root body — verify on device.
2. **Router / coordinator pattern.** A thin navigation coordinator owns presentation;
   screens are pushed/presented without sharing the home view's body. Each screen roots its
   own observation.
3. **Per-surface roots.** TabView / independent scene roots so screens don't share a
   re-evaluating parent at all.
4. **Move recording observation off the root entirely** — only the small surfaces that
   actually need live recording state subscribe to it.

## Sequencing

- **Prereq:** the in-app dictation paste fix ships first (see
  `bug-in-app-dictation-duplicate-paste.md`). If that fix used the in-process-insert bridge,
  this refactor is what lets us **delete that bridge** and reach a true single paste path
  (the keyboard flush works in-app once the field is no longer perturbed).
- Then: brainstorm → design (`docs/<feature>/design.md`) → design-review → implement with
  per-surface verification (every push/sheet/cover flow re-tested on device).

## Open questions for design

- Which option (1–4), or a staged combination (1 now, 2/3 later)?
- Does scoping `isRecording` alone stop the cascade, or do streaming/pipeline reads also
  re-run the root? (Instrument the root's body re-eval on a stop to find out.)
- Can the in-process insert (`FocusedFieldInsert`, if restored as a bridge) be deleted once
  the field is isolated — confirming the single keyboard path holds in-app?
