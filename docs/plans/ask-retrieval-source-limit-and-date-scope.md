# Ask — research: source-count limit (15) & date-scoped questions

Status: **RESEARCH / open questions — not scheduled for implementation.** This is a
read-it-later investigation, not a build plan. It answers two questions the
product owner raised:

1. We cap Ask retrieval at **15 sources**. Can we go higher? What's the real
   constraint, and what's the smarter lever?
2. How do we handle **date-iterated questions** today ("last week", a specific
   day, etc.) — and where does that fall short?

Related: [ask-mode.md](ask-mode.md) §7 (prompt budget), [ask-retrieval-architecture.md](ask-retrieval-architecture.md)
(hybrid + RRF), [ask-time-retrieval.md](ask-time-retrieval.md) (the drafted
date+topic plan — the main fix for question 2), features.md
[§14.1](../../Jot/features.md#14-1-natural-language-qa) / [§14.4](../../Jot/features.md#14-4-library-wide-retrieval--indexing).

---

## 0. The numbers as they stand today

All in `Jot/App/Ask/AskController.swift`:

| Constant | Value | Meaning |
|---|---|---|
| `retrievalK` | **15** | Max transcripts handed to the answer model (both the semantic and the date path). |
| `userTurnCharLimit` | **12000** | Hard ceiling on the assembled user turn (question + sources). Char-based heuristic. |
| `snippetCharLimit` | **500** | Per-transcript truncation before it goes in the prompt. |
| `vagueThreshold` | **3** | Fewer than 3 plausibly-relevant notes (semantic path only) → "be more specific" instead of a model call. |

Two retrieval paths feed the same answer step:

- **Semantic top-K** (`retrieveTopK`) — a lexical floor (BM25 over raw transcript
  text, so every note is reachable) fused via RRF with dense (EmbeddingGemma
  cosine) + chunk-level BM25 over indexed chunks. Takes the top **15** transcripts.
- **Date-scoped** (`retrieveByDate`) — when the question parses to a date window,
  fetch by `createdAt` in that window, **most-recent-first, capped at 15**,
  returned chronologically. Skips the embedding scan and the vague gate entirely.

Then `buildUserTurn` truncates each of the ≤15 transcripts to 500 chars and drops
the lowest-ranked ones until the whole turn fits under 12000 chars.

---

## 1. Can we go higher than 15 sources?

### What actually binds the number

The **15 is calibrated to the weaker of the two answer backends — Apple
Foundation Models**, whose on-device context window is **~4096 tokens**
(input + output), per `ask-mode.md` §160. Rough budget at ~4 chars/token:

- 15 sources × 500 chars ≈ **7,500 chars ≈ ~1,900 tokens** of source text
- instructions block ≈ ~400 tokens
- the question ≈ tens of tokens
- output reservation (the answer itself) ≈ 800–1,024 tokens

That already lands near the ~4k ceiling. So on Apple Intelligence, **15 × 500
is roughly maxed out** — raising K without other changes would just cause
`buildUserTurn` to drop the extra sources to stay under 12000 chars (no real gain).

The **on-board model — Qwen 3.5 4B (4-bit, MLX)** (`Qwen35Client`,
`mlx-community/Qwen3.5-4B-4bit`) — has a **much larger native context** (the Qwen3
family is ~32k tokens; we don't cap it explicitly in code, only the *output* at
800–1024 tokens). So purely on context budget, Qwen could ingest **40–60+
sources**. But raw source count is the wrong lever to pull, for four reasons:

1. **Latency.** On-device prefill cost scales roughly linearly with input tokens.
   Doubling the sources roughly doubles time-to-first-token on the ANE/GPU. Ask
   is already noticeably slower on a cold Qwen; 3–4× the context would hurt.
2. **Memory.** The KV cache grows with context length. A 4-bit 4B model plus a
   large KV cache pushes against the app's memory budget (and the keyboard's
   60 MB ceiling is a separate, stricter constraint — but Ask runs in the main
   app, so this is "only" app-level pressure).
