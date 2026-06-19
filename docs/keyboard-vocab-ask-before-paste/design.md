# Keyboard Vocab — Fewer Asks + Ask-Before-Paste

Status: **REVIEWED — ready to implement.** Architecture design-review + front-end/UX review complete; all accepted findings folded in (see §11). Owner approved Option A (narrowed). Implementing per §6, Thread 1 first, each item adversarially reviewed before merge.
Owner: vineet · Drafted: 2026-06-18 · Feature folder: `docs/keyboard-vocab-ask-before-paste/`

> No `requirements.md` exists for this folder. Intent is captured here directly from the owner brainstorm. If we want a formal scope doc, run `/requirements` — but the two threads below are tightly scoped, so this design doubles as the intent record.

---

## 1. Feature overview

Two related but independently-shippable threads on the keyboard's adaptive-vocabulary **correction prompts** (the post-dictation "what should this say?" quick-review).

- **Thread 1 — Fewer asks.** Stop the keyboard nagging about the same word once the user has clearly answered it. Poster child: the everyday word **"okay"** is an acoustic cousin of the user's vocab term **"Okta"**; the user rejects the swap ~99% of the time, yet the keyboard re-asks on every occurrence forever.
- **Thread 2 — Ask BEFORE paste.** When the keyboard has gated candidate(s) it wants the user to confirm, **hold the paste**, show a small **card deck** (≤3 cards, one per ask) with a per-card idle countdown, and insert the *resolved* text — instead of today's "paste first, ask after."

**Sequence: Thread 1 ships first.** Fewer asks makes Thread 2's hold rare and gentle (most pastes will have zero asks and behave exactly as today).

---

## 2. Background — how it works today (grounded in code)

### 2.1 The gate (why "okay" is asked)
`VocabularyGate.decide()` (`Jot/App/Vocabulary/VocabularyGate.swift:197-274`) is a 5-step cascade deciding **auto-apply vs BLOCK** for a `(heardWord → term)` pair:

1. **Step 0 — user-confirmed override** (`:226-237`): auto-applies a learned mapping **only when `!isCommon && net >= 1`** (`:235`). Common words never reach auto-apply here.
2. **Step 1 — plausibility** (`:240-254`): skeleton edit-distance ≤ 0.45.
3. **Step 2 — multi-word term** (`:256-259`): apply.
4. **Step 3 — confidence ceiling** (`:260-263`).
5. **Step 4 — common-word guard** (`:269-270`): **any common heard-word → BLOCK, unconditionally.** This is a deliberate safety rule ("silently rewriting an everyday word everywhere is the headline over-correction bug").

`isCommon` is checked against the **heard/original word** via `CommonWords.isCommon` (`CommonWords.swift`). `"okay"` IS in `Jot/Resources/common-words.txt` (grep-confirmed). So "okay" always hits Step 4 → BLOCK → surfaced as a per-occurrence ask.

### 2.2 The learning that exists but isn't consulted
`CorrectionStore` (`Jot/App/Vocabulary/CorrectionStore.swift`, actor, `corrections.json`) records every adjudication as `Mapping { originalWord, term, confirmations, reverts, net }` plus a `suppressedBlocks: [String]`. The user's 20+ "keep okay" rejections **are recorded** (each is a `revert`, driving `net` negative). But the gate only reads `net` in **Step 0, which skips common words** — so for "okay" the history is written and never read. **The nag is structural, by design omission.**

### 2.3 What the keyboard actually asks
The keyboard does **not** run the gate. The main app computes asks after save and mirrors them via App Group:

- `CorrectionAsksPublisher.publish()` (`Jot/App/Vocabulary/CorrectionAsksPublisher.swift:14-78`):
  - candidate filter (`:46-48`): `outcome == "applied" || prior > 0 || unsure`, where `prior` = `CorrectionStore` net for the pair (`:31-38`).
  - ranks by `prior` desc, takes top `maxAsks = 3`, publishes `CorrectionBridge.Asks`, posts `correctionAsksReady`.
  - **When there are no asks → `clearAsks()` and returns WITHOUT posting any signal** (`:25-28`, `:59-62`). ← critical for Thread 2.
