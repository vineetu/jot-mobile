# SwiftData Schema Migrations

Jot's persistent data model follows a Flyway-style versioned migration discipline. Every shipped schema version is **frozen** the moment it ships; evolution happens by appending new versions and `MigrationStage`s.

## Why the discipline

SwiftData's auto-migration ("lightweight" inference) is empirically fragile across iOS versions and Xcode SDK builds. Explicit `VersionedSchema` + `SchemaMigrationPlan` makes every schema change:

- **Traceable** — every change has a named file (`JotSchemaVN.swift`) committed to git.
- **Code-reviewable** — the diff between V(N-1) and VN is the migration story.
- **Reversible-on-restore** — old iCloud backups restored on a newer build load cleanly because the plan describes every version on the user's device.
- **Stable across iOS upgrades** — we don't rely on SwiftData inferring the right thing from the runtime shape of the type.

## Flyway parallel

| Flyway concept | SwiftData equivalent |
|---|---|
| `V1__create_users.sql` | `enum JotSchemaV1: VersionedSchema` |
| `V2__add_email.sql` | `enum JotSchemaV2: VersionedSchema` |
| Migration runner (`flyway migrate`) | `enum JotMigrationPlan: SchemaMigrationPlan` |
| `flyway_schema_history` (metadata table) | SwiftData's internal version tracking (CoreData metadata of the `.sqlite` file) |
| Rule: never modify a shipped migration | Same: never modify a shipped `JotSchemaVN.swift` |

`scripts/check-schema-frozen.sh` enforces the frozen rule mechanically. PRs that edit `JotSchemaV*.swift` for any N less than the maximum fail CI.

## Current versions

- **V1** (`JotSchemaV1.swift`, frozen 2026-05-24, baseline as of Jot 1.0.2 build 6+).
  - `Transcript`: id, text, cleanedText, createdAt, durationSeconds, ledgerIndex, derivedFromID, instruction, supersededAt.
  - Models: `[Transcript]`.

> Future versions append here. **Every PR that ships a new VN must update this list.**

## Adding a new version (V → V+1)

Step-by-step:

1. **Copy** `Jot/Shared/Schema/JotSchemaVN.swift` to `Jot/Shared/Schema/JotSchemaV(N+1).swift`. Replace `JotSchemaVN` with `JotSchemaV(N+1)` throughout. Bump `versionIdentifier` (e.g. `Schema.Version(2, 0, 0)`).
2. **Modify the new file only.** Add new fields. NEVER remove or rename existing fields without explicit migration logic.
   - Pure addition of optional field → `.lightweight(...)` stage will suffice.
   - New entity type (e.g. add `RewriteTrainingPair` alongside `Transcript`) → also `.lightweight(...)`; include the new type in the new version's `models` array.
   - Rename / split / default-fill / type change of an existing field → `.custom(...)` stage with `willMigrate` and `didMigrate` closures.
3. **Update `JotMigrationPlan.swift`:**
   - Append `JotSchemaV(N+1).self` to `schemas` (latest last).
   - Append a `MigrationStage` to `stages` describing how to traverse V(N) → V(N+1).
4. **Update the `Transcript` typealias** in `Jot/Shared/Transcript.swift` to point at `JotSchemaV(N+1).Transcript`. (And update any other model typealiases that you've added.)
5. **Update `JotModelContainer.shared`** in `Jot/Shared/TranscriptStore.swift` to use `Schema(versionedSchema: JotSchemaV(N+1).self)` and `JotMigrationPlan.self`.
6. **Run `xcodegen` from `Jot/`** to regenerate the Xcode project — the new `JotSchemaV(N+1).swift` file lives under the recursive `Shared/` glob but the `.pbxproj` needs refreshing to pull the new file into the targets. Without this step, the build is silently green (missing source) and the next clean build fails on missing symbols.
7. **Update this doc's "Current versions" list** with the new VN entry: date, build, summary of changes.
8. **Do NOT modify the prior `JotSchemaVN.swift` file.** It is frozen. `scripts/check-schema-frozen.sh` will block your PR if you do.
9. **Test the upgrade path on a real device.** Install the previous build, dictate transcripts, install the new build. Confirm transcripts load AND Console.app shows no `[SCHEMA-FALLBACK]` log lines (filter for that string). If you see `[SCHEMA-FALLBACK]`, the migration plan failed on that device — investigate before merge.

## Stage types

- `.lightweight(fromVersion:toVersion:)` — additive optional fields, new entity types, anything SwiftData can derive automatically.
- `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` — data transforms requiring explicit Swift closures (rename a field while preserving its data, split one field into two, populate a new required field with a default derived from existing data, etc.).

## Defensive fallback in `JotModelContainer`

`TranscriptStore.swift`'s `JotModelContainer.shared` initializer tries the VersionedSchema + MigrationPlan path first, and falls back to a non-versioned init if SwiftData refuses to load the store. The fallback fires a `[SCHEMA-FALLBACK]` log line. **If you see this log in field telemetry**, the VersionedSchema path is misbehaving on that user's device — investigate the underlying drift (likely iOS version interaction with inferred-schema hashing) before adding any V(N+1) work that depends on the migration plan.

## Plan-doc requirement

Every feature plan in `docs/plans/` that touches `@Model` types MUST include a **"Schema impact"** section per the `Jot/CLAUDE.md` "Schema discipline" rule. Sections:

- Does this feature add/remove/rename `@Model` fields, or add new `@Model` entities? Y/N.
- If Y: what's the new `JotSchemaVN` look like? Diff from prior version.
- What `MigrationStage` traverses V(N-1) → VN? Lightweight or custom?

PRs without a "Schema impact" section on a schema-touching feature: block at code review.

## What lives where

- `Jot/Shared/Schema/JotSchemaVN.swift` — frozen schema snapshots. One per shipped version.
- `Jot/Shared/Schema/JotMigrationPlan.swift` — the `SchemaMigrationPlan` listing all versions + stages.
- `Jot/Shared/Transcript.swift` — `typealias Transcript = JotSchemaVN.Transcript` + computed-property extension.
- `Jot/Shared/TranscriptStore.swift` — `JotModelContainer.shared` (the actual container construction), `TranscriptStore.append/update/delete`.
- `Jot/CLAUDE.md` — the discipline summary that feature planners read.
- `docs/schema-migrations.md` — this file. Current versions + the recipe.

## Cross-process invariant

The keyboard extension target compiles `JotSchemaVN.swift` and `JotMigrationPlan.swift` as part of its shared sources, but **MUST NOT open `JotModelContainer.shared` at runtime.** The keyboard reads `TranscriptHistoryMirror` JSON only. Opening the SwiftData container from a second process is a Core Data anti-pattern that risks store corruption. See `Jot/AGENTS.md`.

## Downgrade limitation

Restoring a backup taken on Jot version N onto a device running Jot version M (where M < N) is **not supported**. The store contains entities (or fields) that the older build doesn't know about; SwiftData will refuse to load. The `JotModelContainer.shared` defensive fallback will also fail (the legacy schema can't load V+ data). The user must install the same or newer version to restore.
