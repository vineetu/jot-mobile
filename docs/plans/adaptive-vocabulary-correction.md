# Plan: Adaptive Vocabulary & Correction (v1)

Status: **DESIGN — not implemented.** Empirically validated on real on-device data
via a throwaway probe (see §10 Evidence). UX designed here for v1. Owner stepped
away and asked me to figure out the correction-learning UX; open decisions for the
owner are collected in §9.

---

## 0b. Session findings incorporated (2026-06-08)

A working session re-grounded this plan in the **actual shipped FluidAudio code**, in
**published expert practice** (three sourced research passes), and in a **new probe test**.
Material corrections folded into the sections below:

- **The rescorer is NOT ungated — the gate exists and is *handicapped*.** `VocabularyRescorer`
  already does the expert-standard "compare-against-original" move
  (`VocabularyRescorer+TokenEvaluation.swift:88`: `shouldReplace = boostedVocabScore >
  originalCtcScore`) — it scores both the vocab term and the original word on the same audio.
  This is exactly NeMo CTC-WS's design. **Two things defeat it:** (a) a hardcoded **`+3.0`
  additive boost** (`ContextBiasingConstants.defaultCbw = 3.0`) added to the term before the
  comparison, so the original word must win by **>3.0 log-prob** just to survive; (b) the only
  content guard is a **~150-word grammar stopword list** ("a/the/is/my") — content words like
  **"name", "cloud", "code" are absent**, so they get zero protection. Jot's own layer
  (`VocabularyRescorerHolder.rescore`) then returns FluidAudio's output **verbatim** with no
  gate of its own. → §3.1/§3.2 reframed; the v1 fix now explicitly **turns the `+3.0` boost
  down** (the NeMo `cbw`/`ctc_w` lever) in addition to the post-filter.
- **Per-term *phonetic collision sets* were tested and FAIL for the core bug.** The user's idea
  ("when 'Jamy' is added, compute which common words it collides with") was built with the real
  expert recipe (CMUdict + panphon feature-edit-distance + frequency filter) and measured: **"name"
  sits at rank #6,053 of ~12,900** in Jamy's phonetic-neighbor ranking. Catching it needs a
  threshold (0.40) that sweeps in **9,574 words — two-thirds of common English**. Reason: "name"
  /neɪm/ and "Jamy" /dʒeɪmi/ share only the rime; the **model confused them for acoustic reasons,
  not phonetic ones** — confirming the expert consensus that *abstract phonetics is a weak proxy
  for a recognizer's real confusions.* → the common-word guard stays **frequency-based** (universal,
  no per-term computation, no hardcoded list — answers the owner's "must work for everyone"
  requirement). Phonetics is **demoted** to flagging *genuine* homophones (cloud↔claude = 0.19, which
  the same test caught cleanly) for suggest-mode only. See §10.
- **The hard floor is citable.** True homophones (identical pronunciation) **cannot** be separated
  by acoustics or phonetics — only lexical context (an LM) resolves them (EMNLP-2023 context-mixing;
  Aalto speech-recognition text). Confirms the §3.4 "suggest, don't auto-fix" tail and the no-LLM
  scoping (that class is left to review, not auto-corrected).
- **The v2 acoustic layer has a concrete, literature-backed recipe** (replaces §3.3's generic
  sketch): passively harvest the user's *own* high-confidence common-word utterances as exemplars
  (same-speaker = the easy regime), use **AWE/DTW + per-speaker mean-centering (CMVN) + cohort/
  S-norm + 5–10-exemplar prototypes**, and treat the score as a **calibrated prior fused with
  context, never a standalone decider**. This is why naive mean-pool cosine failed in the original
  probe (anisotropy) — the recipe, not the idea, was missing.

---

## 0c. Adversarial review round 2 — incorporated (2026-06-08)

Three independent reviewers (ASR/ML, architecture, product/UX) stress-tested this against the
real code. Resolutions (kept where verified, narrowed where overclaimed):

