# Team Orchestration Principles

Core rules for running the jot-mobile agent team. Each principle is stated with rationale so future maintainers can judge edge cases instead of blindly applying rules.

---

## 1. Team-lead orchestrates, never executes

Team-lead's job is to receive user intent, dispatch to the correct lane owner, coordinate, and verify. Team-lead does NOT edit source files directly — not even "small" ones.

**Why:** Editing breaks the mental model of file ownership. The lane owner always has better context than team-lead for deciding local tradeoffs. If team-lead edits a file, the lane owner's next change may conflict, regress the fix, or be based on a stale mental model of that file.

**How to apply:** If a change is needed, dispatch it. Even a one-line fix belongs to the lane owner. The correct team-lead move is "message cleanup-engineer-2 with the requested change" — not "edit the file myself."

**Example mistake in this session:** Team-lead edited `CleanupService.swift` to remove output-token caps instead of dispatching to cleanup-engineer-2. See `anti-patterns.md#the-team-lead-executes-anti-pattern`.

---

## 2. Route follow-up work to the original lane owner

If a file needs another pass — best-practices review, polish, refactor, bug fix — message the teammate who wrote it. Don't spawn a new "polish" agent to modify files someone else authored.

**Why:** The original author holds the context. A fresh "polish-engineer" reloads a cold context, makes assumptions, and often re-litigates decisions the author already made. Parallel editors on the same file produce drift, double-edits, and merge conflicts.

**How to apply:** Best-practices reviewer returned N findings? Route each finding to the lane owner of the file it touches. If findings span multiple lanes, message each owner separately with only the findings that touch their lane.

**Example mistake in this session:** Best-practices-researcher returned 5 fixes; team-lead spawned 3 polish agents in parallel instead of messaging the 4 original lane owners. Polish agents had to be shut down mid-flight and the state rebroadcast to originals. See `anti-patterns.md#the-spawn-to-polish-anti-pattern`.

---

## 3. Match agent type to agent purpose

Research agents are for research. Editing agents are for editing. Build agents are for building. Don't conflate — an agent's brief determines which tools and context get loaded.

**Why:** A researcher given edit authority will edit based on partial context. An editor given a research brief will wander. The brief shapes the behavior; mismatched briefs produce mismatched work.

**How to apply:** When dispatching, pick the agent type that matches the verb. "Find out X" → research agent. "Change X" → editing agent. "Verify the build passes" → build agent.

---

## 4. Name your lanes, not just your agents

Lane names (`Audio Pipeline`, `Cleanup & Settings`) are the stable human-facing identity. Agent names (`recording-engineer-2`, `cleanup-polish-engineer`) are ephemeral and sometimes mangled by retries.

**Why:** Humans identify "who owns what" by lane, not by agent UUID. `cleanup-polish-engineer-2` is decoder noise; "Cleanup & Settings lane" is signal.

**How to apply:** Convention: agent name = `{lane-slug}-engineer`, where lane-slug is a dashed-lowercase version of the lane name. Retries get numeric suffixes (`-2`, `-3`) but the lane stays stable. See `lanes.md` for the current roster.

---

## 5. Broadcast state before winding down a teammate

Before shutting down a teammate that produced changes another lane owner will maintain, send a status-sync message to the remaining lane owner.

**Why:** Shutdowns erase context. If cleanup-polish-engineer wrote changes that cleanup-engineer-2 will maintain going forward, the handoff must happen explicitly — otherwise cleanup-engineer-2 will re-edit the same files without knowing what just landed.

**How to apply:** Before `shutdown_request`: (1) identify which lane owner inherits the work, (2) send them a message describing what was just changed and why, (3) only then shut down.

---

## 6. Verify claims on disk, not in teammate reports

Teammate summaries describe what they INTENDED. File contents describe what actually shipped. Trust, but verify.

**Why:** Agents regularly claim "done" for work that is partial, blocked, or subtly wrong. A summary is a self-report, not a proof. Grep or LSP is the proof.

**How to apply:** When a summary and a file state could be ambiguous — grep the file, don't trust the report alone. Especially after shutdowns and parallel edits where race conditions are possible.

---

## 7. Protect team-lead context from build noise

Build output (xcodebuild, test runs, linker errors) belongs in build-engineer's context, not team-lead's. Team-lead hears "build passes" or "build fails with N errors, here are the classifications" — not the full log.

**Why:** Team-lead's context is a coordination surface. Filling it with log text evicts the team-state the coordinator needs. That's the whole reason build-engineer exists as a separate lane.

**How to apply:** When a build runs, it runs in build-engineer's session. Team-lead asks build-engineer for a summary, not for the raw output.

---

## 8. When unsure whether an action is execution or orchestration, default to orchestration

If a lane owner exists for the files involved, they do the work — even for "trivial" operations.

