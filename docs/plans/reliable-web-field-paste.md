# Reliable insertion of dictated text into web / custom host fields

**Status:** Research only. NO app code changed, nothing deployed.
**Scope:** the Jot keyboard extension inserting a finished transcript into a host
app's compose field where the host is *not* a native `UITextView` — Claude Code
(WKWebView), Slack (React-Native), Safari `<textarea>`. Owner reports plain
`UITextDocumentProxy.insertText` lands ~60% of the time and the keyboard
*false-reports success* the other ~40%.

This is the **fourth chapter** of the keyboard host-paste saga. Read the prior
three first — their lessons are load-bearing and not repeated here:
- [`bug-keyboard-paste-fails-claude-code.md`](bug-keyboard-paste-fails-claude-code.md) — the diagnosis: the proxy cache lies; empty fields reconnect, populated re-mounted web fields drop the insert.
- [`bug-slack-silent-paste.md`](bug-slack-silent-paste.md) — windowed `documentContextBeforeInput`, `contextGrew` ambiguity, banner/clipboard-fallback design, Path D (`hasText`).
- [`bug-rare-empty-field-first-paste-miss.md`](bug-rare-empty-field-first-paste-miss.md) — `nil`-context ambiguity on empty fields.

The current insert path is
`Jot/Keyboard/JotKeyboardViewController.swift` →
`flushPendingAutoPasteIfPossible()` (`:1129`), which already implements a
12 ms re-sync hop (`:1204-1208`), an immediate read-back (`:1227-1232`), and a
350 ms deferred settled-verify with clipboard-fallback (`:1291-1359`). This doc
explains *why even that is not enough*, ranks the remaining techniques against
research, and specifies a deterministic off-device test so a technique can be
validated **before** shipping.

---

## 1. Why `insertText` drops into a re-mounting WKWebView / RN field

### 1.1 The architecture (this is the root fact — ~90% confidence)

`insertText(_:)` is **not** a function that writes into the host's document and
returns. It is a one-way message to a *proxy*. `UITextDocumentProxy` is, by
Apple's own description, "a proxy to the text input object that the custom
keyboard is interacting with" — the keyboard has **no direct access** to the host
text view ([Apple, App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html);
[UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)).

In **iOS 17 Apple moved the keyboard into its own process**, "running almost
completely outside your app" ([WWDC23 session 10281, "Keep up with the
keyboard"](https://github.com/WWDCNotes/Content/blob/main/content/notes/wwdc23/10281.md)).
Apple explicitly warns: *"aspects of this new asynchronous approach now exist
throughout the entire keyboard and can introduce some slight differences in
timing … if your app is especially sensitive to the timing of text entry,
selection changes, or any other text related operations, you should keep this new
architecture in mind … notifications can be delayed."* (ibid.)

So the real pipeline for `proxy.insertText("hello")` is:

```
keyboard process ──IPC──▶ RTIInputSystemClient / remote text input session
                          ──▶ host process ──▶ host's UITextInput object
                                               ──▶ (web/RN) bridge ──▶ DOM / RN state
```

