# Plan: SwiftData Schema-Migration Foundation (Flyway-style)

> **Status:** Requested 2026-05-24. Foundation work, no user-visible change. Done now so Phase 2 (editable transcripts) lands as a clean schema-add only, and so all future field additions have a forced "what's the migration?" checkpoint.
> **Size: half-day** (foundation only, no schema content delta yet).
> **Adversarial review:** to be performed after this draft.

---

## Goal

Lock in a Flyway-style discipline for the Jot SwiftData store so:

1. Every schema change has an explicit, named, immutable version.
2. Every change ships with an explicit `MigrationStage` declaring how to traverse from the prior version.
3. The discipline is documented as an engineering convention so it's never forgotten when adding fields later.
4. Old backups restored on a new build still load — the migration plan handles the traversal automatically.
5. Future features (editable transcripts, titles, tags, anything that touches `Transcript` or future `@Model` types) ship cleanly on this foundation rather than fighting it.

This plan ships **no user-visible change**. The build runs identically to today. The point is the foundation.

## Non-Goals

- Not adding any new schema fields in this PR. Pure scaffolding.
- Not moving the SwiftData store location (it stays in the App Group container per the existing cross-process invariant).
- Not handling cross-process schema-version skew between main app and keyboard at runtime (the keyboard reads JSON mirror, not SwiftData directly — invariant per `Jot/AGENTS.md`).
- Not replacing or refactoring the deferred `docs/plans/migration-system.md` (which handles UserDefaults / one-shot migrations — a separate concern from SwiftData schema versioning). The two systems sit alongside.

---

## Flyway parallel — what we're mapping

| Flyway concept | SwiftData equivalent | Jot usage |
|---|---|---|
| `V1__create_users.sql` | `enum JotSchemaV1: VersionedSchema` | Frozen snapshot of the schema as of build N. **Never modified after ship.** |
| `V2__add_email.sql` | `enum JotSchemaV2: VersionedSchema` | Snapshot of schema as of build N+k. Frozen the moment it ships. |
| `flyway_schema_history` (metadata table) | SwiftData's internal version tracking (stored in CoreData metadata of the `.sqlite` file) | Tracks which version is currently applied on the user's device. |
| Migration runner (`flyway migrate`) | `enum JotMigrationPlan: SchemaMigrationPlan` | Lists ordered versions + stages between them. Invoked at `ModelContainer` construction. |
| `flyway info` (audit) | Build-time grep + `check-backup-attributes.sh` extension | Confirms no shipped version's file has been modified. |
| Flyway rule: "checksum a shipped migration; mismatch = fail loud" | Discipline + code review | Cannot mechanically verify in SwiftData, but mitigated by file-header comment, CLAUDE.md rule, and adversarial review on PRs. |

The hard rule: **once a `JotSchemaVN` file is in a shipped build, its content is frozen.** Add a field = bump to `JotSchemaV(N+1)` + add a `MigrationStage`. Don't ever edit the prior file.

---

## Code structure

```
Jot/Shared/
├── Schema/
│   ├── README.md                     ← Flyway rules; pointer to schema-migrations.md
│   ├── JotSchemaV1.swift             ← Current Transcript shape, frozen as of 1.0.2 (6)
│   └── JotMigrationPlan.swift        ← SchemaMigrationPlan declaration
├── Transcript.swift                  ← Keeps current shape; typealias to JotSchemaV1.Transcript
├── TranscriptStore.swift             ← Updated to use VersionedSchema + MigrationPlan
└── ... (other files unchanged)
```

### `Jot/Shared/Schema/JotSchemaV1.swift` — frozen V1

```swift
import Foundation
import SwiftData

/// **FROZEN.** Snapshot of the SwiftData schema as of Jot 1.0.2 (6).
///
/// Do not modify any field of `Transcript` declared inside this file once
/// this file has been shipped. To add a field, copy this file to
/// `JotSchemaV2.swift`, add the field there, and declare a `MigrationStage`
/// in `JotMigrationPlan` from V1 → V2. See `docs/schema-migrations.md`.
///
/// Why this exists: SwiftData's "lightweight" migration mode is empirically
/// fragile across iOS versions; explicit `VersionedSchema` + `MigrationPlan`
/// makes every schema change traceable and reversible.
enum JotSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [Transcript.self] }

    /// FROZEN. The shape `@Model class Transcript` had at 1.0.2 (6).
    /// To extend, create a new VersionedSchema (V2) with the new fields.
    @Model
    final class Transcript {
        var id: UUID
        var text: String
        var cleanedText: String?
        var createdAt: Date
        var durationSeconds: Double?
        var ledgerIndex: Int
        var derivedFromID: UUID?
        var instruction: String?
        var supersededAt: Date?

        init(
            id: UUID = UUID(),
            text: String,
            cleanedText: String? = nil,
            createdAt: Date = Date(),
            durationSeconds: Double? = nil,
            ledgerIndex: Int,
            derivedFromID: UUID? = nil,
            instruction: String? = nil,
            supersededAt: Date? = nil
        ) {
            self.id = id
            self.text = text
            self.cleanedText = cleanedText
            self.createdAt = createdAt
            self.durationSeconds = durationSeconds
            self.ledgerIndex = ledgerIndex
            self.derivedFromID = derivedFromID
            self.instruction = instruction
            self.supersededAt = supersededAt
        }
    }
}
```

