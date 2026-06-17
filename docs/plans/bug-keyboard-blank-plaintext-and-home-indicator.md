# Plan — Kill the keyboard blank for good (plain-text render) + fix the home recording indicator

**Status:** design → implementation. **Size: M.** Owner-approved (2026-06-17).
Follows `bug-keyboard-ghost-controller-hub.md`: the process-level `KeyboardStreamingHub`
made all controllers render the SAME shared streaming state (verified in build 145/146
logs — every kbd instance reports identical `settledLen`). But the blank still recurs,
because two fragilities remain BELOW the shared state. This plan removes the class.

## Why the hub wasn't sufficient (from build 145/146 on-device logs)

1. **Per-view fade renderer still strands.** Each `TranscribingText` owns its OWN
   `@State StreamingWordReveal` + `SettleRenderer` (NOT shared by the hub). Logs show
   `settleProgress` driven NEGATIVE by `withAnimation` overshoot — `progress=-0.16`,
   `-0.21`, `-1.00`. At negative progress the arriving word draws at ~0 opacity
   (invisible). This is per-view, so the hub's shared input text can't fix it.
2. **Controller churn/ghosts persist.** iOS rapidly creates+destroys controllers
   (11→12→13→14 in ~6s) while old instances (347/354) keep drawing. The hub keeps
   their content consistent, but the proliferation is unchanged — so a visible
   instance can be one whose per-view reveal stranded.

The shared-state hub is correct and stays. The remaining defect is the **fragile
custom per-view renderer** — the wrong tool for a correctness-critical surface in an
appex the OS churns.

## Fix 1 — Replace the custom reveal/renderer with plain text (the decisive simplification)

Rewrite `TranscribingText` (`Jot/App/Design/Components/TranscribingText.swift`, shared
by the keyboard strip AND the recording hero) to render the transcript as **plain
SwiftUI `Text`** from the passed-in `text` (which is the shared hub's
`streamingPartialText`), plus the existing trailing **stepping-ellipsis** "still
transcribing" tail when `isTranscribing`.

REMOVE: `StreamingWordReveal` (the whole class), `SettleRenderer` (the `TextRenderer`),
`ArrivingTextAttribute`, `settleProgress`, the per-word `withAnimation`, the advance
`Task`, the `:136` empty-split safety net, and all the `onChange(text/isTranscribing/
reduceMotion)` reveal plumbing.

KEEP: the public interface (`text`, `font`, `textColor`, `dotColor`, `isTranscribing`,
`reduceMotion`, `tracking`) so call sites (`StreamingStrip.StreamingPane`,
`RecordingHeroView`'s `StreamingDictationText`) are unchanged; the trailing
`SteppingEllipsis` tail (drop it when `!isTranscribing`); line spacing / font / color.

Result: the transcript is drawn by SwiftUI's normal text layout — there is NO per-view
animation/layout state left to strand or go negative, so a blank pane is impossible
regardless of how many ghost controllers iOS spawns. Tradeoff: lose the per-word
"ink-drying" fade (owner accepted: "always show the text" > the cosmetic fade). The
text still arrives in batch chunks and auto-scrolls (StreamingPane unchanged).

### Diagnostics
The `streamReveal*` / `streamRender*` probes live INSIDE the removed reveal/renderer,
so they go with it. KEEP the `KBD/CTRL` controller-lifecycle probe AND add ONE minimal
strip-render probe (log when the keyboard strip draws empty vs N chars) so we can
confirm the plain-text fix on-device. Full diagnostics rip happens in a follow-up once
the owner confirms the blank is gone. Keep the raised log-buffer for this build.

## Fix 2 — Home screen doesn't show an in-progress (keyboard-started) recording

Per the earlier read-only investigation (canonical bug: `bug-keyboard-recording-not-
shown-in-app.md`): the home "Recording" return-pill (`ContentView.isLiveRecordingInline`)
is suppressed by stale UI flags after a cold `jot://dictate` URL-bounce:
- **Mechanism A:** `pendingExternalKeyboardHero` can stick `true` (cleared only in
  guarded sites that early-return without clearing), forcing the pill off forever.
- **Mechanism B:** `showRecordingHero` stays `true` after a system swipe-back (the
  binding isn't reliably written back), suppressing the pill AND blocking re-present.

Fix (in `ContentView`, collision-free): a `scenePhase == .active` reconciliation that
(a) clears a stale `pendingExternalKeyboardHero` when no hero/wizard is presented, and
(b) resets a desynced `showRecordingHero` when `isRecording` but the hero isn't on the
nav stack. This is the bug doc's deferred fix-space item. Do NOT reintroduce
"adopt-unless-vetoed". `isRecording` is genuinely true (same singleton publishing the
preview), so this is purely surfacing existing state.

## Migration / order
1. Rewrite `TranscribingText` to plain text + ellipsis tail; delete the reveal/renderer.
2. Adjust the diagnostics (remove reveal/render probes that no longer exist; keep
   KBD/CTRL + add the minimal strip-render probe). Update `DiagnosticsLog`/`DiagnosticsView`
   category lists accordingly (remove now-dead categories or leave them harmless).
3. `ContentView` scenePhase reconciliation for the home pill.
4. `xcodegen`; build `JotKeyboard` + `Jot`; adversarial review (esp. hero parity —
   the hero uses the same component — and the ContentView flag reconciliation not
   double-presenting the hero); owner on-device test; deploy.

## Risks
- **Hero parity:** `TranscribingText` is shared. Confirm the recording hero still
  renders correctly (plain text, ellipsis) and nothing depended on the per-word fade.
- **Auto-scroll:** ensure `StreamingPane`'s scroll-to-bottom still fires on `text`
  change (it keys off `partialText`, unchanged).
- **ContentView reconciliation** must not cause a hero double-present or fight the
  3 source-based present triggers — review carefully.

## Schema impact: NONE.
