# Settings & Models — UX Research

## TL;DR

- **MVP 1:** Settings is one screen, three rows — **Speech model**, **Re-run setup wizard**, **About**. Cleanup runs unconditionally with the baked-in default prompt; no UI for it.
- **MVP 2:** Add a **Keyboard** section (Full Access deep-link, auto-paste toggle) and a read-only **Rewrite presets** row that previews the three hard-coded preset prompts. Data shape (`[RewritePreset]`) is right from day one so future "edit / add" is additive.
- **Future:** Full AI pane (6 providers, keychain API keys, editable prompts), retention picker, Reset / Erase Data, About, Help shortcuts, custom vocabulary.
- **Opinionated calls:** Apple Foundation Models is the only cleanup provider for MVP 1 and MVP 2. Parakeet variant selection is **never** user-facing (320ms ships; other variants live behind a DEBUG flag).
- **Visual system: stock Apple-native by default** — `NavigationStack` + `Form(.grouped)` + `Section` + `LabeledContent` + `Toggle` + `.searchable`, semantic colors, SF Symbols, system materials. Tejas's monospaced amber `JOT CONFIG` ledger chrome is dropped (reads like a debug pane). Liquid Glass is whatever iOS 26 gives us for free; we don't blanket it. **When we deviate, Superwhisper is the primary reference**: settings-as-table-rows, model-status-as-card, prompt-config-as-inline-disclosure. Wispr Flow / Things / Linear are secondary.

---

## Full Vision

The eventual Settings tab is the 4th tab in the iOS 26 `TabView` (Record / Library / Help / Settings). Stock grouped `Form`. Every pane below ships eventually; tier gates which arrive when.

### Root list

- **GENERAL** — Keep recordings (segmented retention picker), Microphone (status + deep-link), Jot keyboard (status + deep-link), Re-run setup wizard.
- **TRANSCRIPTION** — Speech model (push to Model Mgmt pane), Custom vocabulary.
- **AI / CLEANUP** — Cleanup (push to AI pane), Rewrite presets (push to Presets pane).
- **PRIVACY & DATA** — Privacy pledge, Reset settings, Erase all data (destructive, double-confirm).
- **ABOUT** — About Jot, Help (deep-link to Help tab).

### Model Management pane

Pushed `Form`. **Superwhisper-style status card at the top** — our one deviation from pure native here, because Superwhisper's "Installed Model" card is meaningfully clearer for "what's on disk and is it ready" than three `LabeledContent` rows. Card uses `.regularMaterial`, semantic colors, SF Symbols — three lines: model name (`Parakeet TDT 0.6B v3`), state line (`● Ready` with semantic `.green / .orange / .secondary` dot), and a `.secondary` caption (`1.24 GB · last verified today, 14:22`). Below the card: a **DOWNLOAD** section with a Wi-Fi-only `Toggle` and a Re-download row, then a destructive section with **Delete model** (`.red`, `.alert` copy: "You'll need to download ~1.25 GB again.").

While downloading, the card's caption line is replaced by a native `ProgressView(value:total:)` + "580 of 1240 MB · 47%" — same shape as the App Store download row.

### AI / Cleanup pane (full vision)

Stock `Form`. Two Superwhisper deviations: provider list and prompt config.

- **Master toggle** (`jot.cleanup.enabled`, default OFF) — stock `Toggle`.
- **Provider list** — Superwhisper's settings-as-table-rows: 6 rows, each with SF Symbol mark, name, `.secondary` "on-device / local / cloud" tag, trailing `checkmark` on the active one. We choose this over a stock `Picker(.menu)` because 6 providers in a popover collapses a consequential, privacy-relevant choice into something users tap past — Superwhisper's all-rows-visible treatment forces deliberate selection.
- **Connection** (gated by provider; hidden for Apple FM): keychain `SecureField` API key, Base URL `DisclosureGroup`, Model `Picker`, **Test Connection** `Button` whose result renders as a stock `Label`.
- **Customize prompt** — Superwhisper's prompt-config-as-inline-disclosure: Cleanup, Rewrite, Shared invariants each unfold in a `DisclosureGroup` with `TextEditor` + per-disclosure "Reset to default". All collapsed by default.
- Apple Intelligence availability as a stock `Label` with `exclamationmark.triangle.fill`.

### Rewrite Presets pane

Three hard-coded presets, each with name + one-line summary + system prompt body. Read-only in MVP 2; editable + reorderable + extensible in the future tier. Suggested:
1. **Make it casual** — "Rewrite as a friendly message to a friend."
2. **Make it formal** — "Rewrite as a professional email."
3. **Make it concise** — "Rewrite shorter without losing meaning."

