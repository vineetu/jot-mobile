# Typography migration — editorial serif → native SF Pro

Status: ✅ **BUILT 2026-06-26** (signed sim build green; awaiting on-device design-fidelity verify).
Canonical spec: **GitHub issue #4** (a complete, ordered audit with every call-site located). This doc is the as-built record per the `CLAUDE.md` plan protocol.

## Problem

Jot's display + editorial body type used an **editorial serif** — bundled **Fraunces** (opsz-keyed 72pt/9pt statics, referenced by PostScript name via `Font.custom`) plus the **system New York serif** (`Font.system(…, design: .serif)`), mostly italic. The owner decided to move the whole app to the **native system font (SF Pro)**: cleaner, no bundled font payload, native Dynamic Type, and a more cohesive read against the existing SF chrome.

Live before/after reference: https://jotfonts.ideaflow.page

## Decisions (locked, from issue #4 + its comment)

- **Typography only.** Replace the editorial serif with native SF Pro; preserve the visual hierarchy (display lines stay **bold**, body stays **regular**); **drop the italics** except where italic is a *semantic* signal (see below).
- **Liquid Glass is OUT OF SCOPE — do NOT touch.** The glass tokens/chrome (`jotKeyboardGlass*`, `jotKeyboardChrome*`, `Surface.*`) and the existing SF tokens (`bodyChrome`, `rowTitle`, `rowSub`, …) are untouched. (Glass was separately evaluated for the flat in-app surfaces and decided NO — glass is for overlays with content behind them.)
- **Watch / WatchWidgets** are already serif-free — left alone.
- **Keyboard target** must keep building with no serif-font / MLX dependency — the migrated keyboard sites use `Font.system` directly.

## As-built change list

### §1 Design tokens — `Jot/App/Design/JotDesign.swift`
- `displaySerif(_:)` → **renamed `displayTitle(_:)`**, now `Font.system(size:, weight: .bold, design: .default)` (was `design: .serif).italic()`). All 9 callers renamed.
- `editorialDisplay` (38), `editorialTitle` (30), `editorialBody` (24), `editorialItalic` (19) — repointed from `Font.custom(fraunces…)` to `Font.system(…, design: .default)` at the **same sizes**; display tokens bold, body regular. (None had external callers, but kept as named tokens.)
- Removed the Fraunces PostScript constants `frauncesRegular`/`frauncesSemiBold`/`frauncesItalic`/`frauncesItalicText` and rewrote the file-header + token doc comments.

### §2 system-serif call-sites (`design: .serif` → `.default`, drop `.italic()`)
RecordingHeroView (×3: live transcript + Listening ellipsis + line), FeaturedLatestRow, LiveStreamingRow, FeedbackView heading, NewPromptSheet (×2), EditPromptWithTestSheet (×2), AIRewriteSettingsView (row name), **plus sites not in the original audit that drifted in since** — TranslateSheet, TTS/VoiceCloneRecorderView, Keyboard/ActionsPopover (title). All migrated so the grep-proof is clean.

### §4 direct Fraunces call-sites (`Font.custom(JotType.fraunces…)` → `Font.system` / token)
Ask (×5), Help (HelpView/HowJotWorksPage/SeeForYourselfPage), SetupWizard (WizardChrome ×2, TryKeyboardStep ×2), Keyboard (CorrectionReviewStrip, StreamingStrip ×2), Settings/DiagnosticsView (×2), Vocabulary/CorrectionReviewSection, RecordingHeroView jotIcon "j".

### §5/§6 assets + registration
- Deleted `Jot/Resources/Fonts/` (5 Fraunces `.ttf` + `OFL.txt`).
- Removed `UIAppFonts` + the `Resources/Fonts` resource from `project.yml` (app + keyboard targets) and re-ran `xcodegen`; the regenerated `Info.plist` / `Keyboard-Info.plist` no longer carry `UIAppFonts`.

### §7 attribution
Removed the Fraunces SIL-OFL credit row from `Settings/AcknowledgementsView.swift` (and its header doc) — Qwen is now the last row (`showDivider: false`).

### §8 edge case — `SteppingEllipsis`
The trailing "still transcribing" dots inherit the font passed by their call-sites, which are now SF — no glyph change needed; fixed the "three serif dots" doc comment in `TranscribingText.swift`.

### §9 docs
`AGENTS.md` (visual-language line), `features.md` (6 serif descriptors removed — user-facing wording), `ARCHITECTURE.md` (PostScript-names invariant + code-map row).

## Weight/size choices (for the design-fidelity pass)

- **Display headers** that were Fraunces SemiBold 32 → `Font.system(size: 32, weight: .bold)` (Help, How Jot works, See for yourself, Diagnostics, Wizard title). SF semibold reads lighter than Fraunces SemiBold; bold restores the display weight.
- **`displayTitle`** (was serif-italic regular) → **bold**, same sizes. Same rationale.
- **FeedbackView "Tell us anything." 38pt** (was serif-italic **regular**) → `weight: .bold`. At 38pt a regular SF heading reads thin; bold preserves the display hierarchy the serif gave it for free. **Flagged** as a judgment call.
- **Ask hero question** (Fraunces italic 30/25/22) → `weight: .regular` SF, italic dropped — reads as a clean question hero.
- **Body / caption** text (Fraunces 9pt-italic-text 13–17, system-serif 15–26 body) → `weight: .regular` SF.
- **jotIcon "j" badge glyph** 12pt (Fraunces italic, inside an 18pt tile) → `weight: .semibold` so the single letter reads in the small tile. **Flagged.**
- **Italic kept as a semantic signal (not editorial decoration):** `LiveStreamingRow` and the keyboard `StreamingStrip` live transcript keep **native SF Pro italic** because italic exclusively signals "live/streaming" vs the upright saved-text quote (`FeaturedLatestRow`) — a contrast the codebase deliberately maintains. The issue's literal "drop italic" was deviated from here on purpose; **flagged**.

## Test / verify

- Signed sim build (`-destination 'platform=iOS Simulator,id=2341E12B-985A-4FE5-AAAF-0FB42726FD9F'`, `-allowProvisioningUpdates`) — **BUILD SUCCEEDED**, keyboard target included.
- Grep-proof: no `fraunces` / `design: .serif` / `displaySerif` / `New York` remains in `Jot/**/*.swift` source (only intentional migration-note comments).
- **On-device design-fidelity pass** against https://jotfonts.ideaflow.page still owed — confirm each surface's weight/size reads right (esp. the three flagged sites above).
