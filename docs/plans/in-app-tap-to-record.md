# Plan: In-App Tap-To-Record (No Home-Screen Detour)

> **Source:** [docs/deferred-engineering.md §2](../deferred-engineering.md)
> **Status:** Rewritten after multiple turns of pruning. The keyboard is already app-agnostic at the proxy level; the only Jot-specific change is "don't push the Hero when we're inside Jot."
> **Size: S** (~3-4 hours).

---

## Requirements

The keyboard is the user's typing interface inside Jot for any text field. When the user taps Dictate while focused on a Jot text field, recording happens **without taking the user off their screen.** Final paste lands wherever the cursor is at Stop time — same as any third-party host.

### Cross-boundary behaviors (locked)

| # | Scenario | Required behavior |
|---|---|---|
| A | Start in Slack → end in Jot's feedback / prompt / vocab field, tap Stop | Paste lands in the Jot field. |
| B | Start in Jot's vocab editor → end in Messages, tap Stop | Paste lands in the Messages field. |
| C | Start in Jot field A → switch to Jot field B → Stop | Paste lands in field B. |
| D | Start in Jot field → stay in same field → Stop | Paste lands in the same field. |
| E | Start in Jot field → swipe home, open Messages, come back to Jot → Stop | Paste lands in whatever field the cursor is on at Stop. |

All of these inherit the existing keyboard auto-paste mechanism. The keyboard is app-agnostic at the `UITextDocumentProxy` level — it doesn't know or care which app's field it's typing into. Verified in practice: cross-boundary paste from Slack → Notes works today.

### What changes

