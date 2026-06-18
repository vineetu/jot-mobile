# Vocab correction card — swipe-left/right navigation

> **Status:** PLAN ONLY (not built). Follows the `known-bugs-and-plans.md` protocol — when this is picked up, add a dual entry there (a detailed entry under "Planned Work & Plans Index → Vocabulary & correction" PLUS a one-line index entry), per `Jot/CLAUDE.md`.
>
> **Surface:** `features.md` §8 (Vocabulary Boost) — the post-dictation keyboard correction quick-review. **Size:** S–M.
>
> Template: Problem → Goal → Non-Goals → Current behavior (file:line) → Design → SwiftUI mechanism → State / cross-process model → Edge cases → Accessibility → Implementation outline → Open questions → Cross-links.

---

## Problem

After a dictation, the keyboard surfaces a small set of **vocabulary "asks"** (≤3 gated words worth a quick "did Jot guess right?" confirmation) as a card in the keyboard's strip slot. The owner observes that because it's a **card layout**, the natural gesture is to **swipe left/right to move between the queued questions** (next / previous) — but today there is no swipe. Navigation is forward-only: you can answer a word, or tap **Skip** (forward only). You cannot go back, and you cannot peek ahead without consuming the current ask.

The ask is: make the multi-ask card **horizontally pageable** — swipe to go next/previous through the queued asks — while keeping the existing answer + Skip actions intact.

## Goal

- Swipe **left** → next ask; swipe **right** → previous ask, through the ≤3 queued asks.
- Coexist cleanly with the existing per-ask **answer** (the two word-chips) and **Skip** actions.
- Keep the "N of M" position indicator coherent with whatever ask is on screen.
- Honour the keyboard's hard constraints (~60 MB memory ceiling; the "row-swipe must be a nested horizontal ScrollView, never a DragGesture" lesson).
- VoiceOver + Reduce Motion correct.

## Non-Goals

