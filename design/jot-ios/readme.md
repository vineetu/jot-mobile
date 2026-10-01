# Jot Design System

**Jot** is a privacy-first **voice-dictation app for iPhone** (with an Apple Watch companion).
Its core loop: tap the Jot key on the iOS keyboard → Jot pops up and captures your voice →
on-device transcription → the text pastes back into whatever app you were typing in.
Features documented here: the **home/library**, the **recording surface** (with the
"swipe back to your app" coaching cue), **Ask Jot** (voice-first Q&A over your own notes,
Beta), the **setup wizard** (7-step onboarding), and the **App Store product page**.

The production app is native **SwiftUI/UIKit**; everything in this system is the HTML/React
design source of truth those screens were built from.

## Sources consolidated here
- `ui_kits/` — interactive forks of the finalized design prototypes (wizard, iOS app, watch,
  App Store); each kit carries its original deep handoff spec (`SPEC.md` / `*_SPEC.md`)
- `appstore/` — App Store marketing surface: final raster exports (`export/`) + preview video (`video/`)
- `assets/logo/`, `jot-icon-pack/` — finalized brand mark + Xcode-ready app icons (LOCKED)
- `uploads/` — production screenshots (light + dark + watch, June 2026) — ground truth
- `FEATURES.md` — the full user-facing product feature inventory (voice & intent included)
- `Production Audit.html` — screenshot-vs-system audit record

---

## CONTENT FUNDAMENTALS

**Tone: honest, calm, second-person, a little wry.** Jot talks to "you" and refers to
itself as "Jot" (never "we" except in transparency notes). Sentence case everywhere —
no Title Case headers, no exclamation marks, **no emoji, ever**.

- Titles are short editorial statements, often with a period: *"Welcome to Jot."*,
  *"You're ready."*, *"Settings."*, *"Start jotting."*
- Body copy is plainspoken and concrete: *"Jot needs the mic to transcribe. Audio is
  processed on your iPhone and discarded."* Privacy claims are stated as facts, not marketing.
  The settings footer reads: *"Made with care in San Francisco. No accounts, no cloud,
  no telemetry."*
- **Radical honesty is a brand feature.** Footnotes admit platform limitations:
  *"We'd skip this step if we could. Apple doesn't let keyboards use the mic directly —
  so Jot hops back to capture. If that ever changes, this goes away."* Keep this voice.
- Em-dashes are the signature connective: *"Voice transcription for fast messaging —
  dictate into any app."*
- Anything **spoken** (live transcript, questions, suggestions) renders in Fraunces italic —
  the typography itself distinguishes the user's voice from app chrome.