Every arrow is asynchronous and can fail independently. `insertText` returns
`void` and returns **immediately**, before any of those arrows have resolved
([Microsoft mirror of UIKit docs confirms the proxy surface and void
returns](https://learn.microsoft.com/en-us/dotnet/api/uikit.uitextdocumentproxy)).
There is *no* success/failure channel on the call. The iOS-17 remote text input
session is the same subsystem that produces the widely-reported
`-[RTIInputSystemClient remoteTextInputSessionWithID:performInputOperation:]
… requires a valid sessionID` errors and 30-45 s text-field stalls — i.e. the
session can be **invalid or mid-handshake at the moment you message it**
([Apple forum 744267](https://developer.apple.com/forums/thread/744267);
[RN issue 41801](https://github.com/facebook/react-native/issues/41801)).

### 1.2 Why the proxy cache *lies* (the false-success — ~95% confidence)

`documentContextBeforeInput` / `documentContextAfterInput` / `hasText` are reads
of the **proxy's own local cache** of the text around the caret, *not* live reads
of the host document. Apple's own behaviour note: *"Values of
`documentContextBeforeInput` and `documentContextAfterInput` don't change if the
text isn't changed by the proxy"* — i.e. the cache only tracks the proxy's own
edits, and is updated **locally in the keyboard process** when you call
`insertText`, independent of whether the host ever committed
([Apple forum 45121, "Custom Keyboard TextDidChange Not working"](https://developer.apple.com/forums/thread/45121)).
The cache is also **windowed** — community-measured at roughly the last 300–1024
characters, not the full field ([KeyboardKit proxy
utilities](https://keyboardkit.com/features/proxy-utilities) note KeyboardKit Pro
exists *specifically* to read "the full document context, instead of the limited
text that the native APIs return"; the Slack-bug doc measured ~1024).

This is the mechanism behind the owner's 40% false-success:
**`insertText` updates the proxy's local cache synchronously, then sends the IPC.
When the host's web/RN field has re-mounted (lost its input session) the IPC is
dropped, but the cache already grew** — so `delta>0` and `endsWith==true` both
read `true` from the same poisoned cache. They lie *together*; one is not a check
on the other. This is exactly why the current code's immediate read-back is
insufficient and why `pasteSuccess` shipped as a false positive four times
(`JotKeyboardViewController.swift:1268-1274` already documents this).

### 1.3 Why empty fields work but populated web fields fail

This is the owner's key observation and it falls straight out of §1.1. An empty
(or freshly-mounted, trivial) web field re-establishes its remote input session
cheaply and within the keyboard's ~12 ms re-sync hop, so the IPC arrives at a
live session → real landing. A **populated** web field (Claude's 906-char draft,
a long Slack draft) that re-mounted during the record→transcribe gap is still
rehydrating its remote input session when the insert IPC arrives → the IPC is
dropped while the local cache still grew. The fixed 12 ms hop is tuned for the
cheap case and does not scale with the host's re-mount cost. (Diagnosed in
`bug-keyboard-paste-fails-claude-code.md` §3.2; the iOS-17 out-of-process model
is the *why* behind that diagnosis.)

### 1.4 Documented failure conditions (confirmed across sources)

- **WKWebView / RN custom compose fields**: proxy pointer stays valid but
  `insertText` no-ops, and `documentContext` returns `nil`/stale — reported for
  Gmail/Email (web compose) where reads work in Messages but not after a paste
  in Gmail until the field is edited ([Apple forum 812642](https://developer.apple.com/forums/thread/812642);
  [forum 772158](https://developer.apple.com/forums/thread/772158)).
- **The UIResponder chain breaks** for custom input controls — "the pointer to
  `UITextDocumentProxy` seems to be valid but you won't be able to insert text
  anymore" ([Medium, Limitations of custom iOS keyboards](https://medium.com/@inFullMobile/limitations-of-custom-ios-keyboards-3be88dfb694)).
- **Secure fields & phone pads**: the system swaps in its own keyboard; custom
  keyboards can't insert ([Apple custom-keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)).
- **Apps that block 3rd-party keyboards entirely**: Citrix, banking, password
  managers, corporate MDM — no insert is possible; Wispr Flow documents falling
  back to "dictate into Notes and paste manually" for these
  ([Wispr Flow: fix text not pasting](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation)).

---

## 2. Ranked reliable-insert techniques

Reliability is for the *populated web/RN field* case (the failing cohort), not
native fields. Effort is incremental on top of the current code. "API
legitimacy" = uses only public, App-Store-safe UIKit.

| # | Technique | How it works | Web-field reliability | Effort | API legitimacy | Verdict |
|---|---|---|---|---|---|---|
| 1 | **Bounded reconnect-poll re-sync before insert** (held "Option 2") | After `adjustTextPosition(0)`, poll `documentContextBeforeInput`/`hasText` every ~25–40 ms up to ~300–400 ms until two consecutive reads are *stable*, THEN insert once | **High** — lets a heavy re-mounted remote session finish rehydrating before the write; directly attacks the §1.3 cause; fast hosts settle on poll #1 (no regression) | M | Public, idiomatic | **ADOPT — primary** |
| 2 | **Real landed-signal via `UITextInputDelegate` callback** (`textDidChange` / `selectionDidChange`) gating success instead of a re-read | Override the input-delegate callbacks on `UIInputViewController`; treat the host's `textDidChange` *after* our insert as the only "host committed" proof | **High as a signal** (when it fires it is the host talking back, not our cache) — BUT **does not fire for proxy-originated inserts on many hosts** | M | Public | **ADOPT as a corroborating signal, do NOT rely on alone** (see §3) |
| 3 | **350 ms deferred settled re-read + `hasText`** (already shipped) | Re-read the cache after a delay; require suffix-still-present AND `hasText` | **Medium** — better than immediate, but still a *cache* read; pure §1.2 stale-cache can keep lying past 350 ms | — (in place) | Public | **KEEP, but it is a floor not a cure** |
| 4 | **Adaptive longer single-hop re-sync** (e.g. 50–100 ms instead of 12 ms) | Same as today, bigger constant | Low-Medium — a constant never scales to a 906-char rehydrate; this is the band-aid that produced builds 103-106 | XS | Public | **REJECT** — superseded by #1's poll |
| 5 | **`setMarkedText` + `unmarkText` instead of/around `insertText`** | Stage text as marked (composition) then commit | **Unproven / likely no better** in web fields — marked text rides the *same* remote text-input session that's the failure point; designed for IME composition not bulk paste; risks leaving dangling marked ranges if `unmarkText` IPC drops | M | Public | **REJECT for now** — research-only fallback to test in the harness; no evidence it survives a dropped session |
| 6 | **Chunked / per-chunk-verified insert** | Split the transcript, `insertText` each chunk, verify between | Low — every chunk rides the same broken session; if the session is dead all chunks no-op; if alive, one bulk insert already works. Adds latency + double-paste surface | M | Public | **REJECT** — splits the symptom, not the cause |
| 7 | **Clipboard + programmatically trigger the host's Paste** | Put text on `UIPasteboard`, then make the host run its own Paste | **N/A — impossible.** A keyboard has **no access to the host's edit menu** (Apple: *"If the host app provides an editing menu … the keyboard has no access to it"*), **cannot synthesize key events** (no `⌘V`), and `UIKeyCommand`/`UIKeyboardInputAssistantItem` only add the keyboard's *own* shortcut bar, not host-targeted commands | — | **Not possible** | **REJECT — confirmed impossible** |
| 8 | **Clipboard + visible "tap to paste" banner** (manual paste by the user) | On verified failure, leave full text on `UIPasteboard` (1 h expiry) and show a banner | **100% recoverable** (user does the paste the OS guarantees) — but not an *auto* insert | S (largely shipped) | Public | **KEEP — the guaranteed floor** |

Sources for the impossibility of #7: [Apple custom-keyboard
guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
(no edit-menu access); [WebSearch synthesis on `UIKeyCommand`/⌘V
synthesis](https://www.hackingwithswift.com/example-code/uikit/how-to-use-uikeycommand-to-add-keyboard-shortcuts)
(shortcuts are app-defined, not injectable into another app). Wispr Flow — a
shipping dictation keyboard — confirms the industry pattern: *"Text appears
directly in the text field… If direct insertion fails, Flow automatically copies
the text to your clipboard — tap Paste to insert it manually."*
([Wispr Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free);
[fix text not pasting](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation)).
That is exactly the auto-insert-then-clipboard-floor shape this doc recommends.

### What shipping 3rd-party keyboards actually do (honest read)

- **Wispr Flow**: direct `insertText`; clipboard + manual-paste fallback; gives up
  with a "dictate into Notes" instruction for hard-blocked apps. No magic — same
  two tools Jot has.
- **Gboard / SwiftKey**: no public engineering notes on web-field insertion were
  found; community discussion confirms 3rd-party-keyboard insertion reliability
  on iOS is an unresolved, host-dependent problem, not something a competitor has
  "solved" ([RN keyboard threads](https://github.com/react/react-native/issues/37509)).
- **KeyboardKit (the dominant SDK)**: ships a *timer/polling* layer to work
  around proxy-cache staleness, and KeyboardKit **Pro replaces the proxy entirely
  / reads full context** — i.e. the SDK authors also concluded the native proxy
  reads are untrustworthy and resort to **polling + delay**, which is technique #1
  ([KeyboardKit proxy utilities](https://keyboardkit.com/features/proxy-utilities);
  [forum 45121 — "KeyboardKit uses a timer class … the developers acknowledge
  this is a hack"](https://developer.apple.com/forums/thread/45121)).

**Conclusion of the field scan:** nobody has a clean API that guarantees a web
insert. The best-in-class real-world answer is *poll-until-the-session-is-stable,
insert once, verify, and fall back to clipboard+banner* — which is the recommended
stack below.

---

## 3. A landed-detection signal the proxy cache can't fake

The current oracle (delta / endsWith / hasText / settled re-read) all read the
**same windowed cache** (§1.2), so against a pure stale-cache failure they can all
agree and all be wrong. The question: is there ANY signal that reflects the
*host's* commit?

Findings, ranked by trustworthiness:

1. **`UITextInputDelegate.textDidChange(_:)` / `selectionDidChange(_:)` on the
   `UIInputViewController`** — these are *push* callbacks the host fires when its
   document/selection actually changes
   ([Apple, selectionDidChange](https://developer.apple.com/documentation/uikit/uitextinputdelegate/selectiondidchange(_:));
   [UIInputViewController conforms to UITextInputDelegate](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)).
   When `textDidChange` fires *after* our insert, that is the host talking back —
   the strongest available "it committed" evidence.
   **The catch (well-documented):** these callbacks are **not reliably delivered
   for proxy-originated inserts** — *"`textWillChange`/`textDidChange` are not
   called … when you send text to the text document proxy"*
   ([forum 45121](https://developer.apple.com/forums/thread/45121)). And under
   iOS-17 out-of-process they can be *delayed* (WWDC 10281). So `textDidChange`
   is a **high-value positive signal when present, but its absence does NOT prove
   failure.** Use it as: *if it fires within the verify window → definitive
   success (short-circuit the deferred timer);* never as the sole gate.

2. **`hasText`** — a separate `UITextDocumentProxy` property (used today, Path D).
   It is still a *proxy* read but is a *different* code path from
   `documentContextBeforeInput` and on a fully-disconnected session tends to read
   `false`, so pairing it with the suffix check catches the "detached session"
   class. Keep it; it is the cheapest non-redundant second signal — but it is NOT
   immune to the cache lie in §1.2.

3. **`pasteboard.changeCount` correlation** — a host autosave/focus-shuffle that
   eats the insert often bounces the clipboard; an unexpected `changeCount`
   advance right after insert is weak corroborating evidence of a focus shuffle
   (floated in `bug-slack-silent-paste.md`). Low value; log-only.

**Honest bottom line:** there is **no public API that gives a keyboard a
guaranteed, synchronous, host-authoritative "the text landed" boolean** for an
arbitrary web/RN field. The best achievable oracle is a **composite**:
`textDidChange`-fired (definitive-yes) OR (settled suffix-present AND `hasText`)
— and when that composite is false, **fall back to clipboard+banner rather than
trust any single read.** This matches what the codebase already converged on; the
*new* element is treating `textDidChange` as a definitive short-circuit, and
gating the *insert* on the §2-#1 stability poll so the IPC is far more likely to
land in the first place.

---

## 4. Recommended approach (ranked, layered)

A defence-in-depth stack — each layer narrows the failure window the next must
catch. **Layers A+D are the must-haves; B+C are the upgrades.**

**A. Insert only into a stable session — bounded reconnect-poll (§2-#1).**
Replace the fixed 12 ms hop (`JotKeyboardViewController.swift:1204-1208`) with:
`adjustTextPosition(0)` → poll `documentContextBeforeInput`/`hasText` every ~30 ms
up to a ~400 ms ceiling until two consecutive reads are stable (or `hasText`
flips true) → **then** a single `insertText`. Fast/native hosts settle on the
first poll (no regression); heavy re-mounted web fields get the time their remote
session needs. This is the single highest-leverage change and the one
KeyboardKit's own timer-hack and Apple's "timing can be delayed" guidance point
at.

**B. Treat `textDidChange` as a definitive landed-signal (§3-#1).** Override
`textDidChange` on the controller. If it fires within the post-insert window for
our pending session, classify success immediately (cancel the deferred timer).
Its *absence* still falls through to C — never treat absence as failure.

**C. Composite settled-verify (keep + tighten the current 350 ms path).** Keep
the deferred re-read but make the success predicate `B-fired OR (hasText AND
suffix-survived)`; on false → D. (Already ~90% built at `:1291-1359`.)

**D. Clipboard + visible banner floor (§2-#8) — non-negotiable.** On any
verified-failure, the full transcript is already on `UIPasteboard.general` from
`ClipboardHandoff.publish` (`Jot/Shared/ClipboardHandoff.swift:53`); re-stamp a
1-hour `.expirationDate` and show *"Couldn't paste here — saved to clipboard, tap
to paste."* This converts every silent false-success into a one-tap recovery and
is the floor Wispr Flow also ships. **Caveat:** the collapsed-keyboard banner is
currently invisible (features.md §5.10 / CLAUDE.md) — that bug must be fixed for D
to actually be seen, or the banner shown only in the expanded state.

**Explicitly rejected:** host-paste triggering (§2-#7, impossible), chunked
insert (#6), bigger fixed hop (#4). `setMarkedText` (#5) only as a harness
experiment, not a shipped path, until the harness shows it survives a dropped
session.

Sequencing: A + D are the cure-and-floor and should land together. B + C are the
precision upgrades. Do **not** ship A without D — A reduces but cannot eliminate
the failure, and the floor is what removes the *silent* class for good.

---

## 5. Deterministic off-device test design (the WKWebView JS-readback harness)

The owner asked for "simulated tests, not the iOS simulator but something
similar." Here is the honest feasibility assessment and the most deterministic
design achievable.

### 5.1 What is and isn't automatable — honest constraints

- A `UITextDocumentProxy` only exists when iOS focuses a real text input and
  presents the keyboard extension; you **cannot** instantiate one in a pure
  unit-test process. So the *exact* production path (keyboard-process → IPC →
  host) **cannot** be exercised off a running iOS instance. Anyone claiming a pure
  XCTest reproduces the cross-process drop is wrong.
- BUT the thing we actually need to test is **"did technique X make the host
  field's real value change?"** That does **not** require the keyboard-extension
  IPC. We can host the *same three field types in-process* and drive the candidate
  insert techniques against a real `UITextInput`, then **read the ground truth
  from the host itself** — for the web field, via `WKWebView.evaluateJavaScript`
  reading `document.activeElement.value`. JS-readback is deterministic and runs on
  the app's main thread with a real result/err completion
  ([Apple WKWebView evaluateJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:completionhandler:));
  [Hacking with Swift](https://www.hackingwithswift.com/example-code/wkwebview/how-to-run-javascript-on-a-wkwebview-with-evaluatejavascript)).
- This harness therefore validates **technique correctness against the host's
  live value** (the part our cache-reads lie about), which is precisely the bug.
  It does **not** reproduce the *session-drop timing race* — that still needs an
  on-device confirmation run. State this limit plainly: the harness proves a
  technique *can* write the host value and that our oracle *reads the host truth*,
  not that it wins the production race. It is a necessary, deterministic
  pre-filter before any on-device build.

### 5.2 Harness shape

A new **UI-test / host target** `JotPasteHarness` (a tiny app + an `XCUITest`
target, or a single app target driven by `XCTestExpectation`) containing three
hosts on one screen, each made first responder in turn:

1. **Native** — a `UITextView` (the must-not-regress control).
2. **Web `<textarea>`** — a `WKWebView` loading an inline
   `<textarea id="ta">`/`<div contenteditable>`; ground truth read via
   `evaluateJavaScript("document.getElementById('ta').value")` (and a
   `contenteditable` variant reading `.innerText`). Optionally inject an
   `input`-event listener that pushes each change to a JS array so the harness can
   also assert *event* delivery, mimicking a controlled React input.
3. **RN-style controlled input** — a `UITextField` wired so its bound model only
   updates on the delegate callback, then re-renders the field from the model
   (re-mounting it). This reproduces the "controlled component overwrites the DOM
   on re-render" class (alternative D in the Claude-Code bug doc) without needing
   real React.

Because a real keyboard-extension proxy isn't available in-process, drive each
technique through a thin **`InsertDriver` protocol** with two implementations:
(a) a production-shaped wrapper that calls the same `UITextInput` primitives
(`insertText`, `setMarkedText`/`unmarkText`, `adjustTextPosition`) the proxy
forwards, and (b) optionally a real on-device pass where the field is the host and
Jot's keyboard is active. The harness asserts on **host ground truth**, never on a
proxy cache.

### 5.3 Test matrix

For every (host × field-state × technique) cell, **pass = JS/host readback shows
the inserted text; the oracle's verdict must equal the readback** (catches both
"didn't land" and "lied about landing"):

| Host | Field state | Techniques under test |
|---|---|---|
| Native `UITextView` | empty / short / >2000-char pre-caret | bulk `insertText`; poll-then-insert; markedText±unmark |
| WKWebView `<textarea>` | empty / 900-char / >2000-char | bulk; poll-then-insert; markedText; chunked |
| WKWebView `contenteditable` | empty / populated | bulk; poll-then-insert |
| RN-style controlled `UITextField` | empty / populated, re-render-on-model | bulk; poll-then-insert; (revert-after-landing case) |

Assertions per cell:
1. **Landed:** host readback == expected text appended at caret. (Web: JS value;
   RN: model value after settle; native: `textView.text`.)
2. **Oracle honesty:** the composite oracle (§3/§4-C) returns `success` **iff**
   assertion 1 is true — no false positive, no false negative.
3. **No double-insert:** readback contains the text exactly once.
4. **Revert case (RN):** force a model-driven re-render ~200 ms after insert that
   drops the text; assert oracle reclassifies to failure and the
   clipboard-fallback path fires.

### 5.4 What this buys, and the residual on-device step

- Deterministic, CI-runnable proof that a technique writes the host value and that
  the oracle reflects host truth — the exact pair the production bug violates.
- It will **not** prove the §1.3 *session-drop race* is beaten (that needs a real
  re-mounting host + the real extension IPC). So the gate is: a technique must (1)
  pass the harness matrix green, **then** (2) get one on-device confirmation run in
  Claude Code with a *populated* field (the §5 probe from
  `bug-keyboard-paste-fails-claude-code.md`, which captures `pasteVerifyDeferred`
  metadata). Only after both → ship.

---

## 6. Recommendation summary

1. **Mechanism:** iOS-17 out-of-process keyboard → `insertText` is async IPC to a
   host remote-text-input session; the proxy's `documentContext*` cache updates
   *locally* whether or not the host commits, so it false-reports success when a
   populated web/RN field's session is mid-rehydration. (§1, ~90% confidence.)
2. **Best insert technique:** bounded reconnect-poll re-sync, insert once into a
   *stable* session (§2-#1 / §4-A) — the same poll-and-delay KeyboardKit resorts
   to and Apple's timing guidance implies.
3. **Best landed-signal:** there is no perfect one; use a composite —
   `textDidChange` host callback as a definitive yes (when it fires) + settled
   `hasText`+suffix — and never trust a single cache read (§3 / §4-B,C).
4. **Guaranteed floor:** clipboard + visible "tap to paste" banner on verified
   failure; host-paste-triggering is impossible (§2-#7,#8 / §4-D). Fix the
   collapsed-banner invisibility (features.md §5.10) so the floor is seen.
5. **Validate before shipping:** the deterministic WKWebView JS-readback harness
   (§5) proves technique correctness + oracle honesty off-device; one on-device
   populated-field run confirms the race is beaten. Both gates, then ship.

---

## 7. Sources

- Apple, [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) — proxy-only access, no edit-menu access, secure/phone-pad limits, `UITextInputDelegate` callbacks.
- Apple, [UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy) and [UIInputViewController](https://developer.apple.com/documentation/uikit/uiinputviewcontroller) — proxy surface, void inserts, input-delegate conformance.
- Apple, [selectionDidChange(_:)](https://developer.apple.com/documentation/uikit/uitextinputdelegate/selectiondidchange(_:)) — host push callback.
- Apple, [WKWebView.evaluateJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:completionhandler:)) — main-thread result for JS readback.
- WWDC23, [Keep up with the keyboard (session 10281, WWDCNotes)](https://github.com/WWDCNotes/Content/blob/main/content/notes/wwdc23/10281.md) — iOS-17 out-of-process keyboard, async timing, delayed notifications.
- Apple Developer Forums: [45121 (textDidChange not called for proxy inserts; cache only tracks proxy edits; KeyboardKit timer hack)](https://developer.apple.com/forums/thread/45121); [812642 (documentContext nil after paste in Gmail/Email, works in Messages)](https://developer.apple.com/forums/thread/812642); [772158 (reading field text as keyboard extension)](https://developer.apple.com/forums/thread/772158); [744267 (RTIInputSystemClient invalid sessionID)](https://developer.apple.com/forums/thread/744267).
- [Medium — Limitations of custom iOS keyboards](https://medium.com/@inFullMobile/limitations-of-custom-ios-keyboards-3be88dfb694) — valid proxy pointer but insertText no-ops; broken responder chain.
- [KeyboardKit — proxy utilities](https://keyboardkit.com/features/proxy-utilities) — native proxy reads are limited/windowed; Pro replaces proxy / reads full context.
- Wispr Flow Help Center: [use hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free); [fix text not pasting (clipboard fallback)](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation) — shipping dictation keyboard: direct insert + clipboard/manual-paste floor.
- [Hacking with Swift — UIKeyCommand](https://www.hackingwithswift.com/example-code/uikit/how-to-use-uikeycommand-to-add-keyboard-shortcuts) and [WKWebView evaluateJavaScript](https://www.hackingwithswift.com/example-code/wkwebview/how-to-run-javascript-on-a-wkwebview-with-evaluatejavascript).
- [React Native issue 41801 — iOS17 RTIInputSystemClient text input regressions](https://github.com/facebook/react-native/issues/41801).

## 8. Cross-links

- Current insert path: `Jot/Keyboard/JotKeyboardViewController.swift` —
  `flushPendingAutoPasteIfPossible` (:1129), re-sync hop (:1204-1208),
  immediate read-back (:1227-1232), deferred settled-verify + clipboard fallback
  (:1291-1359), `insertTrackedText` (:679), `fallbackToClipboardWithBanner`
  (referenced :1357).
- Cross-process handoff: `Jot/Shared/ClipboardHandoff.swift` (`publish` :48
  writes `UIPasteboard` :53; `readFresh` :96).
- Prior chapters (READ FIRST):
  [bug-keyboard-paste-fails-claude-code.md](bug-keyboard-paste-fails-claude-code.md),
  [bug-slack-silent-paste.md](bug-slack-silent-paste.md),
  [bug-rare-empty-field-first-paste-miss.md](bug-rare-empty-field-first-paste-miss.md).
- Registry: per CLAUDE.md, when this is picked up add the dual entry to
  [`known-bugs-and-plans.md`](../../Jot/known-bugs-and-plans.md) (detailed entry +
  one-line index) — a `docs/plans/` doc alone is not discoverable.
- features.md §5.10 (collapsed-banner invisibility — blocks fallback visibility),
  §5.12 / §2.9 / §13.2 (auto-paste handoff).
- Test target precedent: `Jot/Tests/` (unit tests) + `JotTests` bundle in
  `Jot/project.yml`; the §5 harness is a new UI-test/host target alongside it.
