# Bug Plan: Auto-Paste Silently Fails in Some Host Apps (Slack)

> **Source:** [features.md §14.3](../../Jot/features.md#14-3-auto-paste-silently-fails-in-some-host-apps-notably-slack)
> **Status:** Diagnostic probe shipped in build 4. **Critical revision after adversarial review:** the probe's `contextGrew` signal is ambiguous on long host fields because `documentContextBeforeInput` is a windowed (~1024-char) view, not a full string. The plan now treats the existing probe as a necessary-but-insufficient signal.

---

## Symptom (recap)

User stops a warm-hold dictation while focused on a host app's text field (most reliably Slack). The keyboard's `pasteSuccess` event fires in diagnostics with the full character count, but no text appears in the host field. The transcript is still stored in Jot's library; only the auto-paste step silently no-ops.

**Path:** Warm-hold (Jot never foregrounded). Slack most reliable host; possibly other custom-compose-field apps.

## Critical correction to the diagnostic interpretation

The build-4 probe at `JotKeyboardViewController.swift:1140-1157` calculates `contextGrew = afterLen - beforeLen`. On a host where `documentContextBeforeInput` returns a **windowed** view (iOS docs and observed behavior: typically the last 1024 characters, sometimes less), `afterLen` saturates at the window size:

- Short host field (under 1024 chars): `contextGrew` is meaningful.
- Long host field (above 1024 chars, e.g. multi-paragraph Slack draft): `afterLen ≈ beforeLen ≈ window_max`, `contextGrew ≈ 0`, even on a fully successful insert.

So the current logic that says "if `contextGrew == 0`, the insert was silently rejected" produces **false positives** on exactly the cohort that reports the bug (long Slack drafts). We have to fix the probe interpretation before we can trust the fix path selection.

## Goal

1. **Tighten the probe** so its signal is unambiguous regardless of host field length.
2. **Once a real failure is captured** with the tightened probe, pick fix path A (proxy disconnected) or B (host rejected) or D (accessory-view interception — added below).
3. **Convert silent failure to visible failure** with a banner + clipboard fallback in all cases.

---

## Probe tightening (Step 1 — needed before any fix work)

### Add a `beforeContextSaturated` signal

```swift
// New: detect that the host field has more pre-caret content than the proxy will return.
// "Saturated" = the returned `documentContextBeforeInput` is at or near the windowed cap.
let kProxyWindowEstimate = 1024
let beforeContextSaturated = beforeLen >= kProxyWindowEstimate - 16  // 16-char safety margin
```

Add to the existing log metadata. If `beforeContextSaturated == true`, the `contextGrew` value is unreliable; the probe must rely on other signals (see below).

### Use `afterContextLenPre` properly

Existing probe captures `afterContextLenPre = textDocumentProxy.documentContextAfterInput?.count ?? -1` but never uses it in the disambiguation logic. After a successful insert, the after-caret context length is unchanged (we insert before the caret, not after). So:

- `afterContextLenPre` after insert (logged but not currently checked) vs. before insert — should be identical on success. A change here means the host inserted text after the caret somehow (re-render, etc.).

Add `afterContextLenPost` to the probe log. Cross-check stability of after-context as an independent signal of insert health.

### `pasteboard.changeCount` correlation

Surfaces a different angle: after insert, the host's autosave may bounce the focus and overwrite our text. If the user's clipboard `changeCount` advances right after our insert (autosave-induced UIPasteboard write), that's evidence of a focus shuffle that could have eaten our insert.

### Audit existing categories before adding new ones

The plan's "new `pasteSilentReject` category" should be cross-checked against existing categories. Per adversarial review, `pasteSkipDocumentMismatch` (line 1079) and `pasteSkipKeyboardTypeMismatch` (line 1097) already exist for related cases. Decision tree before adding a new category:

- Proxy nil at insert time → `pasteSkipProxyDisconnected` (new, or rename if there's an existing match).
- Host accepted but didn't change → `pasteSkipHostRejected` (new).
- Either case where text ended up on clipboard as fallback → metadata flag `clipboardFallback=true`.

Don't proliferate categories — be precise with one new state and reuse the rest.

---

## Fix Paths (Step 2 — pick after tightened probe captures real failure)

### Path A — Proxy disconnected at insert time

The hypothesis. With the tightened probe, we now have `proxyHadContextBefore = false` as a definitive signal (no windowed-context confound).

Fix:

```swift
guard proxyHadContextBefore else {
    // Best-effort retry inside one frame in case the disconnect was microscopic
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self else { return }
        // Re-check; payload value snapshotted in closure
        if self.textDocumentProxy.documentContextBeforeInput != nil {
            self.attemptInsert(payload: payload, session: session, isRetry: true)
        } else {
            self.fallbackToClipboardWithBanner(payload: payload, session: session)
        }
    }
    return
}

attemptInsert(payload: payload, session: session, isRetry: false)
```

Where `fallbackToClipboardWithBanner` (helper):
- Writes text to `UIPasteboard.general` with `.expirationDate` ~1 hour from now (avoids leaking into other apps long-term, and prevents iOS 16+ "Pasted from Jot" pill from firing months later for that string).
- Surfaces the keyboard status banner: *"Dictation paste blocked — saved to clipboard."*
- Logs `pasteSkipProxyDisconnected`.

**Stale-payload guard in the retry:** the 50ms retry should defensively check that the pending-paste session is still the same one we just left. If `ClipboardHandoff.markConsumed()` or a parallel `flushPendingAutoPasteIfPossible` cleared it, abort.

Size: **S** (~3-4 hours).

### Path B — Connected proxy, silently rejected

Harder. With the tightened probe and `beforeContextSaturated` known, we can now distinguish "long field success" from "actual rejection."

- If `beforeContextSaturated == false` AND `contextGrew == 0` → genuinely rejected.
- If `beforeContextSaturated == true` AND `contextGrew == 0` → can't tell; assume success.

For genuine rejection: same banner + clipboard fallback as Path A. Categorized `pasteSkipHostRejected`.

Optional smart-paste: re-emit the payload as a character-by-character `insertText` loop (one char per call) instead of one bulk call. Some hosts treat bulk + single inserts differently. If this works, we can ship as a fallback path.

Size: **S–M** (banner is shared with Path A; smart-paste experiment if needed is ~half a day).

### Path C — Partial insert. **Now correctly handled.**

With `beforeContextSaturated`:
- `contextGrew > 0 BUT < payload.text.count` AND `beforeContextSaturated == false` → real partial insert (host had a length limit).
- `contextGrew > 0 BUT < payload.text.count` AND `beforeContextSaturated == true` → ambiguous (could be windowing); fall back to clipboard rather than guessing.

Banner: *"Some text was clipped — full dictation saved to clipboard."*

Size: **XS** (~1 hour, mostly the conditional).

### Path D — Host accessory view interception (added per review). **Size: S.**

When the user taps Slack's @ mention picker (or formatting toolbar), the field's first responder briefly transfers. `documentContextBeforeInput` may return a non-nil **stale** value, so the Path A guard doesn't catch this.

Detection: probe `textDocumentProxy.hasText` (separate iOS API). When `hasText == false` but `documentContextBeforeInput != nil`, the proxy returned a cache of the previously-focused field — not the current.

Fix: tighten Path A's guard to `proxyHadContextBefore && textDocumentProxy.hasText`. Without `hasText`, the field is effectively unreachable and the same banner + clipboard fallback applies.

---

## UI changes

### Banner copy

| Failure mode | Banner |
|---|---|
| `pasteSkipProxyDisconnected` | *"Dictation paste blocked — saved to clipboard."* |
| `pasteSkipHostRejected` | *"This app didn't accept the paste — saved to clipboard."* |
| Partial insert | *"Some text was clipped — full dictation saved to clipboard."* |

Each banner stays for ~4 s; tap to expand into a small toast with "Tap to view in Jot" → opens main app to the transcript.

### `UIPasteboard.setItems(_:options:)` with expiration

Mitigates the "leak into other apps" concern. Sets `.expirationDate` to `Date(timeIntervalSinceNow: 3600)` (1 hour) so the dictation text isn't readable by other apps after the user has had a chance to paste it manually.

---

## Estimated Sizes

- Probe tightening (Step 1): **S** (~3 hours). Required before any fix.
- Path A fix (most likely needed): **S** (~3-4 hours).
- Path D fix (also likely needed in Slack's case): **S** (~2 hours, shares banner infra).
- Combined cumulative: **M** (~1 day).

---

## Test Plan

1. **Probe tightening verification.** Add the `beforeContextSaturated` signal. Run a known-healthy paste in iOS Notes with a short field → `beforeContextSaturated = false`, `contextGrew = payload.text.count`. Healthy baseline confirmed.
2. **Long-field success false-positive.** Paste into a Notes field with >2000 pre-caret characters. Old probe would log `contextGrew = 0` (bug). New probe logs `beforeContextSaturated = true` → "ambiguous, assume success." Verified the false-positive is gone.
3. **Proxy disconnect repro.** In Slack, type something to grow the draft, then quickly tap @ to open the mention picker (focus transfers), then fire Stop. Expected: banner appears, text on clipboard.
4. **Accessory-view interception (Path D).** In Slack, focus the formatting toolbar mid-recording (B/I/Strike). Fire Stop. Expected: banner appears, text on clipboard.
5. **Bulk-reject host (synthetic).** Write a test host app that overrides `shouldChangeTextIn` to reject anything longer than 5 chars. Verify banner fires.
6. **Clipboard expiration.** After a fallback, advance the clock 1 hour, attempt to paste manually → clipboard empty (expired). Verifies the leak mitigation.
7. **Stale-payload retry.** Trigger the 50ms retry path, then force `markConsumed()` between trigger and retry firing → retry should abort, no double insert.
8. **VoiceOver.** Banner is announced when it appears; "Saved to clipboard" message is read.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#b3--slack-silent-paste](./open-questions-deep-dive.md#b3--slack-silent-paste).

1. **Banner duration — 4 s right?** The existing keyboard status banner uses ~2.5 s for transient errors. The paste-failure case may warrant longer because the user needs to switch attention to clipboard. Recommend 4 s. Confirm.
2. **Clipboard expiration — 1 hour right?** Longer = more chance of leak; shorter = user might miss the window. Recommend 1 hour. Confirm.
3. **Should `pasteSkipProxyDisconnected` also surface a "Try again" button** in the banner? Adds chrome; clipboard fallback may be enough. Recommend no for v1. Confirm.

---

## Cross-Links

- Code: `Jot/Keyboard/JotKeyboardViewController.swift:1125-1184`
- Related: §14.2 (memory pressure) — independent but shares the keyboard's paste-resurrection layer.
- Diagnostics consumer: `Jot/App/Help/HelpView.swift` (Help → diagnostics, where the log is surfaced for support).
