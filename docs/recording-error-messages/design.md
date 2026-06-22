# Recording-start error messages — design (discovery only)

**Status:** Design / discovery. NO product code changed. Owner gates implementation separately.
**Author:** scoping pass, 2026-06-20.
**Problem (owner):** When recording can't start, Jot shows technical/implementation-detail
text the user can't parse. Flagship case: user is on a phone/Zoom/FaceTime call (another app
holds the mic), taps dictate, and gets raw CoreAudio gibberish instead of a plain
*"Can't record — another app (like a call) is using the microphone."*

Confidence legend (house style): **Confirmed** (observed in code / Apple primary source),
**Likely** (strong inference), **Possible** (partial evidence), **Unknown** (no evidence).

---

## 0. TL;DR

1. The error **strings already exist** and several are already friendly
   (`.micUnavailable`). The real problems are: (a) two cases leak raw CoreAudio
   `localizedDescription` into the user's face (`.engineStart`, `.sessionConfiguration`);
   (b) surfaces are **inconsistent** — the hero shows the enum string, the keyboard shows a
   single hardcoded `"Couldn't start mic - tap again"` that **erases which error fired**, and
   the foreground alert prefixes the enum string with its own phrasing.
2. **The flagship "on a call" case does NOT reliably reach the friendly `.micUnavailable`
   string on every surface.** `.micUnavailable` IS the case Jot's preflight is *designed* to
   throw for a held mic (the 0-channel/0-Hz check, `RecordingService.swift:606`), and the
   hero/foreground-alert render it correctly. BUT the **keyboard banner flattens every
   start failure — including `.micUnavailable` — into `"Couldn't start mic - tap again"`**
   (`JotApp.swift:1047`), which is the surface the owner most likely sees (you tap dictate
   from the keyboard while on a call). So the user on a call may get a vague banner, and in
   the residual cases where the mic-busy state slips past the preflight into `.engineStart`
   / `.sessionConfiguration`, they get raw CoreAudio text.
3. **Fix shape:** add ONE `userFacingMessage: String` (Foundation-only) to `RecordingError`
   that maps every case — and, for `.engineStart`/`.sessionConfiguration`, the underlying
   NSError domain/code — to a clear, actionable sentence. Make **every** surface render
   `userFacingMessage` (hero, foreground alert, keyboard banner, intents), deleting the
   per-surface ad-hoc strings. Strengthen the mic-busy *detection* so the call case lands on
   `.micUnavailable` (or a new mic-busy message) rather than a raw-error path.
4. **Schema impact: none** (Confirmed — no `@Model` types touched).

---

## 1. Inventory — every `RecordingError` case → current string → surfaces → verdict

`RecordingError` is defined at `App/Recording/RecordingService.swift:9–40`, with three
user-facing string sources:
- `errorDescription` (`:29–39`) — `LocalizedError`, used by main-app/hero/watch alerts.
- `localizedStringResource` (`:3059–3076`) — AppIntents/Shortcuts surfaces.
- `errorCode` / `errorDomain` (`:3024–3052`) — stable NSError bridge for logs/diagnostics.

