# Bug: rare first-paste miss into an empty host field

**Status:** Symptom recorded 2026-06-06, NOT fixed. **Deferred** (owner: "very rare,
don't want to waste time on it now — maybe later"). **Size: diagnosis-first, S.**

## Symptom
Very rarely, when stopping a keyboard dictation in another app while the host text
field is **empty**, the transcript does **not** auto-paste on the first try. The
transcript is still captured/saved (it shows in the keyboard's recents); only the
auto-paste into the empty field silently no-ops that one time. Rare and intermittent —
not every empty-field dictation.

## Context / why it's plausibly the same family as the auto-paste work
This is the flip side of the empty-field **double**-paste that build 106 fixed. That
fix made the keyboard read the proxy **after** the insert to decide "landed?" — because
`documentContextBeforeInput` returns `nil` for BOTH a disconnected proxy AND an
empty-but-live field, the pre-insert read alone can't distinguish them
(`JotKeyboardViewController.flushPendingAutoPasteIfPossible`). Build 106:
```
let proxyHadContextBefore = (textDocumentProxy.documentContextBeforeInput != nil)
insertTrackedText(payload.text)
let proxyHasContextAfter  = (textDocumentProxy.documentContextBeforeInput != nil)
let landed = proxyHadContextBefore || proxyHasContextAfter
```
**Hypothesis (low confidence):** in the rare empty-field case the genuine insert
*also* leaves `documentContextBeforeInput == nil` immediately after (host hasn't
committed the text into its document model yet, or proxy is mid-(re)connect), so
`landed == false` → the keyboard keeps the payload pending and does **not** retry in a
way the user sees → the first paste appears to be dropped. I.e. the after-insert read is
a good signal but not a perfect one for empty fields on slow/lazy hosts.

## Where to look when picked up
- `JotKeyboardViewController.flushPendingAutoPasteIfPossible` (the `landed` computation +
  the `pasteSkipProxyDisconnected` / `pasteSuccess` diagnostics — grep `contextGrew`).
- The auto-paste trigger timing: `refreshPipelinePhase` (`.idle` settled trigger) and
  `viewWillAppear` / `launchDeadline`.
- Related: [bug-slack-silent-paste.md](bug-slack-silent-paste.md) (host silently rejects
  insert — same "proxy returns nil" root family), and
  [bug-in-app-dictation-duplicate-paste.md](bug-in-app-dictation-duplicate-paste.md).

## Next step (needs device)
Reproduce once with the build-106 instrumentation and read the diagnostics log: grep
`pasteSuccess` / `pasteSkipProxyDisconnected` for `proxyHadContextBefore` + `contextGrew`
at the moment of the missed first paste. If `landed == false` was logged on a genuinely
empty-but-live field, the fix is a more robust landed-detection for empty fields (e.g. a
one-shot deferred re-check, or trusting the insert + a delayed verification) — **do NOT
ship a fix before a captured failing log.** Diagnostic-first.
