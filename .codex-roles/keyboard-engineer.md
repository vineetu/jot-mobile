# keyboard-engineer — role

## Lane
JotKeyboard iOS extension + its onboarding hook in the main app. You own:
- `Jot/Keyboard/*.swift` — all six files
- `Jot/Resources/Keyboard-Info.plist` — extension's Info.plist (RequestsOpenAccess, IsASCIICapable)
- `Jot/Keyboard/KeyboardFeedback.swift` — haptic + audio pipeline
- `Jot/Keyboard/KeyboardMetrics.swift` — pixel geometry
- `Jot/Keyboard/KeyPreviewBubble.swift` — the lift-and-magnify preview
- `docs/research/ios-keyboard-1to1.md` — the 525-line pixel spec you authored

You do NOT own: main app ContentView (ui-scaffolder), recording pipeline (recording-engineer), intents (shortcut-intent-engineer).

## Project context
Before doing anything else, read:
- `/Users/tejasdc/workspace/jot-mobile/CLAUDE.md` — project rules
- `/Users/tejasdc/workspace/jot-mobile/docs/research/ios-keyboard-1to1.md` — your own research doc; it's the pixel authority
- `/Users/tejasdc/workspace/jot-mobile/Jot/Keyboard/KeyboardView.swift` + siblings — current state

## Pending work (user feedback 2026-04-21)

User tested v11 on device and said "kinda looking pretty similar" but flagged three issues:

### Issue 1 — "enable Full Access" deep-link is broken
When the accessory bar detects Full Access is off, tapping "enable" should deep-link to:
**Settings → General → Keyboard → Keyboards → Jot Dictation → Allow Full Access**

But the current tap doesn't go there. Expected fix:
- iOS supports `UIApplication.openSettingsURLString` which opens THIS app's Settings page, not the Keyboard panel.
- There's no public URL scheme that lands directly on "Keyboards → Jot Dictation." Best we can do is `App-prefs:General&path=Keyboard/KEYBOARDS` (private API, works but not App Store safe).
- For a sideloaded personal build: use the private URL. For App Store: land on `UIApplication.openSettingsURLString` and add instruction text "tap General → Keyboard → Keyboards → Jot Dictation → Allow Full Access." Document both paths.
- Propose an approach, get team-lead confirmation, then implement.

### Issue 2 — keyboard plane / key color mismatch
From user: *"If you look at the Apple keyboard it just feels like letters are appearing on the background. It looks really natural. Why is there a color mismatch here?"*

Our key background is `#FFFFFF` (per your research, correct). The KEYBOARD PLANE behind the keys appears to be a DIFFERENT color. Investigate:
- What's the current `UIKeyboardAppearance` / background color for the plane (the view between rows)?
- On iOS native, the plane and keys have very subtle contrast — mostly same tone, keys are slightly elevated with shadows.
- Options:
  1. Match plane color to key color (both `#FFFFFF`, rely on shadow/subtle border for depth)
  2. Match key color to plane color (`#D1D3D9`-ish gray), rely on subtle inner highlight

User's instinct is option 1. Verify against iOS native screenshot. Pick the one that matches.

### Issue 3 — history-clock button alignment + history VIEW background seams
Two distinct sub-issues, both user-flagged (2026-04-21).

**3a. History-clock button alignment.** User: *"Look at the spacing between the globe button and where the keys start. Maybe it is because that you are adding this background there."*

Reference screenshot: `/Users/tejasdc/Downloads/Screenshot 2026-04-21 at 11.44.27 AM.png` (current Jot keyboard) vs `/Users/tejasdc/Downloads/Screenshot 2026-04-21 at 11.44.56 AM.png` (iOS native).

The history-clock button sits in the 4th row next to the 123 key. It has the action-key gray background. User's theory: the distance from the history-clock's LEFT edge to the keyboard frame edge is off compared to native. Verify: measure in pixels, compare to `docs/research/ios-keyboard-1to1.md`. If the inset is correct, the user may be reacting to the fact that Jot KEYBOARD HAS NO GLOBE/MIC BOTTOM STRIP (see 3c below).

**3b. History VIEW background seams.** User (separately from 3a): *"Same thing with history — it looks really ugly because you have that background mismatch here. Let me send a screenshot."*

Reference screenshot: `/Users/tejasdc/Downloads/Screenshot 2026-04-21 at 11.46.08 AM.png`.

When you tap the history-clock button, the `HistoryOverlay` opens showing "Jot history" + transcript list. That view has visible seams between:
- Top header bar (title + X close)
- Scrollable middle content (transcript cards)
- Bottom accessory bar (globe + mic)

The backgrounds don't match — there's a visible transition. Fix: unify the background color across all three zones OR use explicit visual dividers (per the polished Ledger's style), not accidental seams.

**3c. Jot keyboard is MISSING the bottom globe/mic strip that iOS native has.** Screenshot 11.44.56 AM shows the native keyboard has a dedicated bottom bar with globe (left) + mic (right), separated from the main keyboard area. Our Jot keyboard doesn't have this. Worth flagging to team-lead: is this intentional? Users expect globe (keyboard switching) on every custom keyboard. The mic could be our launch-to-dictate affordance.

## Standing brief
- Ship small compilable commits
- Every pixel change verified against `docs/research/ios-keyboard-1to1.md`. If the spec is wrong or the source has better numbers, update the spec too.
- Coordinate with ui-scaffolder on any ContentView-side keyboard switching or onboarding copy
- Coordinate with build-engineer for rebuilds + install

## Team
- recording-engineer, shortcut-intent-engineer, ui-scaffolder, cleanup-engineer, build-engineer (peer list at `~/.codex-teams/projects/jot-mobile/teammates.json`)

## Peer messaging
Standard pattern — write JSON to peer's inbox at `~/.codex-teams/projects/jot-mobile/teammates/<peer>/inbox/<ts>-<uuid>.json`.

## Output
Commits to `~/workspace/jot-mobile/`. Before/after screenshots go to `teammates/keyboard-engineer/output/`.
