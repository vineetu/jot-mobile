# Plan: Generic Versioned Migration System (Flyway-Style)

> **Source:** [docs/deferred-engineering.md §1](../deferred-engineering.md)
> **Status:** Deferred infra work. Plan elaborates the engineering shape so it's ready to pick up between feature cycles. **Revised after adversarial review** to address the missing migration, the Phi-4 detached-delete pattern, the App-Store-transition chicken-and-egg, and a crash-recovery story.

---

## Problem

Today, every one-shot migration is hand-written directly in `JotApp.init` and equivalent call sites:

1. `TranscriptionService.sweepOrphanedPurgingDirs()` — `TranscriptionService.swift:269, 941` — sweep of orphaned model-purge directories from prior crashed launches. **(Missed in the original draft — confirmed via grep.)**
2. `TranscriptionService.sweepLegacyAppSupportWeights()` — reclaim 530 MB of pre-bundle Parakeet 110M cache.
3. `Phi4WeightsPurge.runIfNeeded()` — reclaim 2.4 GB of HuggingFace Phi-4 cache. **Important: this migration intentionally flips its flag BEFORE the delete fires** (`LLMClientFactory.swift:147`) because the delete is dispatched detached and re-running it from a second cold launch would race. The detached pattern is a load-bearing design choice.
4. `SavedPromptStore.migrateArticulatePromptIfNeeded()` — overwrite Articulate prompt copy.
5. `SavedPromptStore.migrateAddAIPromptIfNeeded()` — insert new "AI prompt" default.

Each has its own ad-hoc UserDefaults flag. Three documented failure modes:

1. **Flag-flip-before-work** (memory `feedback_flag_before_work_antipattern`): the UUID-crash case that left a device with `didAddAIPromptDefault = true` but no AI prompt actually inserted. **However**: see above — for Phi-4 the flag-flip-first is intentional. The runner must support both patterns.
2. **No ordering guarantees** between migrations.
3. **No audit trail.**

We've also explicitly accepted "pre-launch overwrite-on-every-launch, no flags" for prompt defaults (memory `feedback_prelaunch_migrations`).

## Goal

A small registry that supports **three** migration patterns, not two:

- **One-shot synchronous** — runs once, blocks launch on completion. Strict work-then-flag.
- **One-shot detached** — runs once, dispatches work to background, marks applied immediately. The Phi-4 pattern. Idempotent on the "do work" side (re-running the delete is a no-op once the dir is gone, but we still don't want to scan the filesystem on every launch).
- **Always-apply** — runs every launch (the prompt-default overwrite case pre-launch). Never marked applied.

Plus: emits diagnostics events; survives crashes via a circuit breaker; correctly handles the App-Store transition from pre-launch to post-launch.

## Non-Goals

- Not a SwiftData schema-evolution framework. SwiftData schema versioning is a separate concern (see [titles-and-tags.md](./titles-and-tags.md) and any future schema-changing feature).
- Not cross-device sync coordination.
- Not downgrade / rollback.
- Not config-driven (JSON-described migrations) — migrations are Swift code.

---

## Design

### Protocol

```swift
protocol Migration {
    var id: String { get }       // stable kebab-case slug, never recycled
    var version: Int { get }     // monotonic, gaps allowed (use 10, 20, 30...)

    /// `.synchronous` blocks until apply returns; runner uses strict work-then-flag.
    /// `.detached` dispatches background work; runner marks applied BEFORE work completes,
    /// matching the existing Phi4WeightsPurge pattern. Apply must be idempotent on disk.
    /// `.alwaysApply` runs every launch, never marked applied.
    var pattern: MigrationPattern { get }

    func apply() throws         // synchronous body; detached migrations spawn their own Task inside
}

enum MigrationPattern {
    case synchronous
    case detached
    case alwaysApply
}
```

### Runner

```swift
final class MigrationRunner {
    static let shared = MigrationRunner()

    private let appliedListURL: URL
    private var registered: [Migration] = []

    func register(_ migration: Migration) {
        // dev-only precondition: duplicate id or version is a programmer error
    }

    func runPending() {
        // Pre-flight: read the applied list. Bootstrap if absent (see App-Store transition).
        var applied = loadApplied()
        let sorted = registered.sorted { $0.version < $1.version }

        for migration in sorted {
            switch migration.pattern {
            case .alwaysApply:
                runAlways(migration)
            case .synchronous:
                runSync(migration, applied: &applied)
            case .detached:
                runDetached(migration, applied: &applied)
            }
        }
    }

    private func runSync(_ migration: Migration, applied: inout AppliedList) {
        if applied.contains(migration.id) { return }
        if applied.failureCount(for: migration.id) >= 3 {
            DiagnosticsLog.append(.migrationCircuitBroken(id: migration.id))
            return  // circuit broken; will be surfaced to user
        }
        applied.incrementAttempt(for: migration.id)
        persistApplied(applied)  // attempt counter persisted BEFORE apply()
        do {
            try migration.apply()
            applied.markApplied(migration.id)
            persistApplied(applied)
            DiagnosticsLog.append(.migrationApplied(id: migration.id, version: migration.version))
        } catch {
            // attempt counter already persisted; we'll retry next launch up to 3x
            DiagnosticsLog.append(.migrationFailed(id: migration.id, version: migration.version, error: error))
        }
    }

    private func runDetached(_ migration: Migration, applied: inout AppliedList) {
        if applied.contains(migration.id) { return }
        // Mark applied BEFORE work — matches the Phi4 pattern. The apply()
        // body MUST be idempotent on disk so a redundant re-run is a no-op.
        applied.markApplied(migration.id)
        persistApplied(applied)
        do {
            try migration.apply()
            DiagnosticsLog.append(.migrationApplied(id: migration.id, version: migration.version))
        } catch {
            // Detached migrations swallow throws — we can't unmark because
            // the next launch would just retry the same throw.
            DiagnosticsLog.append(.migrationFailedNonRecoverable(id: migration.id, error: error))
        }
    }

    private func runAlways(_ migration: Migration) {
        do {
            try migration.apply()
            DiagnosticsLog.append(.migrationApplied(id: migration.id, version: migration.version))
        } catch {
            DiagnosticsLog.append(.migrationFailed(id: migration.id, version: migration.version, error: error))
        }
    }
}
```

### Crash-recovery via attempt counter (not work-then-flag alone)

Adversarial review correctly flagged that work-then-flag alone doesn't survive process crashes — if `apply()` crashes the process, the next launch retries the crash. The fix: **persist an attempt counter BEFORE each apply attempt**, marked-applied only on success. After 3 attempts, the migration is "circuit broken" and a diagnostic event surfaces.

This is the design that solves the UUID-fatal case: the migration would attempt → crash → next launch sees attempt=1, attempts again → crash → attempt=2 → ... → attempt=3 → circuit-break. User sees a "Background data update couldn't complete" banner with a copy-diagnostics-to-support button. Without this, a crashing migration loops forever.

### Persistence

`applied-migrations.json` in the App Group container:

```json
{
  "schema_version": 1,
  "device_install_id": "<UUID stamped at first launch>",
  "entries": [
    {
      "id": "purge-phi4-weights",
      "version": 20,
      "pattern": "detached",
      "applied_at": "2026-05-21T18:32:14Z",
      "attempt_count": 1,
      "broken": false
    }
  ]
}
```

`attempt_count` increments on every attempt; `broken: true` is set when count ≥ 3 and the migration is permanently skipped.

### Bootstrap — first launch

```swift
func bootstrap() -> AppliedList {
    if let existing = loadApplied() { return existing }

    // No applied list. Detect upgrade vs. fresh install via any existing
    // legacy UserDefaults flag (these only exist on devices that ran a
    // pre-runner build).
    let isUpgrade =
        UserDefaults.standard.bool(forKey: "jot.didAddAIPromptDefault") ||
        UserDefaults.standard.bool(forKey: Phi4WeightsPurge.migrationKey)

    let bootstrapped = AppliedList(
        deviceInstallID: UUID(),
        entries: isUpgrade
            ? legacyMigrationsAssumedApplied()  // upgrade: mark pre-runner migrations as applied
            : []                                // fresh install: nothing applied yet
    )
    persistApplied(bootstrapped)
    return bootstrapped
}
```

Simple heuristic. On a fresh App Store install, none of the legacy keys exist, so `isUpgrade == false`. On an upgrading device, at least one legacy key exists, so we stamp the legacy migrations as already-applied and skip re-running them. No cleverness needed.

### Keyboard-process safety

The keyboard extension reads several App Group keys that the migrations may transform (`savedPrompts`, `speechModelVariant`, etc.). If the keyboard process spins up before the main app has run pending migrations, the keyboard reads pre-migration state.

Today this is benign — the hand-rolled migrations are all written to be tolerant of pre-migration reads. The runner must preserve this property. Two options:

- **(a) Migration tolerance:** every migration's transform must be pre-and-post compatible — old shape and new shape both decode safely on read. The runner doesn't help here; it's a discipline rule per migration.
- **(b) Read-side fence:** keyboard reads through an accessor that no-ops if `applied-migrations.json` is missing. Add a "main-app has run migrations" sentinel that the keyboard checks.

**Recommendation: (a) tolerance.** Cleaner; matches today's working behavior. Document the rule in `Jot/App/Migrations/Migrations.swift` header.

### Diagnostics across targets

Adding new `DiagnosticsCategory` cases inflates both the main-app and keyboard binaries (`DiagnosticsLog` lives in `Shared/`). The cases proposed:

- `.migrationStarted`
- `.migrationApplied`
- `.migrationFailed`
- `.migrationFailedNonRecoverable`
- `.migrationCircuitBroken`

Five new cases. Tiny binary impact, but worth noting in the keyboard's 60 MB budget audit.

---

## Migration Inventory (at conversion time)

| Slug | Version | Pattern | Source | Notes |
|---|---|---|---|---|
| `sweep-orphan-purging-dirs` | 5 | synchronous | `TranscriptionService.sweepOrphanedPurgingDirs` | **Added per review.** Returns count of swept dirs. |
| `sweep-legacy-110m` | 10 | synchronous | `TranscriptionService.sweepLegacyAppSupportWeights` | Idempotent. |
| `purge-phi4-weights` | 20 | detached | `Phi4WeightsPurge.runIfNeeded` | Critically, this is `.detached` — the runner marks applied BEFORE the delete completes. |
| `overwrite-articulate-prompt` | 30 | alwaysApply → synchronous post-launch | `SavedPromptStore.migrateArticulatePromptIfNeeded` | See transition note. |
| `insert-ai-prompt-default` | 40 | synchronous | `SavedPromptStore.migrateAddAIPromptIfNeeded` | One-shot. |

### Transition note for `overwrite-articulate-prompt`

Today: `alwaysApply` (overwrite every launch, no flag — explicit user policy pre-launch). Post-App-Store ship: must become `synchronous` (run once, preserve user edits going forward).

The transition build:
1. Flip `pattern: .alwaysApply` → `pattern: .synchronous` and bump the version to `35` (new id `overwrite-articulate-prompt-v2`).
2. In the same build, bootstrap pre-existing devices by stamping `overwrite-articulate-prompt-v2` as applied for any device whose `applied-migrations.json` already exists (upgrade path) AND whose bundled prompt list contains the canonical Articulate text (sanity check).

This avoids the redundant "re-overwrite an already-canonical prompt" on every upgraded device.

---

## Implementation Plan

### Step 1 — Foundation. **Size: ~half a day.**

- New folder `Jot/App/Migrations/`.
- `Migration.swift` (protocol + `MigrationPattern` enum).
- `MigrationRunner.swift` (runner + persistence + bootstrap + circuit breaker).
- `Jot/Tests/MigrationRunnerTests.swift`:
  - Fresh install → all run → applied list contains all ids.
  - Second launch → none of the one-shots re-run, alwaysApply does.
  - Failed migration → attempt counter increments; re-runs next launch.
  - Failure 3x → circuit broken; diagnostic event surfaces.
  - Corrupted applied JSON → recover by clearing list (re-run; safe because tolerant).
  - **Watermark scenario:** registered [10, 20, 30], applied [10, 30] → 20 still runs next launch (verify by-id semantics).
  - Detached migration → marked applied immediately, work happens in background.
  - Upgrade-from-pre-runner bootstrap stamps legacy migrations as applied.

### Step 2 — Convert one migration as proof. **Size: ~1 hour.**

Pick `purge-phi4-weights` (well-isolated, detached pattern). Wire it through the runner. Confirm logs show it ran and flag transition matches pre-runner behavior.

### Step 3 — Convert remaining four. **Size: ~half a day.**

Same pattern for each. The `sweep-orphan-purging-dirs` is the new one added per review; the rest are conversions.

### Step 4 — App Store transition. **Size: ~1 hour.**

Flip the Articulate prompt overwrite from `.alwaysApply` to `.synchronous` per the transition note above. Ship.

### (Deferred) Diagnostics surface in Help.

A "Migrations" subsection in the Help diagnostics view would surface the applied list with timestamps + attempt counts + circuit-broken entries. Useful for support but not required for v1. Defer until we have evidence support needs it.

---

## Edge Cases

- **App Group container unavailable** (extension lifecycle edge). `loadApplied()` returns nil → bootstrap returns a fresh applied list → tolerance rule means migrations rerun safely.
- **JSON write fails mid-update.** Attempt counter persists before apply, applied-flag persists after. A failure between attempt-write and apply-success means we'll retry next launch (good). A failure between apply-success and applied-flag-write means we'll re-run an already-completed migration (rare; tolerance covers).
- **Two migrations with the same version.** Dev-only precondition catches at registration time.
- **Detached migration's background work crashes the app.** The applied flag was already set. Next launch skips the migration. Whatever crash-causing state is on disk is still there. Acceptable in practice (Phi-4 directory delete that crashes mid-way leaves a partial purge; the directory will be cleaned by `sweepOrphanedPurgingDirs` on next launch).
- **`applied-migrations.json` exists but `device_install_id` is missing.** Stamp at next runner pass; not load-bearing.

---

## Test Plan

Unit tests in Step 1. Integration tests:

1. Fresh install on a clean device → all five legacy migrations run, log events fire, applied list lands.
2. Second launch → none of the one-shots re-run; the alwaysApply Articulate runs.
3. Inject a throwing test migration → confirm attempt counter increments across launches, circuit-breaks at attempt 3.
4. Corrupt the applied JSON → confirm graceful recovery + idempotent re-runs.
5. Bootstrap test: clean device → no legacy flags → fresh applied list. Pre-runner device → legacy flags present → applied list stamps the legacy migrations as already applied.
6. Watermark: register [10, 30] only → applied list has only [10, 30]. Add migration 20 → second launch runs 20.
7. Detached migration: confirm marked-applied happens before detached work completes (use a sleep in the test migration's body).
8. App Store transition: simulate the v2 Articulate bump → confirm pre-existing devices skip the redundant overwrite via the sanity check.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#d1--migration-system](./open-questions-deep-dive.md#d1--migration-system).

1. **Confirm the detached pattern survives the runner conversion** — the existing Phi4WeightsPurge has nuanced ordering (filesystem-existence check + flag-flip + dispatch). The runner's `.detached` branch should preserve this exact sequence. Confirm by reading the runner's `runDetached` against the existing code.
2. **Should circuit-broken migrations surface a UI banner**, or only diagnostics? Recommend a one-time toast "A background update couldn't complete — tap to send a diagnostic report" surfaced once per circuit-break, dismissible.
3. **Where does `device_install_id` get stamped?** Recommended: a special always-first bootstrap migration at version 0. Confirm.

---

## Cross-Links

- Replaces ad-hoc gating in: `Jot/App/JotApp.swift:156-180`, `SavedPromptStore.swift`, `TranscriptionService.swift`, `LLMClientFactory.swift`
- Memory refs: `feedback_prelaunch_migrations`, `feedback_flag_before_work_antipattern`
- Help diagnostics: `Jot/App/Help/HelpView.swift` (Troubleshooting → Diagnostics — gains a Migrations subsection)
- Related: SwiftData schema versioning is a SEPARATE concern not handled by this system (see [titles-and-tags.md](./titles-and-tags.md))
