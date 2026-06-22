# Apple Watch redesign — design + port plan

Status: brainstorm decisions locked (2026-06-19). Implementation pending.

## Goal

Recreate the high-fidelity watchOS handoff (`design_handoff_watch_redesign`,
project `jot-ios` on claude.ai/design) in the SwiftUI watch target, swapping the
HTML/React prototype for native watchOS equivalents. This is a **visual + IA
refresh** of the existing, working watch app — the sync/record/transcribe
plumbing underneath is untouched.

Source of truth for visuals: the handoff `README.md` + the three JSX files
(`watch-ui.jsx` tokens/glyphs, `watch-screens.jsx` screens). Treat the JSX as a
precise spec, not code to port line-for-line.

Owner verbal direction (2026-06-19):
- Dictate button → round blue button with a slow glow.
- Tapping it → same-size red/coral button with the timer **inside** it; no "Stop" word on the button.
- The ugly orange "pending sync" button is gone — surface pending **in the Recents list** instead, tagged subtly.
- Transcript view + Diagnostics are "good enough" already.

## Key finding that shaped the plan (read first)

The watch's Recents list is **only transcripts the phone has already
transcribed and pushed back down** (`WatchTranscriptStore`, read-only, has
text). On the watch, a "pending" item is an **audio recording with no text
yet** — either queued (phone unreachable: `WatchSyncQueue.pendingFiles`) or
in-flight ("Transcribing…": `WatchPendingTranscribingStore.entries`). The moment
an item has text, it is already synced.

So the handoff mockup's `synced: false` *note-with-body* does not exist in this
architecture. "Pending in Recents" therefore means: **show the textless
queued/transcribing recordings as placeholder rows at the top of Recents,
tagged subtly** — not a note that has text but hasn't synced.

## Decisions (locked)

1. **Pending representation** — pending/transcribing recordings render as
   subtle-tag rows at the **top of the Recents list**: small orange dot +
   "Waiting to sync" (queued) / "Transcribing…" (in-flight) + relative time.
   No big orange button. Row is replaced in place by the real transcript when
   the phone returns text. (Builds on the existing `TranscribingRow`.)
2. **Diagnostics entry** — keep the existing quiet **"Sync diagnostics ›"
   footer link at the bottom** of the Home scroll. Sync is automatic; if the
   user wants to force it they scroll down and Reset sync there. Remove the
   top-of-screen orange ribbon.

## Deviations from the handoff (defaulted; owner can veto)

- **No green "✓ N synced" ribbon on Home.** The handoff removes all top-of-Home
  ribbons; the pending row vanishing (→ becomes a transcript) is the quiet
  success signal. Cleaner, matches "it just syncs automatically."