When the user taps Dictate from inside Jot (the host is Jot's own process), do **not** navigate to the Recording Hero. Recording starts in place. Everything else — recording lifecycle, audio session, paste mechanism — is unchanged.

### What does NOT change

- No new Cancel button for in-app recording (the [keyboard-cancel-during-recording](./keyboard-cancel-during-recording.md) plan covers Cancel for ALL recording paths uniformly).
- No new focus-mirror infrastructure — the keyboard pastes wherever the cursor is at Stop, same as today.
- No special UI for in-place recording — the keyboard's existing streaming strip continues to show the live transcript.
- No ACK handshake — recording either starts (success) or doesn't (existing failure paths).
- No URL bounce — that's the literal one thing we're removing for in-Jot dictations.

---

## Problem

Today when the user dictates into Jot's own text fields (prompt editor, vocab term editor, feedback form, search bars), the keyboard's Dictate tap follows the third-party host path:

```
keyboard tap → jot://dictate URL → main app opens → Recording Hero pushed → user has to swipe back to settings after
```

That's right for third-party hosts. It's wrong when the host is already Jot — the user gets kicked off the field they were editing onto a full-screen Hero, then has to navigate back.

## Design

### Two-Track Dispatcher

`JotKeyboardViewController.handleMicCTATap` already has three branches:
1. Warm-resume Darwin notification (existing).
2. Wizard W5 short-circuit (existing).
3. URL-bounce + Hero (existing default).

Add a fourth branch between #2 and #3:

```swift
let decision = decideMicTap()
if hasFullAccess && AppGroup.isJotAppForeground(),
   case .start = decision,
   !AppGroup.isWizardActive {
    // Same-process dictation: tell the main app to start recording
    // without presenting the Hero. The proxy-paste path handles
    // everything else.
    CrossProcessNotification.post(name: .inAppDictationRequested)
    keyboardLog.info("mic tap routed in-place; host=Jot")
    return
}
```

`AppGroup.isJotAppForeground` already exists (used by wizard W5 short-circuit). `isWizardActive` is the only new bit of cross-process state — set by the wizard's root view on appear/disappear so the wizard W5 path takes precedence.

### Main-app side

A single observer for `inAppDictationRequested`. On receipt:
1. Start a recording via the existing `RecordingService.shared.start()` path.
2. **Suppress the Hero push.** The existing auto-push in `ContentView` keys on `recordingService.isRecording`; add a guard that skips push when this notification just fired.

The cleanest guard: a transient `AppGroup.suppressNextHeroPush` flag set just before starting the recording, cleared by `ContentView`'s observer after one read. No long-lived state.

### Paste

Nothing to design. The keyboard's existing auto-paste machinery (`flushPendingAutoPasteIfPossible`) targets `textDocumentProxy` at Stop time. The proxy is whatever field has focus — could be the same Jot field, a different Jot field, or a different app entirely. Cross-boundary scenarios (A through E above) all work because the keyboard is fundamentally app-agnostic at the proxy layer.

### Wizard W5 precedence

W5 also fires `keyboardDictateTapped` for in-Jot dictations during the wizard. Plan: gate the in-app branch on `!AppGroup.isWizardActive` so wizard takes precedence. `isWizardActive` is a new App Group bool set by `SetupWizardView.onAppear` / cleared in every dismissal path (per `Jot/CLAUDE.md`'s wizard force-stop contract).

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. Add `isWizardActive` AppGroup flag, set/clear in wizard lifecycle | `Jot/Shared/AppGroup.swift`, `Jot/App/SetupWizard/SetupWizardView.swift` + step `.onDisappear`s | S |
| 2. Add `inAppDictationRequested` Darwin notification | `Jot/Shared/CrossProcessNotification.swift` | XS |
| 3. Add `suppressNextHeroPush` AppGroup flag | `Jot/Shared/AppGroup.swift` | XS |
| 4. New dispatcher branch in keyboard | `Jot/Keyboard/JotKeyboardViewController.swift:handleMicCTATap` | XS |
| 5. Main-app observer + Hero-push suppression | `Jot/App/Intents/DictationPipeline.swift` (observer), `Jot/App/ContentView.swift` (suppress guard) | S |
| 6. Tests across the 5 cross-boundary scenarios | manual | S |

**Total size: S** (~3-4 hours).

---

## Edge Cases

- **`isJotAppForeground` stale-read after force-quit.** Per `AppGroup.swift:262-268`, force-quit + immediate keyboard tap within 2.5s is a known stale-read window. New risk: in-app branch posts a Darwin notification to a dead process. **Mitigation:** if the main app doesn't acknowledge recording-start within ~1s (no `recordingActive` flip), keyboard falls through to URL bounce. Same `recordingActive` AppGroup flag the keyboard's UI already observes.
- **§14.2 keyboard auto-switch.** Orthogonal — affects any cross-app paste path, not specific to this feature.
- **Wizard W5 active.** Discriminated via `isWizardActive` flag (Step 1).
- **Recording starts but user backgrounds immediately.** Recording continues (same as third-party). Paste lands wherever Stop happens — covered by Requirement E.

---

## Test Plan

Five scenarios from the Requirements section, plus:

1. Tap Dictate in vocab editor → speak "Kubernetes" → Stop → "Kubernetes" appears in field. No Hero. No home detour.
2. Tap Dictate in prompt-instruction TextEditor (multi-line) → speak multi-line content → Stop → newlines preserved.
3. Tap Dictate in feedback form → speak → Stop → text lands.
4. Cross-boundary A (Slack → Jot vocab editor) → text lands in vocab editor.
5. Cross-boundary B (Jot vocab → Messages) → text lands in Messages.
6. Cross-boundary C (Jot field A → Jot field B) → text lands in B.
7. Wizard W5 still works (existing keyboard try-it test).
8. Home screen with no field focused → Dictate falls through to URL bounce + Hero (no in-app branch should fire).
9. Force-quit Jot, tap Jot keyboard Dictate from Slack within 2.5s → stale `isJotAppForeground = true` triggers in-app path → 1s timeout fires → keyboard falls back to URL bounce.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md).

None remaining. The plan has been pruned through several iterations to the minimum viable design.

---

## Cross-Links

- Extends: `Jot/Keyboard/JotKeyboardViewController.swift` (`handleMicCTATap` dispatch chain)
- Reuses: `Jot/Keyboard/StreamingStrip.swift`, `AppGroup.isJotAppForeground`, `CrossProcessNotification`, existing auto-paste machinery
- Affects: every in-app text-entry surface (AI prompt editor, vocab editor, feedback form, search bars)
- Related: [keyboard-cancel-during-recording.md](./keyboard-cancel-during-recording.md) — Cancel button works uniformly across third-party and in-app paths via the same Actions-row replacement.
- Related bug: §14.2 (cross-app keyboard switching) — independent of this feature but affects any cross-boundary scenario.
