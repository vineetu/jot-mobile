# Share Audio to Jot — native Share Sheet target

**Status:** Design / discovery only. NO product code written. Owner gates implementation.
**Date:** 2026-06-20
**Author:** scoping agent

---

## 1. Goal (owner intent)

Make Jot a **native iOS Share Sheet target for audio files** so a user can share a voice
memo / audio file from any app (Voice Memos, Files, Mail, Messages, …) → tap **"Jot"** in the
share sheet → it transcribes on-device with Parakeet + saves to the transcript library —
**without the user building a Shortcut**.

Two hard requirements from the owner:

1. **Built-in, not a Shortcut.** The owner already tested the Shortcut path (Share Sheet →
   "Transcribe Audio with Jot" via `TranscribeAudioFileIntent`) and confirmed it works. They
   want the same outcome as a first-class share action — zero setup.
2. **Never a raw crash on an unknown file.** "Jot should NOT throw an exception if someone
   shares an unknown file — tell me what it is." → graceful, clear messaging for non-audio /
   unreadable files. Never a raw `NSException` / red error.

---

## 2. What exists today (cite file:line)

### 2.1 The reusable transcribe+save core
`Jot/App/Intents/TranscribeAudioFileIntent.swift` is the strongest existing precedent — it
already does exactly what we need, just from the Shortcuts runtime instead of a Share Extension:

- `@Parameter audioFile: IntentFile` with `supportedContentTypes: [.audio]`
  (`TranscribeAudioFileIntent.swift:91-96`).
- **`materializeAudioToOwnedTempFile(from:)`** (`:168-203`) — copies the intent's audio **bytes**
  (`IntentFile.data`) into a tmp file **inside its own sandbox**, deliberately NOT using
  `IntentFile.fileURL`. The doc comment at `:174-193` is load-bearing: when the producing action
  runs in a *different process/sandbox*, AVFoundation cannot read across the sandbox boundary —
  `ExtAudioFileOpenURL` returns `-54` (`kAudioFileFilePermissionError`) → surfaces as
  `.audioFileUnreadable` (what users saw as "TranscriptionError error 2"). **This lesson applies
  verbatim to a Share Extension** (§5.3).
- `runTranscription(fileURL:)` (`:222-225`) → `TranscriptionService.shared.transcribe(audioFileURL:)`.
  `.shared` is a process-wide singleton (`TranscriptionService.swift:59-73`) so a warm main-app
  model load is reused.
- Saves via `TranscriptStore.append(raw:cleaned:duration:)` on `@MainActor` (`:155-161`).
- "No code-path divergence across the three transcription surfaces is a shipped invariant"
  (`:133-145`) — a 4th surface (Share Extension) must also land in the same ledger.

### 2.2 The transcription core itself
`TranscriptStore.append(...)` (`Jot/Shared/TranscriptStore.swift:272-279`) is the single ledger
write. It: inserts a `Transcript` into a `ModelContext(JotModelContainer.shared)`, refreshes the
keyboard's App Group JSON mirror (`TranscriptHistoryMirror.refresh`), and wakes live keyboard
observers. Empty/whitespace `raw` is a no-op (`:280-281`). Lives in `Shared/`, so it is already
compiled into extension targets.

`TranscriptionService.TranscriptionError` (`Jot/App/Transcription/TranscriptionService.swift:39-57`)
is the error vocabulary we must map to friendly text:
`.busy`, `.audioTooShort`, `.loadFailed`, `.inferenceFailed`, `.audioFileUnreadable`,
`.audioFileConversionFailed`. **Note: `TranscriptionService` lives in `App/`, not `Shared/`** —
it is NOT compiled into extensions (§5.1 implication).

### 2.3 The strongest architectural precedent: watch audio
`Jot/App/WatchConnectivity/PhoneSideWCSession.swift` is the watch→phone audio path and is the
**exact pattern to mirror** — with one critical difference (§5.1). When the watch sends an audio
file:

1. `session(_:didReceive:)` (`:223-267`) stages the file **synchronously** into a staging
   directory before the delegate returns, because iOS reclaims the source URL immediately
   (`stageFileSync` at `:273-282`, with the load-bearing "copy before return" comment at `:224-236`).
2. `handleIncomingAudio(...)` (`:302-398`) dedups (in-memory + SwiftData), calls
   `TranscriptionService.shared.transcribe(audioFileURL:)` (`:363`), then saves via
   `saveTranscript(...)` (`:409-446`) which mirrors `TranscriptStore`'s pattern (insert →
   `TranscriptHistoryMirror.refresh` → `CrossProcessNotification.post(historyMirrorUpdated)` →
   `TranscriptIndexer.index`).
3. **Crucially, all of this runs IN THE MAIN APP PROCESS** — `PhoneSideWCSession` is a main-app
   `@MainActor` singleton (`:20-22`). The watch is a *separate device*; the iPhone main app does
   the transcription. This is why the watch path can afford to load Parakeet — it is never an
   extension. **A Share Extension does NOT have this luxury (§5.1).**

### 2.4 Existing extension targets (the template + the constraint)
`project.yml` declares two `app-extension` targets:
- **`JotKeyboard`** (`project.yml:293-387`) — `type: app-extension`, App Group entitlement
  (`group.com.vineetu.jot.mobile.shared`, `:375-376`), its own `Info.plist` with an `NSExtension`
  dict (`:346-353`), `LSApplicationQueriesSchemes: [jot]` so it can `extensionContext.open(jot://…)`
  (`:357-358`). **The keyboard explicitly does NOT link MLX / Apple FM and has a documented ~60 MB
  ceiling** (`project.yml:39-40`, `Jot/CLAUDE.md` "Keyboard extension constraints"). It bounces
  heavy work to the main app via a `jot://` deep link rather than running inference in-process.
  This is the single most important precedent for our memory strategy.
- `JotWatchWidgets` (`project.yml:519-541`) — widget extension, no App Group.

**No Share Extension exists yet.** This is a net-new target.

### 2.5 App Group + cross-process plumbing
- `AppGroup.identifier = "group.com.vineetu.jot.mobile.shared"` (`Jot/Shared/AppGroup.swift:9`),
  `AppGroup.defaults` is the shared `UserDefaults(suiteName:)` (`:17-18`). All extension targets
  that need shared state carry this App Group entitlement.
- `CrossProcessNotification` (`Jot/Shared/CrossProcessNotification.swift`) is the Darwin-notification
  wrapper (`post` at `:142-150`, `addObserver` at `:152-157`). Adding a new cross-process signal =
  add one `static let … = Name(rawValue:)` (the file is full of precedents, e.g.
  `historyMirrorUpdated` at `:56-58`). This is how the extension will wake the main app.
- `jot://` URL handling lives in `Jot/App/JotApp.swift:391-450` (`.onOpenURL`), already branching
  on `url.host` (`rewrite`, `history`, `transcript`, `dictate`). A new host (`jot://share`) slots
  in here. The keyboard's `extensionContext.open(jot://…)` bounce (`:444-449`) is the precedent
  for an extension opening the main app.

---

## 3. The crux: where does transcription run?

**This is the single hard problem.** Everything else is plumbing we already own.

iOS app extensions run under **far tighter memory limits than the foreground app**. Apple's
Extensibility guide states extensions "may be aggressively terminated" and must be "nimble and
lightweight"; it does not publish exact numbers, but the community-observed share-extension
ceiling is in the **~120 MB Jetsam range** (and lower under pressure). Jot's own keyboard target
is held to a **~60 MB ceiling** by project convention (`Jot/CLAUDE.md`), and that ceiling is the
explicit reason the keyboard refuses to link MLX / Apple FM and instead URL-bounces heavy work.

