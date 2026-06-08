# Bug: in-app dictation duplicates the text on stop (transcript Edit / Feedback fields)

> **Status: BRIDGE IMPLEMENTED (2026-06-03) — full app builds; PENDING on-device test.** The first attempt (collapse to one keyboard paste path: delete the keyboard same-field guards + the in-process `FocusedFieldInsert` side door) **dropped the in-app paste on device** — confirming the host's SwiftUI re-render on stop disconnects the keyboard proxy (nil-context), so the keyboard flush has nothing to insert into in-Jot. Pivoted to a **bridge**: restored `FocusedFieldInsert` (the in-process insert is the sole in-app deliverer), and on the transient path **clear the keyboard's pending paste BEFORE the publish/phase-flip** so the keyboard flush finds no pending session and skips — closing the duplicate race deterministically (no main-app/keyboard double-insert). The keyboard's documentIdentifier/keyboardType same-field guards stay **removed** (CEO's "paste wherever the cursor is" choice for *other* apps; in-app the keyboard never reaches them — it skips on the cleared session). **True single path is deferred to the root-decoupling refactor** (`refactor-decouple-root-view.md`), which isolates the field so the keyboard flush works in-app and the bridge can be deleted. **On-device test:** in-Jot paste lands EXACTLY once across transcript Edit / Feedback / Wizard W5 (not zero, not twice); no new Recents row (no-save holds); other-app paste still lands once. Original confirmation/diagnosis + fix plan retained below.

## ✅ Confirmation — original hypothesis is RIGHT; it's an intermittent race (on-device, 2026-06-03)

Two on-device reproductions, each showing a DIFFERENT keyboard outcome — which is
the whole story: **the bug is intermittent because the keyboard's flush sometimes
wins the race and pastes, sometimes skips.**

**Reproduction A — DUPLICATE (keyboard pasted).** One in-app stop, all events same
second, chronological:
- `[keyboard] Pending session written at stop`
- `[main-app] Resolved session ID before publish`
- `[keyboard] Flush ran with no fresh transcript` ×2 (harmless — payload already consumed/not fresh)
- **`[keyboard] Inserted transcript into host`**  ← keyboard PASTE = insert #1
- **`[main-app] In-Jot transient paste (in-process insert)`**  ← in-process = insert #2

Both inserters fire for the SAME recording (same second) → text lands twice.
This is the duplicate. No session-ID comparison needed — both inserts are visible.

**Reproduction B — NO duplicate (keyboard skipped).** A different stop logged
`[keyboard] Payload session ID did not match pending` ×2 — the keyboard's flush hit
its reject path and did NOT paste, so only the in-process insert landed (correct,
single).

**So the mechanism is:** on an in-app (transient) stop, the keyboard's
`flushPendingAutoPasteIfPossible` and the main-app in-process `FocusedFieldInsert`
race. The "clear pending paste" at `DictationPipeline.swift:381` is meant to neuter
the keyboard flush, but it runs in the main-app process AFTER the publish + phase
flip (`:343-362`) that wakes the keyboard's flush in its own process. Outcome
depends on timing:
- keyboard flush sees a fresh + session-matching payload AND its in-app guards pass
  → it pastes → **DUPLICATE** (Reproduction A);
- keyboard flush sees a session mismatch / no-fresh payload (clear/consume won the
  race) → it skips → single insert, correct (Reproduction B).

That intermittency is exactly why it's a "weird" bug that doesn't always repro.
The in-app reject-guards (`documentIdentifier` / nil-context) do NOT save us here —
in Jot's own field the identity is stable and the proxy is connected, so when the
session/freshness check passes, the insert goes through.

