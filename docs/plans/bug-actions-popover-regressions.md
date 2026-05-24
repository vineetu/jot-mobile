# Bug Plan: Actions Popover Regression Cluster

> **Source:** user-reported, three symptoms in the keyboard's Actions popover.
> **Status:** Symptoms confirmed by user. Root causes have one high-confidence fix (Paste), one likely fix that needs verification (Undo), one regression that needs a quick read of git history to nail (Move up/down).
> Per the bug-overconfidence learning: confidence levels stated explicitly. Fix proposals are conservative; diagnostic-first where the code reading doesn't match the reported symptom.

---

## Symptoms (user-reported)

1. **Paste — stale clipboard.** Once the user pastes once via Actions → Paste, opening Actions again still shows the old paste state. The popover doesn't re-read `UIPasteboard.general` on each open. If the user copied something new in another app since the last open, that's not reflected.

2. **Undo / Redo — missing coverage for Recents-tap insertions.** User taps a Recents row in the keyboard → text is inserted into the host → they expect to be able to Undo that. Today, Undo isn't available for those insertions.

3. **Move up / Move down — regressed to ~one line per tap.** Previously each tap shifted the cursor by ~one host-visible window (~256–1000 chars). After the rename from "Jump to start / end" → "Move up / down" the underlying multi-char jump was supposed to remain. Now it's moving roughly one line at a time.

4. **Popover is hard to dismiss.** Tapping the Actions button again does not close the popover. Tapping outside the popover doesn't reliably close it either — the user has to tap a specific area (Recents row, or similar) to dismiss. Requirement: tap-anywhere-outside should close, and the Actions button should toggle.

---

## Bug 1 — Paste stale clipboard. **Confidence: 90%.** **Size: XS.**

### What the code does today

`refreshPasteState()` (`JotKeyboardViewController.swift:686`) reads `UIPasteboard.general.hasStrings` into the `hasPasteboardContent` field. It's called from:

- `viewWillAppear` (line 275) — once per keyboard presentation.
- `insertGeneralPasteboardString()` (line 749) — after a paste fires.
- `copySelectionToPasteboard()` (line 758) — after a copy fires.
- After auto-paste (line 1182).

**It is NOT called when the user taps the Actions button to open the popover.** Looking at `KeyboardView.swift:535-552`, the Actions button's `Button { ... }` body only toggles `showActionsPopover` — no refresh.

So the user's symptom is exactly what the code does. Confirmed.

### Caveat — pasteboard reads trigger iOS's privacy toast

Comment at line 298-300 explicitly says:

> "Keep selection and undo-menu enablement fresh without reading UIPasteboard here, which would fire iOS's paste-privacy toast on every keystroke."

Reading `UIPasteboard.general.hasStrings` (or `.string`) triggers the system "App is checking your clipboard" toast on iOS 16+. We can't read on every keystroke without spamming the toast. But reading **once per Actions popover open** is a discrete user-initiated event — one toast per open is acceptable UX.

### Fix

Call `refreshPasteState()` from the Actions button's tap handler before flipping the popover open:

```swift
private var actionsButton: some View {
    Button {
        feedback.systemClick()
        feedback.selectionTick()
        onActionsTapped()       // ← NEW: signals controller to refresh paste state
        showActionsPopover.toggle()
    } label: { ... }
}
```

The `onActionsTapped` closure is plumbed through to the controller and calls `refreshPasteState()`.

Alternative (smarter, optional): also track `UIPasteboard.general.changeCount` (a read that does NOT trigger the toast) and skip the full pasteboard read when `changeCount` hasn't moved since last refresh. Saves a toast on the common case where clipboard didn't change between opens.

### Verification

1. Copy "A" in Safari → switch to Jot keyboard → open Actions → Paste enabled, pastes "A". Confirm.
2. Switch back to Safari, copy "B" → switch to Jot keyboard (still presented) → open Actions → expected: Paste row shows enabled, pastes "B". Today: pastes "A" (stale). After fix: pastes "B".
3. Verify iOS clipboard toast fires once per Actions open, not on every keystroke.

---

## Bug 2 — Undo missing for Recents tap. **Confidence: 50%.** **Size: diagnostic-first.**

### What the code APPEARS to do

The Recents-tap path at `JotKeyboardViewController.swift:1398` calls `insertTrackedText(entry.text)`. `insertTrackedText` (line 658-662):

```swift
private func insertTrackedText(_ text: String) {
    guard !text.isEmpty else { return }
    textDocumentProxy.insertText(text)
    undoLedger.recordInsertion(text)
}
```

So Recents-tap insertions **should** be recorded in `undoLedger`. The Undo button's enabled state comes from `undoLedger.canUndo(contextBeforeInput:)` (line 642).

### Why the user's symptom might still be real

Multiple plausible reasons the code-reading doesn't match observed behavior:

- **H2a — `canUndo(contextBeforeInput:)` returns false even when ledger has the entry.** The check probably verifies the just-inserted text is still the tail of the proxy's pre-caret context. If the proxy buffers the insert (caret update is async), the tail may not show the insert yet when `canUndo` is called. The Undo button stays disabled.
- **H2b — Ledger entry exists but Undo execution fails.** `popUndo` (line 830) returns the entry; the actual delete might not fire if the proxy doesn't accept the backspace count.
- **H2c — Render isn't refreshing after the Recents tap.** The Undo button state is checked at render time; if the view doesn't re-render after `recordInsertion`, the Undo affordance stays disabled.
- **H2d — A different Recents-tap path bypasses `insertTrackedText`.** Line 1398 is one path; there may be others (e.g. the `arrow.up.forward.app` trailing button that opens the main app — but that one shouldn't insert text). Worth checking all Recents-tap call sites.
- **H2e — User tested with auto-paste in flight.** The auto-paste handoff at line 1182 also calls `insertTrackedText` for fresh dictations. If a Recents tap fires DURING an auto-paste window, the two insertions may collide and one's ledger entry overrides the other.

### Diagnostic plan

Before any fix:

1. Add a log line in `insertTrackedText` recording the source: who called this, with what text length, ledger depth after recording. Ship the patch and have the user reproduce.
2. Add a log line in `canUndo(contextBeforeInput:)` recording its return value, the ledger's top entry text, and the actual `documentContextBeforeInput` tail.
3. User reproduces: tap Recents → check log for `insertTrackedText` entry → tap Undo → check log for `canUndo` evaluation.

**Expected outcomes:**
- If `insertTrackedText` doesn't log → the Recents-tap path isn't going through it (H2d).
- If `insertTrackedText` logs but `canUndo` returns false → H2a or H2c.
- If `canUndo` returns true but Undo doesn't visibly delete → H2b.

**Patch size: XS for diagnostic** (~30 min). Fix size depends on which hypothesis confirms (XS for H2a/H2c, S for H2b/H2d, S for H2e).

---

## Bug 3 — Move up/down regressed to single-line jump. **Confidence: 40%.** **Size: diagnostic-first.**

### What the code APPEARS to do

`handleJumpToStart` (line 802-808) and `handleJumpToEnd` (line 815-821) loop up to 50 iterations, calling `adjustTextPosition(byCharacterOffset: -before.count)` per iteration. The doc comment acknowledges that on most hosts each tap shifts roughly one window (~256-1000 chars), not to the absolute start.

User reports it's moving "one line at a time" — which is much less than ~256-1000 chars.

### Hypotheses

Multiple, low-confidence on any one:

- **H3a — `documentContextBeforeInput` returns only the current line on the test host.** Some hosts may return only the line containing the caret. `before.count` would be ~40-80 chars. Each tap moves by that, which feels like one line. The 50-iter loop would compound, but if the proxy buffers updates, only the first iteration advances. Net: one line per tap.
- **H3b — The 50-iter loop is short-circuiting after one iteration** because subsequent `documentContextBeforeInput` reads return empty after the first move (we moved past the windowed view of pre-caret content). Net: one window's move per tap, but on a short-line host, that window IS one line.
- **H3c — Actual regression: someone changed `byCharacterOffset: -before.count` to `byCharacterOffset: -1` or similar.** Git history would show this.
- **H3d — `adjustTextPosition` behavior changed in iOS 26.** iOS-version-correlated; would affect everyone on iOS 26.

### Diagnostic plan

Two paths in parallel:

1. **Quick git check.** Look at the most recent N commits to `JotKeyboardViewController.swift` around the move/jump area. If a commit recently changed the offset multiplier, that's H3c — fix is to revert the multiplier.

2. **Instrumentation if git is clean.** Add a log line at the top of `handleJumpToStart` / `handleJumpToEnd` recording `before.count` (or `after.count`) at each iteration + the total chars moved. User reproduces; log shows what's actually happening.

**Expected outcomes:**
- If `before.count` is small (~40-80) → H3a, the host's proxy limits the window. Fix: investigate `adjustTextPosition` with larger explicit offsets (e.g. -10_000 with bounds check), or accept "one line per tap on short-line hosts."
- If `before.count` is large (~500-1000) but the move doesn't advance → H3b/H3d. Fix needs more investigation.
- If git shows a recent change → H3c. Fix: revert.

**Patch size: XS for git check + diagnostic** (~30 min). Fix size: XS if H3c, S otherwise.

---

## Bug 4 — Popover hard to dismiss. **Confidence: 60%.** **Size: XS.**

### What the code APPEARS to do

`KeyboardView.swift:214-246`:

```swift
if showActionsPopover {
    // Dim catcher behind the popover so a tap outside dismisses.
    Color.clear
        .contentShape(Rectangle())
        .onTapGesture { showActionsPopover = false }
        .accessibilityHidden(true)

    ActionsPopover(...)
        .zIndex(2)
}
```

And the Actions button at `KeyboardView.swift:535-552`:

```swift
Button {
    feedback.systemClick()
    feedback.selectionTick()
    showActionsPopover.toggle()
} label: { ... }
```

So in theory:
- Tapping outside the popover → catcher's `onTapGesture` fires → close.
- Tapping the Actions button → `toggle()` fires → close.

User says neither works reliably.

### Hypotheses (why the catcher doesn't catch most outside taps)

- **H4a — Other interactive elements above the catcher in tap priority.** The keyboard's punctuation row, space, return, and backspace keys are Buttons. When the user taps in those areas, the Button intercepts the tap before it reaches the catcher. Net effect: most "outside" areas of the keyboard don't dismiss because they're themselves tappable controls.
- **H4b — `Color.clear` frame collapses.** In a ZStack with `.bottomTrailing` alignment, `Color.clear` may not expand to fill the full ZStack — its size is determined by its container. If the catcher's frame is small, it only catches taps in that small area.
- **H4c — Z-order / drawing order issue.** The catcher is declared before the popover (lower zIndex), but the keyboard content (declared before the `if` block) might be drawn in a way that puts the catcher behind some interactive controls in hit-testing.
- **H4d — Actions button toggle race.** The button toggles to `false`, but the SwiftUI render hasn't propagated yet, or the popover's own animation keeps it visible while the state flag has already flipped.

### Why tapping Actions itself doesn't close

The Actions button calls `.toggle()`, which should work. If it isn't working, possibilities:
- The button's hit area is being intercepted by the popover's own hit testing (popover overlaps the Actions button's area, popover wins, button doesn't fire).
- A gesture conflict (the catcher's onTapGesture eating taps that should go to the button).

### Fix

Two-part fix, both small:

1. **Explicit full-keyboard tap-catcher with higher hit priority than other controls.** Replace the `Color.clear` catcher with one that:
   - Has an explicit `.frame(maxWidth: .infinity, maxHeight: .infinity)` so it fills the ZStack reliably.
   - Uses `.simultaneousGesture` or `.highPriorityGesture` to ensure it wins against the Buttons below.
   - Visually subtle dim (e.g. `Color.black.opacity(0.05)`) so the user sees the popover is modal.

2. **Make the Actions button explicitly handle the close case.** Instead of `toggle()`, branch:
   ```swift
   if showActionsPopover {
       showActionsPopover = false
   } else {
       onActionsTapped()  // refresh paste state (Bug 1)
       showActionsPopover = true
   }
   ```
   Same observable result as `toggle()` but easier to debug if state desync is the cause.

3. **Optional: surface a small ✕ button in the popover's top-right corner** as a tertiary dismiss affordance. Pure belt-and-suspenders — costs ~10 lines.

### Verification

1. Open Actions popover. Tap on a punctuation key (e.g. comma). Expected: popover closes; comma is NOT inserted into host (catcher consumed the tap).
2. Open Actions. Tap on Recents row. Expected: popover closes; the recents tap MAY also fire — confirm with user which behavior they want.
3. Open Actions. Tap the Actions button again. Expected: popover closes.
4. Open Actions. Tap on space bar. Expected: popover closes; space NOT inserted.
5. Open Actions. Tap on the popover itself (e.g. between rows). Expected: popover stays open.

Open question for #2: when a tap "outside" lands on Recents, should the recents tap fire AND close? Or just close? Probably just close — the popover open is the dominant state.

---

## Bundled implementation plan

All four bugs touch the same surface. Sensible to ship together:

| Step | Scope |
|---|---|
| 1 | Bug 1 fix: refresh paste state on Actions popover open. **XS.** Ship immediately. |
| 2 | Bug 4 fix: full-frame catcher + explicit toggle close + popover ✕. **XS.** Ship in same build. |
| 3 | Diagnostic patches for Bug 2 + Bug 3. **XS.** Ship in same build. |
| 4 | Git history check for Bug 3 — independent of build. **XS.** |
| 5 | User repros + sends logs. Fix Bug 2 and Bug 3 in follow-up build. **XS-S each.** |

Total time-to-resolve, optimistic: one build + one repro session + one follow-up build.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md). (No questions for this plan — all decisions are diagnostic-bound.)

1. **For Bug 1: optionally add `changeCount` short-circuit to avoid toast spam?** Default: yes, it's cheap. Skip the heavy read when changeCount hasn't moved.
2. **For Bug 3: if H3a confirms (host limits the window), should we change UX expectations?** "Move up/down" already names "approximately one window." If a host's window is one line, that's an honest result. May not require a code fix at all — the behavior is what's documented. Confirm with user once we know.

---

## Cross-Links

- Code: `Jot/Keyboard/JotKeyboardViewController.swift:686-822, 1398-1417`, `Jot/Keyboard/KeyboardView.swift:535-552`, `Jot/Keyboard/ActionsPopover.swift`
- features.md: `§5.6` Actions Popover (documents all six operations including Move up/down honesty caveat)
- Memory ref: `feedback_bug_overconfidence` — this plan structured around that learning.
