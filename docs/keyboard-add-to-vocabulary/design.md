# Add to Vocabulary from the Keyboard

## Feature
Let the user add a vocabulary term **without leaving the host app**: select a word
in any text field, open the Jot keyboard's **"..." (Actions) popover**, tap
**"Add to Vocabulary"**, and the selected word is added to the same vocabulary
list used everywhere else — with the same common-word feedback, surfaced in the
keyboard's **Recents strip**.

Today this is only possible from the **transcript detail pane** (select text →
system selection menu → "Add to Vocabulary" → "what should this say?" prompt).
This brings the *direct add* to the keyboard surface.

## Owner decisions (locked 2026-06-21)
- **Surface: the keyboard's own `ActionsPopover`** (`Keyboard/ActionsPopover.swift`),
  NOT the host app's system selection menu. A keyboard extension cannot inject
  items into the host's Copy/Look-Up menu — that's the host's. The popover is the
  same gesture (select → "..." → Add to Vocabulary) in our own UI. Owner
  confirmed this is what they want.
- **Storage + processing stay in the main app.** Nothing vocab-related is stored
  in the keyboard. The keyboard captures the selected word and **bounces** it to
  the main app (same pattern as keyboard rewrite). The main app runs the *exact*
  existing add flow.
- **Reuse the transcript-pane flow verbatim — minus the alias step.** The
  transcript pane asks *"what should this say?"* (heard-as alias) because the
  selected text may be mis-transcribed. From the keyboard the selected word is
  already correct in the host text, so there is **no alias** — it's a direct
  `addTerm(term: selectedWord)`. Nothing else changes.
- **Feedback in the Recents strip** — the same common-word / quality messaging the
  app shows today (e.g. "Added ✓", "'okay' is a common word — not added").

## Make-or-break feasibility — CONFIRMED
- The keyboard **can read the selection**: `textDocumentProxy.selectedText`, which
  Jot's keyboard already reads at `JotKeyboardViewController.swift:703-709`. So
  "select a word → keyboard knows it" works.
- The `ActionsPopover` already has selection-aware actions (Copy needs a
  selection), so a selection-gated "Add to Vocabulary" row fits its existing
  pattern.

## Reuse map (existing pieces — "nothing new")
- **Add + validation:** `VocabularyStore.addTerm(...)` + the common-word filter,
  as used by the transcript pane (`App/TranscriptDetailView.swift:628/685`,
  `App/Vocabulary/MarkedTranscriptText.swift`, `CorrectionReviewModel.swift`).
- **Keyboard ↔ main-app bounce:** the rewrite bounce pattern, and the existing
  keyboard↔vocab plumbing from the parked "ask-before-paste" work
  (`CorrectionAsksPublisher` / the App-Group correction channel) — likely the
  cleanest carrier for the request + the feedback line.
- **Recents strip feedback host:** the keyboard's status/Recents surface
  (features.md §5.2 / §5.10).

## Open detail to settle during build
- The exact request/response carrier for the bounce (reuse the correction
  App-Group channel vs. a small dedicated key) and whether the main app must be
  foregrounded for the add, or it can process from background like other
  App-Group writes. (The add itself is light; only the rescorer *re-prep* is
  heavy and already deferred main-app-side.)

## Out of scope
- The "what should this say?" alias/correction (keyboard has no mis-transcription
  to correct).
- Any new vocab storage in the keyboard (there is none).
