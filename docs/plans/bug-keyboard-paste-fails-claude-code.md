# Bug: keyboard auto-paste reports success but text never appears (Claude Code / web fields)

**Status:** Diagnosed from a 3-session on-device log, NOT fixed. Diagnostic-first.
**Confidence in root-cause class: ~85%.** One on-device probe (below) settles the last 15%.
**Size: M** (probe + the honest-success change is S; the full landed-verification path is M).

> Protocol note: when this is picked up, add the dual entry to
> [`known-bugs-and-plans.md`](../../Jot/known-bugs-and-plans.md) — a detailed
> entry under "Known Bugs (Unresolved)" AND a one-line index entry under the
> plans index — per the standing registry discipline. A `docs/plans/` doc alone
> is not discoverable.

This is the **third chapter** of the keyboard host-paste saga and is a *direct
continuation* of [bug-slack-silent-paste.md](bug-slack-silent-paste.md) (Update
#9 / build 108 proxy re-sync) and [bug-rare-empty-field-first-paste-miss.md](bug-rare-empty-field-first-paste-miss.md).
Read both first — the windowing/`contextGrew` lessons there are load-bearing here.

---

## 1. The symptom and the log (recap)

Owner dictates from the Jot keyboard into the **Claude Code chat field** (a
web/custom compose field, NOT a native `UITextView`) and stops. **Sometimes the
result never pastes.** "Doesn't matter if there's text on screen or not" — but
the captured log shows the failing run was into a field that already held text.

Three keyboard recordings were logged. Owner reports **#1 and #2 pasted, #3 did
NOT**, yet **all three logged `pasteSuccess`.** The differentiator is the host
field's pre-existing content length:

| Session | kbd session | published chars | `beforeLen` | `afterLen` | `delta` | `endsWith` | Owner saw paste? |
|---|---|---|---|---|---|---|---|
| 1 | D6AB2C50 | 50 | 0 | 50 | 50 | true | ✅ yes |
| 2 | 84BFD540 | 29 | 0 | 29 | 29 | true | ✅ yes |
| 3 | F966EBA5 | 57 | **906** | 963 | 57 | true | ❌ **NO** |

The single clue that matters: **#1 and #2 pasted into an EMPTY field
(`beforeLen=0`); #3 pasted into a NON-empty field (`beforeLen=906`) and silently
failed** — while logging an identical-shape "success" (`delta == chars`,
`endsWith == true`).

---

## 2. Reconstruction of the 3 sessions, mapped to code

All paste decisions happen in
`JotKeyboardViewController.flushPendingAutoPasteIfPossible()`
(`Jot/Keyboard/JotKeyboardViewController.swift:1128`). The cross-process
handshake is:

1. **Stop** → keyboard `beginPendingPasteSession()` writes a `PendingPasteSession`
   to the App Group BEFORE posting the stop notification
   (`:1998`, logs `sessionStopRequested`).
2. **Main app** resolves the publish session ID = the keyboard's pending session
   id (`JotApp.swift:1191-1194`, logs `publishResolved resolvedSessionID=…`),
   transcribes, then `ClipboardHandoff.publish(transcript:sessionID:)` writes the
   App Group `lastDictation` payload tagged with that id
   (`DictationPipeline.swift:365`, logs `publishCompleted`). `publish` also sets
   `UIPasteboard.general.string` (`ClipboardHandoff.swift:53`) but the keyboard
   **inserts from `payload.text`, never the clipboard**.
3. **Keyboard** wakes on the pipeline-phase notification, runs the flush, matches
   `payload.sessionID == pending.id` (`:1150`), re-syncs the proxy
   (`adjustTextPosition(0)` + 12 ms run-loop hop, `:1202-1206` — the build-108
   fix), inserts, reads back the proxy to decide `landed`, logs, and on `landed`
   consumes the payload + clears pending (`:1280-1281`).

### Session 1 (preview sid=05051457, kbd D6AB2C50)
- `preview PUBLISH chars=4` = a **streaming preview tick**
  (`StreamingPartial.update` → `publishProjection`, `StreamingPartial.swift:122`).
  This is the live-text projection, NOT a paste payload. It is unrelated to the
  paste handshake and carries the *streaming* session token (05051457), not the
  pending paste session.
- `sessionStopRequested {D6AB2C50}` = stop; pending session written (`:1998`).
- `publishResolved resolvedSessionID=D6AB2C50` = main app adopted the keyboard's
  pending id for the publish (`JotApp.swift:1198`).
- **3× `pasteSkipSessionMismatch {payloadSessionID=62BE8306, pendingSessionID=D6AB2C50}`**
  (`:1306`). These are **benign**. 62BE8306 is a *stale payload from a prior
  session* still sitting in `lastDictation` (it was never consumed/expired). The
  flush ran 3× (on intermediate phase notifications) BEFORE this session's
  publish landed; each time it found the old payload, saw the id didn't match the
  current pending, and **correctly skipped without pasting**. This is the
  designed guard doing its job — it is NOT the bug. (It does reveal a *hygiene*
  issue — a stale payload lingering — discussed in §4, alternative C.)
- `publishCompleted chars=50 sessionID=D6AB2C50` = this session's real payload
  finally written, overwriting the stale 62BE8306 blob.
- `pasteSuccess {beforeLen=0, afterLen=50, delta=50, endsWith=true}` = flush ran
  again, payload id now matches, insert ran into an **empty** field, read-back
  saw 50 chars of pre-caret context ending with the inserted text → "landed".
  **Owner confirms this one pasted.** Here the log is honest.

### Session 2 (sid=75975C08, kbd 84BFD540)
- `PUBLISH chars=15` (preview tick), `stop {84BFD540}`, `publishResolved 84BFD540`.
- **2× `pasteSkipNoPayload {84BFD540}`** (`:1299`). Also benign: the flush ran
  twice before publish; this time `lastDictation` was empty (the prior session's
  payload had been consumed), so `ClipboardHandoff.readFresh()` returned nil →
  "no payload yet, wait." Distinct from session 1's "mismatch" only because the
  slot was empty rather than holding a stale blob.
- vocab rescore → `publishCompleted chars=29 84BFD540` (the published text grew
  15→29 because the **final batch transcript + vocabulary rescore** replaces the
  preview; expected).
- `pasteSuccess {beforeLen=0, afterLen=29, delta=29, endsWith=true}` — empty
  field again, honest success. **Owner confirms pasted.**

### Session 3 (sid=412BC9F4, kbd F966EBA5) — THE FAILURE
- `PUBLISH chars=56` (preview), `stop {F966EBA5}`, `publishResolved F966EBA5`,
  `2× pasteSkipNoPayload {F966EBA5}` (benign, pre-publish).
- `publishCompleted chars=57 F966EBA5` — real payload, 57 chars.
- **`pasteSuccess {beforeLen=906, afterLen=963, delta=57, endsWith=true}`** — the
  flush matched, re-synced, inserted, and the read-back of
  `documentContextBeforeInput` returned a 963-char string that ends with the 57
  inserted chars. `landed = true` → **payload consumed, pending cleared.**
  **Owner saw NO text appear in Claude Code.**

**The handshake (session-ID coordination) worked perfectly in all three.** Every
skip was a benign pre-publish skip; the right payload matched the right pending
in every case. The bug is NOT in the session-ID layer. It is in the
**"did the insert actually land?" oracle** for session 3.

---

## 3. Root-cause diagnosis

### 3.1 The mechanism (confidence ~85%)

`insertTrackedText` calls `textDocumentProxy.insertText(_:)` (`:680`), a **`void`
call that returns nothing** whether the host accepted the text or not (this exact
trap is documented in bug-slack-silent-paste.md). The keyboard's only oracle for
"did it land" is to read `documentContextBeforeInput` again afterward
(`:1221-1239`):

```
beforeCtx = proxy.documentContextBeforeInput   // pre-caret context BEFORE insert
insertTrackedText(pasteText)                    // textDocumentProxy.insertText(…)
afterCtx  = proxy.documentContextBeforeInput    // pre-caret context AFTER insert
landed    = (beforeCtx != nil) || (afterCtx != nil)
delta     = afterCtx.count - beforeCtx.count
endsWith  = afterCtx.hasSuffix(pasteText)
```

The flaw: **`documentContextBeforeInput` is the proxy's own cached view of the
text-around-the-caret. `insertText` updates that cache locally and synchronously
— in the keyboard's process — *before* (and independently of) the host's live
document model committing the change.** In a native `UITextView` (Messages) the
proxy cache and the live document are the same object, so the cache reflecting
the insert IS the text landing. In a **web/custom field (Claude Code = WKWebView,
Slack = React-Native), the proxy is a bridge to a remote text view**; the build-
108 stale-connection problem means `insertText` can update the bridge's cached
context buffer while the **re-mounted live web view never receives the
`UITextInput` callback** — so the read-back shows `delta=57 / endsWith=true`
(the cache grew) while the screen shows nothing.

This makes `pasteSuccess` a **false positive**: it confirms the *proxy's local
buffer* changed, not that the *host field* changed. The `endsWith` "firmer
signal" the [PASTE-DIAG] comment hoped for is **not** firmer against this failure
mode — both `delta` and `endsWith` are computed from the same possibly-stale
cache and both lie together.

### 3.2 Why empty (#1/#2) works but 906-char (#3) fails — the key clue

This is the crux the owner flagged, and it is the strongest evidence for the
mechanism above (and against the alternatives).

**Hypothesis 3.2a (primary, ~60% within the 85%): the build-108 re-sync only
reconnects an empty/short field reliably.** The re-sync is a single
`adjustTextPosition(byCharacterOffset: 0)` + one 12 ms run-loop hop. On an empty
web field, the re-mounted view is cheap and the bridge reconnects within that
window, so the insert lands AND the cache is real. On a field already holding 906
chars, the re-mounted WKWebView has to rehydrate a large document; the input
connection is still mid-rehydration at +12 ms, so `insertText` writes only into
the proxy's cache (which it can do locally) but the live view, still
reconstructing, drops the `insertText` callback. Net: empty → real landing;
populated → cache-only false success. The 12 ms hop is a fixed constant tuned on
small fields; it does not scale with host re-mount cost.

**Hypothesis 3.2b (secondary): `beforeLen=906` proves the proxy was pointed at a
STALE snapshot of the field, not the live one.** If the live Claude Code field
truly had 906 chars of pre-caret context AND the insert truly landed, the text
would be visible. Since it isn't, the 906 is most likely the proxy's cached
context from *before* the re-mount (a detached/stale connection that still
answers reads), and `insertText` appended to that detached buffer. The empty-
field cases have `beforeLen=0` precisely because there was nothing to go stale —
a fresh field and a stale-but-empty field are indistinguishable at 0, and the
re-sync happens to reconnect a trivially-empty field. (This dovetails with the
empty-field note in bug-rare-empty-field-first-paste-miss.md: `nil`/empty context
hides the disconnected-vs-live ambiguity.)

Both sub-hypotheses converge on the same fix space: **the proxy read-back cannot
be trusted as the landed oracle in web/custom fields, and the bug surfaces only
when the field is non-trivial enough that the re-sync hasn't actually
reconnected the live view by insert time.** We do not need to fully disambiguate
3.2a vs 3.2b to act — both say "stop trusting the cache; verify against the live
field or make success honest."

### 3.3 Confidence and the gap

- **That `pasteSuccess` is a false positive in web fields: ~95%.** Directly
  supported by the log (success logged, owner saw nothing) and by the documented
  `void`-insert + proxy-cache architecture.
- **That the EMPTY-vs-906 split is the build-108 re-sync failing to reconnect a
  heavy re-mounted field in time: ~70%.** Plausible and fits the data, but the
  log does not *prove* the live view stayed disconnected vs. accepted-then-
  rejected. This is the 15% gap.
- **Net root-cause-class confidence: ~85%.**

**Probe that settles the gap (see §5).** We cannot pick between "re-sync window
too short" and "this host can never reconnect a populated field via the proxy"
from the current log alone.

---

## 4. Alternatives considered and ranked

**A. False-success via proxy cache desync (PRIMARY — §3).** Ranked #1. Explains
the log, the empty-vs-populated split, and is consistent with the entire
build-104→108 history. ~85%.

**B. Session-ID / payload coordination race.** Ranked LOW (~5%). Investigated
fully (§2): every `pasteSkipSessionMismatch` / `pasteSkipNoPayload` in the log is
a *benign pre-publish* skip; the correct payload matched the correct pending in
all three sessions, including the failing one. **One real risk worth a guard
even though it's not THIS bug:** a *stale* payload (session 1's 62BE8306) sat in
`lastDictation` unconsumed across sessions. The session-id match prevents it
being mis-pasted, BUT if a new pending session were ever (re)assigned a UUID
colliding with a stale payload's id, or if `markConsumed()` failed to run after a
landed insert, a stale payload could in principle paste. Not observed here;
note for hardening (alternative C). The "keyboard tears down before the payload
arrives" race was the *previous* bug (builds 103-106) and is already mitigated by
`armLaunchDeadline` / `rearmLaunchDeadlineIfPending` / the TerminalSessionLog
backstop — not implicated here (the payload DID arrive and DID match).