### `Jot/Shared/Schema/JotMigrationPlan.swift`

```swift
import Foundation
import SwiftData

/// Migration plan for the Jot SwiftData store.
///
/// **DO NOT open `JotModelContainer.shared` from the keyboard target.**
/// The keyboard process reads `TranscriptHistoryMirror` JSON only — see
/// `Jot/AGENTS.md`. Opening the SwiftData container from the extension
/// breaks the cross-process invariant and risks store corruption.
///
/// **Add a new version:**
/// 1. Create `JotSchemaVN.swift` with the new `@Model` shape.
/// 2. Append `JotSchemaVN.self` to `schemas` (chronological order).
/// 3. Add a `MigrationStage` describing how to go from V(N-1) to VN.
///    For pure additive optional fields: `.lightweight(...)`.
///    For data transforms (rename, split, default-fill): `.custom(...)`.
///    For new entity types (e.g. adding `RewriteTrainingPair` alongside
///    `Transcript`): still `.lightweight(...)` — SwiftData handles
///    new entities automatically. Just include the new type in
///    `JotSchemaVN.models`.
/// 4. Update `Transcript` typealias (and any other model typealiases)
///    in `Jot/Shared/Transcript.swift` to point at the new VN type.
/// 5. Update `docs/schema-migrations.md` "Current versions" list with
///    the new VN entry (date, build, summary of fields added).
/// 6. NEVER modify a prior `JotSchemaV(N-1).swift` file. Frozen for life.
///
/// `scripts/check-schema-frozen.sh` (in CI / pre-commit) blocks PRs
/// that edit `JotSchemaV*.swift` files where N is not the highest.
enum JotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [JotSchemaV1.self]
        // Future: append V2.self, V3.self, ... in chronological order.
    }

    static var stages: [MigrationStage] {
        []
        // Future: .lightweight(fromVersion: JotSchemaV1.self,
        //                      toVersion: JotSchemaV2.self),
        //        etc.
    }
}
```

### `Jot/Shared/Transcript.swift` — thin typealias

To avoid touching every call site that says `Transcript`, keep the top-level `Transcript` name resolvable via a typealias that always points at the current version:

```swift
import Foundation
import SwiftData

/// Top-level alias for the current `Transcript` `@Model` type. Always
/// points at the latest VersionedSchema's Transcript. Bump this when a
/// new VN ships.
typealias Transcript = JotSchemaV1.Transcript
```

This means existing code referencing `Transcript` continues to compile. The old `@Model class Transcript` body and its docs migrate into `JotSchemaV1.swift`.

### `Jot/Shared/TranscriptStore.swift` — wire the plan in

Two small changes to `JotModelContainer.shared`:

```swift
let config = ModelConfiguration(
    "JotTranscripts",
    schema: Schema(versionedSchema: JotSchemaV1.self),
    groupContainer: .identifier(AppGroup.identifier),
    cloudKitDatabase: .none
)
return try ModelContainer(
    for: Schema(versionedSchema: JotSchemaV1.self),
    migrationPlan: JotMigrationPlan.self,
    configurations: [config]
)
```

The only delta from today: pass `migrationPlan: JotMigrationPlan.self` and switch from `Schema([Transcript.self])` to `Schema(versionedSchema: JotSchemaV1.self)`. SwiftData uses the version identifier as the migration anchor.

---

## Engineering convention (`Jot/CLAUDE.md` addition)

Add a new section:

