# Inbox Monitor — tool reference

Live-stream new unread messages from a file-backed team inbox into a resumed team-lead session. Bypasses the in-process auto-delivery watcher, which `/resume` leaves in a broken state.

Used in [`session-resume-recovery.md`](../session-resume-recovery.md) Procedure A′ as the primary recovery path. Generalized by [`principles.md`](../principles.md) §11 ("treat every file-backed messaging system as polled-streamable").

---

## Where the script lives

```
~/.claude/temp/scripts/jot-inbox-poll.py
```

Standalone Python 3, no deps beyond stdlib. ~60 lines. Reads `~/.claude/teams/jot-mobile/inboxes/team-lead.json` on a 15-second poll and emits new non-noise items to stdout.

## When to arm it

- **Always, after a fresh session start** in a team. One-time arm per session.
- **Always, after `/resume`.** The prior session's Monitor died with the session; re-arm.
- **After a Monitor timeout.** `timeout_ms: 3600000` (1 hour) is the max; re-arm every hour of active coordination.

If you forget to arm it, incoming replies still land in the inbox file — they're just not delivered to team-lead's chat. Arming later will only stream items that arrive AFTER the arm moment (seed-on-startup behavior). To recover messages from the gap, run Procedure A (one-shot harvest) once to catch up, then arm A′ for live streaming.

## How events appear

The Monitor tool surfaces each `print(flush=True)` line as:
- A `Monitor event` chunk in team-lead's chat context (what the agent sees).
- A `task-notification` in the user's Claude Code CLI (what the human sees).

Format: `[sender] summary :: text` — one line per message. Text truncated at 500 chars with a `...[+N chars]` tail when longer.

Example emitted line:

```
[cleanup-engineer-2] cleanup settings persisted :: Wired UserDefaults to AppGroup.defaults; unit tests pass. Ready for next task.
```

## Exact invocation

```text
Monitor({
  description: "new unread messages in jot-mobile team-lead inbox",
  command: "python3 /Users/tejasdc/.claude/temp/scripts/jot-inbox-poll.py",
  persistent: true,
  timeout_ms: 3600000
})
```

`persistent: true` keeps the process alive; `timeout_ms` caps at one hour per the Monitor tool's limit.

## Filter logic

The script filters these out as noise:
- `m['text']` that is a `dict` (structured payloads — usually `idle_notification` heartbeats).
- Strings containing `idle_notification`.
- Strings starting with `{"type":"shutdown_` or `{"type":"idle`.

Everything else is emitted verbatim. The filter is best-effort — future message shapes may slip through or get dropped. If a new payload type is spammy, add it to `is_noise()` in the script.

## Known limitations

- **`seen` is process-local.** On monitor restart, `seen` re-seeds from the current on-disk state, so any messages that arrived while the monitor was DOWN will be treated as "already seen" — NOT re-emitted. For gap recovery, run Procedure A once before arming A′.
- **15-second poll interval.** Messages have up to a 15s delivery lag. Acceptable for coordination; too slow for synchronous request/response.
- **Filter is best-effort.** New structured-payload shapes won't match current `is_noise()` checks until the script is updated.
- **Script path is absolute.** Hardcoded in the `Monitor` call. Changing the script location means updating both the file and every armed Monitor snippet.
- **One team per script instance.** The `INBOX` constant points at a single team. For multi-team work, clone the script per team (see [`session-resume-recovery.md`](../session-resume-recovery.md) Procedure A′ for the `sed` command).
- **No back-pressure.** If the monitor emits faster than team-lead can consume, the Monitor tool queues; excessive queueing can throttle. Not seen in practice because substantive team messages are low-frequency.

## Cloning for a new team

```bash
cp ~/.claude/temp/scripts/jot-inbox-poll.py ~/.claude/temp/scripts/{newteam}-inbox-poll.py
sed -i '' 's|teams/jot-mobile/|teams/{newteam}/|' ~/.claude/temp/scripts/{newteam}-inbox-poll.py
```

Then arm with the new script path in the `command:` field of `Monitor(...)`.

## Related

- [`../session-resume-recovery.md`](../session-resume-recovery.md) — recovery playbook; this tool is Procedure A′
- [`../principles.md`](../principles.md) §11 — the generalization (file-backed = polled-streamable)
- Underlying tool: Claude Code's `Monitor` tool — streaming counterpart to `Bash + run_in_background`
