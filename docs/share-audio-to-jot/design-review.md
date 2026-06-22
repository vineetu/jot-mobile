# Adversarial review — Share Audio to Jot design

**Reviewer:** adversarial design-review agent
**Date:** 2026-06-20
**Target:** `docs/share-audio-to-jot/design.md`
**Method:** every code claim verified at file:line in the current tree; external iOS/Apple
claims checked against Apple's Extensibility docs and the project's own on-device findings.

---

## Verdict (one paragraph)

**Sound enough to implement — the core shape (thin stager → App Group → main-app drainer) is
correct and forced by real constraints — BUT the design leads with the wrong handoff path and
contains one compile-breaking factual error.** The crux call (don't transcribe in the extension)
is right. The stage-and-handoff architecture is right. However, **the design ranks Option A
(extension auto-opens Jot via `extensionContext.open`) as the primary path, and that mechanism is
documented by this very codebase as non-functional on the project's target OS.** The keyboard's
own code comments (from on-device iOS 26 testing) state `extensionContext.open` "silently no-ops"
and the responder-chain fallback the keyboard actually relies on is "banned by Apple in iOS 18+"
(`KeyboardView.swift:662-671`). The design must **lead with Option B (stage → user opens Jot →
drain on `didBecomeActive`)** and treat auto-open as a best-effort enhancement, not the headline.
Separately, the design's claim that `TranscriptStore` is "already compiled into extension targets"
is **wrong** — it is `#if JOT_APP_HOST`-gated and is NOT in any extension. That doesn't break the
architecture (the extension must not call `TranscriptStore` anyway), but the doc's stated reason
is inverted and must be corrected so an implementer doesn't try to link it. No blocking *unknowns*
remain; the two explicit calls below resolve O1 and #2.

---

## Explicit calls on the two flagged questions

### #1 — Handoff reliability / auto-open vs. user-opens → **LEAD WITH OPTION B**

**This is the design's biggest miss.** The design (§5.4, §12) hedges Option A as the recommendation
"with Option B as fallback if O1 proves `extensionContext.open` unreliable." O1 is already answered
**in this repo** — negatively:

- `KeyboardView.swift:662-671` (verbatim): *"nothing we tried to launch from a custom keyboard
  extension actually opens the containing app reliably on iOS 26 — `extensionContext.open` silently
  no-ops, the responder-chain selector trick is banned by Apple in iOS 18+, and SwiftUI `Link` was
  inconsistent in testing."*
- The keyboard's **working** host-app-open path is NOT `extensionContext.open`. It is a
  responder-chain walk that finds a `UIApplication`/`UIWindowScene` and calls
  `open(_:options:completionHandler:)` via a runtime selector (`openContainingApp`,
  `JotKeyboardViewController.swift:2604-2648`). That is precisely the "responder-chain selector
  trick" the comment above says is **banned in iOS 18+**. So even the keyboard's real mechanism is
  on borrowed time, and a Share Extension (`SLComposeServiceViewController`/`UIViewController`
  host) is not guaranteed to even have a `UIApplication` in its responder chain.
- `extensionContext.open(_:)` historically carried Apple's "available to a Today widget" framing;
  its behavior from a **Share** extension has always been unreliable, and this codebase's on-device
  evidence confirms it no-ops on the target OS.

**Conclusion (Confirmed):** Do not architect around auto-open. Lead with Option B: extension stages
+ posts the Darwin notification + shows a brief confirmation card, and the main app drains on the
next `didBecomeActive`/launch. Keep an `extensionContext.open(jot://share?id=…)` attempt as a
**best-effort** call whose failure is a no-op (the drainer catches up regardless) — exactly the
design's own safety net, just promoted to primary. This also dissolves O3 (Option B needs the
confirmation card, §7) and removes the fragile dependency the design itself flags in §12.

Confidence: **High** for "don't rely on auto-open" (direct in-repo evidence). Medium for the exact
iOS version where it broke — but it doesn't matter, since the safety net is mandatory either way.

### #2 — Does the main-app transcribe path work on a staged App-Group file? → **YES, with a corrected rationale**

Verified the reuse chain end-to-end:

- `TranscriptionService.shared.transcribe(audioFileURL:)` exists and is the shared singleton entry
  point (`TranscriptionService.swift:28-30, 59-75`; signature referenced at
  `TranscribeAudioFileIntent.swift:222-225`). It decodes + resamples in-process (file doc-comment
  `:15-17`). **Confirmed** it accepts an arbitrary file URL.
