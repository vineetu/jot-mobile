# CSS token ↔ Swift `JotDesign` mapping

For handoffs to Claude Code: when a spec references a CSS custom property, use the
matching Swift token that already exists in the Jot codebase. (Swift names from the
JotDesign token dump, June 2026.)

## Colors

| CSS (this DS) | Swift (codebase) | Value |
|---|---|---|
| `--jot-accent` | `jotAccent` | `#1A8CFF` |
| `--jot-accent-grad` | `jotBlueTop → jotBlueBottom` | `#1A8CFF → #0064CC` |
| `--jot-blue-1/2/3` | `jotCtaBlueTop/Mid/Bottom` | `#2E9BFF / #0E7AE6 / #0064CC` |
| `--jot-kb-accent` | `jotKeyboardAccent` | `#007AFF` light / `#0A84FF` dark |
| `--jot-kb-accent-deep` | `jotKeyboardAccentDeep` | `#0064CC` |
| `--jot-coral-top/bottom` (`--jot-ai-accent`) | `jotCoralTop → jotCoralBottom` | `#FF6B57 → #E0533F` — AI marker only, never expand |
| `--jot-ink` | `jotInk` | `#1C1C1E` / white@96% |
| `--jot-mute` | `jotMute` | `#8B8B95` / white@60% |
| `--jot-mute-weak` | `jotMuteWeak` | `#C7C7CC` / white@30% |
| `--jot-page-base` | `jotPageBase` | `#D1D3DA` / `#15171C` |
| `--jot-page-ink(-secondary/-caption)` | `jotPageInk(Secondary/Caption)` | see production.css |
| `--jot-page-separator` | `jotPageSeparator` | 10% |
| `--jot-success` / `--jot-success-ink` | `jotSuccess` / `jotSuccessInk` | `#34C759` / `#1B8E3E` |
| `--jot-warning` / `--jot-warning-ink` | `jotWarning` / `jotWarningInk` | `#FF9F30` / `#B87314` |
| `--jot-record` | `jotRecord` | `#FF3B30` |
| `--jot-recording-dot` / `--jot-recording-halo` | `jotRecordingDot` / `jotRecordingHalo` | `#E0173B` / @18% |
| `--kb2-*` | keyboard v2 tokens | see production.css table |
| `--icon-*-top/bottom` | Settings semantic icon pairs | see production.css |

## Typography

| CSS | Swift (`JotType`) | Face / size |
|---|---|---|
| `--ts-editorial-display` (38) | `editorialDisplay` | Fraunces72pt-SemiBold 38 |
| `--ts-editorial-title` (30) | `editorialTitle` | Fraunces72pt-SemiBold 30 |
| `--ts-editorial-body` (24) | `editorialBody` | Fraunces72pt-Regular 24 |
| `--ts-editorial-italic` (19) | `editorialItalic` | Fraunces9pt-Italic 19 |
| `--font-sys` body | `bodyChrome` / `chromeBold` | system `.body` / semibold |
| `--ts-caption` caps | `captionLabel` | 11pt bold, UPPERCASE, tracking 0.6 |
| timers | `monoTimestamp` | `.caption` monospaced, tabular |
| v0.9: `sectionLabel` 11/700 track 1.5 · `rowTitle` 15/500 track −0.2 · `rowSub` 12.5 · `monoEditor` 12.5 mono lh 1.6 |

Italic Fraunces = onboarding titles + anything spoken (live transcript, questions,
streaming text). Upright SemiBold + period = in-app page titles ("Settings.", "Help").

## Spacing / radii (`JotDesign.Spacing`)

| CSS | Swift | Value |
|---|---|---|
| `--page-margin` | `pageMargin` | 16 |
| `--card-gap` / `--section-gap` | `cardGap` / `sectionGap` | 12 / 20 |
| `--card-radius` / `--sheet-radius` | `cardRadius` / `sheetRadius` | 16 / 24 |
| `--card-radius-v09` / `--page-gutter` | `cardRadiusV09` / `pageGutter` | 18 / 18 |
| `--card-pad-h/v` | `cardPaddingH/V` | 16 / 14 |
| `--tile-row` / `--tile-hero` | `tileRowSize` / `tileHeroSize` | 30 / 84 |
| `--pill-radius` | `pillRadius` | 999 |
| `--status-pill-h` / `--status-dot` | `statusPillHeight` / `statusDotDiameter` | 28 / 5 |

## Surfaces (`JotDesign.Surface`)

- `regular` — iOS 26 `.glassEffect(.regular)` + 0.5pt white@18% border + shadow black@6% (r4,y4; light only)
- `heavy` — regular glass + 1pt white@22% border + shadow black@8% (r12,y8; light only)
- `key` — chrome controls (back/close/pause/trash), NOT glass: light = white gradient 0.92→0.78 + 0.5pt black@8% hairline; dark = `secondarySystemFill` + white@16% hairline
- `keyDim` — white gradient 0.55→0.42, black@6% border

## Glyphs

DS `JotGlyph` names → SF Symbols: sparkle→`sparkles`, chevron-left→`chevron.left`,
pause→`pause.fill`, trash→`trash`, mic→`mic.fill` (custom in heroes), check→`checkmark`,
arrow-up→`arrow.up`, doc→`doc.text`, copy→`doc.on.doc`, keyboard-mini→`keyboard`,
globe→`globe`, recents-open→`arrow.up.forward.app`, thumbs→`hand.thumbsup/down(.fill)`.
The j+waveform brand mark is custom — never substitute.
