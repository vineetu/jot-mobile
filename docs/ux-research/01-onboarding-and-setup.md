# Onboarding & Setup — UX Research

## TL;DR

Jot iOS opens with one job: get the user from "tap the icon" to "see my words on screen" with minimum permission theatre. MVP 1 has effectively no wizard — Welcome, mic prompt, model download with a real progress bar — because the only feature is in-app dictation. MVP 2 adds two platform-mandated steps (enable the Jot keyboard; grant Full Access) plus a Test step, and resists bolting on Tier-2/3 panes (cleanup provider, vocabulary). Setup is re-runnable from Settings via a soft reset of `hasCompletedSetup` (model cache, history, permissions preserved). Every step is skippable except the OS-controlled mic prompt; recovery paths — denied mic, model integrity failure, missing App Group, keyboard not detected — never dead-end. The home screen always works at whatever capability level the user has actually granted.

## Design principle

**Default to the Apple-native pattern.** `NavigationStack` per-step views inside a `.fullScreenCover`; semantic colors (`.primary`, `.secondary`, `.accentColor`); SF Symbols; native `ProgressView`; native `.alert` for Skip-with-warning; `Form` / `List` for structured rows (Done step's Settings + Help pointers). `.task` + `@Observable` for state refresh on view re-appear from iOS Settings. iOS 26 Liquid Glass belongs on the eventual nav-bar / tab-bar chrome and the Record capsule — **not** on wizard cards. Each card is `Color(.systemBackground)` with one or two large native controls; let the OS draw it.

**When the native pattern is too sparse, Superwhisper for Mac is the primary reference.** Monochrome ground, hairline strokes, model-aware status copy ("Downloading model · 240 MB of 1.25 GB"), settings as table-rows not feature-cards, restrained motion (fades + the 900 ms `.ready` hold; no springs or shimmers). Pattern-match Superwhisper's Mac onboarding for the Model download and Test dictation steps — the two that genuinely exceed a `Form` row. Wispr Flow / Linear / Things are secondary, borrowed only if Superwhisper is silent. No web-first idioms (no full-bleed gradients, no animated illustrations, no oversized "Step N of 7" chevrons).

## Full Vision

Onboarding is **progressive disclosure on a permission curve** — a user sees a step only if Jot literally cannot do the next thing without it, or if they re-entered the wizard from Settings to fix a known-broken state.

**1. Welcome.** Full-screen card. Icon, tagline ("Speak. It's written."), *Get started*. Re-runs from Settings start at step 2.

**2. Microphone permission.** One-sentence rationale, primary *Allow microphone* triggering `AVAudioApplication.requestRecordPermission`, secondary *Skip for now*. On `.denied`, primary flips to *Open Settings* + a hairline note: "Mic access is off. You won't be able to record until you turn it on." `.task` re-fires on view re-appear; state refreshes after returning from Settings.

**3. Model download (Parakeet).** Binds to `TranscriptionService.modelState`:
- `.notLoaded` + on-disk check fails → *Download Parakeet* + "≈1.25 GB · Wi-Fi recommended" + Wi-Fi-only toggle (default on).
- `.downloading(fraction)` → `ProgressView(value:)` + monospaced "X of Y MB" + *Cancel*. User can leave; download continues via `BGProcessingTask`.
- `.ready` → checkmark + "Installed", auto-advance 900 ms.
- `.failed(reason)` → render localized reason verbatim, *Retry*, *Skip for now*. Special copy: `cellularBlocked` → "Connect to Wi-Fi or turn off Wi-Fi-only download"; `integrityCheckFailed` → "Download was corrupted — retrying will start fresh"; `appGroupMissing` → "Jot's storage is unreachable. Reinstall to fix. *Continue anyway* will let in-app record work but transcripts won't sync to the keyboard."

**4. Enable Jot keyboard (MVP 2).** Inline walkthrough + *Open Keyboard Settings* (Apple removed the General → Keyboard deep-link in iOS 10; walk the remaining taps in copy: "Tap **General → Keyboard → Keyboards → Add New Keyboard → Jot**"). Secondary *Skip for now* triggers a native `.alert` with destructive Skip. On re-appear, best-effort probes `UITextInputMode.activeInputModes`; if detected, shows "Jot keyboard detected" — if not, copy stays neutral (false negatives are common).

**5. Allow Full Access (MVP 2).** Sub-step gated on prior step. Copy: "Full Access lets the Jot keyboard read your transcript so it can paste it. Without it, Jot can't deliver text to other apps." Same Open Settings + Skip-with-warning. Privacy line: "Your transcripts stay on this iPhone. No network, no telemetry."

**6. Test dictation (MVP 2).** Native `TextField` inside the card. Copy: "Tap the Jot keyboard's mic, say something, watch it appear here." 10-second focus-without-typing watchdog → troubleshooting copy ("Make sure you switched to the Jot keyboard — globe → Jot"). *Continue* never gated on actual typing.

**7. Done.** "You're set up. Tap the mic anywhere to dictate." *Take me to Jot* + a small `Form` of pointers to Settings (Re-run setup, AI cleanup, Vocabulary) and Help.

**Re-run from Settings.** *Setup* row in Settings → *Re-run setup* calls `WizardCompletion.reset()` which only clears the `hasCompletedSetup` UserDefaults flag. Model cache, transcript history, mic permission, and keyboard installation untouched.

**Recovery paths (recurring):** every Open-Settings link uses `UIApplication.openSettingsURLString` inside `guard let` — never force-unwrapped. Every state surface has *Continue anyway* / *Skip for now* except the in-context `requestRecordPermission` call (OS controls that). Returning from Settings re-runs the relevant probe so UI flips without manual kick.

**Error states handled without crashing:** App Group container missing → `ModelManager.shared` is nil → fallback inline "reinstall + Continue anyway" on Model step. Model corrupt mid-use → handled at record time; wizard re-run offers Re-download. Memory-warning eviction → `TranscriptionService.warmUp()` re-loads transparently; files-on-disk check still reads `.ready`.

## MVP 1 Scope

In-app only. No keyboard, no rewrite. Wizard collapses to **three steps**:

1. **Welcome** — *Get started*.
2. **Microphone permission** — request + denied recovery.
3. **Model download** — progress bar, Wi-Fi toggle, retry, *Continue anyway*.

No Done step; auto-dismiss to home on `.ready` + mic granted. The home screen Record button shows the same `.notLoaded` / `.downloading` / `.failed` UI inline if the user skipped — no separate re-entry needed.

**Re-run wizard from Settings is Tier-1 even in MVP 1** — without it, a user who skipped the model download has no path back to the download UI when they're on Wi-Fi later.

## MVP 2 Scope

Adds keyboard + selection-rewrite. Onboarding gains:

4. **Enable Jot keyboard** — walkthrough + Open Settings + Skip-with-warning.
5. **Allow Full Access** — sub-step with explicit privacy reassurance.
6. **Test dictation** — live TextField + 10s watchdog troubleshooting copy.
7. **Done** — *Take me to Jot* + pointers to Settings.

The 3 hard-coded rewrite presets (Articulate, Make it shorter, Make it more professional) get **no setup step** — fixed list in code.

## Future Tiers

Beyond MVP 2, the Done step can grow native `DisclosureGroup` rows inside a `Form` for cleanup provider (default Apple Intelligence on iOS 26+; opt-in to OpenAI/Anthropic/Gemini/Ollama with Test Connection), custom vocabulary phrase list, user-editable rewrite presets, record retention preference (Forever / 7 / 30 / 90 days), notifications opt-in, and a Donation row. Onboarding never gates on these — they're discoverable in Settings; the home screen works without them.

## State Diagram

```
Welcome ─► Mic permission ─► Model download ─┐
                  ▲                          │
                  │ (return from Settings)   │
                  │ refreshes via .task      │
                                             │
                                MVP 1 ◄──────┤──────► MVP 2+
                                  │                       │
                                  ▼                       ▼
                            [ Home / Record ]   Enable keyboard
                                                   │ Open Settings | Skip→alert
                                                   ▼
                                                 Allow Full Access
                                                   │ Open Settings | Skip→alert
                                                   ▼
                                                 Test dictation
                                                   │ TextField + 10s watchdog
                                                   │ Continue never gated
                                                   ▼
                                                 Done ─► hasCompletedSetup = true
                                                            ▼
                                                     [ Home / Record ]

Re-run from Settings ─► hasCompletedSetup = false ─► wizard re-presents
                        (preserves cache, history, permissions)
```

| State | Skippable | Auto-advance | Recovery |
|---|:---:|:---:|---|
| Welcome | n/a | no | none |
| Mic permission | yes | on `.granted` | Open Settings on `.denied` |
| Model download | yes | on `.ready` (900 ms) | Retry / Wi-Fi toggle / Continue anyway |
| Enable keyboard | yes (alert) | no | Open Settings + walkthrough copy |
| Full Access | yes (alert) | no | Open Settings + privacy line |
| Test dictation | Continue is free; no Skip | no | 10s troubleshooting card |
| Done | n/a | n/a | none |

## Open Questions

1. **Wi-Fi-only default for MVP 1?** ~1.25 GB model. Defaulting on protects cellular plans but creates a confusing dead-end on hotspots iOS classifies as cellular. Recommend: default on, surface toggle prominently.
2. **MVP 1 Done step or no?** Designed without one (auto-dismiss after model + mic). Add a "you're all set" beat to plug Settings + Help? Cost: one extra tap on first run.
3. **Re-run preserves model cache — confirm.** Spec says re-run only resets `hasCompletedSetup`. Confirm a re-running user should NOT have to re-download Parakeet.
4. **Mic permission "Skip for now" — acceptable?** Skipping lands the user on an app where Record is non-functional until they fix it in Settings. Acceptable, or should mic be the one non-skippable step?
5. **Keyboard-detection badge worth showing?** `UITextInputMode.activeInputModes` only populates after actively switching to Jot in some app — false negatives are common. Recommend: drop the badge in MVP 2; Test step is the authoritative signal.

## References

**Previous-attempt design (UX inspiration only — do NOT copy architecture):**
- `/Users/vsriram/code/jot/iOS/docs/features.md:88-97` — wizard step list, skippability.
- `/Users/vsriram/code/jot/iOS/docs/features.md:154-156` — re-run wizard is Tier-1.
- `/Users/vsriram/code/jot/iOS/docs/handoff/setup-wizard.md:36-66, 86-115, 120-169, 192-206` — step graph, permission guards, 900 ms auto-advance, Open-Settings handling, re-run via `WizardCompletion.reset()`.
- `/Users/vsriram/code/jot/iOS/docs/handoff/model-mgr.md:166-210, 262-269` — `ModelStatus` machine, Wi-Fi-only contract, integrity check protocol, wizard Model step spec.
- `/Users/vsriram/code/jot/iOS/docs/handoff/app-layout-design.md:64-83, 163-165` — launch-mode split (hot path bypasses wizard); wizard mounted as `.fullScreenCover` when `hasCompletedSetup == false`.

**Tejas's working baseline:**
- `/Users/vsriram/code/jot-mobile/Jot/App/JotApp.swift:46-69` — `.task` warm-up + cold-launch mirror refresh.
- `/Users/vsriram/code/jot-mobile/Jot/App/JotAppDelegate.swift:8-95` — `BGProcessingTask` warming, supports "download continues in background".
- `/Users/vsriram/code/jot-mobile/Jot/App/Transcription/TranscriptionService.swift:30-36, 126-175` — `ModelState` enum + `warmUp()` contract (idempotent, fire-and-forget).
- `/Users/vsriram/code/jot-mobile/EXPERIMENTS.md:7-21, 42-69` — ~1.25 GB Parakeet model + ~10s cold load + Full Access requirement for the keyboard.
- `/Users/vsriram/code/jot-mobile/README.md:36-44` — "Cold-load honesty"; the "show real progress, don't lie" principle.

**Visual / interaction references (deviation cases):**
- **Superwhisper for Mac (primary)** — https://superwhisper.com — monochrome ground, hairline strokes, model-aware status copy ("Downloading model · X of Y"), settings-as-table-rows, restrained motion. Pattern-matched for Model download and Test dictation.
- **Wispr Flow (secondary)** — single-page onboarding tone; borrowed only when Superwhisper is silent.
- **Linear / Things (secondary)** — restrained type and Done-step row composition.