3. **"Lost in the middle."** Small models (a 4B especially) attend worse to
   content buried in the middle of a long context. Past a point, **more sources
   dilute answer quality** rather than improve it — the model anchors on the
   first/last few and skims the rest.
4. **Retrieval precision.** RRF's top-15 are the genuinely most-relevant notes.
   Ranks 16–40 are progressively lower-signal; adding them trades precision for
   recall and feeds the model more noise to wade through.

### The smarter levers (higher ROI than raising K)

If the goal is "better answers that draw on more of my notes," these beat a
bigger K:

- **Backend-aware K.** Keep ~15 for Apple FM; raise to ~25–40 only when the
  active backend is Qwen. One config split, respects each model's real budget.
- **Bigger per-snippet budget.** `snippetCharLimit = 500` is aggressive — a
  3-minute dictation is ~2,000+ chars, so it's cut to ~25% of itself. For many
  questions, **giving the top few notes more room beats adding more notes.**
  (e.g. top-5 at 1,500 chars carries more usable signal than 15 at 500.)
- **Chunk-level context, not truncated transcripts.** Retrieval already ranks
  *chunks*; feed the most-relevant chunks (denser, on-topic tokens per byte)
  instead of whole transcripts hard-cut at 500 chars.
- **Token-accurate budgeting.** Replace the 12000-char heuristic with a real
  per-backend tokenizer count. The char estimate is conservative; an exact count
  reclaims headroom (more/longer snippets for free).
- **Map-reduce for large sets.** For broad questions (and big date windows —
  see §2), summarize each note (or cluster) first, then synthesize from the
  summaries. This scales to an unbounded source count without ever blowing the
  context window — at the cost of more model calls.

### Bottom line for question 1

The 15 cap isn't arbitrary — it's the Apple-FM context ceiling. **On Apple
Intelligence, 15 is near the limit; raising it alone does nothing.** On Qwen we
*could* go higher, but **raw K past ~20 likely hurts** a 4B model. The high-value
moves are backend-aware K + a larger snippet budget on Qwen + token-accurate
budgeting (and map-reduce for the genuinely large cases), not a bigger number.

---

## 2. How do we handle date-iterated questions today?

### Current behavior

`AskController.parseDateScope(from:now:)` is a **deterministic, regex-based,
English-only** parser. On a match it returns a `DateScope { interval, label }`
and routing switches to `retrieveByDate`. It recognizes:

- `today`, `yesterday`
- `last / past / previous N days` and `N weeks` (N as a digit or a word:
  "a", "two", "couple", "few", "ten", …)
- `this / last / past / previous week` (→ last 7 days) and `… month` (→ last 30 days)
- a specific **"Month Day"** or **"Day Month"** ("May 26", "26th May"), assuming
  the current year and rolling back a year if that would be in the future

On a date match, retrieval:

- fetches transcripts with `createdAt` in the window, **most-recent-first**,
  `fetchLimit = 15`, then **reverses to chronological** so a summary reads
  oldest → newest;
- **bypasses the semantic scan** (a time query wants *what I recorded then*, not
  *what's nearest in meaning*);
- **bypasses the vague gate** (a date is specific by definition);
- if the window matches **nothing**, answers locally — "You don't have any notes
  from {label}." — with **no model call**.

### Where it falls short

1. **The 15 cap bites hardest here.** "Summarize last week" when the user has
   **40 notes that week** → only the **15 most recent** are summarized; the
   earlier two-thirds are silently dropped, and there's **no "showing 15 of 40"
   signal**. For a week/month summary this is a real, invisible miss.
2. **Topic is ignored inside the window.** "What did I decide about **pricing**
   last week" fetches by date only — the *pricing* semantics are discarded, so
   the answer summarizes everything from the week, not the pricing thread.
   **Combined date + topic questions aren't handled.** (This is exactly what the
   [ask-time-retrieval.md](ask-time-retrieval.md) draft fixes — see below.)
