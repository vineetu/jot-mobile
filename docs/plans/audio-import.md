# Plan: Accept Audio from Any App and Transcribe It

> **Status:** Planned. Voice Memos is the canary; share-sheet ubiquity is the v1 ship bar.
> **Size: M** (~2–3 days end-to-end including verification).

---

## Intent

Make Jot accept an audio file from any app on iOS — Voice Memos first, then Files, third-party recorders, AirDrop, downloaded podcasts — and produce a normal transcript that lands in the existing library exactly as if it had been dictated. No new format for the user to think about; no new home for the result. The Shortcuts file action (`TranscribeAudioFileIntent`) already proves the conversion pipeline is sound — this plan extends that single conversion path to the rest of iOS's audio-handoff surfaces.

## Scope decisions (assumptions called out)

- **ASSUMPTION:** v1 ships a Share Extension + main-app document-open + an in-app "Import audio" button. We do NOT also add drag-drop in v1 — that's a free follow-up because the document-type registration already enables it, but treating it as a v1 deliverable doubles QA. Drag-drop "works" by accident once `CFBundleDocumentTypes` lands; it just isn't on the v1 verification matrix.
- **ASSUMPTION:** The share extension does NOT transcribe in-process. It stages the file into App Group storage, posts a "pending import" record, and opens `jot://import?token=<uuid>` to bring the main app foreground for the real work. Same architecture as the keyboard's rewrite bounce. Rationale: Parakeet weights are 1.25 GB resident; a share extension's effective memory ceiling on iOS is ~120 MB before jetsam (worse than the keyboard's 60 MB perception because share extensions don't get the long-running keyboard heuristic). Linking FluidAudio + CoreML graphs into a share-extension target is a non-starter.
- **ASSUMPTION:** v1 caps audio length at **30 minutes** of source duration. This is enforced AFTER decode to 16 kHz mono Float32 (~115 MB at 30 min). Longer files surface a user-actionable error pointing at the Shortcuts intent for now, and a chunked-decode follow-up plan. The current `transcribe(audioFileURL:)` already accumulates the entire decoded `[Float]` into RAM before calling `runInference` (`loadAndResample` at `TranscriptionService.swift:1157–1267` returns one fully-realized `[Float]`); raising the cap requires chunked transcription, which is out of scope here.
- **ASSUMPTION:** Imported file is **deleted** after a successful transcription, on the same `defer { try? FileManager.default.removeItem(at: ...) }` pattern the existing intent uses. Rationale: privacy posture matches the rest of Jot ("audio never persists, only transcripts do") and the storage footprint of a 30 min M4A is ~30 MB per import — that adds up across heavy users.
- **ASSUMPTION:** No watchOS surface. The watch produces audio, never consumes it.
- **ASSUMPTION:** No iCloud Drive or remote-file streaming. If Files passes us an iCloud-only file, the system materializes it before invoking the share extension.

## User-facing flows

### Flow 1 — Voice Memos (the canary)

1. User opens Voice Memos, taps a memo, taps the Share button.
2. Share sheet shows Jot's icon. User taps it.
3. Share extension UI presents a single-screen "Import to Jot" sheet with the file name, an estimated duration, and an "Import" button. Cancel is the trailing button.
4. User taps Import. Sheet shows a short "Sending to Jot…" status, then dismisses itself within ~500 ms.
5. Behind the scenes: extension copies the M4A into App Group `Library/Caches/PendingImports/<uuid>.m4a`, writes a small JSON sidecar with origin metadata, and calls `extensionContext.open(URL(string: "jot://import?token=<uuid>"))`.
6. Main app foregrounds (or cold-launches), routes the URL, finds the pending import, kicks `TranscriptionService.shared.transcribe(audioFileURL:)` on it, and inserts the result via `TranscriptStore.append(...)`.
7. App lands on Recents with the new transcript at the top. A small toast confirms "Transcribed from Voice Memos".

### Flow 2 — Files app

1. Long-press an audio file → "Open in Jot" (via `CFBundleDocumentTypes`) OR Share → Jot.
2. Same downstream path as Flow 1.

### Flow 3 — In-app "Import audio" entry

1. Compact icon button on the Recents header (NOT a second floating button).
2. Presents `UIDocumentPickerViewController` filtered to `UTType.audio`.

