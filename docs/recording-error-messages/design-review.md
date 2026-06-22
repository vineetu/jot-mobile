# Adversarial review — recording-start error messages design

**Reviewer pass:** 2026-06-20. Verified every code claim at file:line and every Apple/audio
claim against current Apple docs + arithmetic four-char-code decoding. No product code changed.

## Verdict

**Sound enough to implement — after the Stage-0 on-device triage the design itself gates on.**
The flagship root-cause reframe (#1: the keyboard banner flattens every start failure into one
hardcoded string) is **CONFIRMED at `JotApp.swift:1047`** and is the correct flagship bug. The
single-source-of-truth fix (move `RecordingError` into `Shared/`, add `userFacingMessage`,
collapse the three string tables) is mechanically viable and **lower-risk than the design
states** — the keyboard already compiles `Shared/` wholesale and already links AppIntents +
`LocalizedStringResource`, so nothing forbidden is dragged in. The only blocking issues are
**factual errors in the CoreAudio code table (§2.3)** that feed the allowlist (#4), plus an
**unstated mis-upgrade risk** in that allowlist. Neither blocks the architecture; both must be
corrected before the allowlist copy is finalized — and Stage-0 triage is the right gate for it.

---

## MUST-FIX

### M1. §2.3 four-char-code table has two wrong integer↔fourcc pairings (feeds the allowlist)
The design's §2.3 / §3.2 allowlist hinges on these mappings. Decoded arithmetically (ASCII-packed
OSStatus) and cross-checked against Apple docs:

| Integer | Actual fourcc | Actual `AVAudioSession.ErrorCode` | Design says | Correct? |
|---|---|---|---|---|
| 561145187 | `!rec` | `cannotStartRecording` | `!rec` cannotStartRecording | ✅ |
| 561015905 | `!pla` | `cannotStartPlaying` | `!pla` cannotStartPlaying (not a rec code) | ✅ |
| 560557684 | `!int` | **`cannotInterruptOthers`** | "`!int` = session interrupted" | ❌ **wrong label** |
| 560030580 | **`!act`** | (invalid-state / activation) | "`560030580 = 'what'` generic invalid-state" | ❌ **wrong fourcc** |

- **560557684 is `cannotInterruptOthers`** ("attempt to make a *nonmixable* audio session active
  while the app was in the background"), not "session interrupted." Per Apple this is also the
  code seen "when reactivating the audio session after a phone-call interruption ends."
  ([Apple docs — cannotInterruptOthers](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers))
- **560030580 decodes to `!act`, not `what`.** `'what'` packs to **2003329396**, a completely
  different integer. The §2.3 bullet pairing `560030580 = 'what'` is internally inconsistent.
- Verification: `chr`-decode of each int, and reverse-encode of each fourcc, both run locally;
  `!rec`/`!pla` independently confirmed by
  [Apple docs — cannotStartRecording](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)
  and a search corroborating 561015905 = cannotStartPlaying.

**Why it's MUST-FIX:** §3.2's mic-busy allowlist is `{561145187, 560557684, 561015905}`. Two of
the three rest on this table, and a reader will use the (wrong) semantic labels to decide whether
to keep/drop a code. Correct the table before sizing the allowlist. The numbers themselves are
fine; the *names* and one *fourcc* are not.

### M2. Allowlist mis-upgrade risk is real and understated (#4)
Mapping `.engineStart`/`.sessionConfiguration` with code ∈ {561145187, 560557684, 561015905} to
"another app (like a call) is using the microphone" **can mislabel non-call failures**:

- **560557684 / `cannotInterruptOthers`** literally means "you tried to activate a *nonmixable*
  session in the background." Jot configures `.mixWithOthers` (`RecordingService.swift:1627-1631`),
  so if this code ever fires for Jot it is a *background-activation / session-config* problem, not
  necessarily a held mic — telling the user "a call is using the mic" would be actively wrong and
  send them to do nothing useful. (It is call-*adjacent* per Apple's "after a phone call" note,
  which is why it's defensible to include — but only after Stage-0 shows it actually fires on a
  call for Jot's mixable session. Right now that's an assumption.)
- **561015905 / `cannotStartPlaying`** is a *playback* code. The design itself flags it as "not a
  recording code" (§2.3) yet still puts it in the mic-busy allowlist. Upgrading a playback-start
  failure to "the mic is busy" is a category error unless Stage-0 proves the held-mic case emits
  it on this device/route.

**Resolution:** Gate the allowlist membership on Stage-0 evidence per code, not on the forum
anecdotes. The design's "widen the allowlist rather than the copy" instinct (§3.2 note) is right;
the inverse risk — a *non-call hardware/route failure that happens to emit one of these codes*
getting the call message — is the part that's understated. The safe default is the **generic**
"Couldn't start recording. Close any app using audio and try again." for any residual raw-error
path, and only promote a code to the call-specific message once Stage-0 confirms it. The design
already routes non-allowlisted codes to the generic message (§3.2 row 3) — so the fix is simply:
**start the allowlist EMPTY (everything residual → generic) and let Stage-0 add codes**, rather
than shipping the three-code allowlist on inference. This makes M2 a one-line plan change.

---

## NICE-TO-HAVE

### N1. Q1 placement: option (b) "mirror keyed off bridged errorDomain+errorCode" is not viable today
The design offers (b) as an alternative to moving the enum: have the keyboard mirror the mapping
"keyed off the bridged `errorDomain`+`errorCode` it already receives via
`AppGroup.lastDictationStatusMessage`." **It does not receive that.** `lastDictationStatusMessage`
is a plain `String?` (`Shared/AppGroup+Rewrite.swift:243-252`); the keyboard reads the final
*string* at `JotKeyboardViewController.swift:2547` and never sees the NSError domain/code. So (b)
would require also plumbing the code across the App Group — strictly more work. This *strengthens*
the design's recommendation (a), but the doc should correct the premise so the owner isn't choosing
between two options when one is a phantom. Recommendation: **drop (b), keep (a).**

### N2. "Foundation-only" framing is slightly off — but the move is SAFER than claimed
The design stresses the file must be "Foundation-only … NO SwiftUI/MLX" so the keyboard can link
it. Verified the real constraints:
- The keyboard's only hard bans are **MLX and Apple Foundation Models** (`Jot/CLAUDE.md`:
  "must not link MLX or Apple Foundation Models").
