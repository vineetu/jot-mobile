# Ask — retrieval architecture (RAG redesign)

Status: **REVIEWED — decisions locked (design-review pass complete)** · Supersedes
the tactical date-only patch in `ask-time-retrieval.md` (now just the
"deterministic filter" layer here). Next artifact: Phase-1 implementation plan.

This is the general design for doing retrieval-augmented Q&A over **thousands of
personal voice transcripts on-device**, independent of Jot's current code.

---

## 0. Layering principle — Embeddings (universal) vs Ask (Qwen-gated)

Decided in design review. This is the spine of the design:

- **The embedder is universal.** EmbeddingGemma runs for *every* user and powers
  search and the future mind-map. It is **not** gated on any chat model.
- **Qwen gates the Ask button only.** Ask (natural-language Q&A) needs a capable
  generator + reranker, which on-device = Qwen 3.5-4B. If Qwen isn't downloaded,
  **the Ask button simply isn't shown** (already implemented) — embeddings and
  search still work.
- **The user-seeded tag classifier is REMOVED** (decided in review — judged not
  useful; no one used it, it was buried in Settings). Code + UI deleted; the
  `TranscriptCategory` table is kept dormant (no destructive migration). The only
  thing tags were ever wanted for — the mind-map / garden — rides the embeddings
  directly (§6), so removal costs it nothing.
