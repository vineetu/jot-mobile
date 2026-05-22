# Deferred Engineering Work

Items intentionally deferred. Each is a real piece of work the team agrees needs to happen, but is **not on the critical path for any current product feature.** Pick from this list when between feature cycles — "no features to work on" time is the right slot.

Each entry has:
- **Why it matters** — the user-facing or system-level pain that justifies the work
- **What we'd build** — a brief sketch, enough to not need a fresh design session to start
- **Trigger** — what would escalate this back onto the critical path
- **Estimated size** — rough order of magnitude (hours / day / week)

---

## 1. Generic versioned-migration system (Flyway-style)

**Why it matters.** Today we hand-write one-shot migrations (Phi-4 weight purge, Articulate prompt copy update, AI prompt insertion, legacy Parakeet App-Support sweep, etc.) directly in `JotApp.init`, each gated by an ad-hoc `UserDefaults` flag. Three problems with this shape:

1. **Order-of-operations bugs.** The flag-flip-before-work pattern (which got us once already — see `[[feedback-flag-before-work-antipattern]]` in agent memory) leaves devices in a "marked done, work never ran" state with no recovery short of reinstall or a key-bump.
2. **No version coordination.** Two future migrations that both touch the same data structure could fight each other in an unintended order, since the flags don't carry sequence information.
3. **No audit trail.** A user reporting "I'm on build 1.0.4 but my Articulate prompt is the v1 wording" has no way to tell us which migrations did or didn't run on their device.

**What we'd build.** A small migration registry, modeled on Flyway:

- `protocol Migration { var id: String { get }; var version: Int { get }; func apply() throws }`
- `MigrationRunner.runPending()` called once at launch — reads a stored `applied-migrations.json` list from AppGroup, runs every registered migration whose id isn't in the list, in `version` order, and appends to the list **only after** each `apply()` returns without throwing.
- Each existing migration (Phi4 purge, Articulate overwrite, AI prompt insert, etc.) becomes a typed conformer.
- Built-in support for "always-overwrite" migrations: a `class AlwaysApplyMigration: Migration` variant that runs every launch (idempotent by design — the prompt-default-overwrite case). Keeps the no-flag policy intact for pre-ship state but unifies the code path.
- Diagnostics log integration: emit a `migrationApplied` event for each successful run, including version + id, so the Help screen's diagnostics view becomes a clean audit trail.

**Trigger to pull this forward.** Any of:
- A third migration order-of-operations bug ships a broken state to a user
- We add more than ~6 ad-hoc migrations and the launch path becomes hard to read
- We need to support paid users with synced data (migrations would need to coordinate cross-device — and that requires the version model anyway)

**Estimated size.** ~1-2 days. Most of the work is the runner + tests; converting the existing ad-hoc migrations is mechanical.

**Status.** Captured 2026-05-21. Not yet scoped further. Pre-launch behavior (overwrite-on-every-launch for prompt defaults, no flags) explicitly accepted by user until App Store ship.

---

## 2. In-app dictation: tap-to-record from any text field, no home-screen detour

**Why it matters.** When the user is *inside Jot* and triggers dictation via the keyboard (e.g., editing a saved prompt, typing into a settings text field, the new-prompt editor, the future custom-vocab term editor, etc.) — today this routes through the same path as a third-party host: keyboard → URL bounce → Jot's home → Recording Hero. That's the right flow when the host is *another app* (the keyboard can't directly start a recording outside the main app's lifecycle), but it's wrong when the host already IS Jot.

The user shouldn't be sent back to the home screen and forced to navigate to whatever text field they were just editing. They expect a tap-to-record-here UX: cursor stays where it was, recording starts inline (or in a compact in-place affordance), transcript drops into the field they were already editing.

**What we'd build.** A two-track dictate dispatcher in `JotKeyboardViewController.handleMicCTATap`:

- **Host = third-party app** → today's URL-bounce + Hero flow (unchanged).
- **Host = Jot itself** (already detectable via `AppGroup.isJotAppForeground()` per the W5 wizard short-circuit pattern) → start recording in-place via a Darwin notification (similar to `warmResumeRequested`). The main app gets the signal, captures the current focused text field's identity (via SwiftUI focus state or UITextField responder chain), records, transcribes, and inserts into the same field — no Hero, no home detour.

In-place recording UI surface: needs a small "recording in this field" affordance. Could be:
- A compact pill that appears below or above the focused text field with timer + waveform + stop, OR
- A semi-transparent overlay that doesn't take over the screen, OR
- Reuse the keyboard's StreamingStrip as the live indicator and the field as the typing target.

**Trigger to pull this forward.** Any of:
- We add more in-app text-entry surfaces (custom vocab, prompt names, prompt instructions, saved-prompts editor) — every one of these compounds the "kicked to home" pain
- A user explicitly complains about the home-screen kickback during in-app dictation
- We start considering the watch-companion or iPad layouts (those will need the same in-place dictate primitive)

**Estimated size.** ~3-5 days. The dispatcher branching is small; the real work is the in-place recording UI design + plumbing the captured text back to the original responder.

**Status.** Captured 2026-05-21. Tied to the broader "Jot's surfaces are typing-allergic" philosophy — the keyboard is dictation-only by design, and we shouldn't ask users to type *inside* Jot when we have a real dictation primitive sitting in their pocket.

---

## 3. In-app feature catalog + per-version release log

