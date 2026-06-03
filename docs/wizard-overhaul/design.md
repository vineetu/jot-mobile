# Setup Wizard — Coral → Blue Rebrand + Handoff Reskin

**Status:** Design (pre-implementation) · **Branch:** `feature/editable-transcripts` · **Date:** 2026-06-01
**Design source of truth:** `Jot/design_handoff_setup_wizard/` (README.md + `wizard-*.jsx` + `jot-logo/`)

---

## 1. Goal

Rebrand the existing, fully-wired setup wizard from **coral → blue** to match the rest of
the app, and bring its copy / structure / one animation up to the handoff spec. This is a
**reskin + copy swap + targeted rebuild**, NOT a from-scratch wizard. All backend wiring
(mic permission, keyboard Settings deep-link + return detection, clipboard-handoff polling,
warm-hold setting, the wizard teardown contract) is preserved end-to-end.

The companion **app-icon swap** (blue j+waveform tile, iOS + Watch) is already done in this
branch and is out of scope for this doc except for the **in-app W1 brand mark** (same mark,
rendered natively), covered in §6.

## 2. Locked decisions (from product owner)

1. **Blue everywhere in the wizard; zero coral.** The app accent is blue. Coral survives ONLY
   on Settings + AI surfaces (out of scope — do not touch).
2. **Drop the AI-offer step** entirely → wizard is 7 steps (W1–W7).
3. **Use the handoff copy verbatim** for every step.
4. **W5 = the real keyboard.** No in-app keyboard/streaming simulation. Keep the current
   real-keyboard try-it behavior (Darwin dictate-tap → main-app recording → clipboard-handoff
   poll auto-advance). Just reskin.
5. **W3 = the real iOS Settings deep-link.** No simulated in-app Settings sheet. Keep current
   deep-link + `UITextInputMode.activeInputModes` return detection.
6. **Warm-hold = in-wizard W6** (not the contextual variant).
7. **Last step (W7) CTA: "Start jotting."** (handoff says "Start dictating"; owner overrides.)
8. **Hero tiles stay semantic** (not blue): orange mic (W2/W6), parchment keyboard (W3
   first-run), green check (W3-ready / W7). Blue app-icon tile only on W1.
9. **Build the W4 "How it works" animation verbatim** (the `HowScene` mini-phone). It is the
   only genuinely decorative animation to port.

## 3. Current state — what is ALREADY correct (do not rework)

Verified in code:

| Element | Token / value | Handoff target | Verdict |
|---|---|---|---|
| Progress dots (active) | `Color.jotAccent` = `#1A8CFF` | blue `#1A8CFF` | ✅ already blue (post token-fix) |
| W2/W6 mic tile | `JotSemanticIcon.privacyMicReady` `#FF9A33`→`#D17E2A` | orange `#F6A93B`→`#E8841C` | ✅ orange (name "coralMicTile" is misleading) |
| W3-ready / W7 check tile | `JotSemanticIcon.privacyOnDevice` `#34C759`→`#2BA349` | green `#34C759`→`#27A848` | ✅ green (shaded off by ~2pts) |
| W3 first-run keyboard tile | parchment `rgb(0.953,0.933,0.906)`→`(0.886,0.847,0.792)` | parchment `#F4EFE3`→`#DBD2BE` | ✅ parchment |
| W4 accent dot / swipe arrow | `Color.jotAccent` (blue) | blue `#1A8CFF` | ✅ blue |
| W5 try-field focus ring | `Color.jotAccent` (blue) | blue | ✅ blue |

**Implication:** the *only* coral renders left in the wizard are the CTA pill and the W1
mark (§4). Hero-tile hexes are close-but-not-exact vs handoff; **proposal: leave them as the
existing semantic tokens** (they read correctly and keep the wizard in lockstep with Settings'
privacy rows). Aligning to the exact handoff hexes is optional polish — flag for review.

## 4. Coral → blue — the two real changes

### 4.1 CTA pill — `WizardChrome.swift` `WizardPrimaryButton` (hits every step)

Currently a coral gradient + coral-red shadow:
- `Color.jotCoralTop` → `Color.jotCoralBottom` linear fill (lines ~204–210)
- hardcoded shadow `Color(red: 1.00, green: 0.23, blue: 0.19).opacity(0.35)` (line ~221)

