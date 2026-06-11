# Ask — Product-Help lane (design)

> **Status: IMPLEMENTED on `feature/ask-product-help` — compiles clean
> (BUILD SUCCEEDED), awaiting on-device verification.** Decisions + evidence below.
> Built after a brainstorm + adversarial review pass. End-to-end "tap it" run must
> happen on a physical iPhone — Ask's Qwen backend (MLX) does not run on the
> simulator.
>
> Feature folder name: `ask-product-help`. No `requirements.md` exists; intent is
> in "Feature overview" below.
>
> **What shipped on the branch:**
> - `Jot/App/Ask/HelpCorpus.swift` — `HelpCorpusIndex` (bundled-JSON load,
>   version guard, `bestCosine`, hybrid `retrieve`).
> - `Jot/App/Ask/AskController.swift` — `answerCorpus` state, score-gated routing
>   in `runPipeline`, `runHelpLane`, help prompt, calibrated thresholds.
> - `Jot/App/Ask/AskView.swift` — "From Jot's Help" provenance label +
>   corpus-branched attribution line.
> - `Jot/Resources/help-corpus.json` — 114 pre-embedded chunks (bundled).
> - `scripts/make-help-corpus.sh` + `scripts/help-corpus/` (generator) +
>   `scripts/check-help-corpus-fresh.sh` (staleness guard).
> - `features.md §14.7` documents the feature (bidirectional links to §9, §14.1).
>
> **On-device checklist:** ask a how-to ("how do I pause a recording?") → expect a
> plain answer with the "From Jot's Help" label; ask a notes question → unchanged
> transcript answer; confirm no misroute on a borderline ("what did I note about
> the keyboard").

## Feature overview

Add a **second, auto-routed retrieval lane** to Ask Jot. Today Ask answers ONLY
from the user's own dictated transcripts (`AskController.swift:898` system prompt:
*"using ONLY the user's own dictated transcripts"*). The new lane answers
**"how do I use Jot" / "what can Jot do"** questions from a **help corpus distilled
from `features.md`** — without the user choosing a mode. One Ask box; an intent
router decides which lane (or both) serves each question.

**Why it belongs in Ask (not a separate Help search):** users won't pre-classify
"is this a me-question or an app-question." A single natural-language box is the
right surface. But the two MUST stay **separate lanes under a router** — merging
the corpora invites the model to confabulate ("you noted that the keyboard…" when
it was a help doc), which Ask's whole design already fights.

## Background — how Ask works today (code-grounded)

- **Pipeline:** `AskController.runPipeline` (`Jot/App/Ask/AskController.swift`):
  date-scope parse → `retrieveTopK` (hybrid: brute-force BM25 floor over raw
  transcripts + EmbeddingGemma dense over chunks + chunk-level BM25, fused by RRF
  k=60) → vague gate → build prompt → stream from Qwen → cite-by-index parser.
- **Corpus = `Transcript` rows** (SwiftData). Chunks = `TranscriptChunk` via
  `EmbeddingGemmaService` (`embeddinggemma-300m-256`, 256-d unit-norm).
- **Citations:** `[cite: N]` → Nth retrieved transcript → tappable transcript chip.
- **Backend:** Qwen-only for synthesis (Apple FM dropped — "too weak", §0 of
  `ask-retrieval-architecture.md`). Retrieval substrate is corpus-agnostic.

The retrieval machinery (EmbeddingGemma + BM25 + RRF + the streaming citation
parser) is **corpus-agnostic** — the help lane is a second instance of the same
machinery pointed at a different corpus.

## User-confirmed decisions (from kickoff Q&A)

1. **Routing UX = auto-route (one box) + provenance label (CONFIRMED).** Jot
   decides the lane automatically; no mode toggle. Every answer carries a small
   "answered from Jot's help" / "from your notes" label so a wrong guess is
   visible + re-askable (reuses the existing `answerBackend` footer slot). Owner
   confirmed both the auto default and the label.
2. **Corpus source = distill `features.md`.** Confirmed against alternatives below.
3. **Capability = full RAG lane** (chunk + embed + hybrid retrieve + cite), reusing
   the substrate — not a "stuff the whole doc" shortcut.
4. **Chunking = structural `§N.M` + recursive-512 fallback (CONFIRMED by the
   experiment below).** The two model-based chunkers both lost.

