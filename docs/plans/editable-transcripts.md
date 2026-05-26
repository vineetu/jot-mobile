# Plan: Editable Transcripts (Simplified)

> **Status:** Revised 2026-05-24. Scope simplified — see "What changed" at bottom for the diff from the prior version.
> **Size: S-M** (~½–1 day, dominated by schema V1→V2 + edit-mode UX in Transcript Detail).

---

## What user can do

- In Transcript Detail, tap **Edit** in the floating ActionBar → the currently-visible tab's text turns into a `TextEditor`; keyboard pops up; cursor at end. The other tab is hidden (you edit one tab at a time).
- Tap **Save (✓)** to commit; tap **Cancel** to discard.
- **Original tab edit**: in-place overwrite of `transcript.text`. No before/after stored. The pre-edit Parakeet text is gone forever.
- **Rewrite tab edit**: writes `transcript.rewriteUserEdit`. `transcript.cleanedText` (the LLM's output) stays frozen as the training "before". The pair `(cleanedText, rewriteUserEdit)` is the training signal.
- Edits are local and private. No UI exposes the training-pair data.

## Non-Goals

- **No auto-regenerate** when Original is edited. If the user wants a fresh rewrite they tap Transform like normal.
- **No confirm dialog** when an edited rewrite would be replaced by a re-Transform. The user knows what they're doing.
- **No edit history / version timeline.** Last save wins.
- **No `RewriteTrainingPair` table.** One pair per transcript, inline. If the user re-Transforms, the pair resets — last user-edit-against-current-model-output wins.
- **No `editedOriginalText` field.** Original edit overwrites `text` directly.
- **No `lastRewritePromptID` tracking.** Auto-regen doesn't exist, so prompt-id correlation is unnecessary.
- **No multi-tab edit.** One tab at a time per Save.
- **No edit during recording** (the Edit affordance is disabled while a recording is in progress).

---

## Data model — Schema V2

Per schema discipline (`Jot/CLAUDE.md` §"Schema discipline"), add a new versioned schema file rather than mutating `JotSchemaV1`.

### `Jot/Shared/Schema/JotSchemaV2.swift`

Copy of `JotSchemaV1.Transcript` with **one new optional field**:

```swift
enum JotSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [JotSchemaV2.Transcript.self] }

    @Model
    final class Transcript {
        // ... all V1 fields, identical types and order ...

        /// The user's manual edit to the current Rewrite. `nil` = no user
        /// edit; the model's `cleanedText` is canonical. Non-nil = user
        /// typed corrections.
        ///
        /// Persisted alongside `cleanedText` (NOT replacing it). The pair
        /// `(cleanedText, rewriteUserEdit)` is the future-fine-tuning
        /// training signal: "model produced X, user corrected to Y."
        ///
        /// Reset (set to nil) whenever `cleanedText` is overwritten —
        /// a stale userEdit against a new model output is meaningless.
        /// Specifically:
        ///   - On re-Transform → set new cleanedText, nil out rewriteUserEdit.
        ///   - On Discard rewrite → both nilled.
        /// `displayText` falls back: `rewriteUserEdit ?? cleanedText ?? text`.
        var rewriteUserEdit: String?

        init(/* same as V1 + rewriteUserEdit: String? = nil */) { ... }
    }
}
```

### Migration: V1 → V2

`MigrationStage.lightweight(fromVersion: JotSchemaV1.self, toVersion: JotSchemaV2.self)`.

Pure additive optional field. SwiftData's lightweight inference handles this case reliably (the field is `nil` for every pre-existing row on first read). No `willMigrate` / `didMigrate` needed.

### Schema impact summary

- **Add/remove/rename `@Model` fields?** Add ONE field (`rewriteUserEdit: String?`) to the Transcript entity. No removes, no renames.
- **Add new `@Model` entities?** No.
- **MigrationStage:** `.lightweight` V1 → V2.

---

## Display + persistence rules

### `displayText` (used by Recents, share mirror, keyboard RecentsStrip)

```swift
var displayText: String { rewriteUserEdit ?? cleanedText ?? text }
```

Priority: user's edited rewrite, then model's rewrite, then raw transcript. This is the text any cross-surface consumer should render.

### `hasRewrite` (used by Detail's tab-visibility check)

```swift
// In TranscriptDetailView:
private var hasRewrite: Bool {
    if let edit = transcript.rewriteUserEdit, !edit.isEmpty { return true }
    if let cleaned = transcript.cleanedText, !cleaned.isEmpty { return true }
    return false
}
```

The Rewrite tab is reachable as soon as the user has edited it OR the model has produced one.

### `bodyTextForActiveTab` (used by Copy + Share + word count)

```swift
private var bodyTextForActiveTab: String {
    switch selectedTab {
    case .original:
        return transcript.text  // unchanged
    case .rewrite:
        return transcript.rewriteUserEdit
            ?? transcript.cleanedText
            ?? transcript.text
    }
}
```

### Persistence

**Original Save:**
```swift
transcript.text = trimmedNewText
try modelContext.save()
TranscriptHistoryMirror.refresh(from: modelContext)
CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
```

**Rewrite Save:**
```swift
transcript.rewriteUserEdit = trimmedNewText
try modelContext.save()
TranscriptHistoryMirror.refresh(from: modelContext)
CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
```

**Re-Transform (`startRewrite` + `startKeyboardOriginatedRewrite`):** when `cleanedText = trimmed`, also do `transcript.rewriteUserEdit = nil`. Stale user-edit against new model-output is meaningless.

**Discard rewrite:** existing code nils `cleanedText`; also nil `rewriteUserEdit`.

---

## UX in Transcript Detail

### Entering edit mode

- Add a fifth ActionBar slot: an **Edit** pencil item, placed in the trailing array alongside Delete. New layout: `leading: [Copy, Share], primary: Transform, trailing: [Edit, Delete]`.
- Tap Edit while on the **Original** tab → that tab's text becomes editable.
- Tap Edit while on the **Rewrite** tab → that tab's text becomes editable (initial editor value = `rewriteUserEdit ?? cleanedText`).
- Disabled if recording is in progress (use the same recording-progress source the existing UI uses).
- Tab switcher pill is hidden during edit (one tab at a time).
- Original-tab Edit is disabled if `transcript.text` is empty (shouldn't happen, but guard).
- Rewrite-tab Edit is disabled if there's no rewrite to edit (`!hasRewrite`).

### Edit-mode chrome

While `isEditing == true`:
- Transcript card body is a `TextEditor` bound to a local `@State var editorText: String`.
- Bottom ActionBar is replaced by a slim **EditBar** with: `Cancel` (secondary, dismisses edits) on the left, the active tab label centered, and `Save` (primary blue pill, ✓) on the right.
- Top toolbar's chevron-back is disabled (user must Cancel or Save to leave).
- Rewrite Transform button is disabled (you can't kick a new rewrite while mid-edit).

### Save / Cancel

- **Save**: trims whitespace. If empty after trim on Original tab → show inline error "Original text can't be empty." (revert? user choice — keep the editor open so they can fix it). If empty on Rewrite tab → treat as discard-of-edit (set `rewriteUserEdit = nil` so it falls back to `cleanedText`).
- **Cancel**: discard local state, exit edit mode. No persistence.

### Other affordances

- **No undo bar.** Cancel covers in-flight; once Saved, the prior text is gone. (For Original this is intentional — user said "we don't care about the original at all." For Rewrite we don't need it either; the model's `cleanedText` is still there, so they can hit Cancel-Edit-Edit-cycle to restart.)

---

## Cross-process invariants

After ANY Save (Original or Rewrite):

1. `try modelContext.save()`
2. `TranscriptHistoryMirror.refresh(from: modelContext)` — refresh the JSON the keyboard reads.
3. `CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)` — wake any live keyboard so its RecentsStrip re-renders.

Without these, the keyboard's recents strip renders the pre-edit text until the next dictation refreshes the mirror.

The mirror's `Entry.text` is `row.displayText`, which now incorporates `rewriteUserEdit` automatically (since we changed `displayText`).

---

## Schema-discipline checklist

Following `Jot/CLAUDE.md` §"Schema discipline":

- [ ] Create `Jot/Shared/Schema/JotSchemaV2.swift` (copy V1 + add field).
- [ ] Bump `versionIdentifier` in V2 to `Schema.Version(2, 0, 0)`.
- [ ] Append `JotSchemaV2.self` to `JotMigrationPlan.schemas`.
- [ ] Append `.lightweight(fromVersion: V1, toVersion: V2)` to `JotMigrationPlan.stages`.
- [ ] Bump `typealias Transcript = JotSchemaV2.Transcript` in `Jot/Shared/Transcript.swift`.
- [ ] Update `JotModelContainer.shared` in `TranscriptStore.swift` to `Schema(versionedSchema: JotSchemaV2.self)`.
- [ ] Run `xcodegen` from `Jot/`.
- [ ] Update `docs/schema-migrations.md` "Current versions" with V2 entry.
- [ ] Watch Console.app for `[SCHEMA-FALLBACK]` on the on-device upgrade test.
- [ ] Do NOT touch `JotSchemaV1.swift` (frozen).

---

## Verification

- **Build clean:** `xcodebuild -workspace … -scheme Jot build`.
- **Upgrade test:** install current build (V1), dictate ≥1 transcript, install new build (V2), open Detail, verify the transcript loads and the new Edit affordance works. Watch Console.app for `[SCHEMA-FALLBACK]` — it must NOT fire on a real-device upgrade.
- **Edit Original:** text changes propagate to Recents row, keyboard RecentsStrip after a keyboard re-present, share/copy reflect new text.
- **Edit Rewrite:** `rewriteUserEdit` written, displayText reflects it everywhere, `cleanedText` left intact (verify via debug query or a follow-up TestFlight assertion).
- **Re-Transform after edit:** Tap Transform → new cleanedText written, rewriteUserEdit cleared, Rewrite tab now shows new model output (not the prior edit).
- **Discard Rewrite:** both cleanedText and rewriteUserEdit nilled, tab disappears, Original visible.

---

## features.md updates

- **§7 (Transcript Detail)** — new feature line for "Edit Original" and "Edit Rewrite" + the persistence rule for each.
- **§13 (Storage)** — note that rewrites the user edits store the (model output, user edit) pair locally as a future-fine-tuning training signal. No remote upload.
- **§7.x rewrite section** — cross-link to the new edit feature; note that re-Transform clears any prior user-edit-against-the-prior-cleanedText.

---

## What changed from the prior version

Prior plan (committed as `1c90af5`) had:
- 3 new fields + a new `@Model` (`RewriteTrainingPair`) table with snapshot-on-overwrite machinery.
- Auto-regenerate-on-Original-edit with confirm gate ("Regenerate vs Keep my edits").
- `lastRewritePromptID` tracking so auto-regen picked the prior prompt.
- A revised `displayText` priority chain with FOUR fallbacks (`editedRewriteText ?? cleanedText ?? editedOriginalText ?? text`).

This plan has:
- 1 new field. No new entity.
- No auto-regen. No confirm gate.
- No prompt-id tracking.
- `displayText` has 3 fallbacks (`rewriteUserEdit ?? cleanedText ?? text`).

The simplification was driven by the user's intent statement: *"On original, we just save as if Parakeet was the original — we don't care. On rewrite, we save what Qwen produced and what the user changed it to. Last edit wins."*
