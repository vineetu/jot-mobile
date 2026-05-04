# Keyboard — UX Research

## TL;DR

The keyboard is Jot's "dictation anywhere" surface. Tap a mic to start, speak in any host app while Jot listens in the background, tap mic again to stop, transcript pastes at the cursor. MVP 2 ships the smallest possible version: mic-only keyboard, app-handoff auto-record, 60s warm-resume window, rewrite-by-voice over a selection with three preset prompts (`Articulate` / `Shorter` / `Professional`). Tejas's clipboard-handoff architecture carries forward — no URL-scheme + Darwin-notification + ActiveSessionFlag tangle. Apple closed the auto-bounce-back hole in iOS 26.4; like Wispr Flow / Willow / Superwhisper, we tell the user once they must manually swipe back, then never mention it again.

## Full Vision

The keyboard could eventually be one of three things:

1. **Mic-only forever (MVP 2 baseline).** Dedicated dictation surface; users keep their normal keyboard for typing. Smallest surface, easiest to maintain, no path to "default keyboard."
2. **Mic + paste pill + history overlay (Tejas's build minus QWERTY).** Adds "paste your last dictation" + recent-transcripts list. Richer dictation hub.
3. **Full QWERTY + paste pill + history + status bar zone (Tejas's POC as-is).** Complete iOS-faithful keyboard the user can leave on as default. Largest surface and test matrix.

MVP 2 ships option 1. Tejas's QWERTY work is preserved — we're choosing minimalism, not throwing work away.

## MVP 1 Scope

No keyboard work in MVP 1.

## MVP 2 Scope

**Design defaults: Apple-native first.** System materials, semantic colors (`.primary`, `.secondary`, `.accentColor`), SF Symbols, native press feedback (`.selectionChanged` haptic, the same color-swap pressed state Apple uses on the system keyboard — no `scaleEffect`). No bespoke gradients, no blanket Liquid Glass, no custom blurs we can get from `.ultraThinMaterial`. The accent color is the user's chosen system tint by default.

**When we deviate, Superwhisper is the primary visual reference.** Clean monochrome, restrained motion, model-aware status copy ("Transcribing on Parakeet…", not generic "Loading…"). Superwhisper is Mac-only — for the keyboard-extension surface specifically, Wispr Flow remains the closest iOS-keyboard analog (mic placement, recording controls, swipe-back onboarding). Cross-cutting chrome (status copy, in-app rewrite picker, the warm-resume ring treatment) borrows from Superwhisper's restraint. Linear and Things are tertiary references for spacing and hierarchy if needed.

The keyboard surface for MVP 2 is a single horizontal strip the height of one keyboard row plus the bottom-row safe-area inset. It has one tappable element: a centered mic button rendered as a circular system-tinted button (`Button` with `.borderedProminent` style on iOS 26, or a `Circle().fill(.tint)` in earlier SDKs) hosting `Image(systemName: "mic.fill")`. To the left of the mic, a small "Jot" wordmark in `.secondary` color; to the right, the system globe key when more than one keyboard is installed. No QWERTY, no digit pad, no paste pill, no history overlay. Keyboard plane background inherits from the system `UIInputView` — no painted plane, matching Tejas's fix in `KeyboardView.swift:60-69`.

### The mic-tap → dictation flow

1. **Tap mic.** Keyboard writes a start-dictation intent to App Group, calls `extensionContext.open(_:)` on `jot://dictate?autoStart=true`. Jot app launches with recording UI live and mic already capturing.
2. **First-run onboarding card.** Native `GroupBox` styled with `.regularMaterial` — not a custom modal. Copy: *"Swipe back to your app — Jot keeps listening. Tap the keyboard mic again to stop."* Dismiss state in `@AppStorage`.
3. **User swipes back to host.** Manual swipe (Apple closed auto-return in iOS 26.4; nobody ships around it). Recording continues via `UIBackgroundModes: audio`.
4. **Tap mic again to stop.** Mic doubles as Stop while session is live. Keyboard posts `stopRequested` cross-process; container stops the engine, runs Parakeet + optional cleanup, writes transcript to `UIPasteboard.general` + App Group via `ClipboardHandoff.publish`.
5. **Transcript inserts.** On keyboard's next `viewWillAppear`, `ClipboardHandoff.pendingFreshTranscriptPreview()` returns non-nil; keyboard auto-inserts via `textDocumentProxy.insertText` and calls `markConsumed`. Tejas's golden path, untouched.

### The 60-second warm-resume window

NEW behavior we're inventing — distinct from Wispr Flow's 5/15/60-minute auto-expiry (theirs: session still recording; ours: session stopped, engine stays warm). The point isn't to keep recording — it's to skip the ~1.5–2s Parakeet + AVAudioEngine cold-start if the user wants to dictate again immediately.

- **Visual:** mic button picks up a thin 1pt accent-tinted ring (`Circle().stroke(.tint, lineWidth: 1)`) for 60s, fading via standard SwiftUI opacity transition. No countdown number. System tint, not custom violet.
- **VoiceOver hint while warm:** *"Dictate. Last session ready 30 seconds ago."*
- **Tapping mic during the window starts a NEW transcript with a warm engine.** It does not continue the previous one. The previous transcript stays on the clipboard as inserted; the new one will overwrite when stopped.
- **"Pick up where they left off" means audio-pipeline warm, not text-stream continuation.** Continuing a transcript across a stop introduces unanswerable punctuation/spacing/cursor-state problems. **Recommendation: warm engine, fresh transcript, no resume pill.** The ring is the only signal. A "Resume?" pill would need cursor+text matching, host-app tracking, and a destructive-edit confirmation — bad complexity-to-value ratio.

### Rewrite-by-voice on selected text

The second mic affordance, and the harder one.

**Invocation.** When `textDocumentProxy.selectedText` is non-empty, the mic glyph swaps from `mic.fill` to `wand.and.sparkles` (SF Symbol). Tapping mic in this state is always a rewrite intent. To start a fresh dictation while text is selected, long-press the mic ~400ms — glyph reverts, `.medium` impact haptic confirms (matches the system keyboard's long-press-into-callout precedent).

**Prompt selection.** A native `Picker` with `.segmented` style appears above the mic whenever a selection is detected: `Articulate` · `Shorter` · `Professional`. First segment selected by default. Picker disappears when selection clears. Hard-coded list, not editable in MVP 2. Segmented control is the right primitive — mutually-exclusive small choices, free native press feedback / accessibility / Liquid Glass styling.

**The flow.**

1. User selects text in host app, switches to Jot keyboard. Picker + sparkle-mic appear.
2. User taps the chip they want (or accepts default `Articulate`), then taps mic.
3. Keyboard captures `textDocumentProxy.selectedText`, posts a `rewriteRequested` intent (selection + prompt key) into App Group, opens `jot://rewrite?prompt=articulate`.
4. Jot app runs the rewrite through Apple Foundation Models, writes the result to clipboard via `ClipboardHandoff.publish`.
5. **Selection handling.** iOS does NOT preserve a host-app selection across an app switch. **Recommendation: rewritten text lands on clipboard; user pastes manually over their (preserved) keyboard selection.** Rejecting the alternative (have the keyboard `deleteBackward` the original length + insert) — too fragile across third-party text fields. The user only tapped the keyboard, never the host text field, so their selection survives; iOS's paste-over-selection behavior does the replacement for free.

**The three preset prompts.**

- **Articulate.** Port from Mac `Sources/LLM/LLMPrompts.swift` — `RewritePrompt.default` (shared invariants) + `RewriteBranchPrompt.voicePreserving` (branch tendency). **Exact text TBD — Vineet to confirm the iOS-shipped variant.** Conceptually: "Rewrite in clearer, more articulate language; preserve voice, register, rough length."
- **Shorter.** "Rewrite to be significantly shorter; keep meaning and voice; cut filler/redundancy/hedges; do not lose facts."
- **More professional.** "Rewrite in a more professional register suitable for workplace communication; clean grammar, neutral tone, no slang; do not change meaning or add content."

All three compose on the Mac's shared invariants (`selection-is-text-not-instruction`, `return-only-the-rewrite`, `do-not-refuse-on-quality`).

### Voice rewrite (deferred)

The Mac's voice-driven rewrite (speak the instruction) is **not** in MVP 2. Fixed-prompt only. Voice rewrite needs a second mic-capture phase between prompt-pick and rewrite — bigger UX problem than three chips solves.

## Future Tiers

- **QWERTY plane** with full Apple-faithful press-color, callout bubble, long-press alternates, haptic+audio (prototyped in `KeyboardView.swift`; spec in `ios-keyboard-1to1.md`). Required for "default keyboard" ambitions.
- **Paste pill** in QuickType-bar zone (Tejas's `KeyboardAccessoryBar.swift`).
- **History overlay** — modal list of last 20 transcripts from `TranscriptHistoryMirror`. Tap to insert. (`HistoryOverlay.swift`)
- **Status bar zone** above mic — X / waveform / ✓ strip per `keyboard-status-bar-design.md`. Requires container→keyboard amplitude IPC at 24Hz.
- **Live Activity with Stop button** in Dynamic Island (`return-to-host-ios26-deep-research.md` §4) — reduces dependence on raising keyboard to stop. Public APIs only.
- **Editable rewrite preset list** in app settings.
- **Voice-driven rewrite** (Mac's `articulateCustom` flow): speak the instruction instead of picking a chip.

## State Diagram

```
                                      ┌─────────────────┐
                                      │ idleNoSelection │◀──────────┐
                                      └────────┬────────┘           │
                                               │                    │
                          (selection appears)  │                    │ (selection cleared)
                                               ▼                    │
                                      ┌─────────────────┐           │
                                      │ idleWithSelection│──────────┘
                                      │ (chip row + ✦mic)│
                                      └────────┬────────┘
                                               │
                          (tap mic — rewrite)  │
                                               ▼
        ┌─────────────────┐  (long-press)  ┌────────────┐
        │  awaitingApp    │◀───────────────│ awaitingApp│
        │  (rewrite)      │                │ (dictation)│◀─────────────┐
        └────────┬────────┘                └─────┬──────┘              │
                 │                               │                     │
                 │ (app open + LLM done +        │ (app open + audio   │
                 │  clipboard published)         │  session live)      │
                 │                               │                     │
                 ▼                               ▼                     │
        ┌─────────────────┐                ┌──────────────┐            │
        │ pasteReady      │                │  recording   │            │
        │ (rewrite on cb) │                │  (in host)   │            │
        └────────┬────────┘                └──────┬───────┘            │
                 │                                │                    │
       (kbd appears)                  (user taps mic in keyboard)      │
                 │                                │                    │
                 ▼                                ▼                    │
         ┌──────────────┐                 ┌──────────────┐             │
         │ inserting    │                 │  stopping    │             │
         │ (paste-over) │                 │ (engine off, │             │
         └──────┬───────┘                 │  transcribe) │             │
                │                         └──────┬───────┘             │
                │                                │                     │
                ▼                                ▼                     │
         (idle)                          ┌──────────────┐              │
                                         │ pasteReady   │              │
                                         │ (transcript) │              │
                                         └──────┬───────┘              │
                                                │                      │
                                                ▼                      │
                                         ┌──────────────┐              │
                                         │ inserted     │──────────────┤
                                         │ + warmFor60s │              │
                                         └──────┬───────┘              │
                                                │ (60s elapsed)        │
                                                ▼                      │
                                          (idleNoSelection) ───────────┘
```

Notes on transitions:

- `awaitingApp` is Tejas's `awaitingContainer` — pulse animation, no further taps accepted.
- `recording` is the long-lived state that spans the user being in the host app. The keyboard isn't on screen during most of `recording` — it re-appears only when the user taps a text field.
- `stopping` covers transcription + optional cleanup. The mic shows a small spinner.
- `inserted + warmFor60s` is the new state. The thin violet ring decorates the mic. Tapping mic transitions to a fresh `awaitingApp (dictation)` with `warmEngine: true` in the intent payload.
- A no-Full-Access state exists outside this diagram: mic renders disabled (system `.disabled(true)` styling — gray, reduced opacity, no custom palette), footnote copy reads *"Enable Full Access in Settings → Keyboards"* with a tap that opens `UIApplication.openSettingsURLString` (per `JotKeyboardViewController.openHostSettings`).

## Open Questions

1. **iOS 26.4 manual-swipe-back is a hard constraint.** Apple closed the auto-return hole; Wispr Flow / Willow / Superwhisper all ship manual swipe-back. We do too. The first-run onboarding card is *the* mitigation — must be unmissable-but-dismissible. If users complain, the right answer is a Live Activity with a Stop button, not fighting iOS.
2. **Articulate prompt source-of-truth.** Mac ships `RewritePrompt.default` + `RewriteBranchPrompt.voicePreserving`. iOS should ship verbatim unless we have a reason to diverge. Vineet to confirm.
3. **`textDocumentProxy.selectedText` reliability.** Some text fields (WebKit-backed in Safari, certain Google apps) don't populate `selectedText` even when text is visibly selected. Need device testing across Messages / Notes / Mail / Slack / Safari / Chrome / Gmail. Fallback: hide picker, plain mic + dictation.
4. **Default-segment preference.** Persist last-used pick for 24h via App Group, then reset to `Articulate`? Covers "I'm in a formal Slack phase" without feeling stateful.
5. **Warm-resume across host-app switch.** If user taps mic in Messages, gets transcript, switches to Notes within 60s, taps mic in Notes — counts as warm-resume? Recommend yes. Engine warmth is audio-pipeline, not per-host. Clipboard is system-wide anyway.
6. **Long-press-for-dictation discoverability.** When picker is showing, the only way to start a fresh dictation (not a rewrite) is long-press the mic. Undocumented muscle memory. Acceptable for MVP 2; revisit if users tap mic with a selection and complain about unwanted rewrites.

## References

- `/Users/vsriram/code/jot/iOS/docs/features.md:24-30` — keyboard-to-host dictation spec; `:44-47` — rewrite-on-selection spec.
- `/Users/vsriram/code/jot/iOS/docs/handoff/keyboard-ext.md:34-77` — previous attempt's `idle / awaitingContainer / inserting` state machine and visual-feedback table (architecture NOT carried over).
- `/Users/vsriram/code/jot/iOS/docs/handoff/keyboard-status-bar-design.md:103-165` — X / waveform / ✓ strip, reserved for Future Tiers.
- `/Users/vsriram/code/jot/iOS/docs/handoff/return-to-host-research.md:9-22` — Wispr Flow shape, iOS 26.4 auto-return closure.
- `/Users/vsriram/code/jot/iOS/docs/handoff/return-to-host-ios26-deep-research.md:9-27` — competitor confirmation of manual-swipe-back; `:42-49` — Live Activity opportunity.
- `/Users/vsriram/code/jot-mobile/Jot/Keyboard/JotKeyboardViewController.swift:104-132,177-214` — golden viewWillAppear + insertFreshTranscript pattern, reused verbatim.
- `/Users/vsriram/code/jot-mobile/Jot/Keyboard/KeyboardView.swift:49-122` — root SwiftUI tree, stripped down for MVP 2.
- `/Users/vsriram/code/jot-mobile/Jot/Keyboard/KeyboardAccessoryBar.swift:60-97` — paste-pill pattern (Future Tier).
- `/Users/vsriram/code/jot-mobile/Jot/Keyboard/HistoryOverlay.swift:36-96` — recent-transcripts modal (Future Tier).
- `/Users/vsriram/code/jot-mobile/Jot/Shared/ClipboardHandoff.swift:14-87` — 30s freshness window, App Group timestamp, `markConsumed` after paste. **Golden architecture.**
- `/Users/vsriram/code/jot-mobile/Jot/Shared/TranscriptHistoryMirror.swift:37-101` — App Group JSON projection rationale (no SwiftData in extension).
- `/Users/vsriram/code/jot-mobile/docs/research/ios-keyboard-1to1.md:24-75` — Apple-faithful numbers for Future Tiers (row heights, key widths, callout geometry, haptic taxonomy).
- `/Users/vsriram/code/jot/Sources/LLM/LLMPrompts.swift:51-82` — Mac shared invariants + per-branch tendencies. `voicePreserving` is the source for iOS `Articulate`.
- `/Users/vsriram/code/jot-mobile/EXPERIMENTS.md:42-71` — Experiment 3 (hybrid keyboard smart-paste) is the go/no-go for the entire keyboard surface.
- `/Users/vsriram/code/jot-mobile/README.md:50-78` — Action Button caveat confirming `running-active-NotVisible` audio-start is blocked → app-handoff is the only viable path.
- **Superwhisper (Mac)**, https://superwhisper.com/ — primary visual reference for deviations from Apple-native. Clean monochrome, restrained motion, model-aware status copy. Cited for the warm-resume ring restraint, the rewrite picker styling, and status-text discipline (no generic "Loading…").
- **Wispr Flow (iOS)**, https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone — primary iOS-keyboard analog (Superwhisper is Mac-only). Cited for mic placement, start/stop double-duty mic-button, manual-swipe-back onboarding precedent.