| Case | `errorDescription` (`:29–39`) | `localizedStringResource` (`:3059–3076`) | Surfaces that show it | Verdict |
|---|---|---|---|---|
| `.alreadyRunning` | "A recording is already in progress." | "Jot is already recording. Stop the current recording before starting another." | hero alert, foreground alert, intents | **OK-ish** (rare; user has no real action — a race) |
| `.notRunning` | "No recording is in progress." | "No Jot recording is in progress." | intents (stop leg) | OK (internal-ish) |
| `.converterUnavailable` | "Could not build the 16 kHz audio converter." | "Jot could not prepare the 16 kHz audio converter. Restart the app and try again." | hero, foreground, intents | **GIBBERISH** ("16 kHz audio converter" is an impl detail) |
| `.sessionConfiguration(Error)` | "Audio session error: \\(error.localizedDescription)" | "Audio session could not be configured: \\(error.localizedDescription)" | hero, foreground, intents | **GIBBERISH** (interpolates raw CoreAudio NSError, e.g. "The operation couldn't be completed. (com.apple.coreaudio… error 561145187.)") |
| `.engineStart(Error)` | "Audio engine failed to start: \\(error.localizedDescription)" | "Audio engine failed to start: \\(error.localizedDescription)" | hero, foreground, intents | **GIBBERISH — the flagship offender.** This is the exact "Audio engine failed to start: … com.apple.coreaudio…" banner from issue #3, and a residual landing spot for the on-a-call case |
| `.micUnavailable` | "Microphone is busy — another app is using it. Try again in a moment." | (same) | hero, foreground — but **NOT** the keyboard (flattened) | **FRIENDLY already** — but doesn't name the *call*, and the keyboard never shows it |
| `.warmYieldRestoreFailed` | "Warm-resume audio-session restore failed." | "Warm-resume audio-session restore failed." | **never surfaced** (internal control-flow only, `:23–27`, caught at `:574`) | N/A — keep internal |

**Per-surface display (Confirmed via code read):**

