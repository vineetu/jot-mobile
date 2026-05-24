# Plan: Editable Transcripts + Auto-Regenerate + Training-Pair Persistence

> **Status:** Requested 2026-05-24. Confirmed scope: editable Original and Rewrite tabs in Transcript Detail; auto-regenerate Rewrite on Original edit (with confirm gate if user-edited Rewrite would be lost); persist `(modelOutput, userEdit)` pairs per Rewrite for future Qwen 3.5 4B fine-tuning.
> **Size: M-L** (~2-3 days, dominated by SwiftData schema bump + edit-mode UX + auto-regen plumbing).

---

## Requirements

### What user can do

- In Transcript Detail, tap **Edit** in the floating ActionBar → both tabs become editable. The currently-visible tab's text turns into a `TextEditor`; keyboard pops up; cursor positioned at end.
- Tap **Save (✓)** to commit; tap **Cancel** to discard in-progress changes.
- Editing **Original**:
  - If a Rewrite exists with **no prior user edits** → on Save, **auto-regenerate** the Rewrite using Articulate (the default prompt). Existing rewrite progress UI surfaces.
  - If a Rewrite exists with **user edits** → on Save, show a confirm dialog: *"Regenerate rewrite (your edits to the rewrite will be replaced) or keep my edits (rewrite stays as-is)."*
  - If no Rewrite exists → save persists, nothing to regenerate.
- Editing **Rewrite**:
  - On Save, persists `editedRewriteText`. Original/cleanedText untouched. No regeneration.
  - The (modelOutput = `cleanedText`, userEdit = `editedRewriteText`) pair is now the current training signal.
- Both edits are local and private. No UI exposes the training-pair data.

### Non-Goals

