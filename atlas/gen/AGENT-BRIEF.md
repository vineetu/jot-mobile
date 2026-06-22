# Jot Mockup — screen fragment generation brief

You are generating **HTML fragments** for a visual mockup of the Jot iOS app. Each fragment is ONE screen's
inner markup, rendered inside a device frame by a viewer. Read the exemplar first:
**`/Users/vsriram/code/jot-mobile/atlas/gen/frag/settings-main.html`** and the stylesheet
**`/Users/vsriram/code/jot-mobile/atlas/gen/jot.css`**.

## Output rules
- Write each fragment to `/Users/vsriram/code/jot-mobile/atlas/gen/frag/<id>.html`.
- A fragment is ONLY the screen's inner markup — **no** `<html>`, `<head>`, `<body>`, `<script>`, no device frame,
  no status bar, no page background. The viewer supplies all of that.
- It MUST render correctly in BOTH light and dark. Never hardcode text colors — always use the CSS variables below.
- Use the component classes below. Don't invent new CSS; compose from these. Inline `style="..."` only for
  one-off spacing or the icon-tile color pair.

## Components (from jot.css)
- Hero title: `<div class="jot-display">Settings.</div>` (38px serif italic — for the screen's big title)
- Smaller serif title: `<div class="jot-title">…</div>` (30px, transcript detail)
- Section header: `<div class="jot-section">speech model</div>` (auto-uppercased)
- Card: `<div class="jot-card"> …rows… </div>`
- Row: `<div class="jot-row"> <tile> <div class="grow"><div class="jot-row-title">T</div><div class="jot-row-sub">sub</div></div> <trailing></div>`
- Icon tile: `<span class="jot-tile" style="--c1:#TOP;--c2:#BOT"><svg viewBox="0 0 24 24"><path d="…"/></svg></span>` (white glyph). Big: add class `hero`.
- Status pill: `<span class="jot-pill success">​<span class="dot"></span>READY</span>` (variants: success | warning | info)
- Toggle: `<span class="jot-toggle"></span>` (green/on) or `<span class="jot-toggle off"></span>`
- Chevron: `<span class="jot-chev">›</span>` · External link: `<span class="jot-ext">↗</span>`
- Caption under a card: `<div class="jot-caption">…</div>`
- Primary CTA pill: `<div class="jot-cta">Get started</div>`
- Done button: `<span class="jot-donebtn">Done</span>`

## Color variables (use these, never raw hex for text)
`var(--jot-ink)` primary text · `var(--jot-ink-2)` secondary · `var(--jot-ink-cap)` captions/section labels ·
`var(--jot-accent)` brand blue · `var(--jot-record)` recording red · `var(--jot-success)` green.

## Icon-tile gradient pairs (semantic, --c1/--c2)
speechModel `#1A8CFF`/`#1573D1` · vocabulary `#1FCED1`/`#19A9AB` · ai `#FF6B57`/`#D15847` ·
privacyOnDevice `#34C759`/`#2BA349` · fullAccess `#7C5CFF`/`#664BD1` · micReady `#FF9A33`/`#D17E2A` ·
helpSupport `#1FCED1`/`#19A9AB` · rerunWizard `#1A8CFF`/`#1573D1` · sendFeedback `#7C5CFF`/`#664BD1` ·
version `#8B8E96`/`#72747B` · donations `#34C759`/`#2BA349` · backup `#007AFF`/`#0064CC` ·
privacyPolicy `#7C5CFF`/`#664BD1` · acknowledgements `#FF4F6B`/`#D14158`.

## Fidelity
- If a **real screenshot path** is given for a screen: **Read that image first** and match its layout, copy
  (exact text), order, pills, toggles, and recording controls as closely as the components allow.
- If NO screenshot: **Read the cited `features.md` section(s)** (`/Users/vsriram/code/jot-mobile/Jot/features.md`)
  for the real copy and behavior, and produce a faithful screen consistent with the captured screens' visual language.
- SF Symbols aren't available — approximate each icon with a simple inline `<svg viewBox="0 0 24 24">` path.
- Recording surfaces (`rec-*`) have a serif italic instruction line near the top and a centered control cluster
  (pause / record-stop pill with timer / trash). Look at `screens/ios/rec-surface.png` and `screens/dark/rec-surface.png`.
- Keyboard screens (`kb-*`) are a bottom strip: a text field above, a RECENT list, and a blue "Jot down" pill row.
  Look at `screens/keyboard/*.png`. The keyboard sits at the BOTTOM — push it down with a tall spacer above if needed.