Parakeet (the bundled 600M ASR model) loads **hundreds of MB** of CoreML weights into memory and
is RAM-gated even in the main app (see memory `project_batch_only_streaming.md`: "600M-only,
RAM-gated"). **Running full Parakeet transcription inside a Share Extension is not viable** — it
would Jetsam-kill the extension mid-load on most devices, which is exactly the kind of raw failure
the owner wants to avoid.

**Conclusion (Confirmed by analogy to the keyboard + watch architecture):** the Share Extension
must **NOT transcribe in-process**. It stages the shared audio and hands off to the **main app**,
which already owns a warm-capable `TranscriptionService.shared` and the SwiftData container. This
mirrors the keyboard's "bounce heavy work to the main app" pattern and the watch's "main app does
the ASR" pattern.

---

## 4. Mechanism decision: Share Extension vs document types

| | **Share Extension** (recommend) | `CFBundleDocumentTypes` + `LSSupportsOpeningDocumentsInPlace` |
|---|---|---|
| Share-sheet UX | Appears as a **"Jot" action** in the share sheet (the owner's exact ask). | Appears as **"Copy to Jot"** / "Open in Jot" in the *file*-app import row, not a share action. Different, weaker affordance. |
| Trigger | User taps Jot in the Share Sheet from *any* app. | User uses Files' "Copy to…" or an app's open-in picker; routes through `onOpenURL`. |
| Activation filtering | `NSExtensionActivationRule` can declare **audio-only**, so Jot only appears for audio. | iOS shows Jot for any declared doc type; less precise control over the share-sheet surface. |
| Effort | New extension target + Info.plist + entitlement + a small `UIViewController` host. | Add `CFBundleDocumentTypes` to the **main app** Info.plist + `onOpenURL` import branch. Lower effort. |
| Memory | Subject to extension memory ceiling → must hand off (§3). | Import handler runs **in the main app** → could transcribe directly. |
| Owner's stated UX | ✅ matches "Jot in the share sheet". | ❌ "Copy to Jot" is not what they described. |

**Recommendation: build a real Share Extension.** It is the only mechanism that produces the
share-sheet "Jot" action the owner asked for, and `NSExtensionActivationRule` gives us precise
audio-only filtering (§6). The document-types path is noted as a *possible cheap fallback / future
add* but does not satisfy the intent.

(Worth flagging to the owner: we could ship BOTH — the document-types path is nearly free once the
`onOpenURL` import branch exists, and it would let "Open in Jot" from Files also work. But it is
not required and adds surface area. Default: Share Extension only.)

---

## 5. Recommended architecture: stage-and-handoff

The Share Extension is a **thin stager**. It does three things, all cheap:
1. Validates the shared item is audio (belt-and-suspenders behind the activation rule).
2. Copies the audio **bytes** into the App Group container (a pending-queue file).
3. Signals the main app to transcribe, then dismisses with a confirmation.

The **main app** does the heavy lifting: drains the queue, transcribes with
`TranscriptionService.shared`, saves via `TranscriptStore.append`. This reuses 100% of the
existing core and keeps the extension well under any memory ceiling.

### 5.1 Why the extension can't reuse `TranscriptionService` directly
`TranscriptionService` lives in `App/` (`Jot/App/Transcription/`), not `Shared/`, so it is not
compiled into extension targets — and even if it were, §3 says it can't run there. The extension
links **only `Shared/`** sources (like the keyboard does). The transcribe+save core
(`TranscriptStore`, `TranscriptHistoryMirror`, `CrossProcessNotification`, `AppGroup`) is already
in `Shared/`, but **`TranscriptStore.append` opens `JotModelContainer.shared`** — and
`Jot/CLAUDE.md` is explicit: *"Do NOT open `JotModelContainer.shared` from the keyboard target."*
The same discipline applies here: **the Share Extension must not touch SwiftData or Parakeet.** It
only writes a file + a Darwin notification. The main app is the sole writer.

### 5.2 The staging queue (mirror the watch + keyboard patterns)
Create a pending-share directory inside the App Group container, analogous to the watch's
`WatchAudioStaging` (`PhoneSideWCSession.swift:273-282`) but in the **shared** container (not tmp,
because the main app — a different process — must read it):

```
<AppGroup container>/PendingShares/<uuid>.<ext>      ← the copied audio bytes
<AppGroup container>/PendingShares/<uuid>.json       ← sidecar metadata (orig filename, UTType, sharedAt)
```

The extension:
1. Reads the shared `NSItemProvider` and loads the item's **data** (not its URL) via
   `loadDataRepresentation(forTypeIdentifier:)` / `loadFileRepresentation` then copies bytes —
   **never trust the source URL** (§5.3).
2. Writes the bytes + a small JSON sidecar to `PendingShares/`.
3. Posts a new `CrossProcessNotification.audioShareQueued` Darwin notification (add one
   `static let` in `CrossProcessNotification.swift`).
4. Optionally `extensionContext.open(jot://share?id=<uuid>)` to foreground the app (Option A below).
5. Calls `extensionContext.completeRequest(...)` to dismiss.

The main app:
- On `audioShareQueued` (live, app foregrounded) AND on every `didBecomeActive` / launch
  (catch-up, app was killed), runs a **`PendingShareDrainer`** (new, main-app-only):
  enumerate `PendingShares/`, and for each: `TranscriptionService.shared.transcribe(audioFileURL:)`
  → `TranscriptStore.append(raw:duration:nil)` → delete the staged file + sidecar. Dedup is
  inherent (file deleted on success); add a simple in-flight guard so a foreground signal + a
  launch-catch-up don't double-process the same uuid (mirror `recentlyReceivedUUIDs`,
  `PhoneSideWCSession.swift:382-385`).

This is **directly modeled on `PhoneSideWCSession.handleIncomingAudio`** — same transcribe→append
→mirror-refresh→notify shape, just sourced from a shared-container file instead of a WCSession file.

### 5.3 Sandbox lesson — copy bytes, not the URL (load-bearing)
The `NSItemProvider` the extension receives points at the **source app's** sandbox (Voice Memos,
Files, …). This is the **same cross-sandbox trap** documented at `TranscribeAudioFileIntent.swift:174-193`:
AVFoundation cannot read across the boundary → `-54` / `.audioFileUnreadable`. The extension MUST
materialize the **bytes** into the App Group container, exactly as the intent materializes
`IntentFile.data`. The staged App Group file is then readable by the main app (both processes hold
the App Group entitlement). Do not pass the original share URL across to the main app.

