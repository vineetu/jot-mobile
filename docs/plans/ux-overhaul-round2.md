# Jot UX Overhaul — Round 2

**Status:** Design / brainstorm. Not yet implementation-approved.
**Predecessor:** `Jot/tmp/ux-overhaul-plan.md` (the May-11 v0.9 design-system + mockup plan, now shipped). This round refines behavior on top of that shipped design.
**Source of intent:** the "Features That Would Change (from the UX review)" doc the user provided. Section IDs below map to `Jot/features.md`.

---

## 0. Scope

**In scope (this cycle):**

- **WS-A — Streaming + italic treatment** (C1, C1b, §2.3, §5.3, §1.2)
- **WS-B — Inline dictation everywhere in-app** (C6, §3.7)
- **WS-C — Hero surface cleanup** (§2.2, §2.4, §2.7, + new Pause)
- **WS-D — Keyboard restructure** (C4, §5.1, §5.4, §5.8, §5.10, §5.12, §2.6)
- **WS-E — Home & library polish** (§1.1, §1.9, §1.11)
- **WS-F — Micro-messaging + warm-hold switching nudge** (C5, §13.2 warm hold)
- **WS-G — Transcript detail panel** (§3.5)
- **Privacy copy correction** — ✅ DONE this session (see §7).

**Out of scope / parked:**

- **§4 Setup Wizard** — entirely parked per user (C3 onboarding, §4.1, §4.4; the §4.6 warm-hold *opt-in panel* is wizard, but the runtime *nudge* below is NOT — it lives on the keyboard/hero).
- **R1 — keyboard crash recovery** of in-progress text — parked; "let's talk later."

---

## 1. Locked decisions

1. **Streaming stays, capped.** Italic, bottom-anchored, older text scrolls up and fades at the top. Hero ≈3–3.5 lines; keyboard ≈2.5–3.5 lines. Home preview (§1.10) **unchanged this round**.
2. **Italic = live/streaming only.** Final/saved transcript text renders **regular** everywhere (featured entry §1.2, detail §3). Featured entry stays slightly larger.
3. **Hero is for *targetless* capture only.** It appears for: (a) the **home Dictate button**, and (b) the **cold-start keyboard foregrounding Jot from another app** (no warm-hold session). Every other *in-app field* dictation (Edit §3.7, Ask §14.2, keyboard-while-already-in-Jot) records **inline into the field and saves no separate transcript**. ⚠️ **SCOPE (review fix):** "saves no transcript" applies to **in-app field dictation only**. The shipped **warm-hold keyboard path keeps saving its transcript and auto-pasting** (features.md §13.2/§5.13) — do NOT apply the no-transcript rule there. See the keyboard-origin state matrix in §9.
4. **Keyboard = recording controls + Apple's system row only.** No custom typing keys. The build-72 **"Open Jot" key is removed** (done — revisit after user tests the new format). Spacebar + "return to Jot" + minimize/expand button + char-key preview all go in WS-D. Apple's fixed bottom row (globe/system) stays.
5. **Warm-hold default → 120s (2 min).** `AppGroup.warmHoldDurationSeconds` default `60 → 120`; picker already offers "2 min". No migration (UserDefaults default read at call time, pre-launch).
6. **Warm-hold switching nudge** (full math in §4): fires after a stop when ≥3 consecutive "qualifying returns" are detected; suppressed when warm hold already on; re-shows each qualifying burst until the user either turns warm hold on or taps a one-click **"Don't show again"** (no confirmation step). Passive ignore does NOT suppress.
7. **Resizable AI panel (§3.5) ships only if the drag is genuinely smooth.** If not smooth, ship a fixed (bigger) panel and add no resize at all.
8. **Sequencing:** WS-B (inline) + WS-A (streaming) first — the structural/risky pair — then the cosmetic layer (WS-C/D/E/F/G).

---

## 2. Workstreams

### WS-A — Streaming + italic treatment
**Current:** hero live text fills the page fading at top (§2.3); keyboard strip ~6–7 lines (§5.3); featured entry + detail render transcript text italic (§1.2, §3).
**Change:** one shared "capped fading stream" treatment, built once, applied to hero (~3.5 lines) and keyboard (~2.5–3.5 lines) — italic, bottom-anchored (newest at bottom), older scrolls up + fades. Separately, strip italic from **final** transcript text so italic exclusively signals "live."
**Risk:** the bottom-anchored scroll-up-and-fade is fiddly in SwiftUI — prototype first. This is the highest-risk visual change.
**Files (likely):** `Jot/Keyboard/StreamingStrip.swift`, hero recording view, `RecentsListCard`/featured-entry view, `TranscriptDetailView`.