- `CorrectionBridge` (`Jot/Shared/CorrectionBridge.swift`): App-Group JSON at key `jot.correction.asks`; keyboard reads (`readAsks(sessionID:)` / `readLatestAsks()`), enqueues verdicts back (`enqueueVerdict`), app drains via `CorrectionInbox` on next foreground.

**Why "okay" still leaks through to the keyboard:** after rejections, `prior` (net) goes negative, and `outcome` is `"kept"` (blocked, not applied) — but if the gate marked the proposal `unsure`, the `|| unsure` clause still selects it (`:47`). So a heavily-rejected common-word pair keeps being published as a keyboard ask. **`CorrectionAsksPublisher` never consults `reverts`/`net <= 0` or `suppressedBlocks` to drop a pair.** That's the Thread-1 leak.

**Transcript review is a separate path:** the main-app review pane reads `CorrectionProvenance` (all unresolved proposals), independent of `CorrectionAsksPublisher`. The publisher's own doc comment confirms the intended split: *"Asks decay to zero as the system learns — confident one-off decisions are reviewable only on the transcript"* (`:8-9`). **This is exactly the keyboard-suppress / transcript-keep split the owner wants — the architecture already separates the two surfaces; we just need to make the keyboard publisher honor the learned rejections.**

### 2.4 The paste path & the structural race (Thread 2)
`DictationPipeline` publish order (`Jot/App/Intents/DictationPipeline.swift`):

- **Step A (`:361-369`)** — `ClipboardHandoff.publish(...)` writes the paste payload FIRST and wakes the keyboard's `flushPendingAutoPasteIfPossible` (comment `:361-363`: "publish FIRST … the ledger row … must not gate it").
- `transcriptReady` posted (`:380`).
- **Step B (`:417-441`)** — ledger append → `CorrectionProvenance.commit` (`:429`) → `CorrectionAsksPublisher.publish` (`:432`).

So **asks are published *after* the paste payload that triggers the keyboard.** Today's "paste-first, ask-after" is a direct consequence of this ordering, not an accident. The keyboard's post-paste nudge (`JotKeyboardViewController.swift:1550` `maybeShowCorrectionNudge`) fires on the later `correctionAsksReady`.

**The single proven paste path** (the one that survives Slack / Claude Code / Gemini, hardened over ~1 month): `flushPendingAutoPasteIfPossible (:1301) → performInsertAndVerify → insertTrackedText (:1433)` with the `adjustTextPosition(0)` re-sync. Note the code **already anticipates** converging on this: `:353-356` — *"The root-decoupling refactor will isolate the field and let us delete this and reach a true single paste path."* The in-Jot transient stop uses a **different** deliverer (in-process `FocusedFieldInsert`, `:390`) and clears the pending paste session first (`:357-359`) — so **the card deck is scoped to the non-transient, other-app keyboard path only.**

---

## 3. Assumptions

- A1. The owner rejects "okay→Okta" ~99% of the time (confirmed). The fix targets the **repeated-rejection** case (not repeated-confirm).
- A2. Genuine "Okta" dictation already resolves correctly without asking (owner confirmed) — there is **no** auto-swap-of-okay bug to chase.
- A3. `CorrectionAsksPublisher` is the **only** feeder of keyboard asks; the transcript review reads provenance directly. (Confirmed in code §2.3.) Therefore suppression in the publisher = keyboard-only, transcript untouched.
- A4. None of the touched stores are SwiftData `@Model` types — `CorrectionStore`/`CorrectionBridge`/`CorrectionProvenance` are JSON (App Support / App Group). **→ No schema impact** (see §8).
- A5. Asks computation (`CorrectionAsksPublisher.publish`) is cheap (filtering provenance + slicing context snippets) — the expensive vocab CTC inference already ran during rescore. So reordering it before the handoff adds little latency. **(Verify with a timing log during implementation.)**

---

## 4. Thread 1 — Fewer asks (design) — REVISED post design-review