**Change to the blue brand CTA** per handoff (`CTA pill gradient 180° #2E9BFF → #0E7AE6 →
#0064CC`, glow `rgba(26,140,255,0.44)`):
- Fill: 3-stop linear `#2E9BFF → #0E7AE6 → #0064CC` top→bottom. We already have `jotBlueTop`
  (`#1A8CFF`) and `jotBlueBottom` (`#0064CC`); **add the exact handoff stops** rather than
  reuse `jotBlueTop` — handoff CTA top is `#2E9BFF`, not `#1A8CFF`. Two options:
  - (a) inline the three hex stops in `WizardPrimaryButton`, or
  - (b) add `jotCtaBlueTop/Mid/Bottom` tokens to `JotDesign`.
  **Proposal: (b)** — named tokens, single source, matches the design-system convention.
- Shadow/glow: `Color(red:0x1A, green:0x8C, blue:0xFF).opacity(0.44)` (blue glow).
- Comment block at top of file (lines 1–16) and the `WizardPrimaryButton` doc comment still
  say "coral" — update to "blue."

### 4.2 W1 mark — `WelcomeStep.swift`

Currently `IconTile(systemImage: "sparkles", tint: .jotCoralTop, shaded: .jotCoralBottom)`.
**Replace with the blue app-icon tile + j-waveform mark** (§6), 126px per handoff.

### 4.3 Stale-comment sweep

`WizardChrome.swift` header + dot-row docs, `MicStep.swift` ("Coral 92pt mic"),
`HowItWorksStep.swift` ("coral mic glyph"), `AIOfferStep.swift` (being deleted anyway) carry
"coral" language. Update/remove the comments so the file docs stop lying (same class of bug as
the `jotAccent` mislabel we just fixed).

## 5. Per-step copy — current → handoff verbatim

Replace current copy with the handoff strings **exactly**. State-dependent variants (e.g.
mic-permission denied, keyboard not-yet-added) keep their existing branching logic; only the
happy-path base strings change.

| Step | Field | Current | → Handoff verbatim |
|---|---|---|---|
| **W1** | subtitle | "Voice transcription,\non your iPhone." | "Voice transcription for fast messaging — dictate into any app." |
| W1 | title | "Welcome to Jot." (38) | "Welcome to Jot." (size → ~41) |
| **W2** | title | "Let Jot hear you" | (same) ✅ |
| W2 | body | _verify_ | "Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded." |
| W2 | CTA | _verify_ | "Grant microphone" |
| **W3** first-run | title | "Add the Jot keyboard" (verify) | "Add the Jot keyboard" |
| W3 first-run | body | "In Settings, add Jot as a keyboard, then turn on Full Access…" | "Two quick toggles in Settings let Jot paste your dictation into any app." |
| W3 first-run | checklist | _none_ | Add 2-row card: ① "Add 'Jot' under Keyboards" ② "Turn on Allow Full Access" |
| W3 first-run | CTA | "Open Keyboard Settings" | "Open Settings" |
| W3 first-run | link | "I've already done this" | "I've already added it" |
| W3 ready | title/body | _verify_ | "Keyboard ready" / "The Jot keyboard is added with Full Access — your dictations can paste into any app." |
| **W4** | title | "How it works" (30) | "How it works" (~35) |
| W4 | body | "Tap Dictate, swipe back to your app, then stop from the keyboard." | "Tap Dictate, then **swipe back to your app.** Stop from the keyboard when you're done." (bold span = blue) |
| W4 | drill label | "TAP DICTATE → SWIPE BACK → STOP → TEXT PASTED" | **remove** (not in handoff) |
| W4 | footnote | _none_ | **add** "We'd skip this step if we could. Apple doesn't let keyboards use the mic directly — so Jot hops back to capture. If that ever changes, this goes away." (ink-caption) |
| **W5** | title/body | "Now try the keyboard" / "Tap the field below, switch to Jot via the globe key, then tap Dictate." | (same) ✅ |
| **W6** | title | "Keep mic ready?" | "Keep the mic ready" |
| W6 | body | _bodyCopy_ | "After you dictate, Jot stays ready for two minutes — so your next dictation starts instantly, without hopping back to the app. Nothing is recorded until you tap Dictate." |
| W6 | toggle label | "Keep mic ready" | "Keep mic ready" ✅ |
| **W7** | title | "You're ready." | (same) ✅ |
| W7 | body | "Jot works now. You can start dictating any time." | "Jot works now — start dictating in any app, any time." |
| W7 | watch card | _none_ | **add** (§7) |
| W7 | CTA | "Maybe later" / "Set up now" (AI routing) | **"Start jotting."** (single CTA, closes wizard) |