### WS-B — Inline dictation everywhere in-app
**Current:** dictating from Edit (and keyboard-while-foregrounded-in-app) wrongly pushes the full-screen hero.
**Change:** in-app dictation records **in place**, mirroring the Ask Jot inline pattern (§14.2) and reusing the `ownsActiveRecording` lifecycle machinery built in build 72. Inline dictation **pastes into the current field, saves no transcript**. Hero remains reachable only via the two targetless paths (decision #3).
**Risk:** real behavioral blast radius — recording lifecycle, hero-adoption guards, the ownership flag. Needs its own careful design pass + on-device verification.
**Files (likely):** `TranscriptDetailView` (Edit), Ask already done, `ContentView` hero-adoption guards, `RecordingService` start sites (preserve `RECORDING START FROM:` logs per CLAUDE.md).

### WS-C — Hero surface cleanup
**Change:** remove the amplitude waveform (§2.4); keep a timer/recording indicator (§2.2). Freed top space carries rotating micro-messages (WS-F). Add **Pause/Resume** (new — currently only Stop/Cancel/Background); Pause does not finalize. **Two-path streaming behavior** — see §2a below.

#### §2a — Hero streaming: two entry paths, two behaviors

The hero has two ways in, and they get **opposite** streaming treatment. **Recording (audio capture) starts immediately in BOTH** — only the *display* of the live stream differs.

**Why:** the keyboard→hero path exists only because Apple forces the app to foreground to record (the keyboard extension can't capture in-process the way we'd want). We would prefer the user **not** be on this screen at all — ideally they dictate straight from their own app. So when they arrive via the keyboard, this surface's job is to **send them back to their app**, not to keep them watching a stream. When they arrive via the app's own Dictate button, they *chose* to be here, so we show the stream right away.

| | **App Dictate button** (chosen) | **Keyboard → hero** (Apple-forced) |
|---|---|---|
| Recording (audio) | starts immediately | starts immediately |
| Live stream display | shown **instantly**, regardless of dictation length | **withheld at first** |
| Surface's goal | let them watch / stay | nudge them to **swipe back to their app** |

**Keyboard-initiated timeline** (recording throughout; stream visually withheld):
1. **t=0** — hero opens. Instead of the stream, show info/reassurance panels. Primary message is **instructional, not a rhetorical question** — state the option and show how, no "why don't you…" (reads condescending). Copy candidates: *"Go back to your app"* / *"Here's how to swipe back to your app."* Keep recording running while they leave.
2. Show a **static image** of the swipe-back gesture first.
3. **After a short delay** — a small **animation (~3–4s)** demonstrating the gesture. ⚠️ **GESTURE CORRECTION (research):** the real iOS "return to the previous app" gesture is a **horizontal swipe RIGHT along the bottom home-indicator / gesture bar** — NOT "up from the bottom-left." This is confirmed by Apple and by Jot's own shipped copy (features.md §2.7 "swiping right along the iOS app-switcher gesture bar"). The animation must depict the **rightward** drag. See §8 decision D1.
4. **Stream reveal = `max(coaching-window beat, first real partial token)`** — NOT a bare ~10s wall-clock. ⚠️ **(review fix):** gate the fade-in on the first real partial token so the pane is never empty (if the model is still loading at 10s, a wall-clock reveal would show an empty pane). The ~10s is just the upper bound of the coaching window; reveal when there's real text AND the coaching has had its beat. During the withhold window the **placeholder branch ("Listening…/Loading…") must also be suppressed** (it currently renders whenever text is empty), and a **recording indicator (red dot + timer) stays visible** so "Jot keeps listening" has on-screen proof. Then **fade in slowly from transparent → translucent** (rising out of the background, never snapping on).

**App-Dictate-initiated:** stream shows immediately, full treatment (capped italic, bottom-anchored, fading — WS-A). No swipe-back coaching; the user is here on purpose.

### WS-D — Keyboard restructure
**Change:** remove spacebar, "return to Jot", minimize/expand (§5.8), char-key preview (§5.12); Open Jot already removed. Keep Apple's system row. Add one **adaptive Enter** (return-arrow / search glyph / Go / Send by context). Control set: **Pause + Stop + Cancel**, Cancel as a **trash-can on the left** for reach (§2.6/§5.4). Native **side margins** (~0.4cm each side — verify vs Apple's standard) so it doesn't span full width; **fixed keyboard height**. Keep Actions popover (§5.6). Make the top time bigger / ~2 lines (§5.10). Goal: controls + Enter in **one line**.
**Note:** §5.10 documents a real collapsed-state banner bug (see CLAUDE.md) — removing minimize/expand may interact with it; check.

### WS-E — Home & library polish
**Change:** remove the "Recents." headline → "What do you want to dictate today?" CTA (§1.1), which also hosts adaptive micro-messaging. Replace the "JS" avatar with a **bigger gear** icon, light/dark aware (§1.9). Make multi-select **discoverable from the swipe gesture** (§1.11) — swipe reveals Delete + a path into selection (Mail/Instagram pattern). Lower risk, mostly cosmetic.

### WS-F — Micro-messaging + warm-hold switching nudge
**Change:** a shared **shuffled-hint** component across home (§1.1), hero freed top space (§2.2/§2.7 — "switch back to your app / voice frees your mind / a stronger transcriber runs after you stop"), and the warm-hold nudge. **Presentation still to be designed.** The warm-hold switching nudge math is in §4 below; build the generic micro-message component here, plus the nudge trigger + its two-action affordance.

