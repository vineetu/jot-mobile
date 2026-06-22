# Bug plan — keyboard overlay surfaces (status banner + actions popover)

Two related defects in how the Jot keyboard renders transient overlay surfaces. Both are surfaced
visually in the mockup atlas (`atlas/gen/index.html`) and flagged there as known issues:
- atlas screen `kb-status-banner`
- atlas screen `kb-actions-popover`

Registry entries: `Jot/known-bugs-and-plans.md` →
"Keyboard 'Added to Vocabulary' confirmation uses error styling and appears late" and
"Keyboard Actions popover displaces the Recents list instead of floating over it".

Diagnostic-first — confirm each hypothesis against the code before changing anything.

## A. "Added to Vocabulary" banner — wrong styling + late appearance

**Symptom.** ••• → Add to Vocabulary shows "Added '<word>' to your dictionary" in the **red error
banner with an ✕ icon** (success rendered as error), and it appears only after a follow-up action
(e.g. Enter), not immediately on the add.

**Suspected code.** `Jot/Keyboard/JotKeyboardViewController.swift`:
- `setStatusBanner(_:)` / `refreshStatusBanner()` (~:616, :2572) and the banner overlay in
  `KeyboardView.swift` `statusBannerOverlay` (~:837) — likely a single error-styled component with
  no success variant.
- Add-to-vocab path (~:1116–1134: "Select a word first" / "common word" / "Added '…'") writes the
  message, but the render only refreshes on the next input event → late appearance.

**Fix shape (to confirm).**
1. Add a **severity** to the banner model (success | warning | error) and style accordingly
   (green check for success). Map "Added '…'" → success, "common word"/"select a word" → warning,
   transcription/model failures → error.
2. Make the add-to-vocab action **trigger a banner render immediately** (don't wait for the next
   keystroke) — e.g. call the render path synchronously after `setStatusBanner`, or react to the
   App-Group projection change rather than polling on input.

## B. Actions popover displaces the recents instead of floating

**Symptom.** Opening the ••• popover renders the menu inside the keyboard pane and pushes the
Recents strip down out of view; lower rows (Undo/Redo) can clip behind the control row.

**Suspected code.** `Jot/Keyboard/ActionsPopover.swift` + its host in `KeyboardView.swift` — the
popover is likely a sibling in the keyboard's vertical stack (consumes layout space) rather than an
overlay anchored above the ••• key.

**Fix shape (to confirm).** Present the popover as a floating **overlay** (`.overlay` / `ZStack`)
anchored to the ••• button, so the recents stay rendered underneath and the menu can extend upward
over the host content without reflowing the strip. Keep the single 220pt-wide menu; just change how
it's composited.

## Notes
- Both are **S** (contained keyboard-UI changes). They share a subsystem (keyboard overlay
  rendering) so they're listed under one plan; they can land in one change or separately.
- Keep the keyboard's ~60 MB ceiling in mind — no new heavy dependencies; pure layout/styling.
