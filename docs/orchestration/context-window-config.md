# Context Window Config for Spawned Agents

## TL;DR

Add `CLAUDE_CODE_SUBAGENT_MODEL` (and optionally `ANTHROPIC_DEFAULT_OPUS_MODEL`) to the global `env` block in `~/.claude/settings.json`, pinned to `claude-opus-4-7[1m]`. Restart Claude Code. Every new subagent spawned via the Agent tool then runs with the 1M context window. Existing teammates need their `model` field in `~/.claude/teams/<team>/config.json` edited to `"claude-opus-4-7[1m]"` since their model was frozen at join time.

## The exact plaintext instruction

### Step 1 — Global default for all future subagents

Edit `~/.claude/settings.json`. Find the `"env"` block (currently contains `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) and add two keys:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-4-7[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7[1m]"
  }
}
```

- `CLAUDE_CODE_SUBAGENT_MODEL` — officially documented env var that sets the model for subagents. This is the direct lever.
- `ANTHROPIC_DEFAULT_OPUS_MODEL` — makes the `opus` alias resolve to the 1M variant everywhere (main session, `/model opus`, Agent tool `model: "opus"` enum). The docs state the `[1m]` suffix is stripped before hitting the provider and "applies the 1M context window to all usage of that alias." Belt-and-suspenders with the first key.

### Step 2 — Fix existing team members in the jot-mobile team

Already-joined teammates froze their `model` at join time. Edit `~/.claude/teams/jot-mobile/config.json` and change **every** member's `"model": "claude-opus-4-7"` to `"claude-opus-4-7[1m]"`. Current lines to patch: 26, 39, 52, 67, 82, 97, 112, 127, 142 (9 teammates — team-lead on line 12 is already correct). A one-shot `sed` is safe here because the string only appears as values:

```bash
# Verify first
grep -n '"claude-opus-4-7"' ~/.claude/teams/jot-mobile/config.json
# Apply
sed -i '' 's/"claude-opus-4-7"/"claude-opus-4-7[1m]"/g' ~/.claude/teams/jot-mobile/config.json
# Re-verify
grep -n 'claude-opus-4-7' ~/.claude/teams/jot-mobile/config.json
```

### Step 3 — Restart Claude Code

Env vars are read at startup. Settings-file env blocks are injected into the process environment once, so Steps 1 and 2 both require a restart of the Claude Code session. Currently-running background teammates do NOT hot-reload — they keep their old context window until the next agent invocation that re-reads the config.

### Step 4 — Verify

After restart, spawn a trivial teammate and ask it to run `echo $CLAUDE_CODE_SUBAGENT_MODEL` — should print `claude-opus-4-7[1m]`. Or have it read `/status` to confirm its active model.

## Why this is the right fix

**Evidence that `[1m]` is valid syntax in config files:**
- Official Claude Code model-config docs list `opus[1m]` and `sonnet[1m]` as first-class aliases, and explicitly state you can append `[1m]` to a full model name: `/model claude-opus-4-7[1m]`. Source: https://code.claude.com/docs/en/model-config (section "Extended context").
- The docs explicitly document `ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7[1m]'` as the pinned-model-with-1M pattern ("Pin models for third-party deployments" section).
- Existing team-lead entry already uses `"claude-opus-4-7[1m]"` successfully, proving the team-config JSON parser accepts it.

**Evidence that `CLAUDE_CODE_SUBAGENT_MODEL` is the right lever:**
- Model-config docs environment-variable table lists it explicitly: `"The model to use for subagents"`. Source: https://code.claude.com/docs/en/model-config (section "Environment variables").

**Why team-config editing is also needed:**
- The team config file snapshots each member's model at join time (`joinedAt` timestamp alongside it). That value is passed to the spawned agent process, NOT re-resolved against current env. Env-var changes help future `TeamCreate` / Agent-tool spawns but do not retroactively promote already-joined teammates.

## What we tried / ruled out

- **Per-agent defaults in `~/.claude/agents/*.md`** — these files (memory-manager.md, Orchestrate.md) do NOT contain a model field. Agent definitions support `model: sonnet|opus|haiku` in frontmatter but that resolves through the same alias → env var pipeline we're setting, not a separate knob. No independent escape hatch here.
- **`subagentModelOverrides` in settings.json** — open feature request (GitHub anthropics/claude-code issue #37823, #33734). NOT yet shipped. Don't depend on it.
- **Agent tool `model` enum `["sonnet","opus","haiku"]`** — no explicit `opus[1m]` value, but once `ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7[1m]` is set, passing `model: "opus"` resolves to the 1M variant. So the enum is effectively fine once the env var is set.
- **`~/.claude/settings.local.json`** — also supports `env` blocks but is per-project (currently scoped here only to the JOT-Transcribe repo). Setting the global in `~/.claude/settings.json` is the correct scope for "across any team, any project."
- **`CLAUDE_CODE_DISABLE_1M_CONTEXT=1`** — opposite direction knob. Don't set it.
- **Hot-reload of already-running teammates** — not supported. Agents are forked processes with frozen config. Restart required.

## Open questions

- **Does `CLAUDE_CODE_SUBAGENT_MODEL` override the per-teammate `model` field in `~/.claude/teams/<team>/config.json`?** Docs don't specify precedence. Safe assumption: team-config is explicit and wins over env default (since the config writes out `"claude-opus-4-7"` at creation time and that's the authoritative value for that teammate). That's why Step 2 is necessary.
- **Does restarting Claude Code kill currently-running background teammates?** Likely yes if they share the parent process; may survive if they're separate `iterm2` panes. Test path: restart, check `TeamList` / `TaskList` for still-alive teammates.
- **Ordering of `ANTHROPIC_MODEL` vs `CLAUDE_CODE_SUBAGENT_MODEL`:** docs list model-setting priority for the main session (session > CLI > env > settings), but subagent precedence isn't explicitly stated. Setting both should be defensive.

## Sources

- Claude Code model config: https://code.claude.com/docs/en/model-config
- Claude Code settings: https://code.claude.com/docs/en/settings
- Subagents: https://platform.claude.com/docs/en/agent-sdk/subagents
- Feature request for per-agent model overrides: https://github.com/anthropics/claude-code/issues/37823
- Feature request for defaultAgentModel setting: https://github.com/anthropics/claude-code/issues/33734