**C. Stale-payload hygiene.** Ranked as a *secondary hardening item*, not the
root cause. `lastDictation` is only cleared by `markConsumed()` on a *landed*
paste. A paste that the keyboard believes failed (kept-pending) — or a session
that never reaches the keyboard — leaves the payload to be skipped repeatedly
until the 30 s freshness window expires (`ClipboardHandoff.readFresh` age gate,
`:101`). Benign today but it is the thing that made session 1 log three
mismatches. Worth a tidy-up alongside the real fix.

**D. Host genuinely accepted then auto-reverted (draft autosave / re-render eats
the insert AFTER it landed).** Ranked LOW-MED (~10%). Slack's draft autosave was
floated in bug-slack-silent-paste.md (Path D). Possible for Claude Code's React
field too: the insert lands, then a React re-render from controlled-input state
overwrites the DOM back to its model (which never saw the insert). This would
*also* show `delta>0/endsWith=true` transiently. Distinguishable from A only by a
**deferred** read-back (read the proxy again 200-400 ms later — see §5/§6). If D
is true, no insert-timing fix helps and the only remedy is clipboard-fallback +
banner. Worth keeping live until the probe rules it in or out.

---

## 5. On-device probe to reach >90% confidence (do this BEFORE shipping a fix)

The current [PASTE-DIAG] instrumentation (delta/endsWith) **cannot** distinguish
"cache lied" from "landed then reverted." Add a **deferred read-back** probe (log
only, no behavior change), then reproduce in Claude Code with a populated field:

Pseudo-code, inside the `landed`-success branch, after the existing log:

```
let immediateAfter = afterCtx                       // already have this
DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
    guard let self else { return }
    let settledCtx   = self.textDocumentProxy.documentContextBeforeInput
    let settledLen   = settledCtx?.count ?? -1
    let stillEndsWith = (settledCtx ?? "").hasSuffix(pasteText)
    // Also probe a SECOND independent signal:
    let hasTextNow   = self.textDocumentProxy.hasText
    DiagnosticsLog.record(source: "keyboard", category: .pasteVerifyDeferred,
        message: "deferred read-back",
        metadata: ["immediateLen":"\(immediateAfter?.count ?? -1)",
                   "settledLen":"\(settledLen)",
                   "stillEndsWith":"\(stillEndsWith)",
                   "hasText":"\(hasTextNow)"])
}
```

Interpretation matrix on a **failing** Claude Code repro (populated field):

| immediate `endsWith` | settled `endsWith` | meaning | which alt |
|---|---|---|---|
| true | **false** | landed in cache, host re-render reverted it | **D** (autosave/controlled-input) |
| true | **true but invisible** | cache never reflected the live view at all | **A** (stale/detached proxy) |
| true | settledLen drops back to ~906 | host model never took the 57 chars | **A** |

