# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## ✅ DICTATION ARCHITECTURE — unification COMPLETE

The keyboard-dictation unification (`docs/plans/unify-keyboard-dictation.md`) is **done**.
The custom inline-dictation engine has been removed. In-Jot keyboard dictation now behaves
like the keyboard in **any other app**: record in the app, insert the result into the focused
field on stop. Jot's fields are *just fields* — no registration layer, no live-partial
streaming, no hero fallback band-aid.

**What was removed:** `InlineDictationReceiver` (the whole registration layer, `register`/
`deregister`/`heroFallbackRequest`), `EditDictationController`, and the Edit / Feedback inline
wiring. The `keyboardDictateTapped` → inline-session routing was replaced by a normal
background capture started in `ContentView.updateDictateTapObserver`.

**Current model:**
- Every stop **ends the transcription cleanly** (recording state flips off → home + keyboard
  reset, next Dictate tap starts fresh) and **leaves the mic warm-held exactly as before**.
  "End the transcription" and "release the mic / warm-hold" are SEPARATE axes — do not conflate.
- **A transcript is saved only when you stop OUTSIDE Jot** (another app) or from the **hero**.
  Stop inside a Jot field (feedback/edit/settings/wizard) → paste, **no** save. Fate is decided
  at the *stop*, not stamped at the *start*.

**Survivors — do NOT touch / do NOT delete:**
- **Warm-hold** — orthogonal; untouched.
- **Ask** — keeps its own `InlineDictationSession` and is now its SOLE user (the one intentional
  exception). Do not add new callers of that type outside Ask.
- **Wizard** — its W5 keyboard test uses its own `keyboardDictateTapped` observer and starts a
  pipeline recording; it never used the (now-removed) inline receiver.
- **FAB / cold-keyboard / Action Button / DictateIntent / warm-resume** captures — still save.

---

## Feature work: consult `features.md` FIRST

`features.md` is the single source of truth for what Jot does at a product level — ~100 user-facing features across 13 surfaces, with anchor cross-links between related ones. It was hand-verified across many review rounds; treat it as authoritative.

**Known bugs & planned work live in [`known-bugs-and-plans.md`](known-bugs-and-plans.md)** — the canonical registry (split out of `features.md` to keep that doc user-facing only). It tracks unresolved bugs and the plans index; each entry links an elaborated doc in `docs/plans/`. When recording a NEW bug or plan, follow the protocol: write the `docs/plans/<slug>.md` doc AND add a dual entry here (a detailed entry + a one-line index entry) — a stray `docs/plans/` doc alone is not discoverable. Start here for "what's planned / known bugs" questions.

**Before adding, modifying, or removing any user-facing behavior, do these steps in order and report results to the user BEFORE writing code:**

1. **Read `features.md`** (at minimum the sections most relevant to the request — use the Table of Contents to triage).
2. **Find the closest matching feature(s)** the request touches. The match may be in multiple sections.
3. **Walk one hop of cross-links** from each match. Anchors look like `[Warm Hold](#13-2-warm-hold)`. Open every linked section.
4. **Surface impact to the user**:
   - Where does this feature most naturally belong (which §)?
   - What other sections cross-link to it — i.e. what existing behavior might this change affect?
   - Are any current features in the doc now wrong because of this change?
5. **After implementation**, update `features.md`: add the new entry in the right section, add cross-links in both directions (if §A mentions §B, §B should also mention §A), and amend/remove any sections this change invalidates.

This step is REQUIRED for feature-shaped requests. It's skippable for: pure bug fixes with no product-behavior change, internal refactors with no user-visible effect, one-off questions, and trivial copy/typo edits.

## Style rules when editing `features.md`

- **User-facing only.** No file paths, Swift class/struct/func/var names, framework names (`NotificationCenter`, `UserDefaults`, `App Group`, SwiftUI primitives), or library names (`FluidAudio`, `MLXLLM`, `Phi-4`). Exception: user-visible model labels shown in Settings UI (e.g. "Parakeet 600M (more accurate)") are fine because the user sees them on screen.
- **One paragraph max per feature.** Split into sub-features if longer.
- **Cross-link bidirectionally.** If §A mentions §B, §B should mention §A.
- **Deliberate caveats — do NOT "clean up":**
  - **§7.3 and §7.11** are "visible-copy-with-caveat" entries. Settings/Help advertises a keyboard Magic button and a titles/tags AI feature whose UI is not yet wired. These document what the user actually SEES in the UI — not aspirational features. Leave them.
  - **§5.10** documents a real bug: when a status banner fires while the keyboard is in its collapsed state, the keyboard height grows but the render branch stays on the collapsed view (which has no banner slot), so the banner is silently invisible. Don't "fix" the doc by removing the limitation note — fix the actual bug if you want it gone.

