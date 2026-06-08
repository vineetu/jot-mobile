# Watch UX Overhaul

**Size:** M (~1 day)
**Touches:** `Jot/Watch/Views/*.swift`, `Jot/Shared/JotDesignWatchSafe.swift`, `Jot/project.yml` (only if new files added), `Jot/features.md` §2.13
**Schema impact:** None.
**Status:** Plan only — not yet implemented.

---

## 1. Intent

The watch app today opens directly to a big Dictate button — good — but immediately under it sits a flat pair of equal-weight rows: `Recent` and `Diagnostics`. The user reports two real problems and one visual one: (a) Diagnostics is showing up as a peer of Recents when it should be a buried utility, (b) tapping the Recent row often opens Diagnostics instead, and (c) the surface looks like raw default watchOS — none of the polished iOS visual language (blue gradient, soft cards, semantic glyphs, weight rhythm) carries over. This plan rebuilds the watch IA so that Dictate stays primary, Recents becomes the single secondary surface, Diagnostics drops to a deep-utility footer row inside Recents, and the look-and-feel echoes the iOS "liquid" language using watchOS-appropriate primitives that fit inside the watch's CPU/memory envelope.

---

## 2. Current state audit

### 2.1 Information architecture (as shipped in build 46)

```
RootView (NavigationStack)
└── VStack(spacing: 12)
    ├── Spacer
    ├── MicButton                     ← primary CTA (blue gradient capsule, 96×64)
    ├── Divider
    ├── NavigationLink → Recent       ← peer #1  (subheadline, chevron)
    ├── NavigationLink → Diagnostics  ← peer #2  (caption2, chevron, same row shape)
    ├── [optional] "N pending sync"   ← amber caption
    ├── [optional] "✓ N synced"       ← green caption ribbon
    └── Spacer
```

`RecentTranscriptsView` is a plain `List` (`.listStyle(.plain)`) of `TranscriptRow`s with a `Section { EmptyView() } footer:` carrying "Last synced".
`DiagnosticsView` is a `ScrollView` with a status card + Reset sync button + escalation banner (this is the post-build-46 simplified version — content is correct, placement is wrong).
`TranscriptDetailView` is a `ScrollView` with timestamp + body — default `.body` font, no card surface, no header treatment.

All views import only `SwiftUI` + `WatchKit`/`WatchConnectivity`. They consume `JotDesignWatchSafe` tokens (`jotPageInk`, `jotBlueTop`, `jotBlueBottom`, `jotAccent`, `jotPendingAmber`, `jotSyncSuccess`, `jotRecord`, `jotRecordingDot`). No card/tile/section-label primitives exist on the watch.

### 2.2 ASCII sketch of the current root surface (40mm)

```
┌──────────────────────┐
│         Jot          │
│                      │
│      ┌──────┐        │
│      │ 🎤   │        │
│      │Dictate│       │
│      └──────┘        │
│  ─────────────────   │
│  Recent           ›  │ ← peer row
│  Diagnostics      ›  │ ← peer row (caption2, smaller text — but
│                      │   same chevron, same vertical rhythm, no
│                      │   visual hierarchy beyond font weight)
│  3 pending sync      │
│                      │
└──────────────────────┘
```

### 2.3 Touch-target bug hypothesis

**File:** `Jot/Watch/Views/RootView.swift:47-77`
**Hypothesis:** The two `NavigationLink` labels use `HStack { Text(...); Spacer(); Image(...) }` with `.buttonStyle(.plain)` and no `.contentShape(...)` modifier. SwiftUI's default hit-test for a `Button(label:)` whose label is an `HStack` containing a `Spacer` does **not** cover the spacer's area — the tap region is the union of the rendered subviews (Text + Image), not the full row rectangle. A tap that lands in the visual gap between "Recent" and the chevron falls through.

