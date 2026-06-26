# AGENTS.md

## Scope

This file governs work under `Jot/`. The repository root is mostly historical wrapper material; the app, project file, feature inventory, targets, and source code live in this directory.

Prefer reading and editing files under `Jot/`. Only touch root-level files when the command or script explicitly lives there, such as `../build.sh`, `../README.md`, `../docs/`, or `../scripts/`.

## Confidence And Evidence Protocol

- Do not claim a type, field, relationship, target, entitlement, shortcut, or behavior from memory. Inspect the relevant source and cite file paths plus line numbers in user-facing analysis.
- Label conclusions explicitly as `Confirmed`, `Likely`, `Possible`, or `Unknown`.
- State what was not checked when confidence is incomplete.
- Do not implement or rewrite documentation unless confidence is at least 95%. If confidence is lower, ask focused follow-up questions first.
- If implementation confidence is high but product intent is ambiguous, pause and ask. This app has several deliberate product caveats and edge-case behaviors.

## Product Source Of Truth

- Read `features.md` first for any feature work. It is the user-facing product inventory and should stay free of implementation details.
- Before changing behavior, identify the nearest matching feature section in `features.md`, then scan one-hop related sections for downstream impact.
- After a user-facing behavior change, update `features.md` in the same product-facing style. Do not turn it into a design spec or code map.
- Preserve deliberate caveats and discrepancy notes in `features.md` unless the product behavior has actually changed and the user agrees.
- If `features.md`, older docs, and current code disagree, surface the conflict. Treat current code plus the requested product direction as the evidence to reconcile, not as permission to silently erase history.

## Project Shape

- `project.yml` is the XcodeGen source of truth for targets, package dependencies, bundle IDs, build settings, and schemes.
- The primary app target is `Jot`. It includes `App/`, `Shared/`, and `Resources/`, and links the speech, LLM, and app-framework dependencies needed by the full app.
- The keyboard extension target is `JotKeyboard`. It includes `Keyboard/`, shared files, and selected design files. Keep it light: do not add MLX, Apple Foundation Models, heavy model loading, network sync, or long-running disk work to the keyboard target.
- `Tests/` is currently narrow. Add focused tests when touching shared command parsing, transcript persistence behavior, or other logic that can be exercised without device-only frameworks.

## Build, Run, And Test

- Regenerate the Xcode project from the repository root with `./build.sh`.
- Regenerate directly from this directory with `xcodegen`.
- Open the project with `open Jot.xcodeproj` from this directory, or `open Jot/Jot.xcodeproj` from the repository root.
- Prefer a real device for end-to-end validation involving microphone capture, keyboard extension behavior, Action Button or Shortcuts entry points, and on-device model paths.
- Before simulator test commands, verify available runtimes with `xcrun simctl list devices`. iOS 26 simulator names and availability may differ by machine.
- Do not run TestFlight archive, export, or upload flows unless the user explicitly asks. If they do, reconcile `project.yml`, current credentials, and root-level deployment docs/scripts before proceeding.

## Implementation Workflow

- Small edits, exploration, and narrow documentation updates can be done directly.
- For larger feature work, start with a short design discussion. Use the `brainstorm`, `design-review`, `debug`, and `implement-with-subagents` workflows when they fit the task rather than jumping straight into patches.
- When delegating implementation or review through the CLI, use focused prompts such as `codex exec --full-auto "<specific task, paths, expected behavior>" 2>/dev/null`. Keep prompts small and path-specific.
- Do not dump all of `features.md`, broad conversation history, or unrelated docs into delegated prompts. Point agents to exact files and the feature sections they need.
- When using subagents for implementation, split ownership by file or module and use a separate reviewer/supervisor for validation.
- Never revert user changes in the working tree unless the user explicitly asks. This repository may already be dirty.
- Do not mention Codex in commit messages.

## Core Runtime Model

