# Building with the Jot design system

**Setup.** No provider or theme wrapper is needed — every component is self-styled with inline styles that read CSS custom properties from `styles.css`. Jot is **dark-first**: the tokens on `:root` are the dark theme, and the light theme is `[data-theme="light"]` on any ancestor. So a design must sit on the app's own surface, never on a bare white body: wrap screens in `<div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)" }}>`. Without that, white brand marks, white glyphs and glass chrome are invisible.

**Styling idiom.** There are no CSS classes to reuse. Style your own layout glue with inline styles and the tokens; the components carry their own look. Use only these families:
- Colour: `--bg-screen` (screen gradient), `--ink` / `--ink-sub` / `--ink-caption` (text), `--jot-accent` and `--jot-blue-grad` (the ONE accent — brand blue), `--jot-red` (destructive icon only), `--jot-ai-accent` (coral — marks AI Rewrite surfaces only, never anywhere else; new AI features use blue).
- Type: `--font-serif` (Fraunces, editorial: *italic* for anything spoken or onboarding titles; upright SemiBold with a period for in-app page titles like "Settings."), `--font-sys` (SF/system for chrome and body). Sizes via the `--ts-*` scale: `--ts-title`, `--ts-body`, `--ts-caption`, `--ts-cta`.
- Shape: `--card-radius` (18 for cards; transcript cards use 28), glass surfaces = translucent fill + 0.5px hairline + backdrop blur (use `GlassCard`, don't hand-draw glass), `--shadow-cta` for the primary pill glow.
Copy rules: sentence case, honest, second person, no emoji, titles often end with a period.

**Where the truth lives.** Read `styles.css` (it imports `_ds_bundle.css`, the full token sheet with light + dark values) before styling anything, and each component's `components/<group>/<Name>/<Name>.prompt.md` for usage and `<Name>.d.ts` for props.

**Component gotchas.**
- `CtaPill` is full-width and one per screen, docked at the bottom, label a verb; pair it with `TextLink` beneath for the secondary action.
- `StopPill` is `flex: 1` — place it inside a `display: flex` row with an explicit width (as the recording surface does) or it collapses.
- `HeroTile variant="keyboard"` is parchment-coloured: give its `JotGlyph` `color="var(--tile-key-glyph)"`; the `mic` and `success` variants take white glyphs.
- `JotMark` / `JotGlyph` default to white — only on the dark surface, or pass `color`.
- `Waveform` animates by default; pass `animate={false}` for a still frame.

**Idiomatic screen.**
```jsx
import { SerifTitle, BodyText, CtaPill, TextLink, ProgressDots } from "@jot/design-system";

<div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
              minHeight: 720, padding: 24, display: "flex", flexDirection: "column" }}>
  <ProgressDots total={7} current={2} />
  <div style={{ flex: 1, display: "grid", alignContent: "center", gap: 12 }}>
    <SerifTitle size={30}>Grant the microphone.</SerifTitle>
    <BodyText>Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded.</BodyText>
  </div>
  <CtaPill>Grant microphone</CtaPill>
  <div style={{ textAlign: "center", marginTop: 14 }}><TextLink>I've already added it</TextLink></div>
</div>
```