- The keyboard already `import AppIntents` (`JotKeyboardViewController.swift:1`) and already
  compiles `LocalizedStringResource` via `Shared/Intents/RewriteWithPromptIntent.swift` (in the
  `Shared/` glob the keyboard pulls at `project.yml:307`).
- `RecordingError`'s body needs only `Foundation` (for `LocalizedError`, `CustomNSError`,
  `LocalizedStringResource`); the `Error` associated values are `Swift.Error`, not AVFoundation
  types. `RecordingService.swift` imports `AVFoundation/Foundation/os.log/Synchronization`, but
  the *enum* uses none of AVFoundation.

So moving the enum + `userFacingMessage` (and its `CustomLocalizedStringResourceConvertible`
conformance) into `Shared/` compiles into the keyboard **for free**, with no new dependency. The
design's conclusion is right; its stated reason ("Foundation-only") is over-narrow — `LocalizedStringResource`
is fine to keep. No need to strip the AppIntents conformance.

### N3. Citation path drift (cosmetic, but the owner over-indexes on precision)
Several file:line cites omit the actual subdirectory:
- `RecordingHeroView.swift:874/916/964/368` is at **`Jot/App/Recording/RecordingHeroView.swift`**
  (design writes it bare / implies `App/`). Lines themselves verified correct.
- `DictateIntent.swift` / `RecordAndTranscribeIntent.swift` are at **`Jot/App/Intents/`**, not
  `Jot/Shared/Intents/`. The design's §7 cites them bare; §3.1 reasoning is unaffected (they're
  main-app-only, which actually reinforces that the keyboard never runs them).
- `RecordingService.swift` is at **`Jot/App/Recording/RecordingService.swift`** (design's §1
  header says `App/Recording/…` correctly, but §7 and inline cites drop the prefix).

Fix the paths so Stage-1 doesn't waste a grep.

### N4. Watch scoping is correct — and the "shows nothing" note is worth elevating
Confirmed: watch `RecordingView.startRecording()` calls `try recorder.start()`
(`Watch/Views/RecordingView.swift:160`) and the `catch` just `dismiss()`es with no message
(`:163-165`). The `saveError` alert (`:124-134`, body from `:183`) is the *save/transfer* path,
a different domain. The watch uses `WatchRecorder`, not `RecordingService` — correctly scoped OUT
of `RecordingError` work. The design flags the silent-start-failure as an owner note (§1, Q5);
agree it's a latent bug but correctly out of scope here.

