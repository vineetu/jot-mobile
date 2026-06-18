# Bug: keyboard live-preview shows "Listening…" then goes BLANK (hero works)

**Status:** Diagnosis-only. NO code change, NO deploy. Owner-confirmed on build 137.
**Size:** diagnosis-first, S.

## Symptom (owner, build 137)

Keyboard dictation **into another app**. The in-app **hero** (recording surface,
same process as the main app) renders the live preview correctly. The **keyboard**
(separate process, mirrors via App Group) does NOT: it shows "Listening", and at
the moment text should arrive it goes **blank** (no words). On stop, the final
transcript appears in **Recents** but is not pasted (paste is a *separate* known
bug — `bug-keyboard-paste-fails-claude-code.md` / `…-recording-not-shown-in-app.md`
— and is explicitly **out of scope** here).

## Producer side is CONFIRMED working (from the owner's log)

```
preview session start {liveText=true, modelState=ready, sid=49CC166F}
preview tick {resultChars=16, trigger=volatileRefresh, windowSec=2}
preview PUBLISH {chars=15, final=false, sid=49CC166F}     ← preview text WAS published
... (stop) ... preview drain end {committedChars=0, sid=49CC166F}
```

`liveText=true` ⇒ the live-text gate passed and `PreviewScheduler` ran
(`RecordingService.kickOffStreamingSession`, `Jot/App/Recording/RecordingService.swift:379-416`).
`preview PUBLISH {chars=15}` is logged from inside `StreamingPartial.update(...)`
**after** it set `streamingText` and **before** `publishProjection(...)`
(`Jot/App/Transcription/StreamingPartial.swift:118-131`). So the producer reached
the projection write.

## Runtime topology (owner-confirmed ground truth, cross-app + Warm Hold ON)

From `Jot/known-bugs-and-plans.md` lines 60-62 (owner correction, treated as
authoritative): with Warm Hold on, **keyboard-dictate-in-another-app runs in the
backgrounded-but-ALIVE main app**. Therefore during the repro:

- **Host app** (Claude/Slack) that owns the Jot keyboard extension is **FOREGROUND**.
  The keyboard appex is **visible and alive** → it CAN process Darwin notifications.
- **Jot main app** is **BACKGROUNDED but alive** (warm hold). It runs
  `RecordingService` + `PreviewScheduler` and produces the preview — hence the
  producer log above and the working **hero** (the hero is the owner separately
  verifying in-app; it is not on-screen simultaneously with the other app).

This topology matters: the keyboard is NOT suspended, so notification delivery to
it is plausible. The "Listening" the owner sees proves it.

---

## End-to-end cross-process preview path (file:line)

### 1. Producer → projection write + Darwin post (CONFIRMED)

`StreamingPartial.update(text:isFinal:sessionID:)`
(`Jot/App/Transcription/StreamingPartial.swift:96-132`):
- session-token guard `:97` (passes — `sid` matches across the log);
- `streamingText = joined` `:116`;
- logs `preview PUBLISH` `:120-128`;
- `Self.publishProjection(joined, force: isFinal)` `:131`.

`StreamingPartial.publishProjection(_:force:)` `:231-248`:
- throttle: non-`force` publishes coalesced to ≥0.2 s apart `:233-236` (NOT a gate —
  it only drops *extra* publishes inside the window; the next tick still lands);
- `AppGroup.defaults.set(capped, forKey: AppGroup.Keys.streamingPartialText)` `:246`;
- `CrossProcessNotification.post(name: …streamingPartialChanged)` `:247`.

**No `liveText` / `previewSource==batch` / session-token gate exists on the
projection write itself.** Every `update` that passes the token guard writes the
projection (modulo throttle). The write key is the shared suite
`group.com.vineetu.jot.mobile.shared` / `jot.streaming.partialText`
(`Jot/Shared/AppGroup.swift:9,17-22,53`). **Confidence: Confirmed.**

### 2. Darwin notification + observer install (CONFIRMED present)

`CrossProcessNotification.post` uses the Darwin notify center, `deliverImmediately`
(`Jot/Shared/CrossProcessNotification.swift:142-150,170-177`). The callback hops to
`@MainActor` via `Task { @MainActor in token.handler() }` `:189-196`.