```markdown
## Schema discipline — SwiftData store

The SwiftData store lives in the App Group container (cross-process invariant).
Schema evolution follows a Flyway-style discipline:

1. Every shape lives in `Jot/Shared/Schema/JotSchemaVN.swift` as an
   `enum JotSchemaVN: VersionedSchema`. The current version is the highest N.
2. **Frozen rule.** Once `JotSchemaVN.swift` is in a shipped build, the file
   is FROZEN. Do not edit it. Add fields by introducing `JotSchemaV(N+1).swift`
   and adding a `MigrationStage` in `Jot/Shared/Schema/JotMigrationPlan.swift`.
3. The top-level `Transcript` typealias points at the current version
   (`typealias Transcript = JotSchemaVN.Transcript`).
4. Pure additive optional fields: `.lightweight(...)` stage. Renames,
   removes, or data transforms: `.custom(...)` stage with a Swift closure.
5. Every feature plan that touches `@Model` types MUST include a
   "Schema impact" section declaring the new version + stage (or "no change").
   See `docs/schema-migrations.md` for the full template.

This applies to ALL future schema changes, including features that look
trivially additive — SwiftData lightweight migration is empirically
fragile and the explicit plan catches the surprise cases.
```

---

## Engineering doc: `docs/schema-migrations.md`

A new doc, ~50 lines, that:

- Names the Flyway parallel explicitly so future readers can match concepts.
- Provides a step-by-step recipe for adding a new schema version.
- Lists the current versions in order with one-line summaries (so the file becomes the always-up-to-date version log).
- References the CLAUDE.md "Schema discipline" section.
- Documents what to do during code review when a PR touches `@Model` types but doesn't add a new VersionedSchema (block).

Sample content:

```markdown
# SwiftData Schema Migrations

Jot's data model follows a Flyway-style versioned migration discipline.

## Current versions

- **V1** (`JotSchemaV1.swift`, frozen 2026-05-24, shipped in 1.0.2 build 6+) —
  baseline. Transcript with: id, text, cleanedText, createdAt, durationSeconds,
  ledgerIndex, derivedFromID, instruction, supersededAt.

## Adding a new version (V → V+1)

1. Copy `JotSchemaVN.swift` to `JotSchemaV(N+1).swift`. Update enum names
   inside.
2. In the new file, ADD your fields to the `@Model` class. NEVER remove,
   rename, or retype existing fields without explicit migration logic
   in a `.custom(...)` stage.
3. Update `JotMigrationPlan.schemas` to append the new type.
4. Update `JotMigrationPlan.stages` with a `MigrationStage` describing how
   to traverse VN → V(N+1).
5. Update the top-level `Transcript` typealias (or whatever model
   typealiases were affected) to point at the new VersionedSchema's type.
6. Update `JotModelContainer.shared` to use `Schema(versionedSchema: JotSchemaV(N+1).self)`.
7. Update this doc's "Current versions" list.
8. DO NOT modify the prior `JotSchemaVN.swift` file. It is frozen.

## Stage types

- `.lightweight(fromVersion:toVersion:)` — additive optional fields,
  or other transforms SwiftData can derive automatically.
- `.custom(...)` — data transforms (split a field, populate a default,
  rename a field, etc.). Requires `willMigrate` / `didMigrate` closures.

## Why this discipline

SwiftData's auto-migration is empirically fragile across iOS versions and
Xcode releases. Explicit VersionedSchemas + MigrationPlan make every change
traceable, code-reviewable, and reversible. Old backups restore cleanly
because the plan handles every recorded version on the user's device.

## Plan-doc template requirement

Every feature plan that touches @Model types must include a "Schema impact"
section per the CLAUDE.md "Schema discipline" rule. See an example in
`docs/plans/editable-transcripts.md` (parked on feature/editable-transcripts).
```

---

## Plan-doc template update

Update the implicit template that the existing plan docs follow:

- Add **"Schema impact"** as a required section between "Non-Goals" and "Design."
- Sections:
  - Does this feature add/remove/rename `@Model` fields? Y/N.
  - If Y: what's the new VersionedSchema? Diff from prior version.
  - What MigrationStage handles V(N-1) → VN? Lightweight or custom?
- If a plan lacks this section but does touch @Model types, code review blocks.

Apply retroactively to the Phase 2 `editable-transcripts.md` plan parked on the feature branch (it has the content but needs to fit the section format).

---

## `features.md` update

A small addition to §13.4 documenting that schema changes are versioned:

> Schema changes carry explicit version migrations; restoring an old backup on a newer build of Jot loads cleanly via the migration plan.

