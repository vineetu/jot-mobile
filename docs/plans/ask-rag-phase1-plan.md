# Ask RAG — Phase 1 implementation plan

Status: **PLAN — not yet implemented.** Serves
`docs/plans/ask-retrieval-architecture.md` (REVIEWED, decisions locked). This
plan does not re-open design decisions; it sequences the build and grounds every
choice in the current code. Read the design doc first — section references
below (§0–§6) point into it.

> Confidence: ~85%. Two items are genuine decisions, not pure execution, and are
> flagged inline: (1) whether the EmbeddingGemma Core ML port can sit behind the
> exact `encode(_:) -> [Float]` actor seam without spilling MLX/Core ML into
> `Shared/`, and (2) whether Qwen-as-reranker latency over 20–50 chunks is
> acceptable. Both are validation items the design doc already names (§5); this
> plan structures the build so they're proven before the dependent work lands.

---

## 1. Scope statement + non-goals

### In scope (Phase 1 — the quality unlock)

Per design §3 "Phase 1":

- **Length-adaptive chunking** of transcripts (~256 tokens, ~15% overlap,
  sentence-boundary-aware, single-chunk for short notes).
- **EmbeddingGemma-300M** via the **CoreML-LLM** Core ML/ANE port, behind the
  existing `encode(_:) -> [Float]` actor seam. Store **256-d** (Matryoshka
  truncation). Asymmetric `query:` / `document:` prefixes.
- **`TranscriptChunk` @Model** replacing `TranscriptEmbedding` (schema work in §2).
- **In-memory BM25** inverted index in Swift over the chunk corpus (NOT FTS5 —
  SwiftData hides SQLite, design §0/§2.B).
- **Brute-force cosine** dense retrieval (Accelerate/vDSP), no ANN index.
- **RRF (k=60)** fusion of dense + lexical ranked lists.
- **Deterministic `RetrievalFilter`** (date — already shipped as
  `AskController.parseDateScope`; + tags via the existing centroid classifier;
  + type via `source`; + `minDurationSeconds`). Applied as a pre-filter on the
  candidate pool.
- **Intent routing** (`LOOKUP` / `SUMMARIZE` / `BROWSE`), safe-default = LOOKUP
  (retrieve) when ambiguous (design §2.B.1).
- **Map-reduce** for `SUMMARIZE`.
- **Qwen-as-reranker** (listwise, no new model; design §2.B.3).
- **Citation chunk→parent-transcript migration** in `AskCitationParser` /
  `AskController` ordering (design §2.B.6).
- **Apple FM removal from Ask** — drop `AppGroup.askBackend`, the Settings "Ask
  uses" picker, the `appleFM` branch in `pickBackend`, and the variable
  backend footer label (design §0).
- **User-triggered "Rebuild index" button** + `BGProcessingTask` +
  `requiresExternalPower` for the from-scratch re-index, with resumability +
  progress (design §4).
- **Eval harness** (built alongside; design §3 last bullet, §5).
- Tag classifier centroids re-embed on the new model (design §4 last bullet).

### Non-goals (explicitly Phase 2 — do NOT build)

Per design §3 "Phase 2" and §6:

- Dedicated Core ML cross-encoder reranker (BGE / Jina-reranker-v2).
- HyDE / multi-query / query rewrite.
- Sentence-window context expansion (pull neighbor chunks).
- Timestamp deep-links from a citation to the moment (we **store** `charStart`/
  `charEnd` in Phase 1 so the data is ready, but build no deep-link UI).
