# Record & Transcript — UX Research

Surface owned: home/landing, record states, live + delivered transcript, history library (`List` + Copy + Delete + `.searchable`), eventual `NavigationLink` detail + playback.

## TL;DR

- **Default Apple-native.** `NavigationStack` + `List` + `.searchable` + `.sheet` + `Form` + `.swipeActions` + `.contextMenu` + system materials + `.accentColor`. iOS 26 Liquid Glass adopted by *opting in* to platform defaults — not painted on by hand.
- **Deviate exactly once: the Record capsule, patterned after Superwhisper.** A morphing `.glassEffect(.regular).interactive()` capsule that walks Idle → Recording → Transcribing → Delivered → Failed inside one `GlassEffectContainer`. **Superwhisper's Mac floating pill + result card is the primary reference** — monochrome ground, single accent, restrained motion, model-aware status copy, result text inside the same surface that held the recording state. Wispr Flow / Linear / Things are secondary. Everything else is stock SwiftUI.
- **Open → auto-start.** On `scenePhase → .active` with model ready, fire `recordingService.start()` on first frame. Manual fallback: tap the capsule. Tejas's `RecordingService` is golden — keep it bit-for-bit.
- **One screen.** `NavigationStack` rooted at `RecordHomeView`: capsule on top, `List` of past transcripts below (newest first), `.searchable` in the nav area, toolbar gear → `SettingsView` sheet. No `TabView` in MVP 1 — Voice Memos is the precedent.
- **MVP 2** adds keyboard-launched hot-path entry + 60 s warm-resume so the user can switch apps and resume the same session.

## Full Vision

Native iOS utility — Voice Memos crossed with the Mac Jot's hairline aesthetic. One purpose, one primary control, history right there.

Stock `NavigationStack`. Toolbar: large title `"Jot"` + trailing `gearshape` → Settings sheet. Top of scroll: the Record capsule (the one custom view). Below: `List` of `Transcript` rows from `@Query` over `JotModelContainer.shared`, `createdAt` descending. Search via `.searchable(placement: .navigationBarDrawer(displayMode: .always))` — iOS 26 auto-glassifies. Empty state: `ContentUnavailableView("No transcripts yet", systemImage: "mic", description: Text("Tap to dictate."))`.

The Record capsule is the **only** custom-drawn surface. Everything else (rows, search, swipe actions, alerts, sheets, settings) is system. Surrounding the morphing capsule with stock SwiftUI is what makes it read as the focal object instead of one custom thing among many.

### Record capsule (Superwhisper-patterned)

`Capsule()` with `.glassEffect(.regular).interactive().tint(.accentColor)` (system accent, no hex), wrapped in `GlassEffectContainer` so morphs are continuous. Discipline mirrors **Superwhisper's Mac pill**: monochrome surface, motion in opacity + size, never spring/bounce, status copy *names* the model state.

