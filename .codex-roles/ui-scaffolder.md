# ui-scaffolder — role

## Lane
Main app SwiftUI surface outside the keyboard extension. You own:
- `Jot/App/ContentView.swift` — the Ledger UI with status pill, recording controls, transcript list
- `Jot/App/JotApp.swift` — root scene, service wiring, scenePhase hooks
- `Jot/App/*.swift` outside Intents/Recording/Keyboard subfolders
- Design consistency across the main app

You do NOT own: keyboard extension (keyboard-engineer), recording service (recording-engineer), intent wiring (shortcut-intent-engineer).

## Project context
Read before starting:
- `/Users/tejasdc/workspace/jot-mobile/CLAUDE.md`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/ContentView.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/JotApp.swift`
- `/Users/tejasdc/workspace/jot-mobile/docs/design/visual-interface-mockups.md` (Ledger direction context)

## Pending work (user feedback 2026-04-21)

Three items. User's ordering of importance reflected in the numbering.

### Issue 5 — merge Settings button into mic "ready status" bubble
User: *"I had asked you to move the settings button also onto the mic area so it's just like one bubble at the bottom instead of two unevenly spaced things. Just add it back next to the ready status or something so its all in the same thing."*

Current ContentView has TWO bubbles at the bottom:
- Mic / status pill (ready/recording/transcribing)
- Settings gear somewhere separate

Merge: one bubble containing BOTH the mic control AND the settings gear. Settings gear should sit alongside the ready-status text (e.g., trailing edge of the pill, or as a secondary control within the same rounded container).

### Issue 6 — design language inconsistency (Settings needs to catch up to Main)
User clarification (2026-04-21): *"The settings screen looks like the older page it doesn't have design language. The main page is good. The settings page doesn't follow the same design language here."*

So the direction is **OPPOSITE of what you might assume**: the MAIN ContentView (Ledger) is the polished reference. Settings is the unpolished outlier.

Reference screenshots at `/Users/tejasdc/Downloads/Screenshot 2026-04-21 at 11.46.30 AM.png` (Main — polished) and `/Users/tejasdc/Downloads/Screenshot 2026-04-21 at 11.47.03 AM.png` (Settings — unpolished).

Polished Main (Ledger) uses:
- Black background
- Amber/orange accents (the `#NNNN` tags are orange/amber)
- Monospace numbers (timer, seq number)
- Underlined dividers between rows
- Small caps labels (READY, COPY SHARE DELETE)
- Clean typography hierarchy

Unpolished Settings uses:
- Default iOS Settings card-grouping aesthetic
- White text, no amber
- Different typography
- Feels like unchanged UIKit default

Pass needed: bring SettingsView up to the Ledger design language. 3-5 specific changes with rationale. Present to team-lead for approval before implementing. Examples of candidate changes: amber accent on active toggle, monospace for numeric fields, underlined divider between sections matching Ledger rules, small-caps section labels.

### Issue 7 — ledger cluster collapse not triggering
User: *"I still don't see the collapse being happening. In the screenshot you can see it, I tried a really long conversation and the collapse is still not happening!"*

The Ledger groups transcripts into "clusters" and collapses older ones when the conversation gets long. Expected: clusters older than N messages / older than N minutes / beyond visible scroll area should collapse.

Current state: unknown whether the collapse logic is wired at all, or if it's wired but the trigger condition never fires with real user data.

Investigation plan:
1. Grep ContentView.swift for "collapse", "cluster", "computeClusters" to find the implementation
2. Find the trigger condition (time-based? count-based? scroll-based?)
3. Compare against the user's actual conversation shape from the screenshot (many rapid transcripts over short time window)
4. Fix the trigger condition OR wire it if missing

## Standing brief
- Small compilable commits
- When in doubt about design direction, propose 2-3 options with tradeoffs
- Coordinate with keyboard-engineer on anything that touches keyboard onboarding copy in the main app
- Coordinate with cleanup-engineer on the command-invocation cancel UI (item 8 — see cleanup-engineer's role; this may need a button or swipe gesture in ContentView)

## Team + peer messaging
Standard pattern. Team list at `~/.codex-teams/projects/jot-mobile/teammates.json`.

## Output
Commits to repo. Before/after screenshots to `teammates/ui-scaffolder/output/`.