## Wizard / setup-flow conventions

- The 7-panel wizard (W1–W7) lives in `Jot/App/SetupWizard/`. Each panel has its own file under `Steps/`. (The optional AI-offer follow-on was removed; the wizard is now exactly W1–W7.)
- **Wizard contract:** any recording started inside the wizard (W5 keyboard test triggered via the keyboard's Dictate-tap notification) MUST be force-stopped before the wizard dismisses. Failing this leaks a zombie recording into the home view. The teardown lives in `SetupWizardView.closeAndComplete()` and individual step `.onDisappear` hooks. Don't bypass.

## Build / run

- **Regenerate Xcode project:** `xcodegen` from `Jot/` (reads `project.yml`).
- **Local iteration:** open `Jot.xcodeproj` in Xcode and `Cmd+R`. This is the preferred way for the user to test changes — no TestFlight cycle needed.
- **TestFlight uploads:** `scripts/testflight.sh all`. ONLY run when the user explicitly says "deploy", "cut a new version", "ship to TestFlight", or equivalent in the current turn. Never auto-deploy after fixing a bug. One deploy = one explicit user command.

## Keyboard extension constraints

- The `JotKeyboard` target has a ~60 MB memory ceiling and **must not link MLX or Apple Foundation Models**. The main app handles rewrite (Phi-4 on MLX) and cleanup (Apple FM); the keyboard bounces requests via a deep link rather than running inference in-process.
- The keyboard is **dictation-only** by design — no QWERTY. This is intentional and is surfaced in onboarding (W6 "How it works").

## Recording-start instrumentation

Every code path that starts a recording logs `"RECORDING START FROM: <site>"` via `os.log`. When debugging "where did this recording come from" bugs (zombie hero, double-start, etc.), grep Console.app for `RECORDING START FROM:` to triage in one pass. Preserve these log lines on edits.

## Schema discipline — SwiftData store

The SwiftData store lives in the App Group container (cross-process invariant). Schema evolution follows a Flyway-style discipline:

1. Every shape lives in `Jot/Shared/Schema/JotSchemaVN.swift` as an `enum JotSchemaVN: VersionedSchema`. The current version is the highest N.
2. **Frozen rule.** Once `JotSchemaVN.swift` is in a shipped build, the file is FROZEN. Do not edit it. Add fields by introducing `JotSchemaV(N+1).swift` and appending a `MigrationStage` to `Jot/Shared/Schema/JotMigrationPlan.swift`. Mechanically enforced by `scripts/check-schema-frozen.sh`.
3. **Every new VN file MUST bump `versionIdentifier`** (e.g. `Schema.Version(2, 0, 0)` for V2). Without a unique identifier, SwiftData cannot distinguish versions and the migration plan corrupts the store.
4. **After creating a new VN file, run `xcodegen` from `Jot/`** so the Xcode project picks up the new file. The Shared/ glob picks it up automatically once the project regenerates.
5. The top-level `Transcript` typealias points at the current version (`typealias Transcript = JotSchemaVN.Transcript`). Bump the typealias when a new VN ships.
6. Pure additive optional fields / new entity types: `.lightweight(...)` stage. Renames, removes, or data transforms: `.custom(...)` with explicit `willMigrate` / `didMigrate` closures.
7. **Every feature plan that touches `@Model` types MUST include a "Schema impact" section.** Sections:
   - Does this feature add/remove/rename `@Model` fields, or add new `@Model` entities? Y/N.
   - If Y: what's the new `JotSchemaVN` look like (diff from prior version)?
   - What `MigrationStage` traverses V(N-1) → VN — lightweight or custom?
8. **After each schema change, watch Console.app for `[SCHEMA-FALLBACK]` log lines** on a real-device upgrade test. If that log fires, `JotModelContainer.shared` is using its defensive non-versioned fallback path — the migration is silently broken on that device and must be investigated before merge.
9. Do NOT open `JotModelContainer.shared` from the keyboard target. The keyboard reads `TranscriptHistoryMirror` JSON, never SwiftData directly (see `AGENTS.md`).

See `docs/schema-migrations.md` for the full add-a-version recipe and rationale. SwiftData lightweight auto-migration is empirically fragile across iOS versions — the explicit VersionedSchema + MigrationPlan is the price paid forward to make every change traceable and reversible.
