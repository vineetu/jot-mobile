# Experiments — things this build exists to verify

Each experiment has (1) a setup, (2) a specific thing to measure, (3) a pass criterion. If an experiment fails, write down WHY in this file before reconsidering architecture.

---

## Experiment 1 — Parakeet on iPhone Neural Engine

**Setup:** Build and run on a real iPhone 15 Pro or later. Tap "Record" in the main app, say a 10-second sentence, stop.

**Measure:**
- Model download size (should match `AsrModels.loadDefault` expectation, ~1.25GB)
- Cold-start time (first launch after install)
- Warm inference time (subsequent launches — 10s audio should be ≤ 200ms on A17 Pro)
- Accuracy on typical rambly speech (spot-check)
- Memory peak during inference

**Pass:** Warm inference under 500ms for 10s audio. Transcription quality matches what we see on the Mac app for the same speaker/audio.

**Fail mitigation:** If ANE unavailable / model won't load, fall back to `SpeechAnalyzer.SpeechTranscriber` and skip Parakeet on mobile. Reassess the "Parakeet differentiator" thesis.

---

## Experiment 2 — Apple Foundation Models cleanup quality

**Setup:** Toggle "Clean up transcription" on in Settings. Feed rambly speech like:
> "yeah yeah yeah so I was thinking like do you wanna, um, do you wanna grab coffee uh tomorrow around like maybe four or five I don't know whatever works for you"

**Measure:**
- Cleanup latency (how long after transcription does the cleaned text appear?)
- Output quality (is it actually a polished message? Does it over-edit and lose meaning?)
- Behavior with custom cleanup instructions (tone: casual/formal; length: keep/shorten)
- Behavior when Apple Intelligence is disabled or unavailable

**Pass:** Output is something the user would actually send in iMessage without editing. Latency under 2 seconds. Custom instructions meaningfully change the output.

**Fail mitigation:** If Foundation Models output is mediocre, try prompting strategies. If still bad, evaluate Gemma 3 2B text-only as a download-on-demand cleanup model.

---

## Experiment 3 — Hybrid keyboard smart-paste (THE big one)

This is the experiment that determines whether we have a real product wedge.

**Setup:**
1. Install the app. Enable the Jot keyboard in Settings > General > Keyboard > Keyboards > Add New Keyboard.
2. Grant "Allow Full Access" (required for clipboard read from an extension).
3. Bind the Jot "Dictate" AppIntent to the Action Button (Settings > Action Button > Shortcut > Jot > Dictate).
4. Open Messages. Start a new message to yourself.
5. Press Action Button. Speak. Press Action Button again (or tap stop).
6. Return to Messages (see sub-measure below).
7. Tap the message text field.

**Measure:**
- **How does the user get back to Messages after recording?** Does Jot's main app appear full-screen (bounce), or can we stay in a Live Activity? Count taps/swipes.
- **Does the Jot keyboard appear when the text field is tapped?** (It should, if set as most recently used.)
- **Does the "fresh dictation" banner show in the keyboard?** Timestamp check: < 30s since Jot wrote to clipboard.
- **Does tapping "Paste transcription" in the keyboard bar insert via `textDocumentProxy.insertText()`?** Does it insert cleanly without triggering iOS's built-in "paste from Messages?" privacy toast?
- **Auto-paste mode (toggleable):** Does the keyboard auto-insert on first appearance after fresh dictation? Any unexpected iOS UI?

**Pass criterion — the strict version:**
- Action Button → speak → Action Button again → tap text field → transcript appears. **No more than 2 discrete user actions after "speak".**

**Pass criterion — the pragmatic version:**
- Same as above but the user has to swipe back to Messages from Jot (one extra swipe). Still meaningfully better than Wispr Flow's current flow.

**Fail:** If iOS shows a full-screen "Paste from Jot?" confirmation every time (the iOS 14+ clipboard privacy UI), the pattern is dead. Reassess.

**Fail mitigation:** If the keyboard approach is blocked by iOS privacy UI, we fall back to the plain "copy to clipboard + manual paste" flow (Eloquent's pattern). We still beat SpeechTranscriber quality (Parakeet) and beat everyone on cleanup (Foundation Models), but the "one-tap paste anywhere" wedge is gone.

---

## Experiment 4 — Action Button flow & "return to previous app"

**Setup:** With the Jot "Dictate" AppIntent bound to Action Button, start from Messages.

**Measure:**
- Does the AppIntent run as a Live Activity without showing Jot's full app? (iOS 16+ allows `openAppWhenRun = false` for intents; audio recording from an intent without opening the app is the open question.)
- If Jot's app opens: how long is it visible? Can we auto-background it after recording stops?
- Latency: Action Button press → mic actually recording. Should be < 500ms.
- Stop gesture: second Action Button press? On-screen button? Silence detection? Pick one and verify.

**Pass:** The recording UI appears (in Dynamic Island, full-screen, or both) within 500ms. User can stop recording with a single gesture. After stop, user ends up back where they started (Messages) with ≤ 1 extra swipe.

**Fail mitigation:** If `openAppWhenRun = false` + audio recording isn't possible, accept the full-app-launch flow but keep the visible UI duration minimal (< 2 sec after stop).

---

## Out of scope for these experiments

- Throughput across multiple simultaneous recordings
- Network edge cases (app is fully offline)
- Localization (English only)
- Accessibility (VoiceOver etc.)

These matter for a real product. Not for answering go/no-go.

---

## Scorecard (fill in after testing)

| Experiment | Status | Notes |
|---|---|---|
| 1. Parakeet on ANE | ☐ | |
| 2. Foundation Models cleanup | ☐ | |
| 3. Hybrid keyboard smart-paste | ☐ | |
| 4. Action Button → Live Activity | ☐ | |

If 3 or 4 fail: we either ship the Eloquent-style "open app / copy to clipboard" flow, or we don't ship on iOS.

If all four pass: we have a defensible wedge and proceed to a real iOS app.