### 5.4 Handoff: open-app-now (Option A) vs background-queue (Option B)

**Option A — open the main app immediately.** Extension stages, then
`extensionContext.open(jot://share?id=<uuid>)` foregrounds Jot, which drains immediately and the
user watches "Transcribing…" → lands in the library.
- Pro: immediate, visible result; reuses the warm `TranscriptionService.shared`; clearest UX
  ("I shared it, Jot opened and transcribed it").
- Pro: matches the keyboard's established `extensionContext.open(jot://…)` bounce.
- Con: yanks the user out of the source app (they were in Voice Memos). For a *share* action this
  is arguably expected (they chose to send it to Jot), unlike the keyboard case where it's jarring.
- Caveat (Confirmed risk): `extensionContext.open` from a **Share** Extension is historically less
  reliable than from a keyboard/today extension — Apple has at times restricted it. **Open question
  O1.** If unreliable, fall back to Option B + a local notification.

**Option B — stage silently, transcribe on next foreground.** Extension stages + posts the Darwin
notification + dismisses with a confirmation ("Saved to Jot — open Jot to see the transcript").
Main app drains on next `didBecomeActive`.
- Pro: never interrupts the source app; cleanest "fire and forget".
- Pro: no reliance on `extensionContext.open` from a share extension.
- Con: result isn't immediate — the transcript appears only when the user next opens Jot. For a
  long audio file this could be a surprising delay.
- Note: a Share Extension **cannot** itself run the main app in the background to transcribe; iOS
  does not background-launch the container app from a share extension. So "transcribe in the
  background without opening the app" is **not possible** without the heavy in-extension path we
  ruled out in §3. Be honest with the owner about this.

