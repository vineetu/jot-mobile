# Shortcuts editor action catalog — why `Transcribe Audio with Jot` isn't appearing

**Investigator:** `shortcuts-deep-researcher` teammate
**Date:** 2026-04-20 (iOS 26.3.1 on device, Xcode 26.3 / build tools `17C529`)
**Code under review:** `Jot/App/Intents/{TranscribeAudioFileIntent,JotAppShortcuts,DictateIntent}.swift`, `Jot/project.yml`
**Build inspected:** `~/Library/Developer/Xcode/DerivedData/Jot-gfcxqoswmjnbmpaqgnmbdhfebdjo/Build/Products/Debug-iphoneos/Jot.app/Metadata.appintents/extract.actionsdata` (Apr 20 21:26, 4927 bytes, **contains both intents with well-formed metadata**)

---

## 1. TL;DR

**Confidence: 55%.** Our source and our DerivedData metadata look correct — `TranscribeAudioFileIntent` IS statically extracted into `Metadata.appintents/extract.actionsdata` with `isDiscoverable: true`, `openAppWhenRun: false`, a valid `parameterSummary`, and a registered `autoShortcuts` entry via `JotAppShortcuts`. That almost certainly rules out "metadata is malformed."

**The most likely remaining cause is a Shortcuts-daemon cache that hasn't refreshed for this app version.** iOS caches AppShortcut metadata keyed by bundle-ID + CFBundleVersion + build mtime; re-installing the same CFBundleVersion (ours is a frozen `"1"` / MARKETING_VERSION `"0.1.0"`) over an existing install often does not force `kbd`/`AppShortcuts` to re-index. **Exact fix to try first:**