- `App/JotApp.swift` wires the main app, shared services, setup wizard presentation, foreground heartbeat, and `jot://` URL routing.
- `App/Recording/RecordingService.swift` owns the process-wide audio capture lifecycle. Preserve its singleton assumptions and AVAudioSession safety invariants.
- `App/Transcription/TranscriptionService.swift` owns full-file FluidAudio transcription. `App/Transcription/StreamingTranscriptionService.swift` owns live partial transcription.
- `App/Intents/DictationPipeline.swift` is the shared post-recording tail for dictation entry points. Do not fork end-of-recording behavior in separate UI or shortcut paths.
- `App/Intents/TranscribeAudioFileIntent.swift` is a separate Shortcuts file-transcription path and is intentionally outside the shared dictation pipeline.
- `Shared/Transcript.swift` is the SwiftData model. Chained follow-up uses soft UUID fields, not SwiftData relationships.
- `Shared/TranscriptStore.swift` owns SwiftData container access and refreshes the keyboard history mirror after appends.
- `Shared/AppGroup.swift`, `Shared/AppGroup+Rewrite.swift`, and `Shared/PipelinePhaseProjection.swift` are the cross-process coordination layer. App Group defaults hold state; Darwin notifications wake processes; persisted pipeline projection is the source of truth after wakeup.
- `Shared/TranscriptHistoryMirror+SwiftData.swift` exists so the main app can mirror recent transcript history. The keyboard may compile shared types, but it must not open a SwiftData `ModelContainer` or `ModelContext` at runtime.

## Feature Surface Map

- Home and library: `App/ContentView.swift`.
- Recording surface: `App/Recording/RecordingHeroView.swift` plus `App/Recording/RecordingService.swift`.
- Transcript detail and rewrite entry: `App/TranscriptDetailView.swift`.
- Setup wizard: `App/SetupWizard/`. It is a 12-step wizard. Any recording started inside the wizard must be force-stopped before the wizard dismisses.
- Keyboard shell and imperative bridge: `Keyboard/JotKeyboardViewController.swift`.
- Keyboard SwiftUI surface: `Keyboard/KeyboardView.swift` and related keyboard strip/components.
- Shortcuts and Action Button entry points: `App/Intents/` and `App/Intents/JotAppShortcuts.swift`.
- Cleanup and chained follow-up: `App/Cleanup/CleanupService.swift`, `App/Intents/DictationPipeline.swift`, and `Shared/ChainedFollowUp.swift`.
- AI rewrite: `App/LLM/`, `Shared/LLM/`, `Shared/SavedPromptStore.swift`, rewrite settings, rewrite picker, and transcript detail rewrite UI. The only active local rewrite provider is Phi-4 unless current code proves otherwise.
- Vocabulary Boost: `App/Vocabulary/` and settings surfaces. It is a main-app feature; do not make the keyboard read or write the vocabulary store unless explicitly redesigned.
- Shared visual system: `App/Design/JotDesign.swift` and design helpers reused by the app and selected keyboard files.

## Cross-Process And Keyboard Invariants

- Preserve `RECORDING START FROM:` logs unless the user explicitly asks to remove or rename them.
- The keyboard is dictation-only. Do not add a QWERTY keyboard path as a convenience fallback.
- Full Access gates paste/history behavior. When unavailable, use the existing open-settings and blank-state paths rather than silently inventing a workaround.
- Keyboard auto-paste depends on session IDs, freshness windows, pending paste state, and terminal cleanup. Do not reorder publish, consume, or cleanup steps without tracing the whole handoff.
- Do not read `UIPasteboard` on arbitrary key taps. Keep pasteboard reads scoped to the existing handoff flow.
- Warm-hold resume is cross-process behavior. Check `RecordingService`, App Group warm-hold state, keyboard start/stop handling, and foreground heartbeat together before changing it.
- Pipeline phase projection should recover from stale non-idle states. If a UI appears stuck, inspect projection freshness before adding new state flags.
- Darwin notifications are wakeups, not durable state. Always check the App Group projection/payload after receiving one.

## UI And Product Tone

- The app uses an editorial, glassy SwiftUI visual language. Prefer existing tokens and components before creating new styling.
- The keyboard is deliberately quieter and more system-like than the main app. Keep it compact, responsive, and memory-conscious.
- Preserve accessibility labels, VoiceOver behavior, dynamic type considerations, haptics, and reduced-motion checks when touching user-facing flows.
- Avoid visible instructional copy that explains implementation mechanics. Product text should describe what the user can do and what state the app is in.

## Documentation Caution

- `features.md` and current source are the most important references for product behavior.
- `CLAUDE.md` is useful local guidance and should be considered, but verify any technical claim against current source before repeating it.
- Root-level docs, old review files, and deployment notes may contain stale identifiers or historical architecture. Use them for context, not as final authority.
- Comments can also drift. Prefer actual declarations and call sites over prose comments when they disagree.

## Common Investigation Commands

- Find code quickly with `rg "<term>"`.
- List files with `rg --files`.
- Show line numbers with `nl -ba <file> | sed -n '<start>,<end>p'`.
- Check target membership and dependencies in `project.yml` before moving files across app, shared, and keyboard boundaries.
- Check the dirty tree with `git status --short` before editing, and keep unrelated changes untouched.