**Fix must close the race deterministically** (see Fix direction below) — not rely on
the keyboard happening to lose. Options: clear/consume the pending paste session
BEFORE publishing on the transient path; or don't publish to the clipboard handoff at
all on the transient path (in-process insert is the sole deliverer in-app); or tag
the publish as in-process-handled so the keyboard flush no-ops. Verify in-app paste
still lands EXACTLY once (build 99's in-process insert fixed a *dropped* paste).

---

> _Below: the ORIGINAL hypothesis write-up — now CONFIRMED by Reproduction A above. Kept for the code-path detail._

## Symptom (user-reported, on device)

Dictating **inside Jot's own fields** — the transcript Edit pane, or any in-app
text field (Feedback, etc.) — and then stopping causes the dictated text to be
**inserted twice**. Say "can you hear me", stop → the field shows it duplicated.
The user reports this happens **only** in-app ("only in the transcript pane or
inside the app"), not when dictating into another host app.

That "only in-app" scoping is the key tell: it points squarely at the **transient
(in-Jot) stop path**, which is the one path that inserts in-process.

## Root-cause hypothesis (code-grounded — verify before fixing)

The transient path inserts **twice** because the keyboard's cross-process
auto-paste flush races the in-process insert and wins, in-app:

1. `DictationPipeline.completeEndOfRecording` (transient) publishes to the
   clipboard handoff **and flips the pipeline phase** —
   `ClipboardHandoff.publish(...)` + `recording.publishPipelinePhase(.publishing)`
   at `Jot/App/Intents/DictationPipeline.swift:343-352`, and posts
   `transcriptReady` at `:362` — **all BEFORE** the transient in-process insert +
   clear at `:377-391`.
2. The phase flip posts `pipelinePhaseChanged`. In the **keyboard process**, the
   `pipelinePhaseObserver` fires `refreshPipelinePhase()`, whose tail calls
   `flushPendingAutoPasteIfPossible()`
   (`Jot/Keyboard/JotKeyboardViewController.swift:1352`). The pending paste
   session still exists (not cleared yet) and the clipboard payload's `sessionID`
   matches → it enters the happy path.
3. **The reject-guards don't trip in-app.** `flushPendingAutoPasteIfPossible`
   (`:1044-1126`) only skips when `documentIdentifier` changed since the tap
   (`:1056-1073`) or the proxy context is nil. Inside Jot's own focused field
   (transcript Edit / Feedback) the field identity is **stable** across the
   recording-state flip and the proxy **is** connected, so neither guard fires →
   `insertTrackedText(payload.text)` at `:1126` **succeeds** = **insert #1**.
4. Back in the main app, `FocusedFieldInsert.insertIntoFocusedField(publishedText)`
   at `DictationPipeline.swift:380` lands **insert #2**.
5. `ClipboardHandoff.clearPendingPasteSession()` at `:381` runs **too late** — the
   keyboard already flushed in step 3. The clear is in the main-app process; the
   keyboard flush is a separate process reacting to a notification posted in
   step 1, so the publish-first ordering opens the race window.

The comment at `DictationPipeline.swift:364-376` assumes the keyboard's
same-host guards reject the proxy flush so "the text lands exactly once." That
assumption only holds when Jot's SwiftUI re-render **changes the field's
documentIdentifier**. In the transcript Edit / Feedback field where the identity
is stable, the guard does NOT reject → the keyboard flush + the in-process insert
**both** land → duplicate. This is consistent with the user seeing it ONLY in-app.

## How to CONFIRM (diagnostic-first — do this before any fix)

Reproduce in the transcript Edit field, then check `DiagnosticsLog` for the SAME
`sessionID` having BOTH:
- a **keyboard** `.pasteSuccess` "Inserted transcript into host"
  (`JotKeyboardViewController.swift:1140-1153`), AND
- a **main-app** `.publishCompleted` "In-Jot transient paste (in-process insert)"
  with `inserted=true` (`DictationPipeline.swift:382-390`).

Both firing for one session = double insert confirmed. (If instead you see the
keyboard fire `.pasteSuccess` twice, or the in-process insert fire twice, the
cause is different — re-diagnose.)

## Fix direction (NOT decided — options to weigh at implementation)

The race is "clear happens after the publish that can trigger the keyboard
flush." Candidate directions (pick after confirming):
- **Suppress the keyboard flush before publishing** in the transient path: clear
  / mark the pending paste session consumed **before** `ClipboardHandoff.publish`
  + the phase flip, so the keyboard's flush finds no pending session. Then do the
  in-process insert. (Re-orders steps so there's no window.)
- **Don't publish to the clipboard handoff at all on the transient path** — the
  in-process insert is the sole delivery for in-app; only the non-transient path
  needs the keyboard proxy flush. (Removes the second inserter entirely.)
- **Tag the publish as in-process-handled** so the keyboard flush no-ops on it.

Each needs a check that the non-transient (other-app) path and the cold-start /
warm-hold / Action-Button paths are untouched, and that in-app paste still lands
exactly once (not zero — don't over-correct into a dropped paste).

## Scope guardrails

- Touch ONLY the transient / in-Jot stop path. Do not change other-app paste,
  hero save, cold-start, warm-hold, or `DictateIntent`.
- The whole point of the in-process insert (build 99) was to fix in-app paste
  being *dropped*. The fix must keep it landing **exactly once** — verify both
  the duplicate AND the original drop are gone.
- Related context: build 99 commit "in-app dictation paste + warm-stop fix"
  introduced `FocusedFieldInsert` and the clear-pending logic this bug lives in.

---

## Fix plan (DECIDED 2026-06-03)

> Approach DECIDED by CEO. This section is the precise, grounded write-up — not a
> re-litigation. Note: the original "Fix direction" above (one of three options:
> suppress-before-publish / don't-publish-transient / tag-in-process-handled) is
> SUPERSEDED. The decided fix takes a fourth, simpler line: **delete BOTH
> deliverers' special-casing and keep only the keyboard flush — for every app,
> including in-app.**

### Problem

In-app dictation can paste the dictated text **twice** (transcript Edit pane,
Feedback, Wizard W5). Root cause is CONFIRMED on device (see "✅ Confirmation"
above, ~85% confidence): on a transient (in-Jot) stop the keyboard's
cross-process `flushPendingAutoPasteIfPossible()` and the main-app in-process
`FocusedFieldInsert.insertIntoFocusedField(...)` **both** land for the same
session — an intermittent race whose outcome depends on whether the keyboard's
same-input guard happens to reject. Two deliverers on one path is the disease;
the band-aid clear at `DictationPipeline.swift:381` only sometimes wins the race.

### Decided approach (the principle + the 2 deletions)

**Principle (CEO / `Jot/CLAUDE.md` "Jot's fields are just fields"):** iOS only
instantiates the keyboard extension when a text input is focused. So if the
keyboard is up at paste time, there IS an input — just paste into it, wherever
the cursor is when you stop. **One paste path everywhere — the keyboard's
`textDocumentProxy` flush. No in-app side door, no same-input guard.**

Two concrete deletions collapse to that single path:

1. **Delete the over-strict same-input guard** in
   `flushPendingAutoPasteIfPossible()` so the keyboard pastes wherever the input
   is, in EVERY app (the CEO explicitly chose the "pure" version, not an in-app
   special-case).
2. **Delete the in-process side door** (`FocusedFieldInsert` call + the
   now-pointless `clearPendingPasteSession()`) on the transient path, so the
   keyboard flush is the SOLE deliverer in-app exactly as in other apps.

### Exact change points

**Change 1 — keyboard guard removal.**
File: `Jot/Keyboard/JotKeyboardViewController.swift`.

- **Delete the `documentIdentifier`-changed rejection block,
  `:1056-1073`** — the `if let claimedDoc = session.hostDocumentIdentifier { … if
  nowDoc != claimedDoc { … clearPendingPasteSession(); renderRootView(); return } }`
  branch (logs `.pasteSkipDocumentMismatch`).
- **Delete its `keyboardType`-changed fallback rejection,
  `:1074-1091`** — the `else if let claimedKbRaw = session.hostKeyboardTypeRaw …
  nowKb != claimedKbRaw { … clearPendingPasteSession(); renderRootView(); return }`
  branch (logs `.pasteSkipKeyboardTypeMismatch`).
- **Before/after intent:** today the happy path (payload `sessionID` matches
  pending, `:1050`) is gated by these two "did the focused input change since the
  Stop tap?" guards before reaching `insertTrackedText(payload.text)` (`:1126`).
  After: the matched-session happy path falls straight through to the empty-text
  diagnostic (`:1098-1109`, KEEP) and then the insert. No same-input gate.
- **Snapshot disposition.** `beginPendingPasteSession()` (`:908-914`, called from
  the `.stop` case at `:1732`) snapshots `hostKeyboardTypeRaw` /
  `hostDocumentIdentifier` into the `PendingPasteSession`. With both guards gone
  those two fields are **read nowhere** for gating. Recommendation: **leave the
  snapshot writes in place** (do not change `PendingPasteSession`'s shape or
  `beginPendingPasteSession`) — they are harmless, cost nothing, and remain
  useful as diagnostic breadcrumbs if we ever need to reason about "what input
  was focused at Stop." Removing the fields would be a gratuitous type change for
  no behavioral gain. (If a later cleanup pass wants them gone, that is a
  separate, optional refactor — out of scope for this fix.)

**Change 2 — in-process side door removal.**
File: `Jot/App/Intents/DictationPipeline.swift`, inside the `if transient { … }`
block at `:377-391` (within `completeEndOfRecording`, the fresh-publish branch).

- **Delete the `FocusedFieldInsert.insertIntoFocusedField(publishedText)` call,
  `:380`.**
- **Delete the `ClipboardHandoff.clearPendingPasteSession()` call, `:381`** — it
  exists ONLY to suppress the keyboard flush (the comment at `:369-374` says so);
  with the flush now the intended sole deliverer on the transient path too, this
  clear would actively HARM us (it would race-clear the pending session the
  keyboard needs to flush).
- **Delete or neutralize the trailing diagnostic** `.publishCompleted` "In-Jot
  transient paste (in-process insert)" at `:382-390` — it logs `inserted` from
  the now-deleted call. Remove the whole record (the keyboard's own
  `.pasteSuccess` at `:1140-1153` becomes the single source of truth for "did the
  in-app paste land"). The in-app paste is now driven exactly by the publish +
  phase flip at `:346-362` waking the keyboard's `pipelinePhaseObserver` →
  `refreshPipelinePhase()` (`:1336`) → `flushPendingAutoPasteIfPossible()`
  (`:1352`), identical to the other-app path.
- **Before/after intent:** today the transient branch publishes, then inserts
  in-process, then clears to suppress the keyboard. After: the transient branch
  publishes and does NOTHING ELSE deliverer-wise — it still updates follow-up
  discovery state (`:393-396`, KEEP) and still skips the ledger append (`:408`,
  KEEP). The whole `if transient { … }` insert/clear/log block collapses away.

**File deletion (staged — see rollout).** With `:380` gone, the ONLY caller of
`FocusedFieldInsert.insertIntoFocusedField(...)` disappears. The file
`Jot/App/Recording/FocusedFieldInsert.swift` (79 lines, `enum FocusedFieldInsert`,
sole consumer was `:380` — confirmed by grep: only two hits, the definition and
the call) becomes dead code. **Plan its deletion AFTER the on-device gate passes**
(below), not before — keep it in-tree as a one-line revert if the gate fails.
Removing the file requires a `xcodegen` from `Jot/` so the project drops it.

### What stays untouched

These are explicitly NOT modified by this fix:

- **The four `transient` no-save semantics** (all independent of the insert, all
  preserved):
  1. skip `DictationStats.record` — `DictationPipeline.swift:174` (`if !transient`).
  2. skip `TranscriptStore.append` on the fresh branch — `:408` (`if !transient`).
  3. skip append on the command-cancelled branch — `:467` (`if !transient`).
  4. skip `markSuperseded` + append on the command branch — `:536-538`
     (`if !transient`).
  "Stop inside a Jot field → no saved Transcript" is a hard contract
  (`Jot/CLAUDE.md`). None of these read the deleted insert; deleting the insert
  does not touch them.
- **The non-transient (other-app) publish path, hero save, cold-start,
  warm-hold, `DictateIntent`** — unchanged in mechanism. They already rely on the
  keyboard flush as the deliverer. The ONLY behavioral change reaching them is
  the guard removal in Change 1 (intended — see Accepted side effect).
- **`PendingPasteSession` shape / `beginPendingPasteSession()` / launch-deadline
  machinery** (`:935-1019`) — untouched (per snapshot disposition above).
- **Empty-text diagnostic + `markConsumed` + `clearPendingPasteSession` cleanup
  inside the keyboard happy path** (`:1098-1109`, `:1159-1165`) — untouched;
  these run AFTER the (now-ungated) match check.

### Ask isolation note

Ask is unaffected. Ask drives dictation through its **own**
`InlineDictationSession`, instantiated only at `Jot/App/Ask/AskView.swift:605`
(`let session = InlineDictationSession(recordingService:…, transcribe:…)`). It
never calls `DictationPipeline.completeEndOfRecording`, never touches
`FocusedFieldInsert`, and never arms a keyboard `PendingPasteSession`. Per
`Jot/CLAUDE.md`, Ask is the SOLE intentional surviving user of
`InlineDictationSession`. Both deletions in this fix are on paths Ask does not
traverse, so Ask's in-place partial-streaming into its question field is
untouched.

### Staged rollout (with the verify-once gate)

1. **Stage 1 — make both code deletions, keep the file.** Apply Change 1 (guard
   removal) and Change 2 (side-door removal: delete `:380`, `:381`, and the
   `:382-390` diagnostic). **Leave `FocusedFieldInsert.swift` in the repo for
   now** (dead but compiled). Build locally (`Cmd+R` in Xcode is the preferred
   loop per `Jot/CLAUDE.md`; `xcodebuild` only proves it compiles).
2. **Stage 2 — the ONE safety gate: on-device single-insert verification.** This
   is a BLOCKING gate. Install on the iPhone and reproduce a stop in each of the
   **three** in-app surfaces:
   - transcript **Edit** pane,
   - **Feedback** field,
   - **Wizard W5** keyboard test.
   For each, inspect `DiagnosticsLog` (Help → Diagnostics) and require, for the
   stop's `sessionID`:
   - **exactly one** keyboard `.pasteSuccess` "Inserted transcript into host"
     (`:1140-1153`) — not zero, not two;
   - **NO** `.pasteSkipDocumentMismatch` and **NO** nil-context drop (the
     `contextGrew <= 0` / `proxyHadContextBefore=false` signature in that same
     `.pasteSuccess` record);
   - **NO** `[main-app] … In-Jot transient paste (in-process insert)` record
     (proves the side door is gone).
   **Rationale this should suffice:** the duplicate reproductions above prove the
   keyboard flush DOES successfully insert in-app when the guard passes — so
   nil-context is NOT the in-app blocker in those runs; the *drop* (Reproduction
   B / the original build-99 bug) was the GUARD rejecting on Jot's churned
   `documentIdentifier`, not the proxy being disconnected. Removing the guard
   should therefore land exactly once. **If instead the paste DROPS (nil-context
   after all — zero `.pasteSuccess`, field stays empty), STOP and re-plan** — do
   not ship a dropped paste; the side door (or an equivalent in-process insert)
   would have to be reinstated, which means this whole approach is wrong and we
   fall back to one of the superseded options.
   **Per project memory (intermittent-bug-needs-multiple-repros): run each
   surface MULTIPLE times** — a single clean run is one run of a race, not proof.
   Aim for ≥3 stops per surface with consistent single-insert.
3. **Stage 3 — finalize the file deletion.** ONLY after Stage 2 is green across
   all three surfaces (multiple repros each): delete
   `Jot/App/Recording/FocusedFieldInsert.swift`, run `xcodegen` from `Jot/`,
   rebuild. (Optional follow-up, separate change: strip the now-unread
   `hostKeyboardTypeRaw`/`hostDocumentIdentifier` snapshot fields — not part of
   this fix.)

### Accepted side effect (CEO accepted knowingly — not an open question)

Removing the guard for ALL apps means: in the window between Stop and the
transcript being ready (and within the keyboard's
`ClipboardHandoff.freshnessWindow`, ~30s), if the user moves the cursor to a
different field or app, the text lands **wherever the cursor is THEN**, not where
it was at Stop. **In-app this is a non-issue** (you don't jump fields inside
Jot's own Edit pane mid-transcribe). The real exposure is the other-app "I moved
while it was thinking" case. The CEO chose this deliberately as the simpler, more
intuitive behavior — "paste where I am when I stop." The ~30s freshness window is
**left AS-IS** (no change). Documented here as an accepted trade, not a TODO.

### Schema impact

**None.** This fix deletes a guard, a call, a diagnostic, and (staged) a UIKit
helper file. It adds/removes/renames **no `@Model` fields and no `@Model`
entities**; it does not touch `JotSchemaVN` / `JotMigrationPlan`. The optional
removal of `PendingPasteSession.hostKeyboardTypeRaw`/`hostDocumentIdentifier` is
an App-Group JSON DTO, not a SwiftData `@Model`, and is out of scope regardless.
Stated explicitly per `Jot/CLAUDE.md` §"Schema discipline" item 7.

### Test plan (on-device matrix)

Per project memory, intermittent paste bugs need **multiple repros** per case —
treat one clean run as anecdote, not proof. Aim ≥3 repros per row.

| # | Case | Surface | Expected |
|---|------|---------|----------|
| 1 | In-app paste lands **exactly once** | transcript Edit | single keyboard `.pasteSuccess`; no dup; no drop; no `In-Jot transient paste` log |
| 2 | In-app paste lands exactly once | Feedback field | same as #1 |
| 3 | In-app paste lands exactly once | Wizard W5 keyboard test | same as #1; recording still force-stopped on wizard dismiss (`closeAndComplete()`) |
| 4 | Other-app paste still lands once **and saves** | Notes/Slack (stay in field) | single paste at cursor + a saved `Transcript` (non-transient append at `:408` fires) |
| 5 | Hero save | hero stop | unchanged — transcript saved, paste behavior as before |
| 6 | Cold-start dictation | `jot://dictate` cold | unchanged — saves + pastes |
| 7 | Warm-hold / warm-resume | warm path | unchanged — saves + pastes |
| 8 | `DictateIntent` (Action Button) | shortcut/Action Button | unchanged — saves + pastes |
| 9 | "Stop then wait" normal case | any in-app field, pause before stop | still pastes once (the gate's core no-regression check) |
| 10 | "No-save inside Jot" contract | stop in transcript Edit / Feedback / settings / wizard | **no** new saved `Transcript` (all four `if !transient` skips hold) |
| 11 | Guard-removal other-app behavior is intentional | other app, **move cursor to a different field within ~30s** | text lands at the NEW cursor (the accepted side effect — confirm it's the chosen behavior, not a regression) |
| 12 | Ask unaffected | Ask voice mic | partials still stream into the Ask question field; no `.pasteSuccess`, no transient log |

All "unchanged" rows (5–8, 12) are regression guards on paths this fix does not
mechanically alter; they exist to catch an unintended blast radius from the guard
removal, not because the mechanism changed.

### Risks

- **R1 — in-app drop returns (nil-context).** If, contrary to the
  Reproduction-A evidence, the in-app insert was succeeding via the in-process
  side door and the keyboard flush genuinely hits nil-context in-app on some
  runs, guard removal yields a DROPPED paste, not a single one. **Mitigation:**
  the Stage-2 gate is designed precisely to catch this; multiple repros per
  surface; STOP-and-re-plan if any drop is seen. (Low probability — the dup
  repros show the flush inserting in-app — but it is THE risk.)
- **R2 — other-app "moved-while-thinking" surprise.** A user who moves fields
  within the ~30s window now gets the paste at the new cursor. Accepted by CEO
  (see Accepted side effect); listed here only for completeness, not as a blocker.
- **R3 — stale `FocusedFieldInsert.swift` left compiled if Stage 3 is skipped.**
  Dead but harmless; ensure the cleanup commit actually lands so we don't accrue
  orphan code. Low.
- **R4 — diagnostic blind spot.** Deleting the `In-Jot transient paste` log
  means future in-app paste debugging relies solely on the keyboard
  `.pasteSuccess` record. Acceptable — that record carries `contextGrew` /
  `proxyHadContextBefore`, which are richer drop-detectors than the boolean
  `inserted` we're removing.

### Open questions

- **OQ1 — keep vs. strip the unused snapshot fields?** This plan recommends
  KEEPING `hostKeyboardTypeRaw`/`hostDocumentIdentifier` (cheap diagnostics) and
  treating their removal as an optional later refactor. Confirm the CEO is fine
  carrying two now-unread fields, or wants them stripped in the same change
  (would touch `PendingPasteSession` + `beginPendingPasteSession()` `:908-914`).
  Not a blocker either way.

(No other genuine open questions — the approach, the side effect, and the
freshness window are all DECIDED.)