## Key architectural findings (code-grounded)

### F1. The help corpus needs NO schema migration — it's bundled & static

Unlike the transcript lane (which forced `JotSchemaV7` + `TranscriptChunk`), the
help corpus is **authored, static, ships in the bundle**. So:
- Pre-chunk + pre-embed it **at build time**; ship vectors as a bundled JSON.
- Build an **in-memory index at launch** (same pattern as the transcript BM25
  floor). No SwiftData entity, no migration, no background backfill, no
  `TranscriptIndexer`. This is dramatically cheaper than the transcript lane.

### F2. `features.md` is the right source; the Help screen is too thin

- `features.md` = 114 feature subsections (`## N` → `### N.M`), authored
  "one-paragraph-per-feature" with `§N.M` anchors. Comprehensive + authoritative.
- The Help redesign (`docs/help-redesign/design.md`) is a **scannable deck** (4
  expandable rows + troubleshooting accordion) — human-reading copy, too thin for
  RAG coverage.
- **Caveat (to discuss):** `features.md` is *internal* (it has framework names,
  `§` anchors, cross-links, deliberate "caveat" entries documenting bugs e.g.
  §5.10/§7.11). Distillation must strip to user-facing prose. The doc's OWN style
  rules already define "user-facing" precisely — that rule IS the distillation
  contract. The Help **troubleshooting accordion** is genuinely Q&A-shaped and
  worth folding into the corpus.
- **Each `§N.M` anchor is a built-in citation/deep-link target** → a help citation
  chip can deep-link into the redesigned Help screen sections.

### F3. The router is the whole ballgame (the real risk)

Auto-routing's only failure mode is a misroute: "how does the keyboard work?"
(product) vs "what did I note about the keyboard?" (personal) are lexically close.
Proposed two-tier classifier mirroring the existing deterministic date-scope
detection: cheap lexical priors ("how do I", "can Jot", "does the app", "where is
the setting") + Qwen tie-break for ambiguous queries (Qwen is always resident when
Ask is available). **Needs its own eval set.** (Design — to discuss.)

## Investigation: which chunking strategy? (experiment)

You asked to test Apple Intelligence vs EmbeddingGemma chunking, judged
empirically rather than asserted. I built a faithful offline harness using the
**real production embedder** (bundled EmbeddingGemma-300M, 256-d, via the same
`CoreML-LLM` package the app uses — confirmed unit-norm, dot = cosine) and the
**real on-device Apple Intelligence** (FoundationModels CLI — confirmed available).

**Method (RAGAS-aligned):** 32 hand-labeled "how do I use Jot" questions, each
mapped to gold `§N.M` section(s). Fix retrieval (EmbeddingGemma dense top-k,
`retrieval_query`/`retrieval_document` prefixes — production-faithful), vary ONLY
the chunking. A retrieved chunk "hits" if its source section ∈ gold. Report
Recall@k + MRR (judge-free, gold-based — the gold-standard for the chunking Q).