- `TranscriptStore.append(raw:cleaned:duration:…)` exists, inserts a `Transcript`, refreshes the
  mirror, posts `historyMirrorUpdated`, and runs the indexer (`TranscriptStore.swift:271-329`).
  **Confirmed** as the single ledger write.
- The watch path (`PhoneSideWCSession.handleIncomingAudio` → `saveTranscript`,
  `:302-446`) is the correct precedent and runs **in the main-app process**. **Confirmed.**

**The cross-sandbox `-54` trap does NOT apply to reading the staged App-Group file — but the
design's §5.3 framing conflates two different boundaries and must be tightened:**

- The `-54` / `.audioFileUnreadable` trap in `TranscribeAudioFileIntent.swift:174-193` occurs
  because `IntentFile.fileURL` points into **another process's private sandbox** (Shortcuts'
  `BackgroundShortcutRunner`). AVFoundation can't cross that boundary. **Verified at those lines.**
- An **App Group container is a shared sandbox region** both entitled processes read/write
  natively. A file the extension writes into `<AppGroup>/PendingShares/` is therefore readable by
  the main app **without** any bytes-copy or security-scope bracketing at read time. The design's
  worry that the bytes-copy is needed "because the main app is a different process" (§5.2 line 179
  parenthetical, §5.3) is **imprecise** — the App Group is exactly the mechanism that makes it
  safe.
- **Where the bytes-copy IS load-bearing:** at **staging** time, inside the extension. The
  `NSItemProvider` the extension receives resolves to the **source app's** sandbox (Voice
  Memos/Files/Mail). The extension must materialize the **bytes** INTO the App Group container
  (via `loadDataRepresentation`/`loadFileRepresentation` then a copy) — it must not stash the
  source URL and hand it across. The design reaches the right action (copy bytes into App Group)
  for a partially-wrong stated reason. **Fix the rationale, keep the action.**

**Net:** the transcribe path works on a staged App-Group file. Confidence: **High.**

---

## MUST-FIX

### M1 — Lead with Option B; demote auto-open to best-effort
Per call #1. The design's §5.4 recommendation ("Option A first") and §12 ("ship A first") invert
the project's own evidence. Rewrite §5.4/§5.5/§7/§12 so the primary, shipped flow is: stage →
Darwin notify → confirmation card → drain on `didBecomeActive`. `extensionContext.open` is a
try-and-don't-care enhancement. *Evidence:* `KeyboardView.swift:662-671`,
`JotKeyboardViewController.swift:2604-2648`.

### M2 — Correct the false "`TranscriptStore` is already compiled into extensions" claim
Design §2.2 (line 54): *"Lives in `Shared/`, so it is already compiled into extension targets."*
**Wrong.** `TranscriptStore` and `JotModelContainer` are wrapped in `#if JOT_APP_HOST … #endif`
(`TranscriptStore.swift:51` and `:406`). `JOT_APP_HOST` is defined ONLY for the main `Jot` target
(`project.yml:287-291`); the keyboard does not define it, which is the whole point of the guard
(`TranscriptStore.swift:51-58`). So `TranscriptStore` is **not** in any extension today and will
**not** be in the Share Extension. This does not harm the architecture — §5.1 already (correctly)
says the extension must not touch SwiftData — but the doc must fix the reason: the extension links
`Shared/` and gets `AppGroup` + `CrossProcessNotification` (both unguarded), but `TranscriptStore`/
`JotModelContainer` are compiled OUT of it by `#if JOT_APP_HOST`. An implementer who trusts the
current wording could waste time trying to call `append` from the extension and hit a "cannot find
'TranscriptStore' in scope" build error, or worse, add `JOT_APP_HOST` to the extension and pull
SwiftData + the container into the appex (violating the §5.1 invariant and the keyboard discipline
in `Jot/CLAUDE.md`). *Evidence:* `TranscriptStore.swift:51,406`; `project.yml:280-291`.