Keyboard installs the observer in BOTH `viewDidLoad` and `viewWillAppear`
(`Jot/Keyboard/JotKeyboardViewController.swift:298, 324`) →
`startObservingStreamingPartial()` `:1469-1476`, which adds an observer on
`streamingPartialChanged` whose handler is `refreshStreamingPartialFromProjection()`.
**Confidence: Confirmed installed.** (Teardown nils it in `viewWillDisappear`
`:354` — relevant only if the host app backgrounds; see Hypothesis H4.)

### 3. Keyboard read (the suspect refresh)

`refreshStreamingPartialFromProjection()` `:1478-1485`:
```swift
guard hasFullAccess else { recordingState.updateStreamingPartial(""); return }   // :1479-1482
let text = AppGroup.defaults.string(forKey: AppGroup.Keys.streamingPartialText) ?? ""  // :1483
recordingState.updateStreamingPartial(text)                                       // :1484
```
- **No session-id filter, no `isRecording` gate** on the read — only `hasFullAccess`.
- **There is NO diagnostic log here.** Unlike the loading mirror
  (`refreshStreamingLoadingFromProjection` logs `streaming-loading mirror …` at
  `:1529`), the partial-text refresh logs nothing. **This is why delivery-vs-render
  cannot be settled from the existing logs.**
- **It is the ONLY refresh handler in the whole controller that does NOT call
  `renderRootView()`** (every other observer's refresh ends with `renderRootView()`;
  grep at `:572,631,649,750,762,769,780,790,917,934,939,954,997,1093,1174,1446,1458,
  1571,1591,1640,1742,1788,1797,1807,2127,2167,2173`). It relies **purely on
  `@Observable`** to propagate `recordingState.streamingPartialText` into the live
  SwiftUI tree.

### 4. Keyboard state object (Observable)

`KeyboardRecordingState` is `@MainActor @Observable`
(`Jot/Keyboard/JotKeyboardViewController.swift:2437-2543`). `streamingPartialText`
is a stored `private(set) var` mutated by `updateStreamingPartial(_:)` `:2525-2527`.
`isRecording` is mutated by `applyPipelineProjection(_:)` `:2483-2512` via
`update(isRecording:startedAt:)` `:2514-2517`.

### 5. Keyboard render

`makeKeyboardView()` builds a fresh `KeyboardView` passing `recordingState` as a
plain `let` `:500-503`; hosted as `UIHostingController<AnyView>(rootView:
AnyView(makeKeyboardView()))` `:391-392, 410-411`.

`KeyboardView.body` → `standardModeBody` → `topStrip` → `topStripContent(metrics:)`
(`Jot/Keyboard/KeyboardView.swift:167,194,213,335`):
```swift
if recordingState.isRecording {                          // :336  (strip mount gate)
    StreamingStrip(
        partialText: recordingState.streamingPartialText, // :338
        … loadingLabel: recordingState.loadingVariantLabel.isEmpty ? nil : …,  // :350-352
        statusLine: recordingState.streamingPartialText.isEmpty ? nil : "We tidy this up when you stop") // :357-359
}
```
`StreamingStrip` → `StreamingPane` (`Jot/Keyboard/StreamingStrip.swift:88-98,240`).
Render branches `:291-334`:
- `partialText.isEmpty && loadingLabel != nil && loadRevealed` → `KeyboardLoadingText`;
- `partialText.isEmpty` → `listeningPlaceholder` ("Listening …", `:302-307,480-491`);
- else → `TranscribingText(text: partialText, …)` `:308-333`.

`TranscribingText` (`Jot/App/Design/Components/TranscribingText.swift:66-162`) has a
**build-137 SAFETY NET** `:127-145`: if `reveal.settledText`/`arrivingWord` are both
empty but `text` is non-empty, it draws the full `text` directly. `StreamingWordReveal`
also has the **synchronous first-word paint** `:353-361` and the **isFirstSync
instant reveal** `:329-342`. The keyboard target compiles this exact file
(`Jot/project.yml:331`) and the whole `Keyboard/` dir (`:297`), so the safety net IS
in the appex.