### 4.0 Why the first draft's lever doesn't fire (design-review MUST/SHOULD-3)
The original plan was "suppress when `net <= -2`." **The verdict math makes that never trip for the exact poster-child case.** A *common* word is BLOCKED ("kept") by Step 4 (`VocabularyGate.swift:269`). When the owner taps "keep original" on a **kept** ask, `CorrectionProvenance.desiredContribution` returns **0** — `anyDemote` requires `outcome=="applied"` (`CorrectionProvenance.swift:305-311`). So rejecting "okay→Okta" 20 times moves `net` by **nothing**. Relying on `net` would silently never suppress "okay." Confirmed against code.

Also confirmed (MUST-1): `CorrectionStore.suppressedBlocks` / `isBlockSuppressed` (`CorrectionStore.swift:70-73,113-121`) currently has **zero readers anywhere** — the transcript review (`CorrectionReviewModel.swift:30-53`) derives everything from `payload.verdicts` and ignores suppression. So **reading suppression in the publisher is automatically keyboard-only** — the feared `keyboardSuppressed` flag is unnecessary, and "Stop asking" finally gives that dead state a reader.

### 4.1 The fix (revised)
Two suppression signals, both honored only by `CorrectionAsksPublisher` (the keyboard feed):

1. **Automatic — explicit keyboard-reject counter (delivers the "I shouldn't have to do anything" intent).** Add a per-pair `keyboardKeeps` counter to `CorrectionStore` that increments when a keyboard verdict is "keep original" on a **kept/blocked** ask (the path `net` ignores). Suppress the pair from keyboard asks once `keyboardKeeps >= rejectThreshold` (default **2**). This is a NEW counter, distinct from `net`, precisely because `net` doesn't move for kept pairs.
2. **Manual — one-tap "Stop asking"** on the card → writes `CorrectionStore.suppressBlock(pair)` (instant hard suppress; gives the dead `suppressedBlocks` a reader).

Pseudo (publisher candidate filter, replacing `CorrectionAsksPublisher.swift:46-48`):
```
keyboardSuppressed(pair) =  correctionStore.keyboardKeeps(pair) >= rejectThreshold   // auto, NEW counter
                         || correctionStore.isSuppressedBlock(pair)                  // manual "Stop asking"
candidates = unresolved.filter { r in
    !keyboardSuppressed(r) && ( r.outcome == "applied" || prior(r) > 0 || r.unsure )
}
```
- `keyboardKeeps` increments in the verdict-drain path (`CorrectionInbox`) when `verdict == "original"` AND the ask's `outcome == "kept"`. (For `outcome=="applied"` keeps, the existing `revert`/`net` path already handles it — leave it.)
- `rejectThreshold = 2`, a named constant. **Keyboard-only scope de-risks it:** worst case a too-eager suppress just means the pair is reviewed on the transcript instead — never silent data loss.

### 4.2 What we deliberately do NOT change
- Step 4 common-word guard stays — common words still never silently auto-swap.
- The transcript review keeps surfacing every unresolved proposal (verdict-driven, ignores suppression — confirmed §4.0).

### 4.3 Critical-thinking / pushback
- **Publisher layer vs tightening plausibility:** tightening Step-1 plausibility so "okay~Okta" never becomes a candidate is *proactive* but *global* (regresses other users). The learn-from-keeps fix is *reactive* but *user-specific and safe*. Chosen: learn-from-keeps. Plausibility tightening noted as a future additive lever only.
- **Is the auto counter worth it, or is "Stop asking" enough?** The owner's frustration ("I said it 20 times") is explicitly *"I shouldn't have to do anything."* So we keep BOTH: the auto counter for hands-off relief + the manual button for instant. (If we later find the auto counter noisy, the button alone is the safe floor.)

---

## 5. Thread 2 — Ask-before-paste (design)

### 5.1 The core problem to solve
The keyboard auto-pastes off the **clipboard handoff**, which today lands **before** asks exist (§2.4). To "ask before paste" we must guarantee the keyboard knows the ask set **at the moment it decides whether to paste**, without (a) forking the proven insert path per host, or (b) ever pasting-then-discovering-an-ask, or (c) ever losing the text.

### 5.2 Options explored