### WS-G — Transcript detail panel
**Change:** rename "Transform" → **"Articulate"**; primary clean-up action labeled **"Cleanup"** (§3.5). AI panel **bigger**, or **user-resizable by dragging** — but only if smooth (decision #7).

---

## 3. State / schema impact

- **Warm-hold nudge** needs a small **ring buffer of the last ~4 recording-stop timestamps** + a `Date` of the last recording-start, plus a `nudgeSuppressed` Bool and the streak counter. **All in App-Group `UserDefaults`** (shared keyboard ↔ app), **NOT** SwiftData `@Model`. → **No schema version bump, no migration.**
- Inline dictation (WS-B) **saves no transcript** for in-field dictations — which is exactly why the nudge can't rely on `Transcript.createdAt` and needs its own stop-timestamp buffer.
- Warm-hold default change is a UserDefaults default constant, not stored state.

---

## 4. Warm-hold switching nudge — detection math

**Principle.** Warm hold keeps the mic ready for `W` seconds after a stop. A return that warm-hold-on *would have made instant* is exactly one where:

```
start[i] − stop[i−1]  ≤  W          (W = live AppGroup.warmHoldDurationSeconds, default 120s)
```

Keying off the live setting makes it self-defining (no magic "rapid" threshold) and auto-adjusting if the user changes their warm-hold duration.

**Streak.** On each stop, compare to the previous stop's start:
- gap ≤ W → increment streak (a qualifying return).
- gap > W → reset streak to 0 (a real break; not fighting the swipe).

**Fire** when **streak ≥ 3** qualifying returns (≈4 recordings in tight succession; at the 120s default this spans a few minutes of record-and-bounce).

**Suppression / lifecycle:**
- Only when warm hold is currently **OFF** (it's the off-state nudge; if on, it's meaningless).
- **Re-shows on every qualifying burst** until ONE terminal state:
  1. user turns warm hold **ON** (satisfied → never again), or
  2. user taps **"Don't show again"** — a **single tap, no "are you sure?"** — sets a permanent `nudgeSuppressed` flag.
- **Passive ignore ≠ suppression.** If the nudge auto-hides without a tap, it returns next qualifying burst.

**Affordance.** Inline on the surface they just stopped on (keyboard strip, or hero freed top space). Two actions: **[Keep mic ready]** (flips warm hold on) and one-tap **[Don't show again]**. Copy candidate: "Tired of switching back and forth? Keep the mic ready."

**Cancelled recordings don't count** toward the buffer.

---

## 5. Sequencing

- **Phase 1 (foundation, risky):** WS-B inline dictation + WS-A streaming/italic. Verify on-device before layering.
- **Phase 2:** WS-C hero cleanup (incl. Pause + delayed streaming) + WS-D keyboard restructure.
- **Phase 3 (cosmetic/additive):** WS-E home polish, WS-F micro-messaging + warm-hold nudge, WS-G detail panel.

Warm-hold default change (#5) is a trivial standalone edit; can land any time.

---

## 6. Open / still-to-design

1. **Micro-message presentation** (WS-F) — rotation cadence, placement, animation undefined.
2. **Resizable AI panel smoothness gate** (WS-G) — prototype the drag; ship fixed-bigger if not smooth.
3. **Adaptive Enter glyphs + ~0.4cm side margin** (WS-D) — verify against Apple's current keyboard behavior.
4. **R1 crash recovery** — parked, needs its own diagnosis.
5. **§5.10 collapsed-banner bug** interaction with minimize/expand removal — confirm.

---

## 7. Done this session

- **Privacy copy** corrected so the blanket "nothing leaves your device" claim names the one exception (Send Feedback). Updated: Settings footer, Settings → Privacy caption, Help → Privacy bullet, and `features.md` §13.6 + the two caption mirrors (§6.4, §9.5) with a bidirectional cross-link to §9.6 Feedback Contact. The audio-specific "Audio never leaves the device" line left intact (accurate). See memory `project_only_outbound_is_feedback`.
- **"Open Jot" keyboard key removed** (`KeyboardView.bottomRow`); `onOpenHome` plumbing retained for RecentsStrip "See all". `features.md` §5.1 already described the bottom row as space+return only, so no doc edit needed.

---

## 8. Round-2 UX research findings (adversarially verified)

Four topics researched + each adversarially validated (workflow `ux-research-round2`, 8 agents). Validated outcomes below; **decisions that need the user are marked D1–D3**.

### WS-F — CTA & micro-messaging  *(verified, one critical descope)*

**One rotation engine, three configured instances** (different pool/dwell/animation):
- **Home header CTA** — editorial serif-italic *headline* replacing "Recents." (WS-E), shuffled, **8s** dwell, cross-dissolve + 4pt rise.
- **Hero freed-top-space** (keyboard path) — **sequenced** (it tells a story), **5s** dwell, opacity-only fade.
- **Warm-hold nudge** — one-shot, spring-in, no rotation; auto-hide ~6s if untouched (passive ignore ≠ suppression).

**Home CTA pool** (tag `.anywhere` = the speak-anywhere thesis; `.universal` = true regardless):
1. "Speak it straight into your last app." · 2. "Your keyboard can talk — tap the globe and dictate anywhere." · 3. "Skip the typing. Dictate into any app you're in." · 4. "Mid-message thought? Say it into the field you're already in." · 5. "Dictate into Mail, Notes, Messages — anywhere a keyboard goes." · 6. "What do you want to dictate today?" (anchor) · 7. "Say it out loud and let your hands rest." · 8. "Think out loud — Jot keeps up." · 9. "Talk faster than you type. Start here." · 10. "Say the messy version — tidy the wording later."

**Hero top-space** (sequenced H1→H4; H5 is PINNED as the stream-arrival caption, not buried in rotation, so it's actually seen):
- H1: "You can head back to your app — swipe **[right]** along the bottom. Jot keeps listening." *(gesture wording pending D1)*
- H2: "Recording stays on while you go. Your words land back in that field."
- H3: "You don't have to watch this — looking away helps you find the words."
- H4: "The thinking happens out loud, not on the screen."
- H5 (stream caption): "A sharper transcriber takes a second pass when you stop and tidies the live text."

**Warm-hold nudge:** headline "Bouncing back and forth to dictate? Keep the mic ready and skip the wait." · accept "Keep mic ready" · dismiss "Don't show this again".

**⚠️ CRITICAL — behavior-adaptive gate has NO data source.** Keyboard-initiated recordings save as `source: "main-app"` (the keyboard foregrounds the app to record; it can't write SwiftData), indistinguishable from the home Dictate button. No App-Group per-surface counter exists. → **See decision D2.**

### Swipe-back animation  *(two critical corrections)*

- **⚠️ Wrong gesture** — it's a horizontal swipe RIGHT along the home indicator (see §2a correction + D1).
- **⚠️ Reconcile with shipped code** — `ColdStartNudgeOverlay` (RecordingHeroView.swift) already coaches "Swipe back to your app" for `heroIntent == .coldStartFromExternalKeyboard`: glass pill, `chevron` in `Color.jotBlueTop` (#1A8CFF — the real brand blue token, NOT system blue / NOT coral `jotAccent`), 4s auto-dismiss, tap-dismiss, **suppressed after 7 shows** via UserDefaults `jot.hero.coldStartNudgeShownCount`. §2a **evolves this overlay**; keep the 7-show suppression so power users who know the gesture stop seeing coaching.
- **Finite animation, under ~5s total** (2 cycles, ~1.2s drag + ~0.4s rest ≈ 3.2s) → matches plan "~3–4s" and clears WCAG 2.2.2 cleanly. Ghost touch-point (~26pt, ~70%, luminance-inverted per colorScheme) + horizontal comet trail + rightward chevron, anchored on a dimmed mini home-indicator pill, dragging left→right.
- **Drop the "app-tile thumbnail returns" cue** — the app can't render the host app's icon/snapshot.
- **Reduce Motion:** static end-frame, opacity-only stream cross-dissolve. **VoiceOver:** use `.announcement` (NOT `.screenChanged`, which fights the hero's existing `recordingStatusFocused`).
- **Stream fade-in gated on the FIRST real partial token**, not a wall-clock, so the pane is never empty.

### WS-G — Resizable AI panel  *(verified; decision #7 effectively pre-passed)*

It's **already a system sheet** (`TranscriptDetailView.swift:286` → `.sheet`; `RewritePickerSheet.swift:99` `.presentationDetents([.height(360)])`). Smoothness is UIKit's job — **do NOT hand-roll a `DragGesture` height** (that's the documented jitter). Just add detents:
```swift
@State private var detent: PresentationDetent = .height(360)
.presentationDetents([.height(360), .fraction(0.72), .large], selection: $detent)
.presentationDragIndicator(.visible)
.presentationContentInteraction(detent == .height(360) ? .resizes : .scrolls)
.presentationCornerRadius(JotDesign.Spacing.sheetRadius) // 24, already there
```
- **Smallest detent must stay `.height(360)`**, NOT `.fraction(0.45)` (that regresses iPhone SE to ~300pt and clips the header/subline/footer, which live OUTSIDE the inner ScrollView).
- **Do NOT add `presentationBackgroundInteraction`** — wrong default for a modal picker (mis-tap risk on the transcript behind).
- **Renames:** "Transform"→"Articulate" = `TranscriptDetailView.swift:773` (one line); in-sheet title `RewritePickerSheet.swift:117`. **"Cleanup" on the default row is NOT a one-line edit here** — it's the `SavedPrompt.defaultArticulate` seed; scope separately.
- Decision #7 gate is effectively pre-passed (smooth path = system sheet); the fixed-bigger fallback is the identical file with a single detent. So **ship resizable.**

### WS-D — Adaptive Enter glyph  *(verified solid; one escalation)*

- The host field's `returnKeyType` **IS readable** and already wired (`textDocumentProxy.returnKeyType` → `KeyboardView.returnTitle`). No new plumbing.
- **Change:** `.default` / `@unknown default` → render Apple's return-arrow glyph **`arrow.turn.down.left`** (the down-then-left ↵ — **user-confirmed via reference screenshot of the system keyboard; match it exactly**; currently shows the word "Return"). Search fields (`.search`/`.google`/`.yahoo`) → **`magnifyingglass`** glyph (D3). Every other explicit case keeps a word. Requires refactoring `returnTitle: String` → an enum `{ glyph(name), word(text) }` (the accessibilityLabel at line 733 currently derives from `returnTitle.lowercased()`). Glyph font **15/semibold** to match the returnAccent face.
- Add a `renderRootViewIfReturnKeyTypeChanged()` re-render hook mirroring the existing appearance hook, so a host that flips `returnKeyType` mid-session updates the label.
- `isSecureTextEntry` needs **zero** handling (iOS swaps in the system keyboard for secure fields). Keep Enter on brand-blue `returnAccent`. Don't churn "Emergency"→"SOS".
- **⚠️ ESCALATION** — plan §WS-D said "search glyph" for search fields; research recommends the **word "Search"** instead (matches Apple; a lone magnifier on a commit key reads as a search-field affordance). → **See decision D3.**

### Decisions resolved (D1–D3)

- **D1 — Swipe coaching → coach BOTH return methods. Pill CONFIRMED present (on-device).** Two ways back to the host app: (1) swipe RIGHT along the bottom gesture bar (always available), and (2) the "‹ Back to [App]" pill iOS draws top-left. ✅ **On-device check:** the user confirmed the pill *does* appear — the review's skepticism was wrong; opening `jot://dictate` is an inter-app navigation so iOS draws the breadcrumb, and it shows on exactly the `heroIntent == .coldStartFromExternalKeyboard` path §2a coaches. **DECISION (user):** assume the pill is reliably present whenever the keyboard opens the app (the cold-start path), and **coach the pill ONLY on that path** — gated to `heroIntent == .coldStartFromExternalKeyboard`, which is the only path §2a coaches anyway. Coach **both** methods there (alternate swipe/pill across sessions per "once this, once that"). No programmatic pill-detection needed since we only surface it where we assume it appears; the swipe remains the always-reliable method riding alongside. Build by **evolving `ColdStartNudgeOverlay`**. Swipe variant: left→right home-indicator drag, `Color.jotBlueTop` chevron, finite ≤5s, ghost touch-point + trail. Reduce-Motion → static frame; VoiceOver → `.announcement`, don't disturb `recordingStatusFocused`. ⚠️ **4s auto-dismiss must rise to ≥ the ~5s animation** so the demo isn't truncated.
- **D2 — CTA adaptive gate → RESOLVED: show both buckets to everyone in v1.** Ship the full rotating CTA set (`.anywhere` + `.universal`); tag the lines so a gate can switch on later, but build no gate / no origin counter this cycle. New users see the "speak anywhere" pitch.
- **D3 — Adaptive Enter in search fields → RESOLVED: magnifier glyph.** Use the `magnifyingglass` SF Symbol for `.search`/`.google`/`.yahoo` (overrides the research "word Search" rec; matches the original plan). So the Enter key now has TWO glyph cases — `arrow.turn.down.left` for `.default`/`@unknown`, `magnifyingglass` for search — and words for the rest. Verify on-device that the magnifier reads clearly on the brand-blue `returnAccent` face; glyph font 15/semibold to match.

---

## 9. Design-review resolutions (round-2, adversarially filtered)

Critical review by 5 code-grounded reviewers + 5 supervisors. **Validated outcome:** the architecture is sound — the fading stream already ships in both surfaces (WS-A is a re-tune, not invention), the build-72 ownership flag is load-bearing, the App-Group buffer correctly avoids a schema bump, `heroIntent` already branches the two hero paths, and WS-G resizable is pre-passed. Findings below are folded in; **the 4 user decisions are marked**.

### 🔴 Critical — fixed

**R1 · "Saves no transcript" must NOT touch the shipped warm-hold keyboard path.** Fixed in decision #3. Authoritative keyboard-origin state matrix:

| Origin state | Foregrounds hero? | Saves transcript? | Notes |
|---|---|---|---|
| Keyboard, **warm-hold ON** (in-place) | No | **YES + auto-pastes** | Shipped §13.2/§5.13 — UNCHANGED. The no-transcript rule must not apply here. |
| Keyboard, **cold start** (no warm hold) | Yes (hero, §2a) | YES (existing pipeline) | The swipe-back-coaching path. |
| **Keyboard-while-Jot-foreground** | No | **No** (inline) | New; routes to focused-field inline session (see R5). |
| **In-app Edit** dictation | No | **No** (inline) | Pastes into the Edit field. |
| **In-app Ask** dictation | No | **No** (inline) | Already shipped. |

**R2 · D1 back-pill (USER DECISION: keep both, verify pill on-device).** See §8 D1 — pill variant pending the user's on-device check; drop to swipe-only if it doesn't render.

### 🟠 Major — folded

- **R3 · Inline-Edit insert semantics.** The only shipped inline-fill is whole-field *replace* (`controller.question = newText`), which would obliterate existing Edit text on the first token. WS-B must implement **insert-at-cursor**: snapshot the `prefix`/`suffix` around the caret at dictation-start, render `prefix + streamingText + suffix` per partial, finalize on stop. Decide replace-selection vs insert-at-caret. **Prototype on-device** (live-bound TextEditor selection is finicky).
- **R4 · Extract `InlineDictationSession` with TWO explicit terminals** (highest-leverage structural call). Don't copy-paste Ask's four fragile invariants (await-pending-start before stop/abort; manual `markPipelineFinished()`; clear `ownsActiveRecording` on EVERY exit incl. error; `forceStop()` not `cancel()` on abort). One reusable controller owns `start → partial-fill → {terminal}`. The two terminals are **general, reusable modes** — not surface-specific:
  - **`finalize()`** → transcribe + insert into the field (explicit Stop; or a "save my words" exit like Edit background).
  - **`discard()`** → `forceStop`, drop audio, **no insert, no paste** (any *dismiss/abandon*).
  Every surface maps its exit paths to one of these. Houses R3 + R6 + the in-flight guard.
- **R5 · Keyboard-while-in-Jot (USER DECISION: unified app-level receiver, incl. wizard).** One app-level router observes the keyboard-dictate Darwin tap and routes to the focused-field `InlineDictationSession`. **The wizard is NOT a special "throwaway" route** — its W5 test is just a session whose dismiss calls `discard()`, exactly like **Ask-close already does** (`abortDictation → forceStop`). So the wizard's existing step-gated observer folds into this one router as another consumer of the shared `discard()` terminal; its only distinction is that `discard()` on dismiss is *mandatory* there (the zombie-recording contract). Single observer eliminates the double-fire risk.
- **R6 · Inline teardown = pick a terminal per exit path** (R4's two modes). **`discard()`** on any abandon: Ask sheet-close, wizard dismiss, Edit back-out without an explicit stop. **`finalize()`** on a "preserve my words" exit — recommended for **Edit app-background mid-dictation** (transcribe + insert, leave Edit dirty/unsaved) so spoken words aren't lost. Reuse the await-pending-start guard on both. Named on-device test case. Also: disable the inline mic while `isPipelineInFlight` (or show "finishing previous dictation…") so a tap during a prior dictation's tail isn't a silent no-op.
- **R7 · Inline-Edit does NOT count as usage (USER DECISION).** Inline dictation bypasses `DictationStats.record` (like Ask). Confirmed intentional — document so a future reader doesn't "fix" it. Stats/donation gating count pipeline dictations only.
- **R8 · WS-D one-line layout is width-adaptive, not absolute.** Pause+Stop+trash+Enter+side-margins do NOT fit one row on SE/mini (~320pt) — the Stop pill carries the live MM:SS timer and can't shrink to icon-only. Gate on `KeyboardMetrics.isLargeWidth` (≥428): one row on Plus/Pro-Max, **keep a separate Enter/bottomRow below 428**. If they ever share a row, the recording timer relocates to the StreamingStrip header (it has `startedAt`).
- **R9 · Pause/Resume — full design DONE in §10.** ✅ Designed. Correction to the review's premise: warm-hold does NOT use `engine.pause()` (that was a stale tmp-doc claim) — it keeps the engine running and drops buffers via the slice router, so **Pause reuses that exact mechanism** (gate routing, keep the slice open) rather than colliding with it. §10 covers the state machine, the `.paused` cross-process phase, elapsed-timer freeze, streaming-partial-across-pause, zombie/background safety, and instrumentation. **One open user decision:** the mic-hold-during-pause policy (§10.3 — A keep-warm / **B warm-then-release, recommended** / C release-immediately).
- **R10 · Warm-hold nudge instrumentation.** (a) Pin the buffer-append to **one site** — the clean `stop()` after `endActiveSlice()`, keyed on `currentSessionID` to dedupe — **NOT** the build-72 `markPipelineFinished()` latch (reachable from multiple paths = double-count trap). Explicitly decide whether interruption-recovered (`internalStop`) dictations count. (b) The **keyboard-strip nudge must be app-computed**: the keyboard process can't run the streak math, so the app writes a `nudgeState {shouldShow}` App-Group projection + Darwin post (mirror `pipelinePhaseChanged`); the keyboard renders off the boolean; the two actions write back (`warmHoldEnabled=true` / `nudgeSuppressed=true`).
- **R11 · features.md impact table** (CLAUDE.md REQUIRED). To update post-implementation:

  | WS | features.md section(s) | Edit |
  |---|---|---|
  | WS-A | §1.2 (italic→roman), §2.3, §5.3 | amend |
  | WS-C | §2.4 waveform | **remove** |
  | WS-C | new §2.x Pause | add + cross-link §2.5/§2.6 |
  | WS-D | §5.8 minimize/expand, §5.12 char-preview, §5.10 banner note | **remove** |
  | WS-D | §5.1 (spacebar/return-to-Jot), §5.4 (controls) | amend |
  | WS-E | §1.1 header, §1.9 gear, §1.11 multi-select | amend |
  | WS-G | §3.5 "Transform"→"Articulate" (+ §7.x ripple) | rename |
  | WS-B | §3.7 Edit inline, §13.2/§5.13 (confirm unchanged) | amend |

### 🟡 Minor — folded

- **R12 · §5.10 collapsed-banner bug is resolved by construction** once minimize/expand is removed (no collapsed render branch can exist). Close the open item. WS-D cleanup checklist: delete `CollapsedBarView`, `isCollapsed`/`onToggleCollapsed`, the persisted collapsed flag (grep the real key), the §5.10 note + §5.8; verify `collapsedHeight`/banner-lift logic has no other dependents.
- **R13 · "Strip italic from final text" is a ONE-row change.** Detail body (Original AND Rewrite) is **already regular**; `JotType.editorialItalic` is dead code; the only italic *final* text is `FeaturedLatestRow:33`. Scope the change to that one row; the plan's "detail is italic" premise was false. Keep `LiveStreamingRow` italic (the live/roman contrast is the intended signal).
- **R14 · WS-A = extract the scroll *core* only** (bottom-anchored measured-text + `scrollTo(bottom)` + top-fade-mask, parameterized by font/lineSpacing/maxBlockHeight/reduceMotion). Keep the keyboard's fixed-pane + ScrollIndicator + "↓ live" pill and the hero's grow-around-anchor as thin per-surface wrappers — don't collapse to one view.
- **R15 · Keyboard italic** → use the already-bundled **Fraunces italic** (not synthetic system italic at 13pt) for legibility + hero parity; no memory cost. When shrinking `paneHeight` for the new line cap, **re-derive `outerHeight`** and re-test the 310pt envelope (the documented clip at StreamingStrip.swift:48-50).
- **R16 · Warm-hold math refinements.** W is the user's *live* picker value (60–300), not a constant — **clamp the detection window to `min(W, 120)`** so a stale 5-min setting on a disabled feature can't manufacture slow-motion streaks. Derive the streak **from the timestamp buffer** (compare new start vs persisted prior stop), not a separately-persisted counter that can drift across app kills (self-expiring by construction). **Snapshot `currentRecordingStartedAt` at `stop()` entry** (it's nil'd on terminal publish); store `(startedAt, stoppedAt)` pairs.
- **R17 · "Keep mic ready" copy.** Accepting the nudge flips warm hold on for *next* time but can't retro-warm the just-finished session — **soften copy** so it doesn't overpromise "skip the wait" for the immediately-following dictation.
- **R18 · Chevron exit on the keyboard path.** The top-left back chevron lands on Jot's *home* (a hop from the host field); §2a coaches a swipe to the *host app*. Document the two exits land in different places; decide whether to repurpose/hide the chevron on the cold-start keyboard path. (Recording survives swipe-away via the existing safety-net — no correctness bug.)
- **R19 · Split the warm-hold nudge from the rotation engine.** Keep the engine for the two true rotators (home CTA + hero top-space); build the nudge as its own small component sharing only style tokens (it's one-shot, no rotation — avoid a `rotation:none` branch).
- **R20 · Platform scope.** This cycle is **iPhone only**; explicitly defer iPad (its keyboard is a different layout class — `isLargeWidth≥428` doesn't capture it) and watch (no keyboard/hero surface).

---

## 10. Pause / Resume design (R9)

**Grounding (verified in `RecordingService.swift`):** one AVAudioEngine + one installed tap runs for the whole session. A *slice* (`CaptureContext` + `StreamingBufferQueue`) is the unit of capture; `tapRouter.route(pcm)` ingests buffers into the active slice and returns `false` (drops them) when `isCapturingSlice == false`. **Warm-hold keeps the engine + tap running and just ends the slice + drops buffers with a cooldown timer** — it does NOT call `engine.pause()`. So Pause is a close cousin of warm-hold, not a new subsystem.

### 10.1 Core model — Pause = gate routing, keep the slice open

- **Pause:** stop routing buffers to the current slice **without ending it**. New router primitive `pauseSlice()` sets `isCapturingSlice = false` but **keeps** `capture` + `streamingQueue` (unlike `endSlice()`, which nils them). The `CaptureContext` keeps its accumulated samples; the engine keeps running; the tap drops buffers (zero per-buffer work, same as warm-hold idle).
- **Resume:** `resumeSlice()` sets `isCapturingSlice = true` against the **same** `CaptureContext`. Buffers ingest again and **samples concatenate naturally** — the pause gap is simply absent from the audio. No session-level accumulator, no sample-stitching code.
- **Stop (from paused or active):** unchanged — `endActiveSlice()` → `capture.drain()` returns the full concatenated samples → existing pipeline transcribes. Pause is invisible to the pipeline; it only ever sees one slice's drained samples.

This is the minimal-surface design: two new router methods, no change to the drain/transcribe path.

### 10.2 State & cross-process phase

- Add a `.paused` pipeline phase to `publishPipelinePhase`. The keyboard already derives recording state from the phase (single source of truth), so `.paused` lets both the hero and keyboard render a paused UI (Resume control) cross-process.
- `isRecording` stays **true** while paused (we're still in a live session, just not capturing). Pause is a sub-state of an active recording, terminated only by Resume or Stop/Cancel.
- Pause/Resume can be initiated from the keyboard: mirror the existing `stopRequested` Darwin pattern with `pauseRequested` / `resumeRequested` → app's `RecordingService` (the single owner). Keyboard never runs the engine.

### 10.3 ⚠️ The one genuine decision — mic-hold policy during pause

Because the engine keeps running, **iOS shows the orange mic-active indicator while paused** (we're still holding the mic) — exactly like warm-hold today. Pause can be arbitrarily long, so three options:

- **A — Keep warm indefinitely:** instant resume, but the mic + orange dot are held for the entire pause (could be minutes). Honest but heavy; worst privacy optics.
- **B — Warm-then-release (RECOMMENDED):** keep the engine warm for a bounded window (reuse the warm-hold cooldown machinery), then tear the tap/engine down (mic released, orange off). Resume within the window = instant; resume after = a cold re-acquire that re-opens the slice and **appends to the preserved `CaptureContext`**. Bounds the mic-hold, matches warm-hold's existing, disclosed behavior.
- **C — Release immediately on pause:** orange off the instant they pause (most honest), but every resume is a cold re-acquire (~slower, and can hit "mic unavailable" if another app grabbed it meanwhile).

**DECISION (user): Option A — keep the mic warm for the entire pause** (instant resume always). Two mandatory safeguards so the held mic stays honest with Jot's privacy-first brand: (1) **the paused UI states it plainly** — e.g. "Paused · mic ready, not capturing" — so the orange indicator never reads as covert recording (and it's true: paused buffers are dropped, never captured or stored); (2) **an upper safety ceiling** — fold into / reuse the existing recording cap so a forgotten pause auto-finalizes rather than holding the mic indefinitely (also closes the zombie hazard in §10.7). No warm-hold cooldown is borrowed (that was Option B); the engine simply stays running until Resume, Stop, or the safety ceiling.

### 10.4 Elapsed timer

Freeze during pause. The live timer currently renders off `currentRecordingStartedAt` (wall-clock). Switch the paused-aware duration to **accumulated active time** (sum of active spans, excluding pause gaps) — which also equals `samples.count / sampleRate`, the true recorded length. So the timer naturally freezes when not capturing and resumes on resume. Publish the frozen value in the projection so the keyboard's clock freezes too.

### 10.5 Streaming partial across pause

The live partial shown so far must **persist** across pause (don't clear it) and resume must **append**, not restart. On pause, tear down the current slice's streaming session (promote its preview to a final snapshot via the existing `engine.finish()`); keep that text as a **committed prefix** in the `StreamingPartial` presenter. On resume, a fresh streaming session feeds new partials that render as `prefix + newPartial`. (This is the same "committed prefix + live tail" shape the presenter already needs for long dictations.)

### 10.6 Warm-hold interaction — no real collision

Pause and warm-hold are **mutually exclusive states**: pause is *mid-dictation* (slice open, not finalized); warm-hold is *post-stop* idle (slice ended, dictation finalized, cooldown running). A paused session cannot enter warm-hold (warm-hold is only entered inside `stop()`). On a final Stop from paused, the normal warm-hold-on-stop path runs unchanged. (With Option A chosen, no cooldown timer is involved during pause at all — the engine simply stays running until Resume/Stop/the safety ceiling.)

### 10.7 Background / crash / zombie safety

- **Background while paused:** engine may still be running (Option A/B-within-window) or released (B-after-window/C). Either is safe — no capture is happening. Per the existing model, don't `forceStop` on background.
- **Zombie risk:** a paused session left alive indefinitely is the new hazard. Option B's auto-release bounds the mic-hold; additionally, on app **termination** while paused, finalize-or-discard the session (never leave a paused recording to resurrect as a zombie). The wizard zombie contract is untouched — you can't pause inside the W5 test.
- **Interruption (call/route change) while paused:** treat like active — route to `internalStop` (finalize what's accumulated) rather than silently staying paused through a call that seized the mic.
- **Instrumentation:** add `RECORDING PAUSE FROM:` / `RECORDING RESUME FROM:` logs alongside the existing `RECORDING START FROM:` (CLAUDE.md).

### 10.8 Surfaces & controls

- **Hero:** Pause/Resume control alongside Stop + Cancel (WS-C).
- **Keyboard:** Pause + Stop + trash-Cancel control set (WS-D), within the width-adaptive layout (R8).
- Paused state reads clearly on both (e.g. the recording dot goes static/hollow + "Paused", Resume replaces Pause).

### 10.9 features.md impact

New §2.x "Pause/Resume" (hero + keyboard), cross-linked to §2.5 Stop / §2.6 Cancel / §13.2 Warm Hold (note the shared cooldown machinery if Option B). Add to the R11 table.