- **No ✕ / cancel on the Recording screen.** The app's standing invariant is
  *no Cancel — the only exit is Stop, because silent data loss from an
  accidental cancel is worse* (`RecordingView` header + "never force-stop the
  mic"). The handoff's top-left ✕ is a prototype nav artifact; honoring it as a
  discard would break that invariant, and honoring it as "stop+save" makes a
  ✕ glyph mean the opposite of cancel. So: **omit the ✕**; the coral timer
  circle is the stop affordance.
- **Custom TimeChip dropped.** watchOS draws the system clock + the orange mic
  recording indicator itself; the handoff's `TimeChip` is an HTML stand-in. Not
  implemented.
- **Custom SubNav/back/close buttons dropped.** `NavigationStack` provides the
  native back chevron on subviews. The handoff `SubNav`/`RoundBtn` are prototype
  chrome.
- **"Tap to stop" caption kept** (subtle, below the waveform) for
  discoverability — the *button* has no "Stop" word per the owner; this is a
  one-line hint, not a labeled button. Flagged for owner review; trivial to drop.
- **Diagnostics escalation banner kept** ("Still stuck? Restart your Watch" after
  2 resets). Not in the handoff but a real safety net for the known watchOS
  WCSession daemon bug; additive, only shows after 2 failed resets.

## Token additions (`JotDesignWatchSafe.swift`)

Add (mirror into `JotDesign.swift` per the single-source-of-truth contract only
if they're reused on iOS — these are watch-hero-specific, so watch-only is fine,
but note the divergence):

- `watchDictateHero` — RadialGradient, center (0.5, 0.3): `#5BB4FF → #1B86F0 (52%) → #0061C8`.
- `watchRecordHero` — RadialGradient, center (0.5, 0.3): `#FF8E7A → #FF6B57 (52%) → #E0533F`.
- `watchRecordWave` — `#FF6B57` (coral waveform; replaces blue `jotAccent` bars while recording).
- `watchDictateGlow` — `#1A8CFF @ 0.30`; `watchRecordGlow` — `#FF6B57 @ 0.32` (blurred circle behind heroes).
- `jotBlueGrad` linear pill gradient (168°: `#3AA0FF → #1483F2 → #0064CC`) for the Reset-sync pill. (`jotBlueTop/Bottom` already exist.)

## Per-screen port plan (pseudocode)

### Home — `RootView.swift`
```
VStack {
  DictateHero            // was MicButton capsule
  "Tap to dictate"       // 17pt semibold, centered
  RecentSection          // header row + 3 cards (pending first)
  diagnosticsFooter      // unchanged, stays at bottom
}
// REMOVED: syncRibbons (amber pending + green synced), "Last synced" caption on Home
// REMOVED: .navigationTitle("Jot") — no app-name title; we're already in the Watch app,
//          so Home opens directly on the record button (matches handoff: wordmark removed).

DictateHero =
  ZStack {
    Circle().fill(watchDictateGlow).blur(...).scaleEffect(glow inset ~ -32 → frame larger)
    Circle().fill(watchDictateHero)
      .frame(132×132)
      .overlay(MicGlyph 46pt white)
      .shadow(inner top-highlight + bottom-shade approximated via overlays/strokes)
      .scaleEffect(breathing ? 1.035 : 1.0)   // 4.5s ease-in-out repeatForever; disabled if reduceMotion
      .scaleEffect(pressed ? 0.95 : 1.0)
  }
  // tap → full-check then showingRecording (keep isFull alert + haptics)

RecentSection =
  HStack { "Recent" (14/600 secondary);  Spacer;  "All \(count)" (14/600 blue) → AllNotes }  // "All N" only when total > 3
  ForEach(pendingRows) { WatchPendingCell }       // queued + transcribing, capturedAt desc
  ForEach(transcripts.prefix(3)) { WatchNoteCell → Detail }
  // empty state unchanged when no transcripts AND no pending
```

### Note + pending cells — `WatchPrimitives.swift`
```
WatchNoteCell(transcript) =        // individual rounded card (radius 22), NOT a grouped row
  Button → VStack(alignment:.leading) {
    Text(preview).font(17.5,600).lineLimit(1).truncationMode(.tail)
    Text(relativeDate).font(13.5,400).secondary
  }.padding(13,16).background(cardGradient + hairline).cornerRadius(22)
  // watch-origin glyph stays inline with the date

WatchPendingCell(item) =           // same card shell
  HStack { orangeDot(or spinner);  VStack { Text(label); Text(relTime) } }
  // label: "Transcribing…" (in-flight) | "Waiting to sync" (queued)
```
Note: handoff uses **individual cards per note** (8pt gap), replacing today's
single `WatchCard` with internal dividers. Port the per-card treatment on both
Home and AllNotes.

### Recording — `RecordingView.swift`
```
ZStack/VStack {
  RecordHero (coral 132×132, center timer mm:ss 34/700 tabular, coral glow behind, breathe)
     → tap = stopAndSave()  (saving ? ProgressView replaces timer : timer)
  Waveform: ~21 coral bars, center-weighted, white→coral gradient + glow   // hidden under AOD/ReduceMotion
  "Tap to stop" caption (subtle)                                            // flagged; no "Stop" on button
  cap-warning banner unchanged
}
// REMOVED: blue Stop pill, red dot+timer row (timer now lives inside the circle), ✕
// KEEP: 15-min cap, warn at 14:30, extended runtime session, no swipe-dismiss, error alert, haptics
```

### All notes — `RecentTranscriptsView.swift`
Port to individual `WatchNoteCell` cards + `WatchPendingCell` rows at top.
Title "Recents". Native nav back. Keep "Last synced" footer here (only removed
from Home).

### Transcript detail — `TranscriptDetailView.swift`
Body bumped to ~21/500. Add a sync-status row at the bottom: green check +
"Synced to iPhone" (real transcripts are always synced). Keep "Recorded on
watch" glyph. Inline title = the note's date.

### Diagnostics — `DiagnosticsView.swift`
Mostly unchanged (owner: good). Restyle "Reset sync" to the full-width blue
gradient pill (height 56, radius 28). Keep status card, "N waiting to sync"
orange line, helper caption, escalation banner.

## Out of scope / untouched
- `WatchRecorder`, `WatchSyncQueue`, `WatchConnectivityClient`,
  `WatchTranscriptStore`, `WatchPendingTranscribingStore` logic — visual layer
  only reads them. (Home may need a small read-only "combined pending list"
  computed from queue + transcribing store.)
- Complications / Smart Stack tile (`JotWatchApp.swift` deep-link routing).
- 50-recording cap + full alert.

## features.md / ARCHITECTURE.md sync (after impl)
- `features.md §2.13` paragraphs: **Watch home screen** (drop amber ribbon +
  green ribbon + Last-synced-on-Home; describe round glowing Dictate button,
  pending-in-Recents rows, bottom Sync-diagnostics footer), **Recording sheet**
  (coral circle with timer inside, no Stop button/word, no Cancel), **Recent
  transcript list** (pending rows at top tagged subtly). Keep cross-links.
- `ARCHITECTURE.md`: no subsystem/boundary change → likely no edit. Verify the
  watch row still reads true.

## Shipped notes (post-impl)
- Hero diameter is **proportional to the watch screen**, not the handoff's fixed
  132 (which is 2× pixel scale and looks oversized as points). `WatchMetrics`
  derives it from `WKInterfaceDevice.screenBounds.width`: ~50% of width, clamped
  to 78…104pt. Verified on-sim: 42mm→88, 44mm→92, 49mm→104. The mic glyph
  (0.38×d) and recording timer (0.27×d, matching the spec's 34/132 ratio) scale
  with it. The handoff's absolute sizes are treated as a suggestion.
- Pending cards (`WatchPendingCell`) are the **exact same size** as transcript
  cards (`WatchNoteCell`): identical VStack/fonts/padding/card, title at the same
  left edge and full content width. The amber status dot is a trailing OVERLAY
  (not in-flow) so it never steals width from the title.
- **watchOS 26 `interactiveDismissDisabled(true)` does NOT suppress the system
  sheet ✕** (verified on-sim — tapping it dismisses + ran the old discard path).
  So the handoff's ✕ is satisfied by system chrome, and `RecordingView.cleanup()`
  now SAVES on any dismiss-while-recording (was `cancelIfActive()` discard) —
  repairing a latent data-loss bug and upholding "never lose audio."
- The "Sync diagnostics" footer label can scale down on watches set to large
  text sizes (it's a `.caption2` utility row); verified it stays one line via
  `minimumScaleFactor`. Cosmetic, below the fold.

## Review plan
1. Implement.
2. Design-fidelity review (impl vs handoff: dims/tokens/copy/motion) +
   correctness/adversarial review (data model, reduce-motion, save path, no
   regressions to sync/cap).
3. Fix, re-review.
4. Hand to owner for on-device test. Ship only on explicit go.
```