3. **Recency-then-reverse ≠ the whole window.** Because the cap takes the 15
   *newest* and then reverses them, a busy window can **omit its earliest days**
   while still reading "oldest → newest" over the subset shown.
4. **Limited grammar.** Not recognized: ranges ("between May 1 and May 10"), a
   month by name alone ("in May"), a day-of-month alone ("the 5th"), weekdays
   ("last Tuesday"), parts of day ("this morning"), relative-to-now phrasings
   beyond the fixed set ("2 weeks ago"), non-English / locale date formats.
5. **No duration / metadata filters** ("my long notes from yesterday") — these
   exist in the `ask-time-retrieval.md` `RetrievalPlan` sketch but aren't built.

### The drafted fix (already on file)

[ask-time-retrieval.md](ask-time-retrieval.md) proposes a `RetrievalPlan` —
`{ dateInterval, semanticQuery, min/maxDuration, sort, isVague }` — that parses
the date deterministically **and keeps the topic for semantic ranking within the
window**, with explicit sort control (relevance / recency / chronological). That
directly resolves shortfalls #2 and #3. Worth reading alongside this doc.

### Cheaper, independent improvements (don't require the full plan)

- **"Showing N of M" disclosure** when a date window is capped, so the omission
  isn't invisible (small, high-trust win).
- **Map-reduce summary** for large windows (summarize each note, then combine) —
  removes the cap's relevance entirely for "summarize my week/month".
- **Grammar expansion** — ranges, month-by-name, weekdays, "N weeks/months ago".
- **Rank within the window by topic** when the question also carries a topic
  (the minimal slice of the `RetrievalPlan` idea).

---

## 3. Suggested reading order if/when this gets picked up

1. This doc (the why + the levers).
2. [ask-time-retrieval.md](ask-time-retrieval.md) — the date+topic `RetrievalPlan`
   (the main structural fix for §2).
3. [ask-retrieval-architecture.md](ask-retrieval-architecture.md) — the current
   hybrid + RRF retrieval the above sits on top of.
4. [ask-mode.md](ask-mode.md) §7 — the prompt-budget math behind the 15/500/12000
   constants.

No code changes are proposed here. Sizing, if pursued: backend-aware K + snippet
budget = **S**; token-accurate budgeting = **S**; "N of M" disclosure = **XS**;
the full `RetrievalPlan` (date+topic) = **M**; map-reduce summarization = **M**.

---

## ✅ DECIDED ARCHITECTURE (owner, 2026-06-04)

> **Resolve the date with the parser (model as fallback) → use it as a
> `createdAt` filter → run the existing hybrid vector+keyword ranking inside
> that window, ranked by the topic.**

- **Date parsing = both, layered.** Deterministic parser primary (fix its bugs —
  calendar `this/last month`, ranges — and widen its grammar); Apple Intelligence
  is the **fallback** only for phrasings the parser can't handle, run
  greedy/temp-0 with conventions pinned and the window validated.
- **Date is a FILTER, not a separate path.** Today a detected date *bypasses* the
  hybrid ranker (`runPipeline` branches date-only vs vectors-only,
  AskController.swift:243–254). Change to: window → pre-filter candidates by
  `createdAt` → run the existing BM25 + embedding + RRF ranking **inside** the
  window, **ranked by the topic** (add an optional `dateInterval` to
  `retrieveTopK`).
- **Fixes the cap too:** keep the most *relevant* in-window notes (not the 15
  newest) — what "last two weeks" needs; "pricing last week" keeps "pricing".
  Map-reduce only for genuinely large summary windows.
- **Field-level both:** parser owns the **date**, the model can supply the
  **topic** (it extracted "pricing" reliably even when its date math wobbled).

Sizing **M**. Supersedes the either/or date path. Live test snapshot:
`https://jot-date-retrieval.ideaflow.page`.

---