**Option A — Reorder the pipeline so asks are published before the handoff (RECOMMENDED).**
Move `CorrectionProvenance.commit` + `CorrectionAsksPublisher.publish` to **before** `ClipboardHandoff.publish` (Step A). Keep the heavy/throwable **ledger append last** (it still must not gate paste). Then the keyboard, when woken by the handoff, **synchronously reads the matching-session asks** (already present in the App Group) and decides hold-vs-paste with **zero race and no new signal**.
- Pros: removes the race *by construction*; no timeout on the common no-asks path; no new cross-process signal; aligns with the codebase's stated "single paste path" direction.
- Cons: paste now waits on asks computation (cheap per A5) + provenance commit; needs provenance commit decoupled from ledger append (provenance is keyed by the `transcriptID` UUID generated at `:341`, independent of the SwiftData row, so this is mechanically fine — **verify**).

**Option B — Keep ordering; add an always-fire "asks decided (count N≥0)" signal + keyboard bounded-wait.**
Publisher always posts a completion signal (including zero); keyboard flush waits (bounded, piggybacked on its existing stable-connection poll `:1389-1432`) before pasting.
- Pros: smaller pipeline change.
- Cons: more moving parts; adds latency to the *common* no-asks path (must wait out the timeout unless the zero-signal arrives fast); a timeout is a papering-over vs a structural fix. Less maintainable.

**Option C — Speculative paste + retract on correction. REJECTED.**
The entire point is to avoid landing wrong text that is hard to retract across fancy hosts (Slack/Claude/Gemini). Retraction is exactly the month-long problem we refuse to re-open.

### 5.3 Option selected: **A (NARROWED reorder)**, with the keyboard gate in front of the single insert path.

**The reorder is narrower than the first draft (design-review MUST-3).** Do NOT move `CorrectionAsksPublisher.publish` wholesale — it `await`s two actor hops (incl. a first-time `corrections.json` decode, `CorrectionStore.swift:154-163`) and posts the `correctionAsksReady` Darwin notification (`:73`). Moving all of that ahead of the paste could (a) stall the paste and (b) fire the ready-nudge before the paste lands. Split it: move only the **provenance commit + the asks DATA write**, keep the notification where it is, and add a **timeout-degrade** so asks computation can never gate the paste.

Pipeline (reordered) pseudo — replacing the §2.4 A/B order:
```
// after rescore/cleanup, transcriptID known
if !transient {                                   // transient publishes NO asks (never saves) — keep this gate
    commit provenance(transcriptID)               // moved earlier; UUID-keyed, idempotent, non-persisting (verified)
    try? withTimeBudget(budgetMs) {               // DEGRADE: on overrun → zero asks → paste-now/nudge-after (today)
        asks = computeAsks(transcriptID, sessionID, publishedText)   // filter only; no inference
        CorrectionBridge.publishAsks(asks)        // DATA only → readAsks(sessionID:) populated. NO correctionAsksReady here.
    }
}
ClipboardHandoff.publish(publishedText, sessionID, transcriptID)   // wakes keyboard; asks already readable for this session
post(transcriptReady)
if !transient { try ledgerAppend(...) }           // heavy/throwable; still LAST; still does NOT gate paste
// correctionAsksReady stays as the LEGACY post-paste nudge trigger for non-deck hosts; gate so it can't precede paste
```
- `computeAsks`/`publishAsks` must not throw/hang onto the paste path — on time-budget overrun, degrade to zero-asks rather than delay `ClipboardHandoff.publish`. Confirm `budgetMs` headroom with the A5 timing log.
- New silent-loss note (SHOULD-4): an ask whose later `ledgerAppend` throws → its keyboard verdict is dropped on drain (`CorrectionInbox` skips when the transcript row is missing). Acceptable (append-throw is the rare degraded path); documented, not fixed.

