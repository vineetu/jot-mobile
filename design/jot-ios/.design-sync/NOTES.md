# design-sync notes — Jot design system

- Source of truth is the Claude Design project **jot-ios** (regular project, `6797ae1d-dcb8-42d7-b974-c9a0b5b2b4fc`), mirrored into this folder on 2026-09-15 via the DesignSync tool (`PULLED.md` is the index). There is no upstream JS package: `package.json`, `src/index.js`, `scripts/assemble-dts.mjs` and `docs/<Name>.md` are the sync scaffold added here so the converter has a `dist/` entry, a `.d.ts` tree and per-component docs. The 18 component sources live in `components/<group>/<Name>.jsx` with hand-written `<Name>.d.ts` and `<Name>.prompt.md` (the latter copied into `docs/` with a `category:` frontmatter that reproduces the source groups Actions / Brand / Display / Typography).
- `styles.css` is @import-only and pulls `tokens/*.css`; the brand serif Fraunces loads from Google Fonts at runtime (`tokens/fonts.css`), hence `runtimeFontPrefixes`.
- The source project's group-level demo cards (`components/<group>/<group>.card.html`) and `card-runtime.js` are the design tool's own runtime loader; the converter does not use them. Guideline cards are HTML with `@dsCard` markers (`guidelines/*.html`) — not `.md`, so they are added to `ds-bundle/guidelines/` after the build, outside the converter.
- `guidelinesGlob` is pinned to `guidelines/*.md` (matches nothing on purpose): the converter's default `docs/*.md` glob also swept the generated `docs/<Name>.md` component docs into `guidelines/docs/`, which would show them as design guidelines. The 15 real guideline cards are HTML and are copied by `scripts/post-bundle.sh` after every converter run.

## Preview authoring conventions (folded from the 2026-09-15 waves)
- Every authored preview wraps its cells in a dark `Screen` (`var(--bg-screen)`, `color: var(--ink)`, `font-family: var(--font-sys)`): the card body is white and the `:root` tokens are the dark theme, so white marks/glyphs and glass chrome vanish without it.
- `StopPill` is `flex: 1` — compose it in a flex row with an explicit width or it collapses to content width. `HeroTile variant="keyboard"` needs a dark glyph (`var(--tile-key-glyph)`). `JotGlyph` chevrons and `watch` are non-square: fixed-height rows keep labels aligned. `Waveform` captures fine mid-animation; `animate={false}` is available for a still frame. `--jot-red` is the destructive-icon token (trash glyph).
- All 18 components have authored previews (2–3 cells each), graded good on 2026-09-15; the only iterations were presentation fixes (JotAppIcon size label clipping, StopPill.Sizes flex parent).
- A scoped `preview-rebuild` + capture can exceed 10 minutes in the foreground — run long steps in the background.

## Known render warns
- None recorded after the authored previews landed (the earlier `[RENDER_THIN]`/`[RENDER_BLANK]` on JotGlyph, JotMark and SourceRow were floor cards, replaced by authored previews).

## Re-sync risks
- The design source of truth is the **jot-ios** Claude Design project; this folder is a mirror. If components change upstream, re-pull them (`DesignSync get_file` per path, see `PULLED.md`) before re-syncing — nothing here auto-tracks upstream edits.
- `docs/<Name>.md` are generated copies of `components/<group>/<Name>.prompt.md` with a `category:` frontmatter; regenerate them when a prompt.md changes (they are what the converter ships as `<Name>.prompt.md` and what sets the group).
- `dist/index.d.ts` is assembled by `scripts/assemble-dts.mjs` from the per-component `.d.ts`; a new component must be added to `src/index.js`, the assembler's list, and `docs/`.
- Fraunces loads from Google Fonts at runtime (`runtimeFontPrefixes`); an offline render check would fall back to a system serif and grade wrong.
- Guideline cards are copied by `scripts/post-bundle.sh` AFTER every converter run — a driver/validate run without it leaves `ds-bundle/guidelines/` empty.
- Toolchain assumed: Node 26, esbuild 0.25, Playwright chromium-headless-shell 1243 in the user cache.
- Every component uses `cardMode: column` (config `overrides`): the authored previews sit on a phone-width dark `Screen` (360–440px), which the product's multi-column grid crops (`[GRID_OVERFLOW]` on all 18 at the 2026-09-15 close-out) — one story per row at full card width is the right presentation for phone-sized compositions.
- **Fonts (2026-09-17):** the Design System pane flagged "missing brand font SF Pro Text" and rendered substitutes — the token `--font-sys` named "SF Pro Text"/"SF Pro Display", which can't ship as web fonts (Apple system font, not redistributable). `scripts/assemble-css.mjs` now compiles `--font-sys` to the system-font stack (`-apple-system, BlinkMacSystemFont, system-ui, …`) and strips the SF Pro names from the shipped CSS; on Apple devices that still renders in SF. The source token in `tokens/typography.css` (mirror of jot-ios) is left as-is. Fraunces stays a runtime Google Fonts load (`runtimeFontPrefixes`).