### Flow 4 — Shortcuts (already shipped, unchanged)

`TranscribeAudioFileIntent` continues to work exactly as today.

### Flow 5 — AirDrop / Mail / Safari downloads / third-party recorders

Identical to Flow 1 (share sheet path).

## Architecture

```
┌─────────────────────────┐    ┌──────────────────────┐    ┌─────────────────────┐
│ Voice Memos / Files /   │    │ JotShareExtension    │    │ Jot (main app)      │
│ Mail / AirDrop / Safari ├───►│ - copy file to       │───►│ - onOpenURL handler │
│ Share Sheet             │    │   App Group staging  │    │ - read staged file  │
└─────────────────────────┘    │ - extensionContext   │    │ - transcribe()      │
                               │   .open(jot://import)│    │ - append to library │
                               └──────────────────────┘    │ - delete staged file│
                                                           └─────────────────────┘
```

### New target: `JotShareExtension`

- **Type:** `app-extension`, `NSExtensionPointIdentifier = com.apple.share-services`.
- **Memory budget:** Treat as 120 MB. We never link FluidAudio, MLX, Embeddings, or Apple FM.
- **Sources:**
  - `ShareExtension/ShareViewController.swift` — plain `UIViewController` presenting a tiny custom sheet.
  - `ShareExtension/PendingImportWriter.swift` — pure helper: copies an `NSItemProvider` audio payload into the App Group staging dir and writes a sidecar JSON.
  - Re-uses `Shared/AppGroup.swift` for the App Group identifier and staging-dir path conventions.
- **Info.plist:**
  - `NSExtensionActivationRule`: SUBQUERY predicate accepting only `public.audio` UTI conformance.
  - `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`.
  - `LSApplicationQueriesSchemes = ["jot"]` (required for `extensionContext.open` to fire the main-app URL).
- **Entitlements:** `com.apple.security.application-groups = ["group.com.vineetu.jot.mobile.shared"]`.
- **NOT linked:** `FluidAudio`, `MLXSwiftLM`, `MLXSwiftStructured`, `SwiftEmbeddings`, `FoundationModels.framework`.

### Main app: URL handler

In `JotApp.swift` `.onOpenURL`, add before dictation fallthrough:

```
if url.host == "import" {
    handleAudioImportURL(url)
    return
}
```

`handleAudioImportURL`:
1. Parse `?token=<uuid>`.
2. Look up staged file at `AppGroup.pendingImportsDir().appendingPathComponent("\(token).<ext>")`.
3. Read sidecar JSON for origin metadata (toast string only; transcription is content-type-agnostic).
4. Verify file exists, non-empty, sidecar `createdAt` within 24 hours.
5. Dispatch to `AudioImportCoordinator.run(token:url:)` on `@MainActor`.

`AudioImportCoordinator`:
- Posts "Transcribing imported audio…" via existing status banner.
- Probes duration via `AVAudioFile(forReading:).length / processingFormat.sampleRate`.
- Enforces 30 min cap.
- Calls `TranscriptionService.shared.transcribe(audioFileURL:)`.
- Calls `TranscriptStore.append(raw:, duration:, source: "file")`.
- Deletes staged file + sidecar.
- Shows toast: "Transcribed from \(originHint ?? "audio file")".
- On failure: leaves staged file in place for one retry, surfaces `audioImportError`.

### Main app: in-app document picker

`App/AudioImport/AudioImportButton.swift` — `Button` with paperclip/waveform glyph presenting `UIDocumentPickerViewController` (via `UIViewControllerRepresentable`) configured with `[UTType.audio]`. On `didPickDocumentsAt`:
- `startAccessingSecurityScopedResource()`
- Copy file into App Group pending-imports dir via `PendingImportWriter`
- `endAccessingSecurityScopedResource()`
- `UIApplication.shared.open(URL("jot://import?token=<uuid>"))`

Mounting site: Recents header in `ContentView.swift`.

### Document-types registration

`Jot/project.yml` → `Jot` target → `info:` → add:

```yaml
CFBundleDocumentTypes:
  - CFBundleTypeName: Audio File
    CFBundleTypeRole: Editor
    LSHandlerRank: Alternate
    LSItemContentTypes:
      - public.audio
      - public.mp3
      - com.apple.m4a-audio
      - com.apple.coreaudio-format
      - public.aifc-audio
      - public.aiff-audio
      - public.wav
```