### Reset / Erase Data

Two destructive actions, each behind an `.alert`. **Reset settings** wipes App Group UserDefaults only (preserves transcripts and model). **Erase all data** wipes SwiftData + App Group defaults + keychain + model cache.

### About

Icon, version + build, "Your words stay on your iPhone" pledge, **View logs**, **Support Jot**, **Privacy** disclosure.

---

## MVP 1 Scope

Settings is **one screen, three rows** in a stock `Form(.grouped)` — no section header (three rows is below the threshold where grouping helps). SF Symbols leading, `.secondary` trailing detail, system disclosure chevrons. Rows: **Speech model** (`Ready · 1.2 GB ›`), **Re-run setup wizard** (`›`), **About** (`v0.1.0`).

**Speech model** pushes the Model Management pane (above), stripped down: Superwhisper card + Wi-Fi-only toggle + Re-download. The state line is driven by `TranscriptionService.modelState`: `.notLoaded` → "Not downloaded" + **Download (≈1.25 GB)** button; `.downloading(p)` → `ProgressView` + "X% · Y/Z MB"; `.loading` → "Loading into Neural Engine…" + spinner; `.ready` → green dot + "Ready" + `Last verified` caption; `.failed(reason)` → orange dot + reason + **Retry**. **No Delete model in MVP 1** — too easy to brick the app before we have a Settings-level re-download recovery story.

**Re-run setup wizard** — button row that resets `hasCompletedSetup` and mounts the wizard cover. Idempotent; refuses to mount mid-recording.

**About** — single row reading `Jot vX.Y.Z (build N)`. Tapping opens a `.sheet` with the privacy pledge. Nothing else.

**Explicitly NOT in MVP 1:** cleanup toggle, cleanup instructions editor, auto-paste toggle, retention, provider selection, Reset/Erase. `CleanupSettings` and `keyboardAutoPasteEnabled` keys remain in shared code (keyboard reads them) — no UI, defaults baked (cleanup ON, auto-paste ON).

---

## MVP 2 Scope

Four sections: **GENERAL** (Re-run setup wizard), **TRANSCRIPTION** (Speech model `›`), **KEYBOARD** (Jot keyboard, Auto-paste, Rewrite presets), **ABOUT** (version row).

**Jot keyboard** row shows two states inline (`Full Access · On`). iOS doesn't deep-link directly to Keyboards, so the row opens `UIApplication.openSettingsURLString` with caption "Open in iOS Settings → General → Keyboard". If Full Access is off, surface a stock `Label` with `exclamationmark.triangle.fill` in `.orange`: "Full Access is required for Jot to read your last transcript."

**Auto-paste** is a stock `Toggle` bound to `AppGroup.Keys.keyboardAutoPasteEnabled`. Default On.

**Rewrite presets** pushes a static `List` of three preset rows. Tapping a row pushes a detail view with the prompt body in a non-editable monospaced `Text` and a footer: "Presets aren't editable in this version — coming in a future update." Backed by `RewritePresetCatalog.builtIn: [RewritePreset]` so future "Add preset" plugs in with zero migration.

**Cleanup status** appears as a passive footer line at the bottom of Settings, not a toggle: "Cleanup ready · Apple Intelligence" (green dot) or "Cleanup unavailable — Apple Intelligence is off in Settings →" (amber, deep-links to iOS Settings → Apple Intelligence).

**Re-run setup wizard** moves into the `GENERAL` section.

---

## Future Tiers

