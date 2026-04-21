# Jot Mobile — iOS 26 Experiment

A throwaway iOS app to verify three architectural bets before committing to a full Jot iOS port:

1. **Parakeet TDT 0.6B v3 runs on iPhone Neural Engine** — via FluidAudio, same stack as the Mac app
2. **Apple Foundation Models (iOS 26) do a good job cleaning up rambly speech** — one API call, free, on-device
3. **The "hybrid keyboard" UX is possible** — main app records, keyboard extension smart-pastes from clipboard. Nobody has shipped this pattern.

If all three work, we have a real product wedge vs Wispr Flow (cloud, bouncing) and Google AI Edge Eloquent (on-device but app-confined, no system integration).

## Scope — explicitly minimal

This is NOT a port of `JOT-Transcribe`. This is a separate sandbox that shares **only** the transcription engine choice and the cleanup philosophy. Once the experiments answer go/no-go, we decide whether to:
- fold this into the Mac repo as a second target,
- keep it as a standalone iOS product, or
- scrap it and ship only on Mac.

## Out of scope for this experiment

- Polished UI, Live Activities beyond a bare pill, app icons, onboarding, settings sync, library/history, sharing across devices. Those come AFTER go/no-go.
- Android. Parakeet requires Apple Neural Engine — this is an Apple-only bet.
- Pre-iOS-26 devices. Apple Foundation Models require iOS 26 + Apple Intelligence (iPhone 15 Pro and later, M-series iPad). That's the target cohort.

## Platform targets

| | Version | Rationale |
|---|---|---|
| iOS deployment target | **26.0** | SpeechAnalyzer + Foundation Models framework |
| Xcode | 26 beta or later | iOS 26 SDK |
| Swift | 6.0+ | Strict concurrency |
| Devices | iPhone 15 Pro, 16, 17 series; M-series iPad | Apple Intelligence required |

## Build

We use [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the project is reproducible from a YAML spec and plays well with git.

```bash
# One-time
brew install xcodegen

# Generate the Xcode project (re-run any time project.yml changes)
cd Jot
xcodegen

# Open
open Jot.xcodeproj
```

Then in Xcode: select a real device (Simulator does NOT support Apple Neural Engine — Parakeet won't work), sign with your team, build & run.

## Targets

1. **Jot** — main iOS app. Records, transcribes, optionally cleans up, copies to clipboard.
2. **JotKeyboard** — custom keyboard extension. Zero ML. Reads a "fresh dictation" signal from App Group; if present, shows a one-tap "Paste transcription" affordance OR auto-inserts (toggleable).
3. **JotWidget** — widget extension that hosts a Live Activity for in-flight recording (the Dynamic Island pill).

## Test plan — see `EXPERIMENTS.md`

Four experiments, each with a pass/fail criterion. If any fail, we stop and reconsider.

## What this repo is NOT

A production-quality iOS app. The point is to answer questions. Code is deliberately minimal, comments are sparse, error handling is "print and continue". Resist the urge to polish before the experiments pass.
