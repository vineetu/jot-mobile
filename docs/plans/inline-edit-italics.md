# Inline Edit Italics — design

## Intent (user request)

When editing a transcript — **either tab (Original or Rewrite), via keyboard typing or voice dictation** — the text the user **adds or changes** during this edit session renders in **italic**, while the untouched original text stays **regular**. On **Save**, everything flattens to regular (the edited text becomes the new baseline — italic is a *session-only* cue, never persisted).

Same editor for both tabs. The rewrite panel's editor may be reworked to share it.

## Non-goals / out of scope

- **No persistence of provenance.** Italic is transient. Schema stays frozen at V7 — no migration.
- **AI-rewrite-while-editing.** The app already refuses to rewrite while `isEditing` (`autoFireKeyboardRewrite` guard) and disables the editor during dictation. So "AI splices a span mid-edit" is NOT a path we design for.

## Why not the obvious approach (rejected by adversarial review)

Binding to `AttributedString` and **diffing against a snapshot every keystroke** (LCS) is:
- O(n·m) on the main thread per keystroke AND per streamed voice token;
- semantically wrong on dictation text — repeated words ("the", "I think") make the aligner flip italic onto a *different* identical span than the one edited.

**Avoided.**

## Chosen approach — common-affix delta + `UITextView`

Every edit this surface can produce is a **single contiguous replacement** (typing one char, backspace, paste, select-replace, and the voice stream's `prefix + partial + suffix` rewrite). For a single contiguous change, the changed range is recovered **exactly and in O(n)** by:

```
p = length of common prefix(old, new)
s = length of common suffix(old, new)   // not overlapping p
changedRangeInNew = [p, new.count - s)
deletedRangeInOld = [p, old.count - s)
```

No LCS, no fuzzy alignment.

### Component: `InlineEditTextView: UIViewRepresentable` (wraps `UITextView`)

Bindings (keep the existing contract so `EditDictationController` is **unchanged**):
- `@Binding var text: String` — plain text, source of truth for Save.
- `@Binding var selection: TextSelection?` — synced from the text view's `selectedRange` (so insert-at-cursor keeps working).
- `baseFont` / config for styling parity with the current editor.

Coordinator state:
- `lastText: String` — last text the coordinator rendered.
- `newRanges: [Range<Int>]` (character offsets) — spans added/changed this session.

Flow (one path for typing, paste, AND voice):
1. **Text changes** — from the user (`textViewDidChange`) or programmatically (`updateUIView` sees `text` binding differ from `lastText`).
2. Compute the common-affix delta vs `lastText` → `changedRangeInNew` (inserted) + `deletedLen` (removed).
3. Update `newRanges`: drop the deleted slice, shift offsets after the edit, insert `changedRangeInNew` as a new span, and coalesce touching spans.
4. Rebuild `attributedText`: `baseFont` everywhere, **italic** on `newRanges`. **Save and restore `selectedRange`** around the assignment so the caret never jumps.
5. Sync `selectedRange → selection` binding.
6. `lastText = text`.

Edit-start: on entering edit mode, `newRanges = []`, `lastText = text` → the whole original loads regular. Anything the user then types/dictates/edits becomes italic.

### Save
`TranscriptDetailView.saveEdit()` already persists `editorText` (plain `String`) to `transcript.text` / `cleanedText` / `rewriteUserEdit`. Italic lives only in the view's `attributedText`, so the saved value is already flat. Keep the existing string-vs-string no-op comparison (don't compare AttributedStrings).

### Voice integration (no controller change)
`EditDictationController.renderPartial` / `insertFinal` rewrite the `text` binding as `prefix + mid + suffix`. `updateUIView`'s common-affix delta recovers `mid`'s exact range each partial token → italic, growing as the stream extends. O(n) per token (bounded), not LCS.

## Open product nuance (assumed answer)
Editing **within** the original text (e.g. fixing a word in the middle) marks the changed chars italic — i.e. "new" = *anything you touched*, not only appended text. This matches "identify the rewritten text." Assumed YES.

## Risks to validate on device
1. **Caret stability** when `attributedText` is reassigned per change — mitigated by save/restore `selectedRange`; must confirm no jump/flicker, especially mid-IME composition (CJK marked text).
2. **Performance** on a long transcript — O(n) per keystroke + attributedText set. Fine for typical lengths; load-test a long one.
3. **Selection index sync** between `UITextView.selectedRange` (UTF-16) and the `TextSelection?`/`String.Index` the controller expects — get the index conversion right (UTF-16 ↔ String.Index).
4. **Dictation-disabled state** (`.disabled` while streaming) and the editor's existing focus/streaming wiring must survive the swap from `TextEditor` to the representable.

## Plan
1. Build `InlineEditTextView` + coordinator (this doc's contract).
2. Swap it in for the `TextEditor` in `TranscriptDetailView` edit mode (both tabs).
3. Keep `EditDictationController` and `saveEdit` as-is; only the editor view changes.
4. Adversarial review of the implementation (caret/selection/perf), then build + ship.