**Recommendation: Option A (open app + immediate transcribe), with Option B as the fallback** if
O1 proves `extensionContext.open` unreliable for share extensions on the target iOS. Ship A first;
keep the drain-on-foreground catch-up (it is needed regardless, for the app-was-killed case).

### 5.5 End-to-end flow (Option A)
1. User in Voice Memos → Share → **Jot**.
2. Share Extension presents a minimal confirmation UI (or no UI — see §7), validates audio (§6),
   copies bytes → `PendingShares/<uuid>.m4a` + sidecar, posts `audioShareQueued`,
   `extensionContext.open(jot://share?id=<uuid>)`, `completeRequest`.
3. Main app foregrounds via `.onOpenURL` (`JotApp.swift:391`), new `url.host == "share"` branch →
   triggers `PendingShareDrainer`.
4. Drainer shows a "Transcribing…" state (reuse the existing pipeline-phase UI surface), runs
   `TranscriptionService.shared.transcribe(audioFileURL:)`, then `TranscriptStore.append`.
5. Transcript appears in the library; mirror refresh + Darwin notify happen inside `append`.
6. Staged file deleted.

---

## 6. Graceful unknown-file handling (owner requirement #2)

Two layers of defense:

### 6.1 Activation rule — only offer Jot for audio
The Share Extension's `Info.plist` `NSExtension.NSExtensionAttributes.NSExtensionActivationRule`
declares **audio UTIs only**, so the share sheet does not even show "Jot" for a PDF or photo. Two
forms:
- **Simple dictionary form:** `NSExtensionActivationSupportsFileWithMaxCount = 1` plus a predicate,
  OR
- **Predicate string form** (more precise), e.g. require the shared item to conform to
  `public.audio`:
  ```
  SUBQUERY(extensionItems, $ei,
    SUBQUERY($ei.attachments, $a,
      ANY $a.registeredTypeIdentifiers UTI-CONFORMS-TO "public.audio"
    ).@count == 1
  ).@count == 1
  ```
Declare the concrete audio types Voice Memos / Files emit: `public.audio` (the umbrella),
`com.apple.m4a-audio`, `public.mp3`, `com.microsoft.waveform-audio` (wav), `com.apple.coreaudio-format`
(caf), `public.aiff-audio`. Conforming to `public.audio` covers most; list the concrete m4a/mp3/wav
so providers that don't tag the umbrella still match. **Confirm exact UTI strings against Apple's
UTType reference at implementation time (open question O2).**

### 6.2 In-extension friendly messaging (the file still slips through)
Even with the activation rule, a mistagged or unreadable item can arrive (e.g. a file declared as
`public.audio` but corrupt). The extension must NEVER raise a raw exception. Handle:
- **Not actually audio / no audio attachment:** show a clear sheet message
  *"Jot can only transcribe audio files."* and dismiss cleanly (`completeRequest` /
  `cancelRequest`). No crash.
- **Unreadable / zero bytes:** *"That audio file couldn't be read."*
- The extension does this validation BEFORE staging — it never reaches the main app with garbage.

### 6.3 Map `TranscriptionError` → friendly text (main app side)
If audio stages fine but transcription fails in the main app, map
`TranscriptionService.TranscriptionError` (`TranscriptionService.swift:39-57`) to friendly copy
instead of surfacing the raw `errorDescription`:
- `.audioFileUnreadable` / `.audioFileConversionFailed` → *"Jot couldn't read that audio file. It
  may be a format Jot doesn't support."*
