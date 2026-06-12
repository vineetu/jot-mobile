# Correction Review — Surface Parity Contract

The correction-review feature renders on TWO surfaces: the **transcript pane**
(summary card + accordion + in-text marks/bubble: `App/Vocabulary/CorrectionReviewSection.swift`,
`MarkedTranscriptText.swift`, `CorrectionReviewModel.swift`) and the **keyboard strip**
(`Keyboard/CorrectionReviewStrip.swift`, asks selected by `App/Vocabulary/CorrectionAsksPublisher.swift`).

This doc is the **parity contract**: for every user-noticeable dimension it records
whether the two surfaces must be IDENTICAL (**COMMON**) or are deliberately different
(**DIVERGENT**, with the reason). Any future change to one surface must check this
list and update the twin (or this doc).

Status legend: ✅ already matches · 🔧 mismatch, to fix · 🟡 owner decision pending.

## 1. Copy (must read as one voice)

| Moment | Pane | Keyboard | Contract |
|---|---|---|---|
| Guess count headline | "Jot guessed on N word(s)." | same string | **COMMON** ✅ wording — but see §3 for which N (currently 🔧 mismatched) |
| Resolved verdict line | terse: `X confirmed.` / `X applied here.` / `X restored.` / `X kept.` | terse, same set | **COMMON** ✅ (fixed 2026-06-11 — chatty "Jot's learning it" narrative removed). One deliberate word: pane says "applied **here**" (it edits on the spot); keyboard drops "here" (its edit lands in Jot later). |
| Done headline (keyboard) | n/a (summary flips to "All reviewed") | "All reviewed." | **COMMON** ✅ same phrase as the pane's done state (was "Done — Jot's learning your voice.", removed 2026-06-11) |
| Handoff line (keyboard done) | n/a | "N more guesses are on the transcript in Jot." | **DIVERGENT** — keyboard-only by nature; pane IS the destination |
| Chip tag | "IN TEXT" | "IN TEXT" | **COMMON** ✅ |
| Action hint | "Tap the word you meant." + "Tap an underlined word — or review them all here." | none (chips + Skip are self-evident) | **DIVERGENT** — strip has no room; guided one-at-a-time flow needs no hint |
| Badge + original label | `CHANGED`/`KEPT` badge + `Original "X"` | neither | 🟡 **owner call** — keyboard context line + IN-TEXT tag carry most of this; adding the badge costs vertical space in the 129pt strip |

## 2. Verdict semantics (must behave as one feature)

| Dimension | Pane | Keyboard | Contract |
|---|---|---|---|
| Choices | original + term chips, original first | same | **COMMON** ✅ |
| What a pick does | edits transcript text NOW + blue flash + learning now | enqueues verdict; app applies text edit + learning on next foreground (teach-only — keyboard never edits host text) | **DIVERGENT** — hard constraint (extension can't safely edit). Copy must never promise an immediate edit on the keyboard (hence no "here"). |
| Undo | every resolved row, forever | none | **DIVERGENT** — teach-only strip; undo lives in the pane. The pane's Undo also reverses keyboard-given verdicts once drained, so nothing is irreversible. |
| Skip | none (just don't tap) | Skip button per ask | **DIVERGENT** — required by the one-at-a-time flow |
| Verdict dwell | 1.3 s (bubble) | 0.95 s | 🟡 near-parity; unify at ~1.1 s or leave — not user-confusing |

## 3. Which corrections are shown ← the real confusion source

| Dimension | Pane | Keyboard | Contract |
|---|---|---|---|
| Coverage | ALL unresolved occurrences | top ≤3 by policy (`applied ∨ prior>0 ∨ unsure`, sorted by prior) | **DIVERGENT** — strip is a quick pass, pane is the full ledger. Fine. |
| Headline count N | total records | `asks.count` (≤3) | 🔧 **COMMON required** — the same sentence must never quote two different numbers. Fix: keyboard nudge uses `totalUnresolved` (already in the payload); review stage keeps "1 of asks.count". |
| "N more" remaining | live `unresolvedCount` | `totalUnresolved − verdictsGiven` (snapshot — goes stale if user resolves in-app meanwhile) | 🟡 acceptable staleness window is seconds; revisit only if observed |

## 4. Context line (the "what you said" snippet)

| Dimension | Pane (accordion row) | Keyboard | Contract |
|---|---|---|---|
| Present on unresolved | yes (since 117) | yes | **COMMON** ✅ |
| Window | ±28 chars, live-resolved | ±24 chars, snapshot at publish | 🔧 **COMMON** — unify at ±28; snapshot vs live stays divergent (keyboard has no live text) |
| Font | Fraunces italic 14 | Fraunces italic 15.5 | **DIVERGENT** — each surface's own type scale |
| Gated word | dash-underlined, primary ink | dash-underlined, key ink | **COMMON** ✅ treatment; tokens map per-surface |
| Missing-context fallback | line silently absent if span can't strict-resolve (hand-edited body) | n/a (snapshot always present) | 🟡 pane gap — a row with no context is unidentifiable among repeats; consider falling back to the publish-time snapshot |
| Resolved rows | no context line | n/a (resolved asks advance away) | 🟡 owner call — probably fine |

## 5. Visual language

| Dimension | Pane | Keyboard | Contract |
|---|---|---|---|
| Surface recipe | `--card` white@78%/6% + hairline, r22 | Liquid Glass keyboard recipe, r20 | **DIVERGENT** — surfaces live in different material worlds by design |
| Chip shape | capsule, 15.5 semibold, no mid-word wrap (ViewThatFits stack) | capsule, 15 semibold, no mid-word wrap (scaleFactor 0.75) | **COMMON** ✅ in treatment; size per-surface |
| Progress | "Show N more" expansion | "1 of 3" counter | **DIVERGENT** — list vs guided flow |

## 6. Open fixes queued from this contract

1. 🔧 Keyboard nudge headline → `totalUnresolved` (§3).
2. 🔧 Keyboard context window 24 → 28 (`CorrectionAsksPublisher.contextWindow`) (§4).
3. 🟡 Pane context fallback to publish-time snippet when strict-resolve fails (§4).
4. 🟡 Badge/`Original "X"` on keyboard — owner decision (§1).
5. 🟡 Dwell unification 0.95/1.3 s — owner decision (§2).

Done 2026-06-11: chatty keyboard resolved-copy + done-headline removed (§1).