> Action item: read each step's exact current `bodyText`/`primaryTitle` computed props during
> implementation and swap the base case; preserve permission-state branches.

> **✅ S2 — RESOLVED. The default is ALREADY 2 minutes; "60s" was a stale comment.** The review
> agent (and the first draft of this doc) believed the default was 60s based on stale
> doc-comments. **Ground truth:** `AppGroup.warmHoldDurationSeconds` returns **120** when unset
> (`AppGroup.swift:203`); 60 is only the clamp *floor*. So the handoff's "two minutes" copy is
> **correct as-is — no `RecordingService`/engine change needed.** Owner decision confirmed: warm
> hold is 2 minutes. **Action = fix the stale "60s" references to read "two minutes" / 120s:**
> - `WarmHoldStep.swift:52` body copy ("60-second" → handoff verbatim, see §5).
> - `AppGroup.swift:182` and `:193-194` doc-comments ("default 60s" → "default 120s").
> - `features.md §13.2 / §4.6` (any "60 seconds" default claim → 2 minutes).
>
> Use the **handoff W6 body verbatim**: "After you dictate, Jot stays ready for two minutes — so
> your next dictation starts instantly, without hopping back to the app. Nothing is recorded
> until you tap Dictate."

> **S3 — W4 blue inline span needs real plumbing.** The W4 body bolds "**swipe back to your
> app.**" in blue. `WizardBody` (`WizardChrome.swift:332`) is a single-style `Text` and can't do
> a colored sub-span — build this body with `Text` concatenation or `AttributedString`, not a
> plain string swap. Same for any other accent-colored inline run.

## 6. W1 brand mark (native port of `JotWaveMark` + `AppIcon`)

Build a SwiftUI view rendering the j+waveform mark on the blue app-icon tile, reused for W1
(and available for any future in-app brand-mark needs).

**Tile:** rounded square, radius `0.245 × size`, 168° gradient `#3AA0FF → #1483F2 → #0064CC`,
white top sheen overlay, subtle ambient shadow. (Mirror the app-icon we shipped.) **168° is
near-vertical with a slight tilt** — SwiftUI `LinearGradient` needs explicit `startPoint`/
`endPoint` `UnitPoint`s to approximate it (≈ `topLeading`-ish → `bottom`), not a plain
top→bottom (review N2).

**Hero size (review S1):** the existing semantic tiles all render at
`JotDesign.Spacing.tileHeroSize = 84`. The handoff specs per-screen sizes (W1 126, W2 128, W3
104/120, W6 116, W7 112). **Decision needed (see §11.1):** keep the app's uniform 84pt rhythm,
or adopt the handoff's varied sizes. Default proposal: **keep 84** for in-app consistency; give
`WizardBrandMark` an explicit `size:` param (default ~84) rather than hardcoding 126, so the
call site decides. The §3 table's "W7 check already correct" refers to **color**, not size.

**Mark geometry** (viewBox `22 6 72 148`, scale to fit, white strokes, round caps):
- Stem: `Path` `M58 52 L58 116 Q58 138 34 138`, stroke-width 15.
- Tittle = 3 vertical bars, x = 47 / 58 / 69, centered y≈24, heights 10 / 18 / 10 (centre
  tallest), bar weight 5.4, round caps. **The 3 bars must stay visually separate — never fuse.**

Implement as a `Shape`/`Path` pair scaled into the tile (e.g. mark occupies ~46% of tile,
centered). Source vectors: `jot-logo/jot-mark-white.svg`, `jot-icon-1024.svg`.

**Proposal:** add `WizardBrandMark` (or `JotWaveMark`) to `Components/WizardChrome.swift` (or a
new `Components/JotWaveMark.swift`). Keep it `JotDesign`-token driven.

## 7. W7 restructure (drop AI routing + add watch card)

Today W7 (`YoureReadyStep`) is a fork: "Maybe later" (skip) vs "Set up now" (→ `aiOffer`). With
the AI step gone, W7 becomes terminal:
- Single CTA **"Start jotting."** → `closeAndComplete()`.
- Remove the `onAdvanceToOptional` / `onSkipOptional` two-button layout; `YoureReadyStep` takes
  a single `onFinish` (= `closeAndComplete`).
- **Add the Apple Watch "one more thing" card** below the body (handoff W7): rounded card,
  blue-soft 52px tile with a blue watch glyph, title "It's on your wrist, too", body "Caught an
  idea without your phone? Tap the Jot complication and speak — it syncs back automatically."

