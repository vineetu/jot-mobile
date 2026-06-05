# Plan: Adaptive Vocabulary & Correction (v1)

Status: **DESIGN — not implemented.** Empirically validated on real on-device data
via a throwaway probe (see §10 Evidence). UX designed here for v1. Owner stepped
away and asked me to figure out the correction-learning UX; open decisions for the
owner are collected in §9.

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
  the raw rescorer has **no gate** — it replaces whenever the boosted term out-scores
  the baseline, even on a confident correct word. (This is the shipping over-correction
  bug — see §10.)

### 3.2 The GATE (the fix for over-correction) — NEW, the heart of v1

Wrap the rescorer's proposed replacements; apply one **only if all hold**:

1. **Common-word guard.** The base word being replaced is **not** an everyday word.
   Maintain a common-word set (frequency list); never let a custom term overwrite a word
   in it. *(This single rule killed all three "name"→"Jamy" corruptions in testing.)*
2. **Earned-override check.** The base word was **low-confidence** (`minContentConf <
   τ_conf`, start τ_conf ≈ 0.85, computed over **content tokens only** — exclude
   punctuation/casing tokens) **OR** the boost wins by a **large margin**
   (`replacementScore − originalScore > τ_margin`, start τ_margin ≈ 3.0 in CTC log-prob
   units). *(Lets a genuinely-mangled name through; blocks marginal homophone swaps.)*
3. **Trust check.** The matched vocab entry is in `active` state (not muted by a prior
   revert — §5).

Everything else: leave the base word untouched. A near-miss (passed the common-word
guard but failed the earned-override check by a little) is a candidate for **review**
(§5b), not an auto-edit.

`minContentConf` and per-token confidence come from `ASRResult.tokenTimings`
(per-token softmax probability + start/end times) — available on the **batch** path
(streaming exposes text only).

**Implementation (validated in the probe):** the gate is a **post-filter over
`RescoreOutput.replacements`** — each `RescoringResult` exposes `originalWord`,
`originalScore`, `replacementScore`, `shouldReplace`. Keep `res.text` (the un-boosted
TDT transcript) as the base; re-apply only the replacements that clear the gate, mapping
each `originalWord` to its `minContentConf` via `tokenTimings`. No FluidAudio fork — this
runs entirely on the existing `VocabularyRescorerHolder.rescore` output. Normalize the
margin by the span's frame count before comparing to τ_margin (raw CTC scores are not
length-stable).

### 3.3 Mechanism 2 — Correction memory (reactive)

When the user corrects a word once, remember it and reproduce it when the same sound
recurs. A correction entry stores **wrong-text(s) + right-text + the span's acoustic
fingerprint** (§4), keyed on sound. On later input, a low-confidence span whose text
matches a stored wrong-text is replaced with the right-text — subject to the same gate.
The right-text also enters the vocabulary list, so CTC boost catches future occurrences
proactively.

**Acoustic fingerprint (gated confirm, not a primary key).** For the residual cases,
an **isolated-clip, mean-centered** encoder embedding (see §10 — isolated beats
in-context for short words; centering is mandatory) provides a *weak confirm*
(same-word ≈ 0.24 vs different-word ≈ 0 cosine). Use it only to **veto** a text/phonetic
match that's acoustically implausible — never as the sole trigger. **Deferred past the
first cut if it complicates v1** (the text + phonetic + gate path stands alone).

### 3.4 The tail — suggest, don't auto-fix

Two classes the gate deliberately refuses to auto-change:
- **Severely garbled audio** (e.g. a name swallowed at a rushed sentence-end, base conf
  ~0.16): even CTC can't find it. → surface in review; never guess.
- **True homophones** (cloud↔Claude standalone, a name that *is* a common word):
  acoustics + confidence can't separate them; only **context** can. → suggest in review,
  or (future) a small on-device LLM/n-gram with the dictionary in context. **Out of v1.**

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
| `phoneticKeys` | Double-Metaphone / G2P keys for correct + wrong forms (cheap v1 sound key) |
| `fingerprints` | optional small set of isolated-clip centered encoder vectors (§3.3); may be empty in v1 |
| `collidesWithCommonWord` | true if `correctText` is also a common dictionary word → homophone caution, never auto-apply |
| `trust` | `{ confirmations, reverts, state: active \| muted }` |
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

### 5a. Path A — Learn from in-the-moment edits (primary, zero added friction)

Jot already has transcript editing. When a saved transcript is edited:
0. **Capture a pre-edit snapshot.** `saveEdit()` overwrites `transcript.text` in place with
   no "before" copy, so Path A must snapshot the text on **edit-mode entry** (`preEditText`),
   diff against it on save, and only for the **original tab** (the rewrite tab edits a
   different field). Cleared on Cancel.
