# Help screen redesign — implementation plan

> **Status: PLAN (pre-implementation).** Source: design handoff
> `design_handoff_help_redesign/` (high-fidelity HTML artboards + token mirrors).
> Recreate in SwiftUI with existing JotDesign tokens/components — not a port of the HTML.

## Goal

Redesign the in-app **Help** screen + add **two new pushed pages**, per the handoff:
1. Top of Help becomes **"What Jot does"** — a card of **four tap-to-expand feature rows**,
   now including **Ask Jot** (owner-confirmed addition; Help never surfaced Ask before).
2. Cut long prose; Help is scannable. The old "AI Rewrite guide" section folds into the
   row-3 expandable body.
3. **Getting Started** → its own pushed page **"How Jot works"**, reusing the setup wizard's
   W4 animated mini-phone scene.
4. **Privacy** → its own pushed page **"See for yourself"** (teaches verifying the on-device
   claim via iOS App Privacy Report; "Open Settings" CTA).
5. Troubleshooting (accordion) + Send feedback stay on Help.

**Copy correction (owner):** the rewrite/polish row must **not** mention a keyboard wand
(advertised-but-unwired — `features.md §7.3`/`§7.11`). It happens in the **transcript pane**
via the **Articulate** action (`features.md §7.4` — the blue Articulate pill in Transcript
Detail). Row-3 copy → *"Tap Articulate on any transcript — Cleanup, Action Items, Email, or a
prompt you wrote. All on this iPhone."* **Note:** this **deliberately overrides** the
handoff README's literal row-3 string ("Tap the wand: …") on owner instruction — the README
is wrong on that one line.

**Copy is a deck, not paraphrase.** This plan is a *structure* sketch; all user-facing strings
are **final in the handoff README** and must be lifted verbatim at build time (review m6
flagged strings the plan doesn't restate): the feature-card hint line *"Tap a feature to read
how it works."*, the Getting-Started row sub *"The 30-second refresher, animated"* vs the page
sub *"The whole loop, in 30 seconds"*, the Privacy row title/sub, the Privacy page lead
*"No accounts, no cloud, no telemetry."* + the *"WHAT JOT'S REPORT SHOWS"* label + per-row
captions + the apple.com note + the *"iOS keeps the receipts"* subtitle + bar counts (4 / 1).
Implementer: pull every string from `README.md` §Screens — do not re-author.

## Current state (what exists today)

`App/Help/HelpView.swift` (707 lines), presented two ways via `isModal`: modal sheet from
the home `?` button, nav-push from Settings → About. Sections today: `hero`,
`useCasesSection` (3 stories), `gettingStartedSection`, `aiRewriteSection`, `privacySection`,
`troubleshootingSection`, `contactSection`, **`diagnosticsSection`**, `footer`. Uses
`WizardWallpaper` + JotDesign. No accordion/expand component exists yet (only diagnostics
rows have ad-hoc expand state).

## Diagnostics moves to Settings → About (O1 — DECIDED by owner)

The current Help has a **Diagnostics section** (`HelpView.swift:340+`) reading
`DiagnosticsLog` — the owner's **only** on-device log *reader* (review confirmed no other UI
surfaces it; Feedback only attaches it). The redesign artboards omit it, so **it relocates to
Settings → About**, not dropped. Implementation: lift the existing `diagnosticsSection` (+ its
state: `diagnosticsEntries`, `expandedEntryID`, `showClearConfirm`, `diagnosticsCopiedAck`,
the `.task` load, the Clear alert, `diagnosticsRow`) out of `HelpView` into a row/sub-page
under **Settings → About** (`§6.5`). It's a move, not a rebuild — same view code, new host.
`features.md §6.5` gains it; `§9` loses it.

## Target structure

