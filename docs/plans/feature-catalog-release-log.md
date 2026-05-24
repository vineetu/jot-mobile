# Plan: In-App Feature List + Forward-Only Release Log

> **Source:** [docs/deferred-engineering.md §3](../deferred-engineering.md)
> **Status:** Simplified after several rounds. Catalog is hand-coded static SwiftUI; no JSON sidecar, no CI check, no auto-sync. Release log is forward-only starting from the version that ships this feature.
> **Size: S** (~1 day combined).

---

## Requirements

Users need two things they don't have today:

1. **A scrollable list of what Jot does**, grouped by hero feature, accessible from Help. Hand-maintained. Not auto-generated from anything.
2. **Per-version "what's new"** for upgrades, surfacing once when the user opens the app after an update. Always re-readable from Help. **Starts forward** — no back-fill of past versions (1.0, 1.0.1, etc. simply don't have entries).

### What changes

- New Help section: "All features" — static SwiftUI list.
- New Help section: "What's new" — accordion list of version entries.
- First-launch-after-update sheet showing the current version's entry. Suppressed during wizard. Fires once per version bump.

### What does NOT change

- `features.md` continues to be the engineering source of truth for product behavior, not a user-facing surface.
- No JSON sidecar (`feature-catalog.json` is dropped).
- No CI check to enforce sync.
- No build-phase script.
- No URL deep-link routing from catalog items to settings/wizard surfaces.

---

## Problem

The user has no in-app way to discover Jot's feature surface or see what changed in a given version. Result: features ship and remain undiscovered (Move up/down in Actions, long-press Delete model, milestone donations, etc.).

## Design

### Feature list

A new Help section titled **"All features"**, placed below "Getting started." Layout: hero-feature sections, each with a few bullets.

Hand-coded in SwiftUI. Example structure:

```swift
HelpSection(title: "Recording") {
    FeatureRow(name: "Dictate from anywhere",
               summary: "Tap Dictate from the home screen or keyboard. Recording surface takes over the screen.")
    FeatureRow(name: "Live transcript",
               summary: "Streaming text appears as you speak.")
    FeatureRow(name: "Backgrounding",
               summary: "Swipe back during a recording — it keeps going.")
    // ...
}
HelpSection(title: "Keyboard") {
    FeatureRow(name: "Dictation-only",
               summary: "Replaces system keyboard while active. No QWERTY.")
    FeatureRow(name: "Recents strip",
               summary: "Top strip shows recent dictations, tap to re-insert.")
    // ...
}
HelpSection(title: "AI Rewrite") { ... }
HelpSection(title: "Vocabulary boost") { ... }
HelpSection(title: "Settings & Privacy") { ... }
```

Hero feature groups (rough):
- Recording
- Jot Keyboard
- Transcript library
- AI Rewrite
- Vocabulary boost
- Settings & Privacy
- Donations

Total ~30-40 feature rows hand-curated. Maintenance burden: when a new feature ships, add a row. One developer edit per shipped feature.

### Release log

A new file `Resources/release-notes.json` (or inline Swift array — either works for the small data size):

```json
{
  "versions": [
    {
      "version": "1.1.0",
      "shippedAt": "2026-06-XX",
      "headline": "In-app dictation, Cancel button, feature list",
      "items": [
        "Dictate into Jot's own text fields without leaving the screen.",
        "Cancel button appears while recording — abort without saving.",
        "New Help section: All features."
      ]
    }
  ]
}
```

**Versions before this feature ships are not listed.** No back-fill of 1.0 / 1.0.1 / earlier. The release log starts forward.

#### First-launch-after-update sheet

Logic:
- On scene-active, read `lastSeenReleaseLogVersion` from UserDefaults.
- If `lastSeenReleaseLogVersion != currentVersion` AND we have an entry for `currentVersion` AND wizard is not active → present sheet.
- Sheet shows current version's headline + items. Single "Got it" button dismisses.
- On dismiss: write `lastSeenReleaseLogVersion = currentVersion`.

Fresh installs: on first scene-active, stamp `lastSeenReleaseLogVersion = currentVersion` without showing the sheet. The user sees the sheet only on subsequent upgrades.

#### Always-readable

A "What's new" section in Help. Simple accordion: each version is a row that expands to show the items.

---

## Implementation Outline

| Step | Where | Size |
|---|---|---|
| 1. New `FeatureListView.swift` with hand-coded sections | `Jot/App/Help/FeatureListView.swift` (new) | M (most of the day — content curation + layout) |
| 2. Wire FeatureListView into HelpView as a new section | `Jot/App/Help/HelpView.swift` | XS |
| 3. `Resources/release-notes.json` (or inline Swift) seeded with the first entry (the version that ships this feature) | `Jot/Resources/release-notes.json` or `Jot/App/Help/ReleaseLog.swift` | XS |
| 4. `WhatsNewSheet.swift` + first-launch-after-update trigger | `Jot/App/Help/WhatsNewSheet.swift` (new), `Jot/App/JotApp.swift` scene-active handler | S |
| 5. "What's new" Help section (accordion of versions) | `Jot/App/Help/HelpView.swift` | S |

**Total size: S** (~1 day, content-curation-bound rather than code-bound).

---

## Edge Cases

- **Fresh install** — `lastSeenReleaseLogVersion` is nil. Stamp current version on first scene-active without showing sheet.
- **User skips two versions** (1.1.0 → 1.3.0). Sheet shows the latest version's entry only (1.3.0). Previous versions accessible via the always-readable Help section.
- **Downgrade.** `lastSeenReleaseLogVersion > current`. Don't show anything; don't bump. No-op.
- **Wizard active during scene-active.** Sheet suppressed; will fire on next scene-active outside the wizard. The `lastSeenReleaseLogVersion` only updates on dismiss, so the trigger isn't burned.
- **Release notes missing for current version** (we forgot to add an entry before shipping). Sheet doesn't fire. No banner. Help screen's "What's new" simply shows nothing for that version. Acceptable — soft fail, not user-hostile.
- **Feature list stale** (a feature ships but nobody updates the list). Catalog row missing for that feature. User wouldn't know. Acceptable as soft drift — fix when noticed.

---

## Test Plan

1. Build the app fresh → Help screen → "All features" renders with hand-coded sections.
2. Open a feature row → reads correctly. No tappable affordance (no deep links).
3. Simulate scene-active with `lastSeenReleaseLogVersion = nil` → no sheet, version stamped.
4. Simulate scene-active with `lastSeenReleaseLogVersion = "previous"` and a current version entry exists → sheet fires; dismiss → version updated.
5. Repeat (4) → no sheet (version already seen).
6. Wizard active + scene-active → no sheet; close wizard → next scene-active → sheet fires (trigger preserved).
7. Help → "What's new" accordion → versions listed; expand → items show.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md). (None remain for this plan post-simplification.)

---

## Cross-Links

- Embeds into: `Jot/App/Help/HelpView.swift`
- Touches: `Jot/App/JotApp.swift` (scene-active handler)
- Independent of: `Jot/features.md` (engineering doc, separate from user-facing surfaces)
- Related: future donation milestone (D4), in-app dictation (D2) — these would get release-log entries when shipped.