**Render-path conclusion:** with a *non-empty* `partialText`, `StreamingStrip`
cannot legitimately render blank — the `TranscribingText` safety net guarantees the
words draw even if the reveal loop is stranded. So a blank strip while `isRecording`
is true implies **`partialText` is empty in the keyboard's view tree** (delivery /
re-render gap), NOT a stalled renderer. **Confidence: High** that the renderer is
NOT the break.

---

## Resolving the "Listening → blank" contradiction

The contradiction posed: "Listening" disappearing implies `partialText` became
non-empty (delivery worked) → renderer; but if text never arrived, "Listening"
would *persist*, not go blank.

**Resolution (from the code): "blank" is not the `TranscribingText` branch drawing
nothing — it is the strip in a transient empty state where neither the
`listeningPlaceholder` nor a word run is visible to the eye, OR the strip is briefly
between states.** Two concrete mechanisms produce "Listening fades, nothing
replaces it" WITHOUT the renderer ever drawing a non-empty `partialText` blank:

1. **`isRecording` flips true (strip mounts, shows "Listening"), then the
   `streamingPartialChanged`-driven `streamingPartialText` mutation does not
   re-evaluate the body** → the placeholder stays "Listening" forever, and what the
   owner reads as "goes blank" is the **`loadingVariantLabel` / `loadingLabel`
   interaction**: while loading, the pane shows the cold-start line or "Listening";
   if the load label clears (mirror writes empty) *before* any partial re-render,
   the `.task(id: loadingLabel)` resets `loadRevealed=false` (`StreamingStrip.swift:463-473`)
   and the branch falls to `listeningPlaceholder` — which itself is a faint stepping
   ellipsis that can read as "blank-ish" against the glass. The key point: in this
   mechanism **`partialText` in the view is still ""** — delivery/re-render never
   landed the 15 chars.

2. The owner's "at the moment text should arrive shows blank" is consistent with
   **the placeholder NOT being replaced** (empty `partialText` persists) rather than
   a non-empty text drawing blank. Given the build-137 safety net makes
   non-empty-text-blank essentially impossible, mechanism (1) — **never-delivered /
   never-re-rendered** — is the supported reading.

**So: this is a DELIVERY-or-RE-RENDER gap, not a renderer-draws-blank gap.**
**Confidence: ~70%.** The remaining ~30% (a genuine delivered-then-blank renderer
fault) cannot be excluded with certainty because there is no instrumentation proving
what value `partialText` actually held in the keyboard at the blank moment — hence
the probe in the last section.

---

## Hypotheses, ranked

### H1 — `@Observable` re-render does fire for `streamingPartialText`, but the App-Group READ returns "" (stale/empty). LOW (~10%)

Against: the producer writes the projection BEFORE posting the notification
(`StreamingPartial.swift:246` then `:247`), and `UserDefaults` cross-process reads of
a shared suite are coherent by the time the observer's `@MainActor` task runs. No
`clearStreamingPartialForNewSession()` races the publish in the warm-resume path
(the keyboard clears once, at tap time, `:2042`, before the app even resumes). Low.

### H2 — `@Observable` does NOT re-invalidate the body on `streamingPartialText` alone (missing `renderRootView()`). MEDIUM (~30%)

`refreshStreamingPartialFromProjection` `:1478-1485` is the lone refresh that omits
`renderRootView()`. The whole controller is otherwise built on the imperative
"rebuild `rootView` on every state change" model (see the explicit comment at
`:1783` "renderRootView is the one path everything [funnels through]", and
`refreshPipelinePhase` `:1610-1643` which calls `renderRootView()` only in the
`stopRequestPosted` branch).

Counter-evidence that weakens H2: **`isRecording` itself flips via
`applyPipelineProjection` with NO `renderRootView()` on the recording-start path**,
yet "Listening" DOES appear — which proves `@Observable` auto-tracking is *working*
in this hosting setup for at least one property. If observation works for
`isRecording`, it should equally work for `streamingPartialText` read in the same
`body`. So H2 requires a *selective* tracking failure (e.g. the very first body
evaluation that turned the strip on read `streamingPartialText == ""` and, due to a
`@ViewBuilder`/`AnyView`/`Group` boundary, did not register a dependency on it).
Plausible but not proven — this is the single most actionable suspect and the
cheapest to fix (add `renderRootView()`), so it is the **prime fix candidate** even
though confidence is only medium.

