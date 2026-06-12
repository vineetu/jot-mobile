# Correction Review — implementation plan (design handoff → Jot SwiftUI)

Status: DRAFT (autonomous build, owner away until next day). Source design:
`~/Downloads/design_handoff_corrections_review` (README + `corrections/review-data.js`
are source-of-truth for copy + semantics). This plan adapts that handoff to Jot's
codebase **and to the owner's two explicit overrides** (below).

## Owner overrides on the handoff (AUTHORITATIVE — these win over the handoff)

1. **Per-occurrence, never grouped.** The handoff groups a word's occurrences into one
   proposal (`slots: [...]`) and inherits one verdict to all instances. **Rejected.**
   Every occurrence is its own mark, row, and verdict. Picking "term" on occurrence #1
   must NOT change occurrence #2. Rationale (owner): the same surface word can legitimately
   differ by location — "cloud code" may really be *cloud code* in one spot and *claude
   code* in another. Drop the handoff's `×N` grouped mode entirely.
   - **Upside this unlocks:** the handoff's "only edit text when the word occurs exactly
     once" rule existed *because* of grouping. With per-occurrence rows each bound to a
     specific occurrence, we ALWAYS know which instance to edit, so `editsText` is allowed
     for every row regardless of repeat count. (Provided we can resolve a stable occurrence
     identity — see §3.)

2. **Vocabulary ledger UI — deferred.** Do NOT build the Vocabulary-screen ledger now.
   But model the data so corrections are already organized **under their vocab term**
   (CorrectionStore already is: `terms[term] → [Mapping(originalWord→term, confirmations,
   reverts)]`). The future UI shows, under each existing term, the source mishearings that
   map into it ("Jamie"→Jamy, "Je"→Jamy, "name"→Jamy) with scores. It is a *child of the
   term*, not a new top-level feature.

## ⚑ v2 — Decisions from adversarial review (SUPERSEDE conflicting sections below)

Three parallel adversarial reviews (occurrence-identity / semantics / rendering) found the
v1 plan unsound on its core mechanisms. Locked resolutions — these win over §1–§4 below:

**A. Occurrence identity = gate-time ORIGINAL-text offset, not `occurrenceIndex`.**
`occurrenceIndex` is assigned in `output.replacements` ARRIVAL order (not left-to-right;
`VocabularyGate.swift:83-86`) and `proposals` is never re-sorted, so it does NOT equal the
visual nth occurrence. The published-range claim in v1 §1 is false (the gate builds the
published text by concatenation and records no final offset). FIX:
  - In `apply()`, while we still hold the authoritative `range` in `originalTranscript`
    (`:95`), persist per proposal: **`originalStart` (char offset of range.lowerBound in the
    original text) + `originalLength`**. This is the STABLE identity (a real position; two
    "name"s differ; the non-uniform "cloud code" case disambiguates for free).
  - Refactor the reconstruction loop (`:124-142`) so each `Resolved` carries its owning
    proposal id; as text is spliced, record the **published** range back onto the Record as a
    render/edit HINT (not the identity).
  - Render/edit resolution priority: (a) trust `publishedRange` if its substring == expected
    displayed word; (b) else re-anchor by PROXIMITY to `originalStart` mapped through the
    cumulative edit delta (closest candidate of the expected word) — never by nth-count;
    (c) if still ambiguous, drop the mark, keep the row (teach-only).
  - Verdict key = **`(originalWord, term, originalStart)`** — stable across reopen (original
    text is immutable provenance); `occurrenceIndex` is display-only, never a key.
  - Only occurrences the rescorer actually touched have Records (untouched repeats have none);
    copy must be honest that not every visual repeat is individually marked.

**B. Common-word originals NEVER auto-apply. (resolves the per-occurrence ↔ graduation conflict)**
Graduation→auto-apply (`OVERRIDE` in `VocabularyGate.decide:166-169`) silently rewrites ALL
future occurrences — incompatible with "every occurrence is independent" and re-arms the
headline over-correction bug. LOCK:
  - **A mapping whose `original` is a common word (`CommonWords.isCommon`) is NEVER eligible
    for the auto-apply OVERRIDE** — the gate proposes-and-asks per occurrence forever. Remove
    the `isCommon ? 2` arm branch's auto-apply; for common originals the verdict only tunes
    what's PROPOSED/pre-highlighted, never what's silently committed.
  - Auto-apply (OVERRIDE) stays only for **rare/OOV originals** (`net≥1`) and **multi-word
    terms** (already self-gating at `:172-174`). So "Jamie→Jamy" can graduate; "name→Jamy"
    and "cloud code→claude code" never silently rewrite. *(PRODUCT DECISION — owner: confirm.
    Default chosen because it matches your stated rationale; flag if you want graduation for
    common words too.)*