**CRITICALs (design-changing, all accepted):**
- **[C1 — drop "lower cbw" as a core lever].** The validated probe ran at **cbw = 3.0**
  (`main.swift:405`, no cbw arg). Lowering cbw is *unvalidated* and **fights the gate**:
  `replacementScore = vocabCtcScore + cbw`, so the margin the post-filter thresholds *contains*
  cbw — lowering cbw to 1.0 would drop the validated "Jamie→Jamy margin 3.5" below τ_margin≈3.0
  and break the proof. Lowering cbw also cuts recall *upstream* (a candidate that fails
  `boosted > original` is never emitted into `replacements`, so the post-filter can't see it).
  **Resolution:** v1 keeps cbw at the validated default; the **frequency post-filter does the
  work**. Define the gate margin on the **un-boosted acoustic score** (`vocabCtcScore −
  originalCtcScore`) so it's independent of the cbw knob, and **re-derive τ on the final score
  definition in the calibration pass** (don't ship the raw single-speaker numbers as settled).
  §3.1/§3.2/§8 corrected. cbw becomes a *secondary calibration knob*, not a headline fix.
- **[C2 — v1 is TEXT-ONLY; audio capture defers to v2].** Jot **never persists recording audio**
  — the `[Float]` buffer is drained in `RecordingService.stop()`, passed in-memory to `rescore`,
  and **discarded**; there is no audio file on disk and no audio field on the `Transcript` model.
  So Path B's audio snippet and **all of §6's "N clips held / clear-all / retention" lifecycle
  are a NEW subsystem**, not a bolt-on — and its *only* other consumer (the §3.3 acoustic
  fingerprint) is already v2. **Resolution:** v1 Review is **text-only (no playback, no held
  audio)**; the clip-capture pipeline + §6 lifecycle move to **v2 alongside the acoustic layer.**
  This removes the largest scoping miss and the "creepy retained-audio" risk from v1 entirely.
- **[C3 — narrow "revert" to a detectable signal].** §5d's "user undoes our correction in a
  *later* transcript" is **undetectable** in v1: correction→transcript provenance is deferred
  (§4) and `corrections.json` has no back-link to where a fix was applied. **Resolution:** v1's
  revert signal = a **Path-A edit that changes a word back to a known `wrongText` of an existing
  entry** (detectable from the edit diff + the store alone). The cross-transcript revert needs the
  deferred provenance and is **v2**. §5d/§1-invariant-5 reworded.
- **[C4 — probationary state: learn ≠ auto-apply].** Path A auto-adding an `active` term means it
  boosts **all future audio**; the undo toast only guards the *current* transcript, so a one-off
  bad edit silently corrupts transcript #7. **Resolution:** a learned entry is stored immediately
  (captures the gold) but starts **probationary** — it *suggests* in review but does **not
  auto-fire** until a first confirmation (review 👍 or a confirmed recurrence) promotes it to
  `active`. Keeps Path A zero-friction while making Invariant 2 actually hold. §5a/§5d updated.

**HIGHs (accepted):**
- **[H-freq — common-word guard is a STRONG PRIOR, not an absolute veto].** A hard frequency veto
  kills recall on **names that *are* common words** (Bill, Mark, Rose, Grace, Will). Resolution:
  a common base word raises the bar (needs low base-conf **and** a large boosted margin; §0d-C1) rather
  than being un-correctable; and v1 explicitly **scopes single-word name-is-a-common-word targets
  to the suggest/review tail** (§3.4), not silent auto-correct. ("name"→"Jamy" at 0.998 conf is
  still blocked — it fails both conditions.)
- **[H-relconf — confidence gate is RELATIVE, not absolute].** All τ were fit on the owner's
  single voice; an absolute `baseConf < 0.85` won't generalize across speakers/mics, and there's
  no off-device data to calibrate on (privacy stance). Resolution: gate on a **per-utterance
  relative** confidence (the base word sits in the low tail of *this utterance's* content-token
  confidences — the probe's signal was within-utterance: 0.69 vs 0.95–1.0). Self-calibrates per
  speaker; removes the cold-start generalization risk.
- **[H-store — name the owner: a dedicated `CorrectionStore` actor].** `corrections.json` needs an
  explicit owner with **atomic writes** (temp + `replaceItemAt`), debounced/coalesced, exposing an
  immutable **snapshot** the rescorer actor reads at rescore-start (no MainActor hop on the hot
  path). It also coordinates `vocabulary.txt` regeneration so there aren't two writers. Put the
  path behind one `correctionsFileURL` accessor so the v2 App-Group move is a one-line flip.
- **[H-homophone-UX — explain muted terms at add-time].** A term that collides with a common word
  ("Claude") never auto-fires, which looks broken. Resolution: an inline note at add-time + a
  persistent badge in the Vocabulary list — *instructional*: what + why + where it'll show up.
- **[H-features — run the features.md impact protocol before coding].** v1 adds user-facing
  surfaces (Review, auto-learn toast). Add §8.x entries + bidirectional cross-links + the
  Experimental badge, per CLAUDE.md. (Schema-impact section already present and correct.)

**MEDIUM/LOW (accepted, folded in):**
- **[M-conf-at-edit].** Per-word confidence is **not persisted**, so Path A cannot read "old span
  was low-confidence" at edit time. v1 Path A relies on **text heuristics only** (proper-noun-like
  + not-common) + probation; the confidence filter is an inference-time-only input, not available
  retroactively. (Persisting a per-word confidence map = a future additive schema bump, deferred.)
- **[M-apply-positional — RESOLVED by code check].** **Confirmed:** `RescoringResult` exposes only
  `originalWord/originalScore/replacementWord?/replacementScore?/shouldReplace/reason` — **no span
  index** (`VocabularyRescorer.swift:140-146`). So a pure post-filter **cannot** gate repeated words
  independently (occurrence 1 vs 3 of "name" are indistinguishable) — and global `replacingOccurrences`
  re-introduces the substring bug. The internal pipeline *does* carry `candidate.spanIndices`
  (`+TokenEvaluation.swift:148`); surfacing it on `RescoringResult` is a **~2-line FluidAudio patch**.
  **v1a decision:** carry a minimal FluidAudio patch (or upstream PR) to expose the span index — this
  is the **one real dent in the "zero-fork" claim**, now explicit. Interim fallback without a patch:
  the common-word guard is per-word-*type* (reject *all* occurrences of a common base word — safe and
  consistent), and the per-occurrence override is applied conservatively (any occurrence failing →
  reject all occurrences of that word that round). Patch preferred; fallback unblocks if needed.
- **[M-selftune].** The 👍/👎 flag-threshold dial needs a **min sample count, a clamped range, and
  an EMA/step** to avoid oscillation; drop the "no magic numbers" framing (it trades visible
  constants for controller hyperparameters — say so).
- **[M-phonetics-rhetoric].** Narrow the §0b/§10b claim: abstract phonetic *distance* didn't predict
  *this* confusion (name/Jamy are genuinely far yet acoustically confused) → per-term collision sets
  are the wrong tool **for the common-word guard**; phonetics is *not* "weak in general" (the same
  test caught cloud↔claude correctly). Keep phonetics for homophone-flagging.
- **[M-v2-poison].** v2 exemplar harvest must resist the high-conf-yet-wrong case (0.998 "name"):
  don't harvest when an active vocab term could contaminate; use trimmed/median prototypes; budget
  per-word slice retention against §6.
- **[Split — v1a / v1b].** v1 is honestly two milestones. **v1a** = freq resource + the gate +
  manual vocab (validated, low-risk, makes boosting safe to enable). **v1b** = Path A + Path B
  (text-only) + trust/revert. Ship v1a first; v1b after. §8 restructured.
- **[L].** `replacementScore` is `Float?` (unwrap in the margin); toast copy → *"Added to your
  vocabulary: …"* (not "Learned:"), **batched per save**, fired on edit-exit, tap routes to the
  Vocabulary list; empty-state → *"Nothing to review."* (drop the self-praise).

**Verified FINE by reviewers (no change):** the confidence half of the gate is alive (Jot's saved
transcript is always the **batch** path → `tokenTimings` populated); the compare-against-original
gate exists at `+TokenEvaluation.swift:88`; `cbw` is a public fork-free arg; `RescoreOutput.replacements`
exposes the scoring fields the post-filter needs; the JSON-not-SwiftData call is sound (and aligns
with the keyboard's JSON-mirror pattern for v2); the schema-impact + known-bugs dual entry are correct.

---

## 0d. Review round 2, second pass — corrections to 0c (2026-06-08)

A focused reviewer caught that three of §0c's fixes replaced *validated/computable* quantities with
*unvalidated/uncomputable* ones. These **supersede** the named §0c bullets:

- **[C1 corrected → use the BOOSTED margin, hold cbw fixed].** §0c-C1's "un-boosted margin
  (`vocabCtcScore − originalCtcScore`)" is **not recoverable** from the public API: `RescoringResult`
  exposes `replacementScore` (= `vocabCtcScore + adaptiveCbw`) and `originalScore` only — raw
  `vocabCtcScore` is discarded (`+TokenEvaluation.swift:84-85`), and `adaptiveCbw` is **not a
  subtractable constant** (it scales for terms >3 CTC sub-word tokens — most phrases/long names —
  `VocabularyRescorer.swift:64-69`). The probe's validated margins (3.5; 3.9/4.1) are the **boosted**
  `replacementScore − originalScore` (`main.swift:411`). **Resolution:** v1 gates on the **boosted
  margin** (computable today, exactly what was validated), with **cbw held fixed at the default** so
  the margin is stable; re-derive τ on *that* definition. True cbw-independence is **optional** and,
  if wanted, rides the **same** FluidAudio patch as the span index by also surfacing raw
  `vocabCtcScore` — one fork point, not two. (Replaces §0c-C1's "un-boosted" claim everywhere.)
- **[H-relconf corrected → keep the ABSOLUTE floor; relative is an optional refinement].** A
  relative-only gate removes the very floor that protected the 0.998 "name" case and degenerates on
  short utterances (a 3–4-token "distribution" always has a min). **Resolution:** the **primary**
  earned-override confidence test stays an **absolute** one (the validated `< ~0.85`-eligibility +
  a hard **never-auto-correct-above-~0.95** ceiling — *that* is the 0.998 protector). The
  per-utterance relative tail is an **optional, unvalidated** add-on to pick among genuinely
  uncertain words, **disabled when there are < ~6 content tokens**, and explored in the calibration
  pass — not the main gate. (Replaces §0c-H-relconf as the primary mechanism.)
- **[C4 corrected → split manual vs learned; add the state].** Probation must **not** apply to
  manual adds — typing "Claude" in Settings must boost immediately or v1a's manual vocab is inert.
  **Resolution:** **manual add (Settings) → `active` immediately**; **learned-from-edit (Path A) →
  `probationary`** (suggest-only) until a review 👍 promotes it. "Confirmed recurrence" is dropped
  from v1 (it needs the v2 fingerprint to observe a recurrence without firing); the only v1 promotion
  is the explicit 👍, **or** the same wrong→right edit being made a second time (detectable via Path A
  + store, no firing). Add `probationary` to the §4 `state` enum and fix the §5d "new entry → active"
  line accordingly. (Amends §0c-C4 and §4/§5d.)
- **[Revert widened (tightens §0c-C3)].** The narrowed revert never fires for **manual** entries
  (empty `wrongTexts`) — exactly the Bill/Mark over-correction case. **Resolution:** treat **any
  original-tab edit that changes a word away from an active entry's `correctText`** as a revert (no
  pre-stored wrongText needed), and **add the reverted-to text as a new `wrongText`**. Acknowledge
  the honest limit: paste-and-move-on (no edit) produces no revert signal in v1.
- **[Text-only Review caveat].** Without playback, a text-only card is reliable for **garble/OOV**
  (wrong text is self-evidently non-words) but weak for **plausible-but-wrong names** (user can't
  recall un-edited audio). Route the latter to "skip/unsure," and slow the self-tune EMA to reflect
  the noisier signal.

After these, the reviewer rated C2 (text-only), the span-index patch, H-store, and the v1a/v1b split
**coherent and sound** (v1a valid *given* manual-add stays active).

---

## 0e. Owner steer — single user + in-context feedback loop (2026-06-08)

Two owner clarifications that reshape calibration and the review surface:

- **Single speaker is the OPERATING MODEL, not a limitation.** There is exactly **one user per
  install** (the app's owner). So the round-1/round-2 "single-speaker calibration won't generalize
  across speakers" concern (§0c-H-relconf, Finding-2/M1) **dissolves** — we are not chasing
  cross-speaker robustness; we tune to the one voice that install will ever hear. **Plan change:**
  ship sensible **default** thresholds (calibrated on the owner's corpus = a representative single
  speaker), then **self-tune per install** from that user's own feedback. Cold-start = the shipped
  default; it only gets more personal. This also makes the **absolute** confidence floor fine (it
  adapts to the user over time) and **strengthens v2's per-user acoustic exemplars** — single-speaker
  is the easy regime, and here it's the *only* regime.
- **Collect feedback IN-CONTEXT at Recents, not a buried queue.** The product reviewer flagged
  Settings→Vocabulary Review as undiscoverable; the owner's fix is to surface the question **where
  the user already looks** — the **Recents** surface, when a recent transcript is viewed / re-used.
  When a recent that had a **gated correction** (or a near-miss the gate declined) is shown, ask
  **one very simple inline question** — *"Jamy ✓?"* / one-tap 👍 / ✗ — not a modal, only when there's
  something to confirm (never manufacture). **Each answer updates the score:**
  - **👍** → `confirmations++` → promotes a `probationary` term to `active`, reinforces an active one
    (per-term trust, §5d).
  - **✗** → `reverts++` → demote / `muted`; if the user supplies the right word, capture it as the
    correction (a Path-B-grade `reviewed` entry) and add the wrong form to `wrongTexts`.
  - Both also feed the **damped self-tuning dial** (min-sample count + clamped range + EMA,
    §0c-M-selftune) so the gate's flagging converges to *this* user without oscillating.
  **Plan change:** Path B's primary home moves **Settings → Recents-inline** (answers §9 #3); the
  Settings list remains the "manage / review-all / see muted terms" view, but the **main feedback
  loop is the in-context Recents tap.** Reuses Jot's existing Recents surface rather than building a
  new queue UI. (Still **text-only** in v1 — §0c-C2 — the inline question is on the shown text, no
  audio playback.)

**Honest caveat (don't over-promise "every single time"):** the loop tunes the precision/recall
tradeoff to this one user and will drive the **solvable** cases (their names/jargon) toward
always-right. It **cannot** break the homophone/garble **hard floor** (cloud↔Claude said identically
needs context; severely garbled audio carries no signal) — those stay suggest-only, honestly
flagged. The loop makes the solvable bulk converge; the unsolvable tail stays surfaced, not guessed.

---

## 0j. v1b review — incorporated (2026-06-09)

Two reviewers (model + implementability) stress-tested §0i. Accepted fixes (owner wants SIMPLE — cut
the over-engineered parts):

- **[Override scope — per-pair allowlist beats ALL three guards].** §0i said the override beats only
  the common-word guard. Wrong: the gate has three AND-ed checks (common-word, confidence ceiling,
  margin). A confirmed mapping must fire on **spotter-proposal alone, bypassing all three — but ONLY
  for that exact `(originalWord→term)` pair.** Else "Jamie→Jamy" works when mumbled (conf 0.86) but
  fails when said clearly (conf 0.98 > the 0.95 ceiling) — the "it learned" promise breaks on clear
  speech. It is a per-pair allowlist, never a gate-wide relaxation (every other word keeps full
  protection — the over-correction hole stays closed).
- **[Footgun guard — confirming a blocked COMMON word needs net ≥ 2].** A single ✓ on a blocked
  `name→Jamy` card would re-arm the exact headline bug (corrupt every "name"). Fix: a confirmed
  mapping whose **`originalWord` is a common word** (above the frequency floor) **arms only at
  net ≥ 2** (two confirmations); a rare/OOV original arms at net ≥ 1. Deactivation stays easy
  (net ≤ 0). Asymmetric: hard to arm a dangerous override, trivial to disarm. Reuses v1a's frequency
  set, no new UI.
- **[Confirmed-block suppression — stop re-asking].** "Confirm a block is correct" (keep "name") was
  a no-op that re-surfaced the same card every transcript. Fix: it adds the pair to a per-term
  **"don't ask" set** → the pane never surfaces that blocked pair again (the gate still blocks it
  silently). The pane converges to silence (§0f goal).
- **[Spotter-only firing in v1b; text-replay deferred].** The override only fires when the CTC spotter
  re-proposes the correction. Honest limitation (stated, not hidden). A non-spotter **text-replay**
  (§3.3 reactive: stored `wrongText` at a low-confidence span → apply, no spotter needed) makes "it
  learned" reliable but adds a 2nd correction path — **deferred to a fast-follow** if the spotter
  proves too intermittent in testing. Ambiguity (a wrongText mapping to >1 term) → don't auto-apply.
- **[Cut per-term auto-mute from v1b].** Over-engineered + a footgun (could kill a term's *good*
  mappings). Per-mapping `net ≤ 0` deactivation + the existing manual "disable term" in Settings
  cover it. Removed.
- **[occurrenceIndex in provenance].** Marks are search-resolved; for a repeated word, store the
  occurrence ordinal so the mark + the real-text Revert target the **Nth** occurrence, not the first.
- **[Relabel "hysteresis"].** Override activates at net ≥ 1 (≥ 2 for common originals), deactivates at
  net ≤ 0. No separate band — but an established mapping (net ≥ 2) naturally tolerates a stray revert
  (earned, intended). Fully reversible (1 confirm + 1 revert → net 0 → inactive).

**Implementability — resolved (HIGH confidence, code-verified):**
- **`transcript.id` timing.** At rescore there is no `Transcript` yet. The id is `transcriptID = UUID()`
  minted in `DictationPipeline.completeEndOfRecording` and passed to `TranscriptStore.append(id:)`.
  So: the gate produces proposals (no id) → carry them **in-memory** (widen `transcribe(samples:)` to
  return text + proposals) → `completeEndOfRecording` writes the side-JSON keyed by `transcriptID`
  **after `append` succeeds** (saved branches only; command-classification → key to the saved child
  id; search-skip-if-not-found covers mangled text). NOT `sessionID` (never stored on the transcript).
- **Gate change is nearly free + no actor hop:** `VocabularyGate.apply` already computes each
  proposal's decision/conf/margin — just return them. Fetch the `CorrectionStore` snapshot **once**
  in `rescore` (already async) and pass the immutable `Sendable` array into the static gate; `decide()`
  stays synchronous.
- **The read-only marked pane view is real new UIKit** (the Original-tab read display is
  `Text(...).textSelection(.enabled)`, not a UITextView). Wire it in **only when provenance exists**;
  fall back to the existing `Text` for clean transcripts (zero regression). Marks search
  `transcript.text` (Original tab only — never the rewrite tab).
- **Revert = write `transcript.text` directly** (one contiguous substitution) + reuse `saveEdit`'s
  persistence tail (`modelContext.save` + `TranscriptHistoryMirror.refresh` + `historyMirrorUpdated`).
  No edit-mode round-trip; Original tab only.

**Build order (each step independently testable):** 1 `CorrectionStore` actor → 2 gate returns
proposals + consumes snapshot + the per-pair override in `decide()` → 3 thread proposals out +
persist provenance keyed to `transcriptID` → 4 read-only marked pane view → 5 verdict → store + real
text edit → 6 (deferred) keyboard correction logging + self-tune. Steps 1–3 are pure data (unit/
Diagnostics-testable, no UI); 4–5 are the only new UI surface.

---

## 0i. v1b model — review the gate's decisions + learn from verdicts (2026-06-09)

v1a validated on device (gate blocks name→Jamy ×2, applies cloud code→claude code, protects cloud
services). v1b = the owner reviews the gate's decisions in the **transcript pane** and the verdicts
**teach the gate** — including making a *blocked* proposal apply next time. Concretely:

- **The gate emits ALL proposals (applied AND blocked)**, each with `{originalWord, term, decision,
  conf, margin}`. Persisted **per-transcript** in the side-JSON (keyed by `transcript.id`, §0g).
  (v1a already logs these to Diagnostics; v1b persists them.)
- **CorrectionStore** (per term): `state: active|muted` + **confirmed wrong→right mappings**, each a
  net counter `net = confirmations − reverts`.
- **Gate override (new, top of `decide()`):** if the proposed `(originalWord → term)` matches a
  confirmed mapping with **net > 0**, **APPLY** — overriding the common-word guard. This is the
  "earned override via *explicit user confirmation*": it was blocked only because the gate was
  guessing; once the user has said so, it's not a guess. (Still requires the CTC spotter to *propose*
  the correction — the override can't fire on a correction the spotter never surfaces; that's a
  spotter-recall limit, separate from the gate.)
- **Transcript pane surfaces every proposal for that transcript:**
  - **Applied** → marked on the *changed* word (search `replacementWord`): Keep / Revert.
  - **Blocked** → marked on the *unchanged* word (search `originalWord`): "considered X — should it?".
  - Tap → adjudicate ✓/✗.
- **Verdict → store, and the visible text:**
  - **Confirm a BLOCKED proposal** ("should be Jamy") → `confirmations++` on that mapping (create if
    new) → net > 0 → applies next time; **and apply it now** (real edit — Jot's own text).
  - **Revert an APPLIED correction** → `reverts++` → net drops; at **net ≤ 0** the override
    deactivates → gate falls back to its **safe default** (block) → over-correction stops next time;
    **and fix the text now**. Per-mapping (doesn't nuke the whole term).
  - **Confirm an applied / confirm a block** = reinforcement (the gate did right).
  - **Per-term mute:** if `reverts` clearly exceed `confirmations` across transcripts → `state =
    muted` (never auto-fires until re-enabled).
- **Demote is the mirror of confirm** (same counter, opposite sign), fully reversible. Start with **no
  hysteresis** (one revert deactivates a 1-confirm mapping — most responsive); add a net ≤ −1 rule
  only if a stray revert proves too twitchy.
- **Build needs:** gate returns the proposal list (not just text); a **`CorrectionStore` actor**
  (snapshot read at rescore-start, off the hot path); the gate reads confirmed mappings; a **new
  read-only `UITextView`-backed pane view** for the marks + tap popover (the current pane is SwiftUI
  `Text`, §0g-C1); Revert = a single contiguous edit (compatible, §0g).

---

## 0h. Scope lock — build v1a then v1b; terms added in Settings only (2026-06-09)

- **Build both v1a and v1b**, sequenced: **ship + test v1a (the gate) first**, then v1b.
- **"Add to Vocab on selection" is DROPPED** (both the in-app native callout and the keyboard •••
  action). **New terms are added ONLY in the Settings → Vocabulary section** (the existing manual-add
  UI). This removes the native `editMenuForTextRange`/`canPerformAction` work and the keyboard ••• item
  entirely (supersedes §0f's capture decision and §5a). The transcript pane **only tunes** terms you
  already added — it does not add them.
- **v1b is now just:** (a) the **CorrectionStore** (per-term trust + per-transcript provenance side-
  JSON), (b) **correction marks + tap Keep/Revert popover** in the transcript pane (still needs the
  new read-only marked view, but **no custom edit-menu** now), (c) **keyboard silently logs**
  corrections. No selection-based add anywhere.

---

## 0g. Pre-implementation review — incorporated (2026-06-09)

Two reviewers (design/data + implementability) stress-tested the §0f design against the code before
any Swift. **v1a (the gate) is implementable now**; **v1b had two real cost-corrections + a
persistence design gap**, all resolved here:

**CRITICALs:**
- **[The read-only pane is SwiftUI `Text`, NOT a UITextView — the marks/popover/native menu have no
  host view].** `TranscriptDetailView` renders the normal (non-editing) transcript as
  `Text(...).textSelection(.enabled)`; `InlineEditTextView` exists **only in edit mode**. A SwiftUI
  `Text` can't carry tap-able per-span attributes, anchor a popover on a word, or add a custom edit-
  menu item. **Resolution:** §5e's inline-mark + tap popover **and** §5a's in-app native "Add to
  Vocab" callout require a **new read-only `UITextView`-backed view** (NSAttributedString underline+
  dot runs, tap→glyph hit-test→span, popover rendered outside the scroll container; custom
  `editMenuForTextRange`/`canPerformAction`). This is **new UIKit-bridge work, not "reuse the pane"** —
  the plan was mis-scoped. (v1a's gate is unaffected.)
- **[NO FluidAudio fork — owner decision 2026-06-09 — but we STILL get per-occurrence precision].**
  Forking FluidAudio (`exactVersion: 0.14.7` remote pin) to surface its span index is rejected
  (maintenance cost). **But the span index was never the only per-occurrence signal:** the **TDT
  transcription gives per-word confidence + timing for every occurrence** (the same `tokenTimings`
  the gate already reads). So for a repeated word, the gate looks at each occurrence's TDT confidence
  and lets the correction land **only on the low-confidence occurrence(s)** (located by TDT timing),
  **protecting the confident ones** — e.g. "name" at 0.998 is safe, the "name" at 0.61 is eligible.
  Per-occurrence precision **without a fork**. The only case TDT confidence can't split is **all
  occurrences high-confidence** (true homophone, "the sky" vs clearly-spoken "Sky") → protect all,
  miss that one correction (safe failure, the deferred homophone tail). All decided **live** at
  dictation; nothing extra stored.
- **[Token scores are consumed live, NOT stored].** Per-token confidence/timings exist only at
  dictation time (batch path) and the gate uses them **then**; the raw scores are then discarded.
  We persist only the **outcome** — the per-transcript correction provenance — plus, inside each
  correction record, the **two numbers it fired at (`firedConfidence`, `firedMargin`)** so the
  self-tuning loop can learn "corrections below margin X get reverted → raise the bar." No per-token
  array is stored; nothing in v1 (or v2's audio-based acoustic layer) re-reads it.

**Persistence (the §0f gap, now decided):**
- **Per-transcript correction provenance IS required** for the pane marks (the doc never wrote it
  down). **Decision: option B — a side JSON keyed by `transcript.id` (UUID), NOT a schema field**
  (option A = a full frozen `JotSchemaV8` migration; rejected). Store `{termId, originalText,
  correctedText, firedConfidence, firedMargin}` per correction — **NOT raw offsets, NOT the per-token
  score array** (the array is consumed live by the gate; only the 2 fired-at numbers are kept, for self-tuning).
- **Marks are SEARCH-resolved at render, not offset-stored.** Offsets break: the user edits the
  transcript, and the text is mutated post-rescore by ParagraphSegmenter/FillerWordCleaner/
  NumberNormalizer, **and** the pane shows `displayText = rewriteUserEdit ?? cleanedText ?? text`
  while the correction happened on `text`. **Resolution:** at render, **search `displayText` for
  `correctedText`**; mark it if found, **skip silently if not** (rewrite/cleanup mangled it — correct
  behavior). On Revert, delete that provenance record. This makes marks robust to every edit path.
- **Handoff plumbing carries string pairs, not indices.** Threading corrections from `rescore` →
  `transcribe(samples:)` → the 4 `DictationPipeline` `publish` sites must carry
  `(originalText, correctedText)` (or the un-boosted text), since offsets are stale by publish time.

**Trust-model coherence:**
- **`probationary` is orphaned by §0f** (it was the "learned-from-edit" state; edit-diff is now
  demoted). **Resolution:** **v1 adds are `active`** (manual + Add-to-Vocab are deliberate);
  `probationary` + the auto-learn-from-edit path are **deferred** with the optional edit-diff bonus.
- **In-pane Revert is the reliable v1 revert** (clean, detectable, no `preEditText` snapshot needed).
  It must also **record the mishear as a `wrongText`** (close the §0f open question: **yes**) — the
  data is in hand (termId + original + corrected, zero ambiguity).

**Honest scope limits (acknowledged, not "fixed"):**
- **Pane-only feedback is driven by the reopen minority.** The owner's own rationale ("no one
  revisits the transcript panel") means the tuning loop is slower than §0e implied. The realistic
  in-app moment is the **live pane right after dictation** (already on screen — not "revisiting").
  v1 accepts a slower loop; do **not** re-promise "drives the bulk to always-right" without this.
- **Keyboard-logged corrections are only reviewable if a transcript was saved** (stop-outside-Jot).
  A correction made while dictating into a foreign field (no saved transcript) is logged-but-
  unreviewable until the deferred keyboard-feedback design lands. Don't imply universal pane review.
- **No implicit new-term discovery in v1.** Dropping edit-diff means a brand-new term is learned
  **only** via an explicit "Add to Vocab" tap. Accepted tradeoff; stated.

**Leftover contradictions to clean:** §9 #3 still says "in-context at Recents" (superseded by §0f);
§5d "👍 in review" / §5b Review queue are superseded by the pane feedback. Treat the Review queue as
**removed** in v1; the transcript pane is the feedback surface.

**Verified FINE (both reviewers):** the gate inputs (`RescoreOutput.replacements`), batch-path
`tokenTimings`, boosted-margin-is-the-only-computable-margin, the insufficient 75-word watchlist, the
`KeyboardUndoLedger.replacement` reuse, `textDocumentProxy.selectedText`, `FreshDictation` additive-
safety (one JSON blob, `try?`-decoded), the JSON-store/`Transcript.id`-UUID approach, and Revert =
a single contiguous edit (compatible with `InlineEditTextView`). **v1a is go.**

---

## 0f. Owner UX decisions — capture path & feedback surface (2026-06-09)

After iterating on live demos, the owner settled the *capture* and *feedback* UX. These **supersede**
§0e (Recents-inline), §5a (silent edit-diff learning), and §5e (keyboard chip):

- **Correction feedback lives in the TRANSCRIPT PANE — inline mark + tap.** A corrected word is
  marked in the transcript (soft underline + a small dot). **Tap it → a Jot-styled popover** shows
  *"heard cloud code → Claude Code"* with **↩ Revert / ✓ Keep**. Because the pane is **Jot's own
  text**, Revert *genuinely* restores the original word (a real edit), and both taps move the term's
  trust. No banner, no list — shown on the word, in context. Only vocabulary corrections get a mark;
  a clean transcript shows nothing. Demo: https://jot-keyboard-ux.ideaflow.page.
- **NOT the keyboard, NOT Recents, NO fantasy.** The earlier keyboard chip / Recents-pane / Recents-
  list ideas are **rejected**: the app inserts the *already-corrected* text (there is no visible
  "cloud→Claude" flip), the keyboard must **not** add chrome or grow height, and it **cannot**
  reliably revert another app's text. **v1 keyboard behavior:** silently **log** any applied
  correction; the user reviews/feeds-back later in the transcript pane. (If a keyboard correction was
  wrong, the user fixes it themselves in the moment — "auto-revert from the keyboard" is explicitly a
  later problem.) **The keyboard feedback UX is deferred to the owner's own design pass (Claude
  design).**
- **Adding a term = "Add to Vocab" on selection (two surfaces).** Replaces §5a's silent edit-diff
  learning (the owner: "no one revisits the transcript panel; people correct then-and-there"). Select
  a word → **Add to Vocab**: (a) **in-app** a *native* item in the iOS selection callout (Jot owns
  that text view — `InlineEditTextView`); (b) **in the keyboard** an item in the ••• actions popover,
  acting on `textDocumentProxy.selectedText`. **Gated:** hidden for a single common word (the gate's
  frequency set), shown for multi-word phrases. Deliberate add → `active` immediately. Demo:
  https://jot-add-vocab.ideaflow.page.
- **Contact seeding REJECTED** (owner: "there will be 1000" → floods the gate with names that collide
  with common words). Not a discovery path.
- **Dictionary size confirmed ~3–4 MB** (pronunciation dict, app-side, for phonetic keys); the
  keyboard's "is-common?" check needs only the lightweight common-word set (a few hundred KB) — fine
  within the keyboard memory budget.

---

## 0. Adversarial review — incorporated (2026-06-04)

An independent reviewer stress-tested this against the existing code. Resolutions:

- **[H1 — REJECTED, already validated]** Reviewer feared the gate can't be built because
  `ctcTokenRescore` only returns `.text`/`.wasModified`. **False:** `RescoreOutput.replacements`
  is an array of `RescoringResult` exposing `originalWord`, `originalScore`,
  `replacementWord`, `replacementScore`, `shouldReplace`, `reason`. The probe's gate is a
  **post-filter** over that array: keep `res.text` (un-boosted) as the base, re-apply only the
  replacements that pass the gate, using `tokenTimings` for per-word confidence. This is
  exactly what produced the validated "name preserved ×3 / Jamie→Jamy kept" result. No
  FluidAudio fork needed. (§3.2 updated to say this explicitly.)
- **[H2 — FIX]** The existing common-word list (`VocabularySettingsView.commonEnglishWatchlist`,
  ~75 words) is **UI-warning-only and does NOT contain "name"** — the headline corruption
  word. v1 must ship a **bundled runtime common-word list** (~2–5k high-frequency English
  words, incl. "name") used by the gate **and** by Path A's "common word?" check (merge with M2).
  Multilingual caveat: don't over-block foreign proper nouns that happen to be common words in
  another language — the guard protects *common English words being overwritten*, it does not
  reject *adding* a foreign term.
- **[H3 — FIX]** v1 stores are **main-app-only** (app sandbox, like `vocabulary.txt` today —
  `VocabularyStore` uses `applicationSupportDirectory`, NOT the App Group). The keyboard does
  not read vocabulary today and v1 keyboard-side review is deferred, so this is fine. Moving the
  store to the App Group container (with a one-time migration) is a **v2 prerequisite** before
  any keyboard write/read. §4's "App-Group-scoped" claim corrected.
- **[H4 — FIX]** Path A needs a **pre-edit snapshot**: `saveEdit()` overwrites `transcript.text`
  in place with no "before" copy. Capture `preEditText` on edit-mode entry, diff on save,
  **original tab only** (the rewrite tab edits a different field). Added to §5a/§8.
- **[M1 — CAVEAT]** τ_conf≈0.85 / τ_margin≈3.0 are **estimates from a small single-speaker
  sample**; raw CTC scores ranged −3…−13, so the **margin must be duration/frame-normalized**
  before thresholding. The 👍/👎 self-tune adjusts *flagging*, not the *gate* thresholds — a
  **wider calibration pass is a pre-enable task** (keep the master toggle off until done).
- **[M3 — FIX]** Path B ranking uses `(frequency+1) × uncertainty` (Laplace) so a
  **first-occurrence OOV miss** (frequency 0) surfaces instead of sinking.
- **[M5 — FIX]** `collidesWithCommonWord` is computed **before** the active/muted decision; such
  entries start **muted** regardless of source (never auto-fire once).
- **[L1/L2/L3 — FIX]** On phonetic-key collision between two entries, prefer higher
  `confirmations` and flag ambiguous → review (don't auto-apply). Held audio has a **30-day
  inactivity TTL** then the waveform is dropped. Path B chips in v1 = the entry's stored
  `wrongTexts` + free-text (no new beam-alternate capture needed).

---

## 1. Intent & invariants

Make Jot get the user's personal **names and jargon** right — especially proper
names across many languages (Indian, German, Chinese, European) plus tech terms
(Claude Code, kubectl) — and keep getting them right on its own over time, **without
ever degrading words it already transcribes correctly.** The trusted transcript only
quietly improves.

**Invariants (every decision must hold these):**
1. **The base (TDT) transcript is trusted. Overrides must be earned.**
2. **Never silently overwrite a confident, correct word.** This is the #1 guard.
3. **Conservative by default** — a missed fix is a minor annoyance; a wrong "fix" to
   a correct word burns trust. When unsure: change nothing, optionally queue for review.
4. **Key on the sound, not the spelling.** A learned correction fires only when the
   same acoustics recur — never on unrelated, legitimate uses of the same word.
5. **Every applied correction is reversible**, and a revert is a first-class signal
   that immediately demotes the offending entry.
6. **Local, real-time, light. No model retraining.** All lookup + biasing + gating.
7. **No LLM on the hot path for the common case.** The name/jargon bulk runs with no
   LLM. A small on-device model is reserved only for the homophone/context tail (§3.4),
   and is out of v1 scope.

---

## 2. The core model (one paragraph)

**Add a term → fix it by *sound*, at the tightest safe scope, and never overwrite a
word you already got right.** Concretely: a **CTC boost** matches added terms by their
acoustics (proactive); a **gate** (common-word guard + confidence/margin, all
reversible) stops it from corrupting correct words; a **correction memory** learns
from the user's edits and replays them; and the genuinely hard tail (severely garbled
audio, true homophones) is **flagged for review, never auto-changed.**

---

## 3. Architecture — scope-layered correction

For each word/phrase the system asks: *what is the tightest scope at which I can safely
fix this?* — and only acts at that scope.

### 3.1 Mechanism 1 — CTC vocabulary boosting (proactive), GATED

- The user's vocabulary list is fed to FluidAudio's `CtcKeywordSpotter` +
  `VocabularyRescorer` (already built in Jot, currently off by default). It matches each
  term **by sound** against the CTC log-probs and proposes a replacement where a term
  out-scores the base word.
- **This is precise for distinctive / multi-word terms** (names, "Claude Code",
  kubectl) and is the workhorse. It is **dangerous for single-word homophones** because
  the rescorer's gate is **handicapped, not absent.** The engine already compares the
  boosted term against the original word on the same audio (`shouldReplace =
  boostedVocabScore > originalCtcScore`) — but it first adds a hardcoded **`+3.0` boost**
  to the term (`defaultCbw = 3.0`), so the correct original word must win by **>3.0
  log-prob** to survive, and its only content guard is a **grammar-only stopword list**
  that omits everyday words like "name"/"cloud"/"code". So a confident correct word gets
  overwritten. (This is the shipping over-correction bug — see §10.) The v1 fix is a real
  **content-word guard** layered on top via a post-filter (§3.2); the engine keeps its validated
  cbw = 3.0 (lowering cbw is *not* the lever — §0c-C1).

### 3.2 The GATE (the fix for over-correction) — NEW, the heart of v1

The fix is a **post-filter** over the rescorer's surviving replacements (the engine keeps its
**validated cbw = 3.0**; see §0c-C1 for why lowering cbw is *not* the lever — it both cuts recall
upstream and corrupts the margin, since `replacementScore` includes cbw). cbw stays a *secondary
calibration knob* only. Apply a replacement **only if all hold**:

1. **Common-word guard (frequency-based, universal — a STRONG PRIOR, not an absolute veto).**
   Use a **word-frequency resource** (e.g. Zipf rank). A base word above a frequency floor is
   "common" and **heavily protected**: it may be overwritten only if the earned-override fires
   *hard* (low confidence **and** a large boosted margin, §0d-C1); otherwise the base word is
   kept. This is deliberately **not** a hardcoded list and **not** a per-term phonetic collision
   set — both are brittle; frequency is a universal graded signal needing no per-term computation.
   *(This killed all three "name"→"Jamy" corruptions — "name" is Zipf ≈ 4.1 and the 0.998-conf
   audio fails the hard override. A per-term phonetic collision set was built and **disproved** for
   this bug — §10/§0b.)* **Scope note:** a single-word target that *is itself* a common word (Bill,
   Mark, Rose) is left to the suggest/review tail (§3.4), **not** silent auto-correct.
2. **Earned-override check.** The base word is **absolutely** low-confidence (`minContentConf <
   τ_conf`, the validated ~0.85 eligibility) **AND below a hard never-touch ceiling** (~0.95 — *this*
   is what blocks the 0.998 "name" case) — **OR** the boost wins by a large **boosted** margin
   (`replacementScore − originalScore > τ_margin`, the quantity the API exposes and the probe
   validated; §0d-C1). cbw is **held fixed at the default** so the margin is stable. An *optional*
   per-utterance relative-tail refinement (disabled below ~6 content tokens) is explored in
   calibration but is not the primary gate (§0d-H-relconf). τ values are **re-derived in the
   calibration pass** — the raw single-speaker numbers (3.5 etc.) are provisional. Content-token
   confidence **excludes punctuation/casing tokens** (an implementation task — the probe's `min`
   did not yet filter them).
3. **Trust check.** The matched vocab entry is `active` (not `probationary` and not `muted` by a
   prior revert — §5).

Everything else: leave the base word untouched. A near-miss (passed the common-word
guard but failed the earned-override check by a little) is a candidate for **review**
(§5b), not an auto-edit.

`minContentConf` and per-token confidence come from `ASRResult.tokenTimings`
(per-token softmax probability + start/end times) — available on the **batch** path
(streaming exposes text only).

**Implementation (validated at cbw = 3.0 in the probe):** the gate is a **post-filter over
`RescoreOutput.replacements`** — each `RescoringResult` exposes `originalWord`, `originalScore`,
`replacementScore` (`Float?` — unwrap), `shouldReplace`. Keep `res.text` (the un-boosted TDT
transcript) as the base; re-apply only the replacements that clear the gate, **by span index, not
global `replacingOccurrences`** (string replace re-introduces the substring-corruption bug, §0c-
M-apply-positional). **Confirmed dent in "zero-fork":** `RescoringResult` carries `originalWord` but
**no span index** (`VocabularyRescorer.swift:140`), so v1a carries a **~2-line FluidAudio patch** to
surface the internal `spanIndices` (`+TokenEvaluation.swift:148`), with a conservative per-word-type
fallback if unpatched. Map each `originalWord` to its confidence via `tokenTimings`. The margin is the
**boosted** `replacementScore − originalScore` (what the API exposes and the probe validated, with
cbw held fixed; §0d-C1); if true cbw-independence is wanted, surface raw `vocabCtcScore` on the
**same** patch as the span index. τ_margin is re-derived in the calibration pass on the shipped
definition.

### 3.3 Mechanism 2 — Correction memory (reactive)

When the user corrects a word once, remember it and reproduce it when the same sound
recurs. A correction entry stores **wrong-text(s) + right-text + the span's acoustic
fingerprint** (§4), keyed on sound. On later input, a low-confidence span whose text
matches a stored wrong-text is replaced with the right-text — subject to the same gate.
The right-text also enters the vocabulary list, so CTC boost catches future occurrences
proactively.

**Acoustic fingerprint (v2 — per-user self-harvested, confirm-only).** The original probe
showed naive mean-pool cosine is useless (anisotropy) and even centered embeddings are only a
*weak* generic confirm. The session research found the reason and the fix: the right design is
**per-user, same-speaker** comparison, which is the *easy* regime. Recipe (all literature-backed,
all on-device, all v2):
- **Passively harvest exemplars.** Every time the user confidently dictates a common word, the
  text is known and the audio is in hand — store a few (5–10) acoustic exemplars per word as a
  *prototype*. No enrollment; it bootstraps from normal use. (Self-training/pseudo-label harvest,
  confidence-gated — DUST/STAR; per-speaker kNN exemplar datastores.)
- **Normalize hard.** Fixed-dim **acoustic word embeddings (AWE)** or DTW over selected encoder
  layers, then **per-speaker mean-centering (CMVN)** + **cohort / adaptive S-norm** (the same
  trick speaker-verification uses; ~20–30% relative EER win). This is what turns the probe's
  "weak" signal into a usable one.
- **Use it as a prior, never a decider.** Output a calibrated name-vs-common-word score and
  **fuse it with context** — it cannot settle a true homophone alone (§3.4 floor).
The *application* (homophone/name disambiguation from self-harvested exemplars) is novel; every
*mechanism* is established. **Out of v1** — v1's text + frequency-guard + gate path stands alone.

### 3.4 The tail — suggest, don't auto-fix

Two classes the gate deliberately refuses to auto-change:
- **Severely garbled audio** (e.g. a name swallowed at a rushed sentence-end, base conf
  ~0.16): even CTC can't find it. → surface in review; never guess.
- **True homophones** (cloud↔Claude standalone, a name that *is* a common word):
  acoustics + confidence can't separate them; only **context** can — this is a **citable
  hard floor** (identical pronunciation carries no acoustic information to exploit; EMNLP-2023
  shows speech models resolve homophones via syntactic context, not finer acoustics). → suggest
  in review, or (future) a small on-device LLM/n-gram with the dictionary in context. **Out of
  v1.** *(Note: phonetics CAN cheaply flag this class — cloud↔claude scored 0.19 in the §10
  collision test — so a phonetic key is useful for routing a term into suggest-mode, even though
  it can't auto-resolve it.)*

---

## 4. Data model

Keep the **CTC vocab list as a derived projection** (the existing
`vocabulary.txt` consumed by FluidAudio) — do not fork a second word list. Add a
richer **correction store** alongside it.

**CorrectionEntry** (the store; one per learned/added term):
| field | meaning |
|---|---|
| `id` | stable id |
| `correctText` | the right word/phrase ("Ritagya", "Claude Code") |
| `wrongTexts` | set of observed mis-hearings ("Ritadya", "the Taget", "cloud code"); grows with confirmations |
| `phoneticKeys` | Double-Metaphone / G2P keys for correct + wrong forms (cheap v1 sound key). **Scope caveat:** used only to match a new wrong-text against *this entry's own stored wrong-texts* (correction-memory recall) and to flag homophone-collision (§3.4) — **NOT** as the common-word guard (that's frequency-based) and **NOT** to discover collisions across the dictionary (proved unreliable, §10). Phonetic similarity ≠ the model's actual confusions. |
| `fingerprints` | optional small set of isolated-clip centered encoder vectors (§3.3); may be empty in v1 |
| `collidesWithCommonWord` | true if `correctText` is also a common dictionary word → homophone caution, never auto-apply |
| `trust` | `{ confirmations, reverts, state: active \| probationary \| muted }` — `probationary` = learned-from-edit, suggest-only until a review 👍 promotes it (§0d-C4); manual adds start `active` |
| `source` | `manual` (typed in Settings) \| `learned` (from an edit) \| `reviewed` (from a 👎+fix) |
| `frequency`, `lastSeen` | review prioritization + expiry |
| `audioChunkRef` | **transient** — deleted once the entry is resolved (§6) |

**Derived CTC vocab** = the set of `correctText` of `active` entries → written to
`vocabulary.txt` → boosted.

**Schema impact (required by CLAUDE.md):**
- Does this add/remove/rename `@Model` fields or add `@Model` entities? **No for v1.**
- The CorrectionEntry store is a **file-based JSON store** under
  `Application Support/Vocabulary/corrections.json` (sibling to the existing
  `vocabulary.txt`). This **avoids a SwiftData `JotSchemaVN` bump entirely** for v1.
- **v1 is main-app-only, single-writer.** Like `vocabulary.txt` today, this lives in the
  **app sandbox** (`applicationSupportDirectory`), NOT the App Group — the keyboard does not
  read vocabulary today and v1 review is app-side, so there is no cross-process write race.
  Moving both files into the App Group container (with a one-time migration) and adding write
  coordination is a **v2 prerequisite** before keyboard-side review.
- `collidesWithCommonWord` is computed **at entry creation, before** the active/muted decision;
  a colliding entry starts **muted** (review/suggest only), never `active`. Held `audioChunkRef`
  has a **30-day inactivity TTL** → waveform dropped, entry kept text-only.
- *Future:* if we ever attach correction provenance to the `Transcript` `@Model`, that
  is a separate additive `JotSchemaV(N+1)` + lightweight migration — explicitly deferred.

---

## 5. The correction-learning loop & UX (v1) — *designed here*

**Design principle: the best correction is one the user already makes. Don't add a
chore.** Two paths, in priority order.

### 5a. Capture — "Add to Vocab" on selection (primary; SUPERSEDED design, see §0f)

> **REVISED 2026-06-09 (§0f).** The silent edit-diff learning below is **dropped** — the owner: "no
> one revisits the transcript panel; people correct then-and-there." The primary capture path is now
> an **explicit "Add to Vocab" on a text selection**, in two surfaces:
> - **In-app:** a *native* item in the iOS selection callout (Jot owns the transcript text view —
>   `InlineEditTextView`): `Copy · Add to Vocab · Look Up`.
> - **In the keyboard:** an item in the ••• actions popover, acting on `textDocumentProxy.selectedText`
>   (a keyboard can't touch the host app's own callout).
>
> **Gated:** hidden for a single common word (frequency set), shown for multi-word phrases (self-
> gating). A deliberate add → `active` immediately. Demo: https://jot-add-vocab.ideaflow.page.
> The edit-diff text below is retained only as a *minor, optional* bonus path (if someone does edit a
> saved transcript), not the headline.

Jot already has transcript editing. When a saved transcript is edited:
0. **Capture a pre-edit snapshot.** `saveEdit()` overwrites `transcript.text` in place with
   no "before" copy, so Path A must snapshot the text on **edit-mode entry** (`preEditText`),
   diff against it on save, and only for the **original tab** (the rewrite tab edits a
   different field). Cleared on Cancel.
1. **Diff** `preEditText` vs new at the word/span level.
2. A changed span becomes a **candidate correction** only if: the region is short (1–3
   words); the **new** text is **proper-noun-like** (capitalized mid-sentence / absent from the
   dictionary); **and** the **new** text is **not** a common word (so we never learn
   "their"→"there" as vocab). *(Per-word confidence is NOT available at edit time — not persisted,
   §0c-M — so Path A relies on these text heuristics, not the old span's confidence.)*
3. **Resolution:**
   - **Clean single proper-noun swap** → **auto-add** to the vocabulary as a **`probationary`**
     `learned` entry (suggest-only until a review 👍 or a second identical edit promotes it —
     §0d-C4; this is what keeps a one-off bad edit from corrupting future transcripts), with a
     quiet, undoable confirmation. Toast (batched per save, on edit-exit, tap → Vocabulary list):
     *"Added to your vocabulary: Ritagya. Undo"* (not "Learned:", per the owner's microcopy taste).
   - **Ambiguous / multi-word / common-word-adjacent** → do **not** auto-add; drop a
     pre-filled **suggestion** into the Review queue (Path B) instead.

This captures the gold (wrong→right) exactly when the user naturally fixes something, with no extra
UI. (Audio capture for the span is **v2** — §0c-C2.)

### 5b. Path B — Review surface (for uncertain spans the user did NOT edit)

> **v1 = TEXT-ONLY (revised, §0c-C2).** The audio snippet / playback below is **v2** — Jot
> persists no recording audio today. v1 cards show the highlighted span + surrounding sentence +
> chips from stored `wrongTexts` + free-text, no ▶︎. Discoverability fix: surface a quiet inline
> "we weren't sure about a word here" affordance at the transcript, not only the Settings-buried
> queue (§0c-H-review).

Not everything wrong gets edited (the user often pastes and moves on). Keep a small,
capped **Review** queue of flagged spans.

**What gets flagged in:** a span where base confidence was low **and** one of: it matched
a stored `wrongText`; it's an OOV-ish token; or a boost *almost* fired but failed the
gate by a little. Rank by **leverage = (frequency + 1) × uncertainty** (Laplace, so a
**first-occurrence** OOV miss with frequency 0 still surfaces instead of sinking — a
first-time mis-heard name is the highest-value review item; a sound mis-heard repeatedly
then outranks a one-off as its frequency grows).

**The card — one span, one question:**
- ▶︎ **Audio snippet** of the span (tap to hear yourself say it — the most reliable
  memory trigger).
- The surrounding sentence with the span **highlighted** for context.
- The question: **"Did we hear this right?"** → **👍 Yes / 👎 No.**
  - **👍** = it was correct. A *negative* training signal for our flagging: "you flagged
    this but it was fine" → stop flagging this pattern, nudge the gate tighter here.
  - **👎** = wrong → reveal a correction row: an editable field pre-filled with the heard
    text + **one-tap chips** (in v1, the entry's stored `wrongTexts` / any prior right-text
    guesses — *not* a fresh beam re-run, which we don't persist) + free-text. One tap usually
    finishes it. → creates a `reviewed` CorrectionEntry (wrong+right+audio) and adds the right
    word to the vocabulary.
  - **👎 with no correction given** = weak (we know it's wrong, not the truth) → **demote**
    the heard text but can't build a replacement; allow "wrong — skip."

**Form factor:** a **list** (bulk-confirm the obvious 👍s fast; tap a 👎 to expand the
correction row), not a one-at-a-time card stack — better for a power user. *(Owner
decision §9.)*

**Cadence:** small **capped** daily queue — a ~30-second ritual, not a backlog dump.
Items **roll over**, get **re-ranked**, and **expire when stale** (you won't remember
old audio, and the privacy lifecycle will have purged it — §6). Empty state:
*"Nothing to review — Jot's getting your words right."* **Never manufacture items.**

### 5c. How we decide what's "correct" vs not

We **never autonomously decide correctness** for the ambiguous tail — **the user is
ground truth.** The system only: (a) surfaces *uncertainty* (low confidence + a match
signal), and (b) makes the correction one tap. The explicit edit (Path A) and the 👍/👎
(Path B) are the adjudication. The **up/down ratio is a self-tuning dial**: if most
reviews come back 👍, we're surfacing too much → raise the flag threshold, surface
fewer. This keeps the queue honest without any hand-set magic numbers surviving contact
with the user.

### 5d. Trust, auto-apply, revert (per entry)

- **States:** `active` (auto-applies through the gated boost, reversible), `probationary`
  (learned-from-edit; suggest-only, never auto-fires until promoted), and `muted` (demoted by a
  revert; never auto-fires).
- **New entry (§0d-C4):** **manual add (Settings) → `active` immediately** (the user explicitly
  asked for it — probation here would make manual vocab inert). **Auto-learned-from-edit (Path A) →
  `probationary`**; promoted to `active` only by a review 👍 **or** the same wrong→right edit being
  made a second time. A reviewed 👎+fix → `active`. (This is what makes Invariant 2 actually hold —
  a one-off bad edit can never silently corrupt a future transcript.)
- **Confirm (👍 in review, or repeated successful use)** → `confirmations++`; promotes
  `probationary` → `active`.
- **Revert (v1, §0d):** any **original-tab** edit that changes a word **away from an active entry's
  `correctText`** → the **loudest** signal → `reverts++`, set `state = muted`, **and add the
  reverted-to text as a new `wrongText`** (so even a manual entry with no prior wrongText demotes).
  Honest limit: paste-and-move-on (no edit) yields no revert signal in v1; cross-transcript
  provenance-based revert is v2.
- **`collidesWithCommonWord` entries never auto-apply** regardless of state — review/
  suggest only (the homophone tail).

### 5e. Feedback surface — the TRANSCRIPT PANE (REVISED 2026-06-09, §0f)

> **This is the v1 feedback surface.** A corrected word is **marked inline** in the transcript (soft
> underline + a small dot); **tapping it** opens a Jot-styled popover — *"heard cloud code → Claude
> Code"* with **↩ Revert / ✓ Keep**. Revert is a **real edit** (the pane is Jot's own text), and both
> taps move the term's trust (`confirmations`/`reverts`, §5d). Shown on the word, in context — no
> banner, no list; a clean transcript shows nothing. Demo: **https://jot-keyboard-ux.ideaflow.page**.
> Implementation note: the popover must render **outside** the scrolling text container (else it
> clips) and **flip below** the word when there's no room above.
>
> **Keyboard feedback is DEFERRED (owner → Claude design).** The keyboard inserts the *already-
> corrected* text (no visible flip), must **not** add chrome / grow height / touch Recents, and
> cannot reliably revert another app's text. **v1 keyboard = silently log the applied correction**
> (via the handoff payload, below) for later review in the transcript pane; if a keyboard correction
> was wrong, the user fixes it in the moment. The visual keyboard-feedback UX is the owner's own
> design pass. The research + code findings below are **retained for that future pass**, not v1.

The §0e feedback loop's **keyboard manifestation** *(deferred — see banner above)*: when a vocab
correction fires during dictation into another app, the keyboard could show a one-tap confirmation in
its **suggestion strip** (the only region it may draw).

**The affordance (research-backed — undo, don't ask).** Every precedent (iOS autocorrect, Gboard's
2025 tap-to-undo) and NN/g converge: for a reversible, frequent action, **offer Undo, let silence =
accept** — never pose a "was this right?" question (confirmations "cry wolf"; thumbs-up/down is for
rating finished answers, not in-flow corrections). So:
- **Known / confident term →** a single **Undo** chip (`↩ Changed to "Claude Code"`). Tap = strong
  negative (demote + revert text); silence = *weak* positive (low weight — the user's eyes are on the
  host field, not the strip, so a single silence is unreliable; promote on **volume**, not one).
- **New / probationary term (the uncertain band) →** a two-chip **`✓ Keep` / `↩ Revert`** — the one
  place an explicit *positive* is justified (active-learning "ask only when uncertain"). Keep =
  promote; Revert = demote.
- **Confident, long-trusted term →** show **nothing** (no nag).
- **Dismissal:** on the **next Dictate tap or keystroke** (primary), `~10s` soft timer (fallback) —
  WCAG/Material disfavor fast auto-dismiss of actionable content. Auto-dismiss on `textDidChange`/
  `selectionDidChange` (a stale revert would delete the wrong text).

**The revert mechanism reuses shipping code — verified.** Jot's keyboard already has a
`KeyboardUndoLedger` (`JotKeyboardViewController.swift:2079`) with a **`.replacement(deleted,
inserted)`** entry whose undo deletes the inserted text and re-inserts the original (`:864-870`) —
exactly "Claude Code → cloud". This **sidesteps the ~256–1000-char host context window** (the
caret-move limit, `:753`): undo blind-deletes a *known* length and never reads the field, so the
word-revert isn't bound by it. To revert one word inside a long paste, do a **whole-block replace**
(delete the inserted block, re-insert the same block with that one word reverted) — robust, no
word-locating, dodges web-view fragility.

**Integration — clean at the call site, needs upstream plumbing (verified):**
- `insertTrackedText(_ text:)` (`:616`) is the **single funnel** for the dictation auto-paste insert
  (`:1160`, `pasteText = payload.text`) and today records `.insertion(text)` (`:619`). Add a sibling
  `insertTrackedReplacement(deleted:inserted:)` calling the ledger's existing `recordReplacement`
  (`:2115`). Trivial; other callers (Recents re-paste `:1559`, clipboard `:692/713/1568`) carry no
  corrections and stay `.insertion`.
- **The blocker:** the keyboard only receives the **final corrected text** — `ClipboardHandoff.
  FreshDictation` (`ClipboardHandoff.swift:23`) carries `{sessionID, timestamp, preview, text}`, **no
  correction metadata**. `RescoreOutput.replacements` (originalWord→replacementWord) lives in the app
  pipeline and never crosses. v1b must **extend the handoff payload** (additive Codable: a list of
  `{originalWord, replacementWord, termId}`, or simplest the un-boosted text so revert =
  `.replacement(deleted: original, inserted: corrected)`) and populate it where the pipeline calls
  `ClipboardHandoff.publish`.
- **Score write needs the App Group store (v2 boundary, §4/H3).** Writing per-term trust from the
  keyboard requires the correction store cross-process. **v1 staging:** the keyboard does the local
  text-revert (no store needed) + **queues a feedback event to the App Group** for the app to apply
  to the trust store; full keyboard-side score writes land with the v2 App-Group migration.

**Honest constraints (same as the shipping Undo):** web-view/Electron hosts may revert imperfectly
(redo is the existing recovery path, `:2153`); only valid while the inserted block is still trailing
(auto-dismiss on typing); the score write needs **Full Access** (already on for the handoff). Secure/
opt-out fields never show the keyboard, so the chip is absent by construction — safe.

---

## 6. Privacy & data lifecycle

> **This entire section is v2 (revised, §0c-C2).** Jot persists no recording audio today, so v1
> holds **no** audio — there is nothing to retain, surface, or purge in v1. When the audio layer
> lands in v2 it ships with the lifecycle below **plus an at-enable consent disclosure** (§0c-
> M-consent): when the learning toggle is turned on, a one-line note that Jot briefly keeps short
> on-device clips of uncertain moments, auto-deleted after review, and how to turn it off.

- Audio is **transient**. Keep a span's chunk only until its entry is **resolved**
  (👍 / corrected / auto-learned-confirmed); then reduce it to the embedding/fingerprint
  and **delete the waveform** (an embedding is not reconstructable into speech).
- Store **small spans only**, never whole recordings. Splice the flagged spans
  during/right after transcription and discard the rest of the buffer (a 30-min Float32
  buffer is ~115 MB — never retain it).
- Surface it: *"N clips held for review"* + a one-tap **Clear all**, and a setting to
  **disable audio retention** entirely (text-only review, no playback).
- All on-device. This feature transmits **nothing** — consistent with Jot's
  "only feedback ever leaves the device" stance.

---

## 7. Reuse of existing infrastructure (don't rebuild)

Already present in `Jot/App/Vocabulary/` (consult before writing new plumbing):
- `VocabularyStore` — the term list + `vocabulary.txt` + master toggle
  (`jot.vocabulary.enabled`, default off).
- `VocabularyRescorerHolder` — wraps `CtcKeywordSpotter` + `VocabularyRescorer`;
  `rescore(transcript:tokenTimings:audioSamples:)` is the integration point in
  `TranscriptionService.runInference`.
- `CtcModelCache` — the CTC-110M bundle.
- `VocabularySettingsView` — the manage-terms UI.

**v1 adds:** (a) the **gate** at `VocabularyRescorerHolder.rescore` — a post-filter (frequency
common-word guard + relative-confidence/un-boosted-margin earned-override + trust), engine cbw
unchanged; (b) the **CorrectionEntry** JSON store owned by a dedicated `CorrectionStore` actor +
the edit-diff capture (Path A); (c) the **text-only Review** surface (Path B). Held-audio capture
and the §6 audio lifecycle are **v2** (Jot persists no audio today — §0c-C2). It does **not**
rebuild the spotter/rescorer/term-list.

---

## 8. Implementation phasing

**v1a — the safe-to-enable core (ship first; validated, low-risk):**
0. **Prerequisite — bundled word-frequency resource** (a frequency-ranked list / Zipf table,
   not a hardcoded membership set), shared by the gate's common-word guard and Path A's
   "is this a common word?" check. Universal across users and terms; the existing ~72-word UI
   watchlist is insufficient. Keep the asset compact (bundle-size matters; main-app target).
1. **The gate** — a **post-filter** on `RescoreOutput.replacements` (engine cbw stays at the
   validated 3.0): frequency common-word guard (strong prior) + earned-override (relative
   confidence / boosted margin, cbw fixed) + trust/mute, applied **by span index**. *This makes the
   existing CTC boost safe to turn on.* (Highest-leverage piece; validated in §10 at cbw = 3.0.
   Pick sensible **default** thresholds — frequency floor, confidence floor, margin — on the
   **final score definition** (one-speaker corpus is fine; §0e), keep the master toggle off until
   the defaults are sane, then **the gate self-tunes per user from Recents feedback** (§0e). No
   "calibrate for everyone" — there is one user per install.)
2. **Manual vocabulary** with the gate (Settings already has the list UI) — turn it on, feed
   phrases/names, gated. Add the **homophone-collision at-add explanation + badge** (§0c-H).

**v1b — feedback + tuning (after v1a; revised §0h — terms are added in Settings only):**
3. **`CorrectionStore` actor** — per-term trust + per-transcript correction provenance (side-JSON).
   **No "Add to Vocab on selection"** (dropped, §0h); new terms come from the **Settings → Vocabulary**
   manual-add UI that already exists. The pane only tunes existing terms.
4. **Correction feedback in the TRANSCRIPT PANE** (§5e/§0f) — mark corrected words inline; tap →
   Jot-styled popover (*heard X → wrote Y*) with **Revert** (a real edit — Jot's own text) / **Keep**;
   both move per-term trust. No audio. Popover renders outside the scroll container + flips below near
   the top. Self-tuning flag threshold with min-sample + clamp + EMA (§0c-M-selftune).
5. **Keyboard correction logging (no UI yet)** — extend the `ClipboardHandoff` payload to carry the
   applied corrections so the keyboard can **silently log** them for later pane-review; the **visual
   keyboard-feedback UX is deferred to the owner's design pass (Claude design)**, §0f.
6. **Phonetic key** (Double-Metaphone / G2P via MisakiSwift) for the wrong→right correction match
   and homophone-flag routing — single-pass, no embeddings.
7. **features.md + ARCHITECTURE.md + known-bugs** updates per the CLAUDE.md protocol (impact report
   **before** coding v1b's user-facing surfaces).

**Deferred (v2+):**
- **Acoustic fingerprint** (§3.3) — add once v1's text+phonetic+gate path is proven;
  needs the isolated-clip encoder re-embed (route: load `Encoder.mlmodelc` directly, as
  the probe does — no FluidAudio fork required).
- **Held-audio capture + the §6 audio lifecycle + Review playback** — Jot persists no recording
  audio today; this is a *new* clip-capture-storage-purge subsystem, deferred to land **with** the
  acoustic layer (its only other consumer) and gated behind an **at-enable consent** disclosure
  (§0c-C2, M-consent).
- **Cross-transcript revert detection** — needs correction→transcript-span provenance (an additive
  `JotSchemaV(N+1)` + a store back-link); v1 demotes only on the edit-diff-back-to-`wrongText`
  signal (§0c-C3).
- **Homophone/context disambiguation** via a small on-device LLM/n-gram (the §3.4 tail).
- Nightly housekeeping (dedupe / prune / fingerprint-centroid consolidation).
- Keyboard-side review UX (v1 review lives in the main app).

---

## 9. Open decisions for the owner (when you're back)

1. **Review form factor:** list (bulk-confirm, recommended for a power user) vs card
   stack (guided, habit-forming). Default chosen: **list**.
2. **Auto-add aggressiveness:** auto-add a clean proper-noun edit silently-with-undo
   (recommended), or always route through review first? Default chosen: **auto-add with
   undo** for clean cases.
3. **Where Review lives:** **SUPERSEDED by §0f → the TRANSCRIPT PANE** (inline mark + tap popover),
   NOT Recents. The earlier Recents-inline answer (§0e) is rejected; the Settings → Vocabulary list
   stays as the "manage / muted terms" view. The standalone Review queue is **removed** in v1.
4. **Homophone tail:** ship v1 with homophones simply left alone (never auto-correct,
   surfaced in review), and decide later whether to add the small-LLM context pass?
   Default chosen: **leave alone in v1.**
5. **Default state of the master toggle:** keep CTC boosting **off by default** until
   the gate is in, then consider on-by-default for a curated starter list? Default
   chosen: **off until the gate ships; revisit.**
6. **Acoustic layer in v1 or v2:** **OWNER-CONFIRMED 2026-06-08 → defer to v2.** ("Option A
   now, Option B later.") v1 = text + frequency-guard + gate. v2 = the per-user self-harvested
   exemplar recipe (§3.3). Note: the earlier "acoustic is core" steer is preserved — it *is* the
   right long-term layer; the probe simply tested the wrong (generic, cross-speaker) version.

---

## 10. Evidence (probe results on real on-device data)

Validated with a throwaway SwiftPM CLI linking FluidAudio 0.14.7 (the exact rev Jot
ships) over the Mac Jot corpus (1,223 real transcripts + audio; models on disk).
Mac has no CTC, so its stored transcripts are **raw** — the probe applies CTC + the gate
on that raw audio, faithfully reproducing the **phone's** CTC behavior.

- **Confidence gate is real.** TDT returns per-token confidence + timings
  (`ASRResult.tokenTimings`). On "restart cloud code", "cloud" flagged at **0.69** while
  every correct word sat 0.95–1.0. Word confidence must use **content tokens only** —
  punctuation tokens (e.g. a `.` at 0.49) cause false flags otherwise.
- **CTC phrase boost is precise & self-gating.** Adding the phrase **"Claude Code"**
  fixed "cloud code" *and* "Clot Code" → "Claude Code", and **left genuine "cloud
  providers" untouched** (zero false positives). Bare single-word "Claude" over-replaced
  ("cloud providers"→"Claude providers") — single-word homophones are the danger.
- **Names work when clear.** Boosting **"Ritagya"** fixed "Ritadya"→"Ritagya" (both
  occurrences, margins 3.9/4.1); **"Vineet"** fixed "Vinit"→"Vineet"; decoys
  (Padmini/Søren/kubectl) did **not** false-fire; non-ASCII ("Søren") tokenizes fine.
  The only miss was a *severely garbled* clip (Ritagya → "the Taget" at 0.16 conf).
- **The over-correction bug, reproduced and fixed.** User added Vineet/Jamy/Ritagya on
  their phone and said "my name is Vineet, my wife's name is Jamy, my friend's name is
  Ritagya" → the ungated boost corrupted **every "name"→"Jamy"** (the 3 corrupted
  "name"s were transcribed at **0.998–1.000** confidence — flawless words overwritten,
  because the rescorer has no gate). The probe's **gated** mode (common-word guard +
  margin) restored all three "name"s **and** kept the real "Jamie"→"Jamy" fix
  (margin 3.5). This is the core proof v1 works.
- **Acoustic separability (for the deferred §3.3 confirm).** Naive mean-pool cosine is
  useless (~0.97 for all pairs, anisotropy); **mean-centering** unlocks a real but loose
  gap (same-word ≈ 0.24 vs different-word ≈ 0); **isolated** re-embedding beats
  in-context frame-slicing for short words. → usable only as a weak veto, hence deferred.
- **Product practice (for the LLM tail).** Precise custom-vocab without over-correction
  comes from **whole-word find-replace** (superwhisper, Talon) and **LLM-with-context**
  (Wispr Flow = fine-tuned Llama on cloud GPUs, ~250 ms; Aqua), *not* pure acoustic
  biasing. NeMo phrase-boosting is **broken for Parakeet TDT** (issue #14500) but the
  **CTC word-spotter path FluidAudio uses is the mature one** — we are on the right
  mechanism. Apple `PhraseCount` is *additive* (won't override strong acoustics); the
  fix for FluidAudio's hard-replace is exactly our gate.

### 10b. Session 2026-06-08 — code, research, and a disproof

- **FluidAudio already implements the compare-against-original gate — it's handicapped, not
  missing** (`VocabularyRescorer+TokenEvaluation.swift:88`). The over-correction comes from the
  **`+3.0` additive boost** (`defaultCbw`) and a **grammar-only stopword guard** (no "name"/
  "cloud"/"code"); Jot returns the output verbatim. → v1 fix = **frequency guard** (cbw held fixed; §0d-C1).
  Confirms the NeMo CTC-WS pattern (additive bias, re-compare against greedy, `cbw`/`ctc_w` dials).
- **Per-term phonetic collision set: DISPROVED for the core bug.** Built with the real expert
  recipe (CMUdict + panphon feature-edit-distance + Zipf frequency filter). For added term "Jamy":
  **"name" ranks #6,053 / ~12,900**; collision-set size at threshold 0.40 (the only level that
  includes "name") = **9,574 words (≈⅔ of common English)**; at a usable 0.10 threshold the set is
  19 words and excludes "name". Direct distances: **name↔Jamy = 0.32** (norm feature ED), phoneme
  Levenshtein 3 — *not* neighbors; **cloud↔claude = 0.19** — a genuine near-homophone the test
  *did* catch. ⇒ frequency guard for the common-word case; phonetics only for homophone-flagging.
- **Expert consensus (3 sourced passes).** (1) Over-correction fix = additive bias + re-compare
  vs the un-biased word, replace only if it wins (NeMo CTC-WS, our exact engine); consumer tools
  use soft boost + **whole-word** post-replace (superwhisper v1.32 fixed our exact substring bug)
  and keep vocab small. (2) Collision sets = G2P + feature-weighted phoneme distance, but the *best*
  signal is the recognizer's own confusions — and unlike Apple's closed API, **we have them**
  (FluidAudio CTC log-probs), which is precisely what the score-gate uses. (3) True homophones are
  a **hard lexical floor** — context/LM required; no acoustic method separates them. (4) The v2
  acoustic idea maps to established AWE + self-supervised personalization; same-speaker is the easy
  regime; needs CMVN + S-norm + 5–10 exemplars; a prior fused with context, never standalone.
