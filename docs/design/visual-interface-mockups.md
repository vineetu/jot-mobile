# Visual Interface Design — Jot iOS

**Status:** design exploration, not an implementation spec.
**Audience:** whoever is about to pick a direction for Jot's main screen.
**Author:** visual-interface-designer (jot-mobile team).
**Pair-read:** [`voice-interaction-patterns.md`](./voice-interaction-patterns.md) — the interaction layer this surface has to host.

---

## Frame

Jot is a voice-first iOS 26 dictation app: press hotkey → speak → transcript to clipboard, optional LLM cleanup, entirely on-device for the transcription path. The current `ContentView.swift` is functional but utilitarian — a status label, a big red circle, a box, a button row. It reads like a debug harness, not a product.

The brief: what should the main screen look like when the user opens it, such that *it looks like something Apple would ship*?

---

## 1. Current state critique

Auditing `Jot/App/ContentView.swift` against Apple HIG + the [Vercel web-interface-guidelines](https://github.com/vercel-labs/web-interface-guidelines) (adapted to iOS):

| # | Issue | Location | Severity |
|---|---|---|---|
| 1 | **Status is a whispered label, not a state.** A tiny headline-weight `Text("Recording…")` in red at top-left does none of the work Apple's Dynamic Island–era apps do to make state legible. | `ContentView.swift:85-89` | High |
| 2 | **The record button carries all aesthetic load.** A 160pt flat circle with a `.red` / `.accentColor` fill and two-weight SF Symbol. No level meter, no scale/press animation beyond a 150ms easeInOut fade, no shadow ramp. Reads "onboarding CTA," not "instrument." | `ContentView.swift:91-108` | High |
| 3 | **Transcript container is a grey box.** Literal `secondarySystemBackground` rounded rect, 180–260pt, placeholder "Your transcript will appear here." The text is the product — it shouldn't live inside an obvious container. | `ContentView.swift:110-122` | High |
| 4 | **Copy + Share are the same weight as the hero.** A `.borderedProminent` + `.bordered` pair with `Label` and icons, flush-left, no post-copy confirmation beyond flipping status text to "Copied to clipboard." | `ContentView.swift:124-141` | Medium |
| 5 | **No time display at all.** The user is recording into a void — no elapsed timer, no amplitude feedback, no indication the mic is actually hearing them. [Apple Voice Memos solves exactly this](https://support.apple.com/guide/voice-memos/welcome/mac) with a prominent waveform + timer. | — | High |
| 6 | **No empty state.** First-open users see the same "Your transcript will appear here." placeholder forever, with no onboarding, no hint about Settings, no explanation of what Jot is. | `ContentView.swift:112` | Medium |
| 7 | **Error state is a red banner at the bottom.** `.red` background, white `.footnote` text, 8pt rounded rect. Violates iOS norm (alerts/sheets for errors; inline for inputs); reads like a toast built in 2019. | `ContentView.swift:143-151` | Medium |
| 8 | **Settings is hidden behind a gear icon with no label in the glance path.** A user's first tap is usually *gear → permissions → back*. If that's the canonical first-run trail, it should be a visible "Set up Jot" affordance for at least the first few sessions, not a toolbar icon. | `ContentView.swift:52-60` | Low |
| 9 | **Toolbar title is "Jot" in default navigation-title-weight.** Doesn't ladder with the rest of the visual hierarchy; reads like a debug screen label. | `ContentView.swift:51` | Low |
| 10 | **Status copy.** `"Ready"`, `"Recording…"`, `"Transcribing…"`, `"Cleaning up…"`, `"Copied to clipboard"`. Mixed tone — some sentence case, some gerund, one final-state. Apple's tone guidance is consistent imperative + sentence case with `…` for in-progress states. | `ContentView.swift:155-163` | Low |
| 11 | **No tabular-nums on any numeric displays** (there are none — but there *should* be a timer, and when added it must be monospaced). | — | Low |
| 12 | **No haptic-coupled visual state change on copy.** The haptic fires (`.success`), but visually the screen just flips to `.copied` phase. [HIG guidance](https://developer.apple.com/design/human-interface-guidelines/haptics) is to pair haptics with a visible change — a toast, a checkmark, a pill. | `ContentView.swift:248-255` | Medium |

**Cross-cutting critique:** the screen optimizes for *the developer's mental model* (state machine with four phases + one output) instead of *the user's moment* (open the app; say the thing; use the words). The visible chrome ratio is too high for an app whose reason to exist is to disappear while you talk.

---

## 2. Design directions

Six directions. Each is a distinct voice, paired with a runnable SwiftUI mockup in [`mockups/`](./mockups/). All mockups are self-contained — drop any one into an Xcode preview canvas.

### Product constraint — mandatory: transcription history surface

Before the directions: Jot **must** surface a full history of every past transcription. This is not optional. The user has been explicit: *"a history of all the transcription is a mandatory thing. We need to have history — I'm thinking like a draggable thing from the bottom or left or right where we have a history of all transcriptions that users can look through."*

That reframes the directions into two structural families:

1. **History-as-primary:** the log *is* the main surface. Pulse and Ledger are built this way — every transcript stays on screen in reverse-chronological order; the "hero state" is the log itself.
2. **History-as-secondary:** the hero state is the live dictation moment (speak → paste), and history is behind a draggable surface — a bottom sheet, a side drawer, or a navigation push. Aperture, Granola, NothingJot, and Dictaphone are this family. Each must name its history affordance below.

The draggable-from-edge pattern the user suggested (bottom sheet or side drawer) is a safe default for the history-as-secondary family — it's native iOS (think Maps, Find My, the Apple TV remote panel), it keeps the hero state uncluttered, and on iPhone it reads as "a second layer of the same app," not "a different screen." Each secondary-family direction notes its specific choice below under **History surface.**

The mockup files at `docs/design/mockups/` currently render only the hero state — the history surface is described in prose per direction rather than drawn, to keep each mockup under the 250-line ceiling. Ledger's mockup (the history-as-primary exemplar) *does* render the log in full.

### Direction 1 — Aperture *(“Voice Memos native+”)*
**File:** [`mockups/1_Aperture.swift`](./mockups/1_Aperture.swift)
**Mood:** what Apple's own team would ship if dictation were a first-party iOS app. One surface, one affordance, borrowed from the Voice Memos / Translate language.
**Layout.** Top-aligned `NavigationStack` title ("Jot") → large SF Rounded **elapsed time** (56pt, tabular-nums) → **mic button inside a hairline ring** that doubles as a level meter → **status caption** in small-caps with letter-spacing → **transcript panel** with a subtle rounded rectangle and a hairline stroke → quiet **Copy / Share** row at bottom, muted until there's a result.
**Color + type.**
- Palette: purely semantic — `Color(.systemBackground)`, `.secondarySystemBackground`, `.primary`, `.secondary`, plus `Color.red` for the recording state and `Color.accentColor` for the idle mic.
- Type: `.system(size: 56, weight: .semibold, design: .rounded)` for the timer; `.subheadline` + `tracking(1.6)` for the caption; `.body` for transcript. No custom fonts.
**Micro-interactions.**
- Mic press → mic scales to 0.97, `.spring(response: 0.32, dampingFraction: 0.78)`.
- Amplitude drives a `.trim(from: 0, to: amplitude)` sweep on the outer ring, `.easeOut(0.12)`.
- Timer uses `.contentTransition(.numericText())` so seconds roll.
- Copy pulses the "Copy" button → toast-less; the caption becomes "Copied to clipboard" while the button shows a brief checkmark fill.
**Pairs with.** Voice-interaction pattern **#3 press-and-hold** (the ring becomes the hold-hint arc) and **#1 suffix commands** (the caption becomes "Command detected — tightened" after a suffix fires).
**History surface.** *Bottom-sheet drawer.* A thin hairline drag-handle pinned to the bottom-safe-area (8pt centered capsule in `Color.secondary`). Drag up (or tap) to reveal a `.sheet` with three `.presentationDetents`: small (12% — shows just the most recent 3 transcripts as a peek), medium (42% — scrollable list with search field), large (.large — fullscreen archive with date-section headers). Each row: time eyebrow in `.caption` monospaced, body preview 2-line clamp, trailing chevron. Tap a row → push a detail view with full transcript + Copy/Share/Delete. Matches Apple's Maps/Find-My precedent; leaves the hero state clean; keeps history one gesture away. *HIG: native `PresentationDetents`, standard sheet animation, no custom drag physics.*
**HIG compliance.** 10/10 — uses only Apple's own vocabulary. The only deviation from literal Voice Memos is that the waveform is on the *ring*, not a horizontal strip; this is HIG-legal and earns the app its own silhouette.

### Direction 2 — Granola *(“Editorial whitespace”)*
**File:** [`mockups/2_Granola.swift`](./mockups/2_Granola.swift)
**Mood:** Granola's web landing page, iA Writer, the Things 3 inbox. The whole app is a sentence.
**Layout.** Tiny inline serif "Jot" in the nav bar → metadata line (date · "On device") in uppercase tracking → **massive 44pt NY-serif headline** that *is* the state (`"Ready to listen." / "Listening…" / "Writing it down…" / "Here you go."`) → a single **Material-backed pill** ("Tap to dictate · 00:12") → **transcript as serif paragraph** with no visible container → footer of plain text buttons separated by dividers.
**Color + type.**
- Palette: semantic only. The warmth comes from *whitespace* and *type weight*, not pigment.
- Type: SF Pro Rounded for the pill; **`.design: .serif` (New York)** for headline and body. Serif carries the "reads like a letter" framing.
**Micro-interactions.**
- Headline text swap uses `.transition(.opacity.combined(with: .offset(y: 8)))` with a `.smooth` animation.
- Recording dot does `.scaleEffect(1.2).animation(.easeInOut(0.9).repeatForever(autoreverses: true))` — calm, not jittery.
- Transcript fades up on arrival; no other chrome moves.
**Pairs with.** Voice-interaction pattern **#4 implicit routing** (the headline becomes "Sending to Marcus…" with a full-width confirmation pill appearing beneath) and **#2 chained follow-ups** (previous transcript fades to 40% and new one replaces with the animated swap).
**History surface.** *Trailing nav-bar link + full-screen push.* A serif link in the nav bar's trailing position — `Archive` in small-caps italic serif, no chevron, no pill. Tap → `NavigationStack` push into a full-screen archive that maintains the editorial tone: date mastheads in larger serif, each transcript as a numbered entry (`Entry 42. · Tuesday, April 21.`), body text in the same serif with generous leading. Pull-to-refresh and search (via `.searchable`) feel native. *Why a push rather than a drawer:* Granola's whole point is calm, and a drawer-from-bottom violates that calm. A clean scene-change to a read-mode archive is more in keeping with a literary app (Books, Journal). *HIG: standard `NavigationStack` push, semantic back-chevron, `.searchable`.*
**HIG compliance.** 8/10 — deviates from Apple's preference for filled containers around interactive elements. Justified by the app's core promise: *quiet*. The pill satisfies minimum-44pt-touch-target. `Material` is an Apple-sanctioned primitive.

### Direction 3 — Pulse *(“Dynamic-Island-forward / voice-first”)*
**File:** [`mockups/3_Pulse.swift`](./mockups/3_Pulse.swift)
**Mood:** the interface disappears. The record affordance is a floating *island* pinned near the top-safe-area. Transcripts accumulate as a reverse-chronological log below.
**Layout.** Dark OLED base → **island pill** (capsule + `.ultraThinMaterial` + hairline stroke) hosts a mic button, an expanding waveform when recording, and a state label → **scrolling log** of transcript cards below, newest first, each with a monospaced timestamp eyebrow, body text, and row actions (Copy / Share / Delete).
**Color + type.**
- Palette: `Color.black` ground, `Color.white.opacity(0.04...0.12)` for surfaces, semantic red for the recording state, `Color.white.opacity(0.45...0.92)` for text hierarchy. Defensible brand choice: **defaults to `.dark` color scheme** because the island metaphor only works on dark — and on OLED iPhones, black saves battery.
- Type: SF Pro Rounded for the island label, SF Mono for timestamps (tracking 1.2, uppercase).
**Micro-interactions.**
- Island **expands horizontally** when tapped (`.spring(response: 0.45, dampingFraction: 0.82)`), maxWidth 260→340.
- Waveform bars re-randomize every 80ms, each animated with a snappy default.
- New transcript inserts at index 0 with `.transition(.opacity.combined(with: .offset(y: 12)))`.
**Pairs with.** Voice-interaction pattern **#2 chained follow-ups** (the log *is* the chain; each tap adds a row; long-press chains onto the previous) and **#3 press-and-hold** (distinct *island color* for hold-command mode — e.g., hold goes amber, tap stays white).
**History surface.** ***History-as-primary — already solved.*** The reverse-chronological log **is** the history. No secondary surface needed. The whole app is the archive; the island-pill is just the record affordance floating above it. This is Pulse's structural advantage and the argument for the direction. Scroll-to-search is handled by a `.searchable(placement: .navigationBarDrawer)` modifier on the scroll view — standard iOS pull-down behavior.
**HIG compliance.** 7/10 — aggressively dark-mode-only deviates from "Support both appearances." Justified because the Dynamic Island language is Apple's own, but adapted for a full-screen app. The log pattern is native (`Messages`, `Mail`).

### Direction 4 — NothingJOT *(“Monochrome industrial / Swiss”)*
**File:** [`mockups/4_NothingJot.swift`](./mockups/4_NothingJot.swift)
**Mood:** Nothing OS + Teenage Engineering OP-1 + Braun calculator. The most opinionated variant. Not for everyone, not the HIG-safest choice — but the most *memorable*.
**Layout.** Top strip: `JOT · 01` + `STANDBY / ● REC` in SF Mono with heavy tracking → massive **84pt mono timer** → **24-segment VU meter** (rectangles, not capsules, that light primary → orange → red) → **bordered REC/STOP pill** with a solid color dot + tracked mono label → bordered mono transcript pane → bottom strip `ON-DEVICE · PARAKEET · v1.0`. Behind everything: a subtle dot-matrix canvas.
**Color + type.**
- Palette: semantic `.primary` / `.secondary` / `.systemBackground` + `Color.red` + `Color.orange` for the VU's upper bands. Legible in both appearances.
- Type: SF Mono everywhere except the transcript body. Heavy weights, loose tracking.
**Micro-interactions.**
- VU segments animate with `.easeOut(0.1)` — discrete, mechanical.
- Status strip label flips color (primary → red) on record.
- Timer uses `.contentTransition(.numericText())` and mono digits.
**Pairs with.** Voice-interaction pattern **#1 suffix commands** (the suffix-command-detected state could flash the top-strip label amber: `SUFFIX ● CLEAN`). Harder to pair with implicit routing — the aesthetic is "instrument," not "assistant."
**History surface.** *Bottom-pinned archive strip → full-screen mono log.* A 44pt-tall strip pinned at the bottom of the screen shows `ARCHIVE · 0042 ENTRIES` in SF Mono heavy tracking. Tap → full-screen push into a monochromatic archive where each entry is a single tape-deck row: `#0042 · 09:02 · 00:18` (index, time, duration) on a mono header line, transcript body below, hairline rule between rows. Date sections are rendered as full-width mono-tracked banners (`TUE · 21 APR 2026`). No date picker icon, no animated chrome — just the list. Matches the instrument aesthetic: the archive looks like a print-out from a studio logger. *HIG: standard push nav; mono content is a theme choice, not a control violation.*
**HIG compliance.** 5/10 — deliberately non-Apple-shippable. Justified only if Jot wants a strong brand voice. Could live as an opt-in theme ("Pro mode") rather than the default.

### Direction 5 — Dictaphone *(“Editorial luxury / warm retro”)*
**File:** [`mockups/5_Dictaphone.swift`](./mockups/5_Dictaphone.swift)
**Mood:** a pocket recorder an essayist keeps in their jacket. Warm cream paper tone + New York serif + crimson accent + a *single scribble line* that replaces the amplitude bars.
**Layout.** Masthead (Jot · *"dictate, quietly"* in italic serif) over a hairline rule → **large serif headline that mirrors the state** ("A place to speak, and be written down." / "Listening, carefully." / "Setting the type…" / "Fresh ink.") → **thin scribble graph** of amplitude as a continuous stroke, 44pt tall → tactile **REC pill** with cream fill, subtle shadow, small-caps serif label → serif paragraph transcript → footer of underlined serif buttons (`COPY` · `SHARE` · `NEW ENTRY`).
**Color + type.**
- Palette: one **justified brand color** — a warm cream paper tone `Color(red: 0.98, green: 0.95, blue: 0.89)` — with an espresso ink `Color(red: 0.13, green: 0.10, blue: 0.08)` and a deep crimson accent `Color(red: 0.62, green: 0.13, blue: 0.13)`. Justification: the serif-on-cream language is how Apple Journal, Apple Books, and Apple TV+ pages already treat "literary" surfaces — Jot borrows that shelf.
- Type: **`.design: .serif`** (New York) for display, body, and buttons; SF Mono for the timer; SF Pro for nothing.
**Micro-interactions.**
- Scribble redraws continuously as amplitude changes (`Path`-based; `.easeOut(0.12)`).
- REC pill sits on an 10% opacity shadow (`.shadow(radius: 14, y: 6)`) that deepens on press.
- Footer buttons have a thin 0.5pt under-rule that could animate on hover (if ever ported to iPadOS with pointer).
**Pairs with.** Voice-interaction pattern **#4 implicit routing** (the headline becomes "To Marcus:" followed by serif body; confirmation pill matches the paper palette) and **#2 chained follow-ups** (previous transcript slides up into a smaller serif "marginalia" note).
**History surface.** *Side drawer from leading edge.* Tap a small `book.closed` SF Symbol in the masthead (leading-aligned, espresso-ink, hairline weight). The main surface slides 72% to the right, revealing a full-height cream sidebar of past entries from the leading edge — like a notebook's ribbon-bookmark interface. Each entry shows a serif date header (`· Tuesday, 21 April ·` in italic), a numbered entry label (`Entry #42`), and a two-line body preview in smaller serif. Tap → main surface slides further and loads that entry into the transcript block; the masthead headline updates to read `Fresh ink, from the archive.` *Why the leading edge, not the bottom:* the cream-paper masthead + serif identity feels like a physical notebook, and notebooks open from the spine. A bottom drawer would read as a modal; a side drawer reads as turning a page. *HIG: implemented as a `NavigationSplitView` on iPad-compatible builds, or a custom offset+gesture container on iPhone (with spring physics capped at ~0.85 damping so it feels like parchment weight). Respects reduce-motion — falls back to an instant snap.*
**HIG compliance.** 6/10 — the cream background is a brand deviation from `.systemBackground`. Falls back to system background in dark mode (see mockup). The serif-first typography is HIG-legal (NY is a first-party Apple font). The larger HIG question is whether Jot *wants* a voice this literary — it's further from utilitarian-dictation and closer to "Journal-adjacent."

### Direction 6 — Ledger *(“NothingJot × Pulse hybrid”)*
**File:** [`mockups/6_Ledger.swift`](./mockups/6_Ledger.swift)
**Why this direction exists.** After review, the user liked NothingJot's *instrument* feel but didn't want to copy Nothing OS wholesale. Ledger takes NothingJot's DNA (mono timer, VU, "operating a device") and grafts it onto Pulse's bones (Dynamic-Island-forward pill + chronological log + dark-mode-first), then swaps out every element that reads as Nothing-specific (see §3 audit below).
**Mood.** A CRT terminal from 1983 that got miniaturised into a clip-on recorder. A stenographer's ledger. An accountant's amber-phosphor monitor.
**Layout.** Top-pinned **instrument pill** hosts mic button, mono elapsed timer, a narrow 12-bar VU, and a mono `READY / REC / PROC` status chip — all inside a single ultraThinMaterial capsule. Below: a scrolling **ledger** where each transcript is an entry with a left-padded `#0042` session number in amber, a mono timestamp, a SF-Pro body paragraph, and three small mono action buttons (`COPY` / `SHARE` / `DELETE`). Hairline rules between entries. Very subtle horizontal ledger-paper rules in the background canvas.
**Color + type.**
- **Ground:** a near-black ink `Color(red: 0.06, green: 0.06, blue: 0.07)` rather than pure black — lets the ledger rules show without touching them with pure white.
- **Accent:** warm CRT **amber** `Color(red: 1.0, green: 0.72, blue: 0.10)`. Justified: amber is not owned by Nothing (Nothing's brand accent is red); amber is a 1970s-terminal / Dieter-Rams / OP-1-family color; and on an OLED dark surface amber reads as "status" without the urgency of red.
- **Type:** SF Mono (via `.system(design: .monospaced)`) for timer, session numbers, timestamps, status chip, action buttons. **SF Pro for transcript body text** — deliberately not mono, so the entry stays readable at all Dynamic Type sizes. This is the single most important type decision in the variant.
**Micro-interactions.**
- Pill expands horizontally on state change with a `.spring(response: 0.42, dampingFraction: 0.85)`.
- VU bars re-randomise every 80ms; color flips to amber while `.recording`, back to white-22% on release.
- New entry inserts at index 0 with an upward spring; session number auto-increments.
- Status chip is the instrument's "tally light" — flips color (white-60% → amber) the instant recording arms.
**Pairs with.** Voice-interaction pattern **#2 chained follow-ups** (each tap adds a ledger row, pattern of "what I said → what I asked you to do with it" stacks naturally) and **#3 press-and-hold** (hold arms the pill with a distinct ink-blue tint for command-mode, tap stays amber for dictation-mode — gives the instrument a second voice without adding a gesture).
**History surface.** ***History-as-primary — the log IS the canvas.*** Ledger shares Pulse's structural advantage: the main screen *is* the full archive of transcriptions, reverse-chronological, numbered (`#0042`, `#0041`, …). No drawer, no push, no secondary surface. This is the entire reason Ledger exists as a hybrid rather than staying purely NothingJot: with history mandatory, the log-of-entries scaffold is the product, and Ledger gives that scaffold an instrument-pill top and a ledger-paper background. Scroll-to-search: `.searchable(placement: .navigationBarDrawer)` pull-down; session-number search (`#0042`) and content search both land in the same input. The rendered mockup at `6_Ledger.swift` shows this directly — two seed entries visible on open, newest on top, with hairline rules between.
**HIG compliance.** 7/10 — dark-mode-first is the same accessibility concession as Pulse. Amber accent + ledger background are brand choices but both defensible (first-party Apple apps like Books and Journal carry strong brand color moments). No Nothing-IP pastiche (see §3).

---

## 3. NothingJot IP audit

After user review, the concern: NothingJot (Direction 4) risks being read as a Nothing OS knock-off. This section audits each element of `4_NothingJot.swift` against **Nothing's actual brand assets** (not my training-data memory), identifies what's direct pastiche vs. shared industrial-Swiss vocabulary, and lays out the departures that Ledger (Direction 6) makes.

### 3.1 What Nothing actually owns

Nothing's brand is built around a narrow, very recognisable set of assets. Sourced from [Nothing's Colophon Foundry typeface commission](https://fontsinuse.com/uses/59510/nothing-phone), [Nothing OS 3.0 coverage](https://www.androidauthority.com/nothing-os-3-hands-on-3488739/), and the [Nothing Phone (3) Glyph Matrix launch](https://design-milk.com/the-nothing-phone-3s-glyph-matrix-turns-notifications-into-pixel-art/):

| Nothing asset | What it is | How recognisable |
|---|---|---|
| **Ndot / Ndot-55 / Ndot-57** | Custom dot-matrix typefaces commissioned from Colophon Foundry. LED-dot-matrix-looking glyphs. | Extremely. This is the single most Nothing thing about Nothing. |
| **NType 82 / NType 82 Mono** | The non-dot companion typefaces (body/UI). Less distinctive. | Medium. |
| **Glyph Interface / Glyph Matrix** | Back-of-phone LED strips and now a pixel-dense corner LED cluster on Phone (3). The dot-matrix *display*, not just the typography. | Extremely. |
| **Dot-matrix backgrounds / widgets** | Nothing OS widgets, settings tiles, and marketing surfaces consistently use a literal dot-matrix grid. | Very high. |
| **"nothing." wordmark with period** | The trailing period is load-bearing. | High. |
| **Product numbering "(1) / (2) / (2a) / (3)"** | Parenthetical generation numbers as product names. | Medium (Apple also uses "(1)" etc. for product iterations, so shared). |
| **Red accent** | Earbud interior red dot, OS micro-accents. | Low-medium — red as an accent is not brand-specific. |
| **Monochrome palette + transparent hardware** | Hardware affordance, not software. | N/A for app design. |

**Summary.** The irreducibly Nothing things are: **dot-matrix type (Ndot), dot-matrix backgrounds/widgets, the Glyph Interface metaphor, the "nothing." period wordmark, and "(n)" product numbering.** Miss any of these and you're reading a Nothing brief.

### 3.2 `4_NothingJot.swift` — element-by-element audit

| Element | Source file ref | Reads as | Risk | Call |
|---|---|---|---|---|
| **Dot-matrix background** (14pt grid of 1.2pt dots at 8% primary) | `4_NothingJot.swift:51-67` | Literal Glyph Interface / Nothing OS widget aesthetic. | **High — direct pastiche.** | **Remove.** Replace with a different texture. |
| **"JOT · 01" top-strip header** | `4_NothingJot.swift:75-90` | Tracked-mono app-name + numeric suffix. Adjacent to "Phone (1) / (2)" but with `·` middot instead of parentheses. | Medium. Swiss-standard middot, but the "tracked-mono branded header strip" gesture is very Nothing-OS-packaging. | **Redesign or drop.** |
| **24-segment VU meter** (rectangles, primary → orange → red) | `4_NothingJot.swift:113-124` | Universal tape-deck / studio-console vocabulary. Every Braun / TE / Tascam device has this. | **Low — shared industrial-Swiss vocabulary. Nobody owns it.** | **Keep** (narrow it if pill-hosted). |
| **Big 84pt mono timer** | `4_NothingJot.swift:107-111` | CRT terminal / chronograph. Not Nothing-specific. | Low. | **Keep.** |
| **SF Mono typography** (via `.design: .monospaced`) | throughout | System font, Apple-provided. Looks *nothing* like Ndot (Ndot is pixel-grid; SF Mono is a geometric grotesque). | None. | **Keep.** |
| **`Color.red` for record state** | `4_NothingJot.swift:84, 117` | iOS semantic red. Also Nothing's brand red. | Low — red-as-record is universal (tally lights since 1950s). | **Acceptable, but** for a Nothing-distinct direction, pick a different accent for extra daylight. |
| **"STANDBY / ● REC" all-caps mono status** | `4_NothingJot.swift:81-84, 166-173` | Studio tally-light vocabulary. Shared. | Low. | **Keep.** |
| **"ON-DEVICE · PARAKEET · v1.0" bottom strip** | `4_NothingJot.swift:92-107` | Product-info strip. Adjacent to Nothing's packaging-strip pattern but specific enough (Parakeet is the model we ship). | Low. | **Keep if desired, or drop for simplicity.** |
| **Bordered rectangular REC button with mono label** | `4_NothingJot.swift:136-155` | OP-1 / tape-deck / rack-mount equipment. | Low. | **Keep.** |

**Net:** the single element that reads as direct Nothing pastiche is the **dot-matrix background**. Everything else sits inside a shared industrial-Swiss-mono vocabulary (Braun, Dieter Rams, Teenage Engineering OP-1, Müller-Brockmann, Tascam, studio gear) that predates Nothing by 60 years and nobody owns.

### 3.3 Recommended departures (implemented in Ledger, proposed for NothingJot)

| Current element | Ledger's departure | Why |
|---|---|---|
| Dot-matrix canvas (grid of dots) | **Horizontal ledger rules** (0.5pt lines every 32pt, 3.5% white) | Ledger paper / stenographer's notebook. Pre-Nothing by a century. |
| "JOT · 01" tracked-mono header strip | **No top strip at all** — the pill is the only chrome | Doesn't fight the pill. Also cleaner. |
| `Color.red` record accent | **Amber** `Color(red: 1.0, green: 0.72, blue: 0.10)` | CRT-terminal amber; OP-1 family adjacent; not Nothing's brand red. |
| 24 fat VU segments | **12 slim VU capsules** inside the pill | Scales into the Dynamic-Island form factor and reads as a waveform rather than a tape-deck meter. |
| "Space Mono / Ndot" aesthetic (we never used this but it's the risk) | **SF Mono via `.design: .monospaced`** | System font. Geometric. Zero resemblance to Ndot. |
| Mono-everywhere transcript | **SF Pro body text** inside the ledger entries | Body mono crushes at accessibility sizes. SF Pro also distances us from Nothing-OS-style mono-UI. |

### 3.4 Optional cleanup of the original `4_NothingJot.swift`

If we want to keep NothingJot alive as a "Workshop mode" theme but remove the single Nothing-pastiche element, the minimum change is: replace the dot-matrix `Canvas` block (lines 51-67) with either (a) the horizontal-rule texture Ledger uses, or (b) a 45°-diagonal hatch at 4% opacity (classic Rams / blueprint). That single edit eliminates the meaningful trademark-adjacency risk. I have not made that change — it's a product call, and keeping Direction 4 pristine makes the audit easier to review. Call my confidence on the rest of the elements being in-the-clear: **high** (they predate Nothing).

### 3.5 Confidence

- **Departures will hold:** amber instead of red, ledger rules instead of dots, SF Mono instead of Ndot-adjacent — I'm **high-confidence** these land Ledger in its own territory.
- **Uncertain:** whether the *overall silhouette* of a mono instrument pill + scrolling log still feels Nothing-adjacent to the user despite the element-level departures. Direction 3 (Pulse) has the same pill silhouette without reading as Nothing at all, which suggests the silhouette is safe. But this is a vibes call; the user should eyeball the rendered preview and say.
- **Explicit non-goal:** Ledger is not trying to be Nothing-minus-IP. It's trying to be its own thing that happens to share the industrial-Swiss room with Nothing, OP-1, Rams, and Tascam.

---

## 4. Micro-interactions catalog

The small moments that matter, across any variant. Use these as the bar regardless of which direction is chosen.

### a. Record button press
- **Visible change:** button scales to 0.97 over 120ms with `.spring(response: 0.32, dampingFraction: 0.78)`; fill color transitions accent → red.
- **Haptic:** `.medium` impact on start, `.soft` on stop.
- **Audio:** no system chime (voice dictation must not race its own prompt sound). Optional "listening-start" earcon in Settings, off by default.
- **Level meter:** animates within 50ms of first buffer. If no amplitude after 300ms, show a low-confidence "Not hearing you" caption for 2s, then dismiss.

### b. Transcription arriving
- **If transcript is short (< 60 chars):** fade + translate-y 8pt in one shot, `.smooth`.
- **If transcript is long:** do not type-writer it. Present fully-formed. *Type-writer animations suggest "streaming from a cloud LLM"; Jot's transcription is one-shot local inference and we want it to feel instant.* (This is a distinct decision from LLM cleanup, which *can* stream — see below.)
- **If LLM cleanup is enabled:** show raw transcript immediately. Kick off cleanup. When cleanup completes, cross-fade the text in place — don't slide, don't bounce.

### c. Copy confirmation
- **Haptic:** `.success` notification feedback.
- **Visual:** two-beat pattern. Beat 1 (0–180ms): the Copy button's icon transitions `doc.on.doc` → `checkmark`, fill flashes to `Color.green.opacity(0.9)` → back. Beat 2 (180–600ms): **status caption or headline** swaps to "Copied to clipboard" and holds for 1.6s before reverting.
- **Do not:** use a floating toast. Jot's screen is already one glance; a toast is one too many moving parts.

### d. Error states
- **Mic denied:** full-screen empty-state card ("Jot needs the microphone" → illustration + Learn why + Open Settings button). No inline red banner.
- **Parakeet download failed / inference failed:** replace the transcript pane content with a small failure card — icon (`exclamationmark.triangle.fill` in `.secondary`), one-line diagnosis, retry + learn-more actions. Recording state returns to idle with a cold-water haptic (`.warning`).
- **Anywhere an error banner would appear at the bottom:** don't. Use the transcript region or an `Alert` if action is required.

### e. Empty state (first open, no recordings)
- Replace the transcript pane with a three-line onboarding: **"Hold the hotkey. Say the thing. Paste anywhere."** Plus a single pill button ("Set up Jot") that drops the user into the permissions flow if any are missing; otherwise hides.
- Do not show the transcript-placeholder "Your transcript will appear here" copy. That line is for *in-session* transcript emptiness, not cold-start.

### f. Live Activity / Dynamic Island
- While recording is active from a hotkey or Shortcut (app in background), Jot *must* show a Live Activity. Minimum: mic glyph + elapsed time + amplitude tick.
- On iPhones with the island: compact trailing uses the amplitude tick; expanded shows the timer + "Stop" button.
- On iPads / other: a standard Live Activity pill on the lock screen and in the Dynamic Island equivalent area.

### g. Permission denial (mid-session)
- If the OS revokes mic mid-recording (rare, but possible on Focus changes), stop recording, show the mic-denied empty state, keep whatever partial transcript was produced.

### h. Transition into voice-command detection
- When the [voice-interaction-designer's pattern #1 — suffix commands](./voice-interaction-patterns.md) fires, the status region **does not** blink or strobe. Instead: the caption shows a subtle pill ("COMMAND · CLEAN UP") for 1.5s with a 2-second Undo affordance, then dismisses. `aria-live`-equivalent: post an `AccessibilityNotification.Announcement`.

### i. Haptic + visual coupling (rule)
- **No haptic without a visible change in the same frame.** Muscle memory binds haptic to a visual proof of action — a haptic with no visible feedback is a bug that users register as flakiness.

### j. Copy-to-clipboard sound (explicitly omit)
- Do **not** play a system sound on paste/copy. Pastes happen in other apps; those apps own the audio context. Jot's default is silent.

---

## 5. Apple HIG compliance notes (summary table)

| Direction | Adheres | Deviates | Deviation justified? |
|---|---|---|---|
| **Aperture** | Semantic colors, SF system fonts, native controls, Material backgrounds, `.success`/`.medium`/`.soft` haptics, standard `NavigationStack` | None material | — |
| **Granola** | Semantic colors, NY serif (first-party Apple font), Material pill, native controls | No container around transcript; relies on whitespace | Yes — the calm-reading framing is the product argument |
| **Pulse** | Dynamic Island language, semantic-red record, native `ultraThinMaterial`, SF Mono for timestamps | Dark-mode-only by default | Partial — should also offer a daylight variant for inclusive-design reasons |
| **NothingJOT** | Semantic colors, SF Mono (system font), native buttons | Overall aesthetic is deliberately non-Apple-shippable | Only as an opt-in theme, not a default |
| **Dictaphone** | NY serif (Apple font), native buttons, semantic fallback in dark | One justified cream brand color + crimson accent | Yes — Journal/Books precedent, but puts Jot further from utilitarian |
| **Ledger** | Dynamic-Island pill, semantic fallbacks, SF Mono + SF Pro native fonts, `ultraThinMaterial`, standard scroll | Dark-mode-first + amber brand accent + ledger-paper rules | Yes — amber is not Nothing-owned (warm CRT phosphor, long lineage); dark-first follows Pulse's precedent; instrument-pill silhouette is native Dynamic-Island language |

**Universal HIG requirements all mockups must meet (and do):**
- Minimum 44pt tap targets on all interactive elements.
- `Dynamic Type` ceiling `.accessibility1` on root view (`.dynamicTypeSize(...DynamicTypeSize.accessibility1)`).
- Both color schemes supported (Pulse is the one asterisk — see table).
- VoiceOver labels on every icon-only button.
- No `.red` text over a saturated red background; all copy passes WCAG AA in both schemes.
- No blocking progress — all "in-progress" states are cancellable (return to idle on second tap).

---

## 6. Recommended path forward

**Weighted criterion:** history-hosting is now a mandatory product requirement (see §2 product constraint). That changes the ranking. Directions where the log *is* the canvas (Pulse, Ledger) get a structural bump; directions where history is behind a draggable/pushed surface (Aperture, Granola, NothingJot, Dictaphone) have to execute that surface well or the app feels bolted-on.

**Revised ranking, weighing history-as-primary equally with visual polish and HIG compliance:**

| Rank | Direction | History hosting | Visual polish | HIG | Net |
|---|---|---|---|---|---|
| 1 | **Ledger** | Primary (log = canvas) | High (instrument + paper metaphor) | 7/10 | Strongest when history is a hard requirement |
| 2 | **Aperture** | Secondary (bottom sheet, native) | High (Apple-adjacent) | 10/10 | Strongest when utilitarian-first + low risk is the bet |
| 3 | **Pulse** | Primary (log = canvas) | High but dark-only | 7/10 | Structural twin of Ledger; less branded |
| 4 | **Dictaphone** | Secondary (side drawer) | Highest editorial identity | 6/10 | Best if Jot wants a literary voice; drawer pattern is native but less standard |
| 5 | **Granola** | Secondary (nav push) | Calm / serif-forward | 8/10 | Push-to-archive is clean; loses some of Granola's quiet to the requirement |
| 6 | **NothingJot** | Secondary (bottom strip) | High but branded | 5/10 | IP risk (see §3); retire in favor of Ledger |

### Recommendation A — Ship *Aperture* first, adopt *Granola* typography in v2

**Why.** Aperture is the lowest-risk direction that completely solves the "looks like a debug harness" problem *today*. It borrows entirely from Apple's own language, so the app reads as a shippable first-party-grade tool. Every critique in §1 is addressed: the timer fills the "no time display" gap, the ring-as-meter fills the "no amplitude feedback" gap, the status caption replaces the error banner, the mic button scales + colors correctly on press. The mandatory history surface rides as a native `.sheet` with `PresentationDetents` — small/medium/large — that peeks 3 recent transcripts by default and opens to a full archive on drag-up.

**What makes this a defensible "first" choice:**
1. **Zero brand risk.** If we launch and the App Store screenshots look like Voice Memos' cousin, that's *strength*, not weakness.
2. **All voice-command patterns slot in cleanly.** The ring hosts amplitude; the caption hosts suffix-command confirmations; the Copy button hosts the haptic-coupled checkmark.
3. **Swappable typography.** The transition to Granola-style serif headlines in v2 is a one-file change — the layout skeleton is the same.
4. **History surface is native and battle-tested.** `.presentationDetents` is first-party Apple; the drag-peek-expand gesture is the same one users already know from Maps and Find My. Zero novel physics to tune.

### Recommendation B — If we want Jot to have a *voice* of its own: *Dictaphone*

**Why.** Of the branded directions, Dictaphone is the one that still feels "Apple-adjacent" because of the NY serif and the Journal/Books precedent. It gives Jot a memorable identity without drifting into NothingJOT's industrial voice or Pulse's dark-only constraint. For a consumer app competing for retention against Voice Memos, having a voice matters.

**What to validate first:**
- Cream backgrounds photograph well in App Store screenshots; the crimson accent has enough contrast for WCAG AA on cream.
- Serif body text survives Dynamic Type (the biggest risk; NY at accessibility scale is lovely on some devices and crushed on others).

### Recommendation C — If the mandatory history surface should drive the whole aesthetic: *Ledger*

**Why.** With history-as-primary now a hard product requirement (§2 constraint), the directions where the log *is* the canvas have a structural argument: they don't need a drawer or a push; the archive is already on screen. Of those two (Pulse, Ledger), Ledger wins because it has a stronger identity — the instrument pill + ledger-paper rules + amber-on-ink read as a specific thing, not "Messages in dark mode." Ledger also preserves the NothingJot instrument vocabulary the user responded to, while departing on every element that was Nothing-owned (see §3 audit): ledger-paper horizontal rules instead of dot-matrix, amber CRT-phosphor accent instead of red, SF Mono via `.design: .monospaced` instead of an Ndot-adjacent typeface, no "(JOT)" parenthetical header strip.

**What makes Ledger compelling now that history is mandatory:**
1. **The requirement is the feature.** Where Aperture has to engineer a drawer to host history, Ledger's layout already *is* the history. Zero surface-area added to support the requirement.
2. **Numbered entries compound.** Session numbers (`#0042`) create a sense of archive-as-ledger — the longer you use the app, the more the number means. This is retention design.
3. **The pill earns its position.** The instrument-pill only needs to exist because the log needs something to hover above. Take away the log, and the pill is unjustified. With the log, it reads as "operating a device on top of your transcript stack."

**What to validate first:**
- Does the amber-on-ink contrast read as "instrument" or as "hazard sign"? This is a vibes check that needs device-review in both color schemes.
- Does the dark-first default survive the accessibility check as a *default* direction (not just an optional mode)? Or does it need a light-mode companion palette before shipping?

### Do not ship as-default
- **NothingJOT:** brand too strong and too close to Nothing's actual IP. Worth keeping as an optional theme ("Workshop mode") once themes are a thing — or retire entirely in favor of Ledger, which carries the same instrument feel without the IP overlap.
- **Pulse:** structurally sound (history-as-primary) but lacks identity — it reads as "Messages after dark" rather than a distinct product. Ledger is the better expression of the same structural idea, so Pulse is now redundant rather than wrong.

### Open questions (surface before committing)
- Does Jot want to be *utilitarian* (Aperture) or *literary* (Dictaphone) or *instrument* (Ledger)? That's a product call, not a design call — and now that history is a hard requirement, Ledger's structural case is stronger than before.
- Does the macOS version of Jot want the same visual language? (If yes, Aperture ports cleanly; Ledger ports well — mono-pill above log is a good Mac paradigm too; Dictaphone ports via a windowed split-view; Pulse struggles in full-dark Mac windows.)
- Does `.searchable(placement: .navigationBarDrawer)` feel right on the log-as-canvas directions, or does Jot want a dedicated "Archive" tab once the history gets long (think: 1000+ entries)?

---

## Appendix — Mockup files

Each file is ≤ 250 lines, self-contained (no dependency on production services), and renders in Xcode Preview. Drop into any iOS 26 project to view.

1. [`mockups/1_Aperture.swift`](./mockups/1_Aperture.swift) — Voice Memos native+
2. [`mockups/2_Granola.swift`](./mockups/2_Granola.swift) — Editorial whitespace
3. [`mockups/3_Pulse.swift`](./mockups/3_Pulse.swift) — Dynamic-Island-forward
4. [`mockups/4_NothingJot.swift`](./mockups/4_NothingJot.swift) — Monochrome industrial
5. [`mockups/5_Dictaphone.swift`](./mockups/5_Dictaphone.swift) — Editorial luxury / warm retro
6. [`mockups/6_Ledger.swift`](./mockups/6_Ledger.swift) — Ledger (NothingJot × Pulse hybrid)

### Note on SourceKit diagnostics
When these files are opened in a workspace whose active scheme targets macOS, SourceKit will flag `.topBarTrailing`, `.navigationBarTitleDisplayMode`, `.secondarySystemBackground`, and `.systemBackground` as unavailable. These are all valid on iOS 26 and the mockups render correctly in an iOS Preview canvas. No action required.

---

## References

- [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) — iOS 26.
- [Apple Voice Memos interface reference](https://support.apple.com/guide/voice-memos/welcome/mac) — for Aperture's waveform + timer language.
- [Vercel web-interface-guidelines](https://github.com/vercel-labs/web-interface-guidelines) — audit heuristics (adapted to iOS).
- Granola AI: [product pages and reviews](https://www.granola.ai/) — for the calm-reading / editorial direction.
- [Nothing Design Skill](https://github.com/dominikmartn/nothing-design-skill) — for NothingJOT's vocabulary (Space Mono / segmented bars / dot-matrix).
- [Fonts In Use — "Ndot-55" typeface by Nothing Technology](https://fontsinuse.com/uses/54129/nothing-phone-1-ui-design) — for the IP audit (§3) on Ndot's specifics.
- [Android Authority — Nothing OS 3 brand identity](https://www.androidauthority.com/nothing-os-3-features-3486478/) — for the dot-matrix and Glyph Interface framing.
- [Design Milk — Nothing Phone (2a) Glyph Interface](https://design-milk.com/nothing-phone-2a-review/) — for the dot-matrix-as-brand-asset framing.
- Dieter Rams' [10 principles of good design](https://www.vitsoe.com/rw/about/good-design) — informed the §3 "haptic + visual coupling" rule ("indifference is the cardinal sin").
- Voice-interaction-designer's [voice-interaction-patterns.md](./voice-interaction-patterns.md) — which visual states each variant needs to host.