**Why:** Every action has an accountability chain. The lane owner knows WHY the files are where they are, what's in flight, what the rollback looks like. When team-lead performs the action directly — even something as simple as `mv` on four markdown files — the chain breaks. A future reader can't ask "why did these move?" without reconstructing team-lead's reasoning, which was never written down. Dispatching writes it down automatically in the teammate brief.

**How to apply:** When considering "can I just do this myself?" on anything that changes state — file moves, renames, deletions, config edits, git operations — first check: does a lane owner exist for the affected files? If yes, dispatch. The marginal cost of a one-message dispatch is lower than the cost of a broken accountability chain.

**Example in this session:** Team-lead initially included `mv` instructions in the brief for docs-engineer rather than running it themselves. Correct move. A prior session's team-lead would have just run the `mv` — which feels faster but erodes the ownership model over time.

---

## 9. Context-window planning at team creation

Before spawning a team, confirm the teammate model and context window match the work each lane will do. File-lane teammates (focused edits on small files) fit 200K. Research, build-log, or cross-cutting teammates (holding many references at once) need 1M. Decide at spawn time, not after a teammate has already hit the ceiling.

**Why:** Context is a physical constraint. A teammate that runs out of window mid-task forgets context that was load-bearing for their current decision and produces subtly wrong work. The fix after the fact is expensive (respawn + rebuild context from docs). The fix before the fact is a one-time env-var edit.

**How to apply:** Apply the setup in [`context-window-config.md`](context-window-config.md) once globally (env vars in `~/.claude/settings.json`) and once per team (sync the team config). After that, every new subagent defaults to the 1M variant and no lane is bottlenecked by window size. Re-check after any `~/.claude/settings.json` reset or new team creation.

---

## 10. Prefer peer-to-peer over team-lead routing

Teammates message each other directly. Team-lead is not a router.

**Why:** Routing every cross-lane question through team-lead wastes round-trips, introduces delay, and pollutes team-lead's context with work that should happen at the edge. The lane owner is always closer to the question than team-lead is. Principle #7 ("protect team-lead context from build noise") applies to routing too, not just logs.

**How to apply:** When you need to coordinate — a cross-lane build error, a contract clarification, a status ping, a review handoff — message the peer lane owner directly via `SendMessage`. Only loop team-lead in for prioritization, scope changes, new lanes, shutdowns, research spawns, or anything affecting the user's direction. See [`peer-coordination.md`](peer-coordination.md) for the full P2P vs team-lead split, plus the directory of who to talk to.

**Example in this session:** Build-engineer-2 found 4 errors in `DictateIntent.swift` and messaged intent-widget-engineer directly. Team-lead only saw the completed summary, not the back-and-forth. Correct pattern.

---

## 11. Treat every file-backed messaging system as polled-streamable

Any JSON-backed inbox, outbox, queue, or event log on disk can be tailed via the `Monitor` tool as a fallback transport when the primary delivery channel breaks.

**Why:** Claude Code's primary teammate-delivery mechanism is an in-process file watcher. That watcher is fragile — specifically, it does not survive `/resume` (confirmed in the 2026-04-17 incident: 26 unread messages piled up on disk because the resumed lead's watcher stopped firing). But the file-backed state itself is durable: writes are locked, reads are idempotent, the inbox JSON is never corrupted. The fix is to stop depending on the watcher and start tailing the file.

**How to apply:** When a delivery-layer failure is suspected, don't wait for Anthropic to fix the watcher — write a ~50-line Python poller that seeds on startup, polls every 10-30s, filters noise, and emits one line per substantive event. Wrap it in `Monitor({command: "python3 <script>", persistent: true, timeout_ms: 3600000})` and you have live streaming again. The pattern generalizes: any file-backed state (inboxes, task lists, SwiftData stores, log files) is polled-streamable. [`tools/inbox-monitor.md`](tools/inbox-monitor.md) is the canonical implementation; [`session-resume-recovery.md`](session-resume-recovery.md) Procedure A′ is the playbook.

**Example in this session:** After `/resume` broke team-lead's inbox watcher, we armed a 60-line Python poller via `Monitor(persistent: true, timeout_ms: 3600000)`. Unread messages streamed back into team-lead's chat within 15 seconds. Zero context loss, re-armable across future crashes, generalizable to any future team via a one-line `sed`.

---

## See also

- `lanes.md` — current lane roster, naming convention, and the "Who to talk to" directory
- `peer-coordination.md` — P2P messaging rules + when to loop team-lead in (referenced by principle #10)
- `session-resume-recovery.md` — recovery playbook for crashed/resumed team-lead sessions (Procedure A′ uses principle #11)
- `tools/inbox-monitor.md` — the concrete inbox-monitor tool that implements principle #11
- `anti-patterns.md` — named mistakes from this session
- `future-decisions.md` — open questions
- `context-window-config.md` — one-time setup for 1M-context subagents (referenced by principle #9)