## 8. Drop the `aiOffer` step — full removal checklist

**⚠️ Deletion ORDER matters (review B2) — `DotsStyle.optional` and `WizardProgressDotsOptional`
are NOT dead yet; they're consumed by `AIOfferStep.swift:31` and `WizardChrome.swift:484-485`.
Deleting them first breaks the build. Do this sequence:**

1. **`SetupWizardView.swift`**: remove `case .aiOffer` from the `SetupStep` enum, its switch
   arm, and the `onAdvanceToOptional`/`onSkipOptional` wiring on `youreReady` → `youreReady`
   becomes terminal (single `onFinish = closeAndComplete`). Also update the **file header
   comment block (lines 5–35)** — it still says "8-panel … 1 optional" and describes the
   AI-offer `LLMClientUIAdapter.warm()` wiring; and the **`closeAndComplete()` doc comment
   (line ~230)** which references *"the 'Maybe later'/'Skip' buttons on W7 and the optional
   steps."* Both become lies after this change (B3).
2. **Delete `Steps/AIOfferStep.swift`.**
3. **Now** `WizardChrome.swift`: `WizardProgressDotsOptional`, `WizardGlassButton`, and
   `WizardHeader.DotsStyle.optional` are dead → remove them. `DotsStyle` collapses to a single
   `case core`; either keep it as a one-case enum (legal) or simplify the `init` + `@ViewBuilder
   var dots` to drop the switch. `WizardGlassButton` is already unreferenced today (safe to
   delete anytime). `WizardProgressDots` stays at 7. Update the file header ("8 panels" → "7").
4. `LLMClientUIAdapter.warm()` is **not** removed — it's still used by `TranscriptDetailView`
   and `AIRewriteSettingsView`; only the wizard caller (`AIOfferStep`) goes away. No orphan.
5. Run `xcodegen` from `Jot/` so the project drops `AIOfferStep.swift` from the glob.

## 9. W4 — four-step animated explainer

> **⚠️ SUPERSEDED by owner feedback (post-implementation).** The verbatim 5.2s
> `HowScene` below was built but read as confusing on-device. The owner
> redirected to an **explicit 4-step explainer**:
> 1. Tap Dictate on your keyboard
> 2. Jot opens and starts recording
> 3. Swipe back to your app
> 4. Stop from the keyboard when you're done
>
> **New spec (shipped):** a **20-second looping** mini-phone animation, **~5s per
> step** ("at least five seconds for each step, looping"), keyboard stays up the
> whole time. Each step has one cue: ① tap-ring pulses on the Dictate pill · ②
> record dot pulses + pill→Stop square · ③ swipe arrow sweeps the bottom edge ·
> ④ dictated bubble fades in. The scene shows a **"STEP n" badge** and the
> numbered **step list below highlights the active row in sync** (driven by one
> shared `TimelineView` phase so they never drift). The honest footnote moves to
> the bottom, just above "Got it". Reduce-motion → one static frame, no loop.
> The old 5.2s keyframe spec + Appendix A are kept below for history only.

### (Historical) original verbatim `HowScene` port

Rebuild `HowItWorksStep`'s illustration to match `wizard-panels.jsx` `HowScene`. Mini-phone
frame **168×248**, radius 30, dark `#0C1422` / light `#EAEFF7` body, 1px border, drop shadow.

Layers (z-order) + animation, looping:
1. **Dynamic island** (top, `#05080d`, 58×17 r10) with a **pulsing record dot** (blue `a.dot`,
   7px) — pulses continuously.