### Screen 1 — Help (modal sheet from home / push from Settings)
Content order: **WHAT JOT DOES** (4-row expandable card) → **GETTING STARTED** (row →
push "How Jot works") → **TROUBLESHOOTING** (4-row accordion, collapsed) → **PRIVACY** (row →
push "See for yourself") → **Send feedback** (row → existing `FeedbackView`) → *[Diagnostics,
pending O1]*.

The four feature rows (icon tile + title + chevron + expandable body):
1. Speak in any app (blue / keyboard glyph).
2. Keep going when life interrupts (orange / refresh glyph) — warm-hold (`§13.2`).
3. **Polish via Articulate in the transcript pane** (coral / wand glyph) — corrected copy.
4. **Ask Jot** (blue / sparkle glyph) — links `§14`.

### Screen 2 — "How Jot works" (pushed)
Reuses the wizard's W4 `HowScene` (see Reuse). 4 numbered steps + the honest "Apple won't
let keyboards use the mic, so Jot hops" footnote. Honor Reduce Motion (static final frame).

### Screen 3 — "See for yourself" (pushed)
Static App-Privacy-Report preview card (two domain rows: `huggingface.co`,
`jot-donations.ideaflow.page` — **static copy, no API read**) + "Open Settings" CTA
(`openSettingsURLString`; there is **no** deep-link to App Privacy Report — keep the manual-
path footnote) + lead copy.

## Navigation architecture (and how it fits the app-wide refactor)

Help's two sub-pages are **local sub-navigation owned by the Help screen** — exactly like
Settings' sub-pages. Per the in-flight architecture plan
(`docs/decouple-root-view/design.md`), these do **NOT** belong in the app Router; they stay
local.

**Correction (review C1 — my earlier claim here was wrong):** HelpView **already has an
ambient `NavigationStack` in BOTH presentation paths.** The home modal is wrapped at the call
site — `ContentView.swift:396` does `.sheet { NavigationStack { HelpView(isModal: true) } }` —
and the Settings push is inside `SettingsView`'s own stack (`SettingsView.swift:45`). Proof it
already works: the current Feedback row pushes with a **bare `NavigationLink`** and no internal
stack (`HelpView.swift:593`). **So add NOTHING structural.** Implement the two sub-pages as
plain `NavigationLink` / `navigationDestination` exactly like the Feedback link; they push on
the ambient stack in both paths. There is **no** `isModal`-gated wrapper — wrapping would
nest a second stack inside the modal's and break `navigationDestination` resolution. The
"structural subtlety" was a non-issue; everything is view composition.

## Reuse map (reuse-first, minimal new code)

| Need | Reuse | New? |
|---|---|---|
| Wallpaper / chrome | `WizardWallpaper` (lives in `Components/WizardChrome.swift`), JotDesign tokens (handoff `tokens/` mirror these) | no |
| **Icon tiles (all 6)** | `IconTile` + `JotSemanticIcon` token pairs — **exact matches exist** (review M2): speech=`speechModel`, micready=`privacyMicReady`, ai-coral=`ai`, privacy=`privacyOnDevice`, help=`helpSupport`, feedback=`sendFeedback` | **no — not new work** |
| Section label / card | `SectionLabel`, `GlassCard` (already used in Help) | no |
| Send feedback | existing `FeedbackView` (`§9.6`) | no |
| W4 animation + steps + footnote | `HowScene` + the step list / footnote / driver in `HowItWorksStep.swift` | **extract a bundle** (see below) |
| Troubleshooting copy | existing Help troubleshooting answers | no |
| Privacy lead copy | existing `privacySection` copy, reworked to the new page | partial |
| Modal "Done" pill | existing `isModal`-gated pill (`HelpView.swift:113-132`) — keep | no |
| Expandable feature row | — | **new** `HelpExpandableRow` |
| Tappable push row | — | **new** `HelpLinkRow` |
| Privacy report preview card | — | **new** static `PrivacyReportPreview` |

