import Foundation
import SwiftData

/// Migration plan for the Jot SwiftData store. Flyway-style: every shipped
/// schema version is frozen, evolution happens by appending new versions
/// and `MigrationStage`s.
///
/// **DO NOT open `JotModelContainer.shared` from the keyboard target.**
/// The keyboard process reads `TranscriptHistoryMirror` JSON only — see
/// `Jot/AGENTS.md`. Opening the SwiftData container from the extension
/// breaks the cross-process invariant and risks store corruption.
///
/// **To add a new schema version (V → V+1):**
///
/// 1. Create `JotSchemaV(N+1).swift` with the new `@Model` shape. Start
///    by copying `JotSchemaVN.swift`, then add new fields / new entity
///    types. Never remove or rename existing fields without a `.custom`
///    migration stage.
/// 2. **Bump `versionIdentifier`** in the new file to a new value (e.g.
///    `Schema.Version(2, 0, 0)`). Without a unique identifier, SwiftData
///    cannot distinguish V1 from V2 and the migration plan corrupts
///    the store.
/// 3. Append `JotSchemaV(N+1).self` to `schemas` below (chronological
///    order; latest last).
/// 4. Add a `MigrationStage` to `stages` describing the V → V+1 traversal:
///    - Additive optional fields → `.lightweight(...)`.
///    - New entity types alongside existing ones → `.lightweight(...)`
///      (SwiftData handles new entities automatically).
///    - Field rename / split / default-fill / type change → `.custom(...)`
///      with `willMigrate` and/or `didMigrate` closures.
/// 5. Update the `Transcript` typealias (and any other model typealiases)
///    in `Jot/Shared/Transcript.swift` to point at the new VN type.
/// 6. Update `JotModelContainer.shared` in `TranscriptStore.swift` to use
///    `Schema(versionedSchema: JotSchemaV(N+1).self)`.
/// 7. **Run `xcodegen` from `Jot/`** to refresh the Xcode project so the
///    new schema file is compiled into both targets.
/// 8. Update `docs/schema-migrations.md` "Current versions" list with
///    the new VN entry (date, build, summary of fields added).
/// 9. **NEVER** modify a prior `JotSchemaV<earlier>.swift` file. Frozen
///    for life. `scripts/check-schema-frozen.sh` blocks PRs that do.
/// 10. **Test the upgrade path on a real device.** Install the prior
///     build, dictate transcripts, install the new build, confirm
///     transcripts load. In Console.app filter for `[SCHEMA-FALLBACK]`
///     — if that log fires, the VersionedSchema path is failing and
///     the migration needs investigation before merge.
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
