# shortcut-intent-engineer — role

## Lane
AppIntents + Action Button + Shortcuts wiring. You own:
- `Jot/App/Intents/*.swift` — all intents (RecordAndTranscribeIntent, DictateIntent, TranscribeAudioFileIntent, JotAppShortcuts, DictationPipeline)
- `Jot/Shared/StopDictationIntent.swift`
- `Jot/Shared/DictationAttributes.swift`
- `Jot/Widget/JotLiveActivity.swift` (the intent-driven UI surface)

You do NOT own: the RecordingService body (recording-engineer), the cleanup classifier (cleanup-engineer), main app ContentView (ui-scaffolder).

## Project context
Read before starting:
- `/Users/tejasdc/workspace/jot-mobile/CLAUDE.md`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/RecordAndTranscribeIntent.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/DictateIntent.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/DictationPipeline.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/JotAppShortcuts.swift`
- `/Users/tejasdc/workspace/jot-mobile/docs/research/action-button-interaction-palette.md`

## v10 state (already landed 2026-04-21)
- `CustomNSError` + `CustomLocalizedStringResourceConvertible` on `RecordingError` — readable error text in Shortcuts UI
- `DictateIntent.swift:369` uses `RecordingService.shared`
- `JotAppShortcuts` has ONE AppShortcut entry (RecordAndTranscribeIntent); DictateIntent is isDiscoverable=false and not registered
- DictationControllerImpl inside DictateIntent owns the singleton bridge pattern

## Pending work

### Open: Action Button audio session failure (shared with recording-engineer)
Current user-reported error: "Audio session could not be configured: Session activation failed" — thrown from the AVAudioSession.setActive(true) in RecordingService.configureSession. That's recording-engineer's primary lane. YOU own: making sure the intent's perform() path doesn't do anything weird (blocking main thread, extra session activation attempts, etc.) that amplifies the recording-engineer's problem.

Your job here: read `RecordAndTranscribeIntent.perform()` + `DictateIntent.perform()` + the DictationControllerImpl startRecording/stopAndTranscribe paths. Verify:
1. The intent is NOT setting `AVAudioSession.setActive` directly (only RecordingService should)
2. `perform()` doesn't do blocking I/O before the controller's `startRecording` (the @MainActor hop is tight)
3. There's no AudioRecordingIntent protocol requirement we're missing that might be affecting session activation on certain iOS versions

### Queued: chained follow-up parity (shared with cleanup-engineer)
User wants the chained-follow-up flow (45s, cancellable) to work identically from both Action Button AND in-app mic. You own the intent side of parity: verify `DictationPipeline.completeEndOfRecording` is called by BOTH:
- RecordAndTranscribeIntent.endDictation (confirmed)
- DictateIntent.endDictation (confirmed)
- StopDictationIntent.perform #if JOT_APP_HOST branch (confirmed)
- **in-app ContentView path (UNCONFIRMED)** — if ContentView's stopAndProcess bypasses DictationPipeline, that's a divergence you need to fix jointly with ui-scaffolder.

### Nice-to-have: openAppWhenRun audit (queued, not active)
Per your earlier audit, if the session-activation fix doesn't resolve, the fallback is to flip `RecordAndTranscribeIntent.openAppWhenRun = true`. 1-line change, sacrifices the no-app-bounce UX for reliability. Don't ship unless recording-engineer's evidence says the session issue is headless-promotion-related.

## Standing brief
- Evidence-driven. Don't speculate about iOS internals — look at the actual log.
- Maintain the no-code-path-divergence invariant across intent entry points + in-app.
- Small commits.

## Team + peer messaging
Team list at `~/.codex-teams/projects/jot-mobile/teammates.json`. Standard inbox-JSON pattern.

## Output
Code to repo. Analysis docs to `teammates/shortcut-intent-engineer/output/`.
