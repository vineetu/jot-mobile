# Watch Dictation — UX Design Spec (v3 — post second adversarial review)

> **v3 changelog** (round-2 fixes that needed concrete patches, not just rephrasing):
> - `JotDesign.swift` imports UIKit and won't compile for watchOS — solution: create a new platform-agnostic `Jot/Shared/JotDesignWatchSafe.swift` that re-exports the colors using SwiftUI `Color(red:green:blue:)` literals so it compiles for both iOS and watchOS targets. The watch target imports only this file, never `JotDesign.swift` directly.
> - Schema V5 reconciled: V5 adds BOTH `source: String?` AND `watchOriginUUID: String?`. Plan doc + design doc agree on this.
> - 15-minute recording requires `WKExtendedRuntimeSession` (default watch apps suspend within ~3 min when wrist lowers). Concrete API noted in RecordingView spec.
> - AOD signal corrected: `@Environment(\.isLuminanceReduced)` is the right indicator, NOT `scenePhase == .background`. Fixed.
> - Smart Stack relevance v1 scope locked: 0.5 always-on for v1, history-based escalation deferred to v1.1. Removed self-contradiction.
> - Drop-oldest at cap rule replaced with "block new recording + show 'Open iPhone to sync' prompt" (fail-closed but explicit, consistent with the C5 fix that disallowed accidental data loss).
> - Smaller fixes: REC text placement specified, ack haptic coalescing, ribbon window definition, transferUserInfo idempotency on both sides, ExtendedRuntimeSession + permission flow + Bluetooth routing + sheet dismissal + iCloud restore payload + localization all spec'd.

---