- **Apple Foundation Models is dropped from Ask** — too weak to be useful. The
  "Ask uses Apple Intelligence / Qwen" toggle and the Apple-FM backend path are
  removed → Ask is **Qwen-only**. *Future:* if Apple Intelligence improves,
  re-introduce it as a selectable Ask backend behind the same seam (don't design
  it out — just don't ship it now).

**Storage (verified):** transcripts live in **SwiftData (SQLite under the hood)**
in the App Group container `group.com.vineetu.jot.mobile.shared`, local-only
(`cloudKitDatabase: .none`, `TranscriptStore.swift:90-102`). SwiftData hides the
raw SQLite, so its FTS5 full-text engine is **not** reachable through the API —
which is why lexical search is in-memory BM25, not SQL FTS (§2.B).

**Phase-1 code cleanup this implies** (scaffolding already on the branch):
remove `AppGroup.askBackend` + the Settings "Ask uses" picker + the Apple-FM
branch/reasons in `AskController.pickBackend`; the sources-footer backend
indicator becomes constant (drop or hard-label "Qwen"); keep the Ask-pill
download gate (`currentProviderWeightsOnDisk`) as the single Ask availability rule.

---

## 1. Why today's results are garbage (root cause, not symptoms)

The current pipeline embeds **one vector per whole transcript** with
`all-MiniLM-L6-v2` and does top-K cosine. Every failure traces to that:

1. **Whole-transcript embeddings are a blurry average.** A 14-minute transcript
   is thousands of words crushed into one 384-d vector. Any specific idea inside
   it is averaged away — you can't retrieve a moment you can only retrieve a vibe.
2. **MiniLM truncates at ~256 tokens.** For long recordings the vector only
   "sees" the opening — the rest of the transcript is literally not embedded.
3. **MiniLM is old/weak** by 2026 standards.
4. **No lexical channel.** Dense vectors miss exact terms — names, jargon,
   acronyms, error codes. ("Claude", a person's name, a project codename.)
5. **No reranking.** Raw cosine ordering is coarse; the right chunk is often at
   rank 12, not rank 1.
6. **Wrong tool for vague/aggregate queries.** "What have I been thinking about
   lately" is **not a search** — it's a time-scoped *summarization*. Forcing it
   through nearest-neighbor returns near-arbitrary notes. (This is exactly what
   you saw: "last 3 days" pulled semantically-nearest May 21–23 notes.)

The date band-aid only fixed #6 for date words. The rest needs the real pipeline.

---

## 2. Target architecture

### A. How to create the embeddings (ingestion)

- **Chunk, don't whole-document.** Split each transcript into **length-adaptive**
  windows (~256 tokens, ~15% overlap). Short notes (the majority) stay a **single
  chunk**; only long recordings split. Chunk on sentence boundaries where present
  — Parakeet output is generally punctuated, so this works; the only exceptions
  are very short/bad transcripts, which are single-chunk anyway. Keep a plain
  token-window fallback for the rare unpunctuated case. Each chunk carries
  metadata: `transcriptID, createdAt, durationSeconds, source,
  charStart/charEnd` (offsets let a citation deep-link to the *moment*).
- **Better model: `EmbeddingGemma-300M`** (Google, Gemma-3-derived). Native 768-d
  with **Matryoshka** truncation to 512/256/128 — store **256-d**. Verified iOS
  path: a **Core ML port with ~99.8% ANE optimization** ([CoreML-LLM](https://github.com/john-rocky/CoreML-LLM),
  `EmbeddingGemma.swift`); MLX 4/5-bit builds also exist. **Integration note:**
  this is a *new* on-device path — the current `MiniLMEmbeddingService` runs on
  `swift-embeddings`/MLTensor, NOT MLX/Core ML — so we add a Core ML embedder
  **behind the existing `encode(_:) -> [Float]` seam** (`MiniLMEmbeddingService.swift`).
  Preserving that seam is the maintainability win: the next model swap is an impl
  change, not an API change. Use asymmetric prefixes (`query:`/`document:`).
- Keep one **transcript-level summary embedding** too (coarse recall / dedup).
- **Scale reality check (target: iPhone 16/17):** 1,000 transcripts × ~10 chunks
  = 10k vectors × 256 floats ≈ **10 MB** (≈50 MB at 50k chunks — fine on this
  hardware). Brute-force cosine with Accelerate/`vDSP` is **<50 ms**. ⇒ **No ANN
  index / vector DB** until ~100k+ chunks; the documented scaling lever past that
  is **int8-quantized vectors** (4× less RAM) then an ANN index. Don't build HNSW
  now — premature.

### B. How to feed them to the model for good results

A 2-stage **hybrid retrieve → rerank → synthesize** pipeline (the 2026 baseline;
two-stage hybrid+rerank hits Recall@5 ≈ 0.82 / MRR@3 ≈ 0.61 vs single-stage):

1. **Query understanding** (cheap, mostly deterministic + optional Qwen):
   - **Intent routing** — the key idea:
     - `LOOKUP` ("what did I say about X") → retrieval + QA.
     - `SUMMARIZE/AGGREGATE` ("lately", "last 3 days", "themes this week") →
       metadata filter → **map-reduce summarize**, NOT vector search.
     - `BROWSE/FILTER` ("notes from my watch", "long recordings") → pure
       metadata filter.
   - **Safe default:** when intent is ambiguous (e.g. topic *and* time —
     "what did I think about X lately"), **fall back to retrieval (LOOKUP) with
     the date filter applied**, never to a bare summarize. A wrong LOOKUP degrades
     gracefully (still shows relevant notes); a wrong SUMMARIZE confabulates.
   - Extract the deterministic `RetrievalFilter` (§C).
   - Optional (Phase 2): query rewrite, **multi-query**, or **HyDE**.
2. **Candidate generation — hybrid.** Run in parallel, each prefetch ~50:
   - **Dense**: chunk vector top-K (brute-force cosine).
   - **Lexical**: **in-memory BM25 in Swift** over the chunk corpus. *Not* SQLite
     FTS5 — SwiftData hides the raw SQLite so FTS5 isn't reachable, and an
     in-memory inverted index is **zero new dependencies** (maintainability tenet),
     trivial at ≤50k chunks, rebuilt on launch / maintained incrementally. Catches
     the literal tokens dense misses (names, codenames, jargon).
   - Fuse the two ranked lists with **Reciprocal Rank Fusion (k=60)** — robust,
     no score-scale tuning. Apply the metadata pre-filter to the pool.
3. **Rerank — Qwen-as-reranker (Phase 1).** Listwise re-rank the top ~20–50 with
   the on-board Qwen → top 6–10 chunks. No extra model (Qwen is always present
   when Ask is available, by §0). A dedicated Core ML cross-encoder
   (BGE/Jina-reranker-v2) is a **Phase-2** option if latency/quality warrant.
   Reranking is the biggest single precision win after hybrid.
4. **Context assembly.** Sentence-window expansion (pull each winner's neighbor
   chunks for coherence), dedup, **token-budget pack** (see below), order by
   intent (relevance for lookup, chronological for summaries).

   **Context budget — measured, not a transcript count.** The old `top-15` +
   12k-char cap were sized for Apple FM's ~4k window; Ask is now Qwen-only and
   Qwen3.5-4B is **262k native**, so the model is not the limit — the iPhone is:
   - **KV-cache memory** (~100–150 KB/token for a 4B model fp16 → ~0.5 GB @4k,
     ~1.2 GB @8k on top of ~2.2 GB weights). The ceiling — but iPhone 16/17 have
     the headroom for the working range below.
   - **Prefill latency** (~linear in context).
   - **Lost-in-the-middle** (stuffed context degrades QA — the reason to rerank).
   
   ⇒ Retrieve WIDE (~50 candidate chunks), rerank, pack the best into a TOKEN
   budget (~4–8k to start). Find the knee empirically: sweep 4k/8k/16k on the
   target device, record peak memory + prefill latency + eval quality, take the
   largest that's memory-safe, fast, and before quality plateaus. Lever if needed:
   **quantized (8-bit) KV cache** ≈ halves memory/token — *verify mlx-swift-lm
   exposes it* (MLX-Python does; the Swift port may lag).
5. **Generate.**
   - `LOOKUP` → stuff top chunks, answer + cite (chunk → transcript + timestamp).
   - `SUMMARIZE` → **map-reduce**: summarize each transcript/cluster in the
     window, then synthesize across them. This is what makes "what have I been
     thinking about lately" actually work.
6. **Citations.** The shipped cite-by-index parser maps `[cite: N]` → the Nth
   *retrieved transcript*; under chunking it must map `[cite: N]` → the Nth
   *packed chunk* → its **parent `transcriptID`** (+ char offset → future
   deep-link to the moment). Small parser migration, called out so it isn't missed.

### C. Simple deterministic filtering (date / type) — first-class

```
struct RetrievalFilter {
    var dateInterval: DateInterval?     // "last 3 days", "May 26" (parser already built)
    var source: String?                 // watch / phone / import  (type)
    var minDurationSeconds: Double?      // "long recordings"
}
```

- Extracted deterministically up front; applied as a **SQL predicate that scopes
  the candidate pool before scoring** — works across all three intents.
- The date parser shipped this turn IS this layer, generalized. "type" =
  `source`/`duration` buckets.
- **No tag filter.** The user-seeded tag classifier was removed (judged not
  useful) — see §0. "Tag-like" grouping returns later as *emergent* clusters
  (§6), not a user-maintained taxonomy.

#### C2. Signal weighting — demote "temporary"/meta entries

The corpus is polluted by **meta-instructions** saved as transcripts (Ask-style
questions, keyboard rewrite instructions, dictated prompts). This is the actual
cause of the observed failure (Qwen: "requests for summaries that were never
fulfilled"). Fix WITHOUT changing the capture path — label + weight:

- **Provenance pre-filter (deterministic, high-precision):** exclude/demote by
  metadata already in the schema — `instruction != nil` / `derivedFromID != nil`
  (a rewrite, not a note), and `source` (keyboard vs mic vs watch vs import).
- **Usefulness weight (soft scalar, computed at index time):** multiplies the
  fused retrieval score (or is a reranker feature). Signals: context density
  (length / `durationSeconds`), imperative/meta shape ("summarize…", "rewrite…",
  "what did I…"), and engagement (`rewriteUpvoted`, kept/edited/favorited).
  Low-signal entries sink but don't vanish.

---

## 3. Staging (so this isn't a 3-month rewrite)

- **Phase 1 — the quality unlock (do first):** chunking + EmbeddingGemma +
  hybrid (dense + **in-memory BM25**) + RRF + metadata pre-filter + **intent
  routing (lookup vs summarize)** + map-reduce for summaries + **Qwen-as-reranker**.
  This alone should flip Ask from "useless" to "good."
- **Phase 2 — precision & polish:** dedicated Core ML cross-encoder reranker,
  HyDE/multi-query, sentence-window expansion, timestamp deep-links,
  int8 vector quantization (only if scale demands).
- **Eval harness (build alongside Phase 1):** 30–50 `(question → expected
  transcripts/answer)` pairs. Source: the **developer's own corpus**, hand-labelled
  (can't ship a generic set — it's personal data; keep it local/out of the repo).
  Track Recall@k + MRR + answer quality, plus the context-budget sweep (memory /
  prefill latency). Without it we're guessing whether a change helped.

## 4. Schema impact — clean rebuild (embeddings are beta, shipped to nobody)

Because no user has the embedding feature, we do **not** preserve old data or run
a coexistence migration. We tear out and recreate from transcripts (the untouched
source of truth):

- **Mint `JotSchemaV7`** (decided in review — *not* an in-place V6 edit): the
  developer's device holds a live V6 store with real transcripts (local builds),
  so V6 is frozen-on-device. V7 **drops `TranscriptEmbedding`** + **adds
  `TranscriptChunk`** (keep `Transcript`/`TranscriptCategory`), bump
  `versionIdentifier` to 7.0.0, append a `.custom` V6→V7 stage (`willMigrate`
  deletes embedding rows; chunks are rebuilt by the re-index, not migrated).
  Transcripts preserved deterministically.
- Also delete `MiniLMEmbeddingService` (and the MiniLM 384-d classifier seed
  vectors — re-embed at 256-d). `TranscriptChunk` fields: id, transcriptID,
  chunkIndex, text, vectorData, charStart, charEnd, embeddedAt, modelVersion.
  Lexical index is in-memory (no schema).
- **Re-index = user-triggered button + background, NOT auto-backfill.** A
  "Rebuild search index" button (Settings/Embeddings panel) kicks off a
  background re-index that chunks + re-embeds every transcript with EmbeddingGemma.
  - **Scheduling correction:** the existing `EmbeddingBackfillTask` is a
    `BGAppRefreshTask` (30 s budget) sized for MiniLM (22 MB, ~40 ms/encode). The
    new job — EmbeddingGemma × ~10 chunks/transcript × thousands — is far heavier
    and needs the **`BGProcessingTask` + `requiresExternalPower`** pattern the old
    Qwen classifier used, with **resumability + progress UI**. The button gives an
    immediate foreground/charging path; BGProcessingTask drains the backlog.
- (No classifier to migrate — the tag/classifier feature was removed; see §0.)

## 5. Validation items (confirm before building)

- **EmbeddingGemma-300M on iOS — confirmed feasible** via the Core ML / ANE port
  ([CoreML-LLM](https://github.com/john-rocky/CoreML-LLM)); still confirm **license**
  for shipping + measure cold-load + per-chunk latency on iPhone 16/17.
- `mlx-swift-lm` **quantized KV-cache** support (the context-budget lever).
- Qwen-as-reranker listwise quality + latency over ~20–50 chunks.
- ~~FTS5 access~~ — **resolved**: not reachable through SwiftData → in-memory BM25.
- ~~Apple-FM degraded path~~ — **resolved**: Apple FM dropped from Ask (§0).

---

## 6. What this unlocks later (NOT scoped — do not implement)

The chunk-embedding substrate is multi-purpose. Beyond Ask, the same vectors are
the raw material for a **mind map / garden of ideas** — which the user confirmed
is the *only* reason tags ever existed. **It does NOT need the (now-removed) tag
classifier**: the structure comes from the embeddings themselves, so removing
tags cost this nothing. "Ideas that intersect" = vectors that sit close / clusters
that share members. Adjacent high-value, zero-friction features on the same
substrate: **related-notes** ("you've said this before" — nearest neighbors on any
note) and **auto-grouped Collections**.

- **Nodes:** clusters over chunk embeddings (HDBSCAN/k-means → emergent topics),
  each cluster LLM-labelled ("cluster-then-label", BERTopic-style). No
  user-maintained taxonomy — the app discovers and names the themes.
- **Edges:** cosine between cluster centroids (semantic links) + temporal co-occurrence.
- **Layout:** UMAP/PCA → 2D, or a force-directed SwiftUI canvas. Cheap at ~10k chunks.
- **Cost:** data layer is free from Phase 1; only adds a clustering+labeling pass
  and a graph UI. No new model.

#### Two-layer architecture (decided in discussion — garden = a *layer on the substrate*, not a separate build)

The garden's nodes should be **distilled memories**, not raw chunk clusters — the
garden's job is a clean, readable map, not faithful recall. So:

- **Bottom layer = raw `TranscriptChunk`s** (Phase 1). Verbatim, cited. What Ask +
  search use, because there you want exactly what was said.
- **Top layer = distilled "idea cards"** the LLM writes from clusters (title + gist
  + how it evolved). Each card **links back down to its source chunks** — read the
  idea, tap through to the real notes.

**Reuses the substrate — NO second embedding system, not from scratch:** same
EmbeddingGemma encoder (embed the distilled memory text), same vector-similarity
machinery (dedup / "does this update an existing memory" / edges), same Qwen
(extraction + consolidation), same chunked notes as source. **Net-new** is only:
a small `Memory`/idea-card `@Model` (its text + own embedding + source links), the
**extract + consolidate engine**, and the garden UI.

**The hard part is NOT ours yet — lean on Mem0.** Hybrid retrieval is commodity;
Mem0's actual research is the *consolidation* layer: what to extract + at what
granularity, and the ADD/UPDATE/DELETE/dedup/contradiction-resolution-over-time
logic — benchmarked (LOCOMO-style), iterated as a company. For the garden's memory
layer, **port Mem0's methodology** (their extraction/update approach) rather than
reinvent it (their lib is Python/server, not on-device Swift — adopt the approach,
not the code). Own what's genuinely ours: on-device/ANE, voice notes, the verbatim
raw-note substrate, the visual garden. **Guardrail:** every card cites its source
chunks and is *derived* (regenerate anytime) — the raw note always wins. See Mem0
contrast: distilled-evolving-memories (theirs) vs verbatim-retrieved-notes (ours);
we keep both by distilling on top, not at storage.

Flagged only to record the direction — this feature has not been designed in detail.

### Sources
- [The Best Open-Source Embedding Models in 2026 — BentoML](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [Which Embedding Model Should You Use in 2026? (MTEB guide) — KnowledgeSDK](https://knowledgesdk.com/blog/embedding-model-comparison-2026)
- [Hybrid Search Done Right: BM25 + HNSW + RRF — Medium](https://ashutoshkumars1ngh.medium.com/hybrid-search-done-right-fixing-rag-retrieval-failures-using-bm25-hnsw-reciprocal-rank-fusion-a73596652d22)
- [Retrieval Optimization: Chunking & Re-ranking 2026 — freeacademy.ai](https://freeacademy.ai/blog/retrieval-optimization-rag-chunking-reranking-quantization-2026)
- [From BM25 to Corrective RAG: Benchmarking Retrieval Strategies — arXiv](https://arxiv.org/html/2604.01733v1)
- [google/embeddinggemma-300m — Hugging Face](https://huggingface.co/google/embeddinggemma-300m)
- [CoreML-LLM (EmbeddingGemma on ANE, iOS) — GitHub](https://github.com/john-rocky/CoreML-LLM)
- [Qwen/Qwen3.5-4B (262k context) — Hugging Face](https://huggingface.co/Qwen/Qwen3.5-4B)