**Chunking variants:**
- **structural** — one chunk per `§N.M` (the doc's authored boundaries); recursively
  split the 4 subsections >512 tok. 118 chunks, mean 193 tok. *(the "free baseline")*
- **recursive512** — structure-blind recursive split at ~512 tok / 15% overlap
  (FloTorch 2026's generic winner). 61 chunks, mean 476 tok.
- **embedding** — EmbeddingGemma semantic-breakpoint: split where adjacent-sentence
  cosine drops below the 25th percentile. 156 chunks, mean 142 tok, 26 chunks blend
  sections.
- **ai** — Apple Intelligence windowed semantic chunking (model picks chunk-start
  sentences; robust index-based, no paraphrase). 436 chunks, mean **50 tok** — the
  model over-fragmented badly.

### Results

| variant | R@1 | R@3 | R@5 | R@10 | MRR | #chunks | mean tok |
|---|---|---|---|---|---|---|---|
| **structural** | **0.688** | **0.844** | **0.906** | **0.969** | **0.780** | 118 | 193 |
| embedding (Gemma-semantic) | 0.656 | 0.688 | 0.750 | 0.844 | 0.705 | 156 | 142 |
| ai (Apple Intelligence) | 0.500 | 0.750 | 0.844 | 0.938 | 0.652 | 436 | 50 |
| recursive512 | 0.469 | 0.594 | 0.594 | 0.719 | 0.549 | 61 | 476 |

Harness: real bundled EmbeddingGemma-300M (256-d, via `CoreML-LLM` 1.9.0) + real
on-device Apple Intelligence (FoundationModels). 32 gold-labeled questions.
Throwaway harness lives in `/tmp/jot-help-chunking` (not committed).

### What the literature says (corroboration)

- **FloTorch (Feb 2026), 7 strategies:** recursive/fixed-512 won on generic
  academic prose; **semantic + LLM/proposition chunking underperformed** — they
  "dilute accuracy and waste retrieval focus" and make 3–5× more vectors.
- Explicit guidance: spend complexity budget on **reranking + hybrid search** (Ask
  already has both), **NOT** on chunking.
- **The Jot twist:** FloTorch's recursive-beats-structural result is on prose with
  no clean boundaries. Jot's corpus is the *opposite* — hyper-structured, one
  topic per `§N.M` — so here **structural wins** and structure-blind recursive
  *loses* (its big blended chunks dilute the signal). The principle is the same
  (tight, topically-pure chunks win); the corpus structure flips which method
  produces them.

### Reading of the evidence

For Jot's help corpus, **structural chunking on the authored `§N.M` boundaries is
the best AND the cheapest** — and it hands us the citation anchor for free. It wins
clearly on **R@1 (0.69) and MRR (0.78)** — the metrics that matter for a
citation-based answer where you want the single best chunk to be the right one.

The two "smart" chunkers both **lost** and both demonstrated the literature's
predicted failure mode:
- **Apple Intelligence over-fragmented** (436 chunks, mean 50 tok) — it scattered
  each feature across many tiny pieces, tanking R@1/MRR (the best single chunk is
  rarely complete). R@10 recovers because fragments are still findable, but a
  citation answer reads the top chunks, not the top 10.
- **EmbeddingGemma-semantic** blended across section boundaries (26 multi-section
  chunks) and fragmented mid-feature — middle of the pack.
- **recursive512** made big blended chunks (mean 476 tok) — worst, the dilution
  failure.

**Conclusion:** the author already drew better boundaries than either model
invents. Apple Intelligence / EmbeddingGemma chunking add cost, nondeterminism,
and (for AI) a build-time model dependency for **negative** retrieval value here.
→ **Recommend structural `§N.M` chunking + recursive-512 fallback for the 4
oversized sections.** This directly answers your "prechunk with EmbeddingGemma or
Apple Intelligence" question: tested both, neither beats the free structural split
on this corpus.

**LLM-as-judge (context-sufficiency, Apple Intelligence as judge) on structural's
top-5 retrieval:** 25/32 SUFFICIENT, 4 PARTIAL, 3 INSUFFICIENT → **0.78 fully
sufficient, 0.91 at-least-partial**. Cross-validates the gold-label metric: the
retrieved context is genuinely *answerable* end-to-end, not just a gold-id match.
(Gold-label Recall@k/MRR remains the primary chunking metric — it's judge-free and
doesn't inherit the model's bias; the judge is corroboration, per RAGAS practice.)

## Options explored & tradeoffs

### Corpus source
| Option | Pro | Con |
|---|---|---|
| **Distill `features.md`** (chosen) | comprehensive, authoritative, `§` anchors = citations | needs a user-facing distillation pass; drift vs source |
| Help-screen copy | already user-safe | too thin/marketing-shaped for RAG coverage |
| Purpose-written FAQ | best answer shape | most authoring effort; another doc to maintain |

### Chunking (measured)
| Option | Pro | Con |
|---|---|---|
| **Structural `§N.M`** (recommend) | best retrieval (MRR 0.78), free, deterministic, anchor=citation | 4 oversized sections need a recursive fallback |
| Recursive-512 | generic SOTA, structure-agnostic | worst here (MRR 0.55) — big blended chunks |
| EmbeddingGemma-semantic | adapts to content | worse than structural (MRR 0.71); cross-section blends; nondeterministic |
| Apple Intelligence | "smart" boundaries | over-fragments (mean 50 tok, MRR 0.65); cost + nondeterminism + build-time model dep |

## Open design questions (for discussion — NOT decided)

1. **Router design + threshold.** Lexical-prior + Qwen tie-break — acceptable
   latency? What's the safe default on ambiguity (answer one lane, or retrieve both
   and let synthesis pick)? Needs its own labeled eval set. *(Implementation detail
   to settle during planning — does not block the design.)*
2. ~~Provenance footer~~ — **RESOLVED: yes, keep the answer-source label** (owner
   confirmed). Auto-route + label is the chosen UX.
3. **Distillation pipeline.** A build-time generator (`features.md` → bundled
   `help-corpus.json`) so it can't drift, vs a hand-maintained copy. Who owns
   regeneration when `features.md` changes?
4. **Citation deep-link target.** Map `[cite]` → `§N.M` → which Help screen
   destination? (Depends on the Help redesign shipping.)
5. **Honesty contract when BOTH lanes miss** — distinct "Jot can't do that / not
   in your notes" messaging per lane.

## Adversarial review — resolutions (changed the design)

A critic pass found 5 must-fix items; all adopted:

- **No hard router → retrieve-both, compare scores (H1).** Replaced the
  lexical+Qwen classifier with a score gate: embed the query once, compare the
  **best query-cosine** against the help corpus vs the transcript chunks (same
  embedder → comparable). Help lane wins only if `helpBest > notesBest + MARGIN`
  AND `helpBest > FLOOR`; a date-scoped query never routes to help. Otherwise the
  existing transcript pipeline runs **unchanged** (low blast radius). No Qwen
  pre-classify = no cold-start stall on the critical path.
- **Help answers carry NO citations (owner decision — supersedes B1).** Help is
  *informational*: just answer plainly. No `[cite]` markers, no help-citation
  segment, no parser change, no deep-link. This **removes the B1 blocker entirely**
  — `AskAnswerSegment`/`AskCitationParser` are untouched; the help answer renders as
  plain `.text` segments. (Per-sentence citation only ever made sense for the
  transcript lane, where the user wants to see *which note*.)
- **Provenance ≠ backend (H2).** New `answerCorpus: {notes, help}` on the
  controller (orthogonal to `answerBackend`). `attributionLine` + `sourcesSection`
  branch on it ("Answered from Jot's Help · on-device", no "N notes searched").
- **Staleness + model-version landmines (H3/H4).** `help-corpus.json` stamps
  `sourceHash` (of distilled text) + `modelVersion`. Load asserts
  `modelVersion == EmbeddingGemmaService.modelVersion` → else **disable help lane**
  (route all to notes) + log. `scripts/check-help-corpus-fresh.sh` fails the build
  if `features.md` changed without regenerating (mirrors `check-schema-frozen.sh`).
- **Distillation must drop caveat/bug entries (M4).** Exclude §5.10, §7.3, §7.11
  (documented non-working/buggy UI) and strip markdown cross-links + bold from the
  embedded text; keep the anchor only as citation metadata.

## Implementation plan (build order)

1. **Generator** (`scripts/` + reuse `/tmp/jot-help-chunking` harness): clean
   `features.md` → structural §N.M chunks (recursive-512 for the 4 big ones, drop
   caveats) → embed (EmbeddingGemma 256-d) → `Jot/Resources/help-corpus.json`
   `{ modelVersion, sourceHash, chunks: [{id,title,anchor,text,vector}] }`.
2. **`HelpCorpusIndex`** (`Jot/App/Ask/HelpCorpus.swift`): load bundled JSON off
   main; version-guard; `bestCosine(queryVec)`; `retrieve(query, queryVec, k)` =
   dense cosine + BM25 (reuse `BM25Index`/`RRFFusion`) → top-k help chunks.
3. **Citations:** `.helpCitation` case + parser resolver generalization.
4. **`AskController`:** `answerCorpus`, help state, score-gate at top of
   `runPipeline`, `runHelpLane` (prompt → Qwen stream → help-cite parse), clear in
   `ask()`/`reset()`, cancellation guards.
5. **`AskView`:** help chip render + tap → Help screen, provenance label (visible
   during streaming), `sourcesSection`/`attributionLine` branch on `answerCorpus`.
6. **`project.yml`** bundle the resource; `xcodegen`; build; fix.