Keyboard gate pseudo — **in front of** the existing `flushPendingAutoPasteIfPossible`, never forking it:
```
flushPendingAutoPasteIfPossible():
    payload = ClipboardHandoff.readFresh()                 // existing
    guard session valid                                    // existing
    asks = CorrectionBridge.readAsks(sessionID: payload.session)   // SESSION-FILTERED ONLY — never readLatestAsks (RACE-1)
    if asks == nil || asks.isEmpty:
        insertVerified(text: payload.text, session: payload.session)   // EXACTLY today's path — no change
        return
    stagedButNotInserted = true                            // INV-1 flag (see §5.5)
    suppressReadyNudge(forSession: payload.session)        // legacy correctionAsksReady must not nudge over the deck
    presentCardDeck(asks) { resolvedVerdicts in
        finalText = applyVerdicts(payload.text, resolvedVerdicts)   // splice by offset, with guard (§5.6)
        insertVerified(text: finalText, session: payload.session)   // SAME proven path, once, for every host
        stagedButNotInserted = false
    }
```
- `insertVerified(text:session:)` = the existing `performInsertAndVerify` **hoisted out of its nested closure into a reusable method** (design-review NICE-2). Today it is a local closure baking in `pasteText = payload.text` (`JotKeyboardViewController.swift:1392,1403`); hoisting it is what keeps INV-2's single insert path real, and it is the largest hidden implementation cost (the same "root-decoupling → true single paste path" work the code defers at `:353-356`). **Prerequisite — do it first in Phase 2.**

