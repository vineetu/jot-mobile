# Ask — hybrid time/metadata-aware retrieval (design)

Status: **DRAFT for review** · Depends on: `docs/plans/ask-mode.md`

## Problem

Ask retrieval today (`AskController.retrieveTopK`) is pure semantic top-K cosine
over MiniLM embeddings. It has **zero concept of time or metadata**, so the most
natural Ask questions fail:

- *"What were the main ideas from the last two days?"* → "last two days" ignored.
- *"What did I speak on May 26th?"* → the date is embedded as a fuzzy concept, not a filter.
- *"What have I been thinking about lately?"* → vague query → near-arbitrary 15 notes → rambly answer.

The good, "standard" questions the user wants are almost all **time-scoped**, which
is precisely what semantic-only retrieval can't honor.

## Decision (confirmed with user)

- Retrieval approach: **Both** — parse dates/ranges deterministically (reliable),
  let **Qwen** add the fuzzy metadata/topic constraints on top.
- Vague questions: **answer anyway**, but when we detect the question is vague,
  show a small note under the answer nudging the user to ask something specific.

## Architecture

Three stages. Stage 2 (answer synthesis) is unchanged from today.

### Stage 0 — query understanding → `RetrievalPlan`

```
struct RetrievalPlan {
    var dateInterval: DateInterval?     // deterministic, authoritative
    var semanticQuery: String?          // topic to rank by (nil = no topic)
    var minDurationSeconds: Double?
    var maxDurationSeconds: Double?
    var sort: Sort                      // .relevance | .recency | .chronological
    var isVague: Bool
}
```

**(a) Deterministic date extraction (Swift, no model).** Runs first, always.
- Relative: `today`, `yesterday`, `last N days/weeks`, `this/last/past week`, `this month`.
- Absolute: `May 26`, `May 26th`, `on the 26th`, `26 May`, ISO `2026-05-26`.
- Resolve against "now" (real device clock — fine in-app).
- Mechanism: `NSDataDetector` for absolute dates + a small hand-rolled regex set
  for relative ranges (`NSDataDetector` is unreliable for "last two days").

**(b) Qwen structured filter (only when Qwen weights present).** Qwen reads the
raw question and emits the rest of the plan as constrained JSON (topic,
duration bounds, sort, isVague). **Deterministic dates win** on any conflict with
Qwen's date guesses. Use structured output (vendored `mlx-swift-structured` /
`JSONSchema`) so the JSON is always valid; confirm `Qwen35Client` exposes a
JSON-constrained path or add one.

> If the chosen *answer* backend is Apple Intelligence, prefer running Stage 0(b)
> on Apple FM too, to avoid loading two models. Open question #2.

### Stage 1 — candidate selection (SwiftData + embeddings)

| date? | topic? | behavior |
|-------|--------|----------|
| yes   | yes    | fetch transcripts in `dateInterval` → rank by cosine to topic |
| yes   | no     | fetch transcripts in `dateInterval` → sort recency/chronological |
| no    | yes    | current semantic top-K (today's behavior) |
| no    | no     | semantic top-K + mark **vague** |

- Date fetch: `FetchDescriptor<Transcript>` predicate on `createdAt` in range.
- Duration filter (`durationSeconds`) applied as a post-fetch predicate.
- Always cap the candidate set to the existing `userTurnCharLimit` budget
  (drop lowest-ranked first), and **log** when we truncate (no silent caps).

### Stage 2 — answer (unchanged)

Existing prompt + cite-by-index + backend per the Settings toggle.

## Vague handling

- Always attempt an answer.
- Vagueness signal: Qwen's `isVague` when available; else heuristic — no date AND
  weak semantic peak (top cosine below a floor / flat distribution among top-K).
- When vague: render a small caption beneath the answer, e.g.
  *"Broad question — naming a topic or a time frame (\"last two days\", \"May 26\") gives a sharper answer."*

## Example pills (updated, replace the vague ones)

- "What were the main ideas from the last two days?"
- "What did I talk about yesterday?"
- "Summarize my notes about <topic>."

## Schema impact

**None.** `createdAt`, `durationSeconds`, `source` all exist in `JotSchemaV6`.
No new fields, no new entity, no `MigrationStage`.

## Open questions (for review)

1. **Default Ask backend.** Ask now only appears once Qwen is downloaded, and the
   user finds Apple Intelligence answers weak. Should the *default* answer backend
   flip to **Qwen** (better quality, guaranteed present)? Recommendation: yes.
2. **Which model runs Stage 0(b)?** Same as the answer backend (avoid loading two
   models), or always Qwen? Recommendation: same as answer backend.
3. **Latency.** Two model calls (understanding + answer). Skip Stage 0(b) when the
   deterministic date parse fully scopes the query and there's no topic word?
4. **Date precedence** confirmed: deterministic > Qwen. OK?
5. **features.md.** Add the Ask section after this lands so the doc captures the
   finished shape (entry-point gating on Qwen download, backend toggle, citations,
   time-aware retrieval) in one pass.