### M3 — Tighten the sandbox rationale (§5.3)
Per call #2. The bytes-copy is needed at **staging** (source-app sandbox → App Group), not because
the main app "can't read a different process's file" (the App Group is shared). State both
boundaries correctly so the implementer copies in the extension and reads natively in the app.
*Evidence:* `TranscribeAudioFileIntent.swift:174-193` (the real trap is `IntentFile.fileURL` into
Shortcuts' sandbox), App Group semantics.

### M4 — The drainer must construct `Transcript` to set `source`, OR add the `source:` param — pick one and spell it out
Design §8/§10 says "add `source: String? = nil` to `append`." Verified this is viable and
non-breaking: `source` is a real field on the live schema (`JotSchemaV7.swift:82`, also V5/V6 — so
no migration), and `append` does **not** currently pass `source` to the `Transcript` initializer
(`TranscriptStore.swift:284-299`), so it would be a new defaulted param = backward-compatible.
**However**, note the watch path does NOT use `append` at all — it builds `Transcript(… source:
"watch" …)` directly against its own `ModelContext` (`PhoneSideWCSession.swift:419-428`). So there
are two viable patterns and the design lists both without choosing. **Recommend: add `source:
String? = nil` to `append` and have the drainer call `append(raw:duration:source:"share")`** — it
keeps the single-ledger-write invariant the design rightly prizes (§2.1, "no code-path
divergence"), rather than forking a second direct-context writer like the watch did. Make this an
explicit decision in §10 step 1, not an "OR." *Evidence:* `JotSchemaV7.swift:82`,
`TranscriptStore.swift:271-299`, `PhoneSideWCSession.swift:419-428`.

### M5 — `transcribe(audioFileURL:)` enforces single-in-flight (`.busy`) — the drainer MUST serialize
The design's drainer "enumerate `PendingShares/` and for each: transcribe…" implies it could fire
multiple transcribes. `TranscriptionService` is single-in-flight and throws `.busy` if a
transcription is already running (`TranscriptionService.swift:42,49`; the doc-comment at `:19-23`
explains the `isTranscribing` short-circuit). If a share-drain races an in-app recording's
transcription (user shares a file, then immediately records), one will get `.busy`. The design's
§6.3 says "`.busy` → drainer queues and retries (don't surface)" — **good, but the design must
specify the drainer processes the queue serially and has an explicit retry/backoff on `.busy`**,
not just "for each." Otherwise a `.busy` mid-drain silently drops a staged file (or worse, deletes
it on a non-success path). Tie deletion strictly to transcription *success*. *Evidence:*
`TranscriptionService.swift:19-23,42,49`.

---

## NICE-TO-HAVE

### N1 — Activation-rule predicate: Apple's canonical form differs subtly from the design's
Verified against Apple's Extensibility guide: the documented SUBQUERY pattern asserts **all**
attachments conform (`.@count == $extensionItem.attachments.@count`), whereas the design's §6.1
predicate asserts **exactly one** audio attachment (`.@count == 1`). For single-file audio share
both behave similarly, but the design's form will **fail to activate** for a legitimate
multi-audio selection (which O4 says you may want to support) and could mis-handle a share that
carries an audio file plus an incidental attachment. Recommend Apple's "all attachments are audio"
form combined with `NSExtensionActivationSupportsFileWithMaxCount` for the count cap. *Evidence:*
Apple Extensibility Programming Guide, "Declaring Supported Data Types for a Share or Action
Extension" (SUBQUERY example uses `== $extensionItem.attachments.@count`).

### N2 — In-flight guard belongs in the drainer, and dedup-by-deletion has a crash window
The design (§5.2) borrows the watch's `recentlyReceivedUUIDs` in-flight guard
(`PhoneSideWCSession.swift:382-385`) — good. But note the watch path only appends to that list
**after** success (`:382`), specifically so a failed transcribe doesn't poison retries
(`:329-340`). The drainer should mirror that exactly: guard prevents *double-processing a uuid in
the same run*, but the durable dedup is "file still present = not yet done." If the app is killed
mid-transcribe (after reading, before delete), the file correctly survives and re-drains next
launch. Call this out so the implementer doesn't delete-then-transcribe. *Evidence:*
`PhoneSideWCSession.swift:329-340,382-385`.

### N3 — Memory during staging: prefer streaming copy over `Data(contentsOf:)`
Attack #5 holds. A 1-hour voice memo is tens of MB; `loadDataRepresentation` /
`IntentFile.data`-style whole-file loads pull the entire file into the extension's constrained
heap. The `TranscribeAudioFileIntent` precedent uses `file.data.write(to:)`
(`TranscribeAudioFileIntent.swift:201`) — fine in the **main app/headless intent** process, riskier
in a share extension's tighter Jetsam budget. Prefer `NSItemProvider.loadFileRepresentation` (gives
a temp URL) + `FileManager.copyItem` (kernel-level copy, not a full in-memory load) when copying
into the App Group. This is a *staging* concern only; transcription was already correctly moved out
of the extension. Confidence: Medium (extension budgets aren't published; community range is the
design's cited ~120 MB). *Evidence:* `TranscribeAudioFileIntent.swift:197-203` (the in-memory
pattern to avoid replicating in the appex).

### N4 — App Group entitlement: design is correct, but name the membership trap explicitly
§9's `project.yml` block adds `com.apple.security.application-groups:
[group.com.vineetu.jot.mobile.shared]` to the new target — **correct and required**, and it reuses
the existing group (`AppGroup.swift:9`; keyboard carries the same at `project.yml:372-376`). Add a
one-line note that the Share Extension must be added to the **main app's embedded-extensions /
dependencies** so it ships inside the app bundle (the design mentions this at §9 but it's easy to
miss), and that it must NOT inherit `JOT_APP_HOST` (ties to M2). No new App Group to provision —
**Confirmed.**

### N5 — Document-types fallback (O7) interacts with M1 favorably
Since auto-open is unreliable (M1), the `CFBundleDocumentTypes` + `onOpenURL` import path (§4) is
actually *more* attractive than the design credits: "Open in Jot" from Files routes through
`JotApp.onOpenURL` **in the main app**, where transcription can run directly with no handoff
fragility at all. Worth re-weighting as a genuine complementary path, not just a "near-free
fallback." Not required for v1. *Evidence:* `JotApp.swift:391-450` (the onOpenURL host-branch
dispatcher a `jot://share` or a document-open would slot into).

---

## VERIFIED CORRECT (claims that hold up)

- **The crux — don't transcribe in the extension (§3, §12).** Correct and well-argued. Parakeet is
  RAM-gated even in the main app (memory `project_batch_only_streaming.md`); the keyboard's 60 MB
  ceiling and refusal to link MLX/FM (`project.yml:377-387`, `Jot/CLAUDE.md` "Keyboard extension
  constraints") is the right precedent. **Confirmed.**
- **`extensionContext.open` is the fragile dependency (§12).** Correct — and stronger than the
  design states (it's effectively non-functional on target OS, not merely "fragile"). See M1.
- **Schema: no migration needed (§8).** Confirmed. `source` is an existing field
  (`JotSchemaV7.swift:82`); setting a new string value is data, not schema. No `@Model` field
  add/remove/rename. No `JotSchemaV8`, no `MigrationStage`. **Confirmed.**
- **`TranscriptStore.append` signature change is non-breaking (§8).** Adding `source: String? =
  nil` with a default is backward-compatible; existing callers
  (`TranscribeAudioFileIntent.swift:155-161`, ContentView, etc.) are unaffected. **Confirmed**
  (modulo M4: make it a decision, not an "OR").
- **Activation-rule mechanism (§6.1) keeps Jot out of the share sheet for non-audio.** The
  `NSExtensionActivationRule` predicate approach is the correct Apple mechanism and the SUBQUERY/
  `UTI-CONFORMS-TO`/`registeredTypeIdentifiers` syntax is valid (Apple Extensibility guide).
  **Confirmed** (refine the predicate per N1).
- **`TranscriptionError` vocabulary for friendly mapping (§6.3).** The six cases exist exactly as
  listed (`TranscriptionService.swift:39-57`), and the `.audioTooShort` ≥1 s detail is real
  (`:50`). The mapping covers the real failure surface. **Confirmed.**
- **App Group plumbing (§2.5).** `AppGroup.identifier` (`AppGroup.swift:9`),
  `CrossProcessNotification.post`/`addObserver` (`CrossProcessNotification.swift:142-157`), and the
  "add one `static let`" extension pattern (e.g. `historyMirrorUpdated` at `:56-58`) are all real
  and correctly described. **Confirmed.**
- **Watch path is the right architectural precedent (§2.3, §5.2).** `handleIncomingAudio` →
  `saveTranscript` runs in the main-app `@MainActor` singleton and does transcribe→mirror→notify→
  index (`PhoneSideWCSession.swift:302-446`). The "stage synchronously before the source URL is
  reclaimed" lesson (`:223-282`) is real and transfers. **Confirmed.**
- **Cleanup leak risk / staged-file cleanup (§7 of the attack list).** The design deletes staged
  files on success and re-drains survivors on launch; combined with N2 this is leak-safe. The
  parked `docs/recording-error-messages/design.md` the source task referenced **does not exist** in
  the repo (only `docs/plans/` and this folder) — the design correctly flagged this itself (§6.3).
  **Confirmed absent**; copy in §6.3 is self-contained, fine to proceed.

---

## Bottom line for the owner

Implement it — but **flip the primary handoff to Option B** (stage + confirmation card + drain on
next foreground), since the project's own iOS-26 evidence kills auto-open (M1). Fix the
`TranscriptStore`/`#if JOT_APP_HOST` misstatement before anyone wires the extension (M2). Tighten
the sandbox rationale (M3) and the `source:`/serial-drain/`.busy` details (M4, M5). Everything else
— the crux, the schema call, the activation rule, the error mapping, the App Group plumbing — is
verified sound. No blocking unknowns remain.
