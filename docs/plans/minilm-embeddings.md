# Plan: MiniLM Embedding Foundation (Replacing Qwen Classifier)

> **Status:** Planned 2026-05-27. Foundation work. Replaces the Qwen-based transcript classifier (build 43, 1.0.3) with a lightweight MiniLM-L6-v2 embedding substrate. Lays groundwork for a future "Garden" idea-clustering feature and similarity-search retrieval. **No user-facing feature yet** — embeddings are a derived field that future builds will read.
> **Size: M** (~1 day: schema V6 + service + capture-time hook + BG sweep + Qwen rip-out + sanity test). The Revision 4 addition is ~30 lines (new entity + store), well inside the M envelope.
> **Revision 4 (2026-05-27):** Adds `TranscriptCategory` sibling entity to cleanly decouple future classification work from the deprecated `Transcript.category` field. No consumers in this PR — pure substrate, same as TranscriptEmbedding. Future classifiers (embedding-based, re-introduced Qwen, user-manual tags) write here with a `classifierVersion` discriminator. `Transcript.category` is now explicit dead-data: not migrated, not erased, not read by any V6 code path. Sibling directory rename: `Jot/Shared/Embeddings/` → `Jot/Shared/DerivedData/` to honor that this directory now houses multiple derived-data stores.
> **Revision 3 (2026-05-27):** Round 2 review fixes — corrected `jot.schema.fallbackActiveSince_v1` key + `UserDefaults.standard` store in §Verification (B5), kill-switch guard added to capture hook worked example (C3), cold-prewarm tax folded into BG budget + initial `batchSize = 25` (N1), defensive `BGTaskScheduler.shared.cancelAllTaskRequests()` in JotApp.init (N4), actor-isolation rationale sentence after worked example (C2/N2), `AppGroup.defaults` chosen as the store for `jot.embeddings.enabled` (N3), fallback-active migration-ordering note added to Risk 1 (N5).
> **Revision 2 (2026-05-27):** corrected swift-embeddings API surface, schema-sequencing for V4→V5→V6 chained migration, JOT_APP_HOST gate on EmbeddingStore, default-ON Lab kill switch, BG task type change (drop charging-requirement), Python-reference tokenizer validation gate, MLTensor memory measurement gate, integration test gating.

---

## Intent

Swap the 2.5 GB Qwen 3.5B 5-class classifier (jetsam-prone, charging-only) for a 22 MB MiniLM-L6-v2 sentence encoder that emits a 384-dim float32 embedding per transcript. Embeddings are:

- Cheap enough to compute **inline at capture time** (~30-50 ms on-device, invisible against Parakeet's tail).
- General-purpose. Same vector serves classification (future), clustering (Garden), similarity search, retrieval.
- Versioned (`modelVersion: "minilm-l6-v2"`) so a future model swap re-embeds in a batch without invalidating the table.

The Qwen **classifier** is removed in this PR. The Qwen **rewrite path stays** — `LLMClientFactory`, `Qwen35Client`, `currentProviderWeightsOnDisk`, and the AI Settings download UX are untouched. The category field on `Transcript` is **left in place but deprecated** (removing it would require a `.custom` migration) and is now **explicit dead-data**: not migrated to the new `TranscriptCategory` table, not erased, and not read by any V6 code path.

Re-introducing classification as a downstream task is explicitly deferred — see `deferred-engineering.md` §N. **A future classifier (embedding-based, a re-introduced Qwen-style model, or a user-manual-tag feature) writes its output to the new `TranscriptCategory` table, NEVER to `Transcript.category`.**

This plan delivers the **embedding store + writer AND a sibling category substrate**. Nothing reads embeddings or category rows yet except the sanity test.

---

## Scope

### In
- Schema V6: **two new `@Model` entities**, both keyed by `transcriptID: UUID`, persisted in the same SwiftData container as `Transcript`:
  - `TranscriptEmbedding` — the 384-d MiniLM vectors.
  - `TranscriptCategory` — substrate for future classifier output. **No consumers in this PR.**
  Lightweight V5→V6 migration appended; **V4→V5 stage already present in the uncommitted working tree (see §Schema sequencing) so devices upgrading from App Store production (V4) walk V4→V5→V6 in one launch.**
- `MiniLMEmbeddingService` (`Jot/App/Embeddings/`): loads `sentence-transformers/all-MiniLM-L6-v2` via `swift-embeddings`'s `Bert.loadModelBundle(from:)`, encodes text → `[Float]` of length 384 by materializing the returned `MLTensor` through `.cast(to:).shapedArray(of:).scalars`. Singleton `actor`, lazy first-launch download.
- `EmbeddingStore` (`Jot/Shared/DerivedData/`, wrapped in `#if JOT_APP_HOST`): typed wrapper around the `TranscriptEmbedding` entity — `fetch(forTranscriptID:)`, `upsert(...)`, `missingIDs(limit:)`, `count()`.
- **`CategoryStore` (`Jot/Shared/DerivedData/`, wrapped in `#if JOT_APP_HOST`):** typed wrapper around the new `TranscriptCategory` entity — `fetch(forTranscriptID:classifierVersion:) -> [TranscriptCategory]`, `upsert(transcriptID:category:confidence:classifierVersion:)`, `count(classifierVersion:)`. Mirrors `EmbeddingStore` shape. **Has zero callers in this PR** — present as the substrate-only sibling for a future classifier.
- Capture-time hook: `TranscriptStore.append(...)` and `PhoneSideWCSession.saveTranscript(...)` fire a non-blocking detached embedding write after the transcript save succeeds, **gated by `AppGroup.defaults.bool(forKey: "jot.embeddings.enabled")`** (default `true`; see §Lab kill-switch). **No category write fires from any hook** — `CategoryStore` is pure substrate.
- BG sweep: replaces the existing classifier BG task. **Renamed and re-typed to `BGAppRefreshTask`** so it can run on non-charging devices (MiniLM is light enough that the prior `requiresExternalPower = true` gate is unnecessary and is actively harmful for the "embeddings stale for days on a non-charging user" failure mode).
- Default-ON Lab toggle in Settings → About: `jot.embeddings.enabled` (default `true`), **stored in `AppGroup.defaults` for symmetry with the prior classifier Lab toggle (see §N3 rationale).** Cheap insurance against an MLTensor OOM regression surfacing in production; one Settings row, ~30 lines of code.
- Sanity test (`JotTests/MiniLMEmbeddingSanityTests.swift`): embeds three known strings, asserts cosine bounds. **Gated behind `JOT_RUN_INTEGRATION_TESTS=1` env var** so the 22 MB HF Hub fetch doesn't run on every PR.
- Pre-merge validation (one-time, documented, not in CI): compare 5-10 MiniLM vectors element-wise against Python `sentence-transformers` reference on iOS 26 simulator (L∞ bound).
- Qwen **classifier** removal: delete classifier-only files, remove call sites in `JotApp.init`, `SettingsView`, `TranscriptDetailView`, `ContentView`; clean up `AppGroup.Keys.classifierForegroundInFlight`; remove the residual `jot.classifier.enabled` UserDefaults key on first V6 launch (one-line cleanup); **call `BGTaskScheduler.shared.cancelAllTaskRequests()` once at JotApp.init to drop any pending iOS-scheduled `BGProcessingTaskRequest` under the old `classify-transcripts` identifier (see §N4).** **Qwen rewrite path is NOT touched.** Existing `Transcript.category` values from prior Qwen-classifier runs are **NOT migrated to `TranscriptCategory`** and **NOT erased** — see §Qwen removal for the explicit dead-data convention.
- `project.yml`: add `swift-embeddings` SwiftPM dependency to the main `Jot` target only. Rename BG identifier. Keep `processing` background mode and add the new `BGAppRefreshTask` identifier permission.

### Out (deferred)
- **All consumers.** No similarity search, no clustering, no Garden UI, no retrieval, no embedding-based classifier, **and no category writers**. Both new tables are pure substrate.
- **iCloud Drive sync** of embeddings or category rows. Backup-only, per default SwiftData behavior.
- **watchOS** embeddings. Watch produces audio, phone embeds after transcription. `swift-embeddings`'s `Package.swift` declares watchOS 10+ as a supported platform (verified) — we still choose not to link it from JotWatch.
- **Re-embedding on transcript edit.** v1 embeds the raw `text` at insert time; `rewriteUserEdit` changes are NOT picked up.
- **Cosine pre-computation index.** v1 stores raw `[Float]`; the future Garden feature will iterate and compute cosine in-memory for now.
- **Migration of legacy `Transcript.category` values** into `TranscriptCategory`. User direction (verbatim): "I would like to come back to that later or maybe just merge it alongside this and not use Qwen 3.5b and store it in a separate DB so that we can always work on it later on." The translation is: leave the old `category` field alone, ship the new substrate empty.
- **Increased-memory-limit entitlement** changes. MiniLM is expected at ~22 MB resident — but the actual runtime memory ceiling is a **measurement gate** before merge (see §Memory measurement gate).

---

## Why MiniLM-L6-v2 via swift-embeddings

- **Size.** 22 MB on disk vs. Qwen 3.5B's ~2.5 GB.
- **Latency.** ~30-50 ms per encode on A17 / M-series Apple Silicon (vendor-stated; measured pre-merge). Inline at capture time is invisible against Parakeet's ~200-500 ms tail. Qwen took 2-5 seconds per item.
- **General-purpose.** A 384-d sentence embedding feeds clustering, similarity search, and downstream classifiers.
- **No new MLX surface.** `swift-embeddings` uses Apple's `MLTensor` directly — no MLX, no CoreML compile step. Actual API (verified against jkrukowski/swift-embeddings README):
  ```swift
  let bundle = try await Bert.loadModelBundle(
      from: "sentence-transformers/all-MiniLM-L6-v2"
  )
  let encoded = bundle.encode("The cat is black")           // -> MLTensor
  let scalars = await encoded
      .cast(to: Float.self)
      .shapedArray(of: Float.self)
      .scalars                                              // -> [Float]
  ```
  Note the two awaits and the explicit materialization. Our public `MiniLMEmbeddingService.encode(_:) -> [Float]` hides this chain.
- **Decoupled from Qwen rewrite.** A future model swap (e.g. mpnet) is a `modelVersion` bump on `TranscriptEmbedding`. Qwen rewrite stays put.

### Transitive dependency surface

`swift-embeddings` pulls in four transitive SwiftPM dependencies:
- `huggingface/swift-transformers` (from 1.3.3)
- `jkrukowski/swift-safetensors`
- `jkrukowski/swift-sentencepiece`
- `apple/swift-numerics`

Two of the four come from the same single maintainer. The "library swap is contained to one file" mitigation in Risk 5 holds at the call-site level, but the **supply chain** surface is wider than a single package. Worth noting explicitly: an outage or breaking change in any of these four packages can block a Jot build until pinned versions are reset.

---

## Storage architecture: separate entities, same container

User decision (locked): **two new `@Model` entities** — `TranscriptEmbedding` and `TranscriptCategory` — in the SAME SwiftData container as `Transcript`. Both keyed by `transcriptID: UUID`. **No changes to `Transcript`'s shape.** The existing `Transcript.category` field stays in place as deprecated dead-data; see §Qwen removal for the convention.

### Why a separate `TranscriptEmbedding` entity (not a field on `Transcript`)

1. **Migration cycles decouple.** A future model swap (`minilm-l6-v2` → `mpnet-base-v2`) is a write to the embedding table only; `Transcript`'s schema doesn't move.
2. **Pollution.** `Transcript` already has 12 fields; appending a 384-element `[Float]` blob (~1.5 KB serialized) onto every row bloats the on-the-wire size of fetches that don't need it.
3. **Clean isolation for swap-experiments.** A future "try mpnet for two weeks, A/B against minilm" is a second `TranscriptEmbedding` row per transcript, distinguished by `modelVersion`.
4. **Garden read shape.** Future Garden read paths fetch `TranscriptEmbedding` rows directly with a `@Query(filter:)` predicate on `modelVersion`, then join to `Transcript` by `transcriptID` for display.

### Why a separate `TranscriptCategory` entity (not the existing `Transcript.category` field)

Same reasoning template as `TranscriptEmbedding`, applied to classification:

1. **Migration cycles decouple.** A future classifier swap (`qwen-3.5b-5class-v1` → `minilm-centroids-v1` → `gpt-tagger-v2`) is a write to the category table only. `Transcript`'s shape stays frozen.
2. **Classifier-version discriminator for A/B + iteration.** Multiple rows per `transcriptID` are valid (different classifiers can disagree). We keep all rows so future work can compare schemes head-to-head, train calibration, or roll back without losing prior labels. This is the SAME design move as `TranscriptEmbedding.modelVersion`.
3. **User-manual tags coexist with classifier output.** A future "user can tag a transcript manually" feature writes a row with `classifierVersion = "user-manual"` and `confidence = nil`. No special-case logic, no separate table.
4. **Clean sandbox for the deferred classifier.** When we revisit classification, all the substrate already exists: schema row, store wrapper, store-count diagnostic. The classifier PR is purely "add the writer," nothing more.
5. **Decouple from the dead `Transcript.category` field.** Reading/writing `Transcript.category` is *forbidden by convention* from V6 onward (see §Qwen removal). Putting the new substrate in a separate table makes the dead field structurally invisible to new code — no accidental writes via copy-paste of an old call site.

**No `@Attribute(.unique)` on `transcriptID` in `TranscriptCategory`.** Multiple rows per transcript are valid by design (different classifier versions). `CategoryStore.upsert` enforces one-row-per-(`transcriptID`, `classifierVersion`) by fetch-then-insert/update — the same shape as `EmbeddingStore.upsert`.

### Why same container (not a separate `.sqlite` file)

1. **One App Group store to manage.** Cross-process invariants, backup attributes, schema-fallback handling all stay in one place.
2. **SwiftData's `ModelContainer` handles multi-entity schemas natively.**
3. **Single transaction window** available if we ever need hard consistency.
4. **iCloud backup.** All three entities ride in the same `.sqlite` file at `Library/Group Containers/<group>/Library/Application Support/JotTranscripts.sqlite`, already backed up by default.

### What about backup size

- 22 MB model weights stay in HuggingFace cache (`Library/Caches/...`, unconditionally excluded by iOS).
- On-disk embedding data is ~1.5 KB × N_transcripts. At 10k transcripts that's ~15 MB.
- On-disk category rows are negligible (~50 bytes each, and the table is empty in this PR). Even a future classifier emitting one row per transcript adds < 1 MB at 10k.

---

## Schema sequencing — V4 → V5 → V6

**Critical context (verified against `git status` 2026-05-27):**
- `Jot/Shared/Schema/JotSchemaV5.swift` is currently UNTRACKED in the working tree.
- The V4→V5 stage in `JotMigrationPlan.swift` is a working-tree modification, NOT committed.
- Therefore App Store production builds (1.0.3, build 43) ship with **V4 as the latest schema version**.
- V5 has been on TestFlight only via uncommitted local builds — there is no current production user on V5.

This means real-device upgrades from App Store production to a V6 build walk the chain **V4 → V5 → V6** in one launch on first migrate. Both stages are lightweight-additive (V4→V5 adds `source` and `watchOriginUUID`; V5→V6 adds the `TranscriptEmbedding` AND `TranscriptCategory` entities). SwiftData applies stages sequentially.

**Implications for this PR:**
1. The V4→V5 stage commits **with** this PR (it is a dependency of the V5→V6 stage and cannot remain uncommitted indefinitely).
2. The first V6 build on a production device runs both stages back-to-back during the first `JotModelContainer.shared` access. Verify on a real device wiped to a production install of build 43.
3. Migration ordering is mechanically enforced by `JotMigrationPlan.stages` — no special handling needed beyond appending stages in chronological order.
4. **Schema-frozen invariant:** V4 is shipped; V5 is now also "shipped" via this PR (it becomes part of the migration chain in a TestFlight build); V6 is new. Once this PR merges, V4.swift and V5.swift are frozen for life under `scripts/check-schema-frozen.sh`.

### V6 diff from V5

New file: `Jot/Shared/Schema/JotSchemaV6.swift`. Copy of V5 with:
- `static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }`
- **`static var models: [any PersistentModel.Type] { [JotSchemaV6.Transcript.self, JotSchemaV6.TranscriptEmbedding.self, JotSchemaV6.TranscriptCategory.self] }`** — both new entities added, additive only.
- `JotSchemaV6.Transcript` is **identical** to `JotSchemaV5.Transcript` (the `category` field STAYS — already nil-by-default; removing it would require a `.custom` migration). **A banner comment is added directly above the `category` declaration in `JotSchemaV6.Transcript.swift`:**
  ```swift
  // DEAD-DATA — DO NOT READ OR WRITE.
  // From V6 onward, classification lives in TranscriptCategory.
  // This field is retained only because dropping it requires a
  // .custom migration that is out of scope for this PR. Values that
  // existed in V4/V5 (from prior Qwen classifier runs) are preserved
  // in place but ignored by every V6 code path.
  var category: String? // legacy — DEAD-DATA, see banner above
  ```
- New nested `@Model final class TranscriptEmbedding`:

```swift
@Model
final class TranscriptEmbedding {
    /// Stable join key to `Transcript.id`. Logical join — not a SwiftData
    /// `@Relationship` — so the embedding table can be re-populated
    /// independent of Transcript lifecycle.
    var transcriptID: UUID
    var vectorData: Data        // 384 floats packed (1536 bytes)
    var modelVersion: String    // e.g. "minilm-l6-v2"
    var embeddedAt: Date
}
```

- **New nested `@Model final class TranscriptCategory`:**

```swift
@Model
final class TranscriptCategory {
    /// Join key to Transcript.id. Same pattern as TranscriptEmbedding —
    /// logical join, not a SwiftData @Relationship.
    var transcriptID: UUID

    /// The classification label (e.g. "email", "note", "code", or
    /// whatever future schemes invent).
    var category: String

    /// Optional confidence score from the classifier. nil for manual
    /// user-applied labels.
    var confidence: Float?

    /// Classifier identity that produced this row. e.g.
    /// "qwen-3.5b-5class-v1" for historical, "minilm-centroids-v1" for
    /// the future embedding-based, "user-manual" for user-assigned.
    /// Mirrors the `modelVersion` discriminator on TranscriptEmbedding —
    /// multiple rows per transcriptID are valid (different classifiers
    /// can disagree; we keep all rows for A/B + future iteration).
    var classifierVersion: String

    /// When the row was written.
    var assignedAt: Date
}
```

**No `@Attribute(.unique)` on `transcriptID` for EITHER new entity in v1.** SwiftData unique constraints on new entities behave inconsistently across iOS versions under lightweight migration. `EmbeddingStore.upsert` and `CategoryStore.upsert` each enforce one-row-per-(transcriptID, version-discriminator) by fetch-then-insert/update. For `TranscriptCategory` this is explicitly correct because multiple rows per `transcriptID` (one per `classifierVersion`) are *valid by design*. See Open Question §2.

### Migration stage

Append to `JotMigrationPlan.stages` (alongside the V4→V5 stage that is committed in this PR):

```swift
.lightweight(
    fromVersion: JotSchemaV5.self,
    toVersion: JotSchemaV6.self
)
```

V5 → V6 is purely additive — two new entity types, no field changes to existing models. SwiftData's lightweight inference handles both new entity types automatically in a single stage.

### Companion edits

- `Jot/Shared/Transcript.swift`: bump typealias to `JotSchemaV6.Transcript`. Add typealiases `TranscriptEmbedding = JotSchemaV6.TranscriptEmbedding` AND **`TranscriptCategory = JotSchemaV6.TranscriptCategory`**. Add a `vector: [Float]` computed extension on `TranscriptEmbedding`.
- `Jot/Shared/TranscriptStore.swift:89`: change `Schema(versionedSchema: JotSchemaV5.self)` to `JotSchemaV6.self`.
- `Jot/Shared/TranscriptStore.swift:149`: legacy fallback `Schema([Transcript.self])` becomes **`Schema([Transcript.self, TranscriptEmbedding.self, TranscriptCategory.self])`** so fallback-path devices can read/write both new tables.
- `Jot/project.yml`: add `Shared/Schema/JotSchemaV6.swift` to the `JotWatch` `sources:` enumeration (verified: `project.yml:401-406` explicitly enumerates V1-V5 — every shipped VN is enumerated, never globbed, because most files in Shared/ import UIKit and won't compile on watchOS). Add the new V6 entry.
- `docs/schema-migrations.md` "Current versions" list: append V5 and V6 entries with date, build, summary. V6 summary explicitly notes BOTH new entities and that `TranscriptCategory` has no writers in this PR.

### Schema-fallback awareness — and the un-tested upgrade path

`TranscriptStore.swift:127` defensive fallback to non-versioned schema is unchanged in shape, but its `legacySchema` must include `TranscriptEmbedding.self` AND `TranscriptCategory.self`. **Risk surface (see Risk 1 below):** a device currently on the fallback path has been writing un-versioned data through earlier shipped builds. Adding TWO new `@Model` types to a store opened with inferred-only schema is **not** verified safe by code review alone. The §Verification section now includes a real-device fallback-active test that exercises both new tables.

---

## Code structure

```
Jot/Shared/
├── Schema/
│   ├── JotSchemaV1.swift … JotSchemaV5.swift  (frozen with this PR onward)
│   ├── JotSchemaV6.swift  (NEW — Transcript + TranscriptEmbedding + TranscriptCategory)
│   └── JotMigrationPlan.swift  (UPDATED — append V5 stage AND V6 stage)
├── Transcript.swift  (UPDATED — typealias bumps for Transcript, TranscriptEmbedding, TranscriptCategory)
├── TranscriptStore.swift  (UPDATED — V6 schema + embedding hook + legacySchema with both new types)
├── DerivedData/  (NEW directory — renamed from "Embeddings/" because it now houses multiple derived-data stores)
│   ├── EmbeddingStore.swift  (NEW — typed wrapper, #if JOT_APP_HOST)
│   └── CategoryStore.swift  (NEW — typed wrapper, #if JOT_APP_HOST, no callers in this PR)
└── ... (other files unchanged)

Jot/App/
├── Embeddings/  (NEW directory — runtime embedding service + BG task)
│   ├── MiniLMEmbeddingService.swift  (NEW — actor-isolated encoder)
│   └── EmbeddingBackfillTask.swift  (NEW — BGAppRefreshTask)
├── WatchConnectivity/
│   └── PhoneSideWCSession.swift  (UPDATED — embedding hook after saveTranscript)
├── JotApp.swift  (UPDATED — register EmbeddingBackfillTask, drop classifier, residual-key cleanup, BGTaskScheduler.shared.cancelAllTaskRequests())
├── Settings/
│   └── SettingsView.swift  (UPDATED — drop classifier Lab section; add embeddings Lab kill-switch + diag row)
├── TranscriptDetailView.swift  (UPDATED — drop category chip / classifier toggle reads)
├── ContentView.swift  (UPDATED — drop any classifier reads)
└── Classification/  (DELETED — entire directory except MemoryProbe moves)

Jot/Tests/
└── MiniLMEmbeddingSanityTests.swift  (NEW — gated by JOT_RUN_INTEGRATION_TESTS=1)
```

### Directory naming — `DerivedData/` vs `Embeddings/`

The Round-3 plan placed `EmbeddingStore.swift` under `Jot/Shared/Embeddings/`. With `CategoryStore.swift` joining as a sibling, the directory now houses two unrelated derived-data stores (an encoder output and a classifier output). Renaming the directory to **`Jot/Shared/DerivedData/`** reads better and reflects the actual shape: this is the home for typed wrappers around schema entities that are *derived from* Transcript but not part of Transcript. The `Jot/App/Embeddings/` runtime directory (housing `MiniLMEmbeddingService.swift` and `EmbeddingBackfillTask.swift`) keeps its name — those files genuinely are embedding-specific runtime.

### `EmbeddingStore` and `CategoryStore` placement — `#if JOT_APP_HOST` gating (verified)

Both `EmbeddingStore.swift` and `CategoryStore.swift` live at `Jot/Shared/DerivedData/` and are wrapped in `#if JOT_APP_HOST` matching the existing pattern in:
- `Jot/Shared/TranscriptStore.swift:48` (`#if JOT_APP_HOST` around the entire `JotModelContainer` + `TranscriptStore` body)
- `Jot/Shared/Classification/TranscriptClassifier.swift:10` (the same gate around the classifier)
- `Jot/Shared/RecordingPipelineDispatch.swift:4`

This compiles correctly for both:
- **Keyboard target** (`JotKeyboard`): compiles `Shared/` recursively but the `JOT_APP_HOST` flag is NOT set, so both `EmbeddingStore` and `CategoryStore` are excluded entirely. No reference to `JotModelContainer.shared` reaches the keyboard.
- **Watch target** (`JotWatch`): enumerates a specific list of `Shared/` files in `project.yml:401-408` and does NOT include either file under `Shared/DerivedData/`. Both new files are invisible to the watch build by source-list omission. (Even if they were listed, the `JOT_APP_HOST` gate would still hide them.)

Defense in depth: both the `#if` gate AND the source-list omission protect non-app targets.

### `MemoryProbe.swift` is preserved

Moved from `Jot/App/Classification/MemoryProbe.swift` to `Jot/App/Diagnostics/MemoryProbe.swift`. Reused by embedding backfill diagnostics.

---

## `MiniLMEmbeddingService` design

```swift
actor MiniLMEmbeddingService {
    static let shared = MiniLMEmbeddingService()

    static let modelVersion = "minilm-l6-v2"

    /// Lazy bundle. Holds the swift-embeddings ModelBundle.
    private var bundle: Bert.ModelBundle?
    private var loadTask: Task<Bert.ModelBundle, Error>?

    /// Cold-load the model from HuggingFace cache (or download if absent).
    /// First call from cold can take several seconds (network fetch + MLTensor
    /// warmup); subsequent calls return immediately. Multiple concurrent
    /// callers share one in-flight load via loadTask.
    func prewarm() async throws

    /// Encode a single string. Returns a 384-element [Float].
    /// Internally:
    ///   let encoded = bundle.encode(text)
    ///   return await encoded.cast(to: Float.self).shapedArray(of: Float.self).scalars
    /// The two awaits + materialization force MLTensor evaluation at the
    /// boundary so intermediates are released between encodes. See B2 / §425.
    func encode(_ text: String) async throws -> [Float]
}
```

**Actor isolation (NOT `@MainActor`):** the encoder is a pure transform with no UI state. Holding the MainActor would freeze the UI for ~30-50ms per encode, which is a measurable scroll hitch. The `bundle` + `loadTask` shared state is exactly what an `actor` is for. Callers `await` from any context; the encode runs on the actor's executor; the result is `Sendable` (`[Float]`).

**Materialization between encodes — MLTensor lazy-eval defense:**

There is an open upstream issue (jkrukowski/swift-embeddings#25) documenting that `MLTensor` accumulates per-layer intermediates and can spike memory dramatically on long batches. A contributor measured ~70 GB peak on a 12-layer NomicBERT model at 8192 tokens. For MiniLM (6 layers, 512 max tokens) the ceiling is much lower, but the pattern is real and the issue is OPEN.

**Our defense:** every `encode(_:)` call awaits `.shapedArray(of: Float.self).scalars` before returning. `.shapedArray` is a materialization point that forces MLTensor to compute and release intermediates. The BG sweep loop therefore cannot accumulate state across encodes — each `await encode(...)` call ends with a fully materialized `[Float]` and no live `MLTensor`.

**Pre-warm site:** `JotApp.init` schedules a non-blocking `Task(priority: .utility) { try? await MiniLMEmbeddingService.shared.prewarm() }` after the existing Parakeet warm-up tasks.

**Failure modes** (unchanged from prior draft): network unavailable → throw → BG sweep retries; HF cache corrupt → throw → 22 MB re-download; MLTensor unavailable → log + carry on.

**Public API contract:** `encode(_:) -> [Float]` is the ONLY public method besides `prewarm()`. Callers do not see `ModelBundle` or `MLTensor`.

---

## Memory measurement gate (pre-merge)

Before this PR merges, run this measurement on-device:

1. Cold-launch app with the MiniLM build.
2. Fire `EmbeddingBackfillTask` manually with the **initial `batchSize = 25`** on a backlog of ≥100 transcripts.
3. **Also measure cold-prewarm timing:** suspend the app, wait for `MiniLMEmbeddingService.shared.bundle` to be reaped (or simulate via test injection), then fire the BG handler and time the prewarm call. Record this number — it goes into the §BG sweep budget math.
4. Observe peak resident memory via Instruments (Allocations + VM Tracker) and via `os_proc_available_memory()` in `MemoryProbe`.

**Gate:**
- If peak resident stays under 150 MB during the 25-row batch AND cold-prewarm completes in under 10s: ship `batchSize = 25`. Bumping to 50 is a follow-up after a week of field telemetry shows the cold-prewarm tax is bounded.
- If peak resident exceeds 150 MB but stays under 250 MB: drop `batchSize = 10` and ship; revisit.
- If peak resident exceeds 250 MB OR cold-prewarm exceeds 15s consistently: investigate MLTensor lazy-eval (issue #25 may be biting) / model-load slowness; consider force-materialization between encodes via an explicit `Task.yield()` + a small async pause; do NOT ship until under 250 MB peak and prewarm under 15s.

This is a hard gate, not aspirational. The prior Qwen failure mode was exactly an undefended memory assumption that turned into jetsam in the field. The `BG memory budget on a 6 GB device is around 200-300 MB` claim from the prior draft is replaced with an actual measurement.

**Why `batchSize = 25` initially (not 50):** the first BG fire after suspend pays the cold-prewarm tax (model bundle is nil, must be reloaded). Halving the batch leaves headroom for that tax inside the 30s budget. See §BG sweep design for the full cold-prewarm math.

---

## `EmbeddingStore` design

Wrapped in `#if JOT_APP_HOST`. Mirrors `TranscriptStore` shape: enum with `@MainActor` static methods, fresh `ModelContext` per call.

```swift
#if JOT_APP_HOST
@MainActor
enum EmbeddingStore {
    static func fetch(forTranscriptID id: UUID) -> TranscriptEmbedding?
    static func upsert(transcriptID: UUID, vector: [Float], modelVersion: String) throws
    static func missingIDs(limit: Int, modelVersion: String) -> [UUID]
    static func count(modelVersion: String) -> Int
}
#endif
```

`missingIDs` implementation uses two ID-only fetches and a Set diff (SwiftData's `#Predicate` doesn't reliably support cross-entity subqueries). For v1 with N_transcripts < 100k this is fine. Per-row save in `upsert` (no batching) keeps memory bounded and makes mid-batch cancellation safe.

---

## `CategoryStore` design

Wrapped in `#if JOT_APP_HOST`. Mirrors `EmbeddingStore` shape exactly: enum with `@MainActor` static methods, fresh `ModelContext` per call. **No callers in this PR** — present as substrate.

```swift
#if JOT_APP_HOST
@MainActor
enum CategoryStore {
    /// Returns ALL rows for the given transcript matching the classifierVersion.
    /// Multiple rows can match if the same classifierVersion has been re-run
    /// — caller picks the most recent by `assignedAt`. (Typically 0 or 1.)
    /// Pass `classifierVersion: nil` (default) to retrieve rows from every
    /// classifier that has ever labeled this transcript — useful for the
    /// future A/B compare path.
    static func fetch(forTranscriptID id: UUID,
                      classifierVersion: String? = nil) -> [TranscriptCategory]

    /// Insert or update the (transcriptID, classifierVersion) row.
    /// confidence is nil for user-manual labels.
    static func upsert(transcriptID: UUID,
                       category: String,
                       confidence: Float?,
                       classifierVersion: String) throws

    /// Count of rows for a given classifier — used by Settings diagnostic.
    /// Returns 0 for the empty substrate state shipped in this PR.
    static func count(classifierVersion: String) -> Int
}
#endif
```

**Uniqueness:** like `EmbeddingStore`, `upsert` is implemented as fetch-then-insert/update to enforce one-row-per-(`transcriptID`, `classifierVersion`). **Multiple rows per `transcriptID`** are valid by design — they represent different classifier versions disagreeing, or a user-manual tag coexisting with an automated label.

**`missingIDs` is intentionally absent in v1.** No classifier writer exists in this PR, so there is nothing to "backfill" against. When a future classifier ships, it adds the equivalent method scoped to its own `classifierVersion`.

**Documentation block on the file:** the top of `CategoryStore.swift` includes a banner explaining that `Transcript.category` (the old field) is dead data and that this store is the canonical write target for any future classification work. Mitigates the mental-model footgun called out in Risk 7.

---

## Capture hook integration

### `TranscriptStore.append(...)` — main app capture path

Hook placement: AFTER `context.save()` succeeds, BEFORE `return transcript`. Fire-and-forget — must NOT block the return or fail the append. **Kill-switch guard is included inline** — copy this snippet verbatim and the kill switch is honored. **No category write happens here** — `CategoryStore` has no writer in this PR.

```swift
try context.save()
TranscriptHistoryMirror.refresh(from: context)
CrossProcessNotification.post(name: .historyMirrorUpdated)

// Kill switch — see §Lab kill-switch (default true).
// Stored in AppGroup.defaults for symmetry with the prior classifier toggle.
guard AppGroup.defaults.bool(forKey: "jot.embeddings.enabled") else {
    return transcript
}

let parakeetOutput = raw   // For both paths we embed the Parakeet output string.
let idForEmbedding = transcript.id
Task.detached(priority: .utility) {
    do {
        let vector = try await MiniLMEmbeddingService.shared.encode(parakeetOutput)
        await MainActor.run {
            try? EmbeddingStore.upsert(
                transcriptID: idForEmbedding,
                vector: vector,
                modelVersion: MiniLMEmbeddingService.modelVersion
            )
        }
    } catch {
        logger.debug("inline embed failed for id=\(idForEmbedding): \(error.localizedDescription)")
    }
}

return transcript
```

**Why `Task.detached` (NOT a structured `Task { }`):** the actor switch on `MiniLMEmbeddingService` is why `Task.detached` works correctly here — calling `await encode(...)` from inside the detached task hops to the actor's executor (off MainActor), preventing the 30-50ms encode from blocking UI. A structured `Task { }` would inherit the caller's MainActor isolation and round-trip the encode through MainActor anyway. **Do not "simplify" `Task.detached` to `Task` — it silently re-introduces a UI freeze.**

**Detached task race + BG fallback — addressed:** The prior draft used `requiresExternalPower = true` on the BG fallback. That meant: user dictates → save returns → user backgrounds app within ~50ms → detached `.utility` task never starts → iOS suspends app → row missing → BG sweep only runs **when charging**, potentially hours or days later. For a non-charging user, every captured transcript could lack an embedding for a day or more — and Garden's "this week's themes" reads will be empty.

**Fix:** the embedding backfill task uses `BGAppRefreshTask` (not `BGProcessingTask`) with NO `requiresExternalPower` requirement. `BGAppRefreshTask` runs on opportunistic idle moments throughout the day independent of charging state. The trade-off is a 30-second wall-clock budget per fire vs. `BGProcessingTask`'s ~10-minute budget — but MiniLM at ~30-50 ms × `batchSize = 25` is ~1 s plus cold-prewarm tax, comfortably inside the 30-second budget. See §BG sweep design for the full task lifecycle.

**Watch path** (`PhoneSideWCSession.saveTranscript`) gets the same hook with the same semantics, **including the same `guard AppGroup.defaults.bool(forKey: "jot.embeddings.enabled") else { return }` guard before the detached task is spawned.** The "raw vs cleaned" framing applies only to `TranscriptStore.append` (which has both `raw` and `cleanedText` available); for the watch path the input is already the Parakeet output string. Either way: **both paths embed the Parakeet output string** (whatever variable name it lives under at the call site).

### What `text` do we embed?

**Decision: the Parakeet output text at insert time** — neither cleaned text (which may not be ready yet) nor `rewriteUserEdit` (which is asynchronous and out of scope). Re-embed-on-edit is deferred.

---

## BG sweep design

### Task type change — `BGAppRefreshTask` (not `BGProcessingTask`)

The existing classifier task is a `BGProcessingTaskRequest` with `requiresExternalPower = true` because Qwen at 2.5 GB needed charging to avoid jetsam during 2-5s inferences. MiniLM has neither constraint:
- 22 MB model, 30-50 ms per encode → fits well inside `BGAppRefreshTask`'s 30s budget.
- No reason to require charging — keeps the embedding table fresh for non-charging users.

`BGAppRefreshTask` is iOS's "small periodic background work" task type. Apple's docs schedule it opportunistically a few times per day. Combined with the inline hook covering 99% of captures, this gives us:
- **Fast path:** inline embed during foreground (~30-50 ms after `context.save`).
- **Backstop path:** `BGAppRefreshTask` fires within hours (not days) on a non-charging device to backfill any rows the inline path missed.

### BG budget math — cold-prewarm tax included

Naïve math: 25 × 30-50ms = ~0.75–1.25s, far inside 30s. **But on a cold BG fire (app suspended), `MiniLMEmbeddingService.shared.bundle` is nil and `prewarm()` must reload the model. Service's own doc says "first call from cold can take several seconds."** Real worst-case budget on cold BG fire:

```
cold_prewarm (3–10s observed range, measured pre-merge) + 25 × ~50ms encodes (~1.25s) = 4.25–11.25s
```

This still fits the 30s budget, but with much less headroom than the prior draft implied.

**Defenses:**
1. **Initial `batchSize = 25` (not 50).** Halves the encode time so the cold-prewarm tax has room. Bumping to 50 is a follow-up after telemetry shows the prewarm tail is bounded.
2. **Hard prewarm-timeout guard in the handler:** if `prewarm()` takes > 15s, abort the batch (return processed=0; next BG fire retries on a fresh cycle). Code shape:
   ```swift
   let prewarmStart = Date()
   try await withTimeout(seconds: 15) {
       try await MiniLMEmbeddingService.shared.prewarm()
   }
   let prewarmElapsed = Date().timeIntervalSince(prewarmStart)
   logger.info("BG prewarm took \(prewarmElapsed)s")
   if prewarmElapsed > 15 { task.setTaskCompleted(success: false); return }
   ```
   This defends against the cold-prewarm tail eating the entire 30s budget and the encode loop getting killed by `expirationHandler` mid-batch.

### Identifier rename

Old: `com.vineetu.jot.mobile.Jot.classify-transcripts` (`BGProcessingTaskRequest`, removed)
New: `com.vineetu.jot.mobile.Jot.backfill-embeddings` (`BGAppRefreshTaskRequest`, added)

The two coexist for one launch cycle in iOS's BG scheduler state — see §"Old identifier removal" below.

### `project.yml` change

```yaml
BGTaskSchedulerPermittedIdentifiers:
  - com.vineetu.jot.mobile.Jot.backfill-embeddings
```

### Old identifier removal — soft claim, with verification AND defensive cancellation

Removing the old identifier from `Info.plist` while iOS may still hold in-flight `BGProcessingTaskRequest`s under it: per Apple's BGTaskScheduler documentation, requests for an identifier not in `BGTaskSchedulerPermittedIdentifiers` are not delivered. iOS does not document whether they are silently dropped, logged-and-dropped, or surfaced. The prior draft's "harmless" claim is undefended.

**Verified claim:** on first cold launch of the V6 build, watch Console.app for any messages mentioning `classify-transcripts` or `BGTaskSchedulerErrorDomain`. The absence of such log lines is the verification gate. If they appear, document the actual behavior and revisit.

**Defensive cancellation (NEW, §N4):** at `JotApp.init` for the V6 build, call:
```swift
// Idempotent, cheap. Drops any pending iOS-scheduled BGProcessingTaskRequest
// under the old `classify-transcripts` identifier before the new
// `backfill-embeddings` identifier registers. Closes the "iOS holds a stale
// request" failure mode entirely. Verified safe: the classifier task is the
// only BG scheduler user today, so this clears nothing in active use.
BGTaskScheduler.shared.cancelAllTaskRequests()
```

This runs **before** `EmbeddingBackfillTask.register()` so the new identifier's registration is unaffected. It's a one-line addition to JotApp.init.

### Handler shape

Same drain loop as before but with `BGAppRefreshTask` semantics and the prewarm-timeout guard:

```
drainBatch:
    if !AppGroup.defaults.bool(forKey: "jot.embeddings.enabled"): return 0  // kill switch
    let missing = EmbeddingStore.missingIDs(limit: batchSize, modelVersion: currentVersion)
    if missing.isEmpty: return 0
    let prewarmStart = Date()
    try await withTimeout(seconds: 15) { try await MiniLMEmbeddingService.shared.prewarm() }
    if Date().timeIntervalSince(prewarmStart) > 15: setTaskCompleted(success: false); return 0
    for id in missing:
        if Task.isCancelled: break  // expiration handler
        let transcript = fetch Transcript by id
        let vector = try await MiniLMEmbeddingService.shared.encode(transcript.text)
        try EmbeddingStore.upsert(...)
        processed += 1
    return processed
```

### Batch size — gated by §Memory measurement gate

**Default plan: 25 per fire.** Subject to the measurement gate above. Increase to 50 only after a week of field data shows the cold-prewarm tail is bounded.

### Checkpoint / resume

Per-row save IS the checkpoint. Mid-batch cancellation by `expirationHandler` leaves the table consistent. The next BG fire resumes via `missingIDs(limit:)`.

### Lab kill-switch (DEFAULT-ON)

`jot.embeddings.enabled` UserDefaults key, default `true`. **Stored in `AppGroup.defaults`** (not `UserDefaults.standard`) for symmetry with the prior classifier Lab toggle which lives in `AppGroup.defaults` (verified at `SettingsView.swift:45`). Surfaced in Settings → About:

> **Embeddings**
> [Toggle: Enable on-device embeddings] (ON by default)
> 1,234 transcripts embedded ✓

Why a toggle even though embeddings are foundation work:
1. **Emergency kill switch.** If the §Memory measurement gate clears but the field discovers an MLTensor OOM at scale (e.g., a 50-row batch on a 5k-transcript user) we need a remote-friendly way for affected users to opt out before we ship a hotfix. Without this, the only mitigation is "TestFlight a fix and wait."
2. **Privacy / user agency.** The Qwen classifier had an opt-in toggle. Going from opt-in to no-choice-at-all is a regression for users who care.
3. **Symmetric with Qwen rewrite path** (also user-controllable model state).
4. **Cost is tiny.** One Settings row, one UserDefaults key, **one boolean check in three places: `TranscriptStore.append` hook (`AppGroup.defaults.bool(forKey: "jot.embeddings.enabled")`), `PhoneSideWCSession.saveTranscript` hook (same), `EmbeddingBackfillTask.submitIfBacklog` + the handler drain loop (same).** All three sites read the same `AppGroup.defaults` store — easier to reason about for a maintainer who already knows where the classifier toggle lives. ~30 lines total.

The default is ON because we believe the substrate is needed for foundation work. The toggle gates **execution**, not the **schema** — the `TranscriptEmbedding` AND `TranscriptCategory` tables exist regardless; they're just empty for opted-out users (and `TranscriptCategory` is empty for every user in this PR).

### Submission site

```swift
// JotApp.swift around line 450, replaces classifier submit:
EmbeddingBackfillTask.submitIfBacklog()  // gated by AppGroup.defaults.bool(forKey: "jot.embeddings.enabled") + queueDepth > 0

// New: cold-launch backlog submit, post-Parakeet-warmup:
Task(priority: .utility) { @MainActor in
    EmbeddingBackfillTask.submitIfBacklog()
}
```

`submitIfBacklog` is the renamed `submitIfEnabled`. It drops:
- the `AppGroup.defaults.bool(forKey: labKey)` guard for the classifier key → replaced by `AppGroup.defaults.bool(forKey: "jot.embeddings.enabled")` check (default true).
- the `LLMClientFactory.shared.currentProviderWeightsOnDisk` guard → MiniLM has its own model availability; this guard belonged to the classifier path.

It keeps:
- the `queueDepth > 0` guard.

---

## Qwen removal — classifier ONLY, NOT the rewrite path

**Critical scope clarification.** Qwen ships TWO orthogonal use cases:
1. **Classifier** (`TranscriptClassifier.swift`, `TranscriptClassifierTask.swift`, `ClassificationsDashboardView.swift`, `CategoryChip.swift`) — removed by this PR.
2. **Rewrite** (`Qwen35Client.swift`, accessed via `LLMClientFactory.shared.client().rewrite(...)`) — **NOT touched**. The AI Settings UI, the download CTA, the rewrite call sites in `TranscriptDetailView` / `AIRewriteSettingsView` / `RewriteRequestDispatcher` all keep `currentProviderWeightsOnDisk` references.

The plan-§437 line "Drop the `currentProviderWeightsOnDisk` guard" applies ONLY inside `TranscriptClassifierTask.submitIfEnabled` (which is being deleted with the rest of the classifier). The property itself stays on `LLMClientFactory` because `AIOfferStep`, `AIRewriteSettingsView`, `JotDesign`, `Qwen35Client`, and `TranscriptDetailView` (the rewrite path call site at line 1342) still reference it.

### Dead-data convention for the existing `Transcript.category` field

User direction (verbatim): *"I would like to come back to that later or maybe just merge it alongside this and not use Qwen 3.5b and store it in a separate DB so that we can always work on it later on."*

Translation, locked as policy from V6 onward:

> **Existing `Transcript.category` values from earlier Qwen runs are NOT migrated to `TranscriptCategory`. Reading `Transcript.category` is forbidden by convention going forward — nothing in V6 code paths reads it. It's left in place only because `.custom` migration to drop it is out-of-scope for this PR.**

Enforcement is by convention, not by compiler:
- The banner comment in `JotSchemaV6.Transcript.swift` (see §Schema V6 diff) reminds every future reader.
- The banner comment at the top of `CategoryStore.swift` reinforces that `TranscriptCategory` is the canonical write target for ALL future classification work.
- A future classifier (embedding-based or otherwise) writes to `TranscriptCategory.classifierVersion = "minilm-centroids-v1"` (or whatever scheme it ends up using).
- Re-introducing the old Qwen classifier (if we ever revisit) writes to `classifierVersion = "qwen-3.5b-5class-v1"` so historical and new rows are distinguishable.
- User-manual tags (if ever added) write `classifierVersion = "user-manual"` with `confidence = nil`.

The deprecated `category` field continues to hold whatever the Qwen classifier last wrote on devices that ran it. On fresh installs it is nil-by-default. Neither is exposed in V6 UI.

### Files to delete

- `Jot/Shared/Classification/TranscriptClassifier.swift`
- `Jot/App/Classification/TranscriptClassifierTask.swift`
- `Jot/App/Classification/ClassificationsDashboardView.swift`
- `Jot/App/Classification/CategoryChip.swift`

### Files to update

- `Jot/App/Classification/MemoryProbe.swift` → move to `Jot/App/Diagnostics/MemoryProbe.swift`. No content change.
- `Jot/App/JotApp.swift`:
  - **NEW (§N4):** add `BGTaskScheduler.shared.cancelAllTaskRequests()` as the **first** BG-related line in `init`, BEFORE `EmbeddingBackfillTask.register()`. Cheap, idempotent, drops any stale `classify-transcripts` request iOS may still hold.
  - Replace `TranscriptClassifierTask.register()` with `EmbeddingBackfillTask.register()`.
  - Drop the stale-clear of `classifierForegroundInFlight` (key is removed).
  - Replace `TranscriptClassifierTask.submitIfEnabled()` with `EmbeddingBackfillTask.submitIfBacklog()`.
  - **NEW:** add a one-time `UserDefaults` cleanup on first V6 launch to remove the residual `jot.classifier.enabled` key from previously-installed devices:
    ```swift
    // Once-per-install cleanup of dead classifier state.
    AppGroup.defaults.removeObject(forKey: "jot.classifier.enabled")
    ```
    (Idempotent; safe to leave in place forever.)
- `Jot/App/Settings/SettingsView.swift`:
  - Drop `@State classifierEnabled` and its UserDefaults read.
  - Drop the `onChange(of: classifierEnabled)` block.
  - Drop the entire "LAB FEATURES" classifier section.
  - **ADD:** "Embeddings" section in Settings → About containing the `jot.embeddings.enabled` toggle (reads/writes `AppGroup.defaults`) and `EmbeddingStore.count(modelVersion:)` diag row.
- `Jot/App/TranscriptDetailView.swift`:
  - Drop `@State classifierLabEnabled` and its read.
  - Drop the `onAppear` / scene-active observer for the toggle.
  - Drop the `CategoryChip` render and the surrounding `if classifierLabEnabled` block.
- `Jot/App/ContentView.swift`: grep shows only one comment line — no functional reads. No change needed.
- `Jot/Shared/AppGroup.swift`: drop `AppGroup.Keys.classifierForegroundInFlight`.
- `Jot/Shared/TranscriptStore.swift`: drop the explicit `category: nil` argument from the Transcript initializer call. V6 `Transcript` initializer still accepts `category` (the field stays — deprecated).

### project.yml updates

- `BGTaskSchedulerPermittedIdentifiers`: replace `classify-transcripts` with `backfill-embeddings`.
- Add `packages:` entry:
  ```yaml
  SwiftEmbeddings:
    url: https://github.com/jkrukowski/swift-embeddings
    minVersion: "0.0.16"
    maxVersion: "1.0.0"
  ```
- Add to `Jot` target only (NOT JotKeyboard, NOT JotWatch):
  ```yaml
  - package: SwiftEmbeddings
    product: Embeddings
  ```

---

## Sanity-check test — gated, not on every PR

`Jot/Tests/MiniLMEmbeddingSanityTests.swift`:

```swift
import Testing
@testable import Jot

@MainActor
@Suite("MiniLM embedding sanity")
struct MiniLMEmbeddingSanityTests {
    @Test("Semantically similar pairs cluster; distant pair separates",
          .enabled(if: ProcessInfo.processInfo.environment["JOT_RUN_INTEGRATION_TESTS"] == "1"))
    func sanityCheckThreeStrings() async throws {
        let a = "I need to send an email to my team about the deadline."
        let b = "Draft a quick note to the team regarding the deadline."
        let c = "The recipe calls for two cups of flour and a pinch of salt."

        let svc = MiniLMEmbeddingService.shared
        let va = try await svc.encode(a)
        let vb = try await svc.encode(b)
        let vc = try await svc.encode(c)

        let abSim = cosine(va, vb)
        let acSim = cosine(va, vc)
        let bcSim = cosine(vb, vc)

        // Thresholds calibrated against the §Threshold calibration step below.
        // ±0.1 envelope around the measured Python sentence-transformers reference.
        #expect(abSim > 0.6, "expected close pair similarity > 0.6, got \(abSim)")
        #expect(acSim < 0.2, "expected distant pair similarity < 0.2, got \(acSim)")
        #expect(bcSim < 0.2, "expected distant pair similarity < 0.2, got \(bcSim)")
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float { /* dot / (|a||b|) */ }
}
```

### Threshold calibration — required pre-merge measurement

Before this PR merges, run the three test strings through Python `sentence-transformers` with model `all-MiniLM-L6-v2`:

```python
from sentence_transformers import SentenceTransformer, util
m = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
a, b, c = m.encode([...])  # the three test strings
print(util.cos_sim(a, b), util.cos_sim(a, c), util.cos_sim(b, c))
```

Record the three reference cosines in this plan (as a code comment in the test file). Set assertion thresholds at reference ± 0.1. If the prior draft's intuited thresholds (0.5 / 0.3) survive — fine; if they don't, update.

### Tokenizer-correctness validation — also required pre-merge

A 3-string cosine test catches catastrophic failure (all-zero vectors, random outputs) but would silently pass slightly-wrong-but-correlated embeddings. There is documented prior art for tokenizer mismatches in this exact library: jkrukowski/swift-embeddings#5 traced an off-by-one token-ID bug between Swift and Python for XLMRoberta (worked around via a `tokenOffset` parameter). MiniLM uses `BertTokenizer` not `XLMRoberta` so the specific bug doesn't apply, but the class of bug exists.

**Strategy (one-time, documented, NOT in CI):**
1. Pick 5-10 fixed strings spanning short / long / punctuation / numerals / unicode.
2. Encode in Python with `sentence-transformers` (`all-MiniLM-L6-v2`) → 384-d vectors.
3. Encode the same strings on the iOS 26 simulator with `MiniLMEmbeddingService`.
4. Compare element-wise: L∞ < 0.01 (per-element absolute difference < 0.01).
5. If any string exceeds the bound, suspect tokenizer drift — investigate before merge.

The L∞ < 0.01 bar accommodates legitimate floating-point divergence between Apple Silicon MLTensor and Python PyTorch but flags semantic mismatches (e.g., wrong token IDs that produce correlated-but-shifted outputs).

This is a **one-time pre-merge validation**, not a CI test. The result gets recorded as a code comment in `MiniLMEmbeddingService.swift` for future model-swap validation.

### Why the in-CI test is gated by an env var

The sanity test performs a 22 MB HuggingFace Hub fetch on cold cache. Running on every PR:
1. Hits HF Hub rate limits if the bot scales.
2. Pollutes the singleton model state across tests.
3. Adds 5-10 seconds to CI cold-cache runs.

Gating behind `JOT_RUN_INTEGRATION_TESTS=1` lets us run the test deliberately (locally, or on a nightly job) without burning CI minutes on every push.

---

## swift-embeddings integration

### Package version

```yaml
SwiftEmbeddings:
  url: https://github.com/jkrukowski/swift-embeddings
  minVersion: "0.0.16"
  maxVersion: "1.0.0"
```

Open range allows minor bumps but blocks a breaking 1.0. Current latest as of May 2026 is 0.0.27.

### What's imported

```swift
import Embeddings  // top-level module name per the README
```

Used only inside `MiniLMEmbeddingService.swift`. Enters the codebase through a single point.

### Linking constraints

- `Jot` target: links `Embeddings`.
- `JotKeyboard`: does NOT link. Keyboard never embeds.
- `JotWatch`: does NOT link. swift-embeddings does declare `watchOS 10+` as a supported platform in its `Package.swift` (verified by reviewer) — we choose not to link it because the watch produces audio, phone embeds after transcription.

### Model download semantics

First `Bert.loadModelBundle(from:)` call downloads to `~/Library/Caches/huggingface/hub/`. Backup-excluded by virtue of `Library/Caches/`. No `BackupExclusion.exclude(...)` needed.

---

## Pre-warm strategy

### First-launch download UX

22 MB on first encode. ~2 seconds WiFi, ~5-10 seconds cellular. **No user-facing UX for v1.** Pre-warm fires from `JotApp.init` as a non-blocking detached task in parallel with Parakeet warm-up. If the user dictates before pre-warm completes, the inline embedding hook still fires but blocks on the same `loadTask` future internally — worst case is the first transcript's embedding write takes ~5 seconds instead of 50 ms. The transcript save is unblocked.

### Cold-start time

Pre-warm is `.utility` priority. No measurable impact on cold-start.

---

## Risk surface (top 7)

### Risk 1: Schema V6 migration breaks on devices on the non-versioned fallback path

`TranscriptStore.swift:127-170` defensive fallback opens a non-versioned schema when the VersionedSchema path fails. Devices currently on the fallback have been writing un-versioned data through earlier shipped builds. Adding **two** `@Model` types to a store opened with inferred-only schema is **not** verified safe by the plan or by code review.

**Mitigation:**
- The legacy fallback's `Schema([Transcript.self])` is updated to `Schema([Transcript.self, TranscriptEmbedding.self, TranscriptCategory.self])` so writes to either new entity succeed on fallback devices.
- **§Verification explicitly includes a real-device fallback-active test** that exercises both new tables:
  1. Simulate a fallback-active device by manually clearing the flag at the verified key: `UserDefaults.standard.removeObject(forKey: "jot.schema.fallbackActiveSince_v1")` — this is the actual key set at `TranscriptStore.swift:163` and it lives in `UserDefaults.standard` (NOT `AppGroup.defaults`).
  2. Install build 43, dictate ≥5 transcripts.
  3. Install the V6 build.
  4. Verify embedding writes succeed without `[SCHEMA-FALLBACK]` log lines (or with — acceptable as long as the writes succeed).
  5. Verify the `TranscriptEmbedding` rows are queryable on the device after upgrade.
  6. **NEW:** verify `CategoryStore.count(classifierVersion: "qwen-3.5b-5class-v1")` returns 0 (no rows auto-created from legacy `Transcript.category` values) AND that a manual `CategoryStore.upsert(...)` test write succeeds. This confirms the empty-substrate behavior is correct on fallback devices.

**Migration-ordering note for fallback-active devices (NEW, §N5):** fallback-active devices (the ones with `jot.schema.fallbackActiveSince_v1` set in `UserDefaults.standard`) don't run the V4→V5 or V5→V6 migration stages — SwiftData re-infers the latest shape directly from the model types it's handed. Both stages are lightweight-additive, so this is safe, but worth calling out so a future engineer doesn't expect to see V4→V5 migration logs on those devices. The "no `[SCHEMA-FALLBACK]` log lines" verification gate still holds for the versioned-path devices.

### Risk 2: First-launch model download fails on cellular-only devices with low data quotas

22 MB is small but non-zero. **Mitigation:** detached `.utility` priority means iOS may defer to WiFi. Cached after first download. BG sweep biases to opportunistic windows.

### Risk 3: Detached Task ordering — embedding hook fires before SwiftData commit is visible

The hook keys off `transcriptID: UUID`, not a SwiftData relationship. **Mitigation:** the embedding row can exist before, after, or independently of the transcript row's full hydration. The lookup returns nil if not yet written — handled the same as "no embedding yet." The same property holds for any future `TranscriptCategory` writers.

### Risk 4: Detached Task race + BG fallback gap (CRITICAL)

User dictates → save returns → user backgrounds the app within ~50ms → detached `.utility` task never starts → iOS suspends app → embedding row missing. The prior draft's BG fallback was `BGProcessingTask` with `requiresExternalPower = true` — won't run for hours or days unless the user plugs in. For a non-charging user, every captured transcript could lack an embedding for a day or more.

**Mitigation (incorporated into §BG sweep design):**
- BG fallback is `BGAppRefreshTask` (no charging requirement). iOS schedules these multiple times per day on idle moments.
- 30-second budget covers the cold-prewarm tail (3–10s observed) plus the encode loop (25 × 30–50ms = ~1.25s).
- Cold-prewarm timeout guard at 15s prevents the prewarm tail from eating the entire budget and the encode loop from getting killed by `expirationHandler` mid-batch.
- Combined with the inline hook covering 99% of captures, the worst-case backstop is hours, not days.

### Risk 5: MLTensor lazy-eval OOM (upstream issue #25 — OPEN)

Issue #25 documents `MLTensor` accumulating per-layer intermediates with no automatic release. Contributor measured 70 GB peak on NomicBERT-12-layer at 8192 tokens. Still OPEN as of today.

**Mitigation:**
- Every encode awaits `.shapedArray(of: Float.self).scalars` which is a materialization point — intermediates released between encodes (see §MiniLMEmbeddingService design).
- **§Memory measurement gate is a HARD pre-merge gate.** No shipping the plan without an actual measurement on a 25-row batch on-device.
- `BGAppRefreshTask`'s 30s budget naturally caps total intermediate accumulation.
- Default-ON Lab kill switch lets affected users opt out without a hotfix if a field regression slips through.

### Risk 6: swift-embeddings library availability + transitive dep surface

The package is 0.0.27, pre-1.0, single-maintainer (jkrukowski). It pulls in four transitive deps, two from the same single maintainer (swift-safetensors, swift-sentencepiece). API drift between minor versions is possible.

**Mitigation:**
- `minVersion: 0.0.16, maxVersion: 1.0.0` range catches breaking 1.0.
- `MiniLMEmbeddingService` is the SOLE site that imports `Embeddings` — call-site swap is contained.
- The `modelVersion: String` discriminator means a library swap can re-embed with a new versioned identifier without touching the storage shape.
- **NEW:** the wider transitive supply-chain surface (4 packages, 2 single-maintainer) is documented here so it's not surprising. If any upstream package goes dark, pinning to a working commit hash via SwiftPM is the contingency.

### Risk 7 (NEW): Two coexisting category surfaces — `Transcript.category` (deprecated) and `TranscriptCategory` (new, empty) — create a mental-model footgun for the next engineer

A future engineer revisiting classification could plausibly grep for `category` in the schema, land on `Transcript.category`, and either (a) wire a new classifier to write there (re-introducing the exact decoupling problem this PR is trying to fix) or (b) read it on the assumption that V6 still populates it.

**Mitigation:**
- **Banner comment in `JotSchemaV6.Transcript.swift`** directly above the `category` declaration: "DEAD-DATA — DO NOT READ OR WRITE. From V6 onward, classification lives in TranscriptCategory. This field is retained only because dropping it requires a `.custom` migration that is out of scope for this PR." (Shown in full in §Schema V6 diff.)
- **Banner comment at the top of `CategoryStore.swift`** explaining that this is the canonical write target for all future classification work and that `Transcript.category` is dead-data.
- **`docs/schema-migrations.md` V6 entry** explicitly calls out the dead-data convention and the new substrate side-by-side.
- **`docs/deferred-engineering.md` "Embedding-based transcript classifier" entry** points at `TranscriptCategory` as the write target with a concrete `classifierVersion` example (see below).
- **`docs/features.md` §15 entry** mentions both new entities and the substrate-only state.

Convention enforcement is not bullet-proof but the combination of banner-comment-in-schema + banner-comment-in-store + documentation in three places is a strong nudge. A `.custom` migration to drop `Transcript.category` entirely is the durable fix and is left as a follow-up PR.

---

## Open questions

1. **Does `swift-embeddings` support watchOS?** **Answered:** yes, `Package.swift` declares watchOS 10+ as a supported platform (verified). We still don't link it from JotWatch because the watch produces audio and the phone embeds after transcription — no benefit to duplicating model state on the watch.

2. **Should `TranscriptEmbedding.transcriptID` use `@Attribute(.unique)`?** Conservative: ship WITHOUT in v1. Enforce uniqueness in `EmbeddingStore.upsert`. Lightweight migration on a `.unique` constraint of a new entity field is inconsistent across iOS versions. **Same answer for `TranscriptCategory`** — but for `TranscriptCategory` uniqueness on `transcriptID` would be *wrong* by design (multiple rows per transcript are valid, one per `classifierVersion`).

3. **`vectorData` storage size at scale.** 1.5 KB × 10k transcripts = 15 MB. At 100k it's 150 MB. **Decision: ship as-is.** Move to a separate `.bin` file keyed by transcriptID only if telemetry shows the embedding table dominates store size at scale. (`TranscriptCategory` row size is negligible — ~50 bytes — so no equivalent question applies.)

4. **Should the BG sweep be entirely removed in favor of inline-only?** Decision: keep. Backfills legacy corpus + insures against inline failures. With `BGAppRefreshTask` the schedule is "hours not days," which is acceptable.

5. **Should we re-embed on `displayText` change (Rewrite edits)?** v1: no — embed `text` at insert time, never re-touch. Garden-era question.

---

## Garden context (forward compatibility)

[Unchanged from prior draft — `TranscriptEmbedding` shape supports clustering on `vectorData`, joined by `transcriptID`, filtered by `modelVersion`. No scope creep into Garden's UI / algorithm choices.]

**Note on mid-swap clustering quality:** during a future model swap, the embedding table briefly contains rows under both old and new `modelVersion` strings. Garden's `@Query(filter: modelVersion == current)` filters mid-swap rows out cleanly. Clustering quality of the partial new-model corpus during the swap is a Garden-era concern, not a foundation concern; noted here so it's not surprising later.

**Note on category use by Garden:** if Garden ever wants to color-code clusters by classifier label, it reads `TranscriptCategory` filtered by the most recent `classifierVersion`, joined to `Transcript` by `transcriptID`. The same shape as the embedding read.

---

## `features.md` update

`features.md` doesn't carry classifier copy (it was invisible by design). No public copy to remove. The §15 Plans Index gets a new entry referencing this plan:

> **MiniLM Embeddings Foundation** — replaces the Qwen-based transcript classifier with a 22 MB on-device sentence encoder. Stores embeddings in a new `TranscriptEmbedding` table and a sibling `TranscriptCategory` table reserved for future classifier work; **current PR writes no category rows.** Pure substrate — no user-facing surface yet.

`docs/deferred-engineering.md` gets the "embedding-based classifier deferred" entry **rewritten to reference `TranscriptCategory` as the write target**:

> **Embedding-based transcript classifier.** A future classifier reads `TranscriptEmbedding.vector` and writes its label to `TranscriptCategory` with `classifierVersion = "minilm-centroids-v1"` (or whatever scheme it ends up using). The deprecated `Transcript.category` field is NOT touched. Re-introducing a Qwen-style local-model classifier (if we ever revisit) writes to the same `TranscriptCategory` table with `classifierVersion = "qwen-3.5b-5class-v1"`. User-manual tags (if ever added) use `classifierVersion = "user-manual"` with `confidence = nil`.

---

## Schema impact summary

- **Add/remove/rename `@Model` fields?** No changes to `Transcript`.
- **Add new `@Model` entities?** Yes, **two**:
  - `TranscriptEmbedding(transcriptID, vectorData, modelVersion, embeddedAt)`
  - `TranscriptCategory(transcriptID, category, confidence, classifierVersion, assignedAt)`
- **`models:` array in V6:** `[Transcript.self, TranscriptEmbedding.self, TranscriptCategory.self]`.
- **MigrationStage:** `.lightweight` V4 → V5 (committed in this PR; previously uncommitted) **and** `.lightweight` V5 → V6. The V5→V6 stage handles both new entities in a single additive migration.

---

## Verification

- **Build clean:** xcodebuild compiles `Jot` (iOS) + `JotKeyboard` + `JotWatch` + `JotWatchWidgets` cleanly. xcodegen picks up V6 + SwiftEmbeddings.
- **Sanity test (gated):** `MiniLMEmbeddingSanityTests` succeeds when run with `JOT_RUN_INTEGRATION_TESTS=1` after the §Threshold calibration step has recorded reference cosines.
- **Tokenizer-correctness validation (one-time, pre-merge):** L∞ < 0.01 element-wise comparison of 5-10 fixed strings between iOS 26 simulator and Python `sentence-transformers`.
- **Memory measurement gate (one-time, pre-merge):** peak resident < 150 MB during a 25-row BG batch AND cold-prewarm under 10s. See §Memory measurement gate for fall-through behavior.
- **Schema upgrade test on real device:** install App Store production (V4), dictate ≥10 transcripts, install the V6 build. Confirm:
  - Existing transcripts load cleanly (no `[SCHEMA-FALLBACK]` in Console.app).
  - V4→V5→V6 chained migration completes in one launch.
  - First `BGAppRefreshTask` fire backfills the corpus; Console.app shows `EmbeddingBackfillTask` logs and `EmbeddingStore.count(modelVersion: "minilm-l6-v2")` grows.
  - **NEW: `TranscriptCategory` table exists but is empty.** Verify via:
    - `CategoryStore.count(classifierVersion: "qwen-3.5b-5class-v1")` returns 0.
    - `CategoryStore.count(classifierVersion: "minilm-centroids-v1")` returns 0.
    - `CategoryStore.fetch(forTranscriptID: <some transcript ID>)` returns empty array.
  - **NEW: On a device upgraded from V4 with prior Qwen-classifier runs (i.e., `Transcript.category` is non-nil for some rows), confirm those legacy values are STILL present on the `Transcript` rows (not erased) AND that no `TranscriptCategory` rows are auto-created for them.** This is the "explicit dead-data, not migrated" contract from §Qwen removal.
- **Fresh-install V6 substrate test (NEW):** install V6 clean. Without dictating anything:
  - `EmbeddingStore.count(modelVersion: "minilm-l6-v2")` returns 0.
  - `CategoryStore.count(classifierVersion: <any value>)` returns 0.
  - Both tables exist (verified by manually inserting a row via a debug-only test affordance, then deleting it).
- **Fallback-active device test:** clear the fallback flag manually with the verified key — `UserDefaults.standard.removeObject(forKey: "jot.schema.fallbackActiveSince_v1")` (this is the actual key set at `TranscriptStore.swift:163`, and it lives in `UserDefaults.standard`, NOT `AppGroup.defaults`). Install build 43, write transcripts, install V6, verify embedding writes succeed (Risk 1). **Verify CategoryStore reads/writes also succeed on the fallback path** (Risk 1 step 6). Note: fallback-active devices do NOT log V4→V5 or V5→V6 migration messages — SwiftData re-infers the latest shape directly. Both writes-succeed and queryable-rows are the gates here (see Risk 1 / §N5).
- **Fresh-install test:** install V6 clean, dictate one transcript. Transcript saves immediately; within ~5-10 seconds an embedding row appears. No `TranscriptCategory` row is created.
- **Kill-switch test:** toggle `jot.embeddings.enabled` OFF in Settings → About; dictate a transcript; confirm NO embedding row is created and the inline hook returns early. Toggle ON; manually trigger `EmbeddingBackfillTask.submitIfBacklog`; confirm the backlog drains. (`TranscriptCategory` is unaffected by this toggle since it has no writers.)
- **Backup-restore test:** `TranscriptEmbedding` AND `TranscriptCategory` rows persist through iCloud Backup → restore cycle. (The latter will always be empty in this PR; the test still confirms the schema rides through the backup correctly so a future classifier doesn't discover a broken backup path post-ship.)
- **Old-BG-identifier console scan:** on first cold launch of V6, watch Console.app for any `classify-transcripts` or `BGTaskSchedulerErrorDomain` messages. Absence is the gate. The `BGTaskScheduler.shared.cancelAllTaskRequests()` call at JotApp.init makes this a belt-and-suspenders defense (§N4).
- **Qwen classifier removal smoke:** confirm no Console references to the classifier; Settings has the new Embeddings section (and no Lab classifier section); TranscriptDetailView has no category chip.
- **Qwen rewrite still works:** rewrite a transcript via Phi-4 and via Qwen; AI Settings download CTA still functions. (Sanity-check that the classifier rip-out didn't accidentally clip the rewrite path.)
- **No keyboard regression:** keyboard build size stays under 60 MB; keyboard extension never references `EmbeddingStore`, `CategoryStore`, or `Embeddings`.

---

## Open implementation sequencing

1. Commit the working-tree V5 schema file + V4→V5 stage. (`JotSchemaV5.swift` currently untracked.) Run `xcodegen`. Verify build green + V4→V5 upgrade smoke.
2. Schema V6 file (**with both `TranscriptEmbedding` AND `TranscriptCategory` nested model classes, plus the dead-data banner comment on `Transcript.category`**) + migration stage + typealias bumps + `TranscriptStore.swift` schema change. Verify V4→V5→V6 chained migration on real device.
3. Add SwiftEmbeddings package to project.yml + xcodegen. Verify build green.
4. `MiniLMEmbeddingService.swift` (actor) + `EmbeddingStore.swift` (under `Jot/Shared/DerivedData/`, `#if JOT_APP_HOST`) + **`CategoryStore.swift` (under `Jot/Shared/DerivedData/`, `#if JOT_APP_HOST`, no callers — substrate only)** + gated sanity test. Run §Threshold calibration + §Tokenizer-correctness validation. Verify test green.
5. Capture-time hook in `TranscriptStore.append` and `PhoneSideWCSession.saveTranscript`, **with the `jot.embeddings.enabled` kill-switch guard included inline** (see §Capture hook integration worked example). Verify by dictating and inspecting the embedding table — and by toggling the kill switch OFF and confirming no row appears. Confirm no code path touches `TranscriptCategory`.
6. `EmbeddingBackfillTask.swift` (BGAppRefreshTask, with prewarm-timeout guard, initial `batchSize = 25`) + register/submit wiring + Info.plist identifier rename + **add `BGTaskScheduler.shared.cancelAllTaskRequests()` as the first BG-related line in `JotApp.init`, BEFORE `EmbeddingBackfillTask.register()`.** Verify via Console.app + Xcode "simulate BG task" affordance.
7. **Run §Memory measurement gate (with cold-prewarm timing).** If the memory bound fails, bisect batch size before proceeding. If cold-prewarm exceeds 15s consistently, investigate model-load slowness before proceeding.
8. Qwen **classifier** rip-out (NOT rewrite). Delete files, update call sites, residual UserDefaults cleanup. Verify Qwen rewrite still works. **Confirm legacy `Transcript.category` values are preserved on upgraded devices and NOT migrated to `TranscriptCategory`.**
9. Settings → About Embeddings section with default-ON kill switch (toggle reads/writes `AppGroup.defaults.bool(forKey: "jot.embeddings.enabled")`) + count diag row.
10. `features.md` §15 + `docs/deferred-engineering.md` (with the rewritten "future classifier writes to `TranscriptCategory`" entry) + `docs/schema-migrations.md` V5 + V6 entries (V6 entry calls out both new entities and the dead-data convention on `Transcript.category`).

---

## Response to Round 3 follow-up

**What changed in Revision 4 (additive only — no Round-3 decision reversed):**

1. **Schema impact (§V6 diff / §Schema impact summary):** added a second `@Model` entity — `TranscriptCategory(transcriptID, category, confidence, classifierVersion, assignedAt)` — alongside `TranscriptEmbedding`. The `models:` array now lists all three classes. Migration stays `.lightweight` because both new entities are purely additive — SwiftData handles them in one inference pass.

2. **Storage architecture (§Storage architecture):** added a "Why a separate `TranscriptCategory` entity" subsection that mirrors the embedding rationale — decoupled migration cycles, classifier-version discriminator for A/B + iteration, user-manual-tag coexistence, clean sandbox for a future classifier, and structural decoupling from the dead `Transcript.category` field. Explicit: **no `@Attribute(.unique)` on `transcriptID`** because multiple rows per transcript are valid by design (different `classifierVersion` values).

3. **Code structure (§Code structure):** added a `CategoryStore.swift` sibling under a renamed `Jot/Shared/DerivedData/` directory (formerly `Jot/Shared/Embeddings/`). The rename reflects that the directory now houses two unrelated derived-data stores. `Jot/App/Embeddings/` (runtime service + BG task) keeps its name since those files genuinely are embedding-specific runtime. Added a `CategoryStore` design section with methods `fetch(forTranscriptID:classifierVersion:) -> [TranscriptCategory]`, `upsert(transcriptID:category:confidence:classifierVersion:)`, `count(classifierVersion:)`. `missingIDs` deliberately absent in v1 (no writer to backfill against). Banner comment on the file explaining the dead-data convention.

4. **Qwen removal (§Qwen removal):** added a "Dead-data convention for the existing `Transcript.category` field" subsection that locks in the user direction verbatim: existing `Transcript.category` values are NOT migrated to `TranscriptCategory`, NOT erased, and reading them is forbidden by convention from V6 onward. Enforcement is by banner comments + documentation in three places. The deprecated field continues to hold whatever Qwen wrote on devices that ran the classifier.

5. **Verification (§Verification):** added explicit checks:
   - V6 fresh install: `TranscriptCategory` table exists and is empty (count returns 0 for any `classifierVersion`).
   - V4 upgrade with prior Qwen runs: legacy `Transcript.category` values are still present on Transcript rows; no `TranscriptCategory` rows are auto-created.
   - Fallback-active devices: reads/writes against both new tables succeed.
   - Backup-restore: both new tables ride through cleanly (even though `TranscriptCategory` is empty).

6. **Deferred engineering rewrite (§features.md / §deferred-engineering.md):** rewrote the "embedding-based transcript classifier" entry to reference `TranscriptCategory` as the canonical write target with concrete `classifierVersion` examples ("minilm-centroids-v1" for the future embedding-based, "qwen-3.5b-5class-v1" for a re-introduced Qwen, "user-manual" for user tags). Updated `features.md` §15 entry to mention both new entities and the substrate-only state ("current PR writes no category rows").

7. **Risk surface (§Risk 7 NEW):** added Risk 7 — the mental-model footgun of two coexisting category surfaces (`Transcript.category` deprecated + populated on upgrades, `TranscriptCategory` new + empty). Mitigated by banner comments in `JotSchemaV6.Transcript.swift` AND `CategoryStore.swift`, plus documentation in `docs/schema-migrations.md` V6 entry, `docs/deferred-engineering.md`, and `docs/features.md` §15. A `.custom` migration to actually drop `Transcript.category` is the durable fix and is explicitly left as a follow-up PR.

8. **Revision header:** added the Revision 4 line at the top noting the additive substrate change and that no Round-3 decision was reversed.

9. **Implementation sequencing (§Open implementation sequencing):** updated step 2 to include both new entities in the V6 schema file + the dead-data banner comment, step 4 to add `CategoryStore.swift` alongside `EmbeddingStore.swift` under the renamed `DerivedData/` directory, step 5 to confirm no code path touches `TranscriptCategory`, step 8 to confirm legacy `Transcript.category` preservation, and step 10 to call out the new docs entries.

**What did NOT change (per the "What NOT to change" directive):**

- The embedding architecture (`MiniLMEmbeddingService`, swift-embeddings library choice, MLTensor materialization defense, actor isolation).
- The `BGAppRefreshTask` choice + cold-prewarm budget math + 15s prewarm timeout guard.
- The kill switch design (default-ON, stored in `AppGroup.defaults`, key `jot.embeddings.enabled`).
- The schema V5→V6 migration sequencing or the V4→V5 commit-in-this-PR direction.
- The defensive `BGTaskScheduler.shared.cancelAllTaskRequests()` call at JotApp.init.
- All Round-3 verification steps and pre-merge measurement gates.
- The "Size: M" envelope — the addition is ~30 lines (entity + store) and fits comfortably inside the ~1-day budget.

**Critical Files for Implementation:**

- /Users/vsriram/code/jot-mobile/Jot/Shared/Schema/JotSchemaV6.swift (NEW — must contain both `TranscriptEmbedding` and `TranscriptCategory` nested model classes plus the dead-data banner on `Transcript.category`)
- /Users/vsriram/code/jot-mobile/Jot/Shared/DerivedData/CategoryStore.swift (NEW — sibling to `EmbeddingStore.swift`, banner-commented, no callers in this PR)
- /Users/vsriram/code/jot-mobile/Jot/Shared/DerivedData/EmbeddingStore.swift (NEW — moved from the originally-planned `Jot/Shared/Embeddings/` to the renamed `DerivedData/` directory)
- /Users/vsriram/code/jot-mobile/Jot/Shared/TranscriptStore.swift (UPDATED — V6 schema reference and legacy fallback `Schema([Transcript.self, TranscriptEmbedding.self, TranscriptCategory.self])`)
- /Users/vsriram/code/jot-mobile/Jot/Shared/Schema/JotMigrationPlan.swift (UPDATED — append V4→V5 and V5→V6 lightweight stages; V5→V6 handles both new entities in one inference pass)