2. **Message thread** (the user's app): 3 placeholder bubbles (one tinted blue-soft) + a
   **dictated bubble** (blue gradient, 72%×30, starts `opacity 0`) that **fades up** on
   swipe-back.
3. **Jot keyboard** (bottom, 118px, `t.kbFill`): an italic placeholder line + a row of
   [grey key · **blue Dictate pill** with white dot · grey key]. **Slides down** on swipe-back.
4. **Swipe arrow + "SWIPE" label** (blue), bottom-left, `opacity 0` → **sweeps along the
   home-indicator edge** once per loop.
5. **Home-indicator bar** (bottom center, 64×4).

Loop choreography (one **5.2s** loop, from the standalone HTML's CSS keyframes): record dot
pulsing throughout → keyboard slides down + app thread slides in → swipe arrow sweeps L→R along
the bottom edge → dictated bubble fades up → hold → reset. **Gate on
`accessibilityReduceMotion`**: when reduced, render the end-state (thread visible, dictate pill
present, dot static) with no motion. `.onDisappear` must cancel the loop (no off-screen
animation burn).

> **⚠️ CORRECTION (design review B1):** This is a **from-scratch build**, not an extension.
> The current `HowItWorksStep.swift` is **fully static** — an `HStack` of
> keyboard → arrow → an `OrigamiCrane` PNG → "SWIPE" label → keyboard, with **no `@State`, no
> animation, and no `accessibilityReduceMotion` reference at all**. The implementer builds the
> looping `HowScene` new, and **removes the `OrigamiCrane` image** (this step is its only
> consumer). Verbatim keyframe stops (the 5.2s percentage timings for
> `how-recdot`/`how-kb`/`how-app`/`how-typed`/`how-dict`/`how-swipe`) live in the standalone
> HTML and are reproduced in **Appendix A** below — port them rather than inventing timing.

## 10. CTA pill geometry reconciliation

Handoff: pill **height 64, radius 33** (fully rounded), label **19px / 600**. Current
`WizardPrimaryButton`: `padding(.vertical,12)` + `minHeight 28` ≈ 52pt, label 16px,
`Capsule()`. **Proposal:** bump to handoff (≈ vertical 18 / minHeight 28 → 64; label 18–19 /
semibold). Capsule already gives full rounding. Verify it doesn't crowd the secondary text
button or overflow on small devices (SE) — the panel CTA group is bottom-pinned with 22pt
bottom padding.

**Review S4 — where to actually check SE:** the footer CTA group is a **fixed (non-scrolling)**
`VStack` (`WizardChrome.swift:417-421`); only the panel *content* scrolls. W7 is now a single
CTA (no secondary button) → fine. The tightest footer is **W3 first-run** (primary CTA 64 +
"I've already added it" secondary 44 + 22pt padding + home indicator) — verify that band on SE.
The W3 checklist card lives in the scrollable content, so it's not part of the footer squeeze.

## 11. Risks / open questions (for design-review)

1. **Hero-tile sizing (S1) — OWNER DECISION.** Color is already correct (§3). Open: keep the
   uniform 84pt tile rhythm app-wide, or adopt the handoff's per-screen sizes (W1 126 / W7 112 /
   etc.)? Proposal: keep 84 for consistency; `WizardBrandMark` takes an explicit `size:`.
1b. **Hero-tile hex drift.** Keep existing semantic tokens (close, in lockstep with Settings) or
   align exactly to handoff hexes? Proposal: keep tokens; flag if review disagrees.
2. **CTA token placement.** Inline hexes vs new `jotCtaBlue*` tokens — proposal: tokens.
3. **W3 checklist card** is net-new UI (2-row card). Confirm it should render only in the
   first-run state (not the ready state). Handoff: yes, first-run only.
4. **W4 animation cost.** Continuous looping animation on an onboarding screen — ensure it
   pauses off-screen / on reduce-motion to avoid battery/CPU waste. SwiftUI `.onDisappear`
   should cancel the loop.
5. **W7 terminal change** alters `YoureReadyStep`'s API (two callbacks → one). Confirm no other
   caller. Grep shows only `SetupWizardView` constructs it.
6. **Mark rendering fidelity** — porting the SVG to `Path` must keep the 3 waveform bars
   separate at small sizes (126px tile → mark ~58px). Verify at W1 size + Dynamic Type.
7. **"8 panels" references** scattered in comments — sweep so docs match the new 7-step reality.

## 12. Out of scope / explicitly NOT building

- The prototype's **simulated iOS Settings sheet** (W3) — we deep-link to real Settings.
- The prototype's **simulated Apple/Jot keyboard + streaming text** (W5) — the real keyboard
  extension handles it.
- The **contextual** warm-hold prompt variant — shipping in-wizard W6.
- Any change to **Settings or AI** coral — intentionally retained there.
- The app-icon asset swap — already shipped in this branch.

## 13. Schema impact

**None.** No `@Model` types touched. No migration. (Per `Jot/CLAUDE.md` schema discipline,
recorded explicitly: add/remove/rename `@Model` fields? **N**. New entities? **N**.)

## 14. `features.md` impact

Per `Jot/CLAUDE.md`, before/after implementation. No user-facing feature is removed — AI rewrite
is still reachable from Settings — but dropping the AI-offer step **invalidates specific
sections** (review S5, verified line numbers):

- **§4 lead paragraph** (≈ line 293): says "seven core panels and **one optional follow-on
  panel**" → drop the optional panel; wizard is 7 panels.
- **§4.7** (≈ line 313): describes W7 as a fork "Set up now / Maybe later" → AI offer. Rewrite:
  W7 is terminal with a single "Start jotting." CTA.
- **§4.8** (≈ line 316): the entire "AI Rewrite Download Offer (Optional Step)" section →
  delete or rewrite as "AI Rewrite is set up from Settings, not onboarding."
- **§4.10** (≈ line 323): describes the optional-step progress-dot variant → now dead, remove.
- **§7 cross-links** (≈ lines 410, 415): point to `#4-8-ai-rewrite-download-offer-optional-step`
  → will become **dangling anchors**; repoint to the Settings AI section or remove.
- **New bidirectional link**: W7 watch card ↔ the Apple Watch feature section (≈ §2.13).
- **Warm Hold (§13.2) ↔ wizard W6** cross-link — ensure both directions exist; and if S2 is
  resolved as option (b) (120s default), §13.2/§4.6 duration copy must change too.
- Update the wizard description to 7 steps, verbatim copy, the watch card, "Start jotting."

## 15. Implementation order (proposed)

1. `WizardPrimaryButton` blue CTA + glow + `jotCtaBlue*` tokens (unblocks every step visually).
2. `WizardBrandMark` native mark + W1 hero swap + W1 subtitle.
3. Copy swaps W2/W3/W6/W7 + W3 checklist card.
4. Drop `aiOffer` (enum, view, chrome dead code, W7 terminal restructure + watch card).
5. W4 `HowScene` animation rebuild.
6. Stale-comment sweep + `xcodegen` + `features.md`.
7. Compile-verify locally (Xcode quit first). On-device test before any deploy.

---

## Appendix A — W4 `HowScene` keyframes (verbatim from the standalone HTML)

Port these to SwiftUI animations (5.2s loop, no delay, `infinite`). `how-kb`/`how-app` use
`cubic-bezier(.5,0,.2,1)`; the other four use `ease-in-out`. Translate the CSS `translateY(%)`
against each layer's own height and `translateX(px)` against the 168-wide phone frame.

```css
/* W4 "How it works" scene — 5.2s loop */
.how-recdot { animation: howrec 5.2s ease-in-out infinite; }
@keyframes howrec { 0%,12% { opacity: 0.25; } 22%,100% { opacity: 1; } 50%,70% { opacity: 0.4; } }

.how-kb { animation: howkb 5.2s cubic-bezier(.5,0,.2,1) infinite; }
@keyframes howkb { 0%,30% { transform: translateY(0); } 46%,86% { transform: translateY(100%); } 100% { transform: translateY(0); } }

.how-app { animation: howapp 5.2s cubic-bezier(.5,0,.2,1) infinite; }
@keyframes howapp { 0%,30% { transform: translateY(28%); opacity: .35; } 46%,100% { transform: translateY(0); opacity: 1; } }

.how-typed { animation: howtyped 5.2s ease-in-out infinite; }
@keyframes howtyped { 0%,60% { opacity: 0; transform: translateY(6px) scale(.96); } 72%,90% { opacity: 1; transform: none; } 100% { opacity: 0; } }

.how-dictate { animation: howdict 5.2s ease-in-out infinite; }
@keyframes howdict { 0%,18% { transform: scale(1); } 24% { transform: scale(.9); } 30% { transform: scale(1); } }

.how-swipe { animation: howswipe 5.2s ease-in-out infinite; }
@keyframes howswipe {
  0%,30% { opacity: 0; transform: translateX(118px); }
  38% { opacity: 1; }
  46% { opacity: 1; transform: translateX(14px); }
  56% { opacity: 0; transform: translateX(14px); }
  100% { opacity: 0; transform: translateX(14px); }
}
```

Read: dot pulses throughout (dimmer 50–70%); at ~30–46% the keyboard slides down (`translateY
100%`) while the app thread settles up (`28%→0`, fade in); the swipe arrow sweeps in from the
left edge to `+14px` (~30→46%) then fades; the dictated bubble fades up at ~60–72%; the dictate
pill does a quick press-scale at ~18–30%. SwiftUI: drive with a single repeating
`Animation.timingCurve(...)` keyed phase, or per-layer `withAnimation` on a shared 5.2s clock.