### N5. §3.4 `isOtherAudioPlaying` caveat is correct — keep it non-load-bearing
`AVAudioSession.isOtherAudioPlaying` reports other *audio output*, not mic ownership; the design
correctly says do not make it load-bearing and keep the 0-channel preflight primary. No change
needed; just confirming the reasoning is sound.

---

## VERIFIED CORRECT (the load-bearing claims hold)

- **#1 flagship root cause — CONFIRMED.** `JotApp.swift:1047` hardcodes
  `"Couldn't start mic - tap again"` into `surfaceAutoStartBanner(...)` regardless of the
  `RecordingError` case; `surfaceAutoStartBanner` (`:779-792`) writes it verbatim to
  `AppGroup.lastDictationStatusMessage` (`:787`), which the keyboard renders at
  `JotKeyboardViewController.swift:2547`. Meanwhile the *foreground* alert one line later
  (`:1057-1058`) DOES pull `(error as? LocalizedError)?.errorDescription`, so the friendly
  `.micUnavailable` string reaches the in-app alert but **never** the keyboard. The asymmetry is
  exactly as described, and the keyboard is the most likely surface for "tap dictate while on a
  call." This is the right flagship bug.

- **#2 `.micUnavailable` fires via the 0-channel/0-Hz preflight — CONFIRMED in code, on-device
  reality Likely.** `configureSession()` uses `.mixWithOthers` (`RecordingService.swift:1627-1631`)
  so `setActive(true)` (`:1633`) succeeds with a held mic; the preflight
  `guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0` (`:606`) then throws
  `.micUnavailable` (`:609`). If `setActive` *had* thrown it would be `.sessionConfiguration`
  (`:1649`); if `engine.start()` throws it's `.engineStart` (`:646`). The design's admission that
  "a call always yields 0 channels" is Likely-not-Confirmed (simulator can't model it) is honest
  and correct — Stage-0 is the right gate. The repo cross-ref `docs/carplay/issue-3-mic-rootcause.md`
  independently corroborates this exact call-order analysis.

- **#3 moving `RecordingError` to `Shared/` is safe — CONFIRMED** (see N1/N2): keyboard compiles
  `Shared/` at `project.yml:307`, already links AppIntents/`LocalizedStringResource`, and the
  enum carries nothing SwiftUI/UIKit/MLX. The NSError domain/code contract
  (`RecordingService.swift:3024-3052`, domain `"Jot.RecordingService.RecordingError"`, codes 0-6)
  is preserved by a file move (it's an `extension`, moves with the enum). The keyboard does **not**
  currently depend on that NSError contract for paste/diagnostics — it only consumes the final
  banner string — so the move can't break keyboard logic.

- **Surface inventory — CONFIRMED accurate.** Hero alert title `"Recording error"`
  (`RecordingHeroView.swift:368`), start `:874`, resume `:916`, stop `:964` all interpolate raw
  `error.localizedDescription`. Foreground alert title `"Couldn't start recording"`
  (`JotApp.swift:378`), body `:1057`. Mic-perm banner `:835`, pipeline banner `:866`. Intents
  START leg bounces to `triggerAutoStart` (not inline) — confirmed in
  `DictateIntent.swift` / `RecordAndTranscribeIntent.swift` (both at `Jot/App/Intents/`); STOP leg
  rethrows → `localizedStringResource`. The "four different texts for one failure" consistency
  verdict holds.

- **#6 Schema impact: none — CONFIRMED.** No `@Model` / SwiftData types touched; this is
  string-mapping + call-site edits. No `JotSchemaVN` bump needed (per `Jot/CLAUDE.md` schema
  discipline).

---

## Bottom line for the owner

Implement the architecture as designed — it correctly identifies the keyboard-banner flattening
as the flagship bug and the single-source-of-truth move as the fix, and that move is *safer* than
the doc claims. Before finalizing the **allowlist**: (1) fix the §2.3 code-name table (M1), and
(2) start the allowlist **empty** and let Stage-0 on-device triage add codes with evidence rather
than ship the three-code list on forum inference (M2). Everything else is polish.

## Sources
- [AVAudioSession.ErrorCode.cannotStartRecording](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)
- [AVAudioSession.ErrorCode.cannotStartPlaying](https://developer.apple.com/documentation/avfaudio/avaudiosession/errorcode/cannotstartplaying)
- [AVAudioSession.ErrorCode.cannotInterruptOthers](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers)
- [Apple DTS thread 756507 — recording from a Shortcut requires foreground](https://developer.apple.com/forums/thread/756507)
- Four-char-code values verified by ASCII pack/unpack (local), cross-checked against the above.
