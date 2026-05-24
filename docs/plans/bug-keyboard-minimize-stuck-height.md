# Bug Plan: Keyboard Minimize Shrinks SwiftUI Content But Stays Tall

> **Status:** Reproduced symptom, **multiple plausible causes, none confirmed.** Per the bug-overconfidence learning: this plan enumerates hypotheses without picking a winner and proposes diagnostic instrumentation that disambiguates between them. **Do not ship a fix before logs identify the cause.**

---

## Symptom

User taps **Minimize** in the Jot keyboard:
- SwiftUI render branch updates correctly — the collapsed-bar UI (Stop button centered) appears.
- **But** the keyboard's outer frame stays at expanded height (~450 pt). User sees the small collapsed-bar content floating in a tall empty keyboard envelope.
- Symptom is intermittent ("many times") — sometimes Minimize works, sometimes it stays stuck.
- **The fix that works on the user's side:** globe-switch to another keyboard, then globe-switch back to Jot. On the re-presentation, the keyboard renders at the correct collapsed 58 pt height.

This is **the opposite of the documented §5.10 banner-in-collapsed bug** — there, the height grows but content doesn't update. Here, content updates but height doesn't shrink.

## What we know about the code paths

Verified by reading:

- `JotKeyboardViewController.swift:219-244` — `loadView()` creates a `UIInputView` with `allowsSelfSizing = true`. So the system input-view host IS supposed to honor our internal constraint.
- `JotKeyboardViewController.swift:225-244` — `viewDidLoad` calls `installHeightConstraint()` (line 354-362) which sets up a height pin on `self.view`. Installed once; persists.
- `JotKeyboardViewController.swift:372-388` — `toggleCollapsed()`:
  1. `isCollapsed.toggle()`
  2. Persist to UserDefaults
  3. VoiceOver announce
  4. `renderRootView()` — SwiftUI rebuilds with new state.
  5. `applyCollapsedHeight(animated: true)` — sets constraint constant + animates.
- `JotKeyboardViewController.swift:395-437` — `applyCollapsedHeight`:
  - Guards on `heightConstraint != nil` (silent return if nil).
  - Sets `constraint.constant = target`.
  - Animates via `UIView.animate` + `view.layoutIfNeeded()`.
- `JotKeyboardViewController.swift:518-543` — `temporarilyExpandForBanner` can override the constraint to 450 pt while a status banner is showing.
- `JotKeyboardViewController.swift:459-478` — `viewWillTransition` re-applies the height inside the transition coordinator.

There's already a `[KB-COLLAPSE-DEBUG]` instrumentation layer (line 444-452) that logs the geometry at every transition. **The user can capture these logs in Console.app filtered by `[KB-COLLAPSE-DEBUG]` to diagnose any failed minimize.**

---

## Hypotheses (multiple, no confidence yet)

Listed in rough order of plausibility, but **all need empirical disambiguation**.

### H1 — System input-view host caches the keyboard height per-presentation

The system's outer container (the input-view host owned by iOS, not our `UIInputView`) may cache the keyboard's height once at first presentation and ignore subsequent autolayout-driven changes until a new presentation begins.

**Evidence for:** the user's workaround is globe-switch + re-present. That forces a new presentation. If the height were autolayout-driven end-to-end, the same constraint change should work in-place.

**Evidence against:** `allowsSelfSizing = true` is the documented opt-in for "honor child constraints." Apple's docs say this should propagate.

**How to test:** instrument `viewWillAppear` to capture the outer envelope height (use `view.window?.bounds.height` or trace through `inputViewController.view.superview.bounds`). If the outer envelope stays at 450 after our internal constraint goes to 58, this is the bug.

### H2 — Animation interruption / double-tap race

User taps Minimize twice rapidly (or Minimize while a previous animation is still running). UIView.animate doesn't cancel cleanly across rapid toggles. The constraint constant updates correctly, but the visible frame is left at an intermediate value because the layer's animated presentation is mid-flight.

**Evidence for:** the bug is intermittent. Race conditions are intermittent. Comment at line 374-376 explicitly notes "double-tap race" as a known suspect.

**Evidence against:** `[.beginFromCurrentState]` is set on the animation options — that's the standard mitigation for interrupted animations. Should work unless the constraint solver and the layer animation desync.

**How to test:** log the timestamp of every `toggleCollapsed` entry and every `post-settle` snapshot. If two `toggleCollapsed` entries land within <300 ms, that's the race.

### H3 — Banner auto-expand collision

A status banner fires (transcription result, error, etc.) while user is mid-minimize. `temporarilyExpandForBanner` (line 518) sets the constraint to 450 pt to make the banner visible. The user's intended Minimize is overridden by the banner's expand. When the banner clears (2.5 s later), it calls `applyCollapsedHeight` to restore — but in the meantime the user sees the symptom.

**Evidence for:** the user is likely minimizing right after a dictation, which is exactly when banners fire (success / error message).

**Evidence against:** the banner clear path (line 504-509) should fix the height when the banner expires. User's symptom doesn't auto-resolve at 2.5 s — they have to globe-switch.