**HowScene extraction (review M3 — bigger than just `HowScene`):** `HowScene` itself is a
clean pure function of `(phase, step)` + `colorScheme` with **no wizard-state coupling**
(`HowItWorksStep.swift:148`), so W4 can stay untouched. **But** the Help "How Jot works" page
also needs the pieces that live in the **parent** `HowItWorksStep`, not in `HowScene`: the
numbered **step list** (`stepList`/`stepRow`), the `currentStep(_:)` mapper, the verbatim
**honest footnote** (:58), the `TimelineView` **driver**, and the **Reduce-Motion** static-
frame branch (:77-89). So extract a **self-contained `HowItWorksScene`** bundling all of those
+ a self-looping driver, and have both W4 and the Help page consume it. **Constraint: W4
visually unchanged** — verify after extraction. (Timing: the iOS loop is **13s**
(`loopDuration = 13`, the "20s" is a stale doc-comment), not the HTML's 5.2s — reuse 13s, but
**verify the pacing reads on a standalone page** with no CTA gating attention.)

## features.md updates (AFTER implementation, per the doc rule)

- **§9.7** → becomes "What Jot does"; **add the Ask Jot story + cross-link to §14** (missing today).
- **§9.2** → split into the "How Jot works" page; cross-link wizard **§4 (W4)**.
- **§9.3** → folded into row-3 body; **remove "or in the keyboard"**, say transcript/Articulate.
- **§9.4** → split into the "See for yourself" page.
- **§9.5 / §9.6** → unchanged.
- **§6.5 About** → gains the relocated **Diagnostics** reader (document it; it's currently
  only described under Help).
- New bidirectional links: §9.7 ↔ §14, "How Jot works" ↔ §4, §9.4 ↔ §13.1.

## Test plan (on-device, owner-gated)

- Help opens both ways (home sheet + Settings push); dismiss affordance correct in each.
- Modal Help: tapping Getting Started / Privacy **pushes** the sub-page and back returns to
  Help (the NavigationStack-when-modal wiring).
- Pushed-from-Settings Help: sub-pages push within the existing stack, no double-nav.
- All 4 feature rows + 4 troubleshooting rows expand/collapse; chevron rotates; height animates.
- "How Jot works" animation runs; Reduce Motion shows the static final frame; **W4 in the
  wizard is visually unchanged** (extraction regression check).
- "Open Settings" opens iOS Settings root; footnote present.
- Send feedback opens the existing form.
- Diagnostics still reachable + readable (per O1).
- Dark/light both correct (tokens).

## Open questions

- **O1 — Diagnostics fate.** RESOLVED: **move to Settings → About** (`§6.5`); lift the
  existing view code as-is. See the Diagnostics section above.
- **O2 — Accordion behavior.** Handoff allows multi-open OR one-open. Pick to match app
  convention (lean: one-open for the feature card to keep it tight; multi-open fine for
  troubleshooting). Cosmetic.
- **O3 — Coral on row 3.** RESOLVED (review M2): use `JotSemanticIcon.ai` / `aiShaded`
  (`#FF6B57→#D15847`) via `IconTile`. Do **not** reach for `jotCoralBottom #E0533F` — wrong stop.
- **O4 — Section disposition (full table, review m7).** Map every current section so nothing
  orphans:

  | Current section | Disposition |
  |---|---|
  | `hero` | keep, retitled "Help" |
  | `useCasesSection` (3 stories) | **replace** with the 4-row "What Jot does" card |
  | `gettingStartedSection` | **move** → pushed "How Jot works" page |
  | `aiRewriteSection` | **fold** into row-3 expandable body |
  | `privacySection` | **move** → pushed "See for yourself" page |
  | `troubleshootingSection` | keep (accordion) |
  | `contactSection` | keep as the Send-feedback row |
  | `diagnosticsSection` | **move** → Settings → About (`§6.5`), code lifted as-is |
  | `footer` | keep or drop (decide; "made on-device, made for you." line) |
  | `bulletParagraph` / `composedAttributedString` helpers | likely **dead code** after — remove |