| Surface | File:line | What it renders | Own string vs enum |
|---|---|---|---|
| Hero alert — start | `RecordingHeroView.swift:874` | `"Could not start recording: \(error.localizedDescription)"` (title `"Recording error"`, `:368`) | enum, **prefixed** |
| Hero alert — resume | `RecordingHeroView.swift:916` | `"Could not resume: \(error.localizedDescription)"` | enum, prefixed |
| Hero alert — stop/transcribe | `RecordingHeroView.swift:964` | `"Dictation failed: \(error.localizedDescription)"` | enum, prefixed |
| Foreground auto-start alert | `JotApp.swift:1057–1058` (title `"Couldn't start recording"`, `:378`) | `(error as? LocalizedError)?.errorDescription ?? "Couldn't start recording. Try again."` | enum, with generic fallback |
| **Keyboard banner** | `JotApp.swift:1047` → `surfaceAutoStartBanner` (`:779–792`) → `AppGroup.lastDictationStatusMessage` → keyboard reads at `JotKeyboardViewController.swift:~2547` | **hardcoded** `"Couldn't start mic - tap again"` — **error identity LOST** | **own string, ad-hoc** |
| Keyboard banner — mic perm | `JotApp.swift:835` | `"Tap to grant mic access in Settings"` | own (decent) |
| Keyboard banner — pipeline | `JotApp.swift:866` | `"Still finishing your last dictation - tap again"` | own (decent) |
| Intents (Shortcuts/Action Button) | `DictateIntent.swift` / `RecordAndTranscribeIntent.swift` — START leg does **not** start the mic inline; it bounces to `triggerAutoStart` (post issue-#3 fix). STOP leg rethrows → Shortcuts renders `localizedStringResource` | enum (`localizedStringResource`) | enum |

**Consistency verdict:** **Inconsistent.** The same underlying failure renders as four
different texts depending on surface, and the keyboard — the most likely surface for the
flagship case — discards the error entirely. Hero/foreground inherit the enum string but
each adds its own prefix.

**Not a `RecordingError` surface (Confirmed — flag honestly):**
- **Watch `RecordingView`** uses `WatchRecorder.shared`, **not** `RecordingService`
  (`Watch/Views/RecordingView.swift:160` `try recorder.start()`). Its **start** path
  *swallows* the error and just `dismiss()`es (`:163–165`) — no message at all. The
  `saveError` alert (`:124–134`, title `"Couldn't save recording"`, body
  `error.localizedDescription` from `:183`) is on the **save/transfer** path, a different
  error domain. **The watch is out of scope for `RecordingError` start-message work** but is
  worth an owner note: a watch start failure shows the user *nothing*.

---

## 2. The mic-busy trace — which error actually fires on a call?

### 2.1 The start path (Confirmed — code)

`start()` (`RecordingService.swift:555`) on a cold start:
1. `configureSession()` (`:591`) → `setCategory(.record, .measurement, [.mixWithOthers])`
   (`:1627`) → `setActive(true)` (`:1633`). **`.mixWithOthers` is the key:** with it,
   `setActive(true)` and `engine.start()` both **succeed even while another app holds the
   mic** — Jot's own comments state this at `:597–605` and `:15–21`. If `setActive` *did*
   throw → `.sessionConfiguration` (`:1649`).
2. Mic preflight: `let hardwareFormat = input.outputFormat(forBus: 0)` (`:595`), then
   `guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0` (`:606`). **When a
   call/Zoom holds the mic exclusively, iOS reports the input bus as 0 channels / 0 Hz**, so
   this guard fails → `restoreSession()` + `throw .micUnavailable` (`:608–609`). **This is
   the intended catch for the flagship case** (Confidence: **Confirmed** by the code +
   comment; the *on-device* reality that a call always yields 0-channels is **Likely**, see
   §2.3).
3. Converter build (`:612`) → `.converterUnavailable` if nil.
4. `engine.prepare(); try engine.start()` (`:629–630`) → `.engineStart(error)` (`:646`),
   with the underlying CoreAudio domain/code now **logged** (`:638–641`, added during the
   issue-#3 work).

### 2.2 So which one fires on a call?

- **Designed answer:** `.micUnavailable`, via the 0-channel preflight (`:606`). On the hero
  and foreground alert this already renders the friendly *"Microphone is busy — another app
  is using it…"* — **good**.
- **The owner's bad experience is explained by two gaps:**
  1. **Keyboard flattening (Confirmed):** even when `.micUnavailable` fires, the keyboard
     banner path (`JotApp.swift:1047`) shows `"Couldn't start mic - tap again"` — never the
     friendly string. Tapping dictate *from the keyboard while on a call* is the most likely
     flagship trigger, so the owner sees the vague banner.
  2. **Raw-error residual (Possible→Likely):** if a call/interruption state slips **past**
     the 0-channel preflight (e.g. the bus reports a non-zero stale format but the I/O still
     can't start, or `setActive` throws under certain interruption states), the failure lands
     on `.engineStart` or `.sessionConfiguration`, which interpolate raw CoreAudio text →
     the "Audio engine failed to start: … com.apple.coreaudio…" gibberish.

### 2.3 The CoreAudio codes involved (Confirmed — Apple docs + repo doc)

There is **no single code** that means "another app holds the mic." Observed/relevant codes:
- `561145187` = `'!rec'` = `AVAudioSession.ErrorCode.cannotStartRecording`
  ([Apple docs](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)).
- `561015905` = `'!pla'` = `cannotStartPlaying` (the code seen in Apple DTS thread 756507 —
  *not* a recording code; per `docs/carplay/issue-3-mic-rootcause.md:58`).
- `560557684` = `'!int'` = session interrupted — reported for `setActive(true)` failing
  **after a phone call** while backgrounded
  ([Apple forum 813278](https://developer.apple.com/forums/thread/813278)).
- `560030580` = `'what'` — generic invalid-state, seen in the Action-Button `AURemoteIO`
  trace (`docs/carplay`).

**Design consequence (Confirmed reasoning):** **do NOT switch user copy on the CoreAudio
numeric code** — it varies by route (foreground vs background, call vs Siri vs another voice
app, iOS build) and is unstable. The **reliable** mic-busy signal Jot already has is the
**0-channel/0-Hz input preflight**. Keep that as the primary detector; treat the raw-error
paths as a *fallback* that still needs a friendly generic message, optionally enriched by a
small allowlist of known "mic conflict" codes (`561145187`, `560557684`, `561015905`) to
**upgrade** an `.engineStart`/`.sessionConfiguration` into the mic-busy message.

### 2.4 What needs on-device confirmation (Unknown without a device)

- **Confidence the call case always hits the 0-channel preflight: Likely, not Confirmed.**
  The simulator cannot model the background-mic/interruption gate (it has no real mic — per
  `issue-3-mic-rootcause.md:137`). **Owner must reproduce on a real device**: start a phone
  call (and separately a FaceTime and a Zoom call), tap dictate from (a) the keyboard, (b)
  the in-app FAB, (c) the Action Button, and read the Console log line emitted at `:607`
  (`"Mic unavailable on start — input reports channels=… sampleRate=…"`) vs the `:639`
  (`"engine.start() FAILED — domain=… code=…"`) vs `:1645` (`configureSession FAILED…`).
  That log triage tells us, per call type, **exactly which case fires** and **which CoreAudio
  code** — converting §2.2/§2.3 from Likely to Confirmed and sizing the allowlist in §3.

---

## 3. Proposed centralized message mapping

### 3.1 Where it lives

Add a single computed property on the error type:

```
// RecordingService.swift, on RecordingError — Foundation-only, NO SwiftUI/MLX.
var userFacingMessage: String { … }
```

- **Foundation-only** so the keyboard (≤60 MB, no SwiftUI/MLX — `Jot/CLAUDE.md`) can call it.
  `RecordingError` already lives in `RecordingService.swift`, which the keyboard does **not**
  link. **Decision needed (open Q1):** either (a) move just the `RecordingError` enum +
  `userFacingMessage` into a tiny Foundation-only file under `Jot/Shared/` that both targets
  compile, OR (b) keep the enum where it is and give the keyboard a **mirror** of the
  string-mapping function keyed off the bridged `errorDomain`+`errorCode` it already receives
  via `AppGroup.lastDictationStatusMessage`. **Recommendation: (a)** — one source of truth;
  the enum is already `CustomNSError` with a stable domain/code contract (`:3024–3052`), so
  moving it is low-risk and kills the divergence permanently.
- `errorDescription` and `localizedStringResource` then both return `userFacingMessage`
  (collapse the three string tables into one), so AppIntents and `LocalizedError` callers get
  the same text for free.

### 3.2 The mapping (copy is DRAFT — see open questions)

| Case (+ condition) | Proposed user-facing message |
|---|---|
| `.micUnavailable` **OR** `.engineStart`/`.sessionConfiguration` whose NSError code ∈ {561145187, 560557684, 561015905} | **"Can't record — another app (like a call) is using the microphone. Try again when it's free."** |
| mic permission denied (today handled pre-throw at `JotApp.swift:835`; fold into the same mapping so all surfaces match) | **"Jot needs microphone access. Turn it on in Settings › Jot."** |
| `.engineStart`/`.sessionConfiguration` — any **other** code (not in the mic-busy allowlist) | **"Couldn't start recording. Close any app using audio and try again."** (generic, NO raw CoreAudio text) |
| `.converterUnavailable` | **"Couldn't start recording. Restart Jot and try again."** |
| `.alreadyRunning` | **"Jot is already recording."** (or suppress — it's a UI race; open Q3) |
| `.notRunning` | **"No recording is in progress."** |
| `.warmYieldRestoreFailed` | (never surfaced — keep internal, no user string) |

**Hero / call-busy refinement:** the flagship message names "a call" explicitly per the
owner's wording. If on-device triage (§2.4) shows the held-mic case sometimes lands on
`.engineStart` with a code **not** in the allowlist, widen the allowlist rather than the copy.

### 3.3 How each surface adopts it

- **Hero** (`RecordingHeroView.swift:874/916/964`): replace
  `"Could not start recording: \(error.localizedDescription)"` with
  `(error as? RecordingError)?.userFacingMessage ?? error.localizedDescription`. **Drop the
  "Could not start recording:" prefix** so the friendly sentence stands alone (it already
  reads as a complete message). Resume/stop prefixes can stay if owner prefers, but should
  also stop interpolating raw CoreAudio text.
- **Foreground alert** (`JotApp.swift:1057`): set
  `dictateAutoStartError = (error as? RecordingError)?.userFacingMessage ?? "Couldn't start recording. Try again."`.
- **Keyboard banner** (`JotApp.swift:1046–1051`): replace the hardcoded
  `"Couldn't start mic - tap again"` with the **same `userFacingMessage`** so the keyboard
  finally shows the real reason (e.g. the call message). The banner is short-lived (~2.5s,
  `JotKeyboardViewController.swift`) — keep messages ≤ ~1 sentence (they already are). NOTE
  the documented §5.10 limitation (banner invisible while keyboard is collapsed) is a
  **separate** bug — out of scope here; flag it so QA doesn't think this fix failed.
- **Intents**: nothing to change beyond §3.1 — collapsing `localizedStringResource` into
  `userFacingMessage` makes the Shortcuts surface match automatically.
- **Watch**: out of scope (§1) — separate error domain; owner-note only.

### 3.4 Strengthen detection so the call case lands right

- **Keep** the 0-channel/0-Hz preflight (`:606`) as the **primary** mic-busy signal — it's
  the most reliable, route-independent tell Jot has, and it already throws `.micUnavailable`.
- **Add** the NSError-code allowlist (§3.2 row 1) so a call state that slips past the
  preflight into `.engineStart`/`.sessionConfiguration` still **renders the mic-busy
  message** instead of raw CoreAudio text. This is a *message-mapping* upgrade, not a new
  detection path — low risk.
- **Consider** (open Q4) checking `AVAudioSession.sharedInstance().isOtherAudioPlaying`
  *before* `start()` to pre-empt with the call message, but this is **not reliable for the
  mic** specifically (it reports other *audio*, not mic ownership) — **do not make it
  load-bearing**; the 0-channel check stays primary.

---

## 4. Schema impact

**None. (Confirmed.)** No `@Model` types, SwiftData entities, fields, or migrations are
touched. This is string-mapping + call-site edits only. Per `Jot/CLAUDE.md` schema
discipline, no `JotSchemaVN` bump and no `MigrationStage` are required.

---

## 5. Staged implementation plan (prose/pseudocode only — NO Swift)

**Stage 0 — On-device triage (do FIRST, gates copy/allowlist).**
Reproduce the flagship case on a real device across {phone call, FaceTime, Zoom} × {keyboard
dictate, in-app FAB, Action Button}. Read Console for the three diagnostic lines (`:607`,
`:639`, `:1645`) and record, per combination, which `RecordingError` case fires and the exact
CoreAudio domain/code. Output: the confirmed mic-busy code allowlist for §3.2 and which
surfaces hit the raw-error path. (No code change.)

**Stage 1 — Single source of truth for messages.**
Move the `RecordingError` enum (+ its `CustomNSError`/`CustomLocalizedStringResourceConvertible`
conformances) into a Foundation-only shared file both app and keyboard compile (open Q1), and
add `userFacingMessage` implementing the §3.2 table (including the code-allowlist branch for
`.engineStart`/`.sessionConfiguration`). Point `errorDescription` and `localizedStringResource`
at `userFacingMessage`. Verify the keyboard target still builds under its 60 MB / no-SwiftUI
constraint.

**Stage 2 — Adopt at every surface.**
Rewrite the four display sites (hero ×3, foreground alert) to call `userFacingMessage` and
drop raw-`localizedDescription` interpolation; replace the keyboard's hardcoded
`"Couldn't start mic - tap again"` (`JotApp.swift:1047`) with `userFacingMessage`. Fold the
pre-throw mic-permission banner (`:835`) into the same message so it matches everywhere.
Leave the friendly `"… grant mic access …"` / pipeline banners' *intent* but align wording
with the new copy.

**Stage 3 — Verify & QA.**
On device, re-run the Stage-0 matrix and confirm every surface now shows the friendly
sentence (and the call case specifically shows the mic-busy message). Confirm intents/Shortcuts
banner matches. Note the §5.10 collapsed-keyboard-banner limitation is unrelated.

**Stage 4 (optional) — Watch + AppIntents polish.**
If owner wants: give the watch start-failure path a real message (today it silently
`dismiss()`es, `RecordingView.swift:164`) — separate error domain, separate copy.

---

## 6. Open questions for the owner

- **Q1 (placement):** OK to move the `RecordingError` enum into a Foundation-only `Jot/Shared/`
  file so the keyboard shares one source of truth (recommended), vs. mirroring the mapping in
  the keyboard? The enum's NSError domain/code contract (`:3027–3045`) is "public API" per its
  own comment — moving the file preserves the domain string, so no diagnostic break.
- **Q2 (copy):** Confirm the flagship wording. Draft:
  *"Can't record — another app (like a call) is using the microphone. Try again when it's
  free."* Shorten for the keyboard banner? (It fits, but you may want a tighter
  *"Mic in use by another app (a call?). Try again soon."*)
- **Q3 (`.alreadyRunning`):** show a message at all, or silently no-op? It's a tap-race, not a
  user-actionable error.
- **Q4 (detection belt-and-suspenders):** want a pre-`start()` `isOtherAudioPlaying` check to
  *pre-empt* with the call message, accepting it's not mic-specific? Recommendation: no — keep
  the 0-channel preflight as the single source of truth; only use the code-allowlist to catch
  the residual raw-error path.
- **Q5 (watch):** in scope to give the watch start-failure path a message, or defer? Today it
  shows nothing.
- **Q6 (prefixes):** keep the hero's "Could not resume:" / "Dictation failed:" prefixes on the
  non-start paths, or unify everything to bare `userFacingMessage`?

---

## 7. Citations

**Code (this repo):**
- Error type + strings: `App/Recording/RecordingService.swift:9–40` (enum + `errorDescription`),
  `:3024–3052` (`CustomNSError` domain/codes), `:3059–3076` (`localizedStringResource`).
- Start path / detection: `:555` (`start()`), `:591` (`configureSession()` call), `:595–609`
  (0-channel preflight → `.micUnavailable`), `:612–614` (`.converterUnavailable`), `:629–646`
  (`engine.start()` → `.engineStart`, with CoreAudio code log at `:638–641`), `:1614–1650`
  (`configureSession` → `.sessionConfiguration`, code log at `:1645`).
- Surfaces: `RecordingHeroView.swift:368` (alert title), `:874/916/964` (messages);
  `JotApp.swift:378` (foreground alert title), `:779–792` (`surfaceAutoStartBanner`),
  `:835/866` (perm/pipeline banners), `:1046–1058` (keyboard banner + foreground alert on
  start failure), `:764–768` (`describeAutoStartError`); `JotKeyboardViewController.swift:~2547`
  (keyboard reads `AppGroup.lastDictationStatusMessage`); `Shared/AppGroup+Rewrite.swift:243–252`
  (`lastDictationStatusMessage` storage). Watch (separate domain): `Watch/Views/RecordingView.swift:160`
  (`recorder.start()`), `:163–165` (start error swallowed), `:124–134/183/187` (`saveError` alert).
- Keyboard constraints: `Jot/CLAUDE.md` ("~60 MB … must not link MLX or Apple Foundation Models").

**Apple / external:**
- [AVAudioSession.ErrorCode.cannotStartRecording — 561145187 '!rec'](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)
- [Apple DTS thread 756507 — mic recording from Shortcut fails (code 561015905 '!pla')](https://developer.apple.com/forums/thread/756507)
- [Apple forum 813278 — setActive(true) fails after phone call when backgrounded (code 560557684 '!int')](https://developer.apple.com/forums/thread/813278)
- Repo cross-ref: `docs/carplay/issue-3-mic-rootcause.md:38,42–47,58` (the `.engineStart`
  "Audio engine failed to start" banner + code mapping).
