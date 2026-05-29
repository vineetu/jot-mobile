# Plan: Apple Watch dictation with deferred sync

> **Status:** Planned 2026-05-26. Targets watchOS 10+ (Series 8/9 baseline). Adds two new targets to `Jot.xcodeproj`: a standalone watchOS app and a WidgetKit extension for complications + Smart Stack tile.

---

## Intent

Let the user dictate directly from their Apple Watch, **without the iPhone needing to be present.** Audio is captured on the watch, compressed (AAC 16kHz mono), and queued to disk. Whenever the watch reaches the iPhone via WatchConnectivity, queued audio files transfer in the background, get transcribed on the iPhone using the existing Parakeet pipeline, and land in the same library as any other transcript.

**Why now:** Capture-anywhere is the central Jot value prop. The phone is already the universal capture surface; the watch closes the "in the shower / hiking / mid-conversation when reaching for the phone is socially awkward" gaps. The deferred-sync model means the user doesn't have to think about whether the phone is in range — record now, transcript shows up later.

## Scope

**In:**
- Standalone watchOS app: mic button → record → AAC 16kHz mono → queued on watch → background-transferred to iPhone via `WCSession.transferFile`.
- iPhone receives audio, decodes to 16kHz mono PCM, runs existing Parakeet pipeline, saves a `Transcript` with `source = "watch"`.
- iPhone → Watch sync of the most recent 10 transcripts (read-only on watch). Updates whenever the library changes (new transcript, edit, delete).
- WidgetKit extension provides complications (corner / circular) and a Smart Stack tile that launches the app directly into recording with one tap.
- Source tagging on every `Transcript`: `source: String?` — values for v1: `"watch"`, `"app"` (default for existing + main-app records), `"keyboard"`, `"shortcut"`, `"file"`. Schema V5 lightweight migration.

**Out (v1):**
- Editing transcripts on the watch (read-only — tapping a row shows full text, no edit affordance).
- "Open on iPhone" Handoff between watch app and iPhone Jot (nice-to-have, easy to add later).
- Watch-side AI Rewrite / Transform.
- Watch settings UI — all settings stay on phone.

## Target structure

Add to `Jot/project.yml`:

| Target | Bundle ID suffix | Purpose |
|---|---|---|
| `JotWatch` | `.watch` | Standalone watchOS app (record, queue, sync, list) |
| `JotWatchWidgets` | `.watch.widgets` | WidgetKit ext: complications + Smart Stack tile |

Existing targets (`Jot`, `JotKeyboard`) unchanged.

**Source code:**
- `Jot/Watch/` — watchOS app SwiftUI views, recording logic, sync queue, audio recorder
- `Jot/WatchWidgets/` — Widget views
- `Jot/Shared/` — already exists; extend `xcodegen` config so these files compile into the watch target too:
  - `Transcript.swift`, `JotSchemaV5.swift` (need the schema for the transcript-list view on watch)
  - `AppGroup.swift` — re-used for queue state visible to both targets
  - `DiagnosticsLog.swift` — sync events logged here for the existing Diagnostics UI

## Schema impact

**Required.** Adding TWO fields to `Transcript`:
- `source: String?` — capture source tag (`"watch"`, `"app"`, `"keyboard"`, `"shortcut"`, `"file"`)
- `watchOriginUUID: String?` — for de-dup of incoming watch transfers (phone keeps a quick lookup to ignore duplicates if the watch retransmits before its ack arrives)

Per `Jot/CLAUDE.md` schema discipline: V4 file STAYS FROZEN; this is purely additive.

- New file: `Jot/Shared/Schema/JotSchemaV5.swift` (copy of V4 + the two fields, bump `versionIdentifier` to `Schema.Version(5, 0, 0)`).
- `JotMigrationPlan.swift`: append `MigrationStage.lightweight(fromVersion: JotSchemaV4.self, toVersion: JotSchemaV5.self)`.
- `Transcript.swift`: typealias bumped to `JotSchemaV5.Transcript`.
- `TranscriptStore.append(...)`: tag new entries with the correct source. Watch-originated entries also set `watchOriginUUID`.
- Existing records have both `source = nil` and `watchOriginUUID = nil` post-migration; UI treats nil source as "app".

## Audio format