If A: the fix is insert-timing / verification (§6 options 1-2). If D: only
clipboard-fallback + banner helps (§6 option 3). **Do not ship a behavioral fix
before this probe returns on a confirmed failing run** — the codebase has burned
people four times here (builds 103/104/105/106 each "fixed" a wrong theory).

Also capture, on the same repro: does it fail **every** time into a populated
Claude Code field, or intermittently? Deterministic-on-populated strongly favors
A-3.2a (fixed 12 ms window always too short for a heavy re-mount); intermittent
favors a race (A-3.2b or D).

---

## 6. Fix PLAN (options + tradeoffs — pick after the probe)

### Option 1 — Make `pasteSuccess` honest (REQUIRED regardless of which alt wins)

The non-negotiable first move: a `pasteSuccess` that can false-positive is the
reason this bug shipped four times. Whatever the deeper fix, the success oracle
must verify against a signal the proxy cache cannot fake on its own.

- Gate the success classification on a **deferred** re-read (the §5 probe,
  promoted from log-only to decision): only log `pasteSuccess` + consume the
  payload if the *settled* (≥300 ms) read still shows `endsWith == true` AND
  `hasText == true`. If the settled read disagrees, reclassify as
  `pasteSkipProxyDisconnected` (or a new `pasteRevertedAfterLanding`) and **keep
  the payload pending** so a later flush / the launch-deadline backstop can retry.
