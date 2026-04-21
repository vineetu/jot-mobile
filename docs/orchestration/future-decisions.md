# Future Decisions — open questions

A running queue of orchestration questions that came up but don't have an answer yet. Entries here are candidates for later consolidation into `principles.md` or `lanes.md` once a decision is made.

Each entry: **question / context / candidate answers / who decides / status.**

---

## 1. Where do these orchestration docs ultimately live?

**Context:** Right now they're at `docs/orchestration/` inside the product repo. That co-locates process with code but mixes team-meta with product docs.

**Candidate answers:**
- **(a) Stay in `docs/orchestration/`.** Co-located, versioned with the code the team works on. Easy to find.
- **(b) Promote to `AGENTS.md` at repo root.** Claude Code / Codex convention for per-repo agent instructions. Loaded automatically.
- **(c) Move to global `~/.claude/rules/`.** Cross-project reuse — the principles apply to any agent team, not just jot-mobile.
- **(d) A `CLAUDE.md` variant.** Per-project, loaded into Claude's context automatically.

**Who decides:** Human (Tejas).

**Status:** Pending. Default to (a) until decided; docs-engineer will migrate on instruction.

---

## 2. Should lane names be enforced or remain convention-only?

**Context:** Currently lane naming is convention-based — `{lane-slug}-engineer`. There's no machine check that a spawned agent matches a declared lane.

**Candidate answers:**
- **Enforce via team config.** Teams declare `lanes:` in a spec; team-lead can only dispatch to declared lanes; new lanes require an explicit config change.
- **Convention-only.** Rely on `lanes.md` as the source of truth, reviewed by humans, enforced socially.

**Tradeoff:** Enforcement prevents ad-hoc sprawl (`cleanup-polish-engineer-2`) but adds friction when a genuinely new lane is needed mid-session.

**Who decides:** Team-lead + human, after more sessions of data.

**Status:** Pending. Convention-only for now.

---

## 3. How is a lane owner's context restored after session end?

**Context:** When a Claude session ends (restart, crash, explicit termination), the agent's conversation state is gone. A new session has to rebuild context.

**Candidate answers:**
- **(a) Rely on the docs we're writing.** New session reads `docs/orchestration/*`, the lane's owned files, recent git log, and recent PRs. This is what humans do when onboarding.
- **(b) Persist conversation state.** Some form of snapshot — transcript, TaskList state, memory entries — restored on new session.
- **(c) Hybrid.** Durable docs for principles/lanes/anti-patterns; ephemeral state (current task, in-flight decisions) in TaskList or memory.

**Tradeoff:** (b) is higher fidelity but adds moving parts and may preserve stale context. (a) is cleaner but loses fine-grained task state.

**Who decides:** Human + team-lead, after observing how badly context loss actually hurts.

**Status:** Pending. Currently de facto (a).

---

## 4. How are cross-lane changes coordinated?

**Context:** A change that spans Audio Pipeline + Cleanup & Settings (e.g., a new transcription field that needs both capture and post-processing) needs ordering.

**Candidate answers:**
- Team-lead sequences: owner A changes their side, announces the new interface, then owner B reacts.
- Team-lead opens a "cross-lane" ticket with both owners CC'd; both agree on the interface before anyone writes code.
- Worktrees: each owner works in an isolated worktree, merged by team-lead after both are done.

**Who decides:** Team-lead, with debrief notes to docs-engineer after the first few real instances.

**Status:** Pending empirical data.

---

## 5. When is it OK for team-lead to execute vs. dispatch?

**Context:** Principle #1 says team-lead never executes. Edge cases: what about `git` operations, running a script, reading files for coordination? Those aren't "editing source" but they ARE execution.

**Proposed carve-outs (not yet ratified):**
- Reading files for coordination = OK (not execution in the "changes shipped" sense)
- Running read-only tooling (grep, build status check) = OK
- Git operations on branches team-lead owns (merges, tags) = OK if the team-lead lane explicitly owns release
- Writing source files = NEVER (principle #1 holds)
- Writing docs = only `docs/orchestration/` (and even that is owned by docs-engineer — team-lead should dispatch)

**Who decides:** Human, after more sessions. For now, err conservative: dispatch anything with side effects on shared state.

**Status:** Pending.

---

## 6. How do we ensure the full 1M context window for teammates that need it? ✅ RESOLVED

**Status:** **RESOLVED** — see [`context-window-config.md`](context-window-config.md) for the full setup.

**Conclusion:** Both env-var layer and team-config layer are needed.
1. Set `CLAUDE_CODE_SUBAGENT_MODEL` and `ANTHROPIC_DEFAULT_OPUS_MODEL` to `"claude-opus-4-7[1m]"` in the `env` block of `~/.claude/settings.json` — this makes all future subagent spawns default to 1M.
2. For already-joined teammates (whose `model` froze at join time), edit every `"model": "claude-opus-4-7"` → `"claude-opus-4-7[1m]"` in `~/.claude/teams/<team>/config.json`.
3. Restart Claude Code — env blocks are read once at startup and agent configs don't hot-reload.

**Why not (b) "accept 200K":** The setup cost is small and one-time, so there's no reason to limit any lane. Apply globally and let any teammate tap the full window when they need it.

**Open sub-questions** (kept in `context-window-config.md` "Open questions" section): precedence between `CLAUDE_CODE_SUBAGENT_MODEL` and per-teammate `model` field; whether restart kills running background teammates. Not blocking.

---

## 6 (original candidate answers, kept for history)

**Context:** Team-lead runs on `claude-opus-4-7[1m]` (1M context). When the `Agent` tool spawns teammates, the `[1m]` suffix is dropped — teammates default to `claude-opus-4-7` (200K). The Agent tool's `model` enum (`sonnet` / `opus` / `haiku`) doesn't expose the 1M variant explicitly, and model inheritance from team-lead does not propagate the variant.

This matters for lanes that legitimately hold a lot of context: build-engineer sifting through full xcodebuild logs, a research teammate synthesizing many docs, or a debugging session crawling a large call graph. It matters less for single-lane file owners whose working set is naturally small.

Original candidate answers considered:
- **(a) Edit `~/.claude/teams/{team}/config.json`** — partial fix on its own (only covers existing teammates). Adopted as step 2 of the full solution.
- **(b) Accept 200K for file-lane teammates.** Rejected — setup is cheap, may as well apply globally.
- **(c) Wait for the Agent tool to expose the variant explicitly.** Deferred — the env-var approach works today.

---

## Template for new entries

```markdown
## N. <question>

**Context:** <why this came up>

**Candidate answers:**
- ...

**Who decides:** <human / team-lead / docs-engineer>

**Status:** <pending / decided — see link>
```

When a decision is made, move the entry's conclusion into `principles.md` or `lanes.md` and leave a one-line stub here pointing to it.