**How to test:** correlate `setStatusBanner` calls + their state transitions with the `toggleCollapsed` log. If a banner is active during the user's repro, this is the offender. The `[KB-COLLAPSE-DEBUG]` log already records the entry state; we'd need to add banner-state to that snapshot.

### H4 — SwiftUI render branch decouples from UIKit height

`renderRootView()` is called BEFORE `applyCollapsedHeight()` (line 386 then 387). SwiftUI swaps to the collapsed-bar view immediately. UIKit's height animation runs next. If UIKit's animation is interrupted or somehow no-ops, SwiftUI is showing collapsed content inside a still-expanded frame.

**Evidence for:** exactly matches the symptom — small content in a tall envelope.

**Evidence against:** UIView.animate with `.beginFromCurrentState` should be reliable. But "reliable" assumes the constraint solver actually drives the height change.

**How to test:** the existing `[KB-COLLAPSE-DEBUG]` post-settle log already captures `view.bounds.height` after the animation completes. If `constraint.constant == 58` but `view.bounds.height > 58` at post-settle, this hypothesis is confirmed (the constraint didn't drive the actual layout).

### H5 — Hosting controller's intrinsicContentSize fights the height constraint

The SwiftUI `UIHostingController`'s view has an intrinsic content size that reflects its content. When the expanded view's content is large (full keyboard), the hosting controller's intrinsic size is large. Even after `renderRootView` swaps to the collapsed bar, AutoLayout may take one or more passes to reconcile the new smaller intrinsic size with our 58 pt height constraint.

**Evidence for:** SwiftUI hosting + intrinsic-content-size interactions are a well-known foot-gun.

**Evidence against:** the hosting controller's view is constrained via the 4 anchors (lines 326-329), which should fully constrain its frame to our view's frame. Intrinsic content size shouldn't matter when fully constrained.

**How to test:** log `hostingController?.view.intrinsicContentSize` at the post-settle point. If it's 450 while our constraint is 58, AutoLayout is somehow respecting the larger value.

### H6 — `heightConstraint` is unexpectedly nil at toggle time

`applyCollapsedHeight` has `guard let constraint = heightConstraint else { return }` (line 396). If the constraint is nil at toggle time, the entire height-change path is silently skipped — `isCollapsed` is toggled and SwiftUI re-renders, but no UIKit layout change happens.

**Evidence for:** would explain exactly the symptom — SwiftUI updates, UIKit doesn't.

**Evidence against:** `installHeightConstraint()` runs in `viewDidLoad` and the constraint is stored in `heightConstraint` (var, not weak). Should persist for the controller's lifetime.

**How to test:** add a log inside the guard's failure branch. If it ever fires, this is the bug.

### H7 — `viewWillTransition` collision

Trait-collection change (e.g. brightness, accessibility setting flip) during the toggle window resets the constraint inside the transition coordinator's block (line 471-477). The transition coordinator can interfere with concurrent animations.

**Evidence for:** intermittent timing-dependent failures match this profile.

**Evidence against:** `viewWillTransition` only fires on rotation / size change — rare in normal keyboard use unless the user rotates mid-tap.

**How to test:** the `[KB-COLLAPSE-DEBUG] viewWillTransition` log already exists. If it fires interleaved with `toggleCollapsed` in a failed-minimize capture, this is the bug.

### H8 — Banner auto-expand reset task races toggle

`bannerAutoExpandResetTask` (line 533-544) is a 2.5 s sleep that calls `applyCollapsedHeight` on completion if `isCollapsed` is still true. If user toggles during the sleep, the task could stamp the wrong value at completion.

**Evidence for:** an intermittent race window.

**Evidence against:** the task reads `self.isCollapsed` AT COMPLETION, not at scheduling time. Should reflect current state.

**How to test:** log entry + exit of the reset task. Cross-correlate with toggle events.

### H9 — `UIInputView` layout pass timing

`UIInputView` has its own internal layout dance. The system queries it for height at specific moments — typically on first presentation, after rotation, and after explicit invalidation via `inputViewController.viewDidLoad` or `setNeedsInputViewLayout`. Our `layoutIfNeeded` updates our subtree but might not trigger the system to re-query our preferred size.

**Evidence for:** Apple's documentation around `UIInputView.allowsSelfSizing` is thin; the actual size-negotiation contract isn't fully specified.

**Evidence against:** with `allowsSelfSizing = true`, child constraints are supposed to drive the height. Multiple keyboard extensions in the wild use this pattern.

**How to test:** call `setNeedsInputViewLayout()` (a UIInputViewController method) inside `applyCollapsedHeight` after the constraint change and see if it changes the behavior.

### H10 — Cross-process or cross-presentation state from main app

The keyboard reads several App Group / `UserDefaults` values during `viewWillAppear` (Full Access, history, paste state). If one of these reads kicks off a state-change that triggers `renderRootView()` mid-toggle, the resulting render could fight the in-flight height animation.

**Evidence for:** the keyboard process has multiple async observers (Darwin notifications, App Group readers).

**Evidence against:** observers shouldn't fire on the main thread mid-toggle if the toggle itself runs on main.

**How to test:** add log entries to every observer that calls `renderRootView()` or anything that touches `heightConstraint.constant`.

---

## Diagnostic Plan (do this FIRST)

The existing `[KB-COLLAPSE-DEBUG]` instrumentation is most of what we need. Augment it:

1. **Add banner-state to the geometry snapshot.** Inside `logCollapseGeometry`, also log `bannerActive=\(statusBanner != nil)` so we can correlate banner expand cycles with toggle attempts.

2. **Add a "constraint nil" log path.** Inside the existing guard at line 396, log a `keyboardLog.error("applyCollapsedHeight aborted — heightConstraint was nil")` so H6 fires visibly when it triggers.

3. **Add observer-attribution logging.** Every code path that mutates `heightConstraint.constant` should log who's calling and why. Today we have entry logs for `toggleCollapsed`, `viewWillTransition`, `temporarilyExpandForBanner`, and the banner-reset task. Add a single source-of-mutation tag to each (e.g. `source=toggle`, `source=banner-expand`, `source=banner-reset`, `source=transition`).

4. **Repro protocol.** User reproduces with Console.app filtered to `[KB-COLLAPSE-DEBUG]`. Captures one stuck-minimize event AND one successful-minimize event. The diff between the two log sequences is the answer.

5. **Patch size for diagnostic instrumentation: XS** (~30 minutes). Ship and wait for capture.

---

## Possible Fixes (do NOT commit to one until diagnosis lands)

Listed by hypothesis they'd address. Sized roughly.

| If diagnosis is | Candidate fix | Size |
|---|---|---|
| H1 (system caches height) | Call `setNeedsInputViewLayout()` after every `constraint.constant` change to force the system to re-query our preferred size. | XS |
| H2 (animation race) | Add a cancel-in-flight guard at the top of `applyCollapsedHeight` that stops any prior animation explicitly via `view.layer.removeAllAnimations()` before starting the new one. | XS |
| H3 (banner collision) | Track "user intent" separately from "banner-overridden height." If user toggles during a banner, queue the toggle to fire when banner clears, instead of letting the banner's expand win. | S |
| H4 (UIKit-SwiftUI decouple) | Move `renderRootView()` to AFTER `applyCollapsedHeight` so UIKit height settles first; SwiftUI swap follows the height. Inverted ordering. | XS |
| H5 (hosting intrinsic fight) | Set `hostingController.view.translatesAutoresizingMaskIntoConstraints = false` (already done) AND explicitly invalidate intrinsic content size before constraint change: `hostingController.view.invalidateIntrinsicContentSize()`. | XS |
| H6 (constraint nil) | Defensive: re-call `installHeightConstraint()` in `applyCollapsedHeight` before the guard. Costs nothing if already installed. | XS |
| H7 (transition collision) | Guard `toggleCollapsed` against running while a transition is in flight; queue and replay. | S |
| H8 (banner reset race) | The reset task already checks `isCollapsed` at completion — but it doesn't check whether the user has toggled since scheduling. Add a generation counter that the reset task checks before stamping. | S |
| H9 (UIInputView timing) | Same as H1 — `setNeedsInputViewLayout()`. | XS |
| H10 (observer-driven re-render fights toggle) | Suppress all `renderRootView()` calls during the toggle window (e.g. a `isApplyingCollapse` flag observers check before re-rendering). | S |

**Total fix size, depending on diagnosis: XS → M.** Most plausible candidates are XS. The S options require more state management.

---

## Test Plan (post-diagnosis)

For whichever fix is chosen:

1. **Stress-test the toggle.** Tap Minimize 10× rapidly. Should reliably end in the correct state.
2. **Toggle during banner.** Trigger a banner (force a transcription error), then tap Minimize during the banner's lifetime. Should reliably honor user intent.
3. **Toggle after dictation.** Standard flow: dictate, stop, banner fires with "transcription done," tap Minimize during the banner window.
4. **Toggle during rotation.** Rotate device mid-tap (synthetic test using Xcode simulator).
5. **Toggle on cold keyboard.** First Minimize tap after keyboard's first-ever presentation.
6. **Toggle after globe-switch.** Switch keyboards, come back, tap Minimize.
7. **VoiceOver:** announcement still fires correctly.
8. **Reduce Motion:** the no-animate path doesn't regress.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md). (Currently no questions for this plan — design is diagnostic-first.)

1. **Has the user reproduced this on a specific iOS build, or across multiple?** iOS-version correlation matters for H1 / H9 (system-internal behavior changes).
2. **Does this also reproduce on iPad (if the user uses it there)?** iPad input-view behavior differs subtly.
3. **Does the bug occur on cold-keyboard first tap, or only on subsequent taps within the same session?** Distinguishes "first-presentation never wired up" (rare) from "state accumulates per session."

---

## Cross-Links

- Code: `Jot/Keyboard/JotKeyboardViewController.swift:225-244, 345-543`
- features.md: `§5.8` (Minimize/Expand spec), `§5.10` (related — banner-in-collapsed bug, opposite failure mode)
- Memory ref: `feedback_bug_overconfidence` — this plan is built around staying diagnostic-first.