> Companion to `docs/plans/watch-dictation.md`. The plan covers architecture (targets, sync, schema); this doc covers what the user actually sees and touches.
>
> **Design ethos source:** Color/typography/motion tokens lifted from `/Users/vsriram/code/jot-mobile/Jot/App/Design/JotDesign.swift` (the iPhone app's canonical design system). The watch app inherits the iPhone palette — coral CTAs (`jotAccent`), red recording cue (`jotRecord` / `jotRecordingDot`) — not a new blue brand.
>
> **Deployment target:** watchOS 26.0+ (Apple Watch Series 8 + watchOS 26 baseline). Native watchOS chrome (toolbars, sheets, container backgrounds) provides whatever Liquid Glass affordances watchOS exposes; we **do not** rely on `.glassEffect()` directly because that modifier is iOS/macOS-only as of watchOS 26.

---

## Design principles

1. **Frictionless capture.** One tap from the watch face → recording. No login, no setup, no menus to traverse.
2. **Recording state is unmistakable** — including under Always-On Display, Reduce Motion, and bright sunlight. The red dot is the load-bearing cue; we redundantly back it with always-on text ("REC") when motion is reduced.
3. **No serif on watch.** System SF only with Dynamic Type. Serif italic is a phone/Mac luxury that disappears below ~24pt.
4. **Native chrome only.** SwiftUI primitives + Apple's built-in materials. Don't hand-roll glass on watch; the screen is too small for the highlight/shadow recipe to read, and `.glassEffect()` isn't available here anyway.
5. **Recording = coral. Live recording dot = red. Pending-sync = amber. That's the entire palette.** No invented tokens; all colors come from `JotDesign.swift` so the watch matches the phone.
6. **No editing, no rewrite display, no share on watch v1.** Tap a recent transcript → read it. That's it. All write/transform flows live on phone.
7. **Status > chrome.** When something is happening (recording, syncing, transcribing), show it as text. Hide it when idle. Celebrate sync events with a brief success ribbon so the deferred-sync model is visible.

---

## Color tokens (watch-scoped subset)

Pulled from a new platform-agnostic `Jot/Shared/JotDesignWatchSafe.swift` file that re-exports color/typography/motion tokens from `JotDesign.swift` using SwiftUI primitives (no `UIColor`, no `UIKit`, no `import UIKit`). This file compiles for both iOS and watchOS targets. The watch target imports `JotDesignWatchSafe.swift`, never `JotDesign.swift` directly. iOS-side, `JotDesign.swift` continues to reference these same tokens for parity.

No new BRAND tokens — every color below is already in `JotDesign.swift` for iOS; the watch-safe file is purely a re-export.

| Token | Source line | Use on watch |
|---|---|---|
| `jotAccent` | `JotDesign.swift:35` (coral `#FF6B5C`) | Primary CTA — mic button, "Dictate" capsule, anything tappable that initiates a flow |
| `jotRecord` | `JotDesign.swift:39` (orange-red `#FF3B30`) | Stop button while recording. Distinct from `jotAccent` so it never reads as a generic CTA |
| `jotRecordingDot` | `JotDesign.swift:677` (`#E0173B`) | The pulsing dot — live recording indicator only |
| `jotRecordingHalo` | `JotDesign.swift:680` (red @ 0.18 alpha) | Soft outer halo behind the dot |
| `jotPageInk` (existing) | adaptive | Primary text |
| `jotPageInkSecondary` (existing) | adaptive | Subtitles, relative timestamps |
| `jotPageInkCaption` (existing) | adaptive | Fine-print, section labels |
| `.orange` (system) | — | Pending-sync badge. Add `static let jotPendingAmber = Color.orange` to `JotDesign.swift` so the token is named even if it resolves to system orange |
| `.green` (system) | — | "Synced ✓" success ribbon |

**No `jotBlueTop` / `jotBlueBottom` in this spec.** The earlier v1 of this doc invented those — they don't exist in the codebase and would be brand drift. Blue is the keyboard accent color (`jotKeyboardAccent`), reserved for that surface.

---

## Typography — Dynamic Type tokens (NOT raw pt sizes)

watchOS Dynamic Type scales SF system sizes for users with accessibility text settings. Use Apple's tokens, not raw sizes.

| Token | watchOS font | Use |
|---|---|---|
| `watchTitle` | `.font(.headline)` | "Jot" heading at top of RootView |
| `watchBody` | `.font(.body)` | Transcript body in DetailView |
| `watchRowTitle` | `.font(.subheadline).weight(.medium)` | List row first line (transcript preview) |
| `watchRowSub` | `.font(.footnote)` | List row second line (relative date · source) |
| `watchTimer` | `.font(.title2).monospacedDigit().weight(.semibold)` | Recording elapsed time — `.monospacedDigit()` so numbers don't shift width |
| `watchCaption` | `.font(.caption2)` | "Pending sync" badge, section labels |

All sizes auto-scale with Dynamic Type from "Default" up to "AX5" (largest accessibility size). Layouts MUST be tested at the largest setting and reflow gracefully (likely by truncating preview text and dropping the source glyph).

---

## Motion primitives (watch-scoped subset)

| Primitive | Recipe | Use | Reduce Motion fallback |
|---|---|---|---|
| **PulsingDot** | `scale 0.85↔1.0`, `opacity 0.55↔1.0`, 0.9s ease-in-out, `.repeatForever()` | Red recording dot — primary live cue | Freeze at max opacity + scale. Render "REC" text inline beside the dot in `jotRecord` so the cue isn't ambiguously static |
| **BreathingText** | `opacity 0.55↔1.0`, 1.5s ease-in-out, `.repeatForever()` | "Transcribing…" / "Syncing…" status text | Static text at full opacity, no fade |

**Always-On Display behavior:** AOD on watchOS is signalled by `@Environment(\.isLuminanceReduced)` (NOT `scenePhase == .background` — that fires too late, only after the app fully suspends). When `isLuminanceReduced == true`, the recording dot **must** render at max opacity, max scale, **non-animated** — and the elapsed timer continues updating (visible in AOD via AOD-safe colors). The "is the watch recording?" question is answerable at a glance even when the screen is dim. Reduce Motion (`accessibilityReduceMotion == true`) gets the same static-dot treatment PLUS a "REC" text label inline (see RecordingView mockup below for placement).

---

## Screens

### 1. `RootView` — the default screen when the app opens

**Single decision: tap the mic.** No inline recent list — pushes to `RecentTranscriptsView` via a row. On 40mm the mic button + queue badge + nav row + (optional) sync success ribbon are the entire screen.

```
┌─────────────────────────┐
│                         │
│       ┌──────────┐      │
│       │  mic.fill │     │ ← jotAccent capsule, ~64pt diameter
│       │  Dictate  │     │   SF Symbol mic.fill + "Dictate" label
│       └──────────┘      │   Accessible label: "Start dictation"
│                         │
│  ─── Divider ───        │
│                         │
│  Recent          →      │ ← NavigationLink to RecentTranscriptsView
│                         │
│  • 1 pending sync       │ ← watchCaption, .orange,
│                         │   shown only when queue depth > 0
│                         │
│  ✓ Just synced          │ ← .green, 2s auto-dismiss on ack
└─────────────────────────┘   (the celebration ribbon)
```

**Why no inline list:** "Frictionless capture" means RootView has one job — make the mic obvious. The reviewer's C4 was right: a 88pt capsule + two list rows + headers doesn't fit a 40mm screen at default text size, let alone AX5. The mic button shrinks to ~64pt (still well above the 44pt minimum) so it dominates without crushing the rest.

**Mic button states:**

| State | Visual | Accessibility |
|---|---|---|
| Idle | `jotAccent` capsule, mic glyph + "Dictate" | "Start dictation. Double-tap to begin recording." |
| Tapped | Brief scale 0.95 + `WKHapticType.start` → opens RecordingView sheet | — |

**Background:** default watchOS — black on dark, the watch's tiny screen already provides enough contrast.

**Sync success ribbon:** when the iPhone acks a file transfer, the ribbon appears at the bottom of RootView for 2 seconds: `"✓ Just synced"` in `.green`. Multiple acks within the window coalesce to one ribbon ("✓ 3 synced"). Reviewer's M3.

---

### 2. `RecordingView` — modal sheet over RootView

Centered. No Cancel — once the recording starts, the only exit is Stop. Discard is a phone-side operation (or done by force-quitting the app). Reviewer's C5: silent data loss from accidental Cancel taps is worse than the rare "I changed my mind" case.

```
┌─────────────────────────┐
│                         │
│  ● 02:34                │ ← Dot + timer on same line. Pulsing.
│                         │   Reduce Motion / AOD: dot static at
│                         │   max opacity + scale, plus "REC"
│                         │   appended after timer in jotRecord:
│                         │   "● 02:34 REC"
│                         │
│  ▁▂▄▃▅▆▄▃▂▁           │ ← Waveform amplitude, 10 bars,
│                         │   jotAccent. Hidden under
│                         │   isLuminanceReduced OR Reduce Motion.
│                         │
│  ┌───────────────┐      │
│  │  ■ Stop       │      │ ← jotRecord button, full-width,
│  └───────────────┘      │   accessible label "Stop recording"
└─────────────────────────┘
```

**Extended runtime requirement (CRITICAL):** A watchOS app suspends within ~3 minutes of the wrist lowering. For 15-minute recordings to work, `RecordingView` MUST start a `WKExtendedRuntimeSession` with `sessionType = .audioRecording` immediately when the sheet opens, and end the session in the Stop / cap / interruption / dismiss path. Without this, recording silently dies when the wrist lowers. Reference: `WKExtendedRuntimeSession` in WatchKit; `audioRecording` session type is specifically blessed for mic-capture-during-wrist-down scenarios.

**Recording lifecycle:**

| Phase | Trigger | Visual | Haptic | Action |
|---|---|---|---|---|
| Open | Mic tap | Sheet slides up | `WKHapticType.start` | AVAudioRecorder begins; timer starts |
| Recording | (continuous) | Pulsing dot + ticking timer + waveform | (none) | averagePower polled at 10 Hz; waveform updates |
| Approaching cap | 14:30 elapsed | Red border on Stop + "Reaching 15 min limit — tap Stop to save or keep recording" banner | `WKHapticType.directionDown` | Recording continues |
| At cap | 15:00 elapsed | "Max length reached — saving" overlay | `WKHapticType.notification` | Auto-stop, save, ack, dismiss |
| Stop | Stop tap | Brief "Saving…" via BreathingText | `WKHapticType.success` | File written to `Pending/<uuid>.m4a`, enqueued, sheet dismisses |
| System interruption | phone call / low battery | (system) | (system) | Recorder saves what it has, enqueues, sheet dismisses |

**Cap raised to 15 min** (reviewer's C6). Matches what Parakeet handles comfortably. At 14:30 we *warn the user with a haptic + visible banner* — they can keep recording or tap Stop. No silent truncation.

**Crown:** disabled while recording (so accidental rotation doesn't trigger anything).

**Accessibility:**
- Dot has `accessibilityLabel("Recording")` `accessibilityAddTraits(.updatesFrequently)`
- Timer has `accessibilityValue("\(seconds) seconds elapsed")`
- Stop button has `accessibilityLabel("Stop recording")` `accessibilityHint("Saves the recording and queues it for sync")`
- Waveform has `accessibilityHidden(true)` (decorative only)

---

### 3. `RecentTranscriptsView` — pushed from RootView

Standard list, system nav bar so the back-chevron + left-edge swipe work natively.

```
┌─────────────────────────┐
│  ← Recent               │ ← Native nav bar, left-edge swipe works
├─────────────────────────┤
│ Trail thought...        │ ← watchRowTitle (.subheadline.medium)
│ Yesterday · ⌚            │ ← watchRowSub (.footnote), source glyph
│                         │
│ Standup notes...        │
│ 2 days ago              │ ← no glyph for "app" or nil source
│                         │
│ Grocery list...         │
│ 4 days ago · ⌚          │
│                         │
│ ... (up to 10 rows)     │
│                         │
│ Last synced: 2 min ago  │ ← Footer caption if sync is fresh
└─────────────────────────┘
```

**Behavior:**
- Tap a row → push `TranscriptDetailView`
- DigitalCrown scrolls list
- Pull-to-refresh: no-op (data is push-driven from phone)
- Empty state: "No transcripts yet. Tap Dictate from the main screen to record one."
- Stale-sync hint: if `lastSyncedAt > 24h ago`, footer becomes "Last synced: 2 days ago" in `.orange`

**Source glyph (only shown for `"watch"` source):**

| Source | Glyph | SF Symbol name |
|---|---|---|
| `"watch"` | ⌚ | `applewatch` |
| `"app"` or `nil` | (none) | (suppressed — implicit default) |
| `"keyboard"` | (none for v1) | reserved for v1.1 |
| `"shortcut"` | (none for v1) | reserved for v1.1 |
| `"file"` | (none for v1) | reserved for v1.1 |

Only differentiate `"watch"` for v1 (reviewer's N1). Phone/keyboard/etc. distinctions don't matter on watch.

**Currently-transcribing row** (reviewer's M3 partial):
```
╭───────────────────╮
│ Transcribing…     │ ← BreathingText, jotPageInkSecondary
│ from watch · now  │
╰───────────────────╯
```
Shown at the top of the list while the phone is processing a watch-originated recording. Replaces in place when the real transcript arrives.

---

### 4. `TranscriptDetailView` — pushed from RecentTranscriptsView

```
┌─────────────────────────┐
│  ← Recent               │
├─────────────────────────┤
│ Yesterday at 4:23 PM    │ ← watchCaption, jotPageInkSecondary
│ ⌚ Recorded on watch     │ ← Source line (only shown for "watch")
│                         │
│ This is the full        │ ← watchBody (.body), scrolls with crown
│ transcript text         │
│ rendered as a clean     │
│ reading surface...      │
│                         │
└─────────────────────────┘
```

**No Rewrite section** (reviewer's I6). The principle is "no rewrite display on watch v1" — and the sync payload doesn't include rewrites. If we add rewrite display to v1.1, we'll re-spec then.

**Behavior:**
- DigitalCrown scrolls text
- No actions (no edit, no delete, no share)
- Left-edge swipe-back works natively

---

### 5. Complications + Smart Stack tile

One Widget target providing two configurations.

#### Complication (corner / circular / inline)

```
┌──────────┐
│  mic.fill│   SF Symbol, jotAccent
│   Jot    │   Small label
└──────────┘
```

- Tap → deep-link `jot-watch://record` → app launches into `RecordingView`
- Inline variant: "🎤 Jot" → use SF Symbol + text combination, not emoji

#### Smart Stack tile (large)

```
┌─────────────────────────┐
│  mic.fill  Capture      │ ← jotAccent accent, larger touch target
│            a thought    │
│                         │
│  Tap to start recording │
└─────────────────────────┘
```

**Relevance (v1 — locked):**
- Provide `RelevanceConfiguration` via `WidgetConfiguration` + `relevance()`
- v1: **always-on relevance 0.5** (still appears in stack, not pinned, not escalated)
- v1.1 will add history-based escalation (clustering on `Transcript.createdAt`). Out of scope for v1.
- Do NOT hardcode "7-10 AM" anywhere

---

### 6. Siri AppIntent — "Capture in Jot" (reviewer's M1)

```swift
struct CaptureInJotIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture in Jot"
    static let openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        // Open the app and route into RecordingView immediately
        return .result()
    }
}
```

- User says: "Hey Siri, capture in Jot"
- App opens, RecordingView appears, recording starts within ~1s
- Workout-mode users (reviewer's M4) can capture without leaving the workout face via this path
- Also discoverable as a Shortcut for custom phrases ("note this", "remember this", etc.)

This is NOT a full voice-driven transcription flow (we don't compete with Siri's mic capture). It's a launcher — opens us into recording mode. Simple and reliable.

---

## Cross-cutting concerns

### Sync queue cap behavior (reviewer's I7)

Single cap: **50 recordings**. The 500 MB cap from the plan doc is removed (it's redundant — 50 × 32 kbps × 5 min ≈ 60 MB max, well under 500 MB).

| Queue depth | Behavior |
|---|---|
| 0 | Badge hidden |
| 1-44 | "N pending sync" in `.orange` |
| 45-49 | "N pending sync — open iPhone Jot to sync" warning (still `.orange`) |
| 50 (cap reached) | **Mic button BLOCKS new recording** with a full-screen alert: "Watch storage full — open Jot on iPhone to sync the 50 pending recordings before you can record more." Fail-CLOSED with explicit feedback. This contradicts my earlier "drop-oldest fail-open" idea — fail-closed is consistent with the Cancel-removal posture (no silent data loss). User dismisses the alert, opens phone Jot when next available, syncs drains the queue, mic button works again. |

### Watch ↔ phone clock drift (reviewer's I8)

Audio file metadata carries **two** timestamps:
- `capturedAt`: watch-local `Date` at recording start
- `receivedAt`: phone's `Date()` when WCSession delivers the file

`Transcript.createdAt` is set to `receivedAt`, not `capturedAt`. The library sorts by `createdAt` for monotonic order. The detail view shows "Recorded at <capturedAt>" so the user sees what their watch thought the time was, but the sort order is correct.

If the watch reports a `capturedAt` more than 1 hour in the future from the phone's clock (clock skew), the phone overrides to `receivedAt - duration` (estimate). Log this in `DiagnosticsLog`.

### App uninstall edge cases (reviewer's I9)

- **iPhone app uninstalled, watch app remains:** watch keeps last-known top-10 visible (read-only). Recordings still work, queue locally indefinitely (the 50-cap warning is suppressed since there's nowhere to sync). Footer: "iPhone Jot needs to be reinstalled to view transcripts." On phone-app re-install: sync resumes automatically on next WCSession activation.
- **Watch app uninstalled, iPhone remains:** iPhone's `WCSessionDelegate` observes `session.isWatchAppInstalled` and stops queueing top-10 pushes. Phone's UI shows no change (no special "watch is missing" indicator — watch is optional).
- **iCloud restore on watch:** app reinstalls with empty container. On first launch the watch sends a `transferUserInfo` "hello, fresh install" message; phone responds with full top-10 the next time it processes its WCSession queue (works whether iPhone is reachable or not — `transferUserInfo` is FIFO + queued).

### Sync correctness (reviewer's C7)

- **Audio: `WCSession.transferFile(url:metadata:)`** — file transfers persist across app suspension. Metadata: `{"uuid": UUID-string, "capturedAt": ISO8601 string, "watchClockOffset": double-seconds-from-phone}`.
- **Top-10 transcripts: `WCSession.transferUserInfo(_:)`** (NOT `updateApplicationContext`). `transferUserInfo` is FIFO and guaranteed-delivery. Payload shape:
  ```
  {
    "type": "topTranscripts",
    "version": 1,
    "transcripts": [
      {"id": "...", "preview": "First 200 chars...", "createdAt": "ISO8601", "source": "watch"|"app"|...},
      ...up to 10 entries newest-first
    ]
  }
  ```
- **Ack flow:** watch sends file → phone receives → phone saves Transcript → phone sends `transferUserInfo({"type": "ack", "uuid": "..."})` → watch deletes the local file on ack.
- **Watch-side ack idempotency:** if an ack arrives for a UUID the watch already deleted (because of duplicate ack replay), the watch silently ignores it. Use a Set<UUID> of "seen acks" with TTL of 1 hour.
- **Phone-side dedup:** keeps `Set<UUID>` of recently-received IDs (last 100, TTL 24h) to silently discard duplicates if watch retransmits before its ack arrives. Lookup by `Transcript.watchOriginUUID` first (cheap SwiftData query).
- **`watchOriginUUID` schema field:** added to schema V5 alongside `source`. V5 = V4 + `source: String?` + `watchOriginUUID: String?`. **The plan doc must be updated to reflect both.**

### Currently-transcribing row in RecentTranscriptsView

Pending-but-not-yet-transcribed state lives in App Group UserDefaults (`AppGroup.pendingWatchTranscriptions`) as `[UUID: ISO8601 String]`. Phone-side flow:
1. Watch sends file with UUID. Phone receives.
2. Phone writes `pendingWatchTranscriptions[uuid] = capturedAt`.
3. Phone sends `transferUserInfo({"type": "transcribing", "uuid": "...", "capturedAt": "..."})` to watch.
4. Watch renders the placeholder row at the top of its list.
5. Phone finishes transcribing, saves Transcript with `watchOriginUUID == uuid`.
6. Phone removes from `pendingWatchTranscriptions`.
7. Phone sends fresh `transferUserInfo({"type": "topTranscripts", ...})` with the real transcript now in top-10.
8. Watch replaces the placeholder row with the real entry.

### Ack haptic coalescing

When multiple acks arrive in a burst (e.g., user opens phone after a day of watch-only capturing → 10 pending files all transfer + transcribe + ack rapidly):
- Watch fires `.click` haptic for the FIRST ack within a 5-second window.
- Subsequent acks in that window are silently coalesced.
- Reset the window when 5 seconds pass with no acks.
- The "Just synced" ribbon coalesces the same way (5-second window) and shows "✓ N synced" where N is the count within the window.

### Permission flow

First-launch mic permission on watch:
1. RootView renders with mic button visible but greyed (90% opacity).
2. Tap mic → trigger `AVAudioSession.requestRecordPermission` → system alert.
3. User Allows → proceed to RecordingView normally.
4. User Denies → mic button stays greyed, tap shows alert: "Microphone access denied. Open the Watch app on iPhone → Jot → Privacy to enable, then return here." No recovery from inside the watch app.

### Bluetooth / audio routing

`AVAudioRecorder` on watchOS uses whichever input the system routes. AirPods paired to watch take precedence over watch built-in mic; iPhone-paired AirPods are NOT used (different routing domain). Document this in the recording's metadata for diagnostics: include `inputRoute: String` from `AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName` in the file metadata. No UI surface for this — diagnostic only.

### Sheet dismissal during recording

`RecordingView` is presented with `.interactiveDismissDisabled(true)` while recording. Swipe-down to dismiss is blocked. Only Stop ends recording.

### iCloud restore "hello, fresh install"

On watch app's first launch after install (no `lastSyncedAt` in UserDefaults), send:
```
{"type": "helloFresh", "watchInstallTime": "ISO8601"}
```
Phone responds within ~1s if reachable (full top-10 via `transferUserInfo`). If not reachable, phone responds on next WCSession activation. Watch's empty-state list copy: "Connecting to iPhone Jot…" until first top-10 arrives.

### Localization

All user-facing strings in the watch app + widgets use `LocalizedStringResource` (or `LocalizedStringKey`), not Swift string literals. The Localizable.strings table is shared between iOS and watchOS targets (lives in `Jot/Shared/Resources/`). Watch-specific keys prefixed with `watch.` (e.g., `watch.dictate`, `watch.recording.timer`).

### Always-On Display (reviewer's I1)

In `RecordingView`:
- Switch to "AOD-safe" rendering when `scenePhase == .background`:
  - Pulsing dot: STATIC at max opacity (no animation)
  - Waveform: hidden
  - Timer: continues updating, drawn with AOD-safe color contrast (Apple's `.foregroundColor(.white)` defaults to AOD-dimmed; that's fine)
  - "REC" text inline beside the dot for redundancy
- This is also the Reduce Motion fallback by definition.

### Mic privacy indicator (reviewer's M5)

watchOS 26 shows a system-level **orange dot** in the top-leading corner when the mic is active. The Jot recording UI's red dot lives below that area (centered top, ~30pt from top safe area). Two distinct colors (system orange vs Jot red) reinforce rather than collide. **Documented intent** rather than redesign — both dots together mean "mic is active AND Jot is recording" which is the correct semantic.

### Haptics (reviewer's I10)

Exact `WKHapticType` values only:

| Event | Haptic |
|---|---|
| RecordingView opens | `.start` |
| Recording stops successfully | `.success` |
| Approaching 15-min cap | `.directionDown` |
| Cap auto-saved | `.notification` |
| File transfer ack received | `.click` (subtle — don't interrupt user) |
| Sync failure | `.failure` |

No invented names. `.rigid` is a UIKit value, not watchOS.

---

## Open questions (none)

All earlier opens are closed. Adversarial-review-found gaps are addressed inline above.

---

## What's deferred to v1.1 (intentionally not in v1)

- Audio playback to verify before send (reviewer's M2) — adds complexity; the 15-min cap warning + watchOS's mic permission orange dot are sufficient for v1.
- Rewrite display on watch (reviewer's I6) — schema sync doesn't include rewrites; would need top-10 payload extension.
- Editing on watch — never planned for v1; permanently deferred.
- Per-row "synced ✓" individual indicators in `RecentTranscriptsView` — the celebration ribbon on RootView is enough for v1.
- Smart Stack relevance based on user history clustering — v1 ships with always-on relevance score 0.5; user-history-based escalation is v1.1.

---

## Implementation notes for the agent building this

- **Do NOT use `.glassEffect()`** — it doesn't exist on watchOS. Use SwiftUI's standard `.background(.regularMaterial)` for any surface that needs depth, or just use the system background.
- **Do use Dynamic Type tokens** (`.font(.body)` etc.), never raw `.system(size: N)`.
- **All SF Symbols, no emoji.** `mic.fill` for the mic button glyph, `applewatch` for the source indicator, `xmark` if any close affordance is needed.
- **Single source for tokens:** import `Jot/App/Design/JotDesign.swift` into the watch target (extend the `Shared/` glob). Don't duplicate color definitions in `Watch/`.
- **Test matrix that must pass before shipping:**
  - Default text size on 40mm screen
  - AX5 (largest accessibility text size) on 40mm screen
  - Reduce Motion ON (settings)
  - Always-On Display engaged mid-recording
  - VoiceOver on, navigate all surfaces with crown
- **For the agent implementing this:** if anything in this spec contradicts what you discover when actually compiling against watchOS 26 SDK, the SDK wins — log the contradiction in the doc and update before shipping.