- int8 vector quantization + ANN/HNSW index (only past ~100k chunks; design §2.A).
- The mind-map / concept graph (design §6 — not designed).
- Re-introducing Apple Intelligence as a selectable Ask backend (design §0 says
  keep the seam, don't ship it now).

---

## 2. Schema impact (per `Jot/CLAUDE.md` "Schema discipline")

**Does this feature add/remove/rename `@Model` fields or entities?** YES — adds
the `TranscriptChunk` entity and removes `TranscriptEmbedding`.

### Shipped-state finding (the decisive input)

I checked `git ls-files` and `git log` for the schema files:

- **Last COMMITTED / shipped schema is `JotSchemaV4`.** Confirmed:
  `git ls-files Jot/Shared/Schema/` lists only V1–V4 + `JotMigrationPlan.swift`;
  `HEAD:Jot/Shared/Transcript.swift` has `typealias Transcript =
  JotSchemaV4.Transcript`; `HEAD:Jot/Shared/TranscriptStore.swift` builds
  `Schema(versionedSchema: JotSchemaV4.self)`.
- **`JotSchemaV5.swift` and `JotSchemaV6.swift` are untracked (`??` in
  `git status`) — never committed, never shipped.** V5 adds `source` +
  `watchOriginUUID` (watch dictation); V6 adds the `TranscriptEmbedding` +
  `TranscriptCategory` entities (MiniLM beta). Both live only on this branch.
- The working tree already points the typealias and container at V6
  (`Transcript.swift:14`, `TranscriptStore.swift:89`), and `JotMigrationPlan`
  already appends V5 + V6 stages (lines 80–95). But none of this is in a build
  any user has.

**Consequence (matches design §4 "embeddings are beta, shipped to nobody"):**
We are NOT frozen on V5/V6 — the `check-schema-frozen.sh` "frozen once shipped"
rule binds only committed-and-shipped files. We have two clean options:

> **DECISION (locked with user): Option A — mint `JotSchemaV7`.** The lead
> overrode the original Option-B recommendation: although V6 is uncommitted in
> git, the developer has run local builds pointing at V6 all along, so their
> device almost certainly holds a **live V6 store with real transcripts**.
> Editing V6 in place would risk the `[SCHEMA-FALLBACK]` rebuild on that store —
> embeddings lost for sure, transcripts at risk. Embeddings are disposable;
> transcripts are not. V7 preserves them deterministically for one extra file.

**Option A — new version `JotSchemaV7` (CHOSEN).** Treat V5/V6 as frozen-on-device.
Add `JotSchemaV7.swift` that **drops `TranscriptEmbedding` and adds `TranscriptChunk`**
(keep `TranscriptCategory` and `Transcript` unchanged), bump
`versionIdentifier` to `Schema.Version(7, 0, 0)`, and append a **`.custom`**
V6→V7 `MigrationStage` (entity delete is a transform, not additive — `willMigrate`
nukes the `TranscriptEmbedding` rows, `didMigrate` is a no-op since chunks are
rebuilt by the re-index, not migrated). Bump the `typealias` + container to V7,
run `xcodegen` from `Jot/`, and watch Console for `[SCHEMA-FALLBACK]` on a
real-device upgrade test (per `CLAUDE.md` schema discipline step 8).

> ~~Option B (edit unshipped V6 in place)~~ — rejected: data-safety risk on the
> developer's existing on-device V6 store.

### The `TranscriptChunk` shape (new entity in `JotSchemaV7`)

```swift
@Model
final class TranscriptChunk {
    var id: UUID                 // chunk identity (stable across re-index? no —
                                 //   re-index regenerates; see rebuild §4)
    var transcriptID: UUID       // logical join to Transcript.id (NOT @Relationship,
                                 //   same rationale as TranscriptEmbedding today)
    var chunkIndex: Int          // 0-based position within the parent transcript
    var text: String             // the chunk's own text (BM25 + snippet packing)
    var vectorData: Data         // 256 float32 little-endian (was 384 for MiniLM)
    var charStart: Int           // offset into Transcript.text — future deep-link
    var charEnd: Int
    var modelVersion: String     // "embeddinggemma-300m-256" discriminator
    var embeddedAt: Date

    // Denormalized filter metadata, copied at index time so the candidate-pool
    // pre-filter (RetrievalFilter §C) can scope WITHOUT a Transcript join per
    // chunk. Mirrors design §2.A "Each chunk carries metadata".
    var createdAt: Date          // copy of parent Transcript.createdAt
    var durationSeconds: Double? // copy of parent
    var source: String?          // copy of parent (watch/app/keyboard/shortcut/file)

    init(id: UUID = UUID(), transcriptID: UUID, chunkIndex: Int, text: String,
         vectorData: Data, charStart: Int, charEnd: Int,
         modelVersion: String, embeddedAt: Date = Date(),
         createdAt: Date, durationSeconds: Double? = nil, source: String? = nil) { ... }
}
```

Notes:
- The summary-embedding row design §2.A asks for ("coarse recall / dedup") is
  representable as a chunk with `chunkIndex == -1` (a sentinel) covering the
  whole transcript, OR a separate `isSummary: Bool` flag. **Recommend the
  `chunkIndex == -1` sentinel** — no extra field, and the dense scan can include
  or exclude it with a predicate. Decide at implementation; either is V6-local.
- `TranscriptCategory` is **kept unchanged** in V6 — the classifier still writes
  it; only its *vectors* change model (centroids re-embed, design §4). Its
  `classifierVersion` discriminator already isolates old MiniLM rows from new
  EmbeddingGemma rows (`MiniLMCentroidClassifier.swift:46`).
- The legacy `Transcript.category` dead-data field (`JotSchemaV6.swift:79`)
  stays as-is — untouched.

### Migration stage

`JotMigrationPlan.swift` already has V5→V6 as `.lightweight`
(`JotMigrationPlan.swift:91`). Under Option B that line is **unchanged** — V6
still introduces "new entity types alongside `Transcript`", which is exactly the
`.lightweight` case CLAUDE.md item 6 / `JotMigrationPlan` recipe step 4
describes. `versionIdentifier` stays `Schema.Version(6, 0, 0)`. No bump.

### Typealias + container + xcodegen

- `Jot/Shared/Transcript.swift:19` — replace the `TranscriptEmbedding` typealias
  with `typealias TranscriptChunk = JotSchemaV6.TranscriptChunk`, and replace the
  `extension TranscriptEmbedding { var vector }` (lines 28–41) with the
  equivalent on `TranscriptChunk` (unpack `vectorData` → `[Float]`, length 256).
- `Jot/Shared/TranscriptStore.swift:89` — container schema stays `JotSchemaV6`
  (entity set changes inside V6, container call site unchanged).
- **Run `xcodegen` from `Jot/`** after the schema edit (CLAUDE.md item 4 /
  recipe step 7) so the Shared/ glob recompiles into both targets. The
  `JotSchemaV6.swift` file is already in the glob, so this is a no-op for file
  membership — but run it anyway per discipline.
- Update `docs/schema-migrations.md` "Current versions" V6 entry to describe
  `TranscriptChunk` instead of `TranscriptEmbedding`.

### Frozen-rule check

`scripts/check-schema-frozen.sh` blocks edits to *shipped* VN files. V6 is not
shipped, so editing it is legal — **but verify the script keys off git-tracked +
shipped state, not mere presence on disk.** If the script naively flags any edit
to a `JotSchemaVN.swift` once committed, Option B's V6 edit must land in the
*same commit* that first introduces V6 (it's all uncommitted today, so this is
natural). Validation item — confirm before committing.

---

## 3. Sequenced, file-by-file task breakdown

Build order is grouped into stages. Within a stage, tasks marked **[‖]** are
parallelizable; **[→]** depend on an earlier task. Each task lists files touched.

### Stage 0 — Apple-FM teardown + schema (unblocks everything, low risk)

**T0.1 — Remove Apple FM from Ask. [‖]**
Design §0 "Phase-1 code cleanup".
- `Jot/App/Ask/AskController.swift`: delete the `appleFM` enum case + branch in
  `pickBackend` (lines 273–307), the `AppGroup.askBackend == "qwen"` strict path
  (292), the `appleIntelligence` `AnswerBackend` case (60–69) and the
  `LanguageModelSession`/`SystemLanguageModel` usage (239, 281–306, 587–594).
  `pickBackend` collapses to "Qwen on disk? → `.qwen` : `.none(.qwenNotDownloaded)`".
  Drop `UnavailableReason.appleIntelligenceOff/.deviceNotEligible/.modelDownloading`
  if now unreferenced.
- `Jot/App/Settings/SettingsView.swift`: delete `askBackend` @State (line 31),
  `askBackendRow` (444, 453–482), and the `onChange` writer (480–481).
- `Jot/Shared/AppGroup.swift`: delete `Keys.askBackend` (138) +
  `askBackend` accessor (244–246). (Per MEMORY "check legacy guards when
  reviving" — this is the inverse: confirm nothing else reads the key.)
- `Jot/App/Ask/AskView.swift`: make the footer backend label constant — drop the
  `· \(backend.displayName)` concatenation (349–350) or hard-label "On-board Qwen".
- Keep the Ask-pill download gate (`currentProviderWeightsOnDisk`) as the single
  availability rule — already in `pickBackend` (288).

**T0.2 — Schema: `TranscriptChunk` replaces `TranscriptEmbedding`. [‖]**
Per §2 (Option B). Files: `JotSchemaV6.swift`, `Transcript.swift`,
`docs/schema-migrations.md`, then `xcodegen`. Do NOT touch `JotMigrationPlan`
(stage stays lightweight). This task is the schema half of §2.

**T0.3 — Rewrite `EmbeddingStore` → `ChunkStore`. [→ T0.2]**
`Jot/Shared/DerivedData/EmbeddingStore.swift`. The current API
(`fetch(forTranscriptID:)`, `upsert(transcriptID:vector:modelVersion:)`,
`missingIDs`, `count`, `allEmbeddedTranscriptIDs`) is per-transcript; the new
store is per-chunk. New surface sketch in §4. Keep `@MainActor enum`,
fresh-`ModelContext`-per-call shape. `missingIDs` becomes
"transcripts with zero chunk rows at current modelVersion".

### Stage 1 — Embedder swap (the risky validation gate, do early)

**T1.1 — Add EmbeddingGemma Core ML embedder behind the `encode` seam. [→ T0.x not required, ‖ with stage 0]**
Design §2.A, §5. Files: new `Jot/App/Embeddings/EmbeddingGemmaService.swift`
(or rename `MiniLMEmbeddingService.swift` — see decision below); `project.yml`
(add CoreML-LLM as a dependency — confirm SwiftPM availability of the port);
delete `MiniLMEmbeddingService.swift` content after callers migrate.
- **Preserve the seam:** the actor exposes `func encode(_ text: String) async
  throws -> [Float]` returning a **256-d** vector, plus `prewarm()` and a static
  `modelVersion`. Callers (`AskController.retrieveTopK:313`,
  `TranscriptIndexer:111/152`, `MiniLMCentroidClassifier:89`, `EmbeddingsPanel
  commitAdd:516`) must not change their call shape — only the dim (384→256) and
  the `modelVersion` string change.
- **Add asymmetric prefixes:** the encode call must distinguish `query:` vs
  `document:`. The current single `encode(_:)` has no role param. **Add a role:**
  `func encode(_ text: String, role: EmbeddingRole) async throws -> [Float]`
  with `enum EmbeddingRole { case query, document }`, default `.document` to keep
  the seam minimal for the classifier (seeds are documents). `AskController`'s
  query embed passes `.query`. This is the one *intentional* seam widening.
- **`Shared/` containment risk:** `MiniLMEmbeddingService` is `#if JOT_APP_HOST`
  and lives under `App/` (not `Shared/`), so it never compiles into the keyboard
  (which has the ~60 MB / no-MLX ceiling, CLAUDE.md "Keyboard extension
  constraints"). Keep the new embedder under `App/Embeddings/` and **never**
  import it from `Shared/`. The classifier (`App/Classification/`) already calls
  it cross-folder within the app target — fine.
- **VALIDATION GATE (design §5):** before the rest of Phase 1 depends on this,
  prove on iPhone 16/17: (a) the CoreML-LLM `EmbeddingGemma.swift` port loads,
  (b) cold-load + per-chunk latency are acceptable, (c) the **license** permits
  shipping. If the port can't sit behind the actor seam cleanly, this is where
  we discover it — everything downstream consumes `[Float]`, so a fallback (MLX
  4/5-bit build, design §2.A) is an impl swap, not a redesign.

### Stage 2 — Ingestion: chunking + indexing

**T2.1 — Length-adaptive chunker. [‖, pure function]**
Design §2.A. New `Jot/App/Embeddings/TranscriptChunker.swift`. Pure,
synchronous, testable in isolation (no model, no SwiftData) — see §4 signature.
Sentence-boundary split with token-window fallback. Unit-tested in Stage 6.

**T2.2 — Rewrite `TranscriptIndexer` for chunks. [→ T1.1, T2.1, T0.3]**
`Jot/App/Embeddings/TranscriptIndexer.swift`. The current pipeline
(`runIndexPipeline:150`) does one `encode(text)` → one `EmbeddingStore.upsert`.
New: chunk the text, encode each chunk (`.document`), upsert N `TranscriptChunk`
rows (replacing any prior rows for that transcript at the current modelVersion),
plus the transcript-summary chunk. Preserve the `Task.detached(.utility)`
off-Main discipline (banner lines 14–28) and the
`indexAwait`/`index`/`tagAllTranscripts` entry points. The classify step
(`classifyMulti`) now runs on the **summary/whole-transcript vector** (or mean of
chunk vectors) so tags stay transcript-level — confirm with classifier owner.

**T2.3 — Centroid classifier on the new model. [→ T1.1]**
`Jot/App/Classification/MiniLMCentroidClassifier.swift`. Change the hardcoded
`guard vector.count == 384` (line 130) to 256, bump `classifierVersion`
(line 46) to e.g. `"gemma-centroids-v1"` so old MiniLM `TranscriptCategory` rows
stay distinguishable, and re-embed seeds (`ensureSeedsEmbedded:81` already
re-encodes any seed whose `vectorData` is nil — but seeds cached under MiniLM
have stale 384-d blobs). **Add a one-time seed-vector reset** keyed on model
version so stale 384-d seed vectors are dropped and re-embedded. Rename the type
or keep the name? Recommend keeping `MiniLMCentroidClassifier` filename for diff
clarity is misleading — **rename to `CentroidClassifier`** since it's no longer
MiniLM (low-risk, find/replace + xcodegen). `CategorySeedStore.swift` is
model-agnostic (stores opaque `vectorData`) — no change beyond the reset.

### Stage 3 — Retrieval pipeline (the core)

**T3.1 — In-memory BM25 index. [‖, pure-ish]**
Design §2.B. New `Jot/App/Ask/BM25Index.swift`. Build an inverted index over all
`TranscriptChunk.text` at the current modelVersion, rebuilt on launch /
maintained incrementally. Zero new dependencies (design tenet). See §4 sketch.
Independent of the embedder.

**T3.2 — `RetrievalFilter` + deterministic extraction. [→ T0.1 (date parser stays)]**
Design §2.C. New `Jot/App/Ask/RetrievalFilter.swift` (struct per design §2.C),
plus the extractor. The **date** layer already exists as
`AskController.parseDateScope` (575+ lines of tested regex,
`AskController.swift:378–479`) — **lift it out** of `AskController` into the
filter extractor (or have the extractor call it) so all three intents share it.
- **tags:** map query terms to `CategoryID` via the existing classifier
  categories (`CategoryID.allCases`); a query like "my work-tagged notes" sets
  `filter.tags`. Applied by intersecting against `TranscriptCategory` rows.
- **source / minDuration:** keyword heuristics ("on my watch" → `source ==
  "watch"`; "long recordings" → `minDurationSeconds`). Deterministic, no model.
- Applied as a predicate on the chunk candidate pool (the denormalized
  `createdAt`/`source`/`durationSeconds` on `TranscriptChunk` make this a single
  fetch, no per-chunk Transcript join — see §2 schema note).

**T3.3 — Intent router. [‖ with T3.1/T3.2]**
Design §2.B.1. New `Jot/App/Ask/IntentRouter.swift`. Cheap + mostly
deterministic: `enum AskIntent { case lookup, summarize, browse }`. Heuristics —
"lately / themes / what have I been / last N days" + a date scope but no strong
topic → `summarize`; pure metadata ("my work notes", "long recordings") →
`browse`; everything else → `lookup`. **Safe default = `lookup`** when ambiguous
(design §2.B.1 — wrong LOOKUP degrades gracefully). Optional Qwen disambiguation
is allowed but keep a deterministic path that works without it.

**T3.4 — Dense retrieval (brute-force cosine via vDSP). [→ T1.1, T0.3]**
Replaces `AskController.retrieveTopK` (311–350). New
`Jot/App/Ask/DenseRetriever.swift` (or keep in controller). Fetch all chunk
vectors at current modelVersion (filtered by the RetrievalFilter predicate),
score cosine, top-K (prefetch ~50 per design §2.B.2). Use Accelerate/`vDSP` for
the dot products (design §2.A "<50 ms") — the current hand-rolled loops
(`AskController.dot:578`) are fine at 10k but vDSP is the documented path.

**T3.5 — RRF fusion. [→ T3.1, T3.4]**
Design §2.B.2. New `Jot/App/Ask/RRFFusion.swift` (or a function). Fuse dense +
BM25 ranked lists with `k = 60`. Pure function over two `[ScoredChunk]` → one.

**T3.6 — Qwen-as-reranker. [→ T3.5, depends on Qwen `ask` seam]**
Design §2.B.3. New `Jot/App/Ask/QwenReranker.swift`. Listwise re-rank the fused
top ~20–50 chunks → top 6–10, via `LLMClientFactory.shared.client().ask(...)`
(the seam at `LLMClient.swift:61`, implemented by `Qwen35Client.ask:471`). A
constrained prompt that returns a reordered index list. **VALIDATION GATE
(design §5):** measure listwise quality + latency over 20–50 chunks on-device
before committing to it as the Phase-1 reranker; if latency is unacceptable,
fall back to RRF-only ordering for Phase 1 and defer the reranker (it's the one
Phase-1 item with a clean degrade path). The `ask` call currently caps
`maxTokens: 800` (`Qwen35Client.swift:503`) — a rerank that only emits an index
list needs far fewer; add a separate low-token rerank entry or reuse `ask` with
a tight prompt.

**T3.7 — Pipeline orchestrator. [→ T3.2–T3.6]**
Refactor `AskController.runPipeline` (166–269) to: extract filter → route intent
→ (lookup: hybrid retrieve → RRF → rerank → pack) / (summarize: filter →
map-reduce) / (browse: filter → list). Keep the `Phase` state machine
(retrieving/streaming/done/vague/error) and the existing `vague` gate semantics.
Token-budget packing (design §2.B.4): replace the char-count cap
(`userTurnCharLimit = 12000`, line 97, sized for Apple FM 4k) with a
**token-budget pack (~4–8k to start)** over the reranked chunks; the
context-budget sweep is an eval-harness deliverable (§5).

**T3.8 — Map-reduce summarize. [→ T3.2, Qwen seam]**
Design §2.B.5. New `Jot/App/Ask/MapReduceSummarizer.swift`. For `summarize`
intent: filter transcripts in the window → summarize each
(transcript/cluster) → synthesize across them. Uses the same `ask` seam.

### Stage 4 — Citations (small but easy to miss — design §2.B.6)

**T4.1 — Chunk→parent-transcript citation mapping. [→ T3.7]**
`Jot/App/Ask/AskController.swift` + `AskCitationParser.swift`. The parser already
maps `[cite: N]` → Nth entry of `orderedIDs` → transcript
(`AskCitationParser.swift:132–138`). **The change is what `orderedIDs` contains:**
today it's transcript IDs (`AskController.swift:79, 208`). Under chunking, the
packed context is a list of **chunks**, so `[cite: N]` → Nth **packed chunk** →
its **parent `transcriptID`**. Build `orderedIDs` from the packed chunks' parent
transcript IDs (dedup-aware: if two packed chunks share a parent, decide whether
they're one citation slot or two — recommend **one slot per packed chunk** so the
model's N matches the numbered list it sees, then resolve to parent at chip-build
time). `transcriptsByID` still resolves the chip label/date. Carry `charStart`/
`charEnd` through for the future deep-link but build no deep-link UI (Phase 2).
This keeps `AskCitationParser` itself almost unchanged — the migration is in how
`AskController` assembles `orderedIDs` from chunks.

### Stage 5 — Rebuild index button + background re-index (design §4)

**T5.1 — "Rebuild search index" button. [→ T2.2]**
`Jot/App/Settings/EmbeddingsPanelView.swift`. Add a card mirroring the existing
"Tag all transcripts now" card (lines 162–225) — a button that kicks a
foreground/charging re-index with the same progress-spinner pattern
(`isTaggingAll`/`tagAllDone`/`tagAllTotal` → new `isRebuilding`/counts). On tap:
clear all `TranscriptChunk` rows at the current modelVersion, then chunk +
re-embed every transcript. Reuse `TranscriptIndexer.tagAllTranscripts`'s
row-walking shape (67–146) but for chunking. Also re-embed classifier centroids
(T2.3 reset).

**T5.2 — `BGProcessingTask` + `requiresExternalPower` re-index task. [→ T2.2]**
Design §4 "Scheduling correction". The existing `EmbeddingBackfillTask` is a
`BGAppRefreshTask` (30 s budget, MiniLM-sized — see its banner lines 8–31). The
new from-scratch re-index (EmbeddingGemma × ~10 chunks/transcript × thousands) is
far heavier → needs **`BGProcessingTask` with `requiresExternalPower = true`**
(the pattern the old Qwen classifier used) **plus resumability + progress**. New
`Jot/App/Embeddings/IndexRebuildTask.swift` modeled on `EmbeddingBackfillTask`'s
register/submit/drain skeleton (56–198) but: `BGProcessingTaskRequest` with
`requiresExternalPower = true`, `requiresNetworkConnectivity` per model fetch
need, resumable via the same `missingIDs`-style "transcripts with no current-
version chunks" query (so a killed task resumes next fire), progress persisted so
the panel reflects it. The button (T5.1) gives the immediate
foreground/charging path; this drains the backlog.
- **Add the BG task identifier to `Info.plist`** `BGTaskSchedulerPermitted­Identifiers` (the existing backfill ID is already registered there — add the
  new processing-task ID alongside).
- **Keep or retire `EmbeddingBackfillTask`?** With chunking, inline indexing at
  capture (T2.2) + the rebuild task cover the cases the old `BGAppRefreshTask`
  backfill handled. **Recommend retiring `EmbeddingBackfillTask`** to avoid two
  schedulers fighting over the same backlog query — fold its "drain new
  un-indexed captures" role into the inline path + a light backfill inside the
  processing task. Decide with the owner; either way only ONE task owns the
  "missing chunks" query.

### Stage 6 — Eval harness (build alongside, design §3/§5)

**T6.1 — Eval harness.** See §5 for shape. New files under `Jot/Tests/` (and a
small dev-only runner). Built incrementally as the pipeline lands so each stage
can be measured.

### Build-order summary (dependency graph)

```
Stage 0 (T0.1 FM-teardown ‖ T0.2 schema → T0.3 ChunkStore)
   │
Stage 1 (T1.1 EmbeddingGemma seam)  ← VALIDATION GATE (license+latency)
   │
Stage 2 (T2.1 chunker ‖) → (T2.2 indexer, T2.3 classifier)
   │
Stage 3 (T3.1 BM25 ‖ T3.2 filter ‖ T3.3 router) → T3.4 dense → T3.5 RRF
        → T3.6 reranker (GATE: latency) → T3.7 orchestrator → T3.8 map-reduce
   │
Stage 4 (T4.1 citations)
   │
Stage 5 (T5.1 button ‖ T5.2 BGProcessingTask)
   │
Stage 6 (T6.1 eval harness — runs continuously from Stage 1 onward)
```

Parallelization for a subagent team: **{T0.1}**, **{T0.2→T0.3}**, and **{T1.1}**
can run as three independent tracks. Stage 3's T3.1/T3.2/T3.3 are three more
independent tracks once T1.1's seam shape is fixed. Per the user's
"two-agents-per-feature" rule, pair each with a reviewer.

---

## 4. Key interfaces / signatures (sketches — NOT implementations)

### Chunker (T2.1)

```swift
struct TranscriptChunkSpec: Equatable {
    let text: String
    let charStart: Int
    let charEnd: Int
    let index: Int
}

enum TranscriptChunker {
    /// Length-adaptive. Short text → one chunk. Long text → sentence-boundary
    /// windows of ~targetTokens with ~overlapFraction overlap; token-window
    /// fallback when no sentence boundaries are found. Pure + synchronous.
    static func chunk(_ text: String,
                      targetTokens: Int = 256,
                      overlapFraction: Double = 0.15) -> [TranscriptChunkSpec]
}
```

### Embedder seam (T1.1) — preserve `encode -> [Float]`, widen with role only

```swift
enum EmbeddingRole { case query, document }   // asymmetric prefixes

actor EmbeddingGemmaService {            // was MiniLMEmbeddingService
    static let shared = EmbeddingGemmaService()
    static let modelVersion = "embeddinggemma-300m-256"
    static let dimension = 256

    func prewarm() async throws
    func encode(_ text: String, role: EmbeddingRole = .document) async throws -> [Float]
}
```

### ChunkStore (T0.3)

```swift
@MainActor enum ChunkStore {
    static func chunks(forTranscriptID id: UUID, modelVersion: String) -> [TranscriptChunk]
    static func replaceChunks(forTranscriptID: UUID, with: [TranscriptChunk], modelVersion: String) throws
    static func allChunks(modelVersion: String) -> [TranscriptChunk]   // dense scan + BM25 build
    static func transcriptIDsMissingChunks(limit: Int, modelVersion: String) -> [UUID]
    static func count(modelVersion: String) -> Int
}
```

### BM25 index (T3.1)

```swift
struct BM25Hit { let chunkID: UUID; let score: Float }

final class BM25Index {            // in-memory inverted index, zero new deps
    init(chunks: [(id: UUID, text: String)], k1: Float = 1.2, b: Float = 0.75)
    func search(_ query: String, limit: Int = 50) -> [BM25Hit]
    func add(id: UUID, text: String)        // incremental maintenance
    func remove(id: UUID)
}
```

### RetrievalFilter (T3.2) — verbatim from design §2.C + applied-as-predicate

```swift
struct RetrievalFilter {
    var dateInterval: DateInterval?    // from the lifted parseDateScope
    var tags: [String]                 // mapped to CategoryID
    var source: String?                // watch / app / keyboard / shortcut / file
    var minDurationSeconds: Double?
}

enum RetrievalFilterExtractor {
    static func extract(from question: String, now: Date) -> RetrievalFilter
}
```

### Intent router (T3.3)

```swift
enum AskIntent { case lookup, summarize, browse }
enum IntentRouter {
    /// Deterministic-first; safe default = .lookup when ambiguous.
    static func route(question: String, filter: RetrievalFilter) -> AskIntent
}
```

### Retrieval pipeline orchestrator (T3.7) — inside AskController

```swift
struct ScoredChunk { let chunk: TranscriptChunk; let score: Float }

// dense (T3.4)
func denseRetrieve(query: [Float], filter: RetrievalFilter, prefetch: Int = 50) -> [ScoredChunk]
// RRF (T3.5)
func rrfFuse(_ dense: [ScoredChunk], _ lexical: [BM25Hit], k: Int = 60) -> [ScoredChunk]
// rerank (T3.6)
func qwenRerank(_ candidates: [ScoredChunk], question: String, keep: Int) async throws -> [ScoredChunk]
// pack to token budget (T3.7)
func packToTokenBudget(_ chunks: [ScoredChunk], budgetTokens: Int) -> [TranscriptChunk]
```

### Rebuild task (T5.2)

```swift
@available(iOS 26.0, *)
@MainActor enum IndexRebuildTask {
    static let identifier = "com.vineetu.jot.mobile.Jot.rebuild-index"
    static func register()
    static func submit()                 // BGProcessingTaskRequest, requiresExternalPower = true
    // drain loop: resumable via ChunkStore.transcriptIDsMissingChunks; persists progress
}
```

---

## 5. Eval harness shape (design §3 last bullet, §5)

**Where it lives.** A dev-only target/test. Two viable homes:
- **`Jot/Tests/`** (existing `JotTests` target; depends on `Jot`,
  `project.yml:389–394`). Good for the *deterministic* pieces — chunker,
  BM25, RRF, RetrievalFilter extraction, intent routing — pure functions, no
  model, run in CI-style XCTest.
- The **on-device retrieval-quality + budget sweep** needs the real model on
  real hardware, so it can't be a plain unit test. **Recommend a hidden
  dev-only "Eval" screen** behind a debug flag in the Embeddings/Diagnostics
  panel (a `Jot/App/Diagnostics/` folder already exists per `git status`) that
  loads the local pairs file, runs the full pipeline, and reports metrics. Keep
  it `#if DEBUG` so it never ships.

**How pairs are stored (local / out of repo — design §3/§5).** 30–50
`(question → expected transcripts/answer)` pairs from the **developer's own
corpus**. It's personal data → **must not be committed.** Store as a JSON file
the dev drops into the App Group container or app Documents (e.g.
`eval-pairs.json`), `.gitignore`d, loaded only by the `#if DEBUG` eval screen.
Schema sketch:

```json
[{ "question": "what did I decide about the contractor estimate",
   "expectedTranscriptIDs": ["…"],          // ground-truth relevant transcripts
   "expectedAnswerNotes": "should mention $X quote, defer to spring",
   "intent": "lookup" }]
```

**Metrics (design §5).**
- **Recall@k** and **MRR** over `expectedTranscriptIDs` vs the
  reranked/packed chunk→parent set (target baselines from design §2.B:
  Recall@5 ≈ 0.82, MRR@3 ≈ 0.61).
- **Answer quality** — manual / lightweight rubric against `expectedAnswerNotes`.
- **Context-budget sweep** (design §2.B.4): for 4k / 8k / 16k token budgets on
  the target device, record **peak memory**, **prefill latency**, and **eval
  quality**; pick the largest budget that's memory-safe, fast, and before
  quality plateaus. This sweep feeds the `budgetTokens` constant in T3.7.
- **Per-stage instrumentation** so the harness can attribute a quality change to
  chunking vs. embedder vs. RRF vs. rerank (design §3: "Without it we're
  guessing whether a change helped").

---

## 6. Open risks + validation items (carried from design §5, + plan-level)

| # | Item | Source | Gate / action |
|---|------|--------|---------------|
| R1 | **EmbeddingGemma license** for shipping | design §5 | Confirm license terms BEFORE T1.1 lands in a shippable build. Hard blocker if non-permissive. |
| R2 | **EmbeddingGemma Core ML port behind the `encode` seam** — does CoreML-LLM's `EmbeddingGemma.swift` load on iPhone 16/17, and is cold-load + per-chunk latency acceptable? | design §2.A/§5 | T1.1 VALIDATION GATE. Fallback: MLX 4/5-bit build (still behind the seam). Everything downstream consumes `[Float]`, so a swap is contained. |
| R3 | **Qwen-as-reranker quality + latency** over 20–50 chunks | design §5 | T3.6 VALIDATION GATE. Clean degrade: RRF-only ordering for Phase 1, defer the reranker. |
| R4 | **mlx-swift-lm quantized KV-cache** support (the context-budget lever) | design §2.B.4/§5 | Verify the Swift port exposes it (Python does; Swift may lag). Affects the budget sweep ceiling, not correctness. Check `Vendor/mlx-swift-structured` + `Qwen35Client`. |
| R5 | **Re-index time + UX** — chunk+embed of thousands of transcripts × ~10 chunks on EmbeddingGemma | design §4 | T5.2 needs resumability + progress + `requiresExternalPower`. Measure full-corpus rebuild wall-clock on-device before shipping the button as the primary path. Per MEMORY: wait for on-device test, don't ship on green build alone. |
| R6 | **Schema Option A vs B decision** + `check-schema-frozen.sh` keying | this plan §2 | User picks A or B; confirm no V6 TestFlight build escaped (B's only risk) and confirm the frozen-check script keys off shipped state. |
| R7 | **Two BG schedulers fighting the backlog** if `EmbeddingBackfillTask` is kept alongside `IndexRebuildTask` | this plan §5/T5.2 | Decide single owner of the "missing chunks" query; recommend retiring the old `BGAppRefreshTask`. |
| R8 | **Classifier on 256-d + stale 384-d seed vectors** | this plan §2/T2.3 | Hardcoded `vector.count == 384` guard (`MiniLMCentroidClassifier.swift:130`) must change; add a model-version-keyed seed-vector reset so cached MiniLM seed blobs don't poison the new centroids. |
| R9 | **`[SCHEMA-FALLBACK]` on upgrade** | CLAUDE.md item 8 | After the V6 edit, watch Console.app for `[SCHEMA-FALLBACK]` on a real-device run (`TranscriptStore.swift:126`). If it fires, the redefined-V6 hash mismatched an existing store — investigate before merge. |
| R10 | **`features.md` update** | `Jot/CLAUDE.md` | Ask is a user-facing feature; per CLAUDE.md, consult `features.md` and update it (Ask backend change, new "Rebuild search index" button) — user-facing copy only, no symbol names. |

---

### Appendix — grounding citations (file:line)

- Shipped schema = V4: `git ls-files Jot/Shared/Schema/`; `HEAD:Transcript.swift`
  typealias V4; `HEAD:TranscriptStore.swift:89` `JotSchemaV4`. V5/V6 untracked
  (`git status`).
- Current container: `TranscriptStore.swift:88–108`, fallback log
  `:126`, `cloudKitDatabase: .none` `:102`, App Group `:99`.
- Migration plan stages V1→V6: `JotMigrationPlan.swift:52–96` (V5→V6 lightweight
  `:91`).
- `TranscriptEmbedding` (to delete): `JotSchemaV6.swift:148–166`; typealias +
  `vector` extension `Transcript.swift:19, 28–41`; store `EmbeddingStore.swift`.
- Embedder seam: `MiniLMEmbeddingService.swift:88` `encode(_:) -> [Float]`,
  `:60` `modelVersion`, actor rationale `:25–52`.
- Indexer: `TranscriptIndexer.swift:39,52,67,150`.
- Backfill (BGAppRefreshTask): `EmbeddingBackfillTask.swift:32–35,99,135`,
  rationale banner `:8–31`.
- Ask pipeline + date parser: `AskController.swift:166–269`, `parseDateScope`
  `:378–479`, char cap `:97`, cosine `:578`, `orderedIDs` `:79,208`,
  `pickBackend` `:279–307`.
- Citation parser: `AskCitationParser.swift:132–138` (index→transcript).
- Classifier: `MiniLMCentroidClassifier.swift:46,130`; seeds
  `CategorySeedStore.swift` (model-agnostic `vectorData`).
- Rebuild button location + progress pattern: `EmbeddingsPanelView.swift:162–225,
  574–591`.
- Apple-FM removal surface: `AppGroup.swift:138,244–246`,
  `SettingsView.swift:31,444,453–482`, `AskView.swift:349–350`, `AskController`
  `pickBackend`/`LanguageModelSession`.
- Qwen `ask` seam: `LLMClient.swift:61`, `Qwen35Client.swift:471,503`
  (`maxTokens: 800`).
- Keyboard memory/no-MLX constraint: `Jot/CLAUDE.md` "Keyboard extension
  constraints"; `#if JOT_APP_HOST` gating `project.yml:271–282`.
- Test target: `JotTests` `project.yml:389–394`, existing tests `Jot/Tests/`.
- Frozen-check: `scripts/check-schema-frozen.sh`.
