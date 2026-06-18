# Model-load pre-warm strategy — hide the ~45s cold ANE load no matter how the user enters

Status: **RESEARCH + DESIGN (no code change, no deploy).** Feasibility verdict + approach, grounded in code (`file:line`) and external iOS sources. Confidence flagged inline per the analysis protocol.

**Cross-references:** `docs/plans/model-load-caching.md` (the *why* — cold load = ANE specialization cache gone, only fix is to re-pay it; triggers = install / update / offload-reopen / low-storage purge; **pure non-use is NOT a trigger**). `docs/plans/wizard-model-prewarm.md` (the wizard-entry application of the same idea). This doc is the **general entry-path** companion: app-open, keyboard-entry, and the warming-status / line-rotation UX.

---

## BLUNT VERDICT (read this first)

**You cannot pre-warm the 600M model in the background "no matter how the user enters" — because the entry that matters (the user typing in another app via the Jot keyboard) gives Jot no legal, non-disruptive way to wake its main app to do the load.** The keyboard extension itself **cannot** load the model (≤60MB ceiling, zero inference — `Jot/CLAUDE.md` "Keyboard extension constraints"). And the only ways to get the *main app* to run are:

- **Foreground launch** (the `jot://dictate` URL bounce) — yanks the user out of the app they're typing in. Unacceptable except where Jot is *already* the foreground host (wizard W5).
- **Darwin notification** ("please warm") — works **only if the main-app process is already alive** (backgrounded-but-not-terminated). **iOS will not resume or relaunch a suspended/terminated app to deliver a Darwin notification** (Apple DTS, Quinn, forum thread/769398, verbatim: *"iOS will not resume your app to receive a Darwin notification … If your app is terminated while suspended, it will never receive the notification"*). So this helps a *warm-process* user and does nothing for the common cold case.
- **`BGProcessingTask` submitted from the keyboard** — the **one genuinely background, policy-blessed path** (WWDC19-707, verbatim: *"if our keyboard extension wants to do some learning based on the user's typing habits, it can create a BG processing task request and submit it too … it's always the main containing app that is launched to handle background tasks, never extensions"*). iOS launches the **main app** (not the extension) in the background to run the load. **BUT** it is **best-effort and deferred** (idle/charging, no guaranteed window, may never run if the user doesn't return — WWDC19-707), so it cannot promise the model is warm *by the time the user taps Dictate seconds later*. It is a **pre-pay-while-idle** lever, not a "warm-on-keyboard-appear" lever.

**Therefore the honest best-achievable for the keyboard-entry path is a LAYERED fallback, not a guarantee:**

1. If the main app is **already alive (backgrounded / warm-hold)** → a Darwin "please warm" ping starts the load *before* the Dictate tap. (Real win, narrow applicability.)
2. If the app is **terminated** → no background warm is possible. The load starts at the Dictate-tap URL bounce (today's behavior). The win there is **UX only**: make the unavoidable wait pleasant + honest (the warming chip + rotating lines + capture-first so audio is never lost).
3. Opportunistically, submit a **`BGProcessingTask` from the keyboard** so that *if* iOS later runs it while charging/idle, the next Dictate tap is warm. Pure upside, never relied upon.

**The app-open AND wizard paths collapse into ONE unified warm.** They are not separate concerns: the cold-launch `JotApp.init` warm (`JotApp.swift:309-320`) already covers app-open and cold-launch-into-wizard; the wizard's *own* `warmUp()` and the `SetupCompletion`-gated scene `.task` warm are only there to patch a single gate (the scene warm is gated on `SetupCompletion.isCompleted`, false during the wizard). The owner's directive: **one mechanism — "warm whenever the app is active AND the model isn't loaded AND the model files are on disk"** — which then naturally covers app-open, wizard first-run, and the keyboard-triggered launch, with NO wizard-specific code. See §1.

So: **the keyboard-entry background pre-warm is achievable ONLY for the warm-process subset (Darwin ping) plus best-effort BGProcessingTask. For the cold/terminated case — which is exactly when the 45s bites — there is no way to move the load off the first dictation without foreground-launching the app, which is unacceptable. Accept that, and win on UX.** Everything below elaborates, with sources.

---

## Section 1 — Unified app-open + wizard warm (ONE path, not three)

**Owner directive (load-bearing):** there must be **a single pre-warm mechanism**, not separate launch / wizard / keyboard paths. The rule is: **warm whenever the app is active AND `modelState != .ready`/`.loading` AND the selected variant's weights are on disk.** That one predicate covers app-open, the wizard's first run, and the keyboard-bounced launch — and the wizard gets **no warm code of its own** (delete it once the unified path covers it). The keyboard never enters this section — it cannot load the model; see §2.

### What exists today (confirmed) — three near-duplicates that should become one

`JotApp.init()` fires both warm-ups at process launch, **ungated on `SetupCompletion`** (so it covers cold-launch-into-wizard too), gated only on weights-on-disk for App-Review 4.2.3(ii) safety:

```
if TranscriptionService.modelsExistOnDiskForSelectedVariant() {       // JotApp.swift:311
    Task(priority: .userInitiated) { @MainActor in warmTranscription.warmUp() }   // :312-314
}
if StreamingTranscriptionService.modelsExistOnDisk() {                 // :316
    Task(priority: .userInitiated) { @MainActor in warmStreaming.warmUp() }       // :317-319
}
```

A **second** warm fires on first scene-activation `.task` (`JotApp.swift:573-594`), but that one **IS** gated on `SetupCompletion.isCompleted` (`:582`, `:591`). `warmUp()` → `ensurePreparing()` is idempotent/coalescing (`TranscriptionService.swift:199-208`, `:714` reuse), so the two are belt-and-suspenders, never a double load. The `.onAppear` wizard hook proposed in `wizard-model-prewarm.md` closes the warm-process re-run gap.

**Verdict: the app-open (FAB / Home / cold `jot://dictate`) path is genuinely covered.** On the default bundled 110M the cold specialization is ~3–4.4s (per `model-load-caching.md` / research-models), comfortably hidden behind launch. The 45s only appears post-update / post-eviction, and even then the load is *started at launch*, not at the record tap.

### The unification (primary recommendation — replaces the wizard's separate warm)

- **U1 — Relax the scene `.task` gate from `SetupCompletion.isCompleted` to models-on-disk only.** The scene warm at `JotApp.swift:573-594` is gated on `SetupCompletion.isCompleted && modelsOnDisk` (`:582`, `:591`). The `isCompleted` half exists **only** to avoid triggering a first-launch *download* of an un-downloaded opt-in 600M before setup (4.2.3(ii)). But the **models-on-disk gate already enforces that** — the bundled default 110M/EOU are constant-true on disk, and an un-downloaded 600M is constant-false, so `modelsExistOnDiskForSelectedVariant()` / `modelsExistOnDisk()` **alone** preserves the 4.2.3(ii) intent without the setup gate. **Drop `&& SetupCompletion.isCompleted`.** Now the scene warm fires during the wizard too — the same active-scene + on-disk predicate the owner wants.
- **U2 — DELETE the wizard's own `warmUp()`.** Once U1 lands, the wizard `.onAppear` warm proposed/relied on in `wizard-model-prewarm.md` (§4.1) is redundant — the unified active-scene warm already fires while the wizard is on screen. Remove it (and do not add it) so there is **no wizard-specific pre-warm code**. The wizard contract (force-stop W5 recordings on dismiss, `Jot/CLAUDE.md`) is untouched — that's recording teardown, not model warming.
- **U3 — Single predicate, expressed once.** Fold `init`'s warm (`:309-320`) and the relaxed scene `.task` warm (`:573-594`) toward one helper, e.g. `warmIfNeeded()` = `if scene active && modelState ∉ {.ready,.loading} && modelsOnDisk { warmUp() }`. `warmUp()`→`ensurePreparing()` is already idempotent/coalescing (`TranscriptionService.swift:199-208`,`:714`), so calling it from both `init` and scene-active is safe; the value of one helper is that the predicate (and its 4.2.3(ii) reasoning) lives in exactly one place. This is the "one mechanism that warms whenever the app is active and the model isn't loaded and is on disk."

**Net effect:** app-open, wizard first-run, and the keyboard-bounced cold launch (`onOpenURL`→app foreground) **all** hit the same warm with no per-surface code. Effort: **S** (relax one gate, delete the wizard warm, optionally extract one helper). Policy-risk: none (the on-disk gate carries the 4.2.3(ii) guarantee).

### Other improvements (low effort)

- **I1 — scene-connect reliability.** `init`'s warm fires on every cold launch already; U1 makes the scene-active warm fire on every activation (incl. wizard + warm-process re-entry after `SetupCompletion` flips). Together they remove the only real gap (warm-process re-run) **without** wizard-specific code. Confidence: Confirmed.
- **I2 — Post-update background re-pay (the Apple-engineer-endorsed move).** On first launch after a `CFBundleVersion` change (read/write a value in `AppGroup`), the load is *guaranteed cold* (`model-load-caching.md` decision table). Two sub-options:
  - **I2a (cheap, recommended):** the existing launch `warmUp()` already starts it at launch — just **surface the calibrated bar prominently** on that first post-update launch (the cold-load affordance). This is "hide it," matching the Apple engineer's advice (thread/786051: *"run the background pre-load only after the app update"*).
  - **I2b (fuller):** register a `BGProcessingTask` on the post-update launch so that if the user backgrounds before recording, iOS runs the respecialization while idle/charging. Best-effort (see §2). Gate behind the Q1/Q2 measurements in `model-load-caching.md`.
- **I2 caveat (legacy guard):** if the `CFBundleVersion` flag lives in the App Group, an Offload-Unused-Apps + iCloud-restore cycle can wipe it (`model-load-caching.md` source thread/95343) → false "fresh install" read. Harmless here (worst case: one extra warm), but note it.

**Effort: I1 = none (already done) / S (the re-run hook). I2a = S. I2b = M.** Policy-risk: none.

---

## Section 2 — Keyboard-entry warm (THE HARD PART) — iOS mechanism analysis

**Division of labor (owner-confirmed, frames this entire section):** the **APP loads the model; the KEYBOARD only shows status.** The keyboard can never warm the model (≤60MB, zero inference). So the two questions for the keyboard-entry path are strictly: **(1) how does the keyboard get the APP to start warming, and (2) how does the keyboard surface that status** (read a cross-process "model warming" flag — §3). It is never "the keyboard warms the model."

The user types in Slack/Messages/Claude, switches to the Jot keyboard, and will tap Dictate. We want the model warm *before* that tap. The keyboard cannot load it; it must get the **main app** to. Here is every public mechanism (for question 1) and its real limit.

### Mechanism A — `extensionContext.open` / `openURL` (the `jot://dictate` bounce)

**Does it foreground the app? YES — that is the whole point, and that is the problem.** The codebase already uses it: `openContainingApp(jot://dictate)` walks the responder chain for `openURL:options:completionHandler:` and calls `UIApplication.open` / `UIWindowScene.open` (`JotKeyboardViewController.swift:2075-2118`, launch URL `:1786`). It **brings Jot to the foreground**, which is exactly what we do NOT want for a background warm — it interrupts the host app.

**Policy + reliability caveats (sourced):**
- Apple documents `NSExtensionContext.open(_:completionHandler:)` as **Today-widget-only**; for keyboard extensions it is **unsupported**, and the responder-chain-walk workaround is explicitly called out as *"very much unsupported"* and *"not allowed"* by Apple staff (Developer Forums thread/65621, thread/104579). The app already relies on this workaround and ships it — a **known, accepted risk** in this codebase, not something to lean on harder. (Sanctioned exception: opening **Settings** via `openSettingsURLString`, QA1924 — which is what `openHostSettings()` does, `:2154-2169`.)
- On iOS 18+ the deprecated bare `openURL:` selector is force-failed; only the typed `open(_:options:completionHandler:)` works, and only with Full Access (`:2060-2067`). The code handles this.

**Conclusion: Mechanism A cannot be a background warm. It is inherently a foreground takeover.** It is only acceptable where foreground is already the case (wizard W5) or where the user *intends* to leave their app (the Dictate tap itself).

### Mechanism B — Darwin notification ("please warm")

**Works ONLY if the main-app process is already alive (foreground or backgrounded-not-terminated). It CANNOT wake a suspended/terminated app.** This is the decisive limit, and it is authoritative:

> Apple DTS (Quinn, Developer Forums thread/769398): *"iOS will not resume your app to receive a Darwin notification. If your app is resumed, it should receive the notification then. If your app is terminated while suspended, it will never receive the notification."*

The codebase already proves both halves of this:
- The **ping/pong** handshake (`resolveForegroundThenStart`, `JotKeyboardViewController.swift:1829-1846`; app pongs at `JotApp.swift:85-96`) exists *precisely because* a Darwin ping is unreliable — the keyboard waits 120ms for a pong and, on **silence, assumes the app is not alive** and falls back to the URL bounce (`startColdViaURLBounce`, `:1861`). Silence = terminated/suspended = no warm possible by Darwin.
- The **warm-resume** path (`warmResumeRequested`, posted at `:1925`, handled at `JotApp.swift:98-151`) is **already gated on a fresh `warmHoldHeartbeat`** (`handleMicCTATap`, `:1905-1909`) — the keyboard only posts the Darwin warm-resume when it has *proof the app is alive* (heartbeat ≤4s old). On a stale heartbeat it clears the ghost and URL-bounces (`:1931-1940`). **This is exactly the liveness gate a "please warm" ping would need, and it already exists.**

**So Mechanism B yields a real but narrow win:** when the main app is backgrounded-alive (most reliably during the **warm-hold window**, but also any time iOS hasn't yet reaped it), the keyboard can post a `keyboardPleaseWarm` Darwin notification on **keyboard appear / first keystroke** (well before the Dictate tap), and the live app starts `transcriptionService.warmUp()`. By the time the user taps Dictate the model is warm. **This is additive to warm-hold** (which already keeps the *mic* warm and the engine resident) — it would only matter once warm-hold has *expired* but the process is still alive, a real but smallish slice.

Confidence: **Confirmed** the mechanism and its limit (Apple DTS + existing heartbeat-gated code). Confidence the incremental win is *worth a new notification*: **Possible** — much of it overlaps warm-hold; measure how often "process alive but engine cold" actually occurs.

### Mechanism C — `BGProcessingTask` submitted from the keyboard (the only true background path)

**A keyboard extension CAN submit a `BGTaskScheduler` request, and iOS launches the CONTAINING APP — not the extension — in the background to run it.** This is the mechanism `model-load-caching.md` / `wizard-model-prewarm.md` discuss for post-update, but the **keyboard-can-submit-it** nuance is the new, load-bearing fact for *this* path:

> WWDC 2019 Session 707 (Advances in App Background Execution), verbatim: *"You can also submit requests from an extension while it's running. So, if our keyboard extension wants to do some learning based on the user's typing habits, it can create a BG processing task request and submit it too … note that that processing task requested from the keyboard extension was delivered to the main app, and that's because it's always the main containing app that is launched to handle background tasks, never extensions."*

So: keyboard `viewWillAppear` → `BGTaskScheduler.shared.submit(BGProcessingTaskRequest(...))` → later, when conditions allow, iOS **launches the Jot main app in the background** → its registered handler runs `warmUp()` → the ANE specialization is paid → next Dictate tap is warm.

**The catch that makes this a "bonus," not the answer:**
- **Best-effort + deferred.** WWDC19-707: tasks run *"when all the necessary system conditions and policies are satisfied"*; `requiresExternalPower`/charging is recommended for heavy work; *"if you [set earliest-begin too far out] and the user doesn't come back to your app in the meantime, we may choose to not launch your task at all."* **No window guarantee.** It will NOT reliably be warm "by the time the user taps Dictate seconds later."
- **Won't run before the app's first-ever foreground launch / after force-quit-by-user** in the usual BG-task caveats (forum thread/131205, /673752: tasks frequently don't fire until iOS has learned usage; a user-force-quit app is deprioritized). For a brand-new install (the worst 45s case) this is precisely when it's least likely to fire.
- **Infra already present:** the app already wires `BGTaskScheduler` + `BGTaskSchedulerPermittedIdentifiers` for `EmbeddingBackfillTask` (`JotApp.swift:225-245`, `:526-530`), so adding a warm-task identifier is incremental, not greenfield.

Confidence: **Confirmed** a keyboard extension can submit and the host app is launched (WWDC + forum). **Confirmed** it is best-effort with no timing guarantee. Net: a legitimate *pre-pay-while-idle* that opportunistically warms a future session; **cannot** be the primary "warm by Dictate-tap" mechanism.

### Mechanism D — push / shared-container signaling

- **Silent push (`content-available`)** *can* wake a backgrounded/terminated app — but it requires a **server**, a network round-trip, APNs registration, and is itself throttled/best-effort. Jot's privacy posture is **"only outbound is the user-initiated feedback POST"** (MEMORY: `project_only_outbound_is_feedback`). A server pushing "warm now" would **break that invariant** and is wildly disproportionate to the goal. **Rejected on policy/privacy grounds.**
- **Shared-container (App Group `UserDefaults`) writes** are pure data; they cannot *execute* anything in the main app unless the app is already alive to observe them (and cross-process observation is via the Darwin notifications of Mechanism B). No independent wake capability. **Not a wake mechanism.**

### The keyboard-entry options, ranked

| Option | Moves the 45s off first dictation? | When it applies | Disruptive? | Policy-safe? | Verdict |
|---|---|---|---|---|---|
| **(a) Warm at Dictate-tap (today's bounce) + make the wait pleasant** | No (load still at tap) — but **capture-first** means audio buffers through it (`JotApp.swift:926-945`), nothing lost | Always (the universal fallback) | No (the tap is the user's own intent to leave) | Yes | **Baseline — keep. Pair with §3 chip + §4 rotation.** |
| **(b) Darwin "please warm" on keyboard-appear when app is alive** | **Yes**, but only for the backgrounded-alive subset | App alive (esp. warm-hold-expired-but-not-reaped) | No (background, no foreground change) | Yes (Darwin is on-device) | **Worth it IF measurement shows a meaningful "alive but engine cold" slice.** Reuse the warm-resume heartbeat gate. |
| **(c) Foreground warm-on-keyboard-idle-appear via the bounce** | Yes, but by **foreground-launching** | ONLY when Jot is already foreground (wizard W5) | **YES — unacceptable in any other-app host** | Only safe in the W5 case | **Restrict to W5 (already effectively handled by the wizard prewarm).** Never in a third-party host. |
| **(d) `BGProcessingTask` from keyboard** | Sometimes (opportunistic, idle/charging) | App terminated, device later idle/charging | No | Yes (sanctioned per WWDC) | **Add as pure upside; never rely on it.** Least likely to fire on a fresh install — the worst case. |

**Recommended keyboard-entry behavior = (a) always + (b) when alive + (d) opportunistic.** (c) stays confined to W5. There is no combination that makes a *terminated-app* keyboard entry warm-by-tap without a foreground takeover — state that plainly to the owner.

---

## Section 3 — Warming status indicator in the keyboard (idle, before dictation)

### Where it must live (confirmed)

The idle keyboard renders **`RecentsStrip`**, not `StreamingStrip`. Strip selection is `if recordingState.isRecording { StreamingStrip } else { RecentsStrip }` (`KeyboardView.swift:336-380`, helper `topStripContent`). The existing "Loading [variant]…" label + spinner is **inside `StreamingStrip`** (`StreamingStrip.swift:52-61`, `loadingLabel`), shown only while recording. So the cold-load affordance is **invisible in the idle keyboard today** — there is no warm indicator before dictation. This matches the owner's ask.

The reusable header slot the owner referred to (the pulsing dot + `statusLine`) is the **`StreamingStrip` header** (`StreamingStrip.swift:123-189`: `PulsingBlueDot` at `:149`, `statusLine` at `:173-181`) — again, recording-only.

### The cross-process signal (what the keyboard would read)

There is **already a precedent to clone**: while *recording*, the main app writes `AppGroup.streamingLoadingVariantLabel` + `streamingLoadStartedAt` + `streamingLoadEstimateSeconds` on every `sessionLoadState` transition (`StreamingTranscriptionService.swift:110-127`), posts `streamingLoadingChanged` (Darwin), and the keyboard mirrors it (`refreshStreamingLoadingFromProjection`, `JotKeyboardViewController.swift:1401-1411`). The "warming-before-recording" indicator needs the **same shape, decoupled from `isRecording`**:

- **New App-Group flag**, e.g. `AppGroup.modelWarming` (a `Bool`/timestamp) — written `true` by `TranscriptionService.warmUp()`/`loadOrFail` at `.loading` (`TranscriptionService.swift:875`) and cleared at `.ready`/`.failed` (`:889`, `:958`). Mirror the existing `streamingLoadStartedAt`/`EstimateSeconds` so the keyboard can pace a small bar/spinner identically (and reuse `ColdStartCopy.revealThreshold` 2.5s so a *warm* load never flashes the chip — `ColdStartCopy.swift:33`, already read cross-process for exactly this reason).
- **New Darwin name** `modelWarmingChanged` alongside the existing `streamingLoadingChanged` (`CrossProcessNotification.swift:44`), so the keyboard re-renders on transition rather than polling.
- The label string must stay a **resolved display string** written by the app (never a variant tag) — the keyboard must not link `SpeechModelVariant`/`FluidAudio` (the 60MB ceiling reason documented at `AppGroup.swift:62-68`). Same constraint already honored for `streamingLoadingVariantLabel`.

**Crucial honesty caveat (the §2 verdict bites here):** this chip can only ever light up when the main app is **alive to write the flag**. In the common terminated-app case, *nothing warms before the Dictate tap*, so **there is nothing to show in the idle keyboard** — the warming chip would only appear in the Mechanism-B (alive) and Mechanism-D (BG-task fired) cases. Be explicit with the owner: the idle warming chip is a *nice-to-have for the warm-process subset*, not a universal "we're getting ready" badge. (It DOES light up cleanly in the W5 wizard case, where the app is foreground.)

### How to render it (non-disruptive, not "recording")

**ONE copy source — do NOT build a second message system (owner directive).** The cold-load copy already lives in `ColdStartCopy` (`recurringLines` + `firstEverLine`). The pre-dictation warming chip must **draw from that same source**, not a brand-new "warming…" message set. It is acceptable *for now* if the chip and the streaming panel look slightly distinct (the chip is a compact idle-header affordance; the panel is a full recording strip), but **explicitly do not stand up parallel message machinery** — `ColdStartCopy` stays the single source of truth for cold-load copy, and the chip renders a `recurringLines` entry (rotated per §4) just as the panel does. (A short fixed lead-in like "Getting ready" is fine as chrome around the same line, but the *message* is the shared copy, not a new string table.)

Add a small **warming chip in the `RecentsStrip` header**, next to "Recent"/"See all" (`RecentsStrip.swift:122-160` header `HStack`) — NOT a pulsing *blue* dot (that reads as live recording). Use a **neutral/grey** dot + a quiet spinner + the shared `ColdStartCopy` line (§4), styled with the chrome token `JotDesign.Surface.key` per MEMORY `project_chrome_control_design_token` (never ad-hoc `.ultraThinMaterial`). It must:
- be visually distinct from the recording cue (no red stop, no blue pulse — the blue `PulsingBlueDot` is reserved for active capture);
- be an **overlay/inline** that does not reflow the recents rows (the header already uses an `.overlay` for its press hint at `:148`, same pattern);
- respect reduce-motion (text/static, not animation) — the keyboard constraint `ColdStartCopy` already notes.

**Effort: M** (new App-Group flag + Darwin name + app write-sites + keyboard observer + a header chip). **Policy-risk: none.** Impact: only the warm-process/W5 subset sees it — gate the work behind whether §2(b) is built (they share the alive-app precondition).

---

## Section 4 — Cold-load line rotation (rotate every ~10s within a single load)

### Current behavior (confirmed)

`ColdStartCopy.recurringLines` is a 3-entry array (`ColdStartCopy.swift:43-47`); `beginningLine()` advances the persisted rotation index **once per load** (`:72-79`) — so *consecutive separate* cold loads differ, but **within one 45s load the string is written once and never changes**. It's written into `AppGroup.streamingLoadingVariantLabel` at `.loading` (`StreamingTranscriptionService.swift:114-115`) and both surfaces render it verbatim; nothing re-reads on a timer. The wizard-only koan `firstEverLine` ("This is the slow part…") is gated on `AppGroup.wizardActive` (`:73`) and **must stay single, non-rotating** (you only see it once — `ColdStartCopy.swift:37-38`, `:55-67`).

### Mechanism sketch (parallel UX item; deterministic cross-process)

The two surfaces (recording hero in-app, keyboard strip cross-process) must rotate **in lockstep** or the user could see different lines on each. The clean way is **time-derived from a single shared start timestamp**, which already exists: `AppGroup.streamingLoadStartedAt` (`AppGroup.swift:458-467`) (and the proposed `modelWarming` start time for the idle case).

- Both surfaces compute the displayed index as `floor(elapsed / 10s) % recurringLines.count`, where `elapsed = now − sharedLoadStart`. No shared mutable rotation state, no cross-process write per tick — each surface ticks its **own** `TimelineView`/timer off the **same** timestamp + the **same** bundled array, so they stay identical by construction. (The keyboard already paces the streaming bar off `streamingLoadStartedAt` this way — `StreamingStrip.swift:465`.)
- Drive it with a ~10s `TimelineView(.periodic(...))` (or a lightweight timer) that only advances **after** `ColdStartCopy.revealThreshold` (2.5s) and while still not `.ready` — so a fast warm load never even shows line #1, let alone rotates.
- **Keep the koan non-rotating:** when `AppGroup.wizardActive`, render `firstEverLine` statically; rotation applies only to `recurringLines`. `beginningLine()`'s once-per-load advance still picks the *starting* recurring line so the rotation phase differs run-to-run; the in-load timer advances from there.
- Respect reduce-motion: it is a **text swap**, not animation — already the design intent (`ColdStartCopy` doc).

**Effort: S–M** (a timer + an index function on both surfaces + reading the shared timestamp the keyboard already reads). **Policy-risk: none.** Impact: medium — turns a 45s "frozen line" into "still working," directly addressing the "feels stuck" complaint. Pure presentation; zero effect on load time or the caching mechanism.

---

## Ranked recommendation + sequence

Effort: S = <½ day · M = 1–3 days · L = >3 days. Impact = how much it reduces *perceived* first-dictation pain. Policy-risk: App-Store / privacy exposure.

| # | Item | Section | Impact | Effort | Policy-risk | Notes |
|---|---|---|---|---|---|---|
| 1 | **Unify the warm path (relax gate to models-on-disk; delete the wizard's warm)** | §1 U1–U3 | Med (correctness/maintainability) | S | None | One predicate covers app-open + wizard + keyboard-bounce. **Foundational — do first.** |
| 2 | **Cold-load line rotation (in-load, every ~10s)** | §4 | Med | S–M | None | Pure UX, one copy source (`ColdStartCopy`), hits the "feels frozen" complaint on every cold load. |
| 3 | **Post-update calibrated-bar surfacing (I2a)** | §1 | Med | S | None | App-open path; Apple-endorsed "hide it after update." Reuses existing bar + launch warm. |
| 4 | **Idle-keyboard warming chip (same copy source)** | §3 | Low–Med | M | None | Reads the cross-process warming flag; draws from `ColdStartCopy` (no new message set). Only lights up when app is alive / BG-task fired / W5. Build *with* #5 (shared alive-app precondition). |
| 5 | **Darwin "please warm" on keyboard-appear when app alive (Mechanism B)** | §2(b) | Low–Med | M | None | Reuse warm-resume heartbeat gate. **Gate on measurement** of the "alive-but-engine-cold" slice — much overlaps warm-hold. |
| 6 | **`BGProcessingTask` warm from keyboard + post-update (Mechanism C / I2b)** | §2(d)/§1 | Low (opportunistic) | M | Low | Pure upside, never relied on; least likely to fire on the fresh-install worst case. Reuse `EmbeddingBackfillTask` infra. |
| — | **Foreground warm-on-keyboard-appear in a third-party host (Mechanism c)** | §2(c) | — | — | **High/unacceptable** | **Do NOT build.** Yanks the user out of their app. W5 case only. |
| — | **Silent push to wake app (Mechanism D)** | §2 | — | — | **Unacceptable (privacy)** | **Do NOT build.** Breaks "only outbound is feedback." |

**Recommended sequence:** **#1 (unify the warm path) → #2 (line rotation) → #3 (post-update bar)** — all small, no new cross-process plumbing, and #1 is the foundation that makes "warm whenever active + on-disk" true everywhere. Then, *only if on-device measurement shows the warm-process slice is real*, **#4+#5 together** → **#6** as opportunistic polish. Stop before #c/#D — they are the disqualified options the verdict rules out.

**The single most important thing to tell the owner:** for the terminated-app keyboard entry — the exact moment the 45s hurts most (fresh install / post-update / post-offload, app not running) — **there is no iOS-legal way to warm the model in the background without foreground-launching the app.** Every "background warm" option here (B, C) works only when the process is already alive or when iOS later chooses to run a best-effort task. The realistic engineering is therefore **(1) hide it on the app-open path (already done + #2), (2) make the unavoidable keyboard-tap wait honest and alive (#1, capture-first, #3 where applicable), and (3) opportunistically pre-pay when the OS lets us (#4/#5).** "Seamless no matter how the user enters" is achievable for app-open and the warm-process keyboard subset; for the cold keyboard subset it is a UX problem, not a pre-warm problem.

---

## Open questions to settle on-device (no new measurement built here)

1. **How large is the "main app alive but engine cold" slice?** (decides whether §2(b)/#4 is worth the cross-process plumbing). Warm-hold already covers the just-recorded window; this is the *expired-warm-hold-but-process-not-reaped* slice. Log it.
2. **Does a keyboard-submitted `BGProcessingTask` ever actually fire on a fresh install before first foreground?** (the worst-case 45s). Forum evidence says rarely (#5 caveat) — confirm before investing.
3. **Cross-process line-rotation drift:** confirm hero + keyboard show the *same* line at the same wall-clock second when both are visible (they shouldn't both be visible often, but W5 + a quick app-switch could). The time-derived index should make this exact; verify.
4. Inherit all `model-load-caching.md` Q1–Q6 measurements (per-model load split, post-update vs warm spread, BG-warmed-cache-survives-to-foreground) — they set the `ModelLoadTimekeeper` estimates the bar/rotation pace against.

---

## Sources

External (this doc's new findings):
- WWDC 2019 Session 707 "Advances in App Background Execution" — **a keyboard extension can submit a `BGTaskScheduler` request; iOS launches the containing app (never the extension) to run it; tasks are best-effort/deferred with no guaranteed window**: https://asciiwwdc.com/2019/sessions/707
- Apple Developer Forums thread/769398 (DTS / Quinn) — **"iOS will not resume your app to receive a Darwin notification … If your app is terminated while suspended, it will never receive the notification."**: https://developer.apple.com/forums/thread/769398
- Apple Developer Forums thread/65621 + thread/104579 — **`extensionContext.open` is Today-widget-only; for keyboard extensions it is unsupported and the responder-chain `openURL` workaround is "not allowed" / "very much unsupported"** per Apple staff: https://developer.apple.com/forums/thread/65621 , https://developer.apple.com/forums/thread/104579
- Apple TQA QA1924 "Opening Keyboard Settings from a Keyboard Extension" — the **one sanctioned** keyboard `openURL` (Settings): https://developer.apple.com/library/archive/qa/qa1924/_index.html
- Apple `BGTaskScheduler` docs + forum thread/131205, thread/673752 — best-effort scheduling, frequently won't fire until iOS learns usage / deprioritized after user force-quit: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler , https://developer.apple.com/forums/thread/131205
- Darwin-notification cross-process background-delivery limits (corroborating): https://developer.apple.com/forums/thread/769398 ; overview: https://rizwan95.medium.com/send-data-between-ios-apps-and-extensions-using-darwin-notifications-da680fe21ad0
- Carried forward from `model-load-caching.md`: path-keyed ANE cache, update busts it, no query API (Apple eng. thread/786051 — *"run the background pre-load only after the app update"*): https://developer.apple.com/forums/thread/786051

Repo references:
- `Jot/App/JotApp.swift` — launch warm `:309-320`; scene `.task` warm (SetupCompletion-gated) `:573-594`; ping/pong pong `:85-96`; warm-resume handler `:98-151`; `onOpenURL` `:405-464`; scene-phase/heartbeat `:498-538`; BGTask infra `:225-245`,`:526-530`
- `Jot/Keyboard/JotKeyboardViewController.swift` — URL bounce `:1786`,`:2075-2118`; ping/pong `:1816-1882`; `handleMicCTATap` + warm-resume heartbeat gate `:1884-1940`; streaming-loading mirror `:1392-1411`; keyboard-active heartbeat `:272-279`,`:316`
- `Jot/Keyboard/KeyboardView.swift` — idle vs recording strip selection `:336-380`
- `Jot/Keyboard/RecentsStrip.swift` — idle strip + header (warming-chip insertion point) `:31`,`:122-160`
- `Jot/Keyboard/StreamingStrip.swift` — recording-only header (dot `:149` + `statusLine` `:173-181`), `loadingLabel` `:52-61`, load-bar pacing off shared timestamp `:465`
- `Jot/Shared/AppGroup.swift` — `streamingLoadingVariantLabel`/`streamingLoadStartedAt`/`streamingLoadEstimateSeconds` `:451-474`, 60MB-no-FluidAudio-link rationale `:62-68`, foreground/keyboard heartbeats `:164-187`,`:296-320`
- `Jot/Shared/ColdStartCopy.swift` — `recurringLines` `:43-47`, `beginningLine()` once-per-load `:72-79`, koan gate `:37-38`/`:73`, `revealThreshold` `:33`
- `Jot/Shared/CrossProcessNotification.swift` — `streamingLoadingChanged` `:44` (clone for `modelWarmingChanged`)
- `Jot/App/Transcription/TranscriptionService.swift` — `warmUp()`/`ensurePreparing` idempotent `:199-208`, `modelState` transitions `:875`/`:889`/`:958`
- `Jot/App/Transcription/StreamingTranscriptionService.swift` — `sessionLoadState` → AppGroup write `:110-127`