- `.audioTooShort` → *"That clip is too short to transcribe."* (Parakeet needs ≥1 s — `:50`.)
- `.loadFailed` / `.inferenceFailed` → *"Something went wrong transcribing that file. Try again."*
- `.busy` → drainer queues and retries (don't surface).

This follows the same "user-facing message, not raw error" philosophy the owner wants. (The task
referenced a parked `docs/recording-error-messages/design.md` for the message philosophy — **that
doc does not currently exist** in the repo, only `docs/plans/`; flagging so the owner can point me
at the right doc if they want copy alignment. For now the copy above is self-contained.)

---

## 7. UX — what the user sees

**Decision needed (open question O3):** does the extension show a confirmation card, or dismiss
silently?

Recommended (Option A): **minimal-to-no extension UI.** The share extension presents very briefly
(validate + stage is fast — it's a byte copy, not a transcription), then opens Jot. The user's
"feedback" is the main app foregrounding into a "Transcribing…" state and then the new transcript
in the library. This avoids a redundant double-confirmation (extension card + app).

If Option B (no app open): the extension SHOULD show a brief confirmation card
(*"Saved to Jot"* / *"Jot will transcribe this — open Jot to see it"*) because there's no other
signal the share succeeded.

Reuse existing surfaces in the main app: the pipeline-phase / "Transcribing…" UI already exists
for dictation; the drainer should publish into the same surface so a shared-file transcription
looks like any other in-progress transcription.

---

## 8. Schema impact (per `Jot/CLAUDE.md`)

- **Does this add/remove/rename `@Model` fields or add `@Model` entities?** **No.**
- The staged audio is a **file** in the App Group container, not a model.
- The result is written through the **existing** `TranscriptStore.append(...)`, producing a
  standard `Transcript` (current `JotSchemaVN`). No new fields.
- **Optional consideration:** the watch path stamps `source = "watch"` (`PhoneSideWCSession.swift:424`).
  We may want a `source = "share"` value for provenance/analytics. **`source` is an existing
  field** (read by the top-10 watch push at `:178-181`), so setting it to a new *string value* is
  NOT a schema change — it's just data. `TranscriptStore.append` does not currently take a
  `source` param (`:272-279`); adding one is an API change, not a schema migration. **Recommend:
  add a `source: String? = nil` parameter to `append` (backward-compatible default) OR set it via
  the watch-style direct-context path.** Either way: **no `JotSchemaV(N+1)` needed, no
  `MigrationStage`.** Confirmed.

---

## 9. `project.yml` changes

A new `app-extension` target, modeled on the `JotKeyboard` block (`project.yml:293-387`):

```yaml
JotShareExtension:            # name TBD
  type: app-extension
  platform: iOS
  sources:
    - path: ShareExtension    # new dir: principal view controller + staging logic
    - path: Shared            # for AppGroup, CrossProcessNotification (NOT TranscriptStore use)
  info:
    path: Resources/ShareExtension-Info.plist
    properties:
      CFBundleDisplayName: Jot
      NSExtension:
        NSExtensionPointIdentifier: com.apple.share-services
        NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
        NSExtensionAttributes:
          NSExtensionActivationRule: <audio-only predicate from §6.1>
      LSApplicationQueriesSchemes: [jot]   # for extensionContext.open(jot://share) (Option A)
  entitlements:
    path: Resources/ShareExtension.entitlements
    properties:
      com.apple.security.application-groups:
        - group.com.vineetu.jot.mobile.shared
  # No MLX, no Apple FM, no TranscriptionService — thin stager only.
```

Plus:
- Add `JotShareExtension` to the main `Jot` target's embedded extensions (mirror how
  `JotKeyboard` is embedded — `project.yml:269` region / the `dependencies` + embed config).
- New files: `Resources/ShareExtension-Info.plist`, `Resources/ShareExtension.entitlements`,
  `ShareExtension/` source dir.
- **Memory discipline:** like the keyboard, the share extension must compile ONLY `Shared/` +
  its own thin source — NOT `App/Transcription/`, NOT MLX/FM packages. Keep it featherweight.
- Run `xcodegen` from `Jot/` after editing `project.yml`.

App Group entitlement is the same existing group — no new App Group to provision.

---

## 10. Staged implementation plan (prose / pseudocode only — NO Swift)

1. **Plumbing first (no extension yet).**
   - Add `CrossProcessNotification.audioShareQueued` name.
   - Add a `PendingShares/` helper to `Shared/` (App Group container URL + write/enumerate/delete).
   - Build `PendingShareDrainer` in the main app: enumerate → `transcribe(audioFileURL:)` →
     `TranscriptStore.append` (add `source: "share"` once §8 param lands) → delete; in-flight guard.
   - Wire the drainer to: `audioShareQueued` observer + `didBecomeActive` + a `jot://share`
     `.onOpenURL` branch in `JotApp.swift:391`.
   - **Testable end-to-end** by manually dropping a file into `PendingShares/` — before any
     extension exists.
2. **Add the Share Extension target** (`project.yml` + Info.plist + entitlement + `xcodegen`).
3. **Implement the thin extension**: read `NSItemProvider` → validate audio → copy **bytes** to
   `PendingShares/` + sidecar → post `audioShareQueued` → (Option A) `extensionContext.open` →
   `completeRequest`. Friendly in-extension messaging for non-audio / unreadable (§6.2).
4. **Error-mapping pass**: map `TranscriptionError` → friendly copy in the drainer (§6.3).
5. **Activation rule tuning**: verify the audio-only predicate actually hides Jot for
   non-audio in the real share sheet across Voice Memos / Files / Mail (§6.1, O2).
6. **Decide A vs B** based on `extensionContext.open` reliability testing (O1).
7. **`features.md` + `ARCHITECTURE.md` updates** (new surface + new cross-process boundary —
   this crosses a process boundary so `ARCHITECTURE.md` gets a row).

---

## 11. Owner decisions — LOCKED (2026-06-20)

All open questions resolved with the owner. **The governing principle: never navigate the user
away from where they are.** That is a core product ethos of Jot, and it selects **Model B** over
Model A across the board.

- **O1 — Model B (queue-and-drain), NOT Model A.** The Share Extension **never** calls
  `extensionContext.open`. It stages the audio into `<AppGroup>/PendingShares/` and completes,
  leaving the user exactly where they were (Voice Memos / Files / Mail). Transcription happens on
  the **next natural foreground of Jot** (the `didBecomeActive` drainer, §5.4). "As invisible as
  possible" — the owner accepts that Jot must run *at some point* (iOS won't background-launch for
  ASR), but we never force it open. **This also eliminates the design's one fragile dependency:
  with no `open` call, there is nothing to fail (supersedes §12 / O-fragility).**