**ASSUMPTION:** `LSHandlerRank = Alternate` — keeps Jot in the "Open in…" list without competing with Voice Memos / Apple Music for default ownership.

### Audio format compatibility matrix

| Format | UTI | Decode path | Notes |
|---|---|---|---|
| M4A (AAC) | `com.apple.m4a-audio` | `AVAudioFile` → `AVAudioConverter` | The 99% case. Voice Memos exports mono 22.05–44.1 kHz AAC. |
| MP3 | `public.mp3` | `AVAudioFile` → `AVAudioConverter` | Podcasts. VBR is fine. |
| WAV | `public.wav` | `AVAudioFile` → `AVAudioConverter` | Third-party recorders. |
| AIFF / AIFC | `public.aiff-audio` / `public.aifc-audio` | `AVAudioFile` → `AVAudioConverter` | Legacy QuickTime exports. |
| CAF | `com.apple.coreaudio-format` | `AVAudioFile` → `AVAudioConverter` | Some pro recorders. |
| FLAC | `org.xiph.flac` | **Skipped in v1.** | `AVAudioFile` does NOT decode FLAC on iOS. |
| OGG / Opus | `org.xiph.ogg-vorbis` / `org.xiph.opus` | **Skipped in v1.** | Same reason. |
| DRM-protected | varies | **Cannot decode.** | OS blocks. |

The decoder (`TranscriptionService.loadAndResample`) is already content-type-agnostic.

### Pending-import sidecar shape

```json
{
  "token": "EAB1...",
  "audioFilename": "Memo 27.m4a",
  "audioPathRelative": "EAB1....m4a",
  "audioContentType": "com.apple.m4a-audio",
  "sourceAppHint": "Voice Memos",
  "stagedAt": "2026-05-27T15:42:18Z"
}
```

`sourceAppHint` is best-effort — `NSExtensionItem.userInfo` does NOT reliably carry originating app name. Fall back to `UTType.localizedDescription` ("M4A audio"). Toast handles `nil` gracefully ("Transcribed from audio file").

## Schema impact

- **No new `@Model` fields or entities.** `source: String?` already in `JotSchemaV5.Transcript` (line 74) and `JotSchemaV6.Transcript` (line 90); documented value `"file"` already covers this.
- **Side-quest:** extend `TranscriptStore.append` with `source: String? = nil` parameter and plumb through `Transcript(...)` init. Non-schema change.
- **No `JotSchemaV7`.**

## `project.yml` work

```yaml
JotShareExtension:
  type: app-extension
  platform: iOS
  sources:
    - path: ShareExtension
    - path: ShareExtension/Assets.xcassets
    - path: Shared
    - path: Resources/PrivacyInfo.xcprivacy
  info:
    path: Resources/Share-Info.plist
    properties:
      CFBundleDisplayName: Jot
      CFBundleShortVersionString: $(MARKETING_VERSION)
      CFBundleVersion: $(CURRENT_PROJECT_VERSION)
      ITSAppUsesNonExemptEncryption: false
      NSExtension:
        NSExtensionAttributes:
          NSExtensionActivationRule: <SUBQUERY predicate>
        NSExtensionPointIdentifier: com.apple.share-services
        NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
      LSApplicationQueriesSchemes:
        - jot
  entitlements:
    path: Resources/Share.entitlements
    properties:
      com.apple.security.application-groups:
        - group.com.vineetu.jot.mobile.shared
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.vineetu.jot.mobile.Jot.Share
      GENERATE_INFOPLIST_FILE: NO
      SKIP_INSTALL: YES
```

Then add to `Jot` target's `dependencies:`:

```yaml
- target: JotShareExtension
```

`AudioImportCoordinator` lives in `App/` (main-app-only). `PendingImportWriter` lives in `Shared/` (uses only `Foundation` + `AppGroup.defaults`).

## features.md updates

Per the `CLAUDE.md` "feature work" protocol:

1. **Closest matching:** `§10.1 Shortcuts`, `§1.2 Transcript Library`, `§3 Transcript Detail` (the duration caveat needs updating).
2. **New section to add:** `§11 Import Audio`:
   - `§11.1 Share from any app`
   - `§11.2 Open in Jot from Files`
   - `§11.3 Import audio from inside Jot`
