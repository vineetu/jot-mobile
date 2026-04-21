# Session Resume Recovery

Recovery playbook for when team-lead's Claude Code session crashes and `/resume` leaves the team in a partially-connected state.

Written after the 2026-04-17 incident where outgoing `SendMessage` calls worked (teammates received them) but incoming replies never reached team-lead, despite 26+ messages piling up on disk in `~/.claude/teams/jot-mobile/inboxes/team-lead.json`.

## TL;DR (next-time recovery, <50 words)

1. **Don't kill teammates.** iTerm2 panes survive the lead crash — they're separate processes.
2. **Arm the inbox monitor (Procedure A′):** `Monitor({command: "python3 ~/.claude/temp/scripts/jot-inbox-poll.py", persistent: true, timeout_ms: 3600000})`. Live-streams new unread messages from disk back into team-lead's chat. See [`tools/inbox-monitor.md`](tools/inbox-monitor.md).
3. **If the monitor can't run:** fall back to Procedure A (one-shot python harvest). Same inbox file, no streaming.
4. **If still stuck:** spawn a fresh replacement lead — per Anthropic docs, in-process teammates can't be resumed; you must re-spawn named workers (context is lost).

---

## What actually breaks on resume

Official docs ([agent-teams#limitations](https://code.claude.com/docs/en/agent-teams#limitations)) confirm:

> **No session resumption with in-process teammates:** `/resume` and `/rewind` do not restore in-process teammates. After resuming a session, the lead may attempt to message teammates that no longer exist.

Plus [Issue #26265](https://github.com/anthropics/claude-code/issues/26265) (closed as duplicate):

> None [no workaround] that preserves teammate context. Users must re-spawn teammates from scratch in each new session, losing all accumulated context.

### Specific state that goes out of sync

| State | Behavior after resume | Reason |
|---|---|---|
| **Outgoing `SendMessage`** | ✅ Works | Writes directly to `~/.claude/teams/{team}/inboxes/{recipient}.json` with file locking. Lead doesn't need to know recipient is alive. |
| **Incoming messages (auto-delivery)** | ❌ Broken | `SendMessage` docs: *"Messages from teammates are delivered automatically; you don't check an inbox."* The resumed lead process is no longer subscribed to the on-disk inbox watcher, so replies land in `team-lead.json` but never surface in the chat. |
| **`config.json` `isActive` flag** | 🟡 Stale but not lying | Per community docs: *"Idle is not dead — teammates write `isActive: false` to config.json after every turn."* It flips to `true` while a teammate is actively producing output. A long-idle teammate showing `false` is still alive. |
| **iTerm2 panes (`backendType: iterm2`)** | ✅ Survive | Each pane hosts an independent `claude` process with its own session. Killing the lead's tmux/terminal does not kill the pane processes. Confirmed by known bug where dead panes linger after shutdown. |
| **Task list (`~/.claude/tasks/{sessionId}/`)** | ✅ Persisted | File-backed JSON, claims use file locking. |
| **Teammate context/history** | ❌ Lost if you re-spawn | Per Issue #26265: teammate transcripts are session-scoped; new lead can't re-attach to old named teammates. |

### Filesystem layout (verified on your machine)

```
~/.claude/teams/jot-mobile/
  config.json                       # members, leadSessionId, tmuxPaneId per member
  inboxes/
    team-lead.json                  # messages TO lead (the one that goes stale)
    recording-engineer-2.json       # messages TO that teammate
    ...one file per member
~/.claude/tasks/{leadSessionId}/    # shared task list (1.json, 2.json, ...)
~/.claude/sessions/                 # per-session transcripts
```

Each inbox entry: `{from, text, summary, timestamp, color, read}`. The `"read": false` flag is what tells the runtime "deliver this to the agent." After resume, nothing flips those to `true` because the watcher is dead.

### Evidence from this incident (18:54 UTC crash timestamp)

Inspection of `~/.claude/teams/jot-mobile/inboxes/team-lead.json` after the crash:

- **108 total messages**, 82 read, **26 unread**.
- **Last read:** `2026-04-17T18:53:58.971Z`
- **First unread:** `2026-04-17T18:54:07.025Z` (8 seconds later — matches the crash moment)
- **Last unread:** `2026-04-17T19:09:38.006Z` (15+ minutes of delivery gap)
- **Unread senders:** 8 distinct teammates — every active worker kept trying to report in.

The messages were on disk the whole time. The resumed lead just stopped reading them.

---

## Recovery procedures (least to most destructive)

### A′. Arm the inbox monitor (PRIMARY — live streaming) ⭐

**When to try first.** This is the primary recovery path. It bypasses the broken in-process watcher by streaming the on-disk inbox back into team-lead's chat as a live event source — zero context loss across future crashes, re-armable at any time.

**How Claude Code's `Monitor` tool works.** Any script whose stdout emits lines becomes a live event stream in the tool-using agent's chat. Each `print(flush=True)` in the script surfaces as a `Monitor event` chunk in team-lead's context (and as a `task-notification` in the user's chat). `persistent: true` keeps the monitor alive for the duration; `timeout_ms` can run up to 3,600,000 (one full hour). It's the streaming counterpart to `Bash + run_in_background` — where `run_in_background` gives you batch output you read later, `Monitor` gives you event-by-event delivery.

**The script** lives at `~/.claude/temp/scripts/jot-inbox-poll.py`. On startup it seeds a `seen` set with every message currently in the inbox, so it only emits items that arrive AFTER the monitor is armed. It polls `~/.claude/teams/jot-mobile/inboxes/team-lead.json` every 15 seconds, filters out `idle_notification` and structured `shutdown_*` / `idle*` JSON payloads (pure noise), and emits substantive messages as single lines formatted `[sender] summary :: text` (truncated at 500 chars with a char-count tail). Full reference: [`tools/inbox-monitor.md`](tools/inbox-monitor.md).

**The exact Monitor call to arm it.** Team-lead runs this once after every fresh session start or `/resume`:

```text
Monitor({
  description: "new unread messages in jot-mobile team-lead inbox",
  command: "python3 /Users/tejasdc/.claude/temp/scripts/jot-inbox-poll.py",
  persistent: true,
  timeout_ms: 3600000
})
```

**Why it's durable.**
- The inbox is file-backed (`~/.claude/teams/{team}/inboxes/team-lead.json`). Writes are file-locked. Data lands on disk regardless of which in-process watcher is healthy.
- Monitor re-arms cleanly — if the session crashes, re-running the same `Monitor(...)` call after `/resume` resumes streaming from the crash moment. The `seen` set re-seeds from the current on-disk state on restart, so no duplicates and no gaps beyond the re-seed window.
- Zero context loss: teammates keep replying normally, their messages land in the inbox file, the monitor surfaces them. Team-lead never sees the pipe as "broken."

**Generalizing to any team.** The script's only project-specific line is the inbox path (`INBOX = os.path.expanduser('~/.claude/teams/jot-mobile/inboxes/team-lead.json')`). To clone for a new team, copy the script and patch the team name:

```bash
cp ~/.claude/temp/scripts/jot-inbox-poll.py ~/.claude/temp/scripts/{newteam}-inbox-poll.py
sed -i '' 's|teams/jot-mobile/|teams/{newteam}/|' ~/.claude/temp/scripts/{newteam}-inbox-poll.py
```

Then update the `Monitor` call to point at the new script. Principle #11 in `principles.md` generalizes the pattern: any file-backed messaging system is polled-streamable.

### A. Read the inbox directly (one-shot fallback)

**When to use this.** Only if Procedure A′ can't run for some reason (Monitor tool unavailable, script missing, single-shot recovery of a specific message window). A′ supersedes A for anything ongoing.

```bash
# Dump the unread messages into human-readable form
python3 -c "
import json
d = json.load(open('$HOME/.claude/teams/jot-mobile/inboxes/team-lead.json'))
for m in d:
    if not m.get('read'):
        print('---')
        print(f\"FROM: {m['from']}\")
        print(f\"TIME: {m['timestamp']}\")
        print(f\"SUMMARY: {m.get('summary','')}\")
        print(f\"TEXT: {m['text'][:2000]}\")
"
```

Then paste the relevant summaries back to the team-lead as context in a normal user message. **Do not** hand-edit `"read": true` — the runtime may rewrite the file and your change gets clobbered.

### B. Nudge teammates for a fresh reply (mostly safe)

**Still lossless.** If the in-memory view is stale but outgoing works, you can ask each teammate to re-report via `SendMessage`. Their reply will write to `team-lead.json` too — but will still be invisible to the resumed lead. So this only helps if you pair it with procedure (A): re-read the inbox file after nudging.

Caveat: this spends tokens. Prefer (A) unless the messages are too numerous to skim.

### C. Resync config flags (cosmetic — do not attempt)

**Don't.** The docs are explicit:

> Claude Code generates [config.json] automatically when you create a team and updates them as teammates join, go idle, or leave. **Don't edit it by hand or pre-author it: your changes are overwritten on the next state update.**

The `isActive: false` values are not the bug — they're just stale turn-end markers. Trying to flip them yourself buys nothing and invites state corruption. Verify liveness by inspecting the iTerm2 pane (`backendType: iterm2` + `tmuxPaneId` in config) directly, not by trusting the flag.

### D. Spawn a replacement lead (nuclear, recommended by docs)

If (A) isn't enough — the auto-delivery watcher stays dead for the whole resumed session:

1. Tell the resumed team-lead to issue a **clean shutdown** of the dead lead session only — do NOT have it call "Clean up the team" (that kills teammates too). Just exit the lead's pane.
2. Start a fresh `claude` session in the same cwd.
3. Per [Issue #26265](https://github.com/anthropics/claude-code/issues/26265): there is **no supported way to attach a fresh lead to existing named teammates**. The teammate-ID format (`name@team`) doesn't map to resumable transcripts.
4. Your options:
   - **Accept context loss:** ask the new lead to re-spawn teammates with the same role prompts. Past work is still in the inbox files + tasks directory — pipe the inbox JSON into the new lead's first prompt as background.
   - **Keep old teammates alive for reference:** the iTerm2 panes keep running. You can manually click into each pane and ask the teammate to dump its state to a file, then feed that to the new lead. Ugly but lossless.

### E. True nuclear (only if filesystem state is corrupted)

```bash
# Back everything up first — do NOT rm -rf
trash ~/.claude/teams/jot-mobile   # moves to Trash, recoverable
trash ~/.claude/tasks/{leadSessionId}
```

Then restart. Only do this if the JSON files are unreadable or obviously malformed — normal staleness doesn't warrant it.

---

## Preventive measures

1. **Trust the filesystem, not messages.** Before concluding "teammate X didn't reply," check `~/.claude/teams/{team}/inboxes/team-lead.json` for messages from that teammate. The inbox is source of truth; the chat is a projection of it.

2. **Always use `teammateMode: tmux` with iTerm2 split panes.** In-process teammates die with the lead. Split-pane (iTerm2 or tmux) teammates are separate processes and survive lead crashes — this is the incident we just recovered from *partially*. Per [Eric Buess](https://x.com/EricBuess/status/2028217923760959976), newer Claude Code versions handle pane cleanup better when you spawn inside tmux.

3. **Checkpoint teammate context to disk proactively.** In teammate spawn prompts, add: *"Every 20 minutes, append a state summary to `tmp/teammate-state/{your-name}.md` with your current focus, files touched, and open questions."* Makes procedure (D) lossless.

4. **Keep `claude --version` current.** Agent teams require ≥2.1.32 and the limitation set shrinks with each release. Check the changelog before assuming a limitation still applies.

5. **Enable `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json`**, not shell env. Shell env gets lost on resume from some terminals; `settings.json` is re-read on every launch.

6. **Don't kill iTerm2 panes out of panic.** The dead-looking `isActive: false` teammate is probably idle but alive. Killing it loses accumulated context permanently. Inspect the pane before terminating.

---

## Open questions (UNKNOWN)

1. **Is there a hidden flag to reattach inbox polling after resume?** Searched: official docs (`/en/agent-teams`, `/en/sub-agents`, `/en/resume` — 404), `CLAUDE_CODE_TEAM_NAME` env var (referenced in one third-party deep-dive but not in official docs), `/team` slash command variants. No documented reattach flag exists as of Claude Code 2.1.x. Could not test at runtime because we were told not to disrupt the live team.

2. **Does `CLAUDE_CODE_TEAM_NAME` actually work?** A third-party source ([markdown.engineering](https://www.markdown.engineering/learn-claude-code/22-teams-swarm)) claims `computeInitialTeamContext` reads this env var on startup to rejoin an existing team. Not documented by Anthropic. Worth testing on a disposable team next time the issue recurs — set `CLAUDE_CODE_TEAM_NAME=jot-mobile` in your shell before running `claude --resume`. If it works, procedure (A)+(B) becomes recoverable without context loss. (Not verified — do not rely on it for production recovery.)

3. **Will leftover unread messages in `team-lead.json` be auto-delivered if the team is cleanly restarted without deletion?** UNKNOWN — would need a controlled experiment. Filesystem state suggests yes, since the watcher reads the file from the top; behavior may depend on version.

4. **Does the iTerm2 backend use a heartbeat?** The `isActive` flag flips on every turn end, but there's no evidence of a liveness probe. A teammate whose process crashes silently would stay `isActive: false` forever and look identical to "idle alive." UNKNOWN how to distinguish without opening the pane.

---

## Sources

- [Anthropic — Orchestrate teams of Claude Code sessions](https://code.claude.com/docs/en/agent-teams) (authoritative; limitations section)
- [GitHub Issue #26265 — Support resume for Agent Team teammates](https://github.com/anthropics/claude-code/issues/26265) (closed as duplicate, confirms no workaround)
- [GitHub Issue #24385 — iTerm2 panes not closed on teammate shutdown](https://github.com/anthropics/claude-code/issues/24385)
- [GitHub Issue #24301 — iTerm2 native split pane falls back to in-process](https://github.com/anthropics/claude-code/issues/24301)
- [markdown.engineering — Teams & Swarms source deep-dive](https://www.markdown.engineering/learn-claude-code/22-teams-swarm) (community reverse-engineering; unverified claims)
- Local evidence: `~/.claude/teams/jot-mobile/` inbox + config inspection on 2026-04-17 post-incident.