User-facing reassurance, one sentence.

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. Create `Jot/Shared/Schema/` directory | new | XS |
| 2. Move current `Transcript` `@Model` body into `Jot/Shared/Schema/JotSchemaV1.swift` (wrapped in `enum JotSchemaV1: VersionedSchema`) | new file | S |
| 3. Replace `Jot/Shared/Transcript.swift` body with the typealias | edit | XS |
| 4. Create `Jot/Shared/Schema/JotMigrationPlan.swift` with empty `schemas` + `stages` AND the "do not open from keyboard target" header comment | new | XS |
| 5. Update `Jot/Shared/TranscriptStore.swift` `JotModelContainer.shared` to use VersionedSchema + MigrationPlan **with the defensive fallback to legacy schema init** so existing user data can't get bricked | edit | S |
| 6. Add `scripts/check-schema-frozen.sh` — 4-line bash that fails if a PR's `git diff` touches `JotSchemaV*.swift` for any N less than the max | new | XS |
| 7. Verify all call sites still compile (no signature changes required because of typealias). Include `@Query`, `#Predicate<Transcript>`, `FetchDescriptor<Transcript>`, key-path expressions like `\Transcript.createdAt` | grep + xcodebuild | XS |
| 8. Add `Schema discipline` section to `Jot/CLAUDE.md` | edit | XS |
| 9. Write `docs/schema-migrations.md` with: current-versions list, add-a-version recipe (including new-entity sub-case), why-the-discipline rationale, the no-keyboard-opens rule | new | S |
| 10. Update `features.md §13.4` with the one-sentence migration mention AND the honest downgrade limitation | edit | XS |
| 11. Retroactively reformat `editable-transcripts.md` (on `feature/editable-transcripts` branch) to use the new Schema-impact section | edit on branch | S |
| 12. Build + audit script run + `check-schema-frozen.sh` run | manual | XS |

**Total: half a day.** No user-visible change, no Settings edits, no `RecordingService` touches.

---

## Edge Cases — revised after review

### The load-bearing risk

The original draft claimed SwiftData would silently "stamp V1" onto an existing un-versioned store. Critic correctly flagged this as empirically fragile — SwiftData's first-open behavior with `migrationPlan:` against a store with no `versionIdentifier` metadata depends on iOS version, the exact hash of inferred schema, and the typealias-vs-direct-class concern in finding #4 (qualified type name `JotSchemaV1.Transcript` may hash differently from the original top-level `Transcript`).

If the silent stamp fails on a real user's device, `ModelContainer(for:migrationPlan:)` throws at init, which today calls `fatalError`. The app would not launch.

### The fix: defensive container init with fallback

`JotModelContainer.shared` becomes:

```swift
static let shared: ModelContainer = {
    do {
        // ... existing pre-create-directory bootstrap unchanged ...

        // First try: VersionedSchema + MigrationPlan (the new foundation).
        do {
            let versionedSchema = Schema(versionedSchema: JotSchemaV1.self)
            let config = ModelConfiguration(
                "JotTranscripts",
                schema: versionedSchema,
                groupContainer: .identifier(AppGroup.identifier),
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: versionedSchema,
                migrationPlan: JotMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            // SwiftData refused to load the versioned schema. Most likely
            // an existing un-versioned store can't be auto-stamped to V1
            // because the inferred-schema hash drifted (typealias-vs-class,
            // iOS version, Xcode SDK). Fall back to the original
            // non-versioned init that we know works on every shipped
            // build to date. We lose the migration plan's benefit on THIS
            // launch, but we don't brick the user. A telemetry event
            // surfaces the failure so we can address in a follow-up.
            log.error(
                "[SCHEMA-FALLBACK] VersionedSchema init failed; falling back to non-versioned. error=\(error.localizedDescription, privacy: .public)"
            )
            let legacySchema = Schema([JotSchemaV1.Transcript.self])
            let config = ModelConfiguration(
                "JotTranscripts",
                schema: legacySchema,
                groupContainer: .identifier(AppGroup.identifier),
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: legacySchema, configurations: [config])
        }
    } catch {
        // Both paths failed. This is a real corruption — fall through to
        // the existing fatalError (unchanged from today's behavior).
        fatalError("Unable to construct JotModelContainer: \(error)")
    }
}()
```

**The invariant: this PR cannot regress existing users.** Worst case, the VersionedSchema path fails and we land in the legacy path, which is exactly today's behavior. The user sees no difference. The fallback log fires; we investigate post-ship.

If the VersionedSchema path succeeds (likely the happy path on fresh installs), we get the foundation we want.

This is also the recovery story for the §332 downgrade case — same code handles it gracefully.

### Per-finding mitigations

