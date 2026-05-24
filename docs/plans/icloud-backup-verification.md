# Plan: iCloud Backup Verification + Transparency

> **Status:** Requested 2026-05-24. Scope: passive iOS Device Backup (not active CloudKit sync). Audio is never persisted; this concerns text + metadata only.
> **Size: S** (~3-4 hours, mostly verification + small UI surface).

---

## Requirements

- A user who enables iCloud Backup in iOS Settings → [their Apple ID] → iCloud → iCloud Backup gets their Jot library (transcripts, rewrites, saved prompts, vocabulary, settings) included in the device backup automatically.
- Restoring the backup on a new device → reinstalling Jot from App Store → opening Jot → the library is restored to where it was at backup time.
- The user can see (in Settings → About) a small confirmation row: "Included in iOS Backup ✓" — so they know without trusting the docs.
- Audio is never written to disk, so backup never contains audio. (Verify.)

### Non-Goals

- Not active CloudKit sync. No cross-device live sync.
- Not iCloud Drive document storage.
- Not selective backup (user can't choose which transcripts to back up; it's all or none, gated by iOS-level iCloud Backup toggle).
- Not encryption beyond what iOS Backup already provides (encrypted in transit + at rest in iCloud, decryptable by the user's Apple ID).

---

## Current state — what I had to actually look up

**SwiftData store location.** `Jot/Shared/TranscriptStore.swift:62-84` shows the store config:

```swift
let config = ModelConfiguration(
    "JotTranscripts",
    schema: schema,
    groupContainer: .identifier(AppGroup.identifier),  // <-- key bit
    cloudKitDatabase: .none
)
```

So the store lives in the **App Group container**, NOT the main app sandbox. The actual path is `Library/Group Containers/group.com.vineetu.jot.mobile/Library/Application Support/JotTranscripts.sqlite` (and a `.shm` + `.wal` companion).

### iCloud Backup semantics for App Group containers

**Caveat upfront** (per adversarial review): Apple's canonical iOS Data Storage Guidelines explicitly cover the **main app sandbox** paths (Documents/, Library/Application Support/, Library/Caches/, tmp/). App Group containers (`Library/Group Containers/<group-id>/`) are NOT listed in that canonical doc. **Empirically** (verified across iOS 17+ by various developers), App Group containers ARE included in iCloud Backup by default. We rely on that observed behavior, not on cited Apple policy.

- **Included by default**:
  - App sandbox `Documents/`, `Library/Application Support/`, `Library/<anything except Caches>/`.
  - App Group `Library/Group Containers/<group-id>/` (empirical; not cited Apple doc).
- **Excluded by default**:
  - `Library/Caches/` — unconditional.
  - `tmp/` — unconditional.
  - Anything with `URLResourceKey.isExcludedFromBackupKey == true` (explicit opt-out).
- SwiftData stores are SQLite files on disk; if the file isn't explicitly excluded, it's backed up.
- The `.shm` and `.wal` SQLite companions are also backed up.

**WAL + backup snapshot race:** iOS Backup uses filesystem snapshots. If a `-wal` is mid-checkpoint when the snapshot fires, the backed-up `.sqlite` + `-wal` pair represents a partial transaction. SQLite's recovery handles this at open time — on first launch after restore, the last in-flight transaction may roll back. Acceptable; document if needed in user-facing copy.

**Conclusion:** the SwiftData store should already be backed up. This plan's job is to **verify** empirically, **document** with the caveat above, and **surface** it.

### Other stores that need verification

- **Saved Prompts:** `SavedPromptStore` writes to App Group `UserDefaults`. Per Apple, App Group `UserDefaults` plists ARE included in iCloud Backup. Verify on-device.
- **Vocabulary terms:** `VocabularyStore` — same App Group UserDefaults pattern. Verify.
- **App preferences (warm-hold duration, last-seen flags, etc.):** App Group UserDefaults. Same.
- **`TranscriptHistoryMirror`:** JSON mirror of transcripts in App Group container, kept fresh for the keyboard extension. Re-derived from SwiftData on next launch if missing — safe to be excluded or included, doesn't affect data integrity.
- **Diagnostics log:** AppGroup-backed log file. Probably OK to be excluded (purely diagnostic; loss is fine). Verify current state.
- **HuggingFace model cache (Qwen 3.5 4B weights):** large (~2.5 GB). This SHOULD be excluded from backup — re-downloadable, would balloon backup size. Verify it's excluded.

### Audio: confirmed not persisted

Per `features.md §13.4` ("Transcripts are stored locally... There is no iCloud sync...") and `§2.5` ("After stopping, a brief transcribing state is shown..."). The audio buffer is in memory, transcribed, then released. Nothing in `Library/` or `Documents/` should hold raw PCM. **One thing worth verifying:** that the `Caches/` or `tmp/` paths don't end up with stray audio dumps during interruption / crash recovery.

---

## What to ship

### 1. Verification work (the bulk of the value)

A short audit script + an on-device test pass:

- **Audit script** (`scripts/check-backup-attributes.sh`): for each known data-store path inside the App Group container + the main app sandbox, run `xattr` to check for `com.apple.MobileBackup` exclusion attribute. Report any unexpected exclusions. Also assert the Qwen weights path lives under `Library/Caches/` (which is unconditionally excluded by iOS — so no defensive setter needed; we just verify the location). Run locally before ship.
- **Verify Qwen weights path stays in `Caches/`.** Code review confirms `Qwen35Client` uses `URL.cachesDirectory.appendingPathComponent("huggingface").appendingPathComponent("hub")` — under `Library/Caches/`, automatically excluded by iOS. No code change needed; just an assertion in the audit script that this remains true. (Earlier draft proposed an `isExcludedFromBackup` defensive setter — withdrawn per review: the HF SDK owns the on-disk URL, can't reliably mutate from outside, and the path is already excluded.)
- **Manual restore test — corrected per review.** Reinstalling a single app from the App Store does NOT trigger iCloud Backup restore. iOS only restores app data during initial device setup or after Erase All Content and Settings. The full proper test:
  1. Make a baseline (dictate a couple of transcripts; run a rewrite on one; add a custom vocab term; add a custom prompt).
  2. Settings → Apple ID → iCloud → iCloud Backup → Back Up Now. Wait for "Last successful backup" timestamp to update.
  3. Settings → General → Transfer or Reset iPhone → Erase All Content and Settings.
  4. On setup: pick "Restore from iCloud Backup", select the backup from step 2.
  5. Wait for restore + app reinstall + post-restore download of app data.
  6. Open Jot → confirm transcripts, vocab, prompts all present.
- **Practical alternative if Erase + Restore is too expensive:** rely on the audit script + the empirical-behavior caveat. Document that we have NOT verified end-to-end restore on this build, only that the data is in backup-eligible locations. This is honest and acceptable for v1; we can upgrade verification later.

### 2. Settings transparency

A new row at the bottom of the existing Settings → About card:

```
Backed up with iCloud (when enabled in iOS Settings)
```

Static copy, no checkmark. The checkmark would be a false visual affirmation for users who have iCloud Backup turned off (we can't detect that state from inside the app). Neutral phrasing is honest.

Optionally tappable for a one-line explainer: "Your transcripts, prompts, and vocabulary are included in iCloud Backup if it's enabled on your iPhone. Audio is never stored, so it's never in any backup."

Implementation: a single static row added to the existing `SettingsView` About section. No state required — the message is invariant (we're not gating on iCloud Backup actually being enabled, because we can't reliably detect that from inside the app without extra entitlements). The row is honest: "if you have iCloud Backup on, this data is included."

### 3. features.md update

Update `§13.4 Transcript Storage`:

- Current: "Jot does not explicitly exclude transcripts from standard iCloud Device Backups, so they may be included in a device backup if the user has iCloud Backup enabled."
- New: "Transcripts, AI Rewrites, saved prompts, and custom vocabulary are included in iCloud Device Backup when the user has it enabled. Restoring from an iCloud backup on a new device brings the full Jot library back. Audio is never written to disk so it's not part of any backup. The downloaded AI Rewrite model (~2.5 GB) lives in the system cache directory, which iOS does not back up — the model re-downloads on first use after a restore. (We rely on iOS's automatic Caches/ exclusion; we don't set the exclusion flag ourselves.)"

A subtle note about the `TranscriptHistoryMirror` JSON: it's in the App Group container so it's backed up too. On restore, the keyboard's recents strip would briefly render from the mirror (potentially stale relative to SwiftData if writes were in flight at backup time), then SwiftData rebuilds the mirror on the next dictation. This is invisible to the user but worth noting in code comments.

Also add a cross-link to the new Settings → About row.

### 4. Model-weights exclusion — withdrawn

Earlier draft proposed an `isExcludedFromBackup` defensive setter in `Qwen35Client`. Withdrawn per review:
- The HF SDK owns the on-disk URL; we can't reliably set resource values on its vending path.
- The cache path is already under `Library/Caches/` which iOS unconditionally excludes.
- Defensive code doing nothing is just confusion-bait for future readers.

Replaced with: an **assertion in the audit script** that the Qwen cache base remains under `Caches/`. If a future code change moves the cache elsewhere, the assertion fails and we address the regression then.

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. Write `scripts/check-backup-attributes.sh` audit script (xattr scan + Caches path assertion) | `scripts/` | XS (~30 min) |
| 2. Run audit on a real device's app container | manual | XS |
| 3. Add Settings → About row ("Backed up with iCloud (when enabled in iOS Settings)") | `Jot/App/Settings/SettingsView.swift` | S |
| 4. Update `features.md §13.4` per the revised copy above | `Jot/features.md` | XS |
| 5. *(Optional)* Erase-and-restore test if user is willing to do a full-device reset; otherwise rely on audit + empirical-behavior caveat | on-device | ~hours |

**Total: S** (~3-4 hours, dominated by the manual restore test).

---

## Edge Cases

- **User has iCloud Backup disabled.** Our message says "included if enabled" — honest and accurate. No false promise.
- **Backup size:** if the user has thousands of transcripts, the SQLite store grows linearly. Apple's iCloud Backup includes the file size in the user's iCloud quota. We can't help here — but the Settings row can be honest about this if needed (probably not v1).
- **Schema-mismatch on restore.** If user backs up on version N, restores on version N+1 with a different SwiftData schema, SwiftData lightweight migration handles additive changes. Breaking changes would need a `SchemaMigrationPlan`. This is a known SwiftData concern; same handling as Feature 2's schema bump.
- **App Group identifier change.** If we ever changed the App Group ID, the restored data would be unreachable. We don't have plans to change it — and changing it would break the keyboard extension's data access too, so it's a non-starter.
- **Restore on a device without Apple Intelligence (Apple FM).** Cleanup feature path may behave differently, but the data is restored correctly — only future feature usage is affected.
- **iCloud Backup runs while Jot is in the middle of a write.** SQLite has WAL mode; backup can race with active writes. iOS's backup snapshot mechanism handles this — SQLite + WAL is the standard pattern for backed-up app data.

---

## Test Plan

1. **Audit script run:** all expected files included; Qwen weights excluded; no surprises.
2. **Manual restore test (above):** baseline → backup → delete → reinstall → restore → verify everything present.
3. **VoiceOver:** Settings row announced clearly.
4. **Backup size sanity check:** view Jot's contribution to iCloud Backup size in iOS Settings → Apple ID → iCloud → Manage Account Storage → Backups → [device] → Jot. Should be small (~MB), not GB. Confirms Qwen weights aren't sneaking in.

---

## Open Questions

1. **Should the Settings row say "Included in iOS Backup" unconditionally**, or detect whether iCloud Backup is actually enabled? Detecting requires `NSUbiquityIdentityToken` or similar, which only tells us about iCloud Drive — NOT specifically iCloud Backup state. The unconditional phrasing is honest ("if enabled, this is included") and avoids false negatives. **Recommendation:** unconditional.
2. **Tappable for an explainer sheet, or just static text?** Static is simpler. Tap-for-explainer is more discoverable. **Recommendation:** static; if user feedback asks, add the sheet later.
3. **Do we need to communicate the 2.5 GB AI model is NOT backed up?** Yes — important so users don't worry about backup size. Include in the explainer copy or features.md.

---

## Cross-Links

- Affects: `features.md §13.4` (transcript storage), `§13.1` (on-device processing — unchanged), `§6.5` (Settings About — new row)
- Touches: `Jot/App/Settings/SettingsView.swift`, `Jot/App/LLM/Qwen35Client.swift` (if weight exclusion needed), `scripts/check-backup-attributes.sh` (new), `Jot/features.md`
- No changes to: `Jot/Shared/TranscriptStore.swift` (store location already correct), keyboard extension (unchanged)
- Related: Feature 2 (editable transcripts) — its SwiftData schema bump must also stay backup-friendly. They co-evolve.