- Tradeoff: adds ~300 ms before the payload is consumed → the just-now recents
  marker and correction-nudge fire ~300 ms later. Acceptable. Must guard against
  a second flush stacking in that window (extend the existing
  `isAutoPasteInsertInFlight` guard, `:1199`, to cover the deferred verify too).
- Risk: the deferred read is ALSO a proxy-cache read, so against pure
  alternative A it could *still* lie. Mitigate by pairing it with `hasText` (a
  separate UITextInput API — per bug-slack-silent-paste.md Path D) and, if the
  probe shows the cache is wholly unreliable for this host, by the clipboard
  fallback (option 3) rather than trusting any read.

### Option 2 — Stronger / adaptive re-sync (if probe says A-3.2a: re-sync too short)

- Replace the fixed single 12 ms hop with a **bounded reconnect-poll**: after
  `adjustTextPosition(0)`, poll `documentContextBeforeInput`/`hasText` every
  ~30 ms up to ~300 ms until the proxy reports a *stable* context (two equal
  consecutive reads), THEN insert. This lets a heavy re-mounted field finish
  rehydrating before the write, scaling with host cost instead of a constant.
- Tradeoff: up to ~300 ms added latency on the slow-host path (fast hosts settle
  on the first poll → no regression). More complex than a single hop; must not
  reintroduce the multi-insert double-paste (single insert after the poll
  settles; keep the in-flight guard).
- This is the "do it right at insert time" path. It does NOT help if the host
  reverts AFTER a good insert (alternative D) — option 3 covers that.

### Option 3 — Clipboard fallback + visible banner (REQUIRED safety net; only cure if D)

- When the honest-success check (option 1) says the insert did not survive,
  surface the keyboard status banner *"Couldn't paste here — saved to clipboard,
  tap to paste"* and leave the full transcript on `UIPasteboard.general` (publish
  already wrote it there, `ClipboardHandoff.swift:53`) with a 1-hour
  `.expirationDate` per bug-slack-silent-paste.md's leak mitigation.
- Converts a **silent** failure into a **visible** one with a one-tap recovery —
  the floor we should guarantee even if options 1-2 don't fully cure the host.