That gap is ~110pt wide on a 40mm watch; the Diagnostics row sits 12pt below the Recent row (`VStack(spacing: 12)`); the chevron is `.font(.footnote)`. Combined with the Digital Crown's auto-focus snapping behavior and the small `caption2`/`subheadline` font drop, taps anywhere in the right two-thirds of the Recent row either no-op or get re-claimed by the next nearest hit-testable parent — which on watchOS frequently resolves to the next sibling row (the SwiftUI hit-tester walks the VStack and picks the closest button). **The user's "tapping Recent opens Diagnostics" report is consistent with this.**

Verified evidence:
- `grep -rn contentShape Jot/Watch/` → 0 hits. No row in the watch target uses `.contentShape(Rectangle())` to extend its tap region.
- Both `NavigationLink`s are siblings inside the same `VStack`, not inside a `List` (which would have its own row hit-testing).
- `.buttonStyle(.plain)` is used on both, which strips the system-provided full-width tap area that the default button style would have given them.

**Fix (single line each):** add `.contentShape(Rectangle())` to each `NavigationLink` label's HStack. Equivalently — and consistent with the IA goal below — collapsing the root to a single `Recent` row and burying Diagnostics inside Recents eliminates the ambiguity entirely. The plan does both: collapse the root (item 3) and add `.contentShape(Rectangle())` defensively to all new row primitives (item 4).

---

## 3. Proposed IA

### 3.1 New navigation hierarchy

```
RootView (NavigationStack)
└── ScrollView                              ← vertical scroll, Crown-driven
    ├── DictateHero          (sticky-ish at top, full-bleed)
    ├── SyncRibbon           (in-flow, only when relevant)
    ├── "RECENT" SectionLabel
    ├── RecentTranscriptList (inline, top 5; "More" row links to full list if >5)
    ├── LastSyncedCaption    (subtle, dimmed)
    └── DiagnosticsFooterRow (single muted row at the very bottom of scroll)
```

Diagnostics is **not** a sibling of Recents anymore — it's the **last row inside the Recents region**, below the "Last synced" footer. The user has to scroll past every transcript to find it. This matches the user's mental model ("Diagnostics should be even below to scroll down").

The watch's `NavigationStack` still pushes `RecentTranscriptsView` for the full list when there are >5 transcripts (via the "More" row), and pushes `DiagnosticsView` from the footer row. `RecordingView` remains a `.sheet`.

### 3.2 Walk-throughs

**Cold open.**
1. User raises wrist, taps Jot complication → `JotWatchApp` → `RootView`.
2. The Dictate hero fills the upper ~55% of the screen. The watch shows the inline transcript preview row(s) below it.
3. Tap Dictate → `RecordingView` sheet → mic active in ≤120ms.

**After dictation.**
1. `RecordingView` dismisses → back to `RootView`.
2. The new recording appears as the top inline row (still "Transcribing…" until the phone returns the result).
3. The pending-sync ribbon ("1 pending sync") appears just under the Dictate hero in amber.

**View an old transcript.**
1. From `RootView`, swipe up / Crown-rotate → list scrolls into view.
2. Tap any transcript row → `TranscriptDetailView` pushes.
3. Back-swipe returns to root with scroll position preserved.

**Reset sync (deep recovery).**
1. User notices the amber "N pending sync" badge has been stuck for hours.
2. Tap the badge — see item 5.2 below — which surfaces a short "Sync stuck?" prompt with a `View diagnostics →` link.
3. The link pushes `DiagnosticsView` (re-located, content unchanged) where Reset sync + escalation banner live.
4. Alternative discovery path: scroll all the way to the bottom of Recents and tap the muted "Sync diagnostics" footer row.

**ASSUMPTION:** the 5-row inline preview is enough for the common case. If the user wants the full 10, the "More" row is one tap. Tested mental model: the watch is for "what did I just say a moment ago", not for transcript archaeology.

---

## 4. Visual language (watch-safe)

The iOS app's visual language is built on five primitives: blue gradient CTAs (`jotBlueTop` → `jotBlueBottom`), `LiquidGlassCard` (rounded rect + `.regularMaterial` + hairline + highlight + shadow), `IconTile` (small semantic-color gradient tile with white glyph), `SectionLabel` (UPPERCASE 11pt tracking), and Fraunces serif for editorial display. None of those primitives can be naively ported to watchOS — `LiquidGlassCard` imports UIKit and uses `.regularMaterial` + multi-layer blurs + drop shadows that are too heavy for a 40mm AMOLED tile, and Fraunces isn't installed via `UIAppFonts` on the watch target.

