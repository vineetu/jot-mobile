# Anti-Patterns — named mistakes from this team

Each entry: **what happened / why it went wrong / how to avoid next time.** Use the short section titles as reference handles when debriefing future sessions.

---

## The team-lead-executes anti-pattern

**What happened:** Team-lead edited `CleanupService.swift` directly to remove output-token caps, instead of dispatching the change to cleanup-engineer-2 (the lane owner).

**Why it went wrong:** The lane owner holds the local context — why a cap existed, what other call sites depended on it, what the planned follow-up was. Team-lead editing ignored that context and broke the ownership model. On the next pass, cleanup-engineer-2 had to reconcile "who changed this and why" before making their own edit.

**How to avoid next time:** Team-lead dispatches. If the change is truly trivial, it's STILL the lane owner's job — the cost of a one-message dispatch is much lower than the cost of a confused ownership boundary. See `principles.md#1-team-lead-orchestrates-never-executes`.

---

## The spawn-to-polish anti-pattern

**What happened:** Best-practices-researcher returned 5 findings against files owned by 4 different lanes. Instead of routing each finding to its lane owner, team-lead spawned 3 parallel "polish-engineer" agents to apply the fixes.

**Why it went wrong:** (a) The polish agents loaded cold contexts and began editing files whose authors were still active. (b) The original owners had context the polish agents didn't, including pending follow-ups. (c) The polish agents collided with the originals when the human critiqued "please route fixes through original authors" — which required shutting down the polish agents and rebroadcasting the state. Net effect: duplicate work, merge risk, and wasted context.

**How to avoid next time:** When a reviewer returns findings, route each finding to the lane owner of the file it touches. If findings span multiple lanes, send separate messages to each owner with only their lane's findings. No new agents for polish work — the author IS the polisher. See `principles.md#2-route-follow-up-work-to-the-original-lane-owner`.

---

## The rescind-shutdown anti-pattern

**What happened:** Team-lead sent `shutdown_request` to a teammate mid-work, then tried to rescind it when the human pushed back. The teammate had already begun winding down.

**Why it went wrong:** `shutdown_request` is not a "pause" or "stop what you're doing" signal — it's a "your session is complete, please terminate" signal. Using it as a reactive interrupt confuses teammates, wastes any in-flight work, and requires a rescind dance that often fails because the teammate already flushed state.

**How to avoid next time:** Shutdowns are for teammates who have sent a final status and are genuinely done. Never as a reflex to "stop that." If you need a teammate to change direction mid-task, send a new plain message describing the new direction — don't shut them down.

---

## The double-write anti-pattern

**What happened:** Team-lead dispatched the same work to two teammates in parallel — polish agents AND original lane owners (after the human's "please use original authors" critique). Both sets began editing the same files. Only resolved because one completed before the other's stand-down arrived.

**Why it went wrong:** Parallel edits on the same file are a race condition. The winner is arbitrary, the loser's work is discarded (or worse, silently merged into a broken state). Even when it "works," it's burning agent time on work that will be overwritten.

**How to avoid next time:** Before dispatching, check: is anyone else already writing to these files? If yes, either coordinate a sequence or cancel one of the dispatches BEFORE the second starts. The expensive invariant is "one writer per lane at any moment."

---

## The false-positive playbook-finding anti-pattern

**What happened:** Best-practices-researcher flagged a `MainActor.assumeIsolated` land-mine in a tap block that didn't actually exist in the code. Recording-polish-engineer grepped and confirmed the code was clean. The finding was a hallucination against pattern memory, not evidence.

**Why it went wrong:** Researchers sometimes report what the playbook predicts should be there, not what's actually there. If the fix is dispatched without verification, you get changes to code that didn't have the bug in the first place — which can INTRODUCE bugs.

**How to avoid next time:** Treat playbook findings as hypotheses until verified against the actual source. Before dispatching a fix, the lane owner (or team-lead, before dispatching) greps for the offending pattern. No match → reject the finding as a false positive and move on. See `principles.md#6-verify-claims-on-disk-not-in-teammate-reports`.

---

## The wrong-cwd anti-pattern

**What happened:** Docs-engineer was spawned to create `docs/orchestration/` and wrote the four files into `/Users/tejasdc/workspace/JOT-Transcribe/docs/orchestration/` — the Mac-app repo, not the `jot-mobile/` iOS-experiment repo the team was actually working on. Team-lead had to follow up with a `mv` instruction to relocate them.

**Why it went wrong:** Teammates inherit team-lead's cwd on spawn. If team-lead's cwd is pointed at a sibling repo (here: `/Users/tejasdc/workspace/JOT-Transcribe` instead of `/Users/tejasdc/workspace/jot-mobile`), relative paths in the teammate's brief — "create `docs/orchestration/`" — resolve in the wrong repo. The teammate has no independent way to know they're in the wrong place unless the brief spells it out absolutely.

**How to avoid next time:**
1. **Team-lead:** always use **absolute paths** in teammate briefs when the target directory is known. Not "create `docs/X`" — "create `/Users/tejasdc/workspace/jot-mobile/docs/X`."
2. **Teammate:** before writing any file, confirm cwd with `pwd` (or `ls -la` the target) and sanity-check against the brief. If the repo name doesn't match what the brief describes, stop and ask.
3. **Lane brief template** going forward should include an explicit line: "Your working repo is `<absolute-path>`. Confirm this with `pwd` before writing any file."

---

## Quick-reference table

| Anti-pattern | Symptom | Fix |
|---|---|---|
| team-lead-executes | Team-lead edits source files | Dispatch to lane owner |
| spawn-to-polish | New "polish" agent modifies someone else's file | Route to original author |
| rescind-shutdown | `shutdown_request` used as interrupt | Use plain message to redirect |
| double-write | Two teammates editing same files | Enforce one writer per lane |
| false-positive playbook-finding | Fix dispatched against non-existent bug | Grep-verify before dispatching |
| wrong-cwd | Teammate writes to the wrong repo because cwd was inherited silently | Absolute paths in briefs; teammate confirms cwd before first write |