- Caveat: the keyboard's collapsed-state banner is invisible (features.md §5.10 /
  CLAUDE.md). Verify the banner renders in the post-paste state, or fix §5.10
  first.

### Option 4 — Stale-payload hygiene (alternative C; cheap, do alongside)

- After a *landed+verified* paste, `markConsumed()` already clears
  `lastDictation`. Additionally, clear any stale payload whose `sessionID` is
  neither the current pending nor within a short grace, so a future session
  doesn't log spurious `pasteSkipSessionMismatch`. XS. Behavior-neutral; reduces
  log noise and closes the theoretical stale-paste edge in alternative B.

### Recommended sequencing

1. Ship the §5 **probe** (log-only). Reproduce in Claude Code (populated field).
2. Read the matrix → confirm A vs D.
3. Ship **Option 1** (honest success) + **Option 3** (fallback banner) together —
   these are correct under BOTH A and D and remove the silent-failure class.
4. If the probe says A-3.2a, add **Option 2** (adaptive re-sync) to actually land
   the paste in-place rather than always falling back to clipboard.
5. Fold in **Option 4** opportunistically.

Do NOT ship options 2 in isolation hoping it's a timing fix — that's exactly the
"jump to a fix" pattern that produced builds 103-106.

---

## 7. How to confirm the fix (field-type matrix)

Reproduce a **stop with auto-paste** in each, checking the field both EMPTY and
PREPOPULATED (the empty-vs-906 split is the whole bug):

| Host | Field type | Expectation |
|---|---|---|
| Messages | native `UITextView` | pastes (regression check — must still work) |
| Notes (short) | native | pastes |
| Notes (>2000 chars pre-caret) | native | pastes (windowing must not break honest-success) |
| **Claude Code chat** | **WKWebView** | **populated field pastes OR shows fallback banner + clipboard; never silent**|
| **Slack compose** | React-Native | same as Claude Code |
| Safari `<textarea>` | web | pastes or visible fallback |

Pass criteria:
1. **No `pasteSuccess` is ever logged when the host field did not change** (verify
   via the deferred read-back staying consistent).
2. Every real failure produces EITHER a successful in-place paste (option 2) OR a
   visible banner + clipboard fallback (option 3) — **never** the current silent
   false-success.
3. No double-paste in any host (the in-flight + single-insert guards hold).
4. In-Jot dictation (Edit/Feedback/W5) still single-pastes via the in-process
   `FocusedFieldInsert` path (transient branch, `DictationPipeline.swift:357-400`)
   — untouched by this work, but smoke-test it.

---

## 8. Cross-links

- Code: `Jot/Keyboard/JotKeyboardViewController.swift` —
  `flushPendingAutoPasteIfPossible` (:1128), the success/skip metric sites
  (:1245-1273), the build-108 re-sync (:1202-1206), `insertTrackedText` (:678),
  `beginPendingPasteSession` (:1008), stop/pending-write (:1998).
- Cross-process: `Jot/Shared/ClipboardHandoff.swift` (`publish` :48, `readFresh`
  :96, `markConsumed` :134); session resolution `Jot/App/JotApp.swift:1191`;
  publish `Jot/App/Intents/DictationPipeline.swift:365`.
- Prior chapters (READ FIRST): [bug-slack-silent-paste.md](bug-slack-silent-paste.md)
  (build-108 re-sync, Path D autosave, windowing, banner/clipboard-fallback
  design), [bug-rare-empty-field-first-paste-miss.md](bug-rare-empty-field-first-paste-miss.md)
  (empty-field nil-context ambiguity), and known-bugs-and-plans.md Updates #6–#9.
- Related deferred work: [refactor-decouple-root-view.md](refactor-decouple-root-view.md)
  (the true single-paste path that lets us delete the in-process bridge).
- features.md §5.12 / §2.9 / §13.2 (auto-paste handoff), §5.10 (collapsed-banner
  invisibility caveat — affects option 3).