3. **Cross-link bidirectionally** with `§10.1`, `§1.2`, `§3`.
4. **Existing fixes:** widen `§1.2` to include "audio imported from other apps"; rewrite `§3` duration caveat to specify "Shortcuts" only.

## Implementation sequencing

1. **Plumb `source:` through `TranscriptStore.append`.** Pure additive parameter. Verify clean build.
2. **Add `AppGroup.pendingImportsDir()` helper + `PendingImportSidecar: Codable` + `PendingImportWriter.stage(...)`.**
3. **Implement `JotShareExtension` target.** Sources, Info.plist, entitlements, project.yml. `xcodegen`. Verify file lands in `PendingImports/`.
4. **Wire `jot://import` URL handler.** `AudioImportCoordinator`. Probe duration, enforce cap, transcribe, append, cleanup, toast.
5. **Register `CFBundleDocumentTypes`.** Edit project.yml, `xcodegen`. Verify "Open in Jot" from Files.
6. **In-app "Import audio" button.** `App/AudioImport/AudioImportButton.swift`. Mount on Recents header.
7. **`features.md` updates.**
8. **Help screen copy.** Single bullet, three sentences max.

## Verification

**Voice Memos canary (HARD GATE):**
- 30 s memo. Share → Jot. Transcript appears in Recents within 8 s cold / 4 s warm. Duration shows. `source: "file"` confirmed. Original audio gone from `PendingImports/`.

**Format matrix:** M4A pass, MP3 pass, WAV pass, CAF pass, AIFF pass, FLAC surfaces error.

**Length matrix:** 1 s → "under one second" error. 60 s / 5 min / 30 min pass. 31 min → "over 30 minutes" error before decode attempt.

**Surface matrix:** Voice Memos / Files Open-in / Files Share / AirDrop / Safari / Mail / Shortcuts (regression) / in-app picker — all verified.

**Failure modes:** DRM, file deleted mid-share, force-quit between share and re-launch, background mid-transcription, memory pressure.

**Console logs:** No `[SCHEMA-FALLBACK]`. New `AUDIO IMPORT FROM: <surface>` log line.

## Risks (top 5)

1. **30-minute cap will frustrate users with hour-long meetings.** Clear error copy + chunked-decode follow-up.
2. **`AVAudioFile` decode failures for exotic containers.** Error toast names the file. Best-effort.
3. **Share extension memory ceiling during file copy.** Prefer `loadFileRepresentation` (streaming); fall back to `loadDataRepresentation` only for sources under 10 MB.
4. **`NSExtensionActivationRule` predicate edge cases.** Files typed only as `public.data` won't trigger us — acceptable trade-off.
5. **Cold-launch race against Parakeet model load.** Already-handled by in-app status banner machinery; verify via cold-launch share-sheet test.

## Out of scope (deliberately)

- Long-file chunked transcription (>30 min). Follow-up.
- Keeping imported audio for re-transcription on model upgrade. Follow-up with consent UX.
- watchOS share extension.
- macOS / catalyst share.
- Format expansion to FLAC/OGG/Opus.
- Drag-and-drop into main app (works for free; not on v1 matrix).
- Multi-file import in a single share action.

## Cross-links

- `Jot/App/Transcription/TranscriptionService.swift:303` — `transcribe(samples:)`.
- `Jot/App/Transcription/TranscriptionService.swift:376` — `transcribe(audioFileURL:)`, the entry point reused verbatim.
- `Jot/App/Transcription/TranscriptionService.swift:1157` — `loadAndResample`, 16 kHz mono Float32 conversion.
- `Jot/App/Intents/TranscribeAudioFileIntent.swift` — Shortcuts intent. Untouched.
- `Jot/Shared/TranscriptStore.swift:267` — `append`. Extended to accept `source:`.
- `Jot/Shared/Schema/JotSchemaV6.swift:90` — `source` field. Used, not modified.
- `Jot/Shared/AppGroup.swift` — App Group identifier + staging dir helpers.
- `Jot/App/JotApp.swift:362` — `.onOpenURL`. Extended with `import` host branch.
- `Jot/App/ContentView.swift` — Recents header. Adds in-app import button.
- `Jot/project.yml` — new `JotShareExtension` target + `CFBundleDocumentTypes`.