## 4. Empirical test — can Apple Intelligence resolve dates? (local Mac, 2026-06-03)

Validated **locally on macOS 26.4.1** with a standalone `FoundationModels` CLI
(no app / device / TestFlight). Apple Intelligence is reachable from a plain CLI
(`SystemLanguageModel.default.availability == .available`).

### Does Apple FM return a structured/queryable format, or only text?
**Structured.** Apple FM supports **guided generation** — you declare a
`@Generable` Swift struct (with `@Guide` field descriptions) and the framework
does **constrained decoding** so the model fills the typed fields directly
(equivalent to JSON-schema mode). We get back typed `hasDateScope: Bool`,
`startISO: String`, `topic: String`, … with **no text parsing**. That half of
the idea is sound and easy.

### But it is NOT reliable at resolving the date window. Three architectures, N=5 runs each, ground truth computed in Swift, today = 2026-06-03 (Wed):

| Architecture | Strict-case accuracy | Verdict |
|---|---|---|
| **A** — model emits the ISO window directly | **16/25** | OK for absolute dates / "today" / "this month"; **fails relative arithmetic** |
| **B** — model extracts intent (kind+count), Swift computes | **7/25** | Worst — model **mis-classifies** the kind (defaults to "relativeDays", missed absoluteDate/weekday/thisMonth) |
| **C** — model reads off a pre-computed reference calendar | **16/30** | Only **explicitly-labelled named windows** reliable (last week 5/5); relative *selection* still fails |

### The flaws (evidence)
- **Relative-date arithmetic is broken & non-deterministic.** "yesterday" → 3
  different windows across 5 runs incl. **2026-05-02** (wrong month; should be
  06-02). "two weeks ago" → April. "last Tuesday" → 0/5 in A, 2/5 even with the
  calendar. "the last 3 days" → 0/5 even with the calendar.
- **Same phrase, different answer.** Relative phrases produced **2–4 distinct
  windows in 5 runs** (default sampling). A date filter cannot be that flaky.
- **Only two things were reliably correct everywhere:** absolute dates ("May 26"
  → 5/5 in every architecture) and an **explicitly-labelled named window**
  ("Last week: 2026-05-25…2026-05-31" given in the prompt → 5/5). Both need **no
  arithmetic from the model.**
- **Topic over-extraction.** "what did I record today" → topic = the whole
  question; "between May 1 and May 10" → topic "notes". Noisy.
- **Boundary convention inconsistent** (`T23:59:59` vs next-day `T00:00:00`).
- **Latency** ~1s/call (p50 1065ms, max 1796ms) — a full extra second on every
  date question, on top of retrieval + answer generation.

### Conclusion
The current **deterministic regex `parseDateScope` is more reliable** than the
LLM for everything it covers — correct, instant (0 ms), free, and reproducible.
Handing date resolution to Apple FM would **regress** the core cases (yesterday,
last week, last N days) and add ~1s latency. So:

- **Do NOT use the LLM to compute the date window.** Keep deterministic parsing
  as the authority.
- The LLM's real value is **topic extraction for combined date+topic queries**
  (the §2 "topic ignored in window" gap) — that's the `ask-time-retrieval.md`
  `RetrievalPlan` direction — and **expanding the deterministic grammar**
  (ranges, weekdays, "N weeks/months ago", "first few days of") in Swift, where
  it's reliable, rather than via the model.
- **If** LLM date understanding is still wanted, the only mode that worked was
  "pick an explicitly-labelled window." So: Swift pre-computes every candidate
  window (today/yesterday/this-last week/month, each of the last N days by
  weekday) and the model's ONLY job is to **classify which labelled window the
  phrase matches** — never emit or compute a date. Worth a focused probe
  (call it Experiment D), together with **greedy / temperature-0 sampling** to
  kill the non-determinism (not yet tested — default sampling was used here).

Harness: `/tmp/ask-date-probe` (standalone SwiftPM, not in the repo).