Rough shipping order: (1) **Retention picker** (Forever / 7d / 30d / 90d segmented + SwiftData purge); (2) **Cleanup v1** (master toggle returns, editable prompt, Apple FM only); (3) **Editable rewrite presets** (add / rename / reorder / delete, sync to App Group); (4) **Multi-provider AI** (6-provider list, keychain `SecureField`s, base URL + model overrides, Test Connection; Vertex's "no default URL" gets red helper text); (5) **Articulate / shared invariants** prompts (two more disclosures); (6) **Reset / Erase Data** (two-step `.alert`); (7) **About v1** (credits, donation, log viewer); (8) **Help shortcut rows** (`info.circle` → Help tab anchor, matches Mac); (9) **Custom vocabulary** (phrase list biased into Parakeet).

---

## State Diagram

### Model lifecycle

`.notLoaded → .downloading(p) → .loading → .ready`. Failure paths land in `.failed(reason)` from any of those three; user taps Retry to re-enter `.downloading`. Memory warning evicts `.ready → .notLoaded` (the underlying CoreML handle drops; files stay). User-tapped **Delete model** wipes the cache and lands in `.notLoaded`. Foreground sweep on `scenePhase == .active` runs `AsrModels.modelsExist`, updates `Last verified`, and transitions `.ready → .notLoaded` if files vanished externally.

### Cleanup availability (passive — no user toggle in MVP 1/2)

Maps `SystemLanguageModel.default.availability` to a status pill:
- `.available` → `.ready` (green).
- `.unavailable(.modelNotReady)` → `.modelDownloading` (amber).
- `.unavailable(.appleIntelligenceNotEnabled)` → amber + deep-link to iOS Settings.
- `.unavailable(.deviceNotEligible)` → orange, no recovery.

Re-evaluated on `scenePhase == .active`.

### Rewrite presets (MVP 2)

No state machine — read-only static list.

---

## Open Questions

1. **Provider picker in MVP 2?** Recommendation **no** — exposing 6 providers without keychain + Test Connection is half-shipped.
2. **Parakeet variant in Settings?** Recommendation **no, ever** — 320ms is the defensible default, 160ms costs accuracy, 1280ms isn't user-facing. DEBUG-only.
3. **Editable cleanup prompt before provider choice?** Recommendation **no** — creates migration debt when other providers land. Keep opaque until the AI pane is whole.
4. **Re-run setup wizard mid-session?** Wizard cover refuses to mount while recording or post-processing. Confirm.
5. **Erase Data scope.** Recommendation: **yes**, also wipe the model — confirmation copy must say so explicitly.
6. **"Last verified" timestamp — useful or engineer instinct?** Ship muted; drop after 4 weeks if no support tickets cite it.
7. **Apple FM mid-download progress.** Apple FM doesn't expose progress. Keep "Apple Intelligence model downloading…" as-is; no fake bar.

---

## References

### External design references

- **Superwhisper (macOS / iOS)** — primary reference for deviation cases. Borrowed in three places: (1) the **model status card** at the top of the Speech-model pane mirrors Superwhisper's "Installed Model" card; (2) the **AI provider list** mirrors Superwhisper's settings-as-table-rows for model providers — every option visible as a row with icon + name + tag, not buried in a `Picker(.menu)`; (3) the **prompt configuration** mirrors Superwhisper's prompt-config-as-inline-disclosure (`DisclosureGroup` unfolds the prompt in place, no push).
- **Wispr Flow (iOS)** — secondary; accessory-pill placement above the keyboard (used for the future-tier "Kept for 7 days" retention pill).
- **Things 3 (iOS)** — secondary; row-layout discipline (single line, trailing detail) for top-level Settings rows.
- **Linear** — secondary; muted tag chips ("on-device" / "local" / "cloud") on the AI provider list.

### Project files

- `/Users/vsriram/code/jot-mobile/Jot/App/Settings/SettingsView.swift:1-266` — Tejas's current settings (chrome being dropped).
- `/Users/vsriram/code/jot-mobile/Jot/App/Cleanup/CleanupService.swift:6-26,88-196` — `CleanupStatus` + Apple FM availability mapping.
- `/Users/vsriram/code/jot-mobile/Jot/Shared/CleanupSettings.swift:6-29`, `/Users/vsriram/code/jot-mobile/Jot/Shared/AppGroup.swift:24-36` — persisted shape + App Group keys.
- `/Users/vsriram/code/jot-mobile/Jot/App/Transcription/TranscriptionService.swift:30-36,184-560` — `ModelState` drives the model card.
- `/Users/vsriram/code/jot-mobile/EXPERIMENTS.md:9-39`, `/Users/vsriram/code/jot-mobile/README.md:36-83` — Parakeet/Apple FM experiments, stack.
- `/Users/vsriram/code/jot/iOS/docs/features.md:34-46,62-86,110-176` — feature inventory + tier assignments.
- `/Users/vsriram/code/jot/iOS/docs/handoff/cleanup.md:32-49,118-135,186-194` — provider matrix, UserDefaults keys, Settings brief.
- `/Users/vsriram/code/jot/iOS/docs/handoff/model-mgr.md:166-194,253-260` — `ModelStatus` machine, Wi-Fi-only contract.
- `/Users/vsriram/code/jot/iOS/docs/handoff/parakeet.md:166-178` — variant recommendation.
- `/Users/vsriram/code/jot/iOS/docs/handoff/app-layout-design.md:413-643` — full Settings surface design.
