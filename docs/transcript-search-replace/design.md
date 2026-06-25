# Transcript Find & Replace — design

Shipped in 1.0.6 (build 186). Feature spec lives in `Jot/features.md §3.10`; this doc
captures the decisions and the implementation shape.

## Goal

Let the user fix a word the speech model misheard **several times** in a transcript in one
pass, and — when it looks like a real term correction — offer to teach Jot the word so the
next dictation gets it right by itself.

## Decisions (from brainstorm)

- **Edit-mode only.** No find/replace on the read-only Original/Rewrite tabs. The library
  already has cross-note search (§1.3); transcripts are short voice notes; the reading
  surface stays clean. Search-and-replace operates on whichever tab is being edited.
- **Replace All is the core op.** Whole-word + case-insensitive matching by default (so
  "is" doesn't clobber "this"), with a live match count. No per-match stepping in v1.
- **Changed words render italic** — free, because the inline editor ingests a programmatic
  `editorText` change as a non-user edit and marks the diff (see `InlineEditTextView`).
- **Learn-it offer reuses the existing path.** A qualifying replace, on Save, offers a
  gentle one-tap "Add 'X' to your vocabulary?" that calls the SAME logic as selection
  "Add to Vocabulary" (`confirmVocabAdd`): `VocabularyStore.addTerm(term, heardAs: find)` +
  `CorrectionStore.adjust(originalWord: find, term:, by: 1)`. Term + sounds-like alias +
  correction-store teaching — no new plumbing.
- **Gating** (so content edits like "Q3"→"Q4" don't nag): real change (term ≠ heard),
  1–2 word term, not an all-common-words term (`CommonWords`), replaced in **2+** places.
- **Non-blocking.** The offer is a dismissible card above the action bar; "Not now"
  changes nothing.

## Implementation (TranscriptDetailView.swift)

- State: `showFindReplace`, `findText`, `replaceText`, `@FocusState findFieldFocused`,
  `pendingReplaceLearn`, `replaceVocabOffer`.
- `findReplaceBar` sits above `editBar` (toggled by a magnifier in the edit bar). Focus is
  handed between the editor and the find field via `editorFocused`/`findFieldFocused` so the
  two text views don't fight over first responder.
- Matching/replace via `NSRegularExpression` with `\b<escaped>\b`, `.caseInsensitive`;
  `performReplaceAll` sets `editorText` (→ italic diff) and records `pendingReplaceLearn`.
- `saveEdit` captures a qualifying replace and, after exiting to read mode, shows
  `replaceVocabOfferCard`. `beginEdit`/`exitEditMode` reset the find + offer state.

## Not in v1 (possible follow-ups)

- Per-match next/prev stepping and single-occurrence Replace.
- Find/highlight in read-only tabs.
- Surfacing the heard→term alias in the Settings vocabulary UI (still no aliases field —
  §8.4).
