# Bug Plan: User-Created Prompts Have No Before/After Preview

> **Source:** [features.md §14.4](../../Jot/features.md#14-4-new-user-created-prompts-have-no-beforeafter-preview-in-the-list)
> **Status:** Deterministic, fully understood. **Confidence: 95%.** Plan revised after adversarial review tightened several edge cases.

---

## Symptom (recap)

Each bundled default prompt in Settings → AI Rewrite (Articulate, AI prompt, Action Items, Email) renders with a hardcoded mini before→after sample directly inside its row. User-created prompts show only icon + name + a one-line preview of the system prompt — no before/after sample.

## Root cause

`Jot/App/Settings/AIRewriteSettingsView.swift:581-627` switches on `prompt.defaultKind` to render the sample. User-created prompts have `defaultKind == nil` → no sample case applies → row falls back to the "preview of system prompt" path. Line 637 returns `nil` for `beforeText` for user prompts.

The "Try this prompt" footer pill in the prompt editor (`EditPromptWithTestSheet.swift`) already runs prompts against a real recording — but the result isn't persisted anywhere.

## Goal

Persist the most recent (before, after) pair produced by the "Try this prompt" footer for each user-created prompt. Render it in the list row using the same component path as the bundled defaults. Fall back to the current "first-line of system prompt" preview when no try-run has happened yet.

## Non-Goals

- Not capturing every try-run — only the most recent.
- Not capturing across reinstalls (the dictation source needs to still exist in the user's library).
- Not auto-generating a sample for new user prompts.

---

## Design

### Storage shape

Add to `SavedPrompt`:

```swift
struct SavedPromptSample: Codable, Equatable {
    let beforeText: String       // truncated; see below for byte-aware truncation
    let afterText: String
    let runAt: Date
    /// Stable model identifier (rawValue of the model enum), NOT the
    /// localized display name. Resolved to display name at render time
    /// via the same lookup the model strip + Prompt Picker use.
    let modelID: String
}

struct SavedPrompt: Codable, Identifiable {
    // ...existing fields...

    /// Most recent before/after pair from the Try-This footer.
    /// Optional — set only after the user has run the prompt at least once
    /// in the editor. Bundled defaults always have `lastSample == nil`
    /// (their samples are hardcoded in the render code).
    var lastSample: SavedPromptSample?
}
```

**Forward-compat fix:** the original draft stored `modelName: String` as a display string ("Qwen 3.5"). When display labels change ("Qwen 3.5 (legacy)"), persisted samples would render with the old name. Storing `modelID` (the enum rawValue) and resolving at render time keeps attribution truthful across model-rename events.

**Truncation: byte-aware.** Original draft used `String(beforeText.prefix(300))` — grapheme-count safe but unbounded in UTF-8 storage size for emoji-heavy text. Replace with:

```swift
// Truncate to a logical-character limit but also cap UTF-8 bytes at 1200
// so emoji-heavy samples can't blow up the JSON size.
extension String {
    func truncatedForSample(maxChars: Int = 300, maxBytes: Int = 1200) -> String {
        var s = String(self.prefix(maxChars))
        while s.utf8.count > maxBytes, !s.isEmpty {
            s = String(s.dropLast())
        }
        return s
    }
}
```

### Capture hook — handles the cancel-after-test case

Original draft saved the sample on successful Try-This run. Adversarial review flagged: if the user runs Try-This, then tweaks the system prompt without saving, then cancels the editor (doesn't persist the prompt-text change), the saved `lastSample` reflects a system-prompt that doesn't exist on the persisted prompt. Subsequent renders would be misleading.

**Fix:** capture the sample alongside a **snapshot of the system prompt at the moment of the Try-This run**. Persist only if the run matches the **currently-saved** prompt text — or, more cleanly, persist as an in-memory candidate and commit to disk only on `Save` of the editor.

```swift
// In EditPromptWithTestSheet
@State private var pendingSample: SavedPromptSample?

// On successful Try-This run:
pendingSample = SavedPromptSample(
    beforeText: beforeText.truncatedForSample(),
    afterText: afterText.truncatedForSample(),
    runAt: .now,
    modelID: currentRewriteModelID  // enum rawValue
)

// On editor Save action:
if let sample = pendingSample {
    // Match: the system prompt at sample.runAt must equal the system prompt
    // we're about to save. If user edited between Try-This and Save, drop the sample.
    if sampleSystemPromptSnapshot == promptToSave.systemPrompt {
        promptToSave.lastSample = sample
    }
    // else: silently drop. The user will need to re-run Try-This after saving.
}
// (User cancels the editor → pendingSample dies in @State, never persisted)

// Correct API: SavedPromptStore.update(_ promptToSave) — NOT save(prompt:)
SavedPromptStore.update(promptToSave)
```

**Corrected API name.** Original draft called `SavedPromptStore.save(prompt)` — that method doesn't exist (the real signature is `save(_ prompts: [SavedPrompt])`). The right call is `SavedPromptStore.update(_ prompt:)` at `SavedPromptStore.swift:139`.

### System-prompt edit invalidation — when exactly?

Original draft said "invalidate on system-prompt edit" without specifying detection. Adversarial review flagged: invalidating on every keystroke is wrong (too eager), invalidating only on Save misses the test case where user runs Try-This against a not-yet-saved edit then cancels.

**Resolution:** the snapshot-match check above handles it cleanly:

- User opens editor, sample exists (`lastSample != nil`).
- User edits system prompt → in-memory only.
- User runs Try-This → `pendingSample` captured with snapshot of the current edited text.
- User taps Save → if edited text matches `pendingSample`'s snapshot, sample persists. The pre-existing `lastSample` (from a prior run against the old text) is replaced.
- User taps Cancel → `pendingSample` and edits both discarded. Pre-existing `lastSample` stays as it was.

No keystroke-level eager invalidation needed.

### Render

Extract `BeforeAfterSampleView` as a reusable component (currently exists implicitly inside the switch at `AIRewriteSettingsView.swift:581-627`). Render path:

```swift
if let defaultKind = prompt.defaultKind {
    // Existing switch on defaultKind for bundled samples — unchanged
} else if let sample = prompt.lastSample {
    BeforeAfterSampleView(
        before: sample.beforeText,
        after: sample.afterText,
        modelName: ModelIdentifier(rawValue: sample.modelID)?.displayName ?? "AI",
        capturedAt: sample.runAt
    )
} else {
    // Existing one-line system-prompt preview — unchanged
}
```

### Keyboard impact

`SavedPrompt` is read by both the main app's settings UI AND the keyboard's saved-prompt picker. The keyboard cap at ~60 MB makes this relevant — adding `lastSample` (up to ~2.4 KB per prompt × N prompts) per-process is real.

**Decision:** the keyboard does NOT render `lastSample`. The keyboard's prompt picker (small popover) shows name + icon only; the before/after sample is too large for that UI anyway. To avoid loading sample data into the keyboard process at all, we can either:
- **Option a:** add a separate `SavedPromptStore.allForKeyboard()` API that returns prompts with `lastSample = nil` after decode. Costs a duplicate decode path.
- **Option b:** keep one store, accept that the keyboard process holds the sample data in memory but never renders it. Costs ~2 KB × N prompts of dead memory.

**Recommendation:** Option b for simplicity. With a typical 4-8 user prompts, this is 10-20 KB total — well below the 60 MB ceiling. Revisit if prompt counts grow large.

### Codable migration test

The change is additive. `lastSample` is optional in the struct, so Swift's synthesized `Codable` decoder tolerates missing keys at decode time. But **must verify** with an explicit test:

```swift
func testDecodeFromOldFormatWithoutLastSample() {
    let oldJSON = """
    { "id": "...", "name": "Email", "systemPrompt": "...", "iconKey": "envelope", "createdAt": "...", "sortOrder": 1 }
    """.data(using: .utf8)!
    let prompt = try JSONDecoder().decode(SavedPrompt.self, from: oldJSON)
    XCTAssertNil(prompt.lastSample)
}
```

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. Add `SavedPromptSample` + `lastSample` field | `Jot/Shared/SavedPrompt.swift` | XS (~30 min) |
| 2. Add `truncatedForSample(maxChars:maxBytes:)` extension | `Jot/Shared/SavedPrompt.swift` | XS (~15 min) |
| 3. Wire pending-sample capture + match-on-save | `Jot/App/Settings/EditPromptWithTestSheet.swift` | S (~1-2 hours) |
| 4. Extract `BeforeAfterSampleView` reusable component | `Jot/App/Settings/AIRewriteSettingsView.swift` | S (~1 hour) |
| 5. Add user-prompt branch to render selector | `Jot/App/Settings/AIRewriteSettingsView.swift:581+` | XS (~30 min) |
| 6. Use `SavedPromptStore.update(_)` (correct API) | (touched in step 3) | included |
| 7. Codable migration test | `Jot/Tests/SavedPromptStoreTests.swift` | XS (~30 min) |
| 8. Edit/cancel/save flow tests | `Jot/Tests/SavedPromptStoreTests.swift` | S (~1 hour) |

**Total: S–M** (~half a day).

---

## Edge Cases

- **User runs Try-This but cancels mid-stream.** No `pendingSample` set (incomplete run). Pre-existing `lastSample` untouched.
- **User runs Try-This, then deletes the source dictation.** The before-text is a string snapshot, not a reference. Sample survives the source deletion.
- **User runs Try-This, edits system prompt, taps Save.** `pendingSample.snapshot != saved system prompt` → sample dropped. User must re-run.
- **User runs Try-This, taps Save without editing.** Snapshot matches → sample persists.
- **User runs Try-This against an existing prompt with a previous sample.** New `pendingSample` is candidate; on Save it replaces the old `lastSample`. If user cancels, old `lastSample` stays.
- **User renames the prompt.** Sample stays (no semantic change).
- **Truncation cuts mid-grapheme.** `String.prefix(N)` operates on grapheme boundaries (safe). Ellipsis appended if truncated.
- **Sample contains text the user later regrets.** Add a context-menu "Clear sample" on the prompt row. Size: XS extra.
- **Model name in `lastSample.modelID` for a model that's been removed** (we drop a rewrite model in a future build). Render falls back to `"AI"` placeholder. Historical attribution remains best-effort.
- **Keyboard process reads `SavedPrompt` with `lastSample` set.** Loaded but not rendered. ~2 KB per prompt of dead memory. Accepted (Option b above).

---

## Test Plan

1. Create a user prompt → row shows system-prompt fallback (no sample yet).
2. Open editor, run Try-This → tap Save → row now shows before/after.
3. Open editor again, edit system prompt mid-session, run Try-This, tap Save → row shows new sample with new system prompt.
4. Open editor, edit system prompt (no Try-This run), tap Cancel → row unchanged, no sample regression.
5. Open editor, run Try-This, edit system prompt after, tap Save → snapshot mismatch → sample dropped, row falls back to system-prompt preview.
6. Delete the source dictation from the library → row continues to render the captured sample.
7. Bundled defaults still render their hardcoded samples unchanged.
8. Visual: before/after for user-created prompts uses identical layout/styling as bundled defaults.
9. Long emoji-heavy sample (the bytes-cap test) → truncated cleanly, no JSON bloat.
10. Codable decode of old-format JSON (no `lastSample` field) → decodes with `lastSample == nil`.
11. Keyboard prompt picker — visually unchanged; reads the same store but only renders name + icon.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#b4--user-prompt-no-preview](./open-questions-deep-dive.md#b4--user-prompt-no-preview).

1. **Snapshot match logic — strict equality on system prompt, or fuzzy (e.g. trim whitespace)?** Strict is predictable. Recommend strict.
2. **Context-menu "Clear sample" affordance.** Useful if a user wants to drop a regrettable sample. Recommend yes for v1.1 if user feedback asks; defer.
3. **Should the row show a small re-generate button** so the user can refresh the sample without opening the editor? Saves a tap; adds chrome. Recommend no — re-generation requires picking a recording, which is editor-shaped.

---

## Cross-Links

- Storage: `Jot/Shared/SavedPrompt.swift`, `Jot/Shared/SavedPromptStore.swift` (correct API: `update(_)` at line 139)
- Render: `Jot/App/Settings/AIRewriteSettingsView.swift:581-627`
- Capture: `Jot/App/Settings/EditPromptWithTestSheet.swift` (Try-This footer)
- Related: §7.7 (saved prompt management — this bug is a sub-feature inside that surface)
