# Peer-to-Peer Coordination

Teammates can — and should — message each other directly. Team-lead is not a router. This file is how to tell when to use P2P vs when to loop team-lead in.

Quick pointer to your audience: the **"Who to talk to"** table in [`lanes.md`](lanes.md) is the canonical directory of who owns what.

---

## Why P2P

Routing every cross-lane question through team-lead is:
- **Wasteful.** Each round-trip costs a message you could have sent directly.
- **Slow.** Team-lead has to read, understand the lane split, and forward.
- **Destructive of team-lead context.** Every routing task evicts coordination state from team-lead's window. That's the whole reason `principles.md` §7 ("protect team-lead context from build noise") exists — applied to routing, not just logs.

When build-engineer finds a Swift error in `DictateIntent.swift`, they message intent-widget-engineer **directly**. Team-lead doesn't need to be in that loop — they'll see the outcome in the next status sync.

---

## How to discover teammates

1. **Primary: `lanes.md`** — the canonical map of lane → files → owner. Start here. If you need to know "who owns `Jot/Widget/`?", `lanes.md` has the answer.
2. **Fallback: `~/.claude/teams/jot-mobile/config.json`** — the live roster as the runtime sees it. Useful if you suspect `lanes.md` is out of date. Caveat: the `isActive` flag can be stale after crashes or session resumes — a teammate marked active may actually be gone. Treat it as "probably there" not "definitely there."

If both are ambiguous, broadcast to `*` asking "who owns X?" — but only when the lane file genuinely can't answer. Broadcasts are expensive.

---

## How to send P2P messages

Use the `SendMessage` tool. Refer to teammates by name, never by UUID.

```json
{"to": "keyboard-engineer", "summary": "5-10 word preview", "message": "..."}
```

- **Specific teammate:** `to: "name"`
- **Broadcast:** `to: "*"` — sparingly, only for team-wide announcements. Never to find a single owner.

Your plain text output is NOT visible to other agents. If you want another teammate to see something, you MUST call `SendMessage`. Typing "hey keyboard-engineer, …" in your text output does nothing.

---

## What requires team-lead vs P2P

### Default to P2P

- Cross-lane **build errors** (compiler complaints in a file your lane consumes)
- **Contract clarification** between two services (return types, call timing, error modes)
- **"Is your work done yet?"** status pings
- **Reviewing each other's output** before handoff
- **Coordinating a stub, a shim, or a temporary interface** during parallel work
- **Follow-up fixes** on code you authored that someone else found an issue in — the finder messages you directly (principle #2 applies even when the finder isn't team-lead)

### Loop team-lead in

- **Prioritization decisions** — "should I do A or B first?"
- **Scope changes** — a lane's owned files expanding, shrinking, or splitting
- **Bringing in a NEW lane** that doesn't yet exist
- **Shutting down a teammate** (never initiate shutdown from P2P)
- **Spawning research agents or other new subagents**
- **Anything that changes the user's direction** or promises
- **Disagreements** that can't be resolved P2P — escalate rather than deadlock

---

## Example from this session

Build-engineer-2 found 4 Swift 6 concurrency + access errors in `DictateIntent.swift`. Rather than sending the errors to team-lead for routing:

1. Build-engineer-2 messaged **intent-widget-engineer directly** with the error list and file paths.
2. Intent-widget-engineer applied fixes and replied back to build-engineer-2.
3. Build-engineer-2 re-ran the build, confirmed pass, and marked their task complete.
4. Team-lead saw the summary after the fact, in a single status update — not as four back-and-forth routing messages.

That's the correct pattern. Task #20 ("Fix Swift 6 concurrency + access errors in DictateIntent.swift") was resolved entirely through P2P with team-lead as a silent observer.

---

## See also

- [`lanes.md`](lanes.md) — "Who to talk to" table + full lane roster
- [`principles.md`](principles.md) — §10 "Prefer peer-to-peer over team-lead routing" + §2 "Route follow-up work to the original lane owner" + §7 "Protect team-lead context from build noise"
- [`anti-patterns.md`](anti-patterns.md) — `the spawn-to-polish anti-pattern` (what happens when the finder DOESN'T message the author directly)