### H3 — `hasFullAccess` reads false at notification time → forced "" `:1479-1482`. LOW (~5%)

The same FA gate guards the loading mirror and pipeline refresh; since "Listening"
and the loading affordance appear, FA is on at that point. A transient FA flip
exactly on the partial-notify wake is unlikely. Low.

### H4 — observer torn down (host backgrounded) so the partial notify is never processed. LOW for THIS repro (~5%)

In the **warm-resume cross-app** topology the keyboard's host stays FOREGROUND, so
`viewWillDisappear` (which nils `streamingPartialObserver` `:354`) does NOT fire.
"Listening" arriving via the *same* observer-install pattern confirms observers are
live. (This H would dominate a **cold-bounce** repro where Jot foregrounds and the
host app backgrounds — but then the keyboard isn't on-screen at all, which doesn't
match "keyboard shows Listening then blank".) Low for this repro; keep in mind if
the owner's repro turns out to be cold-bounce.

### H5 — renderer genuinely draws non-empty text blank (StreamingWordReveal advance loop never scheduled in the appex AND the safety net fails). VERY LOW (~3%)

Refuted by the build-137 safety net `:127-145`, which draws full `text`
independent of the reveal loop. For this to fail, `text` itself must be empty in
`TranscribingText` — which collapses back into H2/H1 (delivery/re-render), not a
renderer fault. The advance `Task` is a `@MainActor` `Task` (`TranscribingText.swift:410`);
a starved appex main runloop would delay the *animation*, never blank the *text*,
because of the safety net + synchronous first-word paint. Very low.

### H6 — EOU vs batch path difference / vocab toggle. VERY LOW (~2%)

`previewSource` defaults to `"batch"` (`AppGroup.swift:416-425`) and the log shows
the batch scheduler ran. The projection write is identical for EOU and batch (both
go through `StreamingPartial.update → publishProjection`). The vocab toggle changes
rescoring, not the projection write. No path here gates the keyboard render. Very low.

**Overall:** the break is **delivery-or-re-render (H2 ≫ H1 ≫ H3/H4), NOT the
renderer (H5/H6)**. Best single root-cause candidate: **H2 — the streaming-partial
refresh is the only state mutation that does not force a `renderRootView()`, and the
`@Observable`-only path is not reliably re-invalidating the body for
`streamingPartialText` on the cross-process wake.**

---

## Why I will not ship a fix yet (confidence < 80% on delivery-vs-render)