- **Codec:** AAC
- **Sample rate:** 16 kHz mono (matches Parakeet's expected input — no resampling required on iPhone side)
- **Target bitrate:** 32 kbps (~4 KB/sec of audio, so a 10-second recording is ~40 KB, a 60-second recording is ~240 KB)
- **Container:** `.m4a` (writeable by `AVAudioRecorder` on watchOS)

Watch recorder uses `AVAudioRecorder` with `AVFormatIDKey = kAudioFormatMPEG4AAC`, `AVSampleRateKey = 16000`, `AVNumberOfChannelsKey = 1`, `AVEncoderBitRateKey = 32000`.

## Sync flow

### Watch → iPhone (audio capture)

1. User taps mic in watch app (or launches via Smart Stack widget).
2. `AVAudioRecorder` writes to a `.m4a` file in the watch app's `Documents/Pending/` dir.
3. On stop, file is enqueued for transfer.
4. `WCSession.transferFile(url:metadata:)` — runs in the background even if the watch app suspends. Metadata carries a UUID + watch-local timestamp + source tag.
5. iPhone's `WCSessionDelegate` receives the file in `session(_:didReceive:)`, copies it to a staging directory, kicks off `TranscriptionService.transcribe(audioFileURL:)`.
6. Resulting `Transcript` is saved with `source = "watch"` and the watch-supplied timestamp.
7. iPhone sends an ack back to watch (small `transferUserInfo` payload), watch marks the file as synced and deletes it from `Pending/`.

### iPhone → Watch (transcript top-10)

1. Whenever the iPhone's transcript library changes (new entry, edit, delete) — fires on `ModelContext` save.
2. iPhone serializes the 10 most recent transcripts (just text + timestamp + source tag, ~5-10 KB total).
3. `WCSession.updateApplicationContext(_:)` — replaces the watch's mirror with the latest state. Auto-coalesces if multiple updates arrive in quick succession.
4. Watch receives, persists to a JSON file in its container, reloads list UI.

### Failure modes

- **iPhone unreachable mid-recording:** watch records normally, file sits in `Pending/`, transfers when iPhone is reachable. UI shows count of pending recordings.
- **Watch storage low:** cap the queue at 50 recordings or 500 MB total. Warn with status when within 80%.
- **Transfer interrupted:** `WCSession.transferFile` retries automatically. We just observe the completion delegate.
- **Watch app launched fresh on a paired iPhone with no prior state:** request initial top-10 from phone via `WCSession.sendMessage` round-trip; phone replies with current state.

## Watch app shape

Three SwiftUI views inside `Jot/Watch/`:

1. **`RootView`** — mic button (large, centered, tappable). Below: small badge showing queue depth ("3 pending") if non-zero, plus a "Recent" disclosure that pushes to:
2. **`RecentTranscriptsView`** — `List` of the top-10 with `source` indicator chip (watch glyph for `"watch"`, no glyph otherwise) + relative date + first ~40 chars. Tap pushes to:
3. **`TranscriptDetailView`** — full text, scrollable. No edit. No actions for v1.

`RecordingView` is a presented sheet over `RootView` that shows elapsed time + waveform amplitude + Stop button.

## Widgets + Smart Stack

`Jot/WatchWidgets/`:
- One `Widget` target providing two configurations:
  - Corner / circular complication (lock-screen / watch-face slot) — shows the mic icon; tap launches the app directly into the recording sheet.
  - Smart Stack tile — same affordance with slightly larger touch target; appears in the relevance-based stack on Series 9+.
- Deep-link via `WKApplicationDelegate.handleUserActivity` or a custom URL scheme `jot-watch://record` that `RootView` consumes via `.onContinueUserActivity(_:)`.

## Files to touch

**New:**
- `Jot/project.yml` — add JotWatch + JotWatchWidgets targets
- `Jot/Watch/JotWatchApp.swift` — `@main` watchOS app entry
- `Jot/Watch/Views/RootView.swift`
- `Jot/Watch/Views/RecordingView.swift`
- `Jot/Watch/Views/RecentTranscriptsView.swift`
- `Jot/Watch/Views/TranscriptDetailView.swift`
- `Jot/Watch/Audio/WatchRecorder.swift` — AVAudioRecorder wrapper
- `Jot/Watch/Sync/WatchSyncQueue.swift` — Pending/ file management
- `Jot/Watch/Sync/WatchConnectivityClient.swift` — WCSession on watch side
- `Jot/WatchWidgets/JotWatchWidgets.swift`
- `Jot/Shared/Schema/JotSchemaV5.swift` — adds `source: String?`
- `Jot/Shared/Schema/JotMigrationPlan.swift` — append V4→V5 stage
- `Jot/Shared/WatchTranscriptMirror.swift` — top-10 JSON payload format (shared)
- `Jot/App/WatchConnectivity/PhoneSideWCSession.swift` — phone-side WCSession delegate, receives audio files, kicks off transcription, sends back top-10 + acks

**Modified:**
- `Jot/Shared/Transcript.swift` — typealias bumped to V5
- `Jot/Shared/TranscriptStore.swift` — `source` param on `append`
- `Jot/App/JotApp.swift` — initialize phone-side WCSession on launch
- `Jot/App/Transcription/TranscriptionService.swift` — `transcribe(audioFileURL:)` already supports the watch's `.m4a` format (AVAudioFile can decode AAC); just need to plumb the source tag through to the resulting Transcript

## Sequence to build

1. **Schema V5** (`source: String?` + migration plan). Verify on real device that upgrade install of build 30 → build with V5 doesn't fire `[SCHEMA-FALLBACK]`.
2. **Add watch targets to `project.yml`**, regenerate, get an empty watch app booting on simulator.
3. **`WatchRecorder` + RecordingView** — record + save to local file on watch, no sync yet. Verify file is written + playable on the watch's Files via Xcode.
4. **WatchConnectivity plumbing on both sides** — file transfer watch → phone. Verify on-device with real Apple Watch (pair to iPhone with Jot running).
5. **iPhone receives, transcribes, saves with `source = "watch"`** — end-to-end happy path.
6. **iPhone → Watch top-10 sync** — recent transcripts visible on watch.
7. **Watch list UI + detail view** — read recent transcripts on watch.
8. **Widgets + Smart Stack tile** with deep-link to record.
9. **Edge cases:** queue cap, watch storage low warning, watch app fresh launch with no prior state, transfer-while-watch-suspended (transferFile already handles this).
10. **features.md update** — new §15 "Watch Dictation", cross-links to §2 (Recording Experience), §1.2 (Library).

## features.md impact

New section §15 "Watch Dictation" describing:
- Standalone capture from watch with mic button
- Background sync when iPhone reachable
- Read-only transcript view on watch (top-10)
- Complications + Smart Stack for one-tap recording

Cross-links to add (bidirectional):
- §1.2 (Library) — "transcripts also appear in the library regardless of which device they were captured on; a small watch-face glyph appears alongside the timestamp on rows that originated on watch"
- §2 (Recording Experience) — "an alternative capture surface is the watch (§15); the same Parakeet pipeline transcribes both"

## Test plan

1. Fresh install on iPhone + paired Apple Watch (Series 9+, watchOS 10+).
2. Record on watch with iPhone within range → transcript appears on iPhone library within ~30 sec.
3. Record on watch with iPhone OUT of range → "1 pending" badge on watch.
4. Walk into iPhone's BT range → pending recording transfers + transcribes automatically.
5. Edit a transcript on iPhone → watch's recent list updates within seconds.
6. Delete a transcript on iPhone → watch's recent list updates.
7. Tap complication / Smart Stack tile → watch app launches directly into recording.
8. Tap a row on watch's recent list → full text displayed in detail view, no edit affordance.
9. Schema upgrade: install build 30 (V4) → install new build (V5) → confirm transcripts still load, no `[SCHEMA-FALLBACK]` log.
10. Source tag spot-check: dictation from app shows no glyph; dictation from watch shows watch glyph.

## Estimate

~2 days of focused work end-to-end, including the schema migration, both sync directions, the read-only watch list, and the widget extension. The watchOS-specific debugging (paired-device simulator quirks, WCSession's "session activated" timing, complication previews) eats more time than the actual code. Real-device testing required throughout — simulator watch ↔ simulator iPhone WCSession is notoriously flaky.

## Open question

**`source` enum vs string?** Plan above uses `String?` for simplicity (lightweight migration, future values don't require schema changes). A typed enum would be safer but requires a custom migration when new values are added. Going with `String?` for v1 with documented values in `Transcript.swift`'s doc comment.