- **No new cross-process plumbing.** Navigation is a keyboard-local concern (see [State model](#state--cross-process-model)). The App Group `Asks` blob and the verdict queue are unchanged.
- **No change to which asks are surfaced** (still ≤3, ranked) or the verdict semantics — this is a navigation-UX change only.
- **No edit of host text** — the strip stays **teach-only** (`CorrectionReviewStrip.swift:13-15`).
- **No swipe-to-skip-all / swipe-to-dismiss-card** gesture (swiping past the last ask does NOT auto-finish — see [edge cases](#edge-cases)).
- No SwiftData schema change (file-based correction store only — confirmed in the adaptive-vocab plan).

---

## Current behavior (file:line)

All paths below are under the repo root.

### How many asks, and how they're chosen
- **≤3 asks.** `Jot/App/Vocabulary/CorrectionAsksPublisher.swift:11` (`maxAsks = 3`); ranked closest-to-automatic first and truncated at `:49-50`. Each ask carries `recordKey, original, term, outcome ("applied"|"kept"), contextBefore, contextAfter` (`Jot/Shared/CorrectionBridge.swift:20-27`). The blob also carries `totalUnresolved` (ALL unresolved proposals on the transcript, not just the ≤3 surfaced) — `CorrectionBridge.swift:33-37`, set at `CorrectionAsksPublisher.swift:69`.

### How the card is presented (one at a time, already indexed)
- The card is `CorrectionReviewStrip` (`Jot/Keyboard/CorrectionReviewStrip.swift`). It is **already a one-ask-at-a-time pager driven by a local `@State index`** — it is NOT a list and not a fanned card stack:
  - Stage machine: `nudge → review → done → idle` (`:40-47`).
  - **Nudge stage** (`:114-174`): "Jot guessed on N words." + **Review** / **×** (dismiss) buttons; 10s passive auto-dismiss (`:166-173`).
  - **Review stage** (`:178-247`): renders **`asks[index]`** (`:180-181`) — the spoken-context line (`:252-269`, the gated word dash-underlined), two word-chips (original then term, `:205-218`), a **Skip** text button (`:222-233`), and a **"`index+1` of `asks.count`"** counter (`:235-237`). Re-keyed on `index` (`.id(index)`, `:243`) so the chips/context animate per-ask.
  - **Done stage** (`:321-349`): "All reviewed." + optional "N more guesses are on the transcript in Jot." (uses `totalUnresolved − verdictsGiven`, `:58`); auto-finishes after 2.2s (`:343-348`).
  - **Idle** (`:105-109`): terminal blank while the controller drops the slot.

### What "Skip" does today
- **Skip = advance ONE, forward only, WITHOUT recording a verdict.** The Skip button calls `advance()` (`:224`). `advance()` (`:353-359`) clears `verdictFeedback`, does `index += 1`, and if `index >= asks.count` flips `stage = .done`. There is **no decrement path** — you cannot go back. Skip does NOT enqueue anything; the ask simply remains unresolved (it'll be reviewable on the transcript in Jot). So "Skip" = skip THIS one, not skip-all.
- The **×** on the nudge stage (`:148-161`) dismisses the whole card (`onFinished()`), which clears the published asks (`JotKeyboardViewController.swift:551-557`). That is the only "skip all" affordance, and only from the nudge stage.

### Answering an ask (the verdict path)
- Tapping a **word-chip** (`wordChip`, `:271-317`): plays feedback, calls `onVerdict(ask.recordKey, verdict)` where verdict is `"term"` or `"original"` (`:275`), increments `verdictsGiven` (`:276`), shows the resolved-consequence line for 950 ms (`:277-282`), then calls `advance()` (`:282`). So answering = record verdict + auto-advance forward.

### Cross-process plumbing (App Group + Darwin)
- **App → keyboard:** main app publishes the `Asks` blob to the App-Group suite under `jot.correction.asks` (`CorrectionBridge.swift:63, 70-76`), then posts `CrossProcessNotification.correctionAsksReady` (`CorrectionAsksPublisher.swift:73`). The keyboard observes that notification (`JotKeyboardViewController.swift:1431-1438`), reads the latest blob (`CorrectionBridge.readLatestAsks()`, `:1447`; or session-matched `readAsks(sessionID:)`, `:640`), stores it in `correctionAsks` (`:646, :1451`), sets `showCorrectionNudge = true`, and re-renders. The strip is mounted from `KeyboardView.topStrip` (`KeyboardView.swift:303-311`) — gated on `showCorrectionNudge && !recordingState.isRecording`.
- **Keyboard → app:** each verdict is enqueued back via `CorrectionBridge.enqueueVerdict` (`JotKeyboardViewController.swift:545-550`, `CorrectionBridge.swift:108-114`). The app drains the queue when it next becomes active (`CorrectionInbox.drain`, `Jot/App/Vocabulary/CorrectionInbox.swift:10-28`) and replays each through the same `CorrectionReviewModel.pick` path the in-app marks use (idempotent: already-adjudicated → no-op, `:21-23`).
- **The keyboard owns the review flow.** The blob is a static `Asks` snapshot; `index`, `stage`, `verdictsGiven`, `verdictFeedback` are all keyboard-local `@State`. The app does **not** know or drive which ask is on screen.

### Layout invariant (do not break)
- Every strip variant is pinned to **129 pt** or the keys reflow (`CorrectionReviewStrip.swift:38, 65`; doc note `:35-38`). The card is mounted in a slot shared with recents / streaming / warm-hold (`KeyboardView.swift:298-331`).

---

## Design

### What swiping does vs. answering vs. Skip

Three distinct verbs, all preserved:

| Action | Records a verdict? | Direction | Net effect on the ask |
|---|---|---|---|
| **Answer** (tap a word-chip) | Yes (`term`/`original`) | auto-advance forward | resolved; enqueued to app |
| **Skip** (tap Skip) | No | forward only | left unresolved (reviewable in Jot) |
| **Swipe** (new) | **No** | next **or** previous | **peek only** — never consumes/resolves |

**Decision: swiping is a non-destructive PEEK, not a skip.** Swiping changes which ask is visible; it does **not** record a verdict and does **not** mark the ask resolved/skipped. This is the only model that makes "swipe right (previous)" coherent — going back to an already-answered ask should show its resolved state, not re-ask it. It also keeps the gesture purely navigational, matching the owner's mental model ("move between the questions").

This means **Skip and Swipe become semantically distinct**: Skip = "I'm not answering this, move on (and don't bug me about it here)"; Swipe = "let me look at the next/previous one." We keep **both**. (Alternative considered: collapse Skip into "swipe to next." Rejected — Skip is a deliberate "leave unresolved" signal a blind swipe shouldn't imply, and Skip must stay reachable for VoiceOver users who can't paginate by swipe; see [accessibility](#accessibility).)

### Per-ask state: answered vs. unanswered vs. skipped

To make back-navigation coherent, each ask page renders one of two states based on **keyboard-local per-ask tracking**:

- **Unanswered** (not yet acted on): show the two word-chips + Skip (current `else` branch, `:204-239`).
- **Answered** (verdict given): show the resolved-consequence line (current `verdictFeedback` branch, `:192-203`) **persistently** for that page — so swiping back to it shows "Jamy confirmed." rather than re-presenting the chips. (Today `verdictFeedback` is a single transient `@State` cleared on `advance()`; this must become **per-ask** — see [state model](#state--cross-process-model).)
- **Skipped:** treat as still unanswered when revisited (chips shown again) — a skip is "not now," revisiting it via swipe is a fine chance to answer. (Optional: a faint "skipped" affordance; default = identical to unanswered to keep the cramped 129 pt card simple.)

### Behavior at the ends (first / last)

- **First ask, swipe right (previous):** no-op (rubber-band / bounce). Does NOT leave the card. The position indicator stays "1 of N."
- **Last ask, swipe left (next):** **does NOT auto-finish.** It rubber-bands at the last page. Finishing the card stays an **explicit** act:
  - tapping the last unanswered ask's word-chip → answer → `advance()` past the end → `done` stage (unchanged), OR
  - tapping Skip on the last ask → `advance()` past the end → `done` stage (unchanged), OR
  - the existing auto-dismiss timers / × on nudge.
  - **Rationale:** a swipe is exploratory; auto-finishing on an over-swipe would feel like the card "ran away." The end-of-deck transition to `done` should be a deliberate answer/skip, exactly as today. (This preserves the current `advance()` → `done` semantics; swipe just adds lateral movement *within* the deck.)

### The "N of M" indicator & paging dots

- Keep the existing "`index+1` of `asks.count`" counter (`:235`), now reflecting the swiped page.
- **Add a small paging-dot row** (≤3 dots) so multi-ask decks read as swipeable at a glance (discoverability — otherwise users won't know to swipe). Dots only render when `asks.count > 1`. This is the standard page-control affordance and signals "there's more sideways."

### Stage interaction

The nudge → review → done → idle stages are unchanged. Swipe navigation lives **only inside the `review` stage**. The nudge stage is a single non-paged screen; done/idle are terminal.

---

## SwiftUI mechanism

### The constraint (the load-bearing lesson)

From project memory (`known-bugs-and-plans.md` / Recents work):
> "Recents row-swipe must be a nested horizontal **ScrollView**, never a **DragGesture** (broke scroll 3×); never size that row content with **`containerRelativeFrame`** (collapses + sticks blank)."

Plus: the keyboard target has a **~60 MB memory ceiling** (`Jot/CLAUDE.md`), and **`TabView`/`PageTabViewStyle` is used nowhere in the codebase** (confirmed: zero hits across `Jot/Keyboard/` and `Jot/App/`).

### Recommended: paged horizontal `ScrollView` (iOS 17 `.scrollTargetBehavior(.paging)`)

Use a **horizontal `ScrollView`** with `.scrollTargetBehavior(.paging)` + `.scrollPosition(id:)`, NOT a `DragGesture`, and **NOT** `containerRelativeFrame` for sizing. This directly honours the cited lesson (ScrollView, not DragGesture) and is far lighter than `TabView(.page)` (which lazily hosts page view controllers and is untested in this target's memory budget).

Why not the alternatives:
- **`TabView` + `.tabViewStyle(.page)`** — gives free paging + dots, BUT: never used in this codebase (unknown memory behavior under the 60 MB ceiling), wraps a UIKit page controller, and its page indicator styling is hard to match to the keyboard's glass tokens. **Rejected on memory-budget risk + zero precedent.**
- **`offset` + `DragGesture`** — **explicitly the refuted approach** ("never a DragGesture") and would re-fight the gesture arbitration that already exists: every interactive control in the strip wraps a `DragGesture(minimumDistance: 0)` for press-scale (`CorrectionReviewStrip.swift:417-421` `PressButton`). A page-level `DragGesture` would collide with those per-button drags (the well-known SwiftUI nested-gesture trap that "broke scroll 3×" in Recents). **Rejected.**
- **Paged `ScrollView`** — the OS owns the gesture, so it composes correctly with the tap-only word-chips and the per-button press `DragGesture` (a `ScrollView` and a child `DragGesture(minimumDistance: 0)` coexist; SwiftUI routes the horizontal pan to the scroll view and the touch-down to the button). **Chosen.**

### Sizing rule (avoid the `containerRelativeFrame` trap)

Do NOT size each page with `containerRelativeFrame(.horizontal)` (the lesson's "collapses + sticks blank" failure). Instead measure the strip's inner content width once with a `GeometryReader` at the strip root and pass an explicit `pageWidth` down; each page is `.frame(width: pageWidth)`. The outer 129 pt height is unchanged. Pseudocode in the [implementation outline](#implementation-outline).

### Reduce Motion

`.scrollTargetBehavior(.paging)` still animates the settle. Under Reduce Motion, the existing per-ask `.id(index)` transition is already gated (`:79, :85-91, :312-316`); keep the scroll but suppress any decorative cross-fade. The paging snap itself is a system scroll and acceptable under Reduce Motion (it's not a parallax/zoom). If the owner wants it fully still, fall back to prev/next chevron buttons under Reduce Motion (see [accessibility](#accessibility)).

---

## State / cross-process model

**Navigation is 100% keyboard-local. No new App Group keys, no new Darwin notifications, no main-app changes.** The app already ships a static `Asks` snapshot; paging through it is a pure view concern. This is the right boundary: the main app is backgrounded during keyboard dictation, so it can't (and shouldn't) drive a live cursor.

Changes are confined to `CorrectionReviewStrip`'s `@State`:

1. **`index`** (exists, `:48`) becomes the **scroll position** binding (`@State private var pageID: Int?` driving `.scrollPosition(id:)`), with `index` derived from it. Keep an `index`-equivalent for the counter + `advance()`.
2. **`verdictFeedback`** (today a single transient, `:51`) becomes **per-ask**: `@State private var verdicts: [String: (strong, rest)]` keyed by `ask.recordKey` (or an index-keyed array). A page renders the resolved line if its ask has an entry, else the chips. This is what makes back-navigation show the answered state instead of re-asking.
3. **`verdictsGiven`** (exists, `:54`) — keep; it already feeds the "N more" done-stage line. Equivalent to `verdicts.count`; can be replaced by `verdicts.count` to avoid double-bookkeeping.
4. **`advance()`** (`:353-359`) — keep its "forward + flip to done at the end" semantics for the **answer/Skip** verbs only. Swiping mutates `pageID` directly and never calls `advance()`.

**Verdict enqueue is unchanged** (`onVerdict` → `CorrectionBridge.enqueueVerdict`), and is **idempotent** end-to-end: if a user answers an ask, swipes back, and the chip is somehow re-tappable, the app-side `CorrectionInbox` guard (`CorrectionInbox.swift:21-23`) makes the re-apply a no-op. But the per-ask `verdicts` map should also lock an answered page to its resolved view so re-answering isn't even offered.

---

## Edge cases

- **Single ask (N=1):** no paging dots, no horizontal scroll engagement (one page = no swipe target). Counter "1 of 1" may be hidden. Behaves exactly like today.
- **Zero asks:** the card never mounts (`showCorrectionNudge` only set when `!a.asks.isEmpty`, `JotKeyboardViewController.swift:641, :1448`; bridge drops empty blobs, `CorrectionBridge.swift:71-74`). No change.
- **Ask answered mid-navigation, then swiped back:** shows the persistent resolved line (per-ask `verdicts` map). Chips not re-offered.
- **All asks answered without ever swiping to `done`:** when the *last unanswered* page is answered/skipped, `advance()` runs off the end → `done` (unchanged). If the user answered out of order via swiping and one remains, the card stays in `review` on that page until it's answered/skipped or the card is dismissed. (Define "done trigger" as: `verdicts.count + skips == asks.count` → `done`. Today it's purely positional; with swipe it must be **completion-based**, not position-based, or a user who answers the last page first then swipes back would never reach done. **This is the one genuinely new piece of logic.**)
- **Card dismissed (× on nudge, or auto-dismiss timers):** `onFinished()` → controller clears `correctionAsks`, `showCorrectionNudge = false`, clears the App-Group blob (`JotKeyboardViewController.swift:551-557`). Any verdicts already enqueued survive (they're in the separate verdict queue). Unanswered/skipped asks remain reviewable on the transcript in Jot. Unchanged.
- **Recording restarts while card is up:** `topStrip` gates the strip on `!recordingState.isRecording` (`KeyboardView.swift:303`), so a new recording swaps the slot to the streaming strip and the card disappears. The static blob is untouched; if the new dictation publishes fresh asks they overwrite the slot (`publishAsks` overwrites, `CorrectionBridge.swift:70`). No partial-navigation state needs to survive (acceptable: the deck is ephemeral). Confirm the per-ask `verdicts` `@State` resets on remount (it will — fresh `CorrectionReviewStrip` instance).
- **New asks arrive while reviewing (back-to-back dictations):** the controller currently yields if a nudge is already showing (`showCorrectionNudgeFromReady` guards `!showCorrectionNudge`, `:1446`). So a second dictation's asks won't interrupt an open card. Unchanged — paging doesn't affect this.
- **Over-swipe past last / before first:** rubber-band, no-op (see [ends](#behavior-at-the-ends-first--last)).

---

## Accessibility

- **VoiceOver users cannot reliably page by swipe** (the VO swipe is reassigned to element traversal). Therefore:
  - Keep **Skip** reachable as a button (it already has `accessibilityLabel("Skip this word")`, `:233`) — it remains the VO "move on" path.
  - Add an **explicit Previous control** (mirroring Skip's role for the backward direction) OR expose the scroll as an `accessibilityAdjustableAction` (increment = next, decrement = previous) on the card so VO users get prev/next via the adjustable rotor. The adjustable action is the cleaner fit and matches the page-control idiom.
  - Mark the card `accessibilityElement(children: .contain)` (already present, `:93`) and add an `.accessibilityValue("ask \(index+1) of \(asks.count)")` so position is announced.
- **Reduce Motion:** the paging settle is a system scroll (acceptable); suppress decorative per-ask cross-fades (already gated). If the owner wants zero lateral motion, gate to **chevron prev/next buttons** under Reduce Motion instead of the scroll — design decision to confirm. The existing appear spring is already RM-gated (`:79, :85-91`).
- **Paging dots** must not be the only "more asks" signal for VO — the `accessibilityValue` covers that.

---

## features.md impact

- **§8.x update needed.** §8 currently describes the vocabulary list/settings; the keyboard correction quick-review is the post-dictation surface this card belongs to. Whichever §8 sub-section documents the keyboard correction card (or a new one if absent) should gain a sentence: *"When Jot surfaces more than one guess to review, swipe left or right to move between them; tapping a word confirms it, Skip leaves it for later in the app."* Keep it user-facing per the §8 style rules (no symbol/framework names). Walk one hop of cross-links from §8 to the relevant keyboard strip section and add bidirectional links. **ARCHITECTURE.md likely NOT touched** — no new subsystem, no moved boundary, no new cross-process contract (navigation is keyboard-local). Confirm during implementation per the "pair the edits" rule.

---

## Implementation outline (pseudo-code only)

> All inside `Jot/Keyboard/CorrectionReviewStrip.swift`. No controller, bridge, publisher, or app changes.

1. **State changes**
   ```
   @State var pageID: Int? = 0                 // scrollPosition binding
   @State var verdicts: [Int: (strong, rest)]  // per-ask resolved line, by page index
   @State var skipped: Set<Int>                 // pages explicitly skipped
   var index: Int { pageID ?? 0 }              // derive counter / current ask
   var isComplete: Bool { verdicts.count + skipped.count >= asks.count }
   ```

2. **Review stage → paged ScrollView** (replace the single-`asks[index]` body, `:178-247`)
   ```
   GeometryReader { geo in
     let pageW = geo.size.width            // explicit width — NOT containerRelativeFrame
     ScrollView(.horizontal, showsIndicators: false) {
       LazyHStack(spacing: 0) {            // Lazy keeps ≤3 light; 60MB-safe
         ForEach(asks.indices, id: \.self) { i in
           askPage(asks[i], i)            // resolved-line if verdicts[i]!=nil else chips+Skip
             .frame(width: pageW)
             .id(i)
         }
       }
       .scrollTargetLayout()
     }
     .scrollTargetBehavior(.paging)
     .scrollPosition(id: $pageID)
     .scrollDisabled(asks.count <= 1)     // single ask: no swipe target
   }
   // pinned 129pt height stays on the outer card (:65) — unchanged
   ```
   - `askPage(ask, i)`: if `verdicts[i]` → resolved-consequence line (current `:192-203`); else chips (`:205-218`) + Skip + counter + dots.

3. **Answer (word-chip)** — keep `onVerdict` + feedback, but write **per-ask**:
   ```
   onVerdict(ask.recordKey, verdict)
   verdicts[i] = resolvedParts(ask, verdict)
   after 950ms: if isComplete -> stage = .done   // completion-based, not positional
               else: scroll to next UNANSWERED page (set pageID)
   ```

4. **Skip** — record skip, advance to next unanswered (not just index+1):
   ```
   skipped.insert(i)
   if isComplete -> stage = .done else scroll to next unanswered page
   ```

5. **Paging dots** (render only when `asks.count > 1`): a small `HStack` of `asks.count` circles, the `index` one filled with the accent token; place it where the "N of M" counter sits (or beside it).

6. **Accessibility**: add `.accessibilityValue("ask \(index+1) of \(asks.count)")` and an `accessibilityAdjustableAction { dir in pageID = clamp(index ± 1) }` on the card; keep Skip's existing label.

7. **Reduce Motion** (decision pending): either keep the system paging scroll, or swap to prev/next chevron buttons that set `pageID`.

8. **Ends**: paging `ScrollView` rubber-bands natively — no extra code for over-swipe. Do NOT trigger `done` on over-swipe (only on completion).

---

## Open questions (for the owner)

1. **Swipe = peek (recommended) vs. swipe = skip-forward.** Plan assumes peek (non-destructive). Confirm.
2. **Reduce Motion:** keep the system paging scroll, or fall back to chevron prev/next buttons?
3. **Skipped-page affordance:** show a faint "skipped" marker on revisit, or render identical to unanswered (recommended — simpler)?
4. **Paging dots vs. keep only "N of M":** dots add discoverability but cost ~10 pt of the cramped 129 pt card. Recommend dots when `N>1`.
5. **Should answering the last-but-one and leaving one unanswered keep the card open** (completion-based `done`, recommended) **or** finish on reaching the end positionally (today's behavior)? Recommend completion-based so swipe can't strand an unanswered ask off-screen.

---

## Cross-links

- `features.md` §8 (Vocabulary Boost) — user-facing surface.
- `docs/plans/adaptive-vocabulary-correction.md` — the parent feature; this card is its keyboard review surface.
- `docs/plans/correction-review-surface-parity.md` — the app/keyboard copy-parity contract referenced in `CorrectionReviewStrip.swift:361-366`; any copy added here must stay in lockstep.
- Recents row-swipe lesson (nested horizontal `ScrollView`, never `DragGesture`, never `containerRelativeFrame`) — `known-bugs-and-plans.md` / `Jot/Keyboard/RecentsStrip.swift`.
- `Jot/CLAUDE.md` — keyboard 60 MB ceiling; known-bugs-and-plans protocol (add the dual entry when picked up).