- **First launch after this PR (revised).** Either path produces a working store. If the versioned init succeeds, V1 is stamped going forward. If it fails, we keep the un-versioned store and try again next launch (or next PR that addresses the underlying drift). No data loss either way.
- **Cross-process readers.** The keyboard extension reads `TranscriptHistoryMirror` JSON, NOT the SwiftData store. Plumbing is unchanged. Add explicit "**Do NOT open `JotModelContainer.shared` from the keyboard target**" comment in `JotMigrationPlan.swift` header per review finding #6 so future contributors don't accidentally cross the boundary.
- **App Group container restored from VN backup, opened on V<N build.** Honest: this scenario will fail at the versioned-init step → land in the fallback → fallback also fails (the legacy `Schema([Transcript.self])` can't load data with V2 fields it doesn't know about) → `fatalError`. Document in `features.md §13.4` as: "Restoring a newer-version backup on an older build of Jot is not supported; install the same or newer version." Per finding #10.
- **Schema migration AND iCloud Restore in same session.** Handled by the same fallback mechanism. If the versioned init throws, we try legacy. If both throw, fatalError. Future improvement (out of this PR's scope): non-fatal UX for the both-paths-failed case.
- **Typealias entity-hash concern (finding #4).** The fallback `Schema([JotSchemaV1.Transcript.self])` uses the fully-qualified type name, matching what the versioned init would emit. The legacy code today uses `Schema([Transcript.self])` — but `Transcript` IS `JotSchemaV1.Transcript` via typealias, so the emitted hash should be the same. If iOS treats them differently, the fallback path also fails and we're at `fatalError`. The risk is bounded; the fallback at least gives us one more chance.

---

## Test Plan

1. **Static — signature equivalence.** Confirm `JotSchemaV1.Transcript`'s stored properties + `init` signature is a character-for-character match to the previous top-level `Transcript`. The check: `git diff Jot/Shared/Transcript.swift` (before) vs `JotSchemaV1.swift` (after) should differ ONLY by the `enum JotSchemaV1: VersionedSchema { ... }` wrapper + the `models` declaration. No property reordering, no annotation changes.
2. **Build:** clean build succeeds. No warnings about ambiguous types from the typealias.
3. **Upgrade path (the load-bearing test):** install current production (1.0.2 b6), dictate 3 transcripts, run a rewrite on one, add a custom prompt. Install this PR's build. Confirm: transcripts load, rewrite shows, prompts present. Behavior unchanged. **Critically: check Console.app for `[SCHEMA-FALLBACK]` log.** If it fires, we landed in the legacy fallback — the VersionedSchema path doesn't work for upgrading users yet, and we need to fix that in a follow-up before any V2 work.
4. **Fresh install:** install this PR's build on a clean device (no prior Jot). Dictate. Confirm everything works. Expected: no fallback log (versioned init succeeds).
5. **Audit scripts:** `scripts/check-backup-attributes.sh` still passes. `scripts/check-schema-frozen.sh` passes (only V1 file modified, which is OK since it's being introduced).
6. **No unintended changes:** `git diff` shows ONLY: new Schema/ directory (V1 + plan), Transcript.swift body reduced to typealias + import, TranscriptStore.swift gains versioned-init-with-fallback, new check-schema-frozen.sh, CLAUDE.md gains a section, docs/schema-migrations.md new, features.md §13.4 gets one sentence + a downgrade caveat.

---

## Open Questions

1. **Where does the `Transcript` typealias live?** Option A: keep it in `Jot/Shared/Transcript.swift` (just the typealias + a short header). Option B: move the typealias to a new `Jot/Shared/Schema/CurrentSchema.swift`. **Recommendation: A** — less file churn, easier to grep for `class Transcript`.
2. **Should `Schema/README.md` exist** alongside the .swift files, or is `docs/schema-migrations.md` sufficient? **Recommendation:** skip the README.md — the docs/schema-migrations.md path is the single source of truth; pointer comment in the Swift file headers points at it.
3. **Should we add an Xcode build phase that fails the build if a `JotSchemaVN.swift` file's mtime has changed without bumping N?** Static enforcement of the frozen rule. **Recommendation: no** — discipline + code review + adversarial review is sufficient; build-phase scripts are flaky. Revisit if the rule gets violated.

---

## Cross-Links

- Touches: `Jot/Shared/Schema/` (new), `Jot/Shared/Transcript.swift` (collapsed to typealias), `Jot/Shared/TranscriptStore.swift` (container init), `Jot/CLAUDE.md` (new section), `docs/schema-migrations.md` (new), `Jot/features.md §13.4` (one sentence), `docs/plans/editable-transcripts.md` (retroactive Schema-impact section)
- No changes to: keyboard extension, recording pipeline, intent handlers, RecordingService, anything that uses `Transcript` as a type (typealias preserves the name)
- Sequenced before: any future feature that touches @Model types, including Phase 2 (editable transcripts) and any later titles/tags/edits/history feature
- Independent of: `docs/plans/migration-system.md` D1 (which handles UserDefaults + one-shot tasks — a different concern)