- Not surfacing edit history to the user (no version timeline, no undo-by-revision UI).
- Not collecting transcript (speech-model) training data. Edits to Original are corrections, not Parakeet fine-tuning input.
- Not running fine-tuning on-device. This plan only persists the pair data. A separate future pipeline reads it.
- Not changing the existing Transform/RewritePicker flow. Auto-regen reuses the same rewrite pipeline; it doesn't replace anything.
- Not multi-tab edit (can't edit Original and Rewrite simultaneously in one Save). One tab at a time.
- Not edit during recording (Edit is disabled while a recording is in progress).

---

## Design

### Data model (SwiftData additions) — revised after review

Three new fields on `@Model Transcript`:

```swift
/// User's manual edit to the Original transcript text. `nil` = no user
/// edit (the model's transcribed `text` is canonical). Non-nil = user
/// typed corrections.
var editedOriginalText: String?

/// User's manual edit to the current Rewrite (`cleanedText`). `nil` =
/// no user edit. Non-nil = user typed corrections. Cleared when the
/// rewrite is regenerated — the prior `(cleanedText, editedRewriteText)`
/// pair is snapshotted to `rewriteTrainingPairs` first (see below).
var editedRewriteText: String?

/// Last-used rewrite prompt id for THIS transcript. Auto-regen reuses
/// it so we don't surprise the user with a different prompt shape (per
/// review: "user edited because the prior rewrite was wrong; running a
/// DIFFERENT prompt produces yet another wrong shape"). `nil` for
/// transcripts whose `cleanedText` came from the cleanup pipeline (Apple
/// FM) rather than a Transform — those fall back to Articulate on
/// auto-regen.
var lastRewritePromptID: UUID?
```

Plus one new `@Model` for accumulated training pairs (separate table — review correctly flagged that storing the pair inline destroys data on the second Transform):

```swift
@Model
final class RewriteTrainingPair {
    var id: UUID
    var transcriptID: UUID                   // soft reference, no cascade
    var modelOutput: String                  // cleanedText at snapshot time
    var userEdit: String                     // editedRewriteText at snapshot time
    var promptID: UUID?                      // which prompt produced modelOutput
    var capturedAt: Date

    init(transcriptID: UUID, modelOutput: String, userEdit: String,
         promptID: UUID?, capturedAt: Date = .now) {
        self.id = UUID()
        self.transcriptID = transcriptID
        self.modelOutput = modelOutput
        self.userEdit = userEdit
        self.promptID = promptID
        self.capturedAt = capturedAt
    }
}
```

**Display logic** — narrowly scoped per review (must NOT change `displayText`, which the Recents list / mirror / keyboard consume):

```swift
// On Transcript:
// EXISTING — unchanged. Recents and keyboard continue to render this.
// Whenever a user edits Original AND a rewrite exists, we ALSO clear
// cleanedText (and snapshot to RewriteTrainingPair) so displayText stops
// being a lie. See "Original-edit invalidation" below.
var displayText: String { cleanedText ?? text }

// NEW — for the detail view's tabs only.
var displayOriginalText: String { editedOriginalText ?? text }
var displayRewriteText: String? { editedRewriteText ?? cleanedText }
```

### Training-pair accumulation (revised)

Per review: storing only the current `(cleanedText, editedRewriteText)` inline destroys data the moment the user re-Transforms. **Fixed:**

- Whenever `cleanedText` is about to be overwritten (auto-regen, manual Transform, etc.) AND `editedRewriteText` is non-nil, **snapshot** the existing `(cleanedText, editedRewriteText, lastRewritePromptID)` into a new `RewriteTrainingPair` row before the overwrite.
- Then clear `editedRewriteText = nil`, set `cleanedText = newOutput`, set `lastRewritePromptID = newPromptID`.
- `RewriteTrainingPair` rows accumulate across the transcript's lifetime — every iteration where the user corrected the model is preserved.
- A future fine-tuning pipeline reads `RewriteTrainingPair` across all transcripts to build the dataset.
- On `Transcript.delete()`: cascade-delete its `RewriteTrainingPair` rows (manual cascade since we use a soft `transcriptID` reference; do it in `TranscriptStore.delete`).

If user edits the Rewrite AND saves WITHOUT re-Transforming, the current `(cleanedText, editedRewriteText)` is "in-flight" — not yet snapshotted. We treat that as "the live pair" — the fine-tuning pipeline reads both the accumulated `RewriteTrainingPair` rows AND each transcript's current in-flight pair (if `editedRewriteText` is non-nil).

### Original-edit invalidation of `displayText`

Per review's load-bearing finding: if the user edits Original AND a rewrite exists AND we don't invalidate `cleanedText`, then the Recents row continues to render the stale `cleanedText` while the Detail view's Original tab shows the new edit. The Recents row is lying.

**Fix:**

On Save of Original edit (whether or not auto-regen triggers), if `cleanedText` exists:
1. **Snapshot** the current `(cleanedText, editedRewriteText, lastRewritePromptID)` to `RewriteTrainingPair` if `editedRewriteText` was non-nil (so the user's prior edit isn't lost).
2. **Clear** `cleanedText = nil` and `editedRewriteText = nil`.
3. Either trigger auto-regen (which will re-set `cleanedText`) OR — if user picked "Keep my edits" in the confirm dialog — leave both nil and let `displayText` fall back to `text` (which now resolves to `editedOriginalText` on the Detail view; the Recents row will show the un-edited `text` until the next dictation or until we surface a "needs regenerate" indicator).

Wait — that last case is bad. The Recents row would show the un-edited `text` because `displayText = cleanedText ?? text` and `cleanedText` is now nil. The user's edit isn't visible there.

**Revised display logic** to handle this cleanly:

```swift
// NEW — display priority for cross-surface consumers (Recents, mirror, etc.):
var displayText: String {
    editedRewriteText ?? cleanedText ?? editedOriginalText ?? text
}
```

This is the corrected `displayText`. Recents row shows: latest user edit to rewrite OR model's rewrite OR latest user edit to original OR raw text. Each successive fallback is "the most recent canonical state we know about."

This change DOES affect existing consumers — keyboard's `RecentsStrip`, ledger BFS, share mirror. Verify each call site renders correctly post-change.

### Cross-process mirror refresh — added per review

After any `editedOriginalText` or `editedRewriteText` save:
1. `try modelContext.save()`
2. `TranscriptHistoryMirror.refresh(from: modelContext)`
3. `CrossProcessNotification.post(name: .historyMirrorUpdated)`

Without these calls, the keyboard's recents strip renders the pre-edit text until the next dictation refreshes the mirror.

### Schema migration — versioned per review

Adding three new fields to `Transcript` (`editedOriginalText`, `editedRewriteText`, `lastRewritePromptID`) PLUS a brand-new `RewriteTrainingPair` `@Model`. Lightweight migration claims for additive optionals are not bulletproof on SwiftData — review correctly flagged that the first production schema change is the riskiest place to assume the happy path.

**Decision:** introduce explicit `VersionedSchema` + `SchemaMigrationPlan` now, as part of this PR.

```swift
enum JotSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [TranscriptV1.self]
    // TranscriptV1 = current shape (text, cleanedText, createdAt, durationSeconds, ledgerIndex, derivedFromID, instruction, supersededAt)
}

enum JotSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [Transcript.self, RewriteTrainingPair.self]
    // Transcript = V1 + editedOriginalText + editedRewriteText + lastRewritePromptID
}

enum JotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [JotSchemaV1.self, JotSchemaV2.self]
    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: JotSchemaV1.self, toVersion: JotSchemaV2.self)
    ]
}

// In TranscriptStore.swift:
let config = ModelConfiguration(
    "JotTranscripts",
    schema: Schema(versionedSchema: JotSchemaV2.self),
    groupContainer: .identifier(AppGroup.identifier),
    cloudKitDatabase: .none
)
return try ModelContainer(
    for: Schema(versionedSchema: JotSchemaV2.self),
    migrationPlan: JotMigrationPlan.self,
    configurations: [config]
)
```

Lightweight stage suffices because:
- All `Transcript` additions are optional (nil-default).
- `RewriteTrainingPair` is a brand-new entity (no migration needed for new entities in SwiftData).

This also lays groundwork for future schema changes; D1's UserDefaults migration runner doesn't help here.

**Backup compatibility:** new fields are still in the same SwiftData store at the same App Group path — backup behavior unchanged.

### Edit-mode UX

**Read mode (current default), no changes to existing layout:**

```
ActionBar:
  Leading:  [Copy] [Share]
  Primary:  Transform (sparkles, blue pill)
  Trailing: [Edit (pencil)] [Delete]
```

The new Edit pencil icon is the only addition. Sits next to Delete on the trailing side — both are "modify the entry" actions, fitting semantic group.

**Edit mode (after tapping Edit):**

```
ActionBar:
  Leading:  [Cancel (xmark)]
  Primary:  Save (✓, blue pill — same primary slot as Transform)
  Trailing: (empty — Delete/Transform don't apply mid-edit)
```

The text area for the currently-visible tab transforms from `Text` (or whatever rendering view) into a `TextEditor` with the same font/styling. The keyboard pops up. Cursor placed at end of existing text. User can edit freely.

**On tap Save:**
- Compute whether the text actually changed (avoid no-op writes).
- If unchanged: just exit edit mode, no save.
- If changed in Original tab:
  - Set `transcript.editedOriginalText = newText`.
  - Decide: trigger auto-regen, OR show confirm dialog, OR skip (no rewrite exists).
- If changed in Rewrite tab:
  - Set `transcript.editedRewriteText = newText`.
  - No regen.
- Exit edit mode; ActionBar restores to read shape.

**On tap Cancel:**
- Discard in-progress text changes (revert TextEditor to last-saved state).
- Exit edit mode; ActionBar restores to read shape.
- No iOS-native undo prompt; if user accidentally tapped Cancel, the loss is one edit session.

**Edit mode is exclusive to one tab at a time.** Switching tabs while in edit mode either:
- (a) Auto-saves the current tab's edit then enters edit mode on the other tab; OR
- (b) Locks the tab switcher while editing (greyed out).

**Recommendation: (b) lock the tab switcher.** Simpler, no surprise auto-save semantics. Switching mid-edit is a niche case.

### Auto-regenerate logic — revised per review

**Auto-regen uses `lastRewritePromptID`, not Articulate-as-default.** Review correctly flagged: user edited the Original because the prior rewrite was wrong; auto-regenerating with a DIFFERENT prompt produces a different-shape wrong rewrite, not what they wanted. Reusing the last prompt preserves their intent.

When user saves an Original edit AND a Rewrite exists:

```swift
// Pseudocode in TranscriptDetailView's saveOriginalEdit handler
if transcript.cleanedText != nil {
    if transcript.editedRewriteText != nil {
        // Prior edits to the Rewrite would be lost. Confirm first.
        showRegenConfirmDialog = true
        // Dialog actions:
        //   "Regenerate" → snapshot pair into RewriteTrainingPair,
        //                  clear editedRewriteText + cleanedText,
        //                  trigger regen with lastRewritePromptID
        //   "Keep my edits" → snapshot pair into RewriteTrainingPair (still
        //                     valuable training data even though we're keeping),
        //                     leave cleanedText + editedRewriteText alone,
        //                     no regen
    } else {
        // No user edits to lose; auto-regen silently.
        snapshotTrainingPairIfNeeded()  // no-op since editedRewriteText is nil
        triggerAutoRegen()
    }
}
```

`triggerAutoRegen`:
- **Critical fix per review:** the rewrite input is `transcript.displayOriginalText` (the user's edit), not `transcript.text` (the raw model output). The current code at `TranscriptDetailView.swift:776` has `rewriteSourceText: transcript.text` — this MUST be updated to `displayOriginalText`, otherwise auto-regen runs against the un-edited text and the entire feature is a no-op for its headline scenario.
- Clears `cleanedText = nil` and `editedRewriteText = nil`.
- Calls the existing Qwen rewrite pipeline with the prompt at `lastRewritePromptID` (resolved from `SavedPromptStore`). If `lastRewritePromptID == nil` (legacy data or cleanup-only output), fall back to Articulate.
- The existing rewrite progress card (per `features.md §3.6`) surfaces during regen, with Cancel.
- On completion: `cleanedText = newRewriteOutput`, `lastRewritePromptID = promptID` (re-stamped).
- After save: refresh mirror + post `historyMirrorUpdated`.

### Edit-during-recording lockout — revised per review

Disable the Edit button (greyed out) while ANY of the following are true:
- `recordingService.isRecording == true`
- `isInflightPostRecording` (transcribe / process / cleanup tail)
- Chained follow-up window is active (within 30s of last dictation finishing) — per `features.md §2.11`. The 30s window is a real concern because a follow-up dictation could arrive WITHOUT a visible recording UI, and if it does, it might mark this transcript as superseded mid-edit.

Accessibility hint: *"Editing is unavailable while a recording is in progress or within 30 seconds of finishing one."*

**If transcript becomes superseded mid-edit** (chained follow-up arrived): show a confirm-discard dialog *"A follow-up dictation replaced this transcript. Discard your unsaved edits and view the replacement?"* Don't silently lose edits.

### Stale-Rewrite indicator (after "Keep my edits")

If the user chose "Keep my edits" in the confirm dialog, the Rewrite is now technically stale relative to the edited Original. We do NOT show a "stale" badge per `keep it simple` direction. The user knows what they did. If they want to refresh, they re-Transform manually.

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. Add `editedOriginalText`, `editedRewriteText`, `lastRewritePromptID` fields to `Transcript` | `Jot/Shared/Transcript.swift` | XS |
| 2. New `RewriteTrainingPair` `@Model` (id, transcriptID, modelOutput, userEdit, promptID, capturedAt) | `Jot/Shared/RewriteTrainingPair.swift` (new) | XS |
| 3. Versioned schema (V1 = current, V2 = new) + SchemaMigrationPlan (lightweight) | `Jot/Shared/TranscriptStore.swift` | S |
| 4. Update `displayText` to new priority: `editedRewriteText ?? cleanedText ?? editedOriginalText ?? text`. Add `displayOriginalText`, `displayRewriteText` | `Jot/Shared/Transcript.swift` | XS |
| 5. Audit all `displayText` consumers (Recents row, ledger BFS, keyboard mirror, share extension) to verify no regression | `Jot/App/Recents/`, `Jot/App/TranscriptDetailView.swift`, `Jot/Shared/TranscriptHistoryMirror.swift`, keyboard | S |
| 6. **CRITICAL FIX:** update `rewriteSourceText` at `TranscriptDetailView.swift:776` to use `transcript.displayOriginalText`, not `transcript.text`. Same for `bodyTextForActiveTab` (line 805) and `sourceWordCount` (line 775) where they feed user-facing surfaces. | `Jot/App/TranscriptDetailView.swift` | S |
| 7. Cascade-delete `RewriteTrainingPair` rows when a `Transcript` is deleted | `Jot/Shared/TranscriptStore.swift:delete` | XS |
| 8. Edit mode state in TranscriptDetailView: `@State isEditing: Bool`, `@State editBuffer: String`, `@FocusState editorFocused: Bool` | `Jot/App/TranscriptDetailView.swift` | S |
| 9. Conditional render: `Text` vs `TextEditor` based on `isEditing` AND `selectedTab` | `Jot/App/TranscriptDetailView.swift` (around line 178) | M |
| 10. ActionBar swaps between read and edit shapes | `Jot/App/TranscriptDetailView.swift:635` | S |
| 11. Wire Edit button: enter edit mode, populate `editBuffer` with `displayOriginalText`/`displayRewriteText`, focus | `Jot/App/TranscriptDetailView.swift` | S |
| 12. Wire Save: write to `editedOriginalText`/`editedRewriteText`, snapshot to `RewriteTrainingPair` if needed, save, refresh mirror, post notification | `Jot/App/TranscriptDetailView.swift` | M |
| 13. Wire Cancel: discard `editBuffer`, exit edit mode | `Jot/App/TranscriptDetailView.swift` | XS |
| 14. Auto-regen on Original save: snapshot pair, clear, run Qwen with `lastRewritePromptID` (or Articulate fallback) using `displayOriginalText` as input | `Jot/App/TranscriptDetailView.swift` + existing `Qwen35Client` | M |
| 15. Confirm dialog UI (regenerate / keep edits) on Original save when `editedRewriteText` non-nil | `Jot/App/TranscriptDetailView.swift` | S |
| 16. Tab switcher lock while in edit mode | `Jot/App/TranscriptDetailView.swift:379` | XS |
| 17. Edit button disabled during recording + within 30s follow-up window | `Jot/App/TranscriptDetailView.swift` | XS |
| 18. Supersession-mid-edit confirm dialog | `Jot/App/TranscriptDetailView.swift` | S |
| 19. Update `features.md §3` for Edit affordance + edit mode semantics | `Jot/features.md` | S |
| 20. Tests (manual on-device + simple debug print of training pair count) | manual + small `print` in Save handler | S |

**Total size: L** (~3-4 days). Larger than original estimate due to schema versioning, training-pair table, mirror-refresh, `displayText` audit, and the `rewriteSourceText` fix.

### Open implementation decisions

These ARE NOT optional questions — the implementation needs to pick one each before coding:

- **Empty-text save in Original:** allow as a valid edit (persists empty string)? Or treat empty as "revert to model output" (set field to nil)? Default to "allow as valid edit"; user can manually re-type if they want the model's version back.
- **Back-swipe during edit:** discard silently OR confirm-dismiss? Default: confirm-dismiss if `editBuffer != currentText`. Less surprising.
- **Auto-save draft on app background:** No, v1 ships without draft persistence. If iOS kills the app mid-edit, the edit is lost. Surface this in copy via a subtle "Tap Save to commit" hint near the Save button (or omit if it feels too much).

---

## Edge Cases

- **Empty text after edit.** User clears all text and taps Save. Treatment: allow it. Original becomes empty (rare but possible — user might want to delete content). For Rewrite, treat empty as "I don't want a rewrite" — could set both `cleanedText` and `editedRewriteText` to nil. Confirm with you which behavior you want.
- **Edit conflicts with chained follow-up.** Per `features.md §2.11`, a follow-up dictation within 30s creates a derived transcript. If the user is editing the parent transcript when a follow-up arrives, the edit-mode lockout (Step 13) suppresses Edit availability during recording, but if the recording lands BEFORE the user enters edit mode, the user could enter edit on a transcript that's about to be marked superseded. Mitigation: on `transcript.supersededAt` becoming non-nil, exit edit mode if active. Surface a banner: *"This transcript was replaced by a follow-up. Edits saved to the original."*
- **Auto-regen during another rewrite already in flight.** If user is editing transcript A's Original while a different transcript's Transform is already running, the Qwen client serializes — cancel the existing rewrite or queue? **Recommendation:** queue. The auto-regen for A waits for the in-flight rewrite to finish, then runs.
- **Save fails (SwiftData write error, disk full, etc.).** Surface a banner via existing status-banner mechanism. Keep user in edit mode so they can re-attempt. Don't silently exit edit mode.
- **User navigates away mid-edit.** Two options:
  - (a) Discard the in-progress edit (treat back-swipe as Cancel).
  - (b) Auto-save the in-progress edit (treat back-swipe as Save).
  - **Recommendation: (a) discard.** Matches the existing iOS pattern (e.g. Notes shows a confirm). Optionally: confirm on back-swipe if there are unsaved changes.
- **Transcript deleted while in edit mode.** Race: user is editing, another path deletes the transcript. Exit edit mode + dismiss detail view + show "Transcript deleted" toast. Defensive; rare.
- **Edit Rewrite when no Rewrite exists.** Edit button enabled in Rewrite tab only if `cleanedText` is non-nil. Otherwise hide/disable.
- **Long transcripts.** `TextEditor` handles them fine; scroll-within-editor works natively.
- **Voice-over support.** Edit button announced as button; Save button announced as button. TextEditor itself is VoiceOver-readable.

---

## Test Plan

1. **Fresh install — edit Original.** Dictate something; tap Edit; change text; tap Save. Verify Original tab shows edited text; raw `text` field unchanged.
2. **Fresh install — edit Rewrite.** Dictate; Transform (manual); tap Edit on Rewrite tab; change; Save. Verify Rewrite shows edited; `cleanedText` field unchanged.
3. **Auto-regen path.** Dictate, Transform, then edit Original. No prior edit to Rewrite. Save → regen runs silently → new Rewrite appears.
4. **Confirm-dialog path.** Same as #3 but first edit the Rewrite, then edit the Original. Save Original → dialog appears. Pick "Regenerate" → Rewrite replaced. Repeat, pick "Keep my edits" → Rewrite unchanged.
5. **Cancel discards.** Enter edit, change text, tap Cancel → text reverts to pre-edit.
6. **Tab switcher locked.** Enter edit on Original. Try to tap Rewrite tab → no-op. Visual indication (greyed out) that it's locked.
7. **Edit disabled during recording.** Start a recording (FAB → Hero). Background hero, navigate to detail view → Edit button greyed.
8. **Schema upgrade.** Install current build (1.0.2 b5) → dictate transcripts → upgrade to this new build → open detail view → verify existing transcripts load and edit fields are nil.
9. **Training pair preserved.** Edit a Rewrite. Verify `cleanedText` is unchanged in the underlying store, `editedRewriteText` has the user's edit. (Inspect via Xcode's SwiftData debugger or a print.)
10. **Empty text edit.** Edit and clear all text, Save. Verify behavior matches the decided spec (probably "edit fields stored as empty string, displayText falls back").
11. **VoiceOver.** Walk through edit mode with VoiceOver on.
12. **Reduce motion.** No animation regressions.

---

## Open Questions

1. **Empty edit handling.** Allow empty save? Or treat empty as "no user edit" (set field to nil, fall back to model output)? **Recommendation:** empty IS a valid user edit; persist as empty string. If user wants to revert to model output, we could add a "Revert to AI version" affordance later.
2. **Back-swipe during edit.** Discard (current rec) or confirm-prompt? Notes does confirm. Could go either way.
3. **Auto-regen prompt choice.** Always Articulate (current rec) or remember last-used prompt? Per-transcript prompt tracking is one more schema field but more accurate.
4. **Should the trained-pair stale-marker show when the user picked "Keep my edits"?** Current rec: no, keep simple. If user behaviour shows confusion in the future, add a subtle "rewrite based on previous original" badge.
5. **Long-press menu on the displayed text** in read mode — does iOS still surface "Copy / Share / Look Up" etc.? Should still work since we keep `Text` rendering with `.textSelection(.enabled)` in read mode. Just confirm not broken.

---

## Cross-Links

- Touches: `Jot/Shared/Transcript.swift` (schema), `Jot/App/TranscriptDetailView.swift` (UX), `Jot/App/Design/Components/ActionBar.swift` (no changes; existing API supports Edit), `Jot/App/LLM/Qwen35Client.swift` (existing rewrite call; reused), `Jot/features.md §3`
- Related: [icloud-backup-verification.md](./icloud-backup-verification.md) — the schema bump here must stay backup-friendly (additive optionals are inherently fine)
- Related: [migration-system.md](./migration-system.md) D1 — D1 covers UserDefaults migrations; SwiftData has its own model. This schema bump is the first real test of SwiftData migration in production for Jot.
- Future: a fine-tuning pipeline that reads `rewriteTrainingPair` across all transcripts to produce a Qwen LoRA — separate effort, not in this plan.
