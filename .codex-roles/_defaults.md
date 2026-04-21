# jot-mobile — team defaults

Rules every teammate inherits. Role-specific files add lane detail on top of this.

## Done criteria (hard requirements)

No teammate may report "done", "landed", "ready for rebuild", or "ready for review" without all of these:

1. **Build passes.** Run from the project root:
   ```
   cd /Users/tejasdc/workspace/jot-mobile && bash build.sh && \
   xcodebuild -project Jot/Jot.xcodeproj -scheme Jot -configuration Debug -sdk iphoneos -allowProvisioningUpdates build
   ```
   If the build fails, you are NOT done. Fix the build or revert your change.
   If your sandbox cannot run `xcodebuild` (SwiftPM cache permission errors, CoreSimulatorService dead), say so explicitly in your reply. That is an escalation, not a "done" signal.

2. **Git commit exists.** Do not leave changes in the working tree with only a verbal "the fix is on disk." If it's not committed, it's not landed.
   Commit convention: `fix:`, `feat:`, `chore:`, `instrument:`, `docs:` as verbs. Subject under 72 chars.

3. **Symbol verification (when adding new public Swift symbols).** If you added a new type, new method, or new @AppIntent, confirm it appears in the emitted `Jot.debug.dylib`:
   ```
   nm -a /Users/tejasdc/Library/Developer/Xcode/DerivedData/Jot-*/Build/Products/Debug-iphoneos/Jot.app/Jot.debug.dylib | \
     swift-demangle | grep -E '<YourSymbol>'
   ```

4. **Reply back to team-lead with the commit SHA and build status.** Not "implementation complete" — the actual SHA.

## Protected paths

Never write to these directly:

- `~/.claude/` (any path under it — protected by Claude Code gate, writes silently fail)
- `~/.codex-teams/projects/*/teammates/*/inbox/` — outside your workspace-write sandbox; peer messages via this path WILL fail silently. If you need to cascade to another teammate, write the request to `<project_root>/tmp/codex-team-outbox/<ts>-<uuid>.json` and note it in your reply to team-lead so team-lead relays.

## Replies

- Include: files changed, commit SHA, build result (BUILD SUCCEEDED / specific error), anything that diverged from the brief.
- Do NOT claim success if you skipped the build. Say "build skipped because <reason>" and let team-lead decide whether to accept.
- If you're blocked by something outside your lane (a peer's broken symbol, a missing git repo, an environmental issue), say that explicitly and stop. Don't silently commit partial work.

## Project meta

- Working dir: `/Users/tejasdc/workspace/jot-mobile`
- Git: initialized on `main`. Commit directly — no feature branches for solo engineer work.
- Device UDID: `00008150-000663293C92401C` (jPhone)
- Install path: `xcrun devicectl device install app --device <UDID> <Jot.app path>`
- Syslog: `idevicesyslog -u <UDID> --no-colors -o /tmp/jot-syslog-*.log`
  (note: iOS redacts third-party `os_log` output unless the Apple Logging configuration profile is installed on device; don't assume a syslog capture proves behavior without that profile)

## When stuck

- Ask team-lead via your reply. Don't guess past 2 failed approaches.
- Don't spawn new lanes of work without team-lead approval. Stay in your role's lane.
