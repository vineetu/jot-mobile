# Testing Jot on a real device

This walks you through installing the Jot experiment on an iPhone and exercising each of the four experiments in `EXPERIMENTS.md`. The build engineer maintains this doc — open an issue if something drifts.

## 🚀 Path A: Install on device right now (Experiments 3 + 4)

Do these in order. Takes 5–10 minutes end to end. Transcription runs in **stub mode** right now (Parakeet intentionally disabled) — Path A validates UX wiring only. Experiments 1 and 2 require the real ASR + cleanup pipeline and aren't in scope here.

1. **Install the iOS 26.2 platform runtime on your Mac.** **Xcode → Settings → Components → Platforms → iOS 26.2 → Install**, or run `xcodebuild -downloadPlatform iOS` from Terminal. The runtime is a separate download from Xcode itself and it is required. **Do not skip — every iOS build fails without it.**
2. Plug your iPhone (15 Pro or later) into the Mac with a cable. Unlock the phone. Tap **Trust** on the "Trust This Computer?" prompt if it appears.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On**. The device will reboot. Required for sideloaded builds.
4. From Terminal on the Mac: `cd /Users/tejasdc/workspace/jot-mobile && ./build.sh --open`. This generates `Jot/Jot.xcodeproj` and opens it in Xcode.
5. In Xcode: **Settings → Accounts → +** → sign in with your Apple ID if you haven't already. A free personal Apple ID is enough — see "Signing certificate" below for the details.
6. In Xcode's project navigator, select each of the three targets in turn — **Jot**, **JotKeyboard**, **JotWidget** — and on the **Signing & Capabilities** tab pick your Apple ID under **Team**. All three targets must use the same team.

   **If Xcode shows *"PLA Update available"* or *"No profiles for 'com.jot.mobile.Jot' were found"*:** Apple has published new Program License Agreement terms that need to be accepted before Xcode can create any provisioning profile. This happens roughly 1–2× per year and affects both free personal Apple IDs and paid Developer Program accounts.
   1. Open [developer.apple.com/account](https://developer.apple.com/account/) in a browser.
   2. Sign in with the same Apple ID you added to Xcode.
   3. Accept the Program License Agreement (there will be a banner at the top of the page or a dialog on landing). Scroll all the way through and check the acceptance box.
   4. Back in Xcode's **Signing & Capabilities** panel, click **Try Again** (or toggle "Automatically manage signing" off and on). Profiles generate within a few seconds.

   Profile creation is automatic — leave **"Automatically manage signing"** checked on all three targets. Do NOT try to create a profile by hand at [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles/); that workflow is paid-Developer-Program only and won't recognise a personal-team bundle ID anyway.
7. In Xcode's toolbar, click the run-destination dropdown (to the right of the ⏹ Stop button) and pick your **physical iPhone** — NOT a simulator.
8. Press **⌘R** (or the ▶️ button). First build takes a couple of minutes (FluidAudio + Parakeet model compile steps). Wait for "Build Succeeded" and the app to launch on the phone.
9. **First run only, on the iPhone:** **Settings → General → VPN & Device Management** → tap your Apple ID under "Developer App" → **Trust**. Then back out and tap the Jot icon on the home screen.
10. Grant **Microphone** permission when Jot prompts on first launch.
11. **Experiment 3 setup (keyboard):** iPhone **Settings → General → Keyboard → Keyboards → Add New Keyboard → Jot Dictation**. Back to the Keyboards list, tap **Jot Dictation**, enable **Allow Full Access**, accept the iOS clipboard-access warning.
12. **Experiment 4 setup (Action Button):** iPhone **Settings → Action Button → swipe to Shortcut → Shortcut → App → Jot → Dictate**.
13. **Experiment 3 flow:** Press the Action Button → speak a sentence → press Action Button again to stop → open Messages (new thread to yourself) → tap the text field → long-press the globe icon → switch to **Jot Dictation** → tap the keyboard's **Paste transcription** affordance. A stub string (`[stub] Parakeet disabled…`) should insert. Record in the scorecard how many taps/swipes this took end-to-end.
14. **Experiment 4 flow:** Lock the iPhone or open any non-Jot app → press the **Action Button** once → Jot should foreground (or present a Live Activity) and begin recording → press the Action Button again to stop → observe whether you land back in the prior app or stay in Jot. Record in the scorecard.
15. **Expect stub transcripts.** Every transcript you see during Path A will be the placeholder string `[stub] Parakeet disabled…`. This is intentional. We're validating the keyboard-paste path, the Action Button flow, and the Live Activity — none of which depend on real ASR. The real Parakeet-on-ANE pass lands after the UX is signed off.

**If step 1 is skipped**, Xcode will fail with *"iOS 26.2 is not installed. Please download and install the platform from Xcode > Settings > Components."* Every single time. Install the runtime first.

---

## 🔍 Getting device console logs when something goes wrong

When the app crashes, hangs, or the Action Button does nothing, capture the iPhone's live log stream so we can diagnose. Two options — Console.app is zero-install; the CLI is better for grepping and sharing.

**Console.app (no install):** open `/Applications/Utilities/Console.app` → select your iPhone in the left sidebar under **Devices** → type `Jot` in the search field (top right) → **Start streaming**. To capture a session for sharing: **File → Save As** after stopping the stream.

**CLI (requires `brew install libimobiledevice`):**

```bash
idevicesyslog | grep -iE 'Jot(|Keyboard|Widget)' | tee build-logs/device-$(date +%Y%m%d-%H%M%S).log
```

Leave it running, reproduce the bug, stop with ⌃C. Share the resulting log file. For a point-in-time deep dump (crash reports, spindumps, system state), use `xcrun devicectl device sysdiagnose --device <id>` — this takes several minutes and produces a multi-hundred-MB tarball, so reserve it for hard-to-reproduce crashes.

---

## Required hardware

| Experiment | Device (minimum) | Why |
|---|---|---|
| 1. Parakeet on ANE | iPhone 15 Pro or newer | A17 Pro / A18 / M-series is where FluidAudio's Parakeet TDT 0.6B v3 latency targets are achievable on-device |
| 2. Foundation Models cleanup | iPhone 15 Pro, 16 (any), 17 (any), M-series iPad | Apple Intelligence is required for the on-device `FoundationModels` framework. Older devices silently fall back |
| 3. Hybrid keyboard smart-paste | **Same device as Experiment 1** — needs a Parakeet result in the shared App Group to paste | Keyboard extension has zero ML; it reads `jot.lastDictation` from the shared `UserDefaults` |
| 4. Action Button flow | iPhone 15 Pro or later (Action Button hardware) | The whole experiment is about the side button |

**Simulator is not enough.** Parakeet needs the Apple Neural Engine, which the simulator doesn't virtualize. Foundation Models also doesn't run in the simulator.

## Required software

- macOS host with **Xcode 26.3 or later** AND **the iOS 26.2 platform runtime installed separately via Xcode → Settings → Components**. **This is two downloads, not one.** The iOS 26.2 SDK ships with Xcode 26.3 but the matching platform runtime does not — without the runtime, `xcodebuild -destination 'generic/platform=iOS'` fails with *"iOS 26.2 is not installed. Please download and install the platform from Xcode > Settings > Components."* If you see that error, you haven't installed the runtime yet. Command-line equivalent: `xcodebuild -downloadPlatform iOS`.
- **iOS 26.0 or later** on the target iPhone (the project's deployment target). For Experiments 2-4 you really want iOS 26.2 on device so you're matching the SDK.
- `xcodegen` and `xcbeautify` from Homebrew: `brew install xcodegen xcbeautify`.
- An Apple Developer account (personal is fine for sideload) signed into Xcode. Fill in `DEVELOPMENT_TEAM` in `Jot/project.yml` or set it via the Xcode UI after generation.

## One-time device setup

1. Plug the iPhone in and unlock it. Trust the Mac if prompted.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode → On**. Device will reboot. Required for any sideload.
3. In Xcode: **Window → Devices and Simulators**. Confirm the iPhone appears and is paired.

## Generating and opening the project

```bash
cd /Users/tejasdc/workspace/jot-mobile
./build.sh --open
```

This runs XcodeGen and opens `Jot/Jot.xcodeproj`. Re-run any time `Jot/project.yml` changes. Don't commit the generated `Jot.xcodeproj/` — it is (or will be) in `.gitignore`.

## Signing before first install

In Xcode, select each of the three targets (**Jot**, **JotKeyboard**, **JotWidget**) → **Signing & Capabilities**:

- Team: pick your Apple Developer team.
- Bundle identifiers must remain nested:
  - App: `com.jot.mobile.Jot`
  - Keyboard: `com.jot.mobile.Jot.Keyboard`
  - Widget: `com.jot.mobile.Jot.Widget`
- All three must have the **App Group** capability set to `group.com.jot.mobile.shared`.
- **Jot** (app) needs **Microphone**, **Live Activities**, **App Groups**. Optional: **Siri & Shortcuts** (for the AppIntent).
- **JotKeyboard** needs **App Groups** and its Info.plist must list `RequestsOpenAccess = true` (already set in `project.yml`).
- **JotWidget** needs **App Groups** and Live Activity entitlements.

## Installing on your iPhone

The tight loop is: edit Swift → `./dev.sh` → watch logs on device. First build is slow (FluidAudio + Parakeet model compile for the ANE); subsequent incremental builds are ~15–30 s end-to-end.

Two viable install paths — use the GUI when you want the debugger attached, the CLI when you want to iterate fast without tab-switching:

| Path | Time per iteration | Setup cost | When |
|---|---|---|---|
| Xcode Run button over Wi-Fi | ~20–30 s | 2-minute wireless pairing (once) | Attaching the debugger, inspecting view hierarchy |
| Command-line `devicectl` via `./dev.sh` | ~10–20 s | Export `JOT_DEVICE_ID` once | Tight rebuild-and-launch loops, log tailing |

TestFlight is **not** in this loop. Round-tripping through App Store Connect is minutes-to-hours per iteration and is meant for external testers, not the author.

### Signing certificate — free personal team works for device testing

**TL;DR: the free Apple ID ("personal team") is enough for Jot on your own iPhone. The $99/yr paid Apple Developer Program only becomes necessary when you want TestFlight, App Store distribution, or to escape the weekly re-sign.**

This was a deliberate revision. The earlier verdict was "paid required"; verifying against Apple's own [App Capabilities comparison](https://developer.apple.com/support/app-capabilities/) showed that was wrong for our architecture.

**What the free personal team gives you (verified against Apple docs + 2024–2025 usage reports):**

| Jot needs this | Free personal team |
|---|---|
| App Group (`group.com.jot.mobile.shared`) across 3 targets | ✓ Apple's capabilities page lists "App Groups" as available to the free "Apple Developer" tier. |
| Keyboard extension | ✓ App extensions don't require a separate capability gate. |
| WidgetKit / ActivityKit (Live Activity) | ✓ Same — extensions work. |
| Apple Intelligence / `FoundationModels` | ✓ No signing gate. |
| Keyboard "Allow Full Access" | ✓ Not distribution-gated. |

**The real frictions (budget for these, not show-stoppers):**

- **7-day provisioning expiry.** Build-and-install from Xcode, the app runs fine for 7 days, then one day you tap the icon and it won't launch. Fix: plug in (or stay on wireless), hit ⌘R in Xcode once, continue. Not a daily pain — call it a weekly ritual. Apple: *"Provisioning profiles will expire 7 days from issuance."*
- **10 App IDs per rolling 7-day window.** Jot uses 3 stable bundle IDs (`com.jot.mobile.Jot`, `.Keyboard`, `.Widget`). Re-signing doesn't consume new slots; you only burn App IDs when you add a new bundle ID. 3 out of 10 is comfortable headroom.
- **3 registered test devices per 7 days.** If you're testing on your own iPhone, you're at 1/3. Fine.
- **"3 active sideloaded apps" cap (forum-reported, not formal Apple policy).** Community observation that free accounts max out at 3 sideloaded apps on a device. Jot's keyboard + widget are *extensions embedded in the main app bundle* — they don't count as separate sideloaded apps. Jot sits at 1 slot.

**What paid ($99/yr) actually buys you here:**

- No weekly re-sign — provisioning profiles last a year. If re-running Xcode once a week bothers you, that's the real reason to pay.
- TestFlight / App Store submission (not in scope for this dev loop).
- Push Notifications at production scale (not used by Jot).
- More registered devices (not needed).

**To use the free team**, just sign in: Xcode → **Settings → Accounts → +** → Apple ID. In the project, leave `DEVELOPMENT_TEAM` empty in `Jot/project.yml` — Xcode picks your personal team automatically on first Run. You'll see `"(Personal Team)"` after your name on the target's Signing & Capabilities tab; that's correct.

**If you do want paid** for the one-year provisioning, sign up at [developer.apple.com/programs](https://developer.apple.com/programs/), then Xcode → Settings → Accounts → refresh. Drop your 10-character team ID (from [developer.apple.com/account](https://developer.apple.com/account/) → Membership) into `DEVELOPMENT_TEAM` in `Jot/project.yml` and re-run `./build.sh`.

### One-time wireless pairing

1. Plug the iPhone in via USB.
2. Xcode → **Window → Devices and Simulators** (⇧⌘2).
3. Select the phone → tick **"Connect via network"**.
4. Wait for the Wi-Fi icon to appear in the device row, then unplug.

Mac and iPhone must share a network that permits Bonjour/mDNS (fine on home Wi-Fi; often blocked on corporate/guest networks). If the device disappears, reboot the phone or the Mac's `mDNSResponder` — `sudo killall -HUP mDNSResponder`.

### Apple Intelligence + `FoundationModels` on a dev build

`FoundationModels` has no signing gate — a Developer Program-signed sideload hits the exact same code path as an App Store build. What it *does* need on device:

- Hardware: iPhone 15 Pro / 16 (any) / 17 (any), or M-series iPad.
- Apple Intelligence **finished downloading** (Settings → Apple Intelligence & Siri → On, then wait for the ~3 GB model pack to land). "Toggled on" ≠ "ready"; early launches can report `.unavailable` while models download.
- Supported region/language (US English works everywhere; check Settings for the current list outside the US).

If `SystemLanguageModel.default.availability` comes back anything other than `.available`, it's a device/state problem, not a signing problem.

### Keyboard "Allow Full Access" on a dev build

Works on dev provisioning — iOS doesn't gate Full Access to App Store builds. Two recurring irritations to budget for:

- **iOS silently revokes Full Access when the keyboard extension crashes.** First thing to re-check when the Jot keyboard stops appearing: Settings → General → Keyboard → Keyboards → Jot Dictation → Allow Full Access.
- **Re-running from Xcode sometimes toggles Full Access off** (about 1 run in 5). Not a bug in Jot's code.

### Command-line install via `devicectl`

`xcrun devicectl` ships with Xcode 15+ and is the Apple-blessed replacement for the older `ios-deploy` community tool.

Find and save your device identifier once:

```bash
xcrun devicectl list devices
# Copy the Identifier column from the row where Connection is "wireless" or "wired".
export JOT_DEVICE_ID=00008130-XXXXXXXXXXXXXXXX
```

Build, install, and launch from the terminal:

```bash
# Build for device
xcodebuild \
  -project Jot/Jot.xcodeproj \
  -target Jot \
  -sdk iphoneos \
  -configuration Debug \
  build 2>&1 | xcbeautify

# Locate the product
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -type d -name 'Jot.app' -path '*/Debug-iphoneos/*' -print -quit)

# Sideload
xcrun devicectl device install app --device "$JOT_DEVICE_ID" "$APP_PATH"

# Foreground it
xcrun devicectl device process launch --device "$JOT_DEVICE_ID" com.jot.mobile.Jot
```

(We use `-target Jot` rather than `-scheme Jot` because XcodeGen doesn't currently emit shared `.xcscheme` files. The scheme route works from the Xcode UI only.)

Tail logs from **Console.app** (select your iPhone in the sidebar, filter by process `Jot`, `JotKeyboard`, or `JotWidget`) or from the terminal with `idevicesyslog` (`brew install libimobiledevice`).

### `./dev.sh` — one command

`./dev.sh` wraps `xcodegen → xcodebuild → devicectl install → devicectl process launch`. Set `JOT_DEVICE_ID` once in your shell profile; every iteration after that is one command:

```bash
# First time only (or whenever you rotate phones)
export JOT_DEVICE_ID=$(xcrun devicectl list devices | awk '/wireless|wired/ {print $NF; exit}')

# Every iteration
./dev.sh
```

The script is intentionally thin — no retry logic, no daemon. If any step fails, it fails loudly and you fix it and re-run.

---

## Experiment 1 — Parakeet on ANE

**Before pressing Record the first time,** the app downloads the Parakeet TDT 0.6B v3 model (~1.25 GB). This happens on first launch. Keep the app foregrounded and on Wi-Fi until the "Model ready" state appears. Subsequent launches load from the device.

**Steps:**
1. Launch Jot. If permission sheets appear (Microphone), grant access.
2. Wait for the "Model ready" indicator (first launch only).
3. Tap **Record** in the main view. Speak a natural 10-second sentence.
4. Tap **Stop**.
5. Confirm the transcript appears in the UI within ~500 ms.

**Record in the scorecard:**
- Model download size (check via Xcode's Storage tool, or printed to stderr).
- Cold-start time from launch → "Model ready".
- Warm inference time for a 10 s clip on a subsequent recording (target ≤ 200 ms on A17 Pro).
- Transcription accuracy — pick a 10-word reference sentence and count substitutions/insertions/deletions.

**If it fails:** Screenshot any error banner. Check Xcode's console for `FluidAudio` logs. If the model won't load on the ANE, that's the Parakeet-on-mobile thesis failing; move to `SpeechAnalyzer.SpeechTranscriber` and reassess.

---

## Experiment 2 — Foundation Models cleanup

**Prerequisite:** iPhone must have Apple Intelligence enabled (Settings → Apple Intelligence & Siri → On). Requires supported device and English primary language.

**Steps:**
1. In Jot's Settings tab, toggle **Clean up transcription** on.
2. Optionally set a **Custom cleanup instruction** (e.g. "Make it casual and keep it short").
3. Record a deliberately rambly sentence:
   > "yeah yeah yeah so I was thinking like do you wanna, um, do you wanna grab coffee uh tomorrow around like maybe four or five I don't know whatever works for you"
4. Observe: raw transcript vs cleaned text. Cleaned text should arrive within ~2 s after transcription.
5. Toggle cleanup off, record again — confirm raw transcript is what pastes.

**Edge case to test:** With Apple Intelligence **disabled** (toggle it off in Settings → Apple Intelligence & Siri), the app should degrade gracefully — show the raw transcript, surface "cleanup unavailable" somewhere, and **not** crash.

---

## Experiment 3 — Hybrid keyboard smart-paste

This is the one. Read the pass criteria in `EXPERIMENTS.md` before starting so you know what a "pragmatic pass" vs "strict pass" looks like.

**One-time keyboard setup on the device:**
1. **Settings → General → Keyboard → Keyboards → Add New Keyboard → Jot Dictation**.
2. Tap the newly added Jot keyboard in the list, enable **Allow Full Access**. iOS will warn about clipboard reads — that's expected; the extension needs it.

**Action Button binding (Experiment 3 step 3):**
3. **Settings → Action Button → Shortcut → App → Jot → Dictate**. (The AppIntent `Dictate` must be exposed by the Jot target; if it doesn't appear, Experiment 3 and 4 are both blocked — flag to the team-lead.)

**Run the experiment:**
4. Open **Messages**, start a new thread to yourself.
5. Press **Action Button**. Speak a sentence. Press **Action Button** again to stop.
6. Return to Messages — note how many swipes/taps this takes.
7. Tap the Messages text field. The Jot keyboard should appear if it's the most recently used one; otherwise long-press the globe icon and pick it.
8. The keyboard's accessory bar should show a **"Fresh dictation"** affordance if less than 30 s has elapsed since step 6.
9. Tap **Paste transcription**. The transcript should insert into the text field via `textDocumentProxy.insertText()`.
10. Repeat with **Auto-paste** toggled on (in the main app's Settings). Confirm the keyboard auto-inserts on first appearance without needing a tap.

**What to watch for (failure modes):**
- **iOS "Paste from Jot?" banner every time.** If this shows on every insert, the keyboard-smart-paste pattern is dead. Note the exact iOS banner text in the scorecard.
- **Stale-clipboard detection.** Wait 45 s after dictating; the "Fresh dictation" banner should disappear.
- **Keyboard not appearing.** Confirm "Allow Full Access" is still on. iOS sometimes silently revokes it on crash.

---

## Experiment 4 — Action Button flow

**Steps:**
1. With the Action Button still bound to Jot's `Dictate` intent, start from the **Messages** app.
2. Press Action Button. Observe:
   - Does the Jot app bounce to full-screen, or does a Live Activity appear in the Dynamic Island?
   - How long from button press to mic actually hot? Target < 500 ms. Use Xcode's Instruments or a stopwatch; the audio engine prints a ready timestamp to the console.
3. Speak. Press Action Button again, or use whatever stop gesture the build ships with.
4. After stop, confirm you end up back in Messages with at most one extra swipe.

**Known open questions to capture in the scorecard:**
- Is the AppIntent running with `openAppWhenRun = false`? If the app still launches, why?
- Can audio be captured from an AppIntent background context without opening the app?
- What's the actual stop gesture — second Action Button, silence detection, on-screen button?

---

## Scorecard

Fill this in directly in `EXPERIMENTS.md` after you run each experiment.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `xcodebuild: error: Unable to find a destination matching...` with "iOS 26.2 is not installed" | Xcode has the iOS 26.2 SDK but not the runtime platform | Xcode → Settings → Components → install iOS 26.2, or run `xcodebuild -downloadPlatform iOS` |
| Build fails in `Shared/AppGroup.swift` with "not concurrency-safe" | Swift 6 strict concurrency on a global `UserDefaults` | Assigned to the shared-code lane owner; not a build-plumbing fix |
| App launches but no mic indicator when Record pressed | Microphone permission denied | Settings → Jot → Microphone |
| Keyboard extension crashes on first tap | App Group not matching between targets | Verify all three targets use `group.com.jot.mobile.shared` in entitlements |
| "Fresh dictation" banner never shows | Main app wrote to the wrong App Group, or keyboard is reading the wrong one | Check `AppGroup.identifier` matches in both sides |