**C. Per-occurrence verdicts ≠ mapping-level learning. Two separate stores.**
v1 wired every occurrence tap to a global `CorrectionStore.confirm/revert/suppressBlock`
(one `net` per pair) — so per-occurrence picks contradict each other and `suppressBlock` of
occurrence #1 hides #2/#3 (and all future transcripts). LOCK:
  - **Per-occurrence resolution store**, keyed `(transcriptID, originalWord, term,
    originalStart)` → `{term | original}`. This HIDES the row + does the THIS-occurrence text
    edit, and is the only thing that decides "already answered, don't re-ask THIS spot."
    Lives in the provenance file (per transcript).
  - **Mapping-level learning** (`CorrectionStore`) is updated as a SEPARATE, deliberate signal,
    NOT a side effect of every tap. A per-occurrence "term"/"original" pick contributes at most
    a single confirmation/revert to the mapping (de-duplicated per transcript-mapping so three
    "name→Jamy" picks ≠ net 3), and for COMMON originals it does NOT arm auto-apply (per B).
  - Drop `suppressBlock` as the per-occurrence hide mechanism; the resolution store hides rows.
    `suppressBlock` (if kept at all) becomes a mapping-level "stop proposing this pair" that the
    user sets deliberately, not via one occurrence.

**D. Displayed score == gate behavior.** Never show "n of 3, not automatic yet" while the gate
already auto-applies. The "AUTOMATIC" label is driven by the gate's REAL arm state for that
mapping (and per B, common originals show "always asks", never "automatic").