- Caps labels (`YOU ASKED`, `SOURCES`, `BETA`) are tiny, bold, letter-spaced — used sparingly.
- Buttons are verbs or plain confirmations: `Get started`, `Grant microphone`, `Got it`,
  `I tried it`, `Continue`, `Start jotting.`, `Ask another`, `Type instead`, `Jot down`
  (the keyboard's record key), `Articulate` (the ✨ rewrite CTA on transcripts).
- **Verified production strings** (from June 2026 screenshots): recording surface says
  *"You don't have to watch this — looking away helps you find the words."*; the keyboard's
  live panel says *"We tidy this up when you stop"*; W5 is *"Now try the keyboard"* with
  *"Listening for your text…"*; keyboard recents header toggles *"Opens in Jot"* /
  *"Pastes here"*.
- Tiny caps **status badges**: green `READY` / `ALWAYS` pills, grey `EXPERIMENTAL` pill,
  green `PASTE`/`PUBLISH` + blue `VOCAB` event chips in diagnostics.
- **Home screen (verified, both modes):** header is the tiny j-badge + "Jot" with glass `?`
  and gear circles; a large Fraunces-italic headline **rotates through dictate CTAs**
  (*"Think out loud — no need to slow down."*); date caption; search bar + blue sparkle
  Ask pill; library card with `TODAY` caps, blue `LATEST` caps, the newest entry as a
  quoted serif-italic featured line, SF rows with right-aligned time·duration
  (tabular), and a **coral ✨ on AI-rewritten rows**. The FAB reads **"Jot down"** with a
  mic glyph — same label as the keyboard's record key.
- **Recording surface micro-messages rotate** (verified): *"Recording stays on while you
  go. Your words land back in that field."*, *"You don't have to watch this — looking
  away helps you find the words."*

## VISUAL FOUNDATIONS

**Color.** One accent: **brand blue** — canonical `#1A8CFF` (`--jot-accent`), accent gradient
`#1A8CFF → #0064CC`, wizard-CTA 3-stop `#2E9BFF → #0E7AE6 → #0064CC`.
> ### ⛔ CORAL = AI surfaces ONLY
> The coral ramp (`#FF6B57 → #E0533F`, `--jot-coral-*` / `--jot-ai-accent`) marks **AI
> Rewrite surfaces and nothing else**: the Rewrite/Cleanup icon tiles, the ✦ sparkle on
> AI-rewritten entries, and the `+ New prompt` button. It is NOT the brand accent and must
> never appear on any non-AI surface — and new AI features default to **blue** (Ask Jot is
> blue by explicit decision). When in doubt: blue.

Permitted non-blue colors are *functional*, never accents: orange mic tile + green success
tile + parchment keyboard tile (onboarding hero tiles only); `--jot-red` for trash icons;
iOS-green toggles; the amber mic-privacy dot and green continuity glyph (OS status-bar
chrome). Note the orange **mic tile** (`#F6A93B→#E8841C`) is a semantic "microphone"
identity, not a usable accent.

**Backgrounds.** Never flat, but subtle. **Dark (verified):** deep navy with a soft blue
glow from the top fading to near-black — the prototype `--bg-screen` dark gradient is
accurate; settings/sub-screens sit slightly flatter and darker. **Light (verified):** a
cool blue-grey wash with no visible warm corner — keep the warm radial at or below its
tiny spec alpha, or drop it. In dark mode, cards pick up a faint blue hairline border
(visible on Help/feedback cards). The **Apple Watch is always true black** with the blue
pill, amber sync states, and green connected states.

**Type.** Two voices (see `tokens/typography.css`): **Fraunces** for the editorial layer;
**SF Pro/system** for chrome. Fraunces itself has **two modes** (verified in screenshots):
- **Upright SemiBold + period** for in-app page titles: *Settings.*, *Help* (38/600).
- ***Italic*** for onboarding titles, subtitles, and anything **spoken**: live transcripts,
  streaming keyboard text, Ask questions, "Listening for your text…".
- **Transcript-detail body is plain SF on a white card** — NOT serif. Serif transcript
  styling belongs to live/streaming states only.
The production app bundles **Fraunces statics**: `Fraunces72pt-Regular`,
`Fraunces72pt-SemiBold` (no Medium exists — 600 is the lightest above Regular),
`Fraunces72pt-Italic` (≥24pt) and `Fraunces9pt-Italic` (~19pt body). Editorial sizes:
display 38/600, title 30/600, body 24/400, italic 19. The DS loads variable Fraunces from
Google Fonts — visually equivalent. Numerals in timers are always `tabular-nums`.

**Glass chrome.** Buttons/pills over content are translucent: `--chrome-fill` +
**0.5px** `--chrome-bord` border + `backdrop-filter: var(--blur-chrome)`. ALL borders
in the system are 0.5px hairlines.

**Cards** are barely-there: `--card` fill (6% white in dark), 0.5px `--card-bord`,
radius 18px (settings/step cards) to 28px (transcript card). No drop shadows on cards;
shadows are reserved for **floating** elements (toasts, app-switch cards) and **blue glows**
under CTAs (`--shadow-cta`, `--shadow-fab`).

**CTAs.** Full-width pill, height 62–64, fully rounded, blue gradient fill, white SF 600
label, blue glow shadow + inset top highlight. Press state: `scale(0.975)` (pills) /
`scale(0.9)` (small circles), 0.12s. Hovers are not an iOS concept — press scale only.

**Hero tiles.** Squircle gradient tiles (radius ≈ 0.245–0.30 × size) with white glyph,
inset top sheen, colored glow below. The app-icon tile uses `--jot-icon-grad` (168°).

**Motion.** Signature ease `cubic-bezier(0.45, 0.02, 0.2, 1)`; sheets use
`cubic-bezier(0.32, 0.72, 0, 1)`. Vocabulary: pulse (breathing dots/sparkle), blinking
caret (1s steps), shimmer skeletons, rise/fade reveals (0.4s), word-by-word streaming text
(~34–135ms/word). Always honor `prefers-reduced-motion` — show resolved end-states.

**Layout.** iPhone logical canvas 390–393 × 844–852. Screen padding 24px (wizard) /
20–22px (in-app). Sheets rise to ~44pt below the status bar with 40px top corners.
Primary actions dock at the bottom. Progress dots, not bars.
**Recording transport order (production): pause · Stop pill (center) · trash (right,
red glyph on white circle)** — the swipe-cue handoff's trash·pause·Stop order is outdated.
Transcript detail's bottom bar: trash · pencil · ✨ Articulate (blue pill) · copy.

**Audit trail.** `Production Audit.html` records the June 2026 screenshot audit (what
matched, what was fixed). Raw screenshots live in `uploads/` — light set, dark set, and
Apple Watch. `FEATURES.md` is the canonical inventory of every user-facing feature and
the product's intent ("How Jot Should Feel") — read it before designing any new surface.

## ICONOGRAPHY

- **No icon font, no emoji.** All glyphs are inline SVG, stroke-based, **round caps/joins**,
  stroke ≈ 2.4–3.6 at small sizes — visually equivalent to SF Symbols (production uses
  SF Symbols: `sparkles`, `chevron.left`, `pause.fill`, `trash`, `stop.fill`, `mic`, etc.)
- Reusable glyph React components ship in `components/brand/` and the prototypes
  (`wizard-ui.jsx`, `ask-ui.jsx`): mic, keyboard, check, chevron, close, globe, watch,
  sparkle (4-point, the Ask Jot motif), send up-arrow, document, copy.
- **The logo is LOCKED** (see `assets/logo/` + its `README.md`): lowercase stroked *j*
  with a 3-bar voice-waveform tittle (heights 10·18·10, never fused), round caps. White on
  blue/dark; gradient on light; mono `#1A8CFF` flat. App icon = blue 168° gradient tile +
  white mark + top sheen.
- The tiny "j" avatar badge (30px circle, blue gradient, Fraunces italic white *j*) is the
  in-app identity mark (home header, app-switch cards).

---

## PRODUCTION TOKENS (JotDesign, from the iOS codebase)

`tokens/production.css` mirrors the **shipping** Swift `JotDesign.*` tokens (provided from
the codebase, June 2026). Where prototype and production disagree, **production wins for
in-app surfaces**; the three handoff prototypes remain authoritative for the screens they
specify (wizard, Ask Jot, recording/swipe-cue). Highlights:

- **Accent:** `--jot-accent #1A8CFF` app-wide; Dictate pill / Recents use the 2-stop
  `--jot-accent-grad`; the keyboard uses iOS blue (`#007AFF`/`#0A84FF`) with deep `#0064CC`.
- **Ink/page ramps:** `--jot-ink`, `--jot-mute(-weak)`, `--jot-page-*` (wallpaper `#15171C`
  dark / `#D1D3DA` light) — these are the real app surfaces, flatter than the prototypes'
  blue-glow gradients.
- **Status:** success `#34C759`, warning `#FF9F30`, record `#FF3B30`, recording dot
  `#E0173B` + 18% halo.
- **Keyboard v2:** full chrome/glass/key token set (`--kb2-*`), recording tint + hairline,
  streaming text `#3C5A99`/`#9CB3E5`.
- **Settings icon tiles:** 14 semantic top/bottom pairs (`--icon-*`) — speech-model blue,
  vocabulary teal, AI Rewrite coral, privacy green, full-access purple, mic-ready orange, etc.
- **Surfaces:** iOS 26 `.glassEffect(.regular)` + 0.5pt white@18% border (`regular`);
  `heavy` adds 1pt white@22% + bigger shadow; `key` chrome controls are white-gradient
  (light) / `secondarySystemFill` (dark) — *not* glass.
- **Spacing:** legacy (pageMargin 16, cardRadius 16, sheetRadius 24) and **v0.9**
  (pageGutter 18, cardRadius 18, tileHero 84, pillRadius 999). Settings page bg gradient
  `#F5F5F5 → #E0E0E0` (light).

## INDEX

| Path | What |
|---|---|
| `styles.css` | Global CSS entry — import this one file |
| `FEATURES.md` | Full product feature inventory + intent/voice principles |
| `tokens/` | colors · typography · spacing · effects · fonts · **production (JotDesign mirror)** |
| `tokens/SWIFT_MAPPING.md` | CSS token ↔ Swift `JotDesign.*` translation table for engineering handoffs |
| `assets/logo/` | Locked marks, wordmarks, app icons (PNG + SVG) + usage README |
| `jot-icon-pack/` | Xcode-ready AppIcon sets (iOS + watchOS) |
| `components/brand/` | JotMark, JotAppIcon, HeroTile + glyphs |
| `components/actions/` | CtaPill, GlassButton, GlassPill, TextLink, IosToggle |
| `components/display/` | GlassCard, ProgressDots, Waveform, CitationChip, SourceRow, StopPill |
| `guidelines/` | Specimen cards rendered in the Design System tab |
| `ui_kits/ios_app/` | Recording surface + Ask Jot (interactive) + deep specs |
| `ui_kits/setup_wizard/` | 7-step onboarding (interactive) + deep spec |
| `ui_kits/watch/` | Apple Watch companion mock |
| `ui_kits/app_store/` | App Store product page |
| `appstore/` | Marketing exports (`export/`) + preview video (`video/`) |
| `uploads/` | Production screenshots (light · dark · watch) |
| `Production Audit.html` | Screenshot audit record |
| `SKILL.md` | Agent-skill entry point |

**For deep specs** (exact animation timelines, every screen's copy, state machines), read
`ui_kits/setup_wizard/SPEC.md`, `ui_kits/ios_app/ASK_SPEC.md`, and
`ui_kits/ios_app/RECORDING_SPEC.md` — they are authoritative and very detailed.
For what every feature *does*, read `FEATURES.md`.
