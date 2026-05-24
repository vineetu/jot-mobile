# Plan: Transcript Titles and Tags

> **Sources:** [features.md §3.2](../../Jot/features.md#3-2-transcript-metadata), [features.md §7.11](../../Jot/features.md#7-11-ai-settings-copy-discrepancy--titles-and-tags)
> **Status:** Aspirational. AI Settings advertises titles+tags via "the system's built-in AI"; no UI exists; §3.2 explicitly notes "title and tag fields are intentionally absent from v1."
> **Note:** This revision folds adversarial-review findings — the original draft missed that `Transcript` is SwiftData `@Model`, which makes adding `title` a real schema-migration concern; and the "delete" path is weighted more honestly.

---

## Problem

AI Rewrite settings shows the footnote *"Titles and tags use the system's built-in AI automatically."* But:

- No title appears in the [Transcript Detail view](#3-transcript-detail) header.
- No title appears in the [home library row](#1-2-transcript-library-with-time-grouping).
- No tag chips appear anywhere.
- Transcripts have no title or tag field on the storage model.

The footnote is currently aspirational at best, false at worst. §3.2 says fields are "intentionally absent" — i.e. v1 deliberately ships without — which suggests this was a deferred feature, not a forgotten one.

Apple's `FoundationModels` framework **is** already linked and used (see `Jot/App/Cleanup/CleanupService.swift:1-2`) for the Shortcuts cleanup pass. Calling FM from the main app is established. But **the keyboard extension cannot link FoundationModels** (`Jot/CLAUDE.md`), and dictations that complete during warm-hold may run with Jot in the background — so the "when does title generation actually run" question is more involved than "fire and forget."

**Note on the §7.11 "caveat" rule.** `Jot/CLAUDE.md` is explicit: §7.11 is a deliberately preserved "visible-copy-with-caveat" entry that documents what the user sees. Whichever path we pick — delete or build — the actual visible string in `AIRewriteSettingsView.swift` must change together with the §7.11 entry. They can't drift.

## Storage model reality

`Jot/Shared/Transcript.swift:31-32` is `@Model final class Transcript` — SwiftData, not a Codable struct. Adding a new optional property requires schema versioning. Pre-launch the user has explicitly accepted "wipe and rebuild" (memory `feedback_prelaunch_migrations`), but adding `title: String?` post-launch needs a `VersionedSchema` + `SchemaMigrationPlan`.

**This couples this plan to [docs/plans/migration-system.md](./migration-system.md):** the deferred generic migration system handles UserDefaults / app-state migrations but does NOT cover SwiftData schema bumps. For SwiftData we'd want a sibling pattern — registered `VersionedSchema` snapshots with a `SchemaMigrationPlan` between them. Either:
- Build the SwiftData versioning together with D1, then this plan, OR
- Ship this plan pre-launch with explicit "wipe-on-update" acceptance and revisit post-launch.

## Goal

- **Decide:** delete the §7.11 footnote, or build titles.
- Tags are out of scope; not a deferred-build, just not a feature in any plan today.

## Non-Goals

- Not adding user-editable titles in v1 of "build it" path — auto-generated only, user-editable in a v2.
- Not adding tag filtering or tag-grouped library views — that's a v3 feature.
- Not switching the home library from chronological to title-keyed organization.

---

## Three Options (Phase 0 — pick one)

| Path | Size | What ships | What we lose |
|---|---|---|---|
| **A. Delete** | XS | §7.11 footnote in `AIRewriteSettingsView.swift:171-526` removed. §3.2 + §7.11 entries deleted from features.md. | Loses the value of titles. User keeps the §3.2 "no titles v1" reality. |
| **B. Build titles only** | M (build) + S (SwiftData migration scaffolding) = ~2 days | Titles via Apple FM. Library row + detail header. No tags. | Coupled to SwiftData versioning work. Apple-Intelligence-off devices see no titles. |

Tags are intentionally out of scope. If you ever want them, that's a separate planning conversation — taxonomy alone (free-form vs. closed-set, search semantics, chip rendering) is its own design problem.

### Honest weighting

The original draft pivoted past A too fast. **A is the right answer until there's evidence users want titles** — and there isn't any in the current support / feedback log. Reasons to take A:

- No user has asked for titles. §3.2 explicitly intends them absent for v1.
- The build path forces SwiftData versioning work to happen now, which the D1 plan deliberately defers.
- The pre-launch overwrite policy means a "build" today is OK to wipe data, but a build *just before App Store ship* would force the versioning work anyway. Either build it well or don't ship.
- Removing the footnote is honest UX: don't promise what isn't built.

**Recommendation:** ship **A** unless the user explicitly wants titles. The plan below documents **B** in case the user picks build; **C** stays as a sketch only.

---

## Phase 0 — Pick a path. **Requires user decision.**

If **A (delete)**:
- Edit `Jot/App/Settings/AIRewriteSettingsView.swift:171` (already accurate, no change needed) AND any other "titles and tags use the system AI" copy (grep for "titles" + "tags" in the Settings + Help surfaces) — remove every mention.
- Update `features.md`: remove §7.11 entirely, update §3.2 to drop "title and tag fields are intentionally absent from v1" since the absence is no longer "intentional" — it just is. The cleaned §3.2 reads: "The detail view has no title surface."
- Done. **Size: XS (~30 min).**

If **B (build titles only)**: proceed to Phase 1.

---

## Phase 1 — Build titles. **Size: M + S (SwiftData) ≈ 2 days.**

### SwiftData migration

Adding `title: String?` to `@Model class Transcript`:

```swift
// Jot/Shared/Transcript.swift
@Model final class Transcript {
    var id: UUID
    var text: String
    var cleanedText: String?
    var createdAt: Date
    var durationSeconds: Double?
    var ledgerIndex: Int
    // ... existing fields ...

    var title: String?              // NEW
    var titleGeneratedAt: Date?     // NEW — null = never generated; allows re-gen detection
}
```

**Migration:**
- Pre-launch (current): always-overwrite policy applies. New field is added; existing in-memory data is rebuilt on every launch per memory `feedback_prelaunch_migrations`. No formal `SchemaMigrationPlan` needed because every launch starts from a fresh schema. **Caveat:** verify whether the SwiftData ModelContainer creation respects "always-rebuild" or whether it will refuse to load a schema-bumped container without an explicit migration plan. If the latter, we need a minimal `SchemaMigrationPlan` even for the pre-launch path. **Spike this before committing.**
- Post-launch: requires a `VersionedSchema` declaration plus a `SchemaMigrationPlan` with a `MigrationStage` between schema v1 and v2. SwiftData lightweight migration handles `String?` additions automatically, so the stage can be `.lightweight(...)`. No data backfill needed (title is nil for old entries; the generator runs lazily on access).

### Title generation

Generator service (`Jot/App/Cleanup/TitleGenerator.swift` — new, mirrors `CleanupService`):

```swift
@MainActor
enum TitleGenerator {
    enum Failure: Error { case unavailable, refused, timeout }

    static func generate(for transcript: Transcript) async throws -> String {
        guard #available(iOS 18.1, *),
              SystemLanguageModel.default.availability == .available else {
            throw Failure.unavailable
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let prompt = """
        You are titling a voice memo. Read the transcript and return a 3-7 word title \
        that captures the topic. No quotes, no punctuation, no leading article. Output \
        the title only — nothing else.

        Transcript:
        \(transcript.text)
        """
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### Generation lifecycle (cross-process aware)

The keyboard extension cannot call FM. So title generation must happen in the **main app process**. Three trigger states:

1. **Foreground dictation finishes** (recording hero, in-app dictate). Trigger immediately after `DictationPipeline.finalize()`. FM call runs in main app — already foreground.
2. **Background dictation finishes** (warm-hold path, keyboard-initiated, host app on top). Per `features.md §13.2`, the main app is running but backgrounded. FM calls from a backgrounded app are subject to background task limits. Either:
   - (a) Queue the title-generation request in App Group, run it the next time Jot foregrounds.
   - (b) Try to run immediately; if it fails because of background limits, queue.
   - **Recommendation: (b).** Most warm-hold dictations are short; FM may complete within the iOS background grace period (~30 s). On fail, queue.
3. **Backfill on first detail-view open** (existing transcript without a title): on `TranscriptDetailView.onAppear`, if title is nil, kick off generation. Avoids any big back-fill cost on install (per the open question in the original draft).

A small `TitleGenerationQueue` (`Jot/App/Cleanup/TitleGenerationQueue.swift`) holds pending requests in App Group + drains them on app foreground.

### Re-generation UX correction

Original draft promised "old title doesn't flash" on re-generation but specified an animate-in transition. The two contradict. **Fix:** explicit two-step re-generate:

1. Tap re-generate → title field replaces with a small "Re-titling…" placeholder (no animation).
2. New title arrives → fade in (matches the create-time animation).

No flicker, predictable.

### UI shape

**Library row** (`§1.2`):
- Title (1 line, semibold) above the text excerpt (1 line, regular, secondary color). Total row height unchanged.
- Featured top-of-list quote: small caps title overline above the serif quote.

**Detail view** (`§3.2`):
- Title becomes the page header (large semibold).
- Existing metadata subline (date · words · duration) stays directly below.
- Small re-generate button (`arrow.clockwise` icon) on the right edge of the title row.

### Settings copy

Replace `AIRewriteSettingsView.swift` footnote:
- Before: *"Titles and tags use the system's built-in AI automatically."*
- After: *"Titles are generated automatically using your iPhone's built-in AI."*
- Tags reference removed entirely.

Update `features.md §7.11` to match this new shape (or remove if §7.11 is no longer needed as a "discrepancy" entry — once the UI and footnote agree, the §7.11 is redundant and can go).

### Implementation outline

| Component | Location | Work |
|---|---|---|
| SwiftData schema bump | `Jot/Shared/Transcript.swift`, new `Jot/Shared/Schema.swift` if needed | Add `title: String?`, `titleGeneratedAt: Date?`. VersionedSchema scaffolding. |
| Title generator | `Jot/App/Cleanup/TitleGenerator.swift` (new) | FM call. |
| Generation queue | `Jot/App/Cleanup/TitleGenerationQueue.swift` (new) | App Group queue, drains on foreground. |
| Pipeline hook | `Jot/App/Intents/DictationPipeline.swift` | Post-finalize call to TitleGenerator. |
| Library row | `Jot/App/Recents/RecentsListCard.swift` | Render title above excerpt. |
| Detail header | `Jot/App/TranscriptDetailView.swift` | Replace metadata-only header. Add re-generate. |
| Settings copy | `Jot/App/Settings/AIRewriteSettingsView.swift` | Footnote rewrite. |
| `features.md` update | `Jot/features.md` | §3.2, §7.11 in sync with UI. |
| Diagnostics | `Jot/Shared/DiagnosticsLog.swift` | `titleGenerated` event w/ duration + success. |

### Edge cases

- **Apple Intelligence unavailable** (pre-iPhone-15-Pro, or off): `TitleGenerator.generate` throws `.unavailable`. Title stays nil; row falls back to excerpt; no error UI.
- **Apple Intelligence downloading** (queued behind a 2 GB OS-level download — `CleanupService` already maps this case): we treat `.modelDownloading` as `.unavailable` for now. Future enhancement: surface a one-time hint in Settings that titles will start when the download finishes.
- **Title generation outlives the app session**: if the app is killed mid-FM-call, the request stays in `TitleGenerationQueue`. Drains on next foreground.
- **PII / sensitive content** in transcripts: the FM call sends transcript text to the on-device model. On-device per `§13.1` — no network; OK. The title result may itself contain PII (the speaker's name, etc.) — this is expected and matches what the user already sees in the body text. No new disclosure needed.
- **Multi-language transcripts**: Parakeet is English-only today, but FillerWordCleaner handles "uh"/"um" across English variants. Apple FM may produce non-English titles for code-switched content. Acceptable; the title summarizes whatever the transcript actually contains.
- **Transcript edited via voice command (§3.6)**: the *derived* transcript (e.g. "make this more casual" output) gets its own title generation on creation. The *original* doesn't regenerate. User can manually re-generate from the detail view.
- **Multiple concurrent generations**: serialize via the queue. Drop the oldest if > 5 pending.

### Test plan

1. Foreground dictation → title appears in row + detail header within 1-3 s.
2. Apple-Intelligence-off device → row shows excerpt; no error; diagnostics log shows `.unavailable`.
3. Apple-Intelligence-downloading device → same as off; surface a Settings hint (Phase 1.5).
4. Warm-hold dictation in a third-party app → title queues; appears on next Jot foreground.
5. Three dictations within 10 s → all three titled, none lost.
6. PII transcript ("call John at 555-1234 about the deal") → title generated; may contain "John"; matches body content.
7. Multi-language transcript → some non-English title; UI doesn't break.
8. Voice-command derived transcript (§3.6) → title generated for the derived; original keeps its existing title.
9. Re-generate button — two-step (placeholder → new title) — no flicker.
10. Kill app mid-FM-call → re-launch → title generates from queue.
11. Airplane mode → titles still generate (on-device path); verify.
12. VoiceOver — title is first announced element; re-generate is a distinct action.
13. SwiftData container loads cleanly on a fresh install; on an upgraded device (post-launch); existing rows have nil title.

---

## Open Questions (require user input)

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#a2--transcript-titles-and-tags](./open-questions-deep-dive.md#a2--transcript-titles-and-tags).

1. **Which path: A (delete), B (titles only), C (both)?** Recommendation: A. Reasoning: §3.2 already documents "intentionally absent v1," no user has asked, the build path forces SwiftData versioning work the user has deferred. If the user prefers B, the SwiftData migration cost is real and should be acknowledged.
2. **If B: ship pre-launch (with overwrite policy intact) or post-launch (requires proper SwiftData migration plan)?** Pre-launch is faster; post-launch is the durable shape. Confirm.
3. **If B: how visible should "title generating…" state be?** Row could show a subtle pulsing placeholder vs. no visual indicator vs. text excerpt-only fallback (current draft uses excerpt fallback). Confirm.
4. **Settings copy if A (delete) is chosen.** Should §7.11 be removed entirely from features.md, or kept as a historical record of "shipped without titles intentionally"? Recommendation: remove — the spec describes the present, not the history.

---

## Cross-Links

- Touches: `features.md §1.2`, `§3.2`, `§7.11`, unchanged `§13.1`
- Depends on: Apple `FoundationModels` (already linked via `CleanupService`); SwiftData schema versioning (NEW work, coordinated with [docs/plans/migration-system.md](./migration-system.md))
- Independent of: AI Rewrite stack (`§7`) — Apple FM, not Qwen
- Memory ref: `feedback_prelaunch_migrations` (always-overwrite OK until App Store ship)
