# Jot UX Overhaul — Round 2 · Requirements (Source Intent)

> This is the **initial request** that started Round 2, preserved verbatim-in-substance, plus the decisions made while turning it into a plan. The implementation plan lives in `ux-overhaul-round2.md`; this file is the *why/what-was-asked* so the UX can be changed later without losing the original intent.

---

## 1. The initial request (UX review — "Features That Would Change")

**Scope as given:** features the design review + follow-up decisions would alter. "Let's not focus on the wizard for now. But I would like to work on the rest."

**Headline decisions (as stated):**
- **Streaming stays** — capped, *italic*, slowly fading (Anthropic-2026 pattern): hero ~3.5 lines, keyboard ~2.5–3.5 lines (down from ~7). Home preview left as-is for now.
- **Italic = streaming only.** Final/saved transcript text is **not** italic (regular); the featured entry stays slightly larger.
- **In-app dictation is always inline** — it never opens the hero and **pastes into the field instead of saving a transcript**. The hero is only for targetless capture (home Dictate button + the keyboard foregrounding Jot from another app).
- **Help keeps its feature education;** onboarding *also* educates, but ultra-simple and visual.
- The keyboard is **recording-controls-only** except the system keys Apple fixes at the bottom (globe, etc.). The hide/show button is dropped.

**Cross-cutting asks:**
- **C1 — Cap the live streaming transcript (don't cut it):** italic, slowly fading. Hero ~3.5 lines; keyboard ~2.5–3.5 (down from ~7). Home preview unchanged.
- **C1b — Italic = streaming only:** final/saved text becomes regular everywhere.
- **C2 — Brand mark:** "J + recording dot" merged with the mic glyph. *(Deferred — not this cycle.)*
- **C3 — Educate in BOTH Help and onboarding.** *(Wizard/onboarding parked.)*
- **C4 — Keyboard = recording controls + system keys.** No custom typing keys; one adaptive Enter (return-arrow / search glyph / Go / Send by context); side spacing (~0.4cm); consistent height; fit in one line.
- **C5 — Adaptive, rotating micro-messages** on Home, hero top space, warm-hold prompt.
- **C6 — In-app dictation is inline; the hero is only for targetless capture.** Edit dictation must record in place, paste into the field, save no separate transcript.

**Per-surface asks (as given):**
- **§1.1** drop "Recents." headline → a "What do you want to dictate today?" CTA + adaptive micro-messaging.
- **§1.2** featured entry: drop the "Latest" label and the italic (render regular); keep it slightly larger.
- **§1.9** replace the "JS" avatar with a bigger gear, light/dark aware.
- **§1.10 / §1.11** keep home→hero from the Dictate button; make multi-select discoverable from the swipe gesture.
- **§2.2 / §2.3 / §2.4** hero: keep a timer/indicator, **remove the waveform**, cap the live transcript to ~3–3.5 italic lines anchored at the bottom, older text scrolling up + fading; freed top space carries rotating micro-messages. Keyboard-initiated hero delays streaming (~10s) to encourage swipe-back.
- **§2.x** add **Pause/Resume** (hero + keyboard); pause does not finalize.
- **§2.6** Cancel = trash-can icon on the keyboard (left), "Cancel" label on hero.
- **§3.5** rename "Transform" → "Articulate"; primary clean-up "Cleanup"; bigger / user-resizable AI panel **only if the drag is smooth**.
- **§3.7** Edit dictation records inline (per C6).
- **§5.1 / §5.4 / §5.8 / §5.10 / §5.12** keyboard: remove spacebar + "return to Jot" + minimize/expand + char-key preview; adaptive Enter; trash-Cancel on the left; native side spacing; consistent height; keep Actions popover.
- **§9** Help keeps its feature education.
- **R1** keyboard crash safety — recover in-progress text. *(Parked — "talk later.")*

**Validated / keep as-is:** blue palette (light/dark), Send Feedback, Combine, swipe-to-delete (needs discoverability), Actions popover, consistent keyboard height.

---

## 2. Scope decisions

- **In scope:** WS-A streaming/italic, WS-B inline dictation, WS-C hero cleanup + Pause, WS-D keyboard restructure, WS-E home polish, WS-F micro-messaging + warm-hold nudge, WS-G detail panel.
- **Parked:** the setup wizard (C3 onboarding, §4.x) and R1 keyboard crash recovery.
- **Implementation priority (user, this round):** get the **functional/structural** changes in; the **visual UX is intentionally left adjustable** for later tuning.

---

## 3. Decision log (made during brainstorm + review)

1. Privacy copy corrected — "only feedback you send leaves your iPhone" (DONE, shipped to working tree).
2. Warm-hold default **60 → 120s** (2 min).
3. Warm-hold **switching nudge**: qualifying-return math keyed off live `W`; streak ≥ 3; suppress when warm hold on; re-show until turn-on or one-tap "Don't show again"; stop-timestamp ring buffer in App-Group UserDefaults (no schema change).
4. Hero **two-path** (§2a): App-Dictate shows stream instantly; keyboard path withholds stream, coaches swipe-back, reveals stream on first token / ~10s.
5. **Gesture correction:** the iOS return-to-app gesture is a **rightward** swipe along the home indicator (not "down-and-left").
6. **D1 (pill):** coach BOTH the swipe and the "‹ Back to [App]" pill, **only on the cold-start keyboard path** (pill assumed present there); swipe is the reliable base.
7. **"Open Jot" keyboard key removed** (DONE, working tree).
8. **Inline dictation** scope: Edit/Ask/keyboard-while-in-Jot paste into the field and **save no transcript** — but the shipped **warm-hold keyboard path keeps saving + auto-pasting** (regression guardrail).
9. **Inline-Edit does NOT count** toward usage stats / donation gating.
10. **Unified app-level receiver** for the keyboard-dictate tap (incl. the wizard as a consumer); `InlineDictationSession` exposes `finalize()` (insert) and `discard()` (drop) terminals.
11. **WS-G:** keep the system `.sheet`, add detents (smallest stays `.height(360)`); ship resizable. Adaptive Enter: arrow glyph for default, **magnifier glyph for search** (user override), words for the rest.
12. **Pause/Resume:** reuses warm-hold's engine-stays-running mechanism; **keep the mic warm the whole pause** (Option A) with a plain "mic ready, not capturing" paused UI + an upper safety ceiling.
13. **iPhone-only** this cycle (defer iPad/watch).

---

## 4. Feature index — what's being updated

See `ux-overhaul-round2.md` for the full plan. Workstreams:

| WS | Feature area | Updates |
|---|---|---|
| WS-A | Live streaming + italic | shared capped/fading scroll-core (hero + keyboard); final text → roman (one row) |
| WS-B | Inline dictation | `InlineDictationSession` (finalize/discard); Edit/Ask/keyboard-in-Jot inline; unified receiver |
| WS-C | Hero cleanup + Pause | remove waveform; rotating top-space messages; **Pause/Resume** (§10); §2a two-path |
| WS-D | Keyboard restructure | remove spacebar/return-to-Jot/minimize-expand/char-preview; adaptive Enter; trash-Cancel left; side margins; fixed height; width-adaptive one-line |
| WS-E | Home & library | header CTA; gear icon; multi-select via swipe |
| WS-F | Micro-messaging + nudge | rotation engine (home + hero); warm-hold switching nudge |
| WS-G | Detail panel | Transform→Articulate; "Cleanup"; resizable sheet detents |

Plus standalone: warm-hold default 60→120; privacy copy (done); Open Jot key removed (done).