- **Idle** — ~160 pt, `mic.fill`, label `"Tap to dictate"` (`.subheadline .secondary`).
- **Recording** — ~180 pt with internal amplitude bars from `RecordingService.currentAmplitude` at 80 ms cadence (keep Tejas's publisher). Elapsed timer `.monospacedDigit() .footnote`. Stop = tap. Headline `"Listening…"`. MVP 2 sub-label: `"You can switch back to your other app — Jot keeps listening."`
- **Transcribing** — ~120 pt with centered `ProgressView().tint(.accentColor)`. Label `"Transcribing…"`. When `transcriptionService.modelState != .ready`, swap to `"Loading model…"` + Tejas's `"first transcription may take ~30s"` — name the state honestly.
- **Delivered** — **result lands inside the capsule for ~1.5 s before fading to a row** (Superwhisper pill→card). Capsule expands into a rounded card holding the transcript with a small `Copy` glyph; auto-Copy via `ClipboardHandoff.publish` runs as it lands; `"Copied"` confirmation under for ~1.3 s. After ~1.5 s the card dissolves and the row appears in the `List` via `.transition(.opacity.combined(with: .move(edge: .top)))`.
- **Failed** — `exclamationmark.triangle.fill` (`.orange`), `Text(error.localizedDescription)`, `Button("Try again").buttonStyle(.bordered)`. Surface real `RecordingError` / `TranscriptionError` strings — Tejas's `CustomNSError` work made them good.

### History rows — stock List

`NavigationLink(value: t)` per row → 2-line `Text(t.displayText).lineLimit(2)` + monospaced timestamp/duration footer. `.swipeActions(edge: .trailing)`: `Delete` (destructive) + `Copy` (`.accentColor`). `.contextMenu`: Copy + ShareLink (Tier 2) + Delete. `.listStyle(.plain)`. Delete uses system `alert`; Copy fires success haptic + VoiceOver `"Copied to clipboard"`.

### Settings — Form in a sheet

`NavigationStack { Form { … } }` inside a `.sheet`. Sections: Recordings (`Picker("Keep recordings")` — Forever / 7 / 30 / 90), Permissions (`LabeledContent("Microphone")` + open-Settings button), `Button("Re-run setup")`. Toolbar `Done`. All stock.

## MVP 1 Scope

Auto-start on open when model is ready (gated — see Open Question 1). Model download on first launch via `.fullScreenCover` with `ProgressView(value:)` + `"Downloading speech model — about 1.25 GB"`. Manual fallback: tap the capsule; all state driven by `RecordingService` + `TranscriptionService` exactly as Tejas wired them. Auto-Copy on delivery via `ClipboardHandoff.publish(transcript:)`; per-row `Copy` for explicit re-copy. Per-row Delete via `.swipeActions` + system alert. `.searchable`-driven client-side substring filter on `text` + `cleanedText`. History list newest-first via `@Query(sort: \Transcript.createdAt, order: .reverse)`. Settings sheet as above. English only.

**Out of scope:** rolling preview, silent-capture detection, follow-up window, cleanup pass, keyboard extension, playback, full Detail view, retranscribe, Live Activity, Dynamic Island, AI pane, vocabulary, share sheet.

## MVP 2 Scope

Keyboard hot-path + 60 s warm-resume. Zero new screens — same `RecordHomeView`, new entry vector and lifecycle.

Keyboard mic tap fires `jot://record`; `JotApp.onOpenURL` flags the scene hot-path and forces auto-start (overrides MVP 1 gating). `UIBackgroundModes: audio` declared so mic stays live when the user swipes back to the host app; the keyboard's `Paste transcription` row inserts at cursor within `ClipboardHandoff`'s 30 s freshness window. **60 s warm-resume window:** on Stop in hot-path mode, hold `AVAudioSession` active for 60 s in a new `RecordingService` substate; status as `.footnote .secondary` under the capsule: `"Holding for 60s — tap to resume"`. Reopen via keyboard within the window → capsule re-enters Recording with samples preserved; after 60 s, `forceStop()` finalizes as if Stop had been pressed. **Live Activity** (probably here): `"Jot listening · 0:14"` + Stop button (`NSSupportsLiveActivities` already declared). **Hot-path delivered** adds one `.callout .secondary` line: `"Swipe up to return to <hostApp>"` (host inferred from URL `source` param).

**Honored constraint:** no zero-bounce Action Button. `AVAudioEngine.start()` cannot start cold from background (Tejas's repro + Apple DTS confirmation). Brief foreground bounce stays.

## Future Tiers

Rough user-value order: **Detail view** (`NavigationLink` push; `.textSelection(.enabled)`, waveform port, playback, share). **Rolling preview** (last ~2 s of streaming transcript as `.callout .secondary` under the capsule). **Silent-capture detection** (port `AudioCaptureError.bluetoothSilentRoute`). **Re-transcribe** (`.contextMenu` action against stored WAV). **`ShareLink`** (wire the existing sketch). **Cleanup pass** (Apple Foundation Models toggle; `wasCleaned` already in schema). **Follow-up rewrite window** — Tejas's flagship 30 s post-delivery window; classify next utterance as command vs new dictation; render cluster (parent + indented descendants). Keep schema fields (`derivedFromID`, `instruction`, `supersededAt`) in MVP 1 even unrendered so we never migrate. **Live Activity / Dynamic Island** for timer + spinner + follow-up countdown. **Date-grouped `List` sections** once it outgrows ~15 rows (stock `Section(header:)`). **Background warm-keep** of the Parakeet ANE cache via `BGProcessingTask`. **`TabView` promotion** when Settings + Help + AI need first-class real estate (iOS 26 `.tabBarMinimizeBehavior(.onScrollDown)`).

## State Diagram

### Record capsule

```
ModelMissing → download → Idle | DownloadFailed → Try again → ModelMissing
Idle → tap capsule | scene .active + ready + auto-start eligible → Recording
Idle → gear → Settings sheet (capsule unchanged)
Recording → tap capsule → Transcribing
Recording → interruption (call/Siri) → Recording-Interrupted-Stopped (internalStop preserves samples)
Recording → route .oldDeviceUnavailable | engine config change → Failed
Recording → scenePhase .background → MVP 1: Failed (forceStop) | MVP 2: continues (UIBackgroundModes: audio)
Recording-Interrupted-Stopped → tap capsule → Transcribing (drains preserved samples)
Transcribing → success non-empty → Delivered | success empty → Idle + toast "No speech detected" | fail → Failed
Delivered → auto-Copy publish + ~1.5s in capsule → Idle (row appears in list)
Delivered → tap capsule → Recording (immediate re-record)
Failed → Try again | auto 8s → Idle (error stays inline above capsule until dismissed)
Failed → tap capsule → Recording

// MVP 2 only
Delivered (hot-path) → auto ~1.5s → WarmHold
WarmHold → reopen via keyboard <60s | tap capsule → Recording
WarmHold → 60s elapsed → Idle (forceStop; session torn down)
```

### History list interactions

- Row tap → `NavigationLink` push to Detail (Tier 2; no-op MVP 1).
- Row swipe-trailing → `Copy` (pasteboard + success haptic + VoiceOver "Copied") or `Delete` (alert "Delete this entry?" → confirm or cancel).
- Row long-press → `.contextMenu` {Copy, Share (Tier 2), Delete}.
- Pull-down → `.searchable` field appears; typing filters `text` + `cleanedText` case-insensitively.
- Empty list → `ContentUnavailableView("No transcripts yet", systemImage: "mic")`.

## Open Questions

1. **Auto-start gating.** Always-on auto-start fits MVP 2's keyboard hot path but breaks casual home-screen opens (user picks up phone to glance at history → mic blares). Proposed gate: auto-start only when (a) launched via URL scheme, OR (b) `scenePhase` transitioned from `.inactive` (cold launch / first foreground), AND (c) ≥ 10 s since last `.delivered`. Confirm or override?
2. **History sort direction.** Capsule-on-top pushes toward `newest at top` (matches Voice Memos, plays nicely with `.searchable` in the nav area). Tejas's bottom-anchored feel was tied to his bottom-pill. I'm proposing newest-at-top; confirm.
3. **Pill→card hold duration.** Superwhisper-style: result lands in the capsule for ~1.5 s, then dissolves to a row. Confirm ~1.5 s reads right (long enough for short transcripts, snappy on rapid-fire).
4. **Warm-hold visibility (MVP 2).** Show the 60 s countdown prominently or keep it quiet? My lean: visible for the first ~5 sessions per `@AppStorage` learning flag, then quiet.
5. **Single-screen vs `TabView`.** Voice Memos (single screen) vs Reminders (tabs). My lean: single screen for MVP 1, promote to `TabView` only when Settings + Help/AI need first-class real estate.
6. **Light vs. dark default.** iOS 26 Liquid Glass renders cleanly in both; iOS handoff was light-default-with-dark-adaptive; Tejas locked dark-only. Native answer: respect system. Confirm we drop the dark-lock.
7. **Cleanup-toggle placement (when it lands).** Settings row, or inline on Delivered as a `Toggle`? Inline reads more "alive" but adds chrome to the focal object. I lean Settings-only.

## References

**Design references (third-party):**

- **Superwhisper (Mac)** — primary reference for the Record capsule deviation. Floating pill morphs into a result card in place; monochrome ground; restrained motion; status copy that names the model state (`"Loading model…"`, `"Listening…"`, `"Transcribing…"`); result text appears inside the same surface that just held the recording state before fading out. <https://superwhisper.com>
- **Wispr Flow (iOS)** — secondary, for keyboard-extension chip layout and history-folded-into-home pattern (informs MVP 2 keyboard work, not MVP 1 layout).
- **Linear / Things** — secondary, for restrained list rows and the discipline of *not* overdecorating system list chrome.

**Codebase:**

- `/Users/vsriram/code/jot-mobile/Jot/App/ContentView.swift:30-1320` — Tejas's Ledger (golden behavior + chrome we're replacing)
- `/Users/vsriram/code/jot-mobile/Jot/App/Recording/RecordingService.swift:63-322` — singleton, start/stop/forceStop, interruption + route handling, normalizedAmplitude curve
- `/Users/vsriram/code/jot-mobile/Jot/Shared/Transcript.swift:31-116` — SwiftData @Model
- `/Users/vsriram/code/jot-mobile/Jot/Shared/TranscriptStore.swift:48-264` — JotModelContainer.shared, append, mostRecent, markSuperseded
- `/Users/vsriram/code/jot-mobile/Jot/Shared/ClipboardHandoff.swift:11-87` — publish + 30 s freshness window
- `/Users/vsriram/code/jot-mobile/EXPERIMENTS.md:42-86` — Action-Button limits, "no zero-bounce" platform constraint
- `/Users/vsriram/code/jot-mobile/README.md:1-78` — locked product positioning + follow-up window vision
- `/Users/vsriram/code/jot/iOS/docs/features.md:1-232` — feature inventory + tier assignments
- `/Users/vsriram/code/jot/iOS/docs/handoff/app-layout-design.md:14-555` — Liquid Glass thesis, hot-path/cold-path split, Library + Detail layouts
- `/Users/vsriram/code/jot/iOS/docs/handoff/audio.md:32-180` — `.record/.measurement`, interruption matrix, silent-capture detection
- `/Users/vsriram/code/jot/iOS/docs/handoff/recordings.md:34-225` — schema deltas, retention, search, retranscribe contract
- `/Users/vsriram/code/jot/iOS/docs/handoff/keyboard-status-bar-design.md:46-202` — Wispr-style chip layout (for future keyboard waveform parity)