Extending `Jot/Shared/JotDesignWatchSafe.swift` with watch-native echoes:

### 4.1 New tokens (extend `JotDesignWatchSafe.swift` only — do not add new files unless §4.6 requires)

```
// MARK: - Watch surface tokens (new)
//
// Spacing rhythm tuned to 40mm + 45mm. All values are deliberately tighter
// than iOS — watchOS lists ~30pt row heights, 12pt page gutter.
static let watchCardRadius: CGFloat = 12      // softer than iOS's 16
static let watchCardPaddingH: CGFloat = 10
static let watchCardPaddingV: CGFloat = 8
static let watchPageGutter: CGFloat = 8
static let watchRowSpacing: CGFloat = 6

// Hairline + highlight (light & dark adaptive via Color.primary opacity)
static let watchHairline = Color.primary.opacity(0.10)
static let watchHighlight = Color.white.opacity(0.06)

// Card fill — slightly translucent over the system black/white page bg,
// no .regularMaterial (that's iOS-only and too heavy on watchOS).
static let watchCardFill = Color.primary.opacity(0.06)

// Muted utility row tint (for the buried Diagnostics row at the bottom of
// Recents) — visibly de-emphasized vs. transcript rows so the user reads
// it as "below the fold of normal usage".
static let watchUtilityInk = Color.secondary.opacity(0.65)
```

### 4.2 Typography ramp (no new tokens — just adopt SwiftUI primitives consistently)

| Role | Font | Notes |
|---|---|---|
| Dictate label | `.footnote` semibold (existing) | Keep |
| Section label ("RECENT", "DIAGNOSTICS") | `.caption2` bold, tracking 1.0, `Color.secondary` | New helper `WatchSectionLabel` |
| Transcript row preview | `.subheadline` weight `.medium` (existing) | Keep |
| Transcript row sub (relative time + glyph) | `.caption2` (was `.footnote`) | Slight downsize — line height fits on 40mm |
| Detail body | `.body` (existing) | Keep |
| Detail header (date/time) | `.caption2` (existing) | Keep |
| Utility footer rows (Diagnostics drill-in) | `.caption2`, `Color.secondary.opacity(0.65)` | Lower contrast = "deep utility" |

**ASSUMPTION:** Fraunces is skipped on watch. The iOS editorial serif moment doesn't translate to a 40mm cap-height; SF's standard weight rhythm is the right idiom for the watch. This is a deliberate divergence, not an oversight — flag if you disagree.

### 4.3 Gradients & accents — sparingly

- The blue gradient (`jotBlueTop` → `jotBlueBottom`) is reserved for the Dictate hero and the Stop button (both already in place). Do not paint cards or strokes with it — at 40mm a single gradient is a focal anchor; two competes.
- Coral (`jotAccent`) is the live-amplitude waveform color — keep.
- Amber (`jotPendingAmber`) and green (`jotSyncSuccess`) are the only "status colors" on the surface — keep their narrow usage.

### 4.4 Cards — `WatchCard` primitive

New private struct, defined inside `RootView.swift` initially (no new file needed) and promoted to a shared file only if a second view consumes it:

- Wraps content in a `RoundedRectangle(cornerRadius: watchCardRadius, style: .continuous)` filled with `watchCardFill`.
- Hairline overlay via `.strokeBorder(watchHairline, lineWidth: 0.5)`.
- No drop shadow (watchOS AMOLED renders shadow as a smudge over true black; the shadow doesn't read).
- No `.glassEffect()` — see §4.6.
- Padding: `watchCardPaddingH` × `watchCardPaddingV`.

This is the watch-native echo of `LiquidGlassCard`. It has the same role (a grouped surface that frames related rows) but uses one layered fill + one stroke instead of material + hairline + highlight + shadow + clip. ~5x cheaper to render.

### 4.5 Section label — `WatchSectionLabel`

Watch-native echo of `SectionLabel`. Renders UPPERCASE `.caption2` bold, tracking 1.0, `Color.secondary`. Used as the divider between the Dictate hero and the Recent list region, and (if reached) before the Diagnostics footer row.

### 4.6 `.glassEffect()` — NOT used

watchOS 26 introduced `.glassEffect()`. The watch target deploys to watchOS 26.0 (`project.yml:6`), so the API is callable. But:
- The Dictate hero already has a strong blue gradient — `.glassEffect()` over it would mush the gradient.
- Watch cards on a black AMOLED page don't benefit from glass — there's no underlay to refract.
- Battery / CPU cost: every glass surface ticks an extra render pass.

Decision: **do not** use `.glassEffect()` in this overhaul. Revisit if `WatchCard`'s flat fill reads as too plain after on-device review.

---

## 5. Per-screen design

### 5.1 RootView (post-overhaul)

```
┌──────────────────────┐
│         Jot          │  ← navigationTitle, inline
│  ┌────────────────┐  │
│  │     🎤         │  │
│  │   Dictate      │  │  ← MicButton, ~96×64 capsule (unchanged)
│  └────────────────┘  │     blue gradient (jotBlueTop → jotBlueBottom)
│                      │
│  3 pending sync ⓘ    │  ← amber caption (when queue.pendingCount > 0)
│                      │     The "ⓘ" is a tap target — see §5.2.
│  ─── RECENT ─────    │  ← WatchSectionLabel "RECENT"
│  • "remember to —"   │  ← inline transcript rows, max 5
│   2m · ⌚            │
│  • "the keyboard …"  │
│   17m                │
│  • "—"               │
│   1h · ⌚            │
│  Show all (10) ›     │  ← only if store.transcripts.count > 5
│                      │
│  Last synced 2m ago  │  ← LastSyncedCaption (dimmed)
│                      │
│  Sync diagnostics ›  │  ← WatchUtilityRow (caption2, secondary.opacity(0.65))
└──────────────────────┘
```

Structure:
- Outer `NavigationStack` (unchanged).
- Page container becomes a `ScrollView` (was a flat `VStack` — change is required to let Diagnostics live "below the fold"). Crown-driven scroll inherits for free.
- Top region: `MicButton` (existing), centered, ~64pt tall, ~96pt wide. Wrapped in a `VStack` with `.padding(.top, 4)` and `.padding(.bottom, watchPageGutter)` so it doesn't collide with the navigation bar.
- Sync ribbons (amber pending, green ack) sit immediately under the Dictate hero in a fixed-height `VStack` slot so the layout doesn't jump when they appear/disappear. The amber ribbon becomes a `Button` whose tap pushes `DiagnosticsView` (see §5.2).
- `WatchSectionLabel("RECENT")` separator.
- Inline transcript rows — `ForEach(store.transcripts.prefix(5))` rendered as `WatchTranscriptRow` (same content as today's `TranscriptRow`, wrapped in a `NavigationLink` to `TranscriptDetailView`, with `.contentShape(Rectangle())` applied to extend the tap region across the row).
- "Show all (N)" row — only when `store.transcripts.count > 5` — `NavigationLink` to `RecentTranscriptsView` (which keeps its current full-list role).
- `LastSyncedCaption` (existing styling, dimmed).
- `WatchUtilityRow("Sync diagnostics", systemImage: "stethoscope")` → `NavigationLink` to `DiagnosticsView`.

Rationale:
- Cold open shows Dictate without scrolling (HIG: above-the-fold primary action).
- Recents is the next thing the eye lands on after the Dictate hero — no longer a peer of a utility surface.
- Diagnostics is a single muted row at the bottom of a scrollable region — discoverable, but visually subordinate.

**ASSUMPTION:** inlining 5 transcript previews on the root is cheap given `WatchTranscriptStore.shared.transcripts` is already an in-memory array of `WatchTranscript` value types capped at 10. No paging, no extra fetches. If row rendering becomes a hot path on cold-launch, drop to 3.

### 5.2 Sync stuck affordance (new)

When `queue.pendingCount > 0` for >30s without a successful ack, the amber "N pending sync" ribbon gains a "Sync stuck?" subline:

```
3 pending sync · Sync stuck? ›
```

Tap target is the whole row (with `.contentShape(Rectangle())`); tap pushes `DiagnosticsView`. The 30-second threshold uses a simple `Task.sleep` watcher kicked off when `pendingCount` first goes >0 and cancelled when it drops to 0 or an ack arrives. This is the discoverability backstop the user asked about: Diagnostics is buried by default, but the moment sync is actually broken, the path to Reset is one tap from the root.

**ASSUMPTION:** 30s is a reasonable "stuck" threshold for the foreground case (we don't want to nag during normal background queueing). Adjustable in code; not a tunable.

### 5.3 RecentTranscriptsView (post-overhaul)

Two paths into this view:
1. The "Show all (N)" row on RootView (when >5 transcripts).
2. Direct navigation from URL deep-links (not applicable today; future-proof).

Visual changes:
- Replace `List` with `ScrollView { LazyVStack }` so rows can be wrapped in `WatchCard` groupings without the default `List` row chrome (which adds an opaque background and disables custom card styling).
- Two grouped cards:
  - "Transcribing…" entries (if any) in a top `WatchCard`.
  - All transcripts in a second `WatchCard`, rows separated by 1pt `Color.primary.opacity(0.06)` dividers.
- `LastSyncedFooter` retained at the bottom; styling matches §4.2 utility row caption.
- `EmptyStateRow` retained (mic.slash icon + copy) — wrap it in a single `WatchCard` for visual consistency.

Tap regions: every row gets `.contentShape(Rectangle())` defensively.

### 5.4 DiagnosticsView (content unchanged, placement changed)

Keep all content exactly as shipped in build 46. Only changes:
- Wrap the status card and the Reset sync button in a `WatchCard` each so they pick up the new surface language.
- Rename `navigationTitle` from "Sync" to "Diagnostics" — matches what the entry-point row is labeled and matches the user's mental model when they go looking for it.
- The escalation banner already uses a tinted RoundedRectangle background; leave it as-is (the amber tint is meaningful).

### 5.5 TranscriptDetailView (post-overhaul)

Wrap the transcript body in a `WatchCard` for visual consistency with the rest of the new language. Headers (date, time, watch glyph row) sit above the card in the existing dimmed style.

Optional polish: typography ramp on the body — keep `.font(.body)` (Dynamic Type still scales it). No serif here; SF on watch.

---

## 6. Touch-target fix

**File:** `Jot/Watch/Views/RootView.swift:50` and `:66`
**Fix:** add `.contentShape(Rectangle())` to each `NavigationLink` label's `HStack`.

```swift
// BEFORE
NavigationLink {
    RecentTranscriptsView()
} label: {
    HStack {
        Text("Recent") …
        Spacer()
        Image(systemName: "chevron.right") …
    }
}
.buttonStyle(.plain)

// AFTER
NavigationLink {
    RecentTranscriptsView()
} label: {
    HStack {
        Text("Recent") …
        Spacer()
        Image(systemName: "chevron.right") …
    }
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

In the new IA the second `NavigationLink` (Diagnostics) is removed from this level entirely, eliminating the hit-test ambiguity at its source. The `.contentShape(Rectangle())` rule is still added to every new row primitive in the rebuild (`WatchTranscriptRow`, `WatchUtilityRow`, "Show all" row, Sync stuck row) as a defensive standard for the watch target.

---

## 7. Implementation sequencing

Ordered so each step compiles + runs in isolation; no flag-day rewrite.

1. **Extend `JotDesignWatchSafe.swift`** with the new tokens from §4.1 (spacing constants, `watchCardFill`, `watchHairline`, `watchHighlight`, `watchUtilityInk`). No new files — `Shared/JotDesignWatchSafe.swift` is already in the JotWatch sources block, so no xcodegen run required.
2. **Add `WatchCard`, `WatchSectionLabel`, `WatchUtilityRow` private helpers inside `RootView.swift`** (collocated for v1; promote to a `Watch/Views/WatchPrimitives.swift` file only if a second view needs them — at that point add the file to the `Watch` glob already in `project.yml` and re-run `xcodegen`).
3. **Rewrite `RootView.body`** per §5.1:
   - Wrap the page in `ScrollView`.
   - Keep the existing `MicButton` (unchanged).
   - Keep the existing `pendingCount` / sync ribbon logic; extend the amber ribbon to become a `Button` per §5.2 (add the 30s "stuck" timer task).
   - Insert `WatchSectionLabel("RECENT")`.
   - Inline the first 5 transcripts using a new `WatchTranscriptRow` (lifted from `RecentTranscriptsView.TranscriptRow`, with `.contentShape(Rectangle())` and a `NavigationLink` to `TranscriptDetailView`).
   - "Show all (N)" `NavigationLink` to `RecentTranscriptsView` when `count > 5`.
   - `LastSyncedCaption`.
   - `WatchUtilityRow("Sync diagnostics", systemImage: "stethoscope")` `NavigationLink` to `DiagnosticsView`.
   - Remove the standalone Diagnostics `NavigationLink` and the `Divider` that separated Recents from Diagnostics.
4. **Touch-target defensive fix** — apply `.contentShape(Rectangle())` to every new row's label and to any retained row from §3.
5. **`RecentTranscriptsView`** (§5.3) — switch from `List` to `ScrollView { LazyVStack }`, wrap transcript groups in `WatchCard`s, keep the existing Transcribing / EmptyState / LastSynced subviews. Promote `WatchTranscriptRow` to file scope so both views consume the same component.
6. **`DiagnosticsView`** (§5.4) — wrap the two existing subviews (statusCard, Reset button) in `WatchCard`s. Rename `navigationTitle` to "Diagnostics". Leave escalation banner unchanged.
7. **`TranscriptDetailView`** (§5.5) — wrap the body `Text` in a `WatchCard`. Otherwise unchanged.
8. **`features.md` §2.13 update** — update the "Watch home screen" paragraph to reflect the new IA (inline Recents under Dictate, Diagnostics buried in footer), and add a sentence under "Recent transcript list" about the "Sync stuck?" affordance. Do NOT mention Swift types, file paths, or framework names per `CLAUDE.md`'s features.md style rules.
9. **Manual on-device pass** — see §9.

Estimated cost: ~6h of code + ~2h of on-device shaping. No new model code, no Sync changes, no schema work.

---

## 8. Schema impact

None. No `@Model` types touched. No `JotSchemaVN.swift` changes. No `MigrationStage` additions. The watch target's `Shared/` includes are unchanged.

---

## 9. Verification

On a 40mm physical watch (preferred — Simulator AMOLED rendering is unreliable):

- [ ] Cold open: Dictate hero is fully visible above the fold without scrolling. Time-to-tap from raise-wrist ≤ 1.5s.
- [ ] Tap Dictate → recording sheet appears with no lag. Stop → returns to root.
- [ ] After a fresh recording: "1 pending sync" amber appears under Dictate. Wait for iPhone ack → "✓ 1 synced" green ribbon appears for ~2s, then auto-dismisses (existing behavior preserved).
- [ ] Wait 30s with pending > 0 and the phone unreachable → the amber ribbon gains "Sync stuck? ›". Tap → Diagnostics pushes.
- [ ] From DiagnosticsView, tap Reset sync. Verify the existing escalation banner appears after 2 consecutive resets without ack (existing behavior unchanged).
- [ ] Scroll past Dictate → first 5 transcripts visible. Tap any row → TranscriptDetailView pushes. Back-swipe → scroll position preserved.
- [ ] Tap the right edge of a Recent row (in the gap between text and chevron) → opens the correct transcript every time (10/10 taps). This is the regression check for the original bug.
- [ ] Scroll further → "Show all (N)" row visible (if >5 transcripts) → tap → RecentTranscriptsView pushes the full list.
- [ ] Scroll all the way to the bottom of root → "Sync diagnostics" muted footer row visible. Tap → DiagnosticsView pushes.
- [ ] AOD: raise wrist to dim mode → root surface stays legible, no animations running on Dictate.
- [ ] Reduce Motion on → no animated ribbons (existing breathing animation in TranscribingRow is already guarded).
- [ ] VoiceOver: swipe through the root surface → Dictate is the first element; Recents transcripts are grouped under a "RECENT" header; Diagnostics is last. No order surprises.
- [ ] Crown rotation: rotates the scroll position smoothly, no focus-snap weirdness on the rows.
- [ ] On a watch with `store.transcripts.isEmpty`: root shows Dictate + amber/green ribbons (if any) + "RECENT" header + an empty-state card ("No transcripts yet…") + Sync diagnostics. No crashes on empty state.

---

## 10. Risk surface

1. **Rendering perf on 40mm at cold launch.** Inlining 5 transcript rows + 2 sync ribbons + WatchCards on the root surface adds ~7-9 SwiftUI subtrees vs. today's 4. watchOS launches the app at a lower clock speed than iPhone; cold launch could regress by 100-300ms. **Mitigation:** the `WatchTranscriptStore.shared.transcripts` array is already in memory at launch (singleton). No data fetching is added. If on-device profiling shows regression, drop the inline preview from 5 to 3 rows and rely on "Show all" sooner. Worst case: defer the inline preview behind a `.task` modifier so the Dictate hero paints first, then the rows fill in.

2. **`.glassEffect()` availability vs. omission.** The plan deliberately skips `.glassEffect()` (§4.6). Risk: the flat `WatchCard` fill might read as visually plain on-device, and an iteration cycle later we'd want it. **Mitigation:** `WatchCard` is a single private struct — adding a `.glassEffect()` modifier behind `if #available(watchOS 26.0, *)` is a one-line change if we change our minds.

3. **Scrollable-but-discoverable trade-off for Diagnostics.** The user said "below to scroll down" — but a hidden affordance is only useful if the user knows to scroll. **Mitigation:** the "Sync stuck?" affordance on the amber ribbon (§5.2) is the primary discovery path — Diagnostics is buried only when nothing is broken. The footer row is the secondary path. The "Show all" row above the footer also signals "there's more below" — visually breaking the assumption that the page ends at the transcripts.

4. **Navigation stack depth.** Today the root pushes 1-deep (Recents or Diagnostics). The new IA can push 2-deep (root → Recents → Detail, or root → Diagnostics). 2-deep nav on a 40mm screen with the small back chevron is uncomfortable. **Mitigation:** every push is one screen, never two simultaneously; back-swipe is one gesture per pop. This is the standard watchOS pattern; no novel friction.

5. **`features.md` drift.** §2.13 currently describes "a row that navigates to the recent transcript list" — the new IA inlines that list. **Mitigation:** the §2.13 update is step 8 in the sequence and explicitly covers the IA change. The `[Home library](#1-2-...)` cross-link in §2.13 stays valid; no other section cross-links to "Recent" on the watch, so no bidirectional updates needed elsewhere. Per `CLAUDE.md` rules: no Swift types, no file paths, no framework names in the updated copy.

---

## Open assumptions (flag if any are wrong)

- Inlining the top 5 transcripts on root is preferred to a dedicated "Recents only" surface. (Alternative: keep RootView as a Dictate-only hero with a single "Recent ›" row that pushes the full list, and put the Diagnostics footer inside the pushed RecentTranscriptsView. That's the lighter-weight version of this plan.)
- The 30-second "Sync stuck?" threshold is right. (Alternatives: 60s, or only when an ack failure is explicitly received.)
- Skip Fraunces on watch — SF is the right idiom at watch scale.
- `.glassEffect()` is not adopted in this overhaul.
- Diagnostics is renamed to "Diagnostics" in the navigation title (was "Sync"). The link from the root utility row is also "Sync diagnostics".