1. **Diff** `preEditText` vs new at the word/span level.
2. A changed span becomes a **candidate correction** only if: the region is short (1–3
   words); the **old** span was low-confidence **or** the **new** text is a
   proper-noun-like token absent from the dictionary; and the **new** text is **not** a
   common word (so we never learn "their"→"there" as vocab).
3. **Resolution:**
   - **Clean single proper-noun swap on a low-confidence span** → **auto-add** to the
     vocabulary as an `active` `learned` entry, with a quiet, undoable confirmation:
     a small toast *"Learned: Ritagya — Undo"*. (Mirrors how Wispr auto-adds proper
     nouns; the common-word filter is what makes this safe.)
   - **Ambiguous / multi-word / common-word-adjacent** → do **not** auto-add; drop a
     pre-filled **suggestion** into the Review queue (Path B) instead.

This captures the gold (wrong→right + the span's audio) exactly when the user naturally
fixes something, with no extra UI.

### 5b. Path B — Review surface (for uncertain spans the user did NOT edit)

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

- **States:** `active` (auto-applies through the gated boost, reversible) and `muted`
  (never auto-fires; offered only as a review suggestion).
- **New entry** (manual add, auto-learned edit, or reviewed 👎+fix) → `active`. An
  auto-learned-from-edit entry is also dropped into the next Review as a one-time sanity
  check.
- **Confirm (👍 in review, or repeated successful use)** → `confirmations++`.
- **Revert** of an applied correction (user undoes it in a later transcript) → the
  **loudest** signal → `reverts++`, set `state = muted`, raise its threshold. Never
  silently auto-fire again until re-earned.
- **`collidesWithCommonWord` entries never auto-apply** regardless of state — review/
  suggest only (the homophone tail).

---

## 6. Privacy & data lifecycle

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

**v1 adds:** (a) the **gate** wrapping `VocabularyRescorerHolder.rescore` (common-word
guard + earned-override + trust); (b) the **CorrectionEntry** JSON store + the
edit-diff capture (Path A); (c) the **Review** surface (Path B); (d) the privacy
lifecycle. It does **not** rebuild the spotter/rescorer/term-list.

---

## 8. Implementation phasing

**v1 (ship first):**
0. **Prerequisite — bundled common-word list** (~2–5k high-frequency English words incl.
   "name"), shared by the gate and Path A. The existing 75-word UI watchlist is insufficient.
1. **The gate** around the existing rescorer — post-filter on `RescoreOutput.replacements`:
   common-word guard + earned-override (frame-normalized margin / confidence) + trust/mute.
   *This alone makes the existing CTC boost safe to turn on.* (Biggest, highest-leverage piece;
   validated in §10. Run a **wider threshold calibration** before enabling the master toggle
   for everyone — keep it off until then.)
2. **Manual vocabulary** with the gate (Settings already has the list UI) — turn it on,
   feed phrases/names, gated.
3. **Path A** — learn from edits → auto-add proper nouns (undoable) + correction store.
4. **Path B** — the Review surface (list, 👍/👎, candidate chips, audio snippet).
5. **Privacy lifecycle** — transient spans, "N clips held", clear-all, retention toggle.
6. **Phonetic key** (Double-Metaphone / G2P via MisakiSwift) for the wrong→right
   correction match — single-pass, no embeddings.

**Deferred (v2+):**
- **Acoustic fingerprint** (§3.3) — add once v1's text+phonetic+gate path is proven;
  needs the isolated-clip encoder re-embed (route: load `Encoder.mlmodelc` directly, as
  the probe does — no FluidAudio fork required).
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
3. **Where Review lives:** a dedicated tab, a Settings → Vocabulary subsection, or a
   home-screen nudge when the queue is non-empty? Default chosen: **Settings →
   Vocabulary subsection** for v1 (lowest surface-area).
4. **Homophone tail:** ship v1 with homophones simply left alone (never auto-correct,
   surfaced in review), and decide later whether to add the small-LLM context pass?
   Default chosen: **leave alone in v1.**
5. **Default state of the master toggle:** keep CTC boosting **off by default** until
   the gate is in, then consider on-by-default for a curated starter list? Default
   chosen: **off until the gate ships; revisit.**
6. **Acoustic layer in v1 or v2:** the evidence says it's a *weak confirm* — include the
   veto in v1 or defer entirely? Default chosen: **defer to v2**; v1 = text+phonetic+gate.

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