**E. Rendering = read-only selectable `UITextView` (extend `InlineEditTextView`).** NOT
`FlowLayout`-of-Buttons (kills `.textSelection`, fragments multi-word underlines, breaks
Dynamic Type/RTL). The UITextView renders `AttributedString` (continuous multi-word underline
spans; solid blue@32% = applied, dashed ink@50% = kept) and uniquely gives `boundingRect`
per word-range for exact marks + tap hit-testing + bubble arrow-at-word-x. Body is **17pt
system sans** (not Fraunces — handoff is stale here). There is **no render-time filler regex**
(it's baked into `transcript.text`), so marks align with `transcript.text` directly.

**F. Layout — the review list lives INSIDE the scroll content (below the body text), not as a
card-external row.** `transcriptCard.frame(maxHeight:.infinity)` (`TranscriptDetailView.swift:199`)
eats the viewport; there is no room below the card. Keep summary-row + accordion inside
`transcriptScrollContent` under the `Text`, as today. Bubble/accordion/flash `@State` must live
ABOVE the `.id(selectedTab)` boundary (else wiped on tab switch). Bubble presents at the ZStack
root (not inside the ScrollView), closes on scroll explicitly, width-clamped (no hardcoded 393).

**G. Reload triggers.** `.task(id: transcript.id)` does NOT refire on a same-id text mutation;
add `.onChange(of: transcript.text)` to re-resolve marks/ranges after any in-detail edit. After
a verdict that edits text, re-resolve ALL marks from scratch (don't maintain incremental
offsets). Flash = time-driven overlay rect over the word frame, NEVER via `.id`-change.

**H. `unsure` keys off confidence near the boundary, not raw block margin.** v1's `margin≥2.4`
clause flags confident-word blocks (conf=1.0) as unsure → over-fires `selectAsks`. Use
`unsure = confidence ∈ [lowConfidence, confidenceCeiling)` (genuine acoustic uncertainty) and
drop the standalone block-margin clause.

**Build-order impact:** the gate refactor (A) + the auto-apply restriction (B) + the
per-occurrence resolution store (C) are the foundation and land BEFORE the UI. The UITextView
marks (E) are the biggest UI chunk. Re-review the IMPLEMENTATION (not just this plan) after the
foundation compiles.

---

## 🛠 Build status (autonomous session — for owner review next day)

**DONE (compiles clean; on-device test pending):**
- **Foundation (gate + provenance):**
  - `VocabularyGate.apply()` now emits per occurrence: stable identity `originalStart`
    (+`originalLength`) and published-text hint `publishedStart`/`publishedLength`; proposals
    are emitted only for spans surviving the overlap guard (no phantom records). `outcome`
    (applied/kept) + `unsure` added.
  - `decide()`: **common-word originals NEVER auto-apply** — they always BLOCK (propose-and-ask);
    auto-apply (OVERRIDE) is reserved for rare/OOV originals (net≥1) + multi-word terms. `unsure`
    keys off MEASURED confidence in [lowConfidence, confidenceCeiling), false when unknown.
    *(This is decision §v2-B — a behavior change to the shipped gate. **Owner: confirm.**)*
  - `CorrectionProvenance`: Record carries the new fields; `Payload{records, verdicts,
    mappingsTaught}`; per-occurrence verdict store (`setVerdict`/`clearVerdict`/`payload`);
    `commit` preserves existing verdicts on re-commit.
- **Transcript-pane UI (increment 1):** new `CorrectionReviewSection` = summary row + accordion;
  pick-the-word chips (original/term, IN TEXT tag); per-occurrence verdicts (hide row); resolved
  consequence + Undo. Replaced the old Yes/No + Right/Wrong list.
- **Text edits: deterministic per-occurrence anchoring** (`currentOffset` = `publishedStart` +
  Σ earlier resolved edits' length deltas; exact-offset span match, proximity only as hand-edit
  fallback). Correct for tightly-spaced repeats and across reopen — fixes the round-2 anchoring bug.
- **Two adversarial review rounds** (plan + implementation); critical findings fixed (offset
  anchoring, common-word auto-apply, unsure over-fire, commit clobber, phantom records).

**DONE — round 2 (marks + bubble + names; compiles clean, device-test pending):**
- **Names are not common words** (owner decision #1): `common-words.txt` regenerated with 306
  popular given names removed (SSA peak-share ≥ 0.005 minus a curated dual-meaning allowlist so
  may/will/mark/rose/grace/april stay protected). Audit: `docs/plans/correction-review-names-excluded.txt`.
  So Jamie/John/Sarah are now learnable/applyable; name/cloud/code/orange/storm stay protected.
- **In-text underline marks + tap bubble** (§v2-E): `MarkedTranscriptText` (read-only selectable
  `UITextView`, solid-blue/dashed underlines, multi-word spans, per-word tap → word rect). Tap a
  mark → `CorrectionBubble` (pick-the-word chips) anchored at the word.
- **Shared `CorrectionReviewModel`** (@Observable, above `.id(selectedTab)` — §v2-F): owns payload
  + verdicts + the deterministic per-occurrence anchoring; drives BOTH the marks/bubble AND the
  accordion. `.onChange(of: transcript.text)` re-resolves after a manual Edit-mode save (§v2-G).
- **One more adversarial review round** (the integration) → fixed: bubble coordinate-space offset
  (window→overlay-local), marks fail-safe (drop, don't nearest-guess, on hand-edit), sizeThatFits
  collapse, onChange re-resolve.

**DONE — round 3 (learning loop + device-tuning; compiles clean, device-test pending):**
- **Mapping-level learning, reversible** (owner: "ok if they auto-apply, user can change via the
  2 ways"): a per-occurrence "term" pick reinforces the mapping, a reverted applied one demotes
  it. One transcript contributes at most ±1 per mapping (recomputed from all its verdicts in
  `CorrectionProvenance.desiredContribution`; mixed = 0), fully reversible via `MappingDelta` +
  `CorrectionStore.adjust(by:)`. Gate now **suppresses a demoted mapping** (`net ≤ −1 → BLOCK`,
  common AND rare — so a reverted auto-correction stays undone) and OVERRIDE-applies a confirmed
  rare one; **common words still never auto-apply**. Honest resolved copy ("…Jot keeps fixing
  this" / "…Jot will stop changing it"). Adversarial-reviewed: net math proven sound + reversible;
  fixed the stale-`payload` undo race (reload from the actor at the start of pick/undo).
- **Device-tuning (background agent, docs-verified via context7):** bubble dismisses on scroll
  (`onScrollGeometryChange`, iOS 18+); tap-catcher inset ~110pt so it no longer eats action-bar
  taps; window→overlay coordinate mapping confirmed correct against Apple docs.

**KNOWN MINOR (not blocking):** orphaned provenance JSON on transcript delete (`discard` is
unwired — tiny disk, sweep candidate; learning intentionally PERSISTS past deletion). Verify
swipe-back + text-selection coexist with the UITextView body on-device.

**DEFERRED — next loops:**
- **Keyboard surface** (Phase 2): App-Group exposure of `selectAsks` + the 10s nudge + inline
  quick-review + verdict write-back/reconcile. (Owner: "do keyboard surface later.")
- **Vocabulary ledger UI** (under each term): the persistent "what Jot's learned" list with the
  real per-mapping state (AUTOMATIC / learning / Stopped). Data is already there
  (`CorrectionStore` net per mapping); just the Settings UI. Owner deferred.

**Owner decisions — RESOLVED:**
1. §v2-B common-word originals never auto-apply — CONFIRMED ("common words never ought to apply").
2. Names are NOT common words — DONE (306 names excluded from the guard).
3. Auto-apply for confirmed/name mappings is OK; the two correction surfaces are the safety net
   (revert demotes) — CONFIRMED; learning loop wired.

## Scope / phasing
- **Phase 1 (now): transcript pane.** Marks + summary row + accordion review list + word
  bubble + pick-the-word chips + resolved states + learning dots + text-flash. Replaces the
  current `CorrectionReviewSection` (the Yes/No + Right/Wrong list) entirely.
- **Phase 2 (after): keyboard.** 10 s post-dictation nudge in the recents strip + inline
  one-at-a-time quick review (≤3 asks). Needs App-Group exposure of proposals (the keyboard
  can't read the app-local provenance). Bigger plumbing — second.
- **Deferred:** Vocabulary ledger UI.

## Locked design decisions (from handoff, kept)
- **Verdict = pick-the-word.** Two chips = the two words (`original` / `term`); the one
  currently in the text carries an `IN TEXT` caps tag. No Yes/No, no Right/Wrong. The system
  derives confirm/reject from `outcome × choice`.
- **Placement = marks + summary row.** Underline marks on gated words (solid blue = CHANGED/
  applied; dashed = KEPT). Below the transcript card, ONE collapsed summary row ("Jot guessed
  on N words.") that expands accordion-style into the full list. No always-expanded section,
  no bottom sheet.
- **Clean transcript (0 proposals) renders nothing** — no marks, no summary row.
- **Blue only — NO coral.** This is not an AI-Rewrite surface; keep it visually distinct from
  the rewrite/cleanedText tab. (Owner is sensitive to conflating the two.)
- Copy strings = `resolvedCopy()` / `rowNote()` in `review-data.js` (sentence case, no `!`,
  em-dashes, no emoji).

## Current code we build on / replace
- `VocabularyGate.apply(...)` → produces per-replacement decisions; already resolves the
  nth-occurrence range against the ORIGINAL transcript and reconstructs positionally.
- `CorrectionProvenance` (actor) → per-transcript side-JSON of proposals, keyed by
  transcript id. `Record { originalWord, term, decision, confidence, margin, occurrenceIndex }`.
  Commit/load proven working on device.
- `CorrectionStore` (actor) → `terms[term] → [Mapping]` with confirmations/reverts/net;
  `suppressedBlocks`. Already the "corrections under a term" shape.
- `CorrectionReviewSection` (SwiftUI) → CURRENT list UI; **to be replaced** by marks +
  summary + accordion + bubble.
- `TranscriptDetailView` → mounts the section in the Original-tab scroll content; renders
  `Text(transcript.text)`. Marks require rendering the body as styled runs, not a plain Text.

## §1 — Data model changes (provenance Record)
Map handoff fields onto our Record, per-occurrence:
- `outcome: "applied" | "kept"` ← derive from `decision` (APPLY/OVERRIDE → applied; BLOCK →
  kept). Store explicitly to avoid re-deriving.
- `original`, `term` ← already present.
- `occurrenceIndex` ← already present (nth whole-word occ of `original` in the ORIGINAL text).
- `unsure: Bool` ← NEW. Low-margin gate decision. Threshold TBD in §6; compute at gate time.
- `range` (character offsets in the PUBLISHED text) ← NEW, STRONGLY CONSIDERED. The gate
  already computes the applied range; persist the final-text range so marks + per-occurrence
  edits target an exact span, with re-validation on render (if the substring no longer equals
  the expected displayed word — e.g. user hand-edited — drop that mark gracefully). See §3.
- `prior` is NOT stored on the Record — it's read live from `CorrectionStore` at render
  (confirmations from earlier transcripts), so it stays current as other transcripts teach.

Verdict storage (per occurrence): extend provenance or add a sibling. Key =
`proposalId + occurrenceIndex` (handoff uses `proposalId(:instanceIndex)`). Persist with the
transcript (provenance file already is). Resolved rows never re-ask.

## §2 — Verdict semantics (per-occurrence)
verdict ∈ { term, original }. Polarity table (handoff `editsText`/`resolvedCopy`, adapted —
NO single-occurrence restriction because rows are per-occurrence):

| outcome | picked   | learning effect          | text effect (this occurrence) |
|---------|----------|--------------------------|-------------------------------|
| applied | term     | +1 confirmation (mapping)| none (already term)           |
| applied | original | revert mapping (this pair)| revert THIS occurrence → original |
| kept    | term     | +1 confirmation (mapping)| apply THIS occurrence → term  |
| kept    | original | suppress (stop asking)   | none                          |

- Learning is at the MAPPING level (CorrectionStore `confirm`/`revert`/`suppressBlock` —
  already implemented). A per-occurrence "term" pick = `confirm(original, term)`; "original"
  on an applied = `revert`; "original" on a kept = `suppressBlock`.
- **Graduation tension (flag for owner / ties to deferred ledger):** handoff graduates a
  mapping to AUTOMATIC at 3 confirmations. But per-occurrence checking exists precisely
  because auto-applying everywhere can be wrong. Proposal: graduation still arms the gate's
  override (auto-apply on FUTURE dictations) but every future occurrence remains individually
  reversible in its transcript. Reconcile the threshold: handoff=3 flat; current gate arms at
  net≥2 (common) / net≥1 (rare). LEAN: adopt flat 3 for "AUTOMATIC" *labeling*, keep the
  gate's safety (common needs ≥2 to even start applying). Revisit with the ledger.

## §3 — The hard problem: stable occurrence identity
Marks + per-occurrence edits need to point at a specific span across three text states:
ORIGINAL (gate time) → PUBLISHED (saved) → USER-EDITED (later). Plan:
- Gate persists, per proposal, the **range in the PUBLISHED text** (it already reconstructs
  positionally, so it can emit final offsets). For `kept`, the span is the original word; for
  `applied`, it's the term.
- On render, the view re-validates each range: the substring at `[range]` must equal the
  expected displayed word (term if applied & unresolved, etc.). If it matches → draw the mark
  / use it as the edit target. If it doesn't (user edited the text, or a prior verdict shifted
  offsets) → re-resolve by (displayedWord, occurrenceIndex) as a fallback; if still ambiguous,
  drop the mark but keep the row (row can still teach the mapping without a text edit).
- A verdict that edits THIS occurrence must update sibling proposals' ranges (offset shift).
  Simplest robust approach: after any text edit, re-resolve all marks from scratch
  (displayedWord + occurrenceIndex recomputed) rather than maintaining offsets incrementally.
- Adversarial review must stress this (overlapping spans, repeated words, multi-word terms
  like "claude code", punctuation-attached, user edits mid-review).

## §4 — Rendering the marks (SwiftUI)
`Text(transcript.text)` → must become a composed run of styled substrings so gated spans get
underlines + tap targets. Options:
- (a) `AttributedString` with custom underline + a custom attribute carrying the proposalId;
  tap handling via an overlaid transparent hit-test layer (Text doesn't give per-run taps
  pre-iOS17 reliably). 
- (b) Build the body as a wrapped `FlowLayout`/`WrappingHStack` of word-views, each gated
  word a tappable `Button`. Most control over taps + the bubble anchor (handoff wants an
  arrow bubble at the word's x). Heavier.
- LEAN: (b) for the gated-word tappability + bubble anchoring, but only if perf on long
  transcripts is acceptable; else (a) + overlay. Prototype both in a throwaway first.
- Marks: applied → `border-bottom 1.5px solid blue@32%`; kept → `1.5px dashed ink@50%`.
  Disappear on resolution. (Tokens in §7.)

## §5 — The surfaces (transcript pane)
- **Summary row** (always when proposals exist, even all-resolved): card surface r22,
  hairline; title "Jot guessed on N words." (SF 15.5/600), sub "Tap an underlined word — or
  review them all here." (12.5 ink-sub), trailing chevron rotates 90° on expand. All-resolved
  → blue check + "All reviewed".
- **Accordion review list**: header + sub "Tap the word you meant — a few answers and Jot
  fixes these on its own." Rows: caps badge `CHANGED`/`KEPT`; note `rowNote(p)`; two chips
  (original first, in-text tagged `IN TEXT`); resolved → blue check + `resolvedCopy` line +
  learning dots ("n of 3") + Undo. >5 rows → cap at 4 + "Show N more".
- **Word bubble** (tap a mark): card w272 r18, arrow at word x; badge + note + two chips;
  after pick → resolved line, auto-dismiss 1.3 s; backdrop/scroll closes.
- **Text-mutation flash**: blue wash over the edited word fading 1.5 s.
- **Undo**: restores unresolved row + reverts any text edit (with flash). Calls the inverse
  CorrectionStore op.

## §6 — `unsure` threshold
Gate decision is `unsure` when its margin is within a small band of the decision boundary
(low confidence in the verdict). Define from `confidence`/`margin` already computed in
`VocabularyGate.decide`. Start: `unsure = (decision == BLOCK && margin >= earnedMargin*0.6)
|| (confidence between lowConfidence and confidenceCeiling)`. Calibrate; log it. Only used to
prioritize keyboard asks (Phase 2) + a subtle row hint.

## §7 — Tokens (from `tokens/SWIFT_MAPPING.md` → JotDesign.*)
brand blue #1A8CFF (+grad #0064CC), blue-soft rgba(26,140,255,.20), blue-border
rgba(26,140,255,.32); card surfaces (78–90% white light / 6% white dark) + 0.5px hairline;
radii 999/28/22/20/18/16/12; ease cubic-bezier(0.45,0.02,0.2,1). Fraunces italic = spoken
context (keyboard). NO coral. Verify each against `JotDesign.swift` before use.

## §8 — Phase 2 (keyboard) — sketch only (build after Phase 1 lands)
- Expose the per-transcript proposals + `selectAsks` (≤3: unresolved AND (prior>0 OR unsure),
  sorted prior desc) to the keyboard via the **App Group** (provenance is app-local today).
  Likely a small App-Group JSON the app writes alongside the history mirror, OR extend the
  `ClipboardHandoff` post-dictation payload with the asks for the just-finished dictation.
- Recents-strip stage machine: `nudge(10s) → review → done(2.2s) → idle`; dismiss → idle;
  next dictation clears. Inline one-at-a-time review with Fraunces-italic context snippet.
- Keyboard writes verdicts back to the App Group; app reconciles into CorrectionStore +
  provenance. Define the write path + reconcile carefully (cross-process, §schema discipline).

## §9 — Build order (Phase 1)
1. Provenance Record: add `outcome`, `unsure`, published-text `range`; commit them from the
   gate. Verdict store keyed per-occurrence. (Migrate/replace the throwaway diagnostics.)
2. Throwaway: prototype marks rendering (a vs b) on a long transcript; pick approach.
3. Build summary row + accordion list (pick-the-word chips, resolved states, dots, Undo)
   against live provenance + CorrectionStore.
4. Build word marks + bubble; wire taps; text-edit + flash; range re-validation (§3).
5. Remove old `CorrectionReviewSection` Yes/No UI + the 3 diagnostics.
6. Compile; adversarial review (subagents) on §3 identity + §2 polarity + perf; iterate.
7. On-device verify checklist for owner (next day).

## §10 — Open questions parked for owner (don't block; pick sane default + flag)
- Graduation threshold reconcile (§2) — defaulting to "label AUTOMATIC at 3, gate safety
  unchanged".
- Marks rendering approach (§4) — defaulting to whichever prototypes cleaner.
- Whether the summary row shows when ALL resolved (handoff: yes, "All reviewed") — keeping.

## §11 — 2026-06-12: anchor system rework + gate plausibility + merged-word alias

Owner-reported bugs: (a) verdict edits "firing on wrong word" after hand-edits; (b)
"Vikram Sriram" → "Sriram Shriram" (bogus cross-word replacement; right one blocked);
(c) "Ramaa Nathan" (multi-word term) heard as merged "Ramanathan" → replaced by the
SHORTER term "Ramaa" because FluidAudio only tries multi-word forms against multi-word
ASR spans (the right term never competed).

Three changes (all compiled, adversarially reviewed ×2 — initial review found 1 CRITICAL
+ 1 MAJOR, both fixed and re-verified):

1. **Live anchors + reconcile (fixes a — root cause was DEEPER than hand-edits).**
   `Record.publishedStart` is now a LIVE anchor. The payload stores `anchoredText` (the
   text anchors are valid for — seeded with the GATE-OUTPUT text captured at
   `record(_:gatedText:)`; critically NOT the saved text: the post-gate transform chain
   (segmenter/filler/number/AI-cleanup) shifts offsets, so anchors were stale FROM BIRTH
   and the old nearest-match fallback was routinely resolving — sometimes onto the wrong
   occurrence. That fallback is DELETED; resolution is strict-only everywhere (exact
   offset or fail safe). `reconciledPayload(transcriptID:currentText:)` maps anchors
   between texts with an EXACT multi-region diff (`CollectionDifference` patch-offset
   mapping in `mapOffsets`) — state-based (fingerprint), so any edit is absorbed exactly
   once no matter which surface made it. Self (verdict) edits don't trust the diff at
   all: a replacement sharing a suffix with the replaced word ("nathan"→"Ramanathan")
   makes any diff ambiguous, so `editText` reports its exact span via `noteSelfEdit`
   (race-tolerant against the onChange reconcile). `CorrectionAsksPublisher` reads
   reconciled-to-publishedText so keyboard snippets slice the right offsets.

2. **Gate plausibility guard (fixes b-class).** New guard (1) in `decide()` after the
   learned-override early-out, BEFORE multi-word self-gating (closing that bypass): the
   heard word's letter-skeleton (lowercased alphanumerics, spaces dropped) must be within
   0.45 normalized Levenshtein of the term or ANY of its aliases (aliases plumbed from
   the holder via `termAliases`). shriram→sriram 0.14 / cloud→claude 0.33 / jamie→jamy
   0.40 pass; vikram→sriram 0.50 / ramanathan→ramaa 0.50 / name→jamy 0.50 block. A block
   still emits a reviewable "kept" row; confirming it teaches the net≥1 override which
   bypasses the guard (so je→Jamy-style learned pairs survive).

3. **Merged-word auto-alias (fixes c).** `VocabularyRescorerHolder.enrichedAliases`
   appends each multi-word term's space-stripped form as an alias at FEED time only
   (user's vocabulary.txt untouched). "RamaaNathan" → normalized "ramaanathan" matches
   any merged ASR rendering at ~0.9 similarity and outranks "Ramaa"'s 0.50 at equal span
   length. Layer-1 user workaround (works today): add the merged form as a "sounds like"
   alias in Settings → Vocabulary.

Accepted risks (reviewed, deliberate): user listing BOTH "Ramaa Nathan" and "Ramaanathan"
as separate terms → merged-alias collision; digit-form terms ("iPhone 17 Pro" heard
"seventeen") in the 0.45–0.5 band blocked until confirmed once; multi-disjoint hand-edit
in one Save → anchors between regions fail safe (mark dropped, verdict still learns).

Open (not yet verified): why "Vikram"→"Sriram" fired at all (similarity ≈0.50 is below
the matcher's 0.52 floor by our reading) — owner to pull Diagnostics → VOCAB for that
session; the plausibility guard blocks the class regardless.

### §11 addendum (same day)
- Re-review verified all three fixes (mapOffsets executed empirically against adversarial
  cases — all passed) and found ONE new MINOR: the asks publisher persisting
  anchoredText=publishedText routed the durable anchor chain through the AI-cleaned text,
  stranding records whose words cleanup rewrote away. Fixed: publisher now uses
  `mappedPayload(into:)` — an EPHEMERAL mapping for snippet slicing; the durable chain
  stays gate-output → transcript.text. Debug + Release compile clean.
- NEW FEATURE (owner request, same batch): **selection-menu "Add to Vocabulary"** in the
  transcript pane. `MarkedTranscriptText.Coordinator` is now the UITextView delegate and
  appends an "Add to Vocabulary" action to the system selection menu
  (`textView(_:editMenuForTextIn:suggestedActions:)`), shown only when the selection
  sanitizes to a plausible term (≤4 words, ≤60 chars, has letters; edge punctuation
  trimmed) and isn't already a term. Tap → `VocabularyStore.addTerm` (dedup,
  case-insensitive) → success haptic + the same blue flash a verdict edit gets
  (`CorrectionReviewModel.flashSpan`). Original tab only (the Rewrite tab's SwiftUI Text
  has no custom menu — fine: vocabulary is about the spoken original). features.md §8
  entry owed at feature-complete per owner's docs rule. NOTE found during this work:
  features.md §8.4 says the mobile Vocabulary UI has NO aliases field — the file format +
  rescorer support aliases but users can't enter them on mobile; the auto merged-form
  alias (§11.3) is currently the only alias producer. The parked hand-edit→vocab design
  (Cases A/B/C: silent correction-learning on edit-matches-term, "Add X?" chip for
  name-like OOV edits, silence otherwise) remains parked — this selection menu is the
  explicit-action complement, not a replacement.

## §12 — PARKED: Vocabulary-section overhaul (owner deferred 2026-06-12)

One future work package, owner-confirmed scope-later. Pieces:
1. **Correct-and-add from selection** (owner-described, understood + confirmed): select a
   WRONG word in the transcript (one the correction system has no term for → no underline)
   → action opens the selected text EDITABLE (likely collapse with today's "Add to
   Vocabulary" into one prefilled-sheet flow) → on confirm: fix that text, add the
   corrected form as a term, and LEARN the heard→meant pairing (CorrectionStore mapping
   and/or term alias — also fills the no-aliases-field-on-mobile gap, features.md §8.4).
   Open sub-decisions: one menu action vs two; fix selected occurrence only vs all in
   transcript.
2. **Vocabulary ledger UI** — "what Jot's learned" (mappings + AUTOMATIC/learning/stopped)
   under each term in Settings → Vocabulary; data already in CorrectionStore.
3. **Hand-edit → vocab Cases A/B/C** (earlier brainstorm): silent learning when an edit
   matches a term; "Add X?" chip for name-like OOV edits; silence otherwise.
4. Aliases surfacing on mobile (no UI today; only the auto merged-form alias exists).

Until then the shipped 118 behavior stands: selection-menu add of the (correct) selected
text only.

### §12 correction (owner clarified same day): item 1 is NOT parked — BUILT
Owner: "the vocabulary SECTION we will talk about later. Right now I want to add a word."
The selection→prompt flow shipped as the v2 of the selection-menu add (not yet deployed):
select ANY 1–4 word run / acronym in the transcript body (no underline needed — this is
exactly for words the gate has no term for) → "Add to Vocabulary" → ALERT with the
selection prefilled: "Heard “X”. Type the word Jot should write — or Add as-is." On Add:
(1) the selected span is replaced with the typed word (defensive range+substring check;
other records' anchors shift via the reconcile diff like any hand-edit; blue flash);
(2) COMMON-WORD FILTER: if every word of the typed replacement is a common word → no
vocab entry (that's the "what is this?" test — ordinary rewording isn't vocabulary);
(3) otherwise `VocabularyStore.addTerm(replacement, heardAs: selection)` — term added
(dedup; merging into an existing term just adds the alias), the mis-heard form attached
as a "sounds like" alias (feeds the rescorer matcher — the ONLY user path that writes an
alias on mobile), and `CorrectionStore.adjust(+1)` teaches the mapping so the gate's
net≥1 override can auto-apply next dictation. Items 2–4 of §12 (ledger UI, hand-edit
chips, alias UI) remain the deferred overhaul.

INCIDENT note 2026-06-12: repo-root files (Vendor/ 710 files, README, build.sh, dev.sh,
marketing/, prototypes/, EXPERIMENTS.md) were found deleted from the working tree
(NOT by the agent); Vendor/ is the load-bearing local MLX package → restored via
`git restore Vendor` only; the other 36 deletions left untouched pending owner intent.

## §13 — 2026-06-12 (same day, build 119): R3 fixes + Voice Prompt rewrite option

**R3 adversarial review of the "what should this say?" prompt flow** found 4 MAJORs, all
fixed: (1) sanitized-candidate-vs-raw-range mismatch made the text fix silently no-op on
any selection with edge punctuation → menu now passes the SAME trimmed (substring, range)
pair (`trimmedSelection`); (2)+(3) typed terms/aliases carrying ":" "," or leading "#"
corrupted the vocab simple format → sanitized at the `addTerm` choke point (`fileSafe`);
addTerm now returns the CANONICAL stored term and the CorrectionStore mapping is keyed on
it; (4) haptic restructured (fires on fix OR learn). NOTE: Settings rows' free-text term
editing still bypasses fileSafe — tracked with the §12 overhaul.

**Voice Prompt (owner request, scoped→built→reviewed→fixed same day):** 2nd row in the
Articulate picker — "Voice prompt / Say what to change." Tap → recording starts
immediately (`RECORDING START FROM: RewritePickerSheet (voice prompt)`), pulsing dot +
live partial + Stop/X; Stop → transcribe → dictation wrapped in a bundled-style system
prompt → existing `startRewrite` via an ephemeral never-persisted SavedPrompt; empty →
"Didn't catch that — try again." Implementation: `VoicePromptCapture` replicates
InlineDictationSession's 4 lifecycle invariants against raw RecordingService/
TranscriptionService (the TYPE stays Ask-exclusive). Adversarial review (FIX-FIRST):
(a) capture must CLAIM `ownsActiveRecording` — without it a keyboard mic-tap from another
app saved+pasted the spoken instruction, retries polluted the warm-hold nudge ring, and
the return pill could flash; the flag is the GENERIC in-app ownership signal (ARCHITECTURE
:62 rewritten — two sanctioned claimants); (b) interruption-publish (call/Siri mid-capture
→ saved transcript + clipboard) now GATED on the ownership flag in `internalStop`
(snapshot-then-guard) — intentionally also closes the identical pre-existing Ask hole;
unowned dictations keep delivery byte-for-byte. Polish: StreamingPartial.reset() on
terminals, interactiveDismissDisabled while transcribing, features.md §7.13 + backlinks.

**On-device verify list for 119:** voice prompt happy path; interrupted capture (incoming
call mid-Listening) must end "Didn't catch that" with NO new transcript in Recents; vocab
add with trailing-punctuation selection now actually fixes the text; term with ":" stored
sanitized.