- **O2 — UTIs:** declare `public.audio` + concrete m4a/mp3/wav/caf/aiff. (m4a is what Voice Memos
  emits — primary case.)
- **O3 — Confirmation card: YES.** Before the extension dismisses, show a brief **"Saved to Jot ✓"**
  so the user knows it took (then they stay put). Minimal, no navigation.
- **O4 — Multi-select: YES.** Selecting multiple audio files shares them all → **one transcript
  each** (`NSExtensionActivationSupportsFileWithMaxCount` set > 1; stage each into the queue).
- **O5 — `source = "share"` provenance: YES.** Stamp shared transcripts so they're filterable
  later. (No schema cost — `source: String? = nil` on `append`, the watch path already uses this.)
- **O6 — Cleanup: honor the global setting,** run in the main-app drainer where Apple FM is
  available (same behavior as an in-app transcript).
- **O7 — Share Extension only.** No document-types "Open in Jot" fallback for now.

---

## 12. Honesty / risk summary

- **The crux is real and unavoidable:** a Share Extension cannot run Parakeet (§3). The design's
  whole shape — stage-and-handoff to the main app — is forced by this. Anyone proposing
  "just transcribe in the extension" is wrong; it Jetsam-dies.
- **`extensionContext.open` from a *share* extension is the one fragile dependency** (§5.4 / O1).
  The catch-up drainer on `didBecomeActive` is the safety net regardless.
- **No schema migration, no new App Group** — this is additive plumbing over existing, well-worn
  patterns (keyboard's bounce-to-app, watch's stage-and-transcribe). Low schema risk; the work is
  in the new target + the activation rule + friendly error copy.
