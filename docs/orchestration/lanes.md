# Lane Roster — jot-mobile team

A **lane** is a stable ownership zone: a named set of files that one teammate owns end-to-end. Humans identify "who owns what" by lane, not by agent name. Agent names are ephemeral — they get `-2`, `-3` suffixes across retries — but the lane stays stable.

## Who to talk to

**Read this first** when you need to coordinate. Default to messaging these teammates directly via `SendMessage` — don't route through team-lead. See [`peer-coordination.md`](peer-coordination.md) for when to use P2P vs when to loop team-lead in.

| Lane | Teammate | Message them when… |
|---|---|---|
| **Audio Pipeline** | `recording-engineer-2` | You hit a recording-capture, VAD, audio-format, or transcription-wiring question |
| **Cleanup & Settings** | `cleanup-engineer-2` | You need a post-transcription cleanup change, a settings UI update, or anything touching `CleanupSettings` / `AppGroup` / `ClipboardHandoff` |
| **Keyboard Extension** | `keyboard-engineer` | A dictation trigger, transcript insertion, or anything in `Jot/Keyboard/` needs attention |
| **App Shell** | `ui-scaffolder` | Entry point, top-level views, or resource/Info.plist changes |
| **Intents & Live Activity** | `intent-widget-engineer` | App Intent handler change, widget update, or Live Activity attribute edit |
| **Build & Test** | `build-engineer` | You hit a compiler error, XcodeGen spec question, or want a rebuild/test run |
| **Documentation** | `docs-engineer` | A new principle, anti-pattern, lane change, or learning to capture |

If the teammate has been re-spawned (`-2`, `-3` suffix), the suffix here reflects the **current** active instance — use the name as written. If `lanes.md` lags reality (e.g., after a session crash), check `~/.claude/teams/jot-mobile/config.json` — see `peer-coordination.md` for the caveats.

---

## Preconditions for any new team

Before spawning a new team (with `TeamCreate` or otherwise), ensure `~/.claude/settings.json` has `CLAUDE_CODE_SUBAGENT_MODEL: "claude-opus-4-7[1m]"` (and ideally `ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-4-7[1m]"`) in its `env` block, and restart Claude Code afterward. This gives every spawned teammate the 1M context window by default — a cheap one-time setup that avoids surprise context-ceiling hits later. See [`context-window-config.md`](context-window-config.md) for the full step-by-step, including how to retrofit existing teams whose member models froze at join time. Linked from principle #9.

---

## Naming convention

- **Lane name:** Title Case, human-readable (`Audio Pipeline`, `Cleanup & Settings`)
- **Lane slug:** dashed-lowercase (`audio-pipeline`, `cleanup-settings`)
- **Agent name:** `{lane-slug}-engineer`, optionally suffixed with `-2`, `-3` on retries
- Avoid ad-hoc suffixes like `-polish` on long-lived agents — if you find yourself spawning `{lane-slug}-polish-engineer`, you're violating principle #2 (route follow-up work to the original owner). See `principles.md`.

## Current lanes

| Lane | Description | Files owned | Current teammate |
|---|---|---|---|
| **Audio Pipeline** | Recording capture, VAD, transcription wiring, audio format conversion | `Jot/App/Recording/`, `Jot/App/Transcription/` | `recording-engineer-2` |
| **Cleanup & Settings** | Post-transcription cleanup service, settings UI, app-group + handoff plumbing | `Jot/App/Cleanup/`, `Jot/App/Settings/`, `Jot/Shared/CleanupSettings.swift`, `Jot/Shared/AppGroup.swift`, `Jot/Shared/ClipboardHandoff.swift` | `cleanup-engineer-2` |
| **Keyboard Extension** | Custom keyboard target — dictation trigger, transcript insertion | `Jot/Keyboard/` | `keyboard-engineer` |
| **App Shell** | Entry point, top-level views, resources, Info.plist | `Jot/App/JotApp.swift`, `Jot/App/ContentView.swift`, `Jot/Resources/` | `ui-scaffolder` |
| **Intents & Live Activity** | App Intents, widget extension, Live Activity attributes | `Jot/App/Intents/`, `Jot/Widget/`, `Jot/Shared/DictationAttributes.swift` | `intent-widget-engineer` |
| **Build & Test** | XcodeGen spec, build scripts, testing docs | `Jot/project.yml`, `build.sh`, `TESTING.md`, `scripts/` | `build-engineer` |
| **Documentation** | This directory — orchestration docs, process, conventions | `docs/orchestration/` | `docs-engineer` (me) |

## Lane hygiene

- **One lane, one owner.** If two teammates are writing to the same lane, something is wrong — see `anti-patterns.md#the-double-write-anti-pattern`.
- **Cross-lane changes go through both owners.** If a change spans Audio Pipeline + Cleanup & Settings, team-lead coordinates the sequence: one owner changes their side, then the other owner reacts to the new interface.
- **Shared types belong to the lane that owns the source of truth.** E.g., a SwiftData model used by Cleanup is owned by the lane that persists it, and imported by other consumers.
- **Lane splits should be explicit.** If a lane grows too large (e.g., Cleanup & Settings eventually needs a dedicated Settings lane), team-lead proposes the split, docs-engineer updates this table, and ownership is reassigned cleanly — not fought over.

## Out-of-scope for lane owners

Individual lane owners do NOT own:
- **Product docs** (README, EXPERIMENTS, TESTING, best-practices.md) — those belong to their respective lane owners (typically Build & Test or the lane whose behavior they describe).
- **Orchestration docs** (this directory) — owned by `docs-engineer`.
- **Cross-lane architecture decisions** — team-lead coordinates; the decision is captured here in `future-decisions.md` or `principles.md`.
