# Plan: Delete Misleading "Wand in Keyboard" Help Copy

> **Sources:** [features.md §7.3](../../Jot/features.md#7-3-ai-rewrite-activation-model), [features.md §9.3](../../Jot/features.md#9-3-ai-rewrite-guide)
> **Status:** Aspirational claim that's never coming. Plan removes the claim, period.
> **Size: XS** (~10 minutes).

---

## Requirements

The Jot keyboard will **never** have a wand button. Decision is final per user direction. The only work this plan covers is removing the lying Help copy.

- After this plan ships: no app surface advertises a wand inside the keyboard.
- The transcript-detail Transform pill remains the canonical AI Rewrite entry point. No other entry points exist or are planned.
- `features.md §7.3` no longer carries the "keyboard wand/Magic entry point advertised but not yet present" caveat — because nothing is advertised anymore.

## Problem

`Jot/App/Help/HelpView.swift:223-227` says:

> "Jot ships with a built-in AI rewriter. Tap the **wand** icon on any transcript **or in the keyboard** to clean up filler words, fix grammar, or reformat into bullet points."

There is no wand in the keyboard. There never will be. The copy is false advertising that confuses users searching for a control that doesn't exist.

## Fix

Two changes:

1. **`Jot/App/Help/HelpView.swift:223-227`** — change the bullet to drop "or in the keyboard":

   ```
   "Jot ships with a built-in AI rewriter. Tap the wand icon on any transcript to clean up filler words, fix grammar, or reformat into bullet points."
   ```

2. **`Jot/features.md §7.3`** — remove the caveat sentence ("...the keyboard wand/Magic entry point is advertised but not yet present.") since the advertising is gone.

That's it. No new code. No new UI. No new App Group keys. No new infrastructure.

## Verification

- Grep `Jot/` for any other mentions of "wand" + "keyboard" together → expect zero hits after the edit.
- Open Help in-app, scroll to AI Rewrite section, confirm the bullet now only references the transcript wand.

## Cross-Links

- Touches: `Jot/App/Help/HelpView.swift:223-227`, `Jot/features.md §7.3`
- The transcript-detail Transform pill (`§7.4`) is unchanged and remains the only AI Rewrite entry point.