**Why it matters.** Today the only place a user learns what Jot can do is:
- the App Store description
- the setup wizard (very thin — onboarding-focused)
- the Help screen's "What it's for" + "Getting Started" sections (story-shaped, not a comprehensive list)

There's no in-app surface that shows the user the **full list** of features the app actually has, and no surface showing **what shipped in which version** (so a returning user who upgraded from 0.9 to 1.0 has no way to see what changed unless they read App Store release notes). Both are common patterns in well-considered consumer apps (e.g. Things, Bear, Drafts) and Jot is missing them.

**What we'd build.** Two new Help sub-sections:

1. **Feature catalog** — a scrollable list of every user-facing feature in Jot, grouped by surface (Recording, Keyboard, AI Rewrite, Vocabulary, Settings, etc.). Each entry has a one-line description and (optionally) a "Show me" affordance that deep-links to the relevant settings row, wizard panel, or affordance. Source of truth: features.md, which is already organised this way. The catalog renderer parses features.md at build time (or at install — features.md ships in the bundle) and produces the in-app list. Keeps the doc and the UI in sync automatically.

2. **What's new / release log** — per-version "What changed" entries. On version bumps, the user gets a one-time sheet on first launch summarizing what's new in that version. They can always re-read from Help. Backed by a small `Resources/release-notes.json` array (one entry per shipped version: version string, date, bullet list of changes). Maintained alongside the App Store release notes — same source, displayed in-app for users who don't read App Store metadata.

**Trigger to pull this forward.** Any of:
- We ship a feature that users routinely miss because it's not discoverable (e.g. the "Move up / Move down" keyboard actions, or the long-press → "Delete model" affordance)
- We get a support question asking "what changed in this update" — proves users want the changelog inside the app
- We pass 5 shipped versions and the App Store release-notes timeline is no longer enough context for a new user trying to understand the app's state

**Estimated size.** ~2-3 days. Feature catalog renderer is the bigger piece (markdown-to-SwiftUI parsing for features.md, or a simpler JSON sidecar). Release log is straightforward — JSON file + one new sheet + a UserDefaults "lastSeenVersion" key for the one-time-on-upgrade trigger.

**Status.** Captured 2026-05-21.

---

## 4. Milestone-based donation prompt on the home screen

**Why it matters.** Today the Donations screen ([features.md §6.7](../Jot/features.md)) is reachable only via Settings → About → Donations. A user who never opens Settings will never discover it. Result: Jot is genuinely free but most users won't even know they have the option to give back. The data is right there — the app already tracks cumulative time-saved per [§6.5](../Jot/features.md) — we're just not surfacing it at the moment of value.

**What we'd build.** A dismissible "milestone card" that appears above the recents list on the home screen when the user crosses a meaningful cumulative time-saved threshold.

**Trigger conditions:**
- Cumulative time-saved ≥ 30 minutes (first threshold)
- Subsequent thresholds at 2h, 5h, 10h (multi-step encouragement, not a single one-shot)
- AND the user hasn't dismissed the card in the last 90 days
- AND the user hasn't tapped "Never ask again"

**Card shape:**
- Single line: *"Jot has saved you 32 minutes."* (computed from the actual milestone hit)
- Sub-line: *"Want to give back? See where Jot raises money →"* — tap opens the Donations screen
- Trailing × to dismiss this instance (90-day cooldown starts)
- Long-press → context menu with "Don't show again" (sets a never-ask UserDefaults flag)
- Visual: same Liquid Glass card surface as other home-screen cards. Coral accent on the "Want to give back?" line to mark it as an opt-in CTA, not a system status.

**Implementation sketch:**
- New UserDefaults keys: `jot.donation.lastShownAt` (Date), `jot.donation.dismissedMilestones` (Set<Int> — milestone-second values already shown), `jot.donation.neverAskAgain` (Bool).
- New small view `DonationMilestoneCard` in `Jot/App/Donations/` (folder to be created).
- Render-decision helper on the home view: read the existing time-saved tracker, compare against the threshold list, surface the highest unshown milestone that's also outside the 90-day cooldown.
- One-shot tap navigates to `DonationsView` (already exists per §6.7) via the same nav-path machinery the rest of Settings uses.

**Pros / cons of this shape over alternatives:**
- Surfaces at a real value moment (time-saved milestone), not "after 5 launches" or "after onboarding"
- Generous-first framing ("Jot has saved YOU 32 minutes") before any ask — feels like a thanks, not a pitch
- Dismiss-first design (90-day cooldown, never-ask, multiple thresholds rather than escalation) keeps it from becoming a nag
- Stays on the home screen — same surface the user already loves — instead of yanking them into a sheet or push notification

**Trigger to pull this forward.** Any of:
- Donations community feed shows low engagement post-launch (signal that the pull-only path isn't enough)
- We add other home-screen cards and the card-rendering infrastructure exists → low marginal cost to add this one
- We have a creative push to write the donation copy and want to ship a fresh value milestone for a launch moment

**Estimated size.** ~1 day. Card UI is small (~80 lines of SwiftUI). Threshold logic + UserDefaults gating is straightforward. Donations screen already exists; only the deep-link wiring is new.

**Status.** Captured 2026-05-21. Direction confirmed by user — option 1 from the donation-prompt discussion. Not on the critical path; defer until donations engagement data motivates building.

---