Static analysis shows both delivery and render *should* work, and the one piece of
live evidence ("Listening" appears) proves `@Observable` reactivity is not globally
dead. I cannot reach >80% on **which** of (a) the keyboard never reads the 15 chars,
(b) it reads them but the body never re-evaluates, or (c) it reads + re-evaluates but
something downstream blanks it — because **there is zero instrumentation on the
keyboard's streaming-partial receive path.** Per the project's diagnostic-first rule
(MEMORY: "Don't be overconfident on bugs"; "Reason from symptoms, then a minimal
probe"), the next step is a probe, not a patch.

## Minimal probe to settle delivery-vs-render (one build, no behavior change)

Add ONE diagnostic line inside `refreshStreamingPartialFromProjection`
(`Jot/Keyboard/JotKeyboardViewController.swift:1478-1485`), mirroring the existing
`streaming-loading mirror` log shape at `:1529`:

```swift
private func refreshStreamingPartialFromProjection() {
    guard hasFullAccess else {
        keyboardLog.info("streaming-partial mirror: NO Full Access")   // probe
        recordingState.updateStreamingPartial("")
        return
    }
    let text = AppGroup.defaults.string(forKey: AppGroup.Keys.streamingPartialText) ?? ""
    keyboardLog.info("streaming-partial mirror chars=\(text.count, privacy: .public) isRecording=\(self.recordingState.isRecording, privacy: .public)")  // probe
    recordingState.updateStreamingPartial(text)
}
```

Interpretation of a failing-run Console capture (filter
`subsystem == com.vineetu.jot.mobile.Jot.Keyboard`):

| Observation | Verdict |
|---|---|
| `streaming-partial mirror` **never logs** during the recording | **Delivery gap** — Darwin notify not reaching the keyboard observer (revisit H4 / observer lifecycle). |
| logs `chars=0` (or `NO Full Access`) repeatedly while `isRecording=true` | **Read gap** — projection empty in the appex / FA flip (H1 / H3); chase the App-Group write/read coherence or a racing clear. |
| logs `chars=15 isRecording=true` but the strip stays blank | **Re-render gap** — value delivered, body not re-invalidated → **H2 confirmed**; fix = call `renderRootView()` (see below). |

Because the probe is a single `os.log` line on an existing code path, it is
behavior-neutral and safe to ship for one diagnostic build.

## Fix plan (apply ONLY after the probe confirms the branch)

- **If H2 (re-render gap) confirmed — ROOT-CAUSE fix, not a band-aid:**
  Make the streaming-partial refresh consistent with every other observer in the
  controller: re-render the hosted tree when the value changes. Two acceptable
  shapes, pick per the probe:
  1. Minimal + consistent: in `refreshStreamingPartialFromProjection`, after
     `recordingState.updateStreamingPartial(text)`, call `renderRootView()` **only
     when the value actually changed** (guard on prior value to avoid per-tick
     rebuild churn at ~5 Hz — mirror the `historyMirrorUpdated` "snapshot, refresh,
     re-render only on change" pattern `:986-998`). This treats the imperative
     `renderRootView()` as the keyboard's real re-render contract (which the rest of
     the file already assumes) and stops relying on a partial-only `@Observable`
     edge that demonstrably under-fires.
  2. Deeper (preferred if we want to KEEP the `@Observable` contract): determine
     why the `streamingPartialText` read isn't registering as a dependency on the
     strip-mount render. Candidate: the first body pass that turned the strip on
     read `streamingPartialText == ""` inside the `@ViewBuilder topStripContent`
     and the dependency wasn't installed across the `AnyView`/`Group` boundary.
     If reproducible, the structural fix is to read `streamingPartialText` at a
     stable point in `body` (not only inside a conditional `@ViewBuilder`), so the
     dependency is always registered. This is the truer root cause but needs the
     probe + a focused SwiftUI repro before committing.

  Recommendation: ship **(1)** as the reliable, consistent fix (it matches the
  file's own re-render model and is what the other 25+ call sites already do), and
  open a follow-up to investigate **(2)** so the `@Observable` path can be trusted
  or removed.

- **If delivery gap (mirror never logs):** investigate observer lifecycle vs the
  warm-resume background topology — confirm the host app truly stays foreground in
  the repro, and whether a brief host re-mount nils the observer between
  `viewWillDisappear`/`viewWillAppear`. Re-arm the streaming observer on the same
  wakeups that re-arm pipeline/loading (already done at `:324`), and consider a
  post-`pipelinePhaseChanged` `refreshStreamingPartialFromProjection()` sweep so a
  dropped partial-notify is recovered by the next phase heartbeat.

- **If read gap (`chars=0`):** audit for a racing `clearStreamingPartialForNewSession`
  (`:1495-1500`) write or an FA flip; confirm the App-Group suite read coherence
  across the process boundary.

Do NOT add retries, do NOT conflate with the paste bug, do NOT touch the producer
(`StreamingPartial`) — it is confirmed correct.

## Out of scope (explicitly)

- Auto-paste failure on stop → `docs/plans/bug-keyboard-paste-fails-claude-code.md`
  and `bug-keyboard-recording-not-shown-in-app.md`.
- Hero rendering — confirmed working; it reads the in-process `StreamingPartial`
  directly via `@Environment(StreamingPartial.self)` (`RecordingHeroView.swift:111,
  362,507`) and never depends on the App-Group projection.

## Registry note (do when this graduates from diagnosis)

Per `Jot/CLAUDE.md`, add a dual entry in `Jot/known-bugs-and-plans.md` (detailed +
one-line index) linking this doc, so it is discoverable.