1. **Fully delete Jot** from the iPhone (press-and-hold → Remove App → Delete App; don't just reinstall via `dev.sh`).
2. Reinstall via `./dev.sh`.
3. Launch Jot once, grant mic permission, let it idle for ~10 s.
4. Open Shortcuts → Apps tab → look for the "Jot" row. Both tiles (Dictate + Transcribe Audio) should appear there before they appear in the global "Add Action" search.
5. If step 4 fails, flip to **forced refresh**: temporarily bump `CURRENT_PROJECT_VERSION` in `project.yml` from `"1"` to `"2"` (and/or `MARKETING_VERSION` from `"0.1.0"` → `"0.1.1"`) so the daemon treats it as a new version. Rebuild + redeploy.

If **both** `Dictate` and `Transcribe Audio` are missing after that, the problem is install/indexing. If only `Transcribe Audio` is missing, the problem is that specific intent's shape (most likely `IntentFile` required-parameter handling on iOS 26.3 — see §6).

---

## 2. How Shortcuts discovery actually works — the mental model

Two surfaces, one pipeline:

### 2a. Static metadata extraction at build time

Xcode's `appintentsmetadataprocessor` build phase (`ExtractAppIntentsMetadata`) reads your `AppIntent`, `AppEntity`, `AppEnum`, and `AppShortcutsProvider` conformances directly from the compiled Swift and emits a binary plist called `Metadata.appintents/extract.actionsdata` plus `version.json` into the `.app` bundle. ([Apple: Dive into App Intents, WWDC22][4])

> "App Intents achieves an elegant developer experience by statically extracting information about intents, entities, queries, and parameters at build time. A tool parses compiler information to generate a Metadata.appIntents directory in your built product." ([Explore enhancements to App Intents, WWDC23][4])

For the Jot target the relevant build-phase invocation is:

```
appintentsmetadataprocessor \
  --module-name Jot --bundle-identifier com.jot.mobile.Jot \
  --compile-time-extraction --deployment-aware-processing --validate-assistant-intents
```

**This already works for us** — our extracted blob (inspected via `plutil -p`) contains:

| Key | DictateIntent | TranscribeAudioFileIntent |
|---|---|---|
| `identifier` | `DictateIntent` | `TranscribeAudioFileIntent` |
| `isDiscoverable` | true | true |
| `openAppWhenRun` | true | false |
| `supportedModes` | 2 | 1 |
| `parameterSummary.formatString` | `Dictate` | `Transcribe ${audioFile} with Jot` |
| `parameters` | 0 | 2 (audioFile: file + `public.audio`; cleanup: bool, default 0) |
| in `autoShortcuts[]` | yes | yes |
| phrase | `Dictate with ${applicationName}` | `Transcribe audio with ${applicationName}` |

Both are there. `autoShortcutProviderMangledName` resolves to `JotAppShortcuts`.

### 2b. Runtime indexing by the Shortcuts daemon

After the `.app` is installed, iOS's coreservices daemon reads `Metadata.appintents/extract.actionsdata` and hands it to the Shortcuts daemon (`shortcutsd`/`com.apple.shortcuts`) + the AppIntents background registry (`com.apple.appintents`). Those daemons build the in-memory catalog that powers:

- **Shortcuts app → Apps tab → <Your app>**: shows the list of `AppShortcut` tiles from `AppShortcutsProvider`
- **Shortcuts app → Add Action → search bar**: searches over *every* `isDiscoverable: true` `AppIntent` in every installed app's extracted metadata, plus the curated `AppShortcut` tiles
- **Spotlight search**: surfaces `AppShortcut` tiles as suggestions (iOS 17+) ([SwiftLee: App Intents Spotlight integration][5])
- **Siri**: matches the `AppShortcut.phrases` array against recognized utterances

**App launch semantics:** community writeups are inconsistent on whether first-launch is *required* for indexing. The authoritative signal in our log (`build-logs/device-launch-20260420-231037.log`) is that the Jot bundle identifier was launched on device at 23:10:37 via `devicectl device process launch`. So "app never launched" is **not** our failure mode — the app has been launched on this device. What *can* still be true:

- The daemon caches metadata keyed by `CFBundleVersion`. Ours is frozen at `"1"` — every rebuild ships the same version string. On iOS 17+ this has been observed to cause stale caches where the old metadata blob (from a prior install) is still served even after a reinstall.
- `updateAppShortcutParameters()` is the documented public API to force a refresh ([Apple: updateAppShortcutParameters()][6]). The docs note "the system calls this method periodically automatically, but you can force updates when you know data changed." However, this is intended for *dynamic-entity* refreshes (e.g., a new playlist appearing). For *new static intents*, it's not needed — static metadata is reread on install. It's cheap to call from `JotApp.init()` as a defensive belt-and-suspenders.

### 2c. What the Shortcuts editor sees vs. what the user sees

Three separate views that can diverge:

| View | Data source | What determines visibility |
|---|---|---|
| **Settings → Action Button → Shortcut → Jot** | AppShortcuts only | `AppShortcut` registration + `openAppWhenRun` filter |
| **Shortcuts app → Apps tab → Jot** | AppShortcuts only | `AppShortcutsProvider` registration + `isDiscoverable: true` |
| **Shortcuts app → Add Action → search "Transcribe"** | All AppIntents with `isDiscoverable: true` | global catalog |

If the action is missing from **Apps tab → Jot** but present in global search, that's a misconfigured `AppShortcut`. If it's missing from **both**, the app isn't indexed. We need to know which case we're in (see §7 Open Questions).

---

## 3. What we have vs. what's needed — concrete diff

Our current files are, **per the extracted metadata, correct**. The deltas listed below are low-probability but worth ruling out.

### 3a. `TranscribeAudioFileIntent.swift`

Already matches the canonical shape documented in `docs/research/shortcuts-transcribe-intent.md`:

- ✅ `struct TranscribeAudioFileIntent: AppIntent` (not public)
- ✅ `static let openAppWhenRun = false`
- ✅ `static let isDiscoverable = true`
- ✅ `@Parameter(..., supportedContentTypes: [.audio]) var audioFile: IntentFile`
- ✅ `parameterSummary = Summary("Transcribe \(\.$audioFile) with Jot") { \.$cleanup }` — the trailing closure puts `cleanup` under "Show More" per Apple's `ParameterSummary` DSL
- ✅ `func perform() async throws -> some IntentResult & ReturnsValue<String>`
- ✅ No `@MainActor` on the struct itself — matches DictateIntent's diagnosis of Action Button regression
- ✅ In the **main app target** (via `project.yml: targets.Jot.sources.[path: App]`) — not a framework, not an extension (satisfies the DTS constraint ([Apple DevForums #759160][3]: "those intents which back App Shortcuts cannot be in a framework"))

### 3b. `JotAppShortcuts.swift`

Already canonical:

- ✅ `struct JotAppShortcuts: AppShortcutsProvider`
- ✅ Single phrase per `AppShortcut`, each includes `\(.applicationName)` — required for auto-add-on-install ([Apple DevForums #707851][1])
- ✅ Both intents registered with `shortTitle` and `systemImageName`
- ✅ Provider is `struct`, not `public struct` — all community examples use bare `struct`; `public` has historically upset the metadata extractor ([stubbed in comment, corroborated by survey of sample code][2])

### 3c. `project.yml`

- ✅ `AppIntents.framework` linked as SDK dependency on Jot target
- ✅ All three targets (Jot, JotKeyboard, JotWidget) share the `Shared/` folder, but the Intents folder is only in Jot — correct
- ✅ `bundleIdPrefix: com.jot.mobile`, product bundle id `com.jot.mobile.Jot`
- ⚠️  **`MARKETING_VERSION: "0.1.0"` and `CURRENT_PROJECT_VERSION: "1"` never change across rebuilds.** This is the single most likely reason for stale catalog cache. Not technically a bug in our config — just a known footgun that bites hard when iterating on intents. Recommendation: bump `CURRENT_PROJECT_VERSION` every time we change an intent, or script it off `git rev-list --count HEAD`.

### 3d. What's **not** required (and we correctly don't do)

- ❌ No need for `AppIntentsPackage` conformance (that's only for intents defined in a separate Swift Package / framework — ours are in the main app target) ([Apple DevForums #759160][3])
- ❌ No need for an AppIntents extension (`.appintentsextension`) — Parakeet's ~1.25 GB model would exceed the extension's memory cap per the existing research doc
- ❌ No Info.plist key required for AppIntents in iOS 16+. `NSUserActivityTypes` is for legacy SiriKit only; `NSExtensionAttributes.IntentsSupported` is for `.intentsdefinition` files from the pre-AppIntents era. Neither applies here.
- ❌ No iOS 26 `AppIntentsPackageManifest.json` requirement. `Package.appintents` is a macOS/Mac Catalyst concept; iOS uses `Metadata.appintents/` directly. Our build produces the iOS shape correctly.

---

## 4. Verification commands

Run in order. Each step either confirms or falsifies a hypothesis.

### 4a. Confirm the bundle on device actually has the new metadata

```bash
# From Mac, pull the installed app's metadata blob. devicectl doesn't
# directly expose app bundle internals, so the easiest path is:
#   (a) reinstall fresh
./dev.sh
#   (b) verify the build product on disk was just updated
stat -f "%Sm %z" ~/Library/Developer/Xcode/DerivedData/Jot-*/Build/Products/Debug-iphoneos/Jot.app/Metadata.appintents/extract.actionsdata
#   (c) confirm both intents are in the local blob (sanity)
plutil -p ~/Library/Developer/Xcode/DerivedData/Jot-*/Build/Products/Debug-iphoneos/Jot.app/Metadata.appintents/extract.actionsdata | grep -E '"(DictateIntent|TranscribeAudioFileIntent)"'
```

Expected: both identifiers appear, file is > 4000 bytes, mtime is within the last few minutes of the install.

### 4b. Tail the Shortcuts daemon on device (paired + trusted Mac)

```bash
# Streaming predicate-filtered log from the attached iPhone.
# Subsystems to watch: com.apple.appintents, com.apple.shortcuts, com.apple.siri.shortcuts
sudo log stream --device \
  --predicate 'subsystem IN { "com.apple.appintents", "com.apple.shortcuts", "com.apple.siri.shortcuts" }' \
  --level debug
```

(Ctrl-C after ~30 s while interacting with Shortcuts.app on the phone.) Look for:
- `Ingesting metadata for com.jot.mobile.Jot` — confirms daemon saw our install
- `AppShortcut registered: DictateIntent` / `TranscribeAudioFileIntent` — confirms both were indexed
- Any lines with `error`, `validation`, `rejected`, `malformed`

Absence of the "Ingesting" line after an install is the **smoking gun** for the CFBundleVersion-stale-cache hypothesis.

### 4c. Test the paste chain from inside Shortcuts

Without editing code, build the following Shortcut by hand on the phone:

```
Record Audio                       (built-in; prompts for mic on first run)
  ↓  (magic variable: Recording)
Transcribe Audio with Jot          (if the action is selectable)
  Audio File: Recording            (default-linked from prior step)
  Clean Up Transcript: Off
  ↓  (magic variable: Transcribed Text)
Copy to Clipboard                  (built-in)
  Input: Transcribed Text
```

Then chain `Paste` — it's *not* a built-in Shortcuts action; to "paste at cursor" the user configures a **Hand Off (end-of-shortcut)** flow or pastes manually. The iOS Shortcuts runtime cannot synthesize a global `⌘V` into an arbitrary app. Practical user-facing shape is usually:

```
Record Audio → Transcribe Audio with Jot → Copy to Clipboard
```

…and the user pastes in the target app. (Calling the action from Messages with "Run Shortcut" leaves Messages in the foreground; they long-press the compose field and paste.)

### 4d. `plutil`/`strings` sanity checks on the bundle

```bash
# Confirm appintentsmetadataprocessor ran without errors in the most recent build
grep -iE 'appintent|Shortcuts metadata|error|malformed' \
  build-logs/$(ls -t build-logs/ | head -1)

# Confirm the mangled type names round-trip through xcrun swift-demangle
plutil -extract actions.TranscribeAudioFileIntent.mangledTypeName raw \
  ~/Library/Developer/Xcode/DerivedData/Jot-*/Build/Products/Debug-iphoneos/Jot.app/Metadata.appintents/extract.actionsdata \
  | xargs -I{} xcrun swift-demangle {}
# Expect: Jot.TranscribeAudioFileIntent
```

---

## 5. Paste workflow — user instructions

Jot's design goal is "user stays in Messages, presses Action Button, speaks, transcript appears at the cursor." There are **two** shapes for that on iOS 26, only one of which depends on our new intent:

### Shape A — Foreground via DictateIntent (already shipping)

User binds the Action Button directly to Jot's `DictateIntent`. Jot briefly foregrounds, captures mic, transcribes, and publishes to clipboard. User swipes back to Messages and long-pastes. This is what's already wired in `Settings → Action Button → Shortcut → Jot → Dictate`.

### Shape B — Chained via Shortcuts + TranscribeAudioFileIntent (new, the thing we're debugging)

User builds this Shortcut manually in Shortcuts.app:

```
1. Record Audio
     - When Run: Start Recording (no prompt)
     - Audio Quality: Normal
     - Start Immediately: On

2. Transcribe Audio with Jot
     - Audio File: (magic variable from step 1)
     - Clean Up Transcript: Off (or On if they want LLM cleanup)

3. Copy to Clipboard
     - Input: (magic variable from step 2 — a String)
```

Bind this Shortcut to the Action Button (`Settings → Action Button → Shortcut → My Shortcuts → <this shortcut>`). Now:

- Press Action Button in Messages → Record Audio prompts the user in a sheet ("Stop" button) → they speak and tap Stop → our intent runs headlessly (no app bounce) → transcript goes to clipboard → they long-press the compose field → Paste.

The key user-facing thing is that **there is no synthesized global paste in Shortcuts** on iOS. The clipboard is the handoff mechanism; the user tap-pastes. This matches the existing DictateIntent UX.

**Caveat:** the Shortcuts `Record Audio` action is the one documented in forum #756507 as still requiring a *foreground app* to own the mic — but that requirement applies to apps trying to start audio recording **from their own intent**. `Record Audio` is Shortcuts.app's own built-in; Shortcuts itself foregrounds (briefly, as a sheet) to host the mic. Our `TranscribeAudioFileIntent` then receives an already-decoded file, so we sidestep the restriction.

---

## 6. Open questions / risks

Confidence-labeled.

### Q1 — [Unknown] Does `DictateIntent` appear in Shortcuts.app for the user right now?

Critical signal. If yes, only `TranscribeAudioFileIntent` is broken, which narrows to intent-specific causes (IntentFile parameter, `openAppWhenRun = false`, `supportedModes = 1`). If no, neither is indexed, which points to install/cache. **Please ask Tejas before making code changes.**

### Q2 — [Possible, 30%] iOS 26.3 regression on required `IntentFile` parameters

`TranscribeAudioFileIntent` has `isOptional: false` on its `audioFile: IntentFile` parameter. Historically, Shortcuts sometimes hides actions with required non-entity parameters from the "Add Action" global search and only surfaces them when the user is editing an *existing* shortcut step that can supply the value. Community reports ([Apple DevForums #713178][7]) mention "App Shortcuts with parameterized phrases" issues on iOS 17. We couldn't definitively confirm or refute for iOS 26.3 in 25 minutes.

**Mitigation to try (cheap):** add a default by making `audioFile` optional (`IntentFile?`), or require prompting when not piped. That changes the intent semantics, though — need design consent.

### Q3 — [Possible, 25%] `supportedModes = 1` filters the intent out of the Shortcuts editor in some views

Our extract shows `DictateIntent.supportedModes = 2` (foreground) and `TranscribeAudioFileIntent.supportedModes = 1` (background). We didn't find Apple documentation for the bitfield. This isn't something we can adjust — `supportedModes` is derived from `openAppWhenRun` — but it's one axis where the two intents differ, so worth naming.

### Q4 — [Unknown] Settings.app toggle

Settings → Shortcuts on iOS 26 has a small set of toggles ("Allow Running Scripts", "Allow Sharing Large Amounts of Data", etc.). None are documented to gate 3rd-party AppIntent visibility, but we couldn't exhaustively verify.

### Q5 — [Likely, 20%] Post-install indexing delay

First-install AppShortcuts indexing in iOS 17/18 has been reported to take up to ~60 seconds after install + first launch. If Tejas searched immediately after `./dev.sh`, that could be the whole thing. Easy to rule out: wait 2 minutes, restart Shortcuts.app, try again.

### Q6 — [Ruled out] Packaging / framework linkage

Not our failure mode — both intents are in the main app target per `project.yml` and the extractor confirms this in `fullyQualifiedTypeName: "Jot.TranscribeAudioFileIntent"`.

### Q7 — [Ruled out] Metadata extraction failure

Not our failure mode — we have fresh `extract.actionsdata` at 4927 bytes containing both intents. No errors in recent build logs.

### Q8 — [Ruled out] App never launched

Not our failure mode — `build-logs/device-launch-20260420-231037.log` confirms the app was launched on device 30 min before the user's report.

---

## 7. Execution plan for `intent-widget-engineer-2`

**Do these in order. Stop after each step and have Tejas check Shortcuts.app.**

### Step 1 — Force a version bump (zero-risk, high-signal)

Edit `Jot/project.yml`:

```yaml
settings:
  base:
    ...
    CURRENT_PROJECT_VERSION: "2"   # was "1"
    MARKETING_VERSION: "0.1.1"     # was "0.1.0"
```

Then: `./build.sh && ./dev.sh`.

Ask Tejas to **fully delete** Jot from the phone first (press-and-hold → Remove App → Delete App), then reinstall via `./dev.sh`, launch Jot once, wait 15 s, open Shortcuts.app.

Verify:
- Shortcuts → Apps tab → "Jot" row should appear with *both* tiles: Dictate + Transcribe Audio
- Shortcuts → Add Action → search "Transcribe" → action should appear

If this resolves it, keep the version bump and add a TODO to make `CURRENT_PROJECT_VERSION` auto-derive from git commit count (matching the pattern in `macOS Jot`'s `scripts/release.sh`).

### Step 2 — If Step 1 doesn't resolve it, add a defensive `updateAppShortcutParameters()` call

In `Jot/App/JotApp.swift`, during app launch (after the mic permission prompt has been handled), call:

```swift
Task { await JotAppShortcuts.updateAppShortcutParameters() }
```

This forces the daemon to re-read the `AppShortcutsProvider`. Cheap, idempotent, documented by Apple.

### Step 3 — If still missing, make `audioFile` optional

Change `TranscribeAudioFileIntent`:

```swift
@Parameter(
    title: "Audio File",
    description: "...",
    supportedContentTypes: [.audio]
)
var audioFile: IntentFile?
```

And handle the nil case inside `perform()` with `requestValueDialog(...)`. This is a last-resort workaround for the "required file parameter hidden from global search" hypothesis (§6.Q2). It changes the intent's UX — discuss with Tejas before committing.

### Step 4 — If STILL missing, run the log-stream command from §4b and share output

```bash
sudo log stream --device --predicate \
  'subsystem IN { "com.apple.appintents", "com.apple.shortcuts", "com.apple.siri.shortcuts" }' \
  --level debug
```

Tap around Shortcuts.app for ~30 s. Save output to `build-logs/shortcuts-indexing-<timestamp>.log` and post findings back. At that point we're out of statically-researchable options and need daemon-level data.

### Do NOT do any of this without confirming §6.Q1 first

Before any of these code changes, ask Tejas: **"Does `Dictate` appear in Shortcuts.app → Apps → Jot, and in the global 'Add Action' search?"** That one binary answer splits the problem space in half.

---

---

## 8. Paste workflow — corrected (urgent insert, 2026-04-20)

**Team-lead previously asserted that a built-in "Paste" action exists in iOS Shortcuts. That is wrong.** User confirmed: the action is not in the Shortcuts editor.

### Definitive answer (confidence: 95%)

**There is no built-in Shortcuts action that injects text into the frontmost app's focused text field on iOS.** This applies to iOS 26 and every prior iOS release that's shipped Shortcuts (iOS 13+). The limitation is **deliberate iOS sandboxing**, not a missing feature.

What exists in the Clipboard category:
- **Get Clipboard** — reads whatever is currently on the system pasteboard and returns it as a variable. Does not paste anywhere.
- **Copy to Clipboard** — writes a value to the pasteboard. Does not paste anywhere.

What does **not** exist:
- **No "Paste" / "Paste Text" / "Insert Text" action.** You cannot synthesize a `⌘V` or simulate a keyboard tap into another app from Shortcuts.
- No "Type Text" action in Scripting category (unlike macOS Automator which has "Type Keystrokes" via Accessibility).
- No AppIntent protocol that grants focused-field write access to third-party apps.

Confirmed by:
- Apple Support Community #254714961: user asks "Is it true that Shortcuts cannot Paste?" — community consensus cites sandboxing; **no Apple rep contradicts it.** ([1][paste-1])
- Automators forum thread #8888: "Direct automation of pasting text into other apps' input fields is not possible on iOS due to system-level sandboxing." ([2][paste-2])
- Apple's official Shortcuts Action Reference catalog (URL in Team Lead's question) lists only `Get Clipboard` and `Copy to Clipboard` under Clipboard, plus `Set Clipboard at Date` — no paste action. ([3][paste-3])
- iOS 18 and iOS 26 release-note surveys: no new paste-related action introduced.

### What this means for Jot's UX

The end-to-end chain `Record Audio → Transcribe Audio with Jot → user-sees-text-in-their-app` **cannot** be a single atomic Shortcut. The best the Shortcuts runtime alone can deliver is:

```
Record Audio → Transcribe Audio with Jot → Copy to Clipboard
```

…then the user long-presses the target app's text field and taps **Paste** from the callout menu. One extra tap after the Shortcut completes.

### The two paths forward

**Path A — accept the extra tap (ship-today):**

Document the canonical Shortcut in the Jot README / in-app Help:

> 1. Open Shortcuts → `+` → Add Action
> 2. Record Audio → Transcribe Audio with Jot → Copy to Clipboard
> 3. Settings → Action Button → Shortcut → (this shortcut)
> 4. In Messages / Notes / wherever: press Action Button, speak, tap Stop.
> 5. Long-press the text field → **Paste**.

This is the minimum-viable flow. The Action Button already foregrounds Shortcuts (which briefly foregrounds itself to host `Record Audio`); the transcript lands on the clipboard; the user taps once to paste. This is exactly the UX Apple's own Translate and Live Text features ship with.

**Path B — zero-tap via `JotKeyboard` (higher ambition, already half-built):**

Jot already ships a **custom keyboard extension** (`JotKeyboard`, `project.yml` → `type: app-extension` with `com.apple.keyboard-service`). The keyboard layer is the *only* iOS surface with blessed access to inject text into the focused field of an arbitrary third-party app. The pattern:

1. `TranscribeAudioFileIntent` writes the transcript to the App Group's shared `ClipboardHandoff` (existing code — `Shared/ClipboardHandoff.swift`).
2. `JotKeyboard`, when selected as the active keyboard, surfaces a **smart-paste banner** above the suggestion row whenever a fresh handoff appears: "Paste transcript: *[first 40 chars…]*". One tap → `textDocumentProxy.insertText(fullTranscript)` → done, zero app-switches.

This is the native-iOS equivalent of Jot-for-macOS's synthetic `⌘V` delivery. It's the only architecturally correct way to deliver the "text appears where my cursor is without me doing anything else" invariant on iOS. It **does** require the user to switch to JotKeyboard as their active keyboard (swipe up the globe icon) in the moment — and accept `RequestsOpenAccess: true`, which is already in our `Keyboard-Info.plist`.

### Recommendation

Ship Path A now (documented user shortcut + clipboard handoff), and escalate Path B to a near-term design conversation with Tejas. The keyboard extension is already wired, has open access, and has an App Group shared with the main app — the work is smart-paste banner UI + a fresh-transcript handoff-event subscription in `JotKeyboardViewController`. This is days of work, not weeks.

[paste-1]: https://discussions.apple.com/thread/254714961
[paste-2]: https://talk.automators.fm/t/paste-text-into-app-input-field/8888
[paste-3]: https://support.apple.com/guide/shortcuts/action-reference-apdd80b6f64f/ios

---

## Sources

- [Apple DevForums #707851 — Implemented AppIntent doesn't show in Shortcuts app][1]
- [Apple DevForums #722169 — App Intent Not Appearing in Shortcuts App (target membership)][2]
- [Apple DevForums #759160 — AppIntents don't show up in Shortcuts app when in SPM (DTS: "those intents which back App Shortcuts cannot be in a framework")][3]
- [Apple WWDC23 — Explore enhancements to App Intents (metadata extraction mental model)][4]
- [SwiftLee — App Intents Spotlight integration using Shortcuts][5]
- [Apple Docs — AppShortcutsProvider.updateAppShortcutParameters()][6]
- [Apple DevForums #713178 — App Shortcuts with parameterized phrases][7]
- [Apple DevForums #692738 — Intents not showing up in Shortcuts app][8]
- [Apple DevForums #764239 — App's shortcut actions not showing on iOS 18 (unanswered)][9]
- [Apple DevForums #756507 — "You cannot trigger an audio recording from the Shortcuts app" (DTS, 2024) — referenced in DictateIntent's doc comment][10]
- [Marc Palmer — Confusing appintentsmetadataprocessor errors in Xcode 16][11]
- [Shaun Hevey — Fixing custom Shortcuts actions not showing][12]
- [Adam Russell — AppIntent Not Showing in Shortcuts App][13]
- [UseYourLoaf — Getting Started With App Intents][14]

[1]: https://developer.apple.com/forums/thread/707851
[2]: https://developer.apple.com/forums/thread/722169
[3]: https://developer.apple.com/forums/thread/759160
[4]: https://developer.apple.com/videos/play/wwdc2023/10103/
[5]: https://www.avanderlee.com/swiftui/app-intents-spotlight-integration-using-shortcuts/
[6]: https://developer.apple.com/documentation/appintents/appshortcutsprovider/updateappshortcutparameters()
[7]: https://developer.apple.com/forums/thread/713178
[8]: https://developer.apple.com/forums/thread/692738
[9]: https://developer.apple.com/forums/thread/764239
[10]: https://developer.apple.com/forums/thread/756507
[11]: https://marcpalmer.net/changes-in-app-intents-pre-processing-causing-confusing-errors-in-xcode-16/
[12]: https://shaunhevey.com/posts/fixing-custom-shortcuts-actions-not-showing-up-in-the-ios-shortcuts-app/
[13]: https://www.adamrussell.com/appintent-not-showing-in-shortcuts-app
[14]: https://useyourloaf.com/blog/getting-started-with-app-intents/
