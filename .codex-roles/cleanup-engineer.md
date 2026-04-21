# cleanup-engineer — role

## Lane
Transcript post-processing: LLM-based cleanup + chained follow-up (command invocation). You own:
- `Jot/App/Cleanup/CleanupService.swift`
- `Jot/App/Cleanup/RewriteInstructionClassifier.swift` (if exists)
- `Jot/Shared/ChainedFollowUp.swift`
- The pipeline integration in `Jot/App/Intents/DictationPipeline.swift` (coordinate with shortcut-intent-engineer who owns intent wiring; you own the classification + rewrite logic)

You do NOT own: recording (recording-engineer), intent wiring (shortcut-intent-engineer), UI surfacing of cancel (ui-scaffolder).

## Project context
Read before starting:
- `/Users/tejasdc/workspace/jot-mobile/CLAUDE.md`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Cleanup/CleanupService.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/Shared/ChainedFollowUp.swift`
- `/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/DictationPipeline.swift`
- `/Users/tejasdc/workspace/jot-mobile/docs/design/voice-interaction-patterns.md`

## Pending work (user directive 2026-04-21)

### Issue 8 — command invocation: 45s + cancellable + in-app + Action Button parity

Current state:
- `ChainedFollowUp.freshnessWindow = 75s`
- Pipeline: `DictationPipeline.completeEndOfRecording(transcript:, startedAt:, controller:)` handles the chained-follow-up branch for Action Button flow
- `CleanupService.resolveUtterance(new:, priorTranscript:) -> CommandResolution` is the classifier
- UNKNOWN: whether the in-app recording path (ContentView's mic button) uses the same `DictationPipeline.completeEndOfRecording` or a separate code path

**User's asks:**
1. Change 75s → **45s** — update `ChainedFollowUp.swift:freshnessWindow`
2. Make it **cancellable** — user should be able to abort the follow-up before the LLM runs
3. Works for **both** in-app and Action Button — same `DictationPipeline` call, no divergence

Proposed approach (validate before implementing):
1. **Window**: one-line change to `ChainedFollowUp.swift`. Easy.
2. **Cancellable**: during the classifier → transform → publish window, show a cancel affordance (UI is ui-scaffolder's — coordinate). On cancel:
   - Stop the in-flight LLM request
   - Treat the new utterance as a fresh dictation (paste as-is, don't supersede prior)
   - Don't mark prior transcript as superseded
3. **In-app parity**: grep for how ContentView's `stopAndProcess` handles the post-recording path. If it's NOT going through `DictationPipeline.completeEndOfRecording`, make it. "No code-path divergence across entry points" is the shipped invariant.

Specific questions to resolve while reading the code:
- Does the in-app flow currently check `TranscriptStore.mostRecent(within:)` at all?
- Does `CleanupService.resolveUtterance` have a cancel token / async-cancellation path? If not, what's the right Swift concurrency shape (`Task.cancel()` + `try Task.checkCancellation()` in the classifier?)
- Where should the cancel button live in the UI — on the pill, in the Live Activity, in both?

Write up your findings + proposed diff shape to `teammates/cleanup-engineer/output/chained-followup-45s-design.md`. Then wait for team-lead approval before implementing.

## Standing brief
- Evidence-driven: if the in-app flow already uses DictationPipeline, don't rewrite it
- Follow the no-code-path-divergence invariant
- Coordinate with ui-scaffolder on cancel UI placement
- Coordinate with shortcut-intent-engineer if DictationPipeline's signature needs to change

## Team + peer messaging
Standard pattern. Team list at `~/.codex-teams/projects/jot-mobile/teammates.json`.

## Output
Design doc + diff to `teammates/cleanup-engineer/output/`. Commits to repo when approved.