### 5.4 Card deck behavior (owner-specified, UX-confirmed)
- ≤3 cards (matches `maxAsks=3`), one per ask, shown **inside the keyboard** (the existing 129pt strip slot — §7).
- Per-card **idle countdown = 10s** (22pt depleting ring, top-right — §7).
- **Interact** (pick term / keep original / "Stop asking") → enqueue verdict (`CorrectionBridge.enqueueVerdict`), advance to next card, **reset timer**, set `hasEngaged = true`.
- **Idle timeout — branches on `hasEngaged` (UX-Q2 resolved):**
  - First card, **zero engagement** → **paste ALL defaults + dismiss the whole deck** (don't march the user through 3×10s they're ignoring).
  - After ≥1 engagement → per-card **skip** (use that occurrence's default), show next.
- After last card resolved/skipped → `applyVerdicts` → single `insertVerified`. Done-state dwell **shortened to ~0.8–1.0s** (the user is waiting for the paste — the shipped 2.2s teach-card dwell is too long when it gates the paste; UX §7f).

### 5.5 Invariants (must hold) — INV-1 made concrete (design-review MUST-2)
- **INV-1 (never lose text):** the staged text is ALWAYS eventually inserted. **The hazard:** today insert happens *before* the in-flight window opens, so `viewWillDisappear` (`JotKeyboardViewController.swift:430-449`) safely assumes "window open ⇒ already inserted" and consumes (`markConsumed` + `clearPendingPasteSession`). The deck **inverts** this — during the deck nothing is inserted yet, so the existing consume-on-teardown would **drop** the text. **Mechanism:** an explicit `stagedButNotInserted` flag the teardown path checks:
  - teardown/app-switch mid-deck **with a live proxy** → run `applyVerdicts(defaults) + insertVerified` synchronously before dismiss;
  - teardown **with a detached proxy** (insert unreliable) → **leave the pending session + payload INTACT (do NOT consume)** so the next flush re-pastes — safe from double-paste *because* `stagedButNotInserted == true` means no prior insert exists to duplicate (this is the only thing that reconciles INV-1 with the build-103-106 anti-double-paste consume). Clipboard floor remains the last resort.
- **INV-2 (single insert path):** every host goes through the hoisted `insertVerified(text:session:)` exactly once. The gate changes only *when* and *with what text*. (Requires the closure→method hoist, §5.3.)
- **INV-3 (no race):** the keyboard reads `readAsks(sessionID:)` (session-filtered, never `readLatestAsks`) and never inserts before it has the ask set for THIS session (Option A ordering + RACE-1 fix).

### 5.6 Splicing on the keyboard side — by offset, with a fail-safe guard
`applyVerdicts` rewrites the staged text at the corrected occurrence, but `CorrectionBridge.Ask` (`CorrectionBridge.swift:20-27`) has **no offset**. Decision:
- Extend `Ask` with `publishedStart`/`publishedLength` from the provenance `Record` (`CorrectionProvenance.swift:45-46`; publisher maps into `publishedText` at `CorrectionAsksPublisher.swift:22-23,89-90`).
- **Back-compat (design-review NICE-1):** `Ask` uses *synthesized* Codable — a non-optional new field hard-fails decode of a pre-upgrade blob. Make the new fields **`Int?`** (or give `Ask` a hand-written `init(from:)` with `decodeIfPresent`), exactly the `totalUnresolved` pattern but applied to `Ask` itself (not just the `Asks` wrapper).
- **Offset-baseline guard (design-review SHOULD-2):** the offsets are valid only if the keyboard splices into the *same* string the publisher measured. Today `payload.text === publishedText` (same variable), but it's undocumented coupling. Guard: if the substring at `publishedStart..<+Length` doesn't equal `original` (or `term`), **fall back to paste-defaults — never splice blind.** A single off-by-one corrupting pasted text is strictly worse than today.

### 5.7 UX questions — RESOLVED by the front-end review (§7)
- UX-Q1 → card = the existing 129pt strip slot, **zero height change** (respects `expandedHeight=200`, `JotKeyboardViewController.swift:100`).
- UX-Q2 → first-card zero-engagement = paste-all-defaults + dismiss; per-card skip only after engagement (folded into §5.4).
- UX-Q3 → fork the **already-shipped `CorrectionReviewStrip`** (it's ~90% this) + add the ring + present-tense copy (§7).

---

## 6. Implementation plan (concrete, sequenced — pseudo only)

> Each numbered item is implemented, then **adversarially reviewed individually**, and only merged if the review is clean (owner process, §9).

**Phase 1 — Thread 1 (fewer asks):**
1. Add a per-pair `keyboardKeeps` counter to `CorrectionStore` + an `isKeyboardSuppressed(pair)` (counter≥`rejectThreshold` OR `isBlockSuppressed`). Add the `keyboardSuppressed` filter to `CorrectionAsksPublisher` candidate selection (§4.1). (No `keyboardSuppressed`-flag worry — `suppressedBlocks` has no other readers, confirmed §4.0.)
2. Increment `keyboardKeeps` in `CorrectionInbox` drain when `verdict=="original"` on a **kept** ask (the path `net` ignores). Wire "Stop asking" → `CorrectionStore.suppressBlock`.
3. Update `features.md` §8.x (vocab) for the new keyboard suppression behavior; extend the `CorrectionAsksPublisher.swift:8-9` doc-comment to mention rejection-suppression (§10).

**Phase 2 — Thread 2 (ask-before-paste):**
4. **Prerequisite hoist:** lift `performInsertAndVerify` out of its nested closure into `insertVerified(text:session:)` (§5.3, NICE-2) — keeps INV-2's single path real. Adversarial-review this *alone* (it touches the hardened paste path) before building on it.
5. Extend `CorrectionBridge.Ask` with **optional** `publishedStart/publishedLength` + the offset-baseline guard (§5.6).
6. Narrowed `DictationPipeline` reorder: commit + asks-DATA write before `ClipboardHandoff.publish`, with time-budget degrade; keep `correctionAsksReady` from preceding paste; ledger append stays last (§5.3). Add the A5 timing log.
7. Keyboard gate in front of `flushPendingAutoPasteIfPossible`: `readAsks(sessionID:)`-only, `stagedButNotInserted` flag + teardown reconciliation, `applyVerdicts` splice, card-deck controller honoring INV-1/2/3 (§5.3-5.6).
8. Build the card-deck UI as a **paste-holding fork of `CorrectionReviewStrip`** + 22pt countdown ring + present-tense copy (§7). Slot it above `showCorrectionNudge` in `KeyboardView.topStrip` (`:303-331`).
9. Update `features.md` §5.x (keyboard) + §8.x; pair `ARCHITECTURE.md` only if a boundary/invariant changed (the reorder changes the pipeline ordering contract — likely a one-line note).

---

## 7. Front-end / UX spec (front-end review — adopted)

**Headline: do not build a new surface — fork the already-shipped `CorrectionReviewStrip`** (`Jot/Keyboard/CorrectionReviewStrip.swift`). It is already a per-ask card deck: `.nudge→.review→.done` stage machine, one card per ask, heard-vs-term chips, serif context line, "Skip", "N of M" counter, 10s auto-dismiss, and the full keyboard glass recipe. It is currently **teach-only / post-paste** (header doc `:13-15`: "never edits the host app's already-pasted text"). The new deck is the **pre-paste, paste-holding** variant: same visuals, different timing + consequence (verdicts splice the staged text).

**(a) Placement — zero height change.** The card IS the existing 129pt top strip slot. Keyboard height is a hard 200pt: `expandedHeight=200` (`JotKeyboardViewController.swift:100`) pinned at 999-priority (`:573`), mirrored by `KeyboardView .frame(minHeight:200)` under the CRITICAL INVARIANT comment (`KeyboardView.swift:176-189`) — the two MUST stay equal or bottom controls clip. Every strip variant is pinned to exactly 129pt (`RecentsStrip.swift:308-310`, `CorrectionReviewStrip.swift:38`, etc.), chosen by the mutually-exclusive `if/else` chain in `topStrip` (`KeyboardView.swift:303-331`). **Add the deck as the top branch of that chain, above `showCorrectionNudge`.** Controls row stays mounted underneath (don't look "taken over").

**(b) Card layout (the 129pt glass strip):** header context line (Fraunces italic, muted before/after, gated word in `jotKeyboardKeyInk` + dashed underline — reuse `spokenLine(for:)` `:252-269`) with the **countdown ring at its trailing/top-right** (empty space → no added height); spacer; actions row = `okay` "keep original" chip + `Okta` "use term" chip + "Stop asking" (replaces "Skip" slot `:226-232`) + "N of M" counter (`:222-237`). Drop the "IN TEXT" badge (nothing's in text yet, pre-paste). Cap the context line to 2 lines + `minimumScaleFactor(0.85)` so a long snippet shrinks, never grows the card (the one fit risk).

**(c) Countdown ring:** 22pt, top-right, depleting clockwise. Track = `jotKeyboardGlassHairline` 2pt (`JotDesign.swift:183`); arc = `.trim` in `jotKeyboardAccentDeep` (`:203`, brand blue, in-language). `.linear(duration: remaining)`; **Reduce Motion → static full ring, no sweep** (match existing `reduceMotion` gating `CorrectionReviewStrip.swift:79`). No digits inside (expose seconds via `.accessibilityValue`). Restart per card via `.id(index)` (`:243`) + the existing `Task.sleep` pattern (`:169-172,280-283`).

**(d) Tokens/components to reuse (cite):** glass envelope `glassSurface` (`:386-400`), `Stage`/`advance()`/`.id(index)` (`:40-110,243`), `wordChip` (`:271-317`), `PressButton` (`:405-423`), `doneStage` (`:321-349`); tokens `jotKeyboardGlassFill1/2`, `…GlassHighlight/Hairline`, `jotKeyboardAccentDeep`, `jotKeyboardKeyInk/KeyFill`, `JotType.frauncesItalicText`. **Keyboard can't link app-only `JotDesign.Surface.key`** — for any dismiss chrome use the keyboard's `jotKeyboardKeyFill` capsule (`:155-159`), never ad-hoc `.ultraThinMaterial` circles (the card *background* legitimately uses the shared glass `ultraThinMaterial` recipe). **Light theme works by construction** (all tokens are adaptive pairs with explicit light values; `KeyboardView` forces `effectiveColorScheme` `:175`). Owner prefers light → verified fine.

**(e) Microcopy (instructional, present-tense — text isn't pasted yet):** chips = the term/heard word + captions "use term" / "keep original"; "Stop asking" (a11y hint: *"Jot won't ask about "{original}" again. You can still review it on the transcript in Jot."* — encodes the keyboard-suppress/transcript-keep split); resolved feedback = `"{term}" added.` / `"{original}" kept.`; done = **"All set."** + (if N>0) reuse the "{N} more guess(es) on the transcript in Jot." line (`:331-339`); **shorten the done dwell to ~0.8–1.0s** (the 2.2s `:344-347` is too long when it gates the paste).

**(f) UX-Q2 (adopted):** first-card zero-engagement → paste all defaults + dismiss; per-card skip only after ≥1 engagement; also paste-defaults on teardown/app-switch mid-deck (ties to INV-1, §5.5). No visible banner on skip-all (a banner is itself a nag).

---

## 8. Schema impact
**None.** No `@Model`/SwiftData types are added, removed, or renamed. All touched state is JSON: `CorrectionStore` (App Support `corrections.json`), `CorrectionBridge` (App Group `jot.correction.asks` / `jot.correction.verdicts`), `CorrectionProvenance` (App Support JSON). The `CorrectionBridge.Ask` field addition (§5.6) is JSON, optional-decoded for back-compat.

---

## 9. Rollout / process (owner directives)
- **Reviews before code:** this doc → `/design-review` (architecture/correctness) + the §7 UX review. Resolve findings (critically, not blindly) before implementing.
- **Per-step adversarial review:** every numbered item in §6 is adversarially reviewed *individually*; implement only if clean.
- **Sequence:** Thread 1 (Phase 1) first, then Thread 2 (Phase 2).
- **Ship a new build when done:** current is **1.0.5 / build 148** (submitted to App Store), so a TestFlight build must use a **new number** (≥ **149**; decide 1.0.5/149 vs 1.0.6/149 at ship time). Deploy only on explicit "ship it".

---

## 10. Doc-quality notes found while reading
- `DictationPipeline.swift:353-356` already flags the "root-decoupling → true single paste path" intent; Thread 2's gate (esp. the `insertVerified` hoist) is a concrete step toward it — cross-reference it there in a comment when we touch it.
- `CorrectionAsksPublisher.swift:8-9` documents the keyboard-vs-transcript decay split clearly — extend it to mention the new rejection-suppression so the split stays self-documenting.
- `CorrectionStore.suppressedBlocks`/`isBlockSuppressed`/`suppressBlock` is currently **dead write-only state** (no readers, §4.0). Phase-1 item 2 gives it its first reader ("Stop asking"); if we don't, consider deleting it.

---

## 11. Design-review + UX-review outcomes (2026-06-18)

Both reviews verified every claim against code. Findings I ACCEPTED and folded in:

| # | Severity | Finding | Resolution (section) |
|---|----------|---------|----------------------|
| MUST-1 | – | `suppressedBlocks` has **no readers**; transcript pane is verdict-driven and ignores suppression | Keyboard-only suppression is automatic; dropped the `keyboardSuppressed`-flag worry (§4.0) |
| MUST-2 | High | Card-deck hold **inverts** the insert order → existing consume-on-teardown **drops text** | `stagedButNotInserted` flag + teardown reconciliation with anti-double-paste (§5.5 INV-1) |
| MUST-3 | High | Moving full `publish` ahead of paste can stall paste + fire ready-nudge pre-paste | **Narrowed reorder**: move commit + asks-DATA only, keep notification, time-budget degrade (§5.3) |
| SHOULD-3 | High | Verdict math: "keep" on a **kept** common word ⇒ `desiredContribution==0` ⇒ `net` never moves ⇒ `net<=-2` lever **never fires for "okay"** | Replaced with an **explicit `keyboardKeeps` counter** + "Stop asking" as primary (§4.0-4.1) |
| SHOULD-1 | High | `readLatestAsks()` not session-filtered (RACE-1) | Deck uses `readAsks(sessionID:)` only; suppress ready-nudge during deck (§5.3, §5.5 INV-3) |
| SHOULD-2 | Med-High | Splice offset valid only if keyboard text === publisher's `publishedText` | Offset-baseline guard → fall back to defaults on mismatch, never splice blind (§5.6) |
| SHOULD-4 | High | `publish` is inside `!transient` + the append `do`; reordered, an append-throw orphans the verdict | Keep `!transient` gate; documented as acceptable rare degraded path (§5.3) |
| NICE-1 | High | `Ask` uses synthesized Codable → non-optional new field hard-fails upgrade decode | New offset fields are **`Int?`** / hand-written init (§5.6) |
| NICE-2 | High | `performInsertAndVerify` is a nested closure baking in `payload.text` → can't be reused for post-deck insert without a second path | **Hoist to `insertVerified(text:session:)`** as a Phase-2 prerequisite (§5.3, §6 item 4) |
| UX | – | Feature is ~90% the shipped `CorrectionReviewStrip`; fits the 129pt slot with zero height change | Fork it; placement + tokens + copy specced (§7) |
| UX-Q2 | – | First-card idle behavior | Paste-all-defaults + dismiss; per-card skip only after engagement (§5.4) |

Rejected / not adopted: Option B (timeout band-aid) and Option C (speculative paste) — see §5.2. No other findings outstanding; ready for implementation per §6.
