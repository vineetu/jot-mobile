# Jot architecture: decouple the root view + a pattern every feature follows

> **Status: DESIGN (pre-implementation).** Supersedes the seed at
> `docs/plans/refactor-decouple-root-view.md`. Rewritten 2026-06-09 after a long
> requirements pass with the owner and one adversarial review. **Reconciled to the
> codebase 2026-06-24 by the recon team** — the data layer, Router-injection
> guardrails, paste-bridge framing, and line cites were updated to today's reality
> (the original decisions stand; only the scope under them grew). **Design-reviewed
> 2026-06-24; verdict READY after M1+M2** (Watch `append` params; `setCleanedText`
> clears `rewriteUserEdit`+`rewriteUpvoted`), both folded in below. **Scope decision =
> all-four-writers-in-one (option b).** Read this top to bottom before touching code.

## The real goal (in the owner's words)

**One documented architecture pattern that every future feature follows** — so adding a
feature is "drop it into the known shape," and you touch a few *predictable* places
instead of spelunking through a god-view. It must be written down clearly enough that a
**fresh, stateless agent** (or the owner) reads it and conforms automatically, without
re-explaining the architecture each session. Success = *"to add a screen I change N known
files, nothing else,"* and `ARCHITECTURE.md` stays short and true.

Two concrete pieces of work both **prove** the pattern and **seed** it:

1. **Kill the monolithic root view** (`ContentView`, 1,266 lines) → a proper layered
   structure. This becomes the *reference example* future features copy.
2. **Clean up how a dictation's context is decided** — *when the Return-to-app page
   shows* and *whether a dictation is saved* — by deciding each at its **natural time**
   instead of guessing from scattered ambient state.

Constraints: nothing existing breaks; shipped in small independently-verifiable steps
(owner is the on-device gate); **the "keyboard disappears when I tap Jot Down" bug is
deferred** until the architecture is clean (then it's findable).

## Non-goals

- Not a rewrite. Leaf screens (`SettingsView`, `AskView`, `TranscriptDetailView`,
  `RecordingHeroView`, wizard) are **not** touched except to read the Router/services
  instead of passed-in Bools.
- Not a visual/UX change. Every flow looks and behaves identically.
- **No** ViewModel-per-screen, **no** single Redux mega-store, **no** TCA, **no** DI
  container. One Router, one promoted store, existing services kept.
- We do **not** move the save/no-save decision to start time (see "Two decisions, two
  times" — that would lose data).

---

## Architecture: four layers (grounded in expert guidance)

The 2025 SwiftUI consensus — Naumov's *Clean Architecture for SwiftUI* + the MV+Router
pattern — **scaled down** to Jot so it doesn't over-engineer. Sources at the bottom.

| Layer | Responsibility | In Jot | Status |
|---|---|---|---|
| **Views** | Render; hold ONLY local view-state (selection mode, the `copied!` flash). No persistence, no cross-process, no business logic. | `HomeScreen`, `SettingsView`, `AskView`, … | Mostly fine; transcript CRUD leaking in |
| **Services** (business logic) | Per-domain `@Observable` units owning a domain's logic. | `RecordingService`, `DictationPipeline`, `TranscriptionService`, `AskController`, … | ✅ already good |
| **Repository** (data access) | The ONLY code that touches the transcript store + the cross-process mirror/notification, behind a clear API. | `TranscriptStore` (exists, under-used) | ❌ CRUD lives in `ContentView` |
| **Router** (navigation SoT) | Single source of truth for what screen/sheet is shown + the dictation **entry context**. Navigation state only — not a mega app-state. | new `Router` `@Observable` | ❌ it's 6 correlated Bools |

**Two deliberate divergences from the textbook, both to avoid over-engineering:**

1. **No ViewModel per screen.** Under `@Observable` it's dead weight (Apple's direction +
   Naumov). Screens read services / `@Query` directly. Add a screen model *only* where
   there's genuine derived state.
2. **No single Redux `AppState`.** That recreates a god object. iOS-17+ `@Observable`
   makes fine-grained observation cheap → keep Jot's focused per-domain services, add a
   **narrow Router for navigation only.** Many small observables, not one big one.

---

## Two decisions, two times (the heart of the dictation cleanup)

The "complex logic for in-app dictation" the owner dislikes is really **two different
decisions that today are tangled together and both guessed from ambient process state.**
They have *different natural times*, and separating them by time is the fix.

### Decision A — "Does the Return-to-app page (Hero) show?" → an ENTRY decision (mostly already clean)

The behavior we want (verified faithful to current code):

| Trigger | Mic already on? | Where the user is | Show Hero? |
|---|---|---|---|
| **Record (FAB)** in the app | — | in Jot | **Hero** (direct start) |
| **Keyboard**, from another app | No | another app | **Hero + Return-to-app cue** (we bounced you in for the mic) |
| **Keyboard**, from another app | Yes (warm) | another app | **None** — keyboard keeps capturing, app never opens |
| **Keyboard**, inside Jot | either | in Jot (Ask, Settings, anywhere) | **None, ever** — capture inline |

> One sentence: **the Hero opens iff you tapped Record, or we had to pull you in from
> another app to get the mic.**

**Reality check (this part is smaller than it looks — do NOT over-build it).** Hero routing
is *already* source-based: it presents from exactly three triggers (FAB tap, cold
`jot://dictate` URL, return-pill tap). The old `isRecording` auto-push was already deleted
(`ContentView.swift:526-532`; the remaining `.onChange(of: isRecording)` is teardown-only).
So there is **no scattered mess left to "unify" with a new abstraction.**

Crucially, the keyboard's "is the mic warm / will the app even open" question is **not a
stampable fact** — it's a live cross-process ping/pong handshake the keyboard resolves
*itself* in ~120 ms (`JotKeyboardViewController.swift` warm check `1769-1773`, foreground
ping `1693-1709`). Rows 1, 3, 4 are decided **without anything crossing to the app** (FAB is
in-process; warm-no-open and in-Jot never reach the app's Router at all). The **only** bit
that crosses the process boundary is **row 2's** "we bounced you in from another app" — and
that bit **already exists** as `pendingExternalKeyboardHero`, set in `JotApp.onOpenURL:462`.

**So there is no `DictationEntryContext` to invent.** The cleanup is just: in Step 1, fold
the existing `pendingExternalKeyboardHero` + `showRecordingHero` bits into the Router enum
(`Route.hero(.openedFromExternalKeyboard)` vs `.startRecording`), so the Router *reads* the
one bit instead of it living as a loose `@State`. Keep the keyboard's warm/foreground
handshake exactly where it is — it correctly belongs on the keyboard side. The dictation
"payoff" of this refactor is therefore **only** paste-delivery reliability (below), not a
new entry model.

**Rename:** the so-called "cold start page" has nothing to do with cold start — it is the
**Return-to-app page** (shown only in row 2). This is **mostly done already**: the load-bearing
identifier was renamed `coldStartFromExternalKeyboard` → `openedFromExternalKeyboard`, and
`SwipeBackCardCue` is the visual name. What remains is **conceptual/comment cleanup only**
(no persisted keys, analytics, or diagnostics categories use "cold start" — verified). Low
priority; fold it into whichever step touches the hero code.

### Decision B — "Is this dictation saved, or transient?" → a STOP decision (unchanged)

This **must** stay a stop-time decision and we keep it. Verified rationale
(`unify-keyboard-dictation.md:72-74`): a dictation can **start in one place and end in
another**, and the text follows the cursor at stop:

| You can do | Lands in | Save? |
|---|---|---|
| Start in Slack → end in Jot's Feedback field → stop | Jot field | **No** |
| Start in Jot's vocab editor → end in Messages → stop | Messages | **Yes** |
| Start in Jot field A → switch to field B → stop | field B | **No** |

Stamping save/no-save at *start* would drop the case-2 transcript — real data loss. So the
**no-save-in-Jot-fields feature is preserved exactly**, decided at the stop site. The
current foreground signal stays as the data-loss-safe floor; we only stop *entangling* it
with Hero logic and render state.

### The genuinely fragile bit — in-app paste *delivery* — is fixed by the decouple

The flaky part isn't either decision; it's the in-app paste *delivery* (the
`FocusedFieldInsert` bridge, the proxy disconnect, the duplicate/dropped paste). The bug
doc already states the fix is "deferred to the root-decoupling refactor … which isolates
the field so the keyboard flush works in-app." Isolating the field (Step 4 below) is what
makes delivery reliable. We treat "delete the bridge" as a **hypothesis validated on
device**, not a guarantee — if the field still re-mounts after isolation, the bridge stays.

---

## Target architecture

```
JotApp  ──────────────────── owns the app-level URL routing + injects the Router
  └─ AppRootView                       ← the shell. Owns NavigationStack(path) + modal
       │  reads: Router only             presenters. Observes ZERO volatile state.
       │
       ├─ Router (@Observable, app-owned, injected)   ← the ONLY nav source of truth:
       │     path: [Route]                              stack pushes (enum), incl. Route.hero(intent)
       │     sheet: Sheet?                              one modal at a time (enum)
       │     var currentRoute: Route
       │     (the "external-keyboard open" bit stays on JotApp — the Router just reads it)
       │
       ├─ HomeScreen                    ← just a screen. reads @Query transcripts.
       │     ├─ RecordingStatusBar(leaf)← the ONLY view observing isRecording (FAB↔pill)
       │     └─ StreamingPreview (leaf) ← the ONLY view observing StreamingPartial
       │
       ├─ TranscriptDetailScreen / RecordingHeroScreen
       ├─ AskScreen / SettingsScreen / HelpScreen     (unchanged internally)
       └─ Wizard (fullScreenCover, stays at JotApp level)

Underneath all screens (layers, not tree):
  Services (@Observable, per-domain)  ← RecordingService, DictationPipeline, AskController…
  Repository (TranscriptStore)        ← the ONLY code touching the transcript store + mirror
  SwiftData store / App Group         ← persistence + cross-process channel
```

Why this isn't a new monolith: the Router holds **only navigation state** — low-churn,
changes on navigation, never per-frame. The sin in `ContentView` was mixing low-churn
navigation with high-churn volatile reads in one body.

---

## Complete route inventory (from the code, not memory)

**Top-level routes — in the Router:**

| Route | Reached from | Today |
|---|---|---|
| Home (Recents) | root | `ContentView` body |
| Transcript Detail | Recents row tap, **Ask citation chip**, **`jot://transcript?id=` deep link** (3 entries) | `navigationDestination(for: UUID)` |
| Recording Hero / Return-to-app | FAB, keyboard `jot://dictate` bounce, return pill | `navigationDestination(isPresented:)` |
| Keyboard-rewrite landing | keyboard rewrite deep link | `navigationDestination(for: KeyboardRewriteTarget)` |
| Settings / Help / Ask | Home header / pill | `.sheet` |
| Wizard | first run / re-run | `fullScreenCover` at `JotApp` level (stays) |

**App-level URL routing** (`JotApp.onOpenURL`): `jot://dictate`, `jot://transcript`,
`jot://history` — the Router must be reachable here, which is why it's **app-owned and
injected**, not purely `@Environment`. (Note: Action-Button / Siri AppIntents foreground to
the **return pill / home**, NOT the Hero — `DictateIntent` never sets the hero flag; verified.)

**Permanent two-object boundary (not a violation):** `KeyboardRewriteRouter` lives in
`Shared/` because the **keyboard target links it** — it cannot move into the in-app
Router. So the contract is explicit: *cross-process intent inbox (`KeyboardRewriteRouter`,
two fields: `pendingTarget`, `pendingOpenTranscriptID`) → in-app `Router`.* One hands off
to the other; they don't merge.

**Local sub-navigation — stays inside its screen, NOT in the Router:** Settings' 9
sub-pages (incl. Send Feedback), Transcript Detail's Rewrite/AI sheets, Home's
delete/combine/bulk dialogs. Rule: *a route is in the Router only if more than one screen
reaches it or it's top-level.* (Backend analogy: top-level URL router vs. a controller's
private sub-resources.)

---

## The pattern: "how to add a feature" (the self-enforcing deliverable)

This is the durable goal made concrete. After the refactor, adding a feature is a fixed
recipe — and this list goes verbatim into `ARCHITECTURE.md`:

- **A new full screen reachable only by in-app navigation?** → add a `Route` case, add the
  screen view, add one `navigationDestination` arm. *(3 known places.)*
- **…also reachable from outside the app?** → **+1 documented file per external entry
  point:** a deep-link arm in `JotApp.onOpenURL`; **and/or** an `AppIntent` + its
  `AppShortcut` entry; **and/or** a field on the cross-process `KeyboardRewriteRouter` + one
  consume-`.onChange`. Still a fixed, predictable set — just not "nothing else."
- **A new modal?** → add a `Sheet` case + one `.sheet` arm.
- **A new data operation on transcripts?** → add one method to `TranscriptStore`. Views
  call it; nobody else touches `modelContext` or the mirror.
- **New business logic for a domain?** → it goes in that domain's Service, never in a view.
- **Local-only state (a flash, a toggle, selection)?** → `@State` on the screen. Stays put.

If a feature can't be expressed in these moves, that's the signal to extend the *pattern*
deliberately (and update this doc), not to bolt state onto a god-view.

---

## Migration — strangler-fig, independently shippable steps

Each step is shippable, **zero behavior change**, with an on-device gate the owner runs
before the next. Order: data layer → nav state → structure → field isolation → paste-delivery test.

> **Line cites are indicative — relocate by symbol, not number.** The files grew since
> 2026-06-09 (`ContentView` 1,266 → 1,331; `TranscriptDetailView` ≈ 2,330). The function /
> symbol names below are the source of truth; the `:NNNN` anchors are reconciled to
> 2026-06-24 where given but will drift again. Find by symbol.

### Step 0 — Extract the transcript Repository (independent, lands first)
Move **every** transcript store-mutation into `TranscriptStore`, **including** the
`TranscriptHistoryMirror.refresh` + Darwin-notification fan-out (today hand-coded at each
site) so it lives in one place. The 2026-06-24 recon found this is **~9 mutation sites
across FOUR files** — not "5–6 in Detail + 4 in ContentView" — because two of the writers
are **not views** (an inbox drainer and the Watch-sync path), and a new vocab site landed
since 2026-06-09.

**It's a QUADRUPLET, not a triplet.** Every write site hand-codes:
`save → TranscriptHistoryMirror.refresh(from:) → post historyMirrorUpdated (Darwin)` and,
for *new-row* appends, `+ TranscriptIndexer.index(...)`. `TranscriptStore.append`
(`TranscriptStore.swift:271-331`) **already does exactly this** (save `:304`, mirror `:314`,
notify `:322`, index `:328`) — it is the proof-of-pattern the new methods copy. `markSuperseded`
(`:381-405`) is the one sanctioned exception (main-app-only flag, deliberately no mirror/notify).

**The four files / nine mutation sites (+ reads + bootstrap):**

- `ContentView` — **3 mutating + 1 read** (scene `modelContext`):
  - `delete(_:)` (`:1137`), `deleteSelectedTranscripts(ids:)` (`:1155`),
    `combineSelectedTranscripts(ids:deleteOriginals:)` (`:1197`) — each hand-codes the
    quadruplet. `fetchTranscript(byID:)` (`:1086`) is a read.
- `TranscriptDetailView` — **7 sites** (scene `modelContext`; the first review counted 5):
  - `confirmVocabAdd` (`:842`) — **NEW since 2026-06-09** (vocab in-place text fix; sets
    `transcript.text`, then quadruplet).
  - `saveEdit` (`:1860`) — original/rewrite-tab edit save.
  - `toggleRewriteRating` (`:1950`) — **save ONLY, deliberately NO mirror/notify** (ratings
    aren't shown cross-process; see its doc comment). *Preserve this asymmetry.*
  - `delete()` (`:1975`), `discardRewrite()` (`:2008`).
  - `startRewrite`-complete, in-app (`:2098`) — sets `cleanedText`, then quadruplet.
  - keyboard-originated-rewrite-complete (`:2237`) — sets `cleanedText` + quadruplet, but
    **entangled** with the App-Group rewrite-result writes (`AppGroup.rewriteResult` /
    `rewriteJobID` `:2247-2250` + `RewriteNotifications.postCompleted()`). *Only the
    persistence core moves; the rewrite-result protocol writes stay in the view.*
- `CorrectionReviewModel` (`App/Vocabulary/CorrectionReviewModel.swift:188-192`) — **NOT a
  view.** Sets `transcript.text = newText` + quadruplet. Driven from the cross-process
  correction inbox: `CorrectionInbox.drain(modelContext:)` → `JotApp.swift:537` on
  launch/foreground.
- `PhoneSideWCSession.saveTranscript(...)` (`App/WatchConnectivity/PhoneSideWCSession.swift:409-439`)
  — **NOT a view.** **Fully reimplements `append`**: hand-computes `ledgerIndex` (`:412-417`),
  insert, save, mirror (`:438`), notify (`:439`), `TranscriptIndexer`. Its own comment admits
  it "mirror[s] `TranscriptStore`'s pattern" — the clearest sign the Repository is overdue and
  new code is already drifting. Route this through `TranscriptStore.append`.
- `JotApp.swift:612-614` — a **read-only bootstrap** `TranscriptHistoryMirror.refresh` on
  scene-attach (no mutation; seeds the keyboard mirror on first launch). Belongs to the
  Repository conceptually; fold it in as a `TranscriptStore` projection call (no behavior
  change).

**Method set to add (corrected from the original `update/setRewriteRating/delete/discardRewrite/setCleanedText`):**
- `setText(id:newText:)` — **new, was missing.** Used by BOTH `confirmVocabAdd` and
  `CorrectionReviewModel`.
- **`append` gains two defaulted params (M1, recon 2026-06-24) — required to route the Watch
  path through it.** `PhoneSideWCSession.saveTranscript` passes the original recording time and
  the dedup key, so `append` must grow:
  - `createdAt: Date? = nil` — the original recording time (`PhoneSideWCSession.swift:421`);
    when `nil`, `append` keeps today's behavior (the model's `createdAt` default = now).
  - `watchOriginUUID: String? = nil` — the idempotency/dedup key
    (`PhoneSideWCSession.swift:425`), checked by `transcriptExists(watchOriginUUID:)`
    (`:400-407`) **before** the call. The dedup *check* stays at the Watch call site (it's a
    pre-insert query, not persistence); `append` only needs to persist the field so the next
    check sees it. Both params are defaulted, so every existing caller is unchanged.
- `delete(id:)` and **`delete(ids:)`** — the plural form lets `combineSelectedTranscripts`
  fire the mirror **once**. Today combine **double-fires the quadruplet** (`TranscriptStore.append`
  at `:1217` mirrors/notifies, then the manual delete-originals at `:1220-1224` mirrors/notifies
  again). Behavior-neutral cleanup the original doc didn't flag.
- `update(...)` (edit save), `setRewriteRating(...)` — **must NOT mirror/notify** (preserves
  `toggleRewriteRating`'s deliberate skip), `discardRewrite(id:)`, `setCleanedText(id:...)`
  (persistence core only — see nuance 2).
- **Every new method must `throw` (N1, recon 2026-06-24).** The view call sites have `catch`
  blocks that depend on it: keyboard `setCleanedText` catch writes `writeKeyboardError`
  (`:2257-2264`); `confirmVocabAdd` flashes a span on success (`:845`); `CorrectionReviewModel`
  returns `nil` on failure (`:195`). **Side effects that currently live inside the `do`-block
  stay in the view, AFTER the `try store…` call** (the success-path `flashSpan`/`flash`, the
  App-Group rewrite-result writes, etc.). The Repository owns only `save → mirror → notify`
  and rethrows; the view keeps its UI/protocol reactions around it.

**Three must-preserve nuances** (each a regression trap):
1. `setRewriteRating` stays mirror/notify-free.
2. Keyboard-originated `setCleanedText`: the persistence **core** is `cleanedText = trimmed;
   clear rewriteUserEdit = nil; clear rewriteUpvoted = nil; save; mirror; notify` — **both
   clears move with it** (M2, recon 2026-06-24). Both rewrite-complete sites do these clears
   before save (in-app `:2090-2096`, keyboard `:2231-2235`); a fresh model output makes the
   prior user-edit and rating meaningless. What stays in the view is the App-Group
   rewrite-result reply (`AppGroup.rewriteResult/rewriteJobID` + `postCompleted()`) — the
   keyboard handshake, not transcript persistence.
3. `combineSelectedTranscripts` currently double-fires; the new `delete(ids:)` collapses it to one.

**Key insight — "no view touches `modelContext`" is necessary but NOT sufficient.** The two
non-view writers (`CorrectionReviewModel`, `PhoneSideWCSession`) must **also** route through the
Repository, or the duplication the design exists to kill survives in code that passes the
"no view" check. The acceptance criterion is updated accordingly (below).

**Scope decision — DECIDED: all-writers-in-one (option b).** All four files land in one
Step 0 so the Repository is genuinely the sole `Transcript`/mirror owner before Step 1 —
rather than (a) views-first with a Step 0b for the two non-view writers. Rationale: the
Watch-sync duplicate is live drift and the inbox path is small; splitting risks shipping a
"Repository" that two paths still bypass. (Design-review 2026-06-24 ratified this.)

Pure view-state funcs (selection, `copied!` flash, card visibility) stay on the view.
- **Note (cross-context):** `TranscriptStore` mutates on a fresh `JotModelContainer.shared`
  context, not the scene `@Environment(\.modelContext)` the `@Query` uses. That's fine but
  behavior-sensitive — the gate must confirm propagation. (See also Q7 — the cold-load
  serialize chain runs on a different context still and does not constrain this.)
- **Gate:** swipe-delete; bulk-delete; combine 2+ (keep vs delete originals, **mirror fires
  once**); **edit-save, rate (no keyboard wake), delete, discard-rewrite, vocab in-place fix
  from Detail**; **a keyboard-correction verdict drained on foreground**; **a Watch recording
  appearing in keyboard Recents**; after each, both the home `@Query` list AND the keyboard
  Recents mirror update immediately. Identical behavior.

### Step 1 — Introduce the Router; move nav state into it
Create app-owned `Router` `@Observable`, injected from `JotApp` (reachable in
`onOpenURL`). Migrate the 6 nav Bools + `pendingExternalKeyboardHero` one at a time;
replace the `navigationDestination` plumbing with the enum path; model `HeroIntent` as
`Route.hero(intent)`.
- **Deletes:** the double-push guard, the dual-modal race workaround, the
  defer-until-teardown hack (all boolean-soup symptoms).
- **Hero LAST — the enum path rebuilds load-bearing machinery (N4, recon 2026-06-24).**
  Moving `navigationDestination(isPresented:)` → the enum path rebuilds the exact mechanism
  that `reconcileHomeRecordingIndicator` (`ContentView.swift:658-666`) + `heroIsPresented`
  (`:213`, set at `:366-367`) were written to **paper over** — and that machinery is
  **load-bearing** for warm-resume and the swipe-back card cue (it re-surfaces the recording
  pill when a hero is swipe-back-dismissed without writing its binding back, and clears a stale
  external-keyboard-hero flag). So **sequence within Step 1:** migrate the Settings/Help/Ask
  **sheets first** (low-risk, no reconcile entanglement), do the **hero LAST**, and **delete
  `reconcileHomeRecordingIndicator` as the final Step-1 commit with its own gate** (warm-resume
  + swipe-back card cue + external-keyboard bounce), so the deletion is independently revertable
  if the enum path doesn't fully subsume it.
- **Guardrail (recon 2026-06-24):** Router injection must be **purely additive** to
  `JotApp`'s existing `@State` services. It must **NOT** reorder or gate either launch-sensitive
  path: (1) the `init` launch-serialize Task (`JotApp.swift` ≈ `:205–225`: `awaitWarmSettled`
  → vocab `prepare` → embedding prewarm — the chain that shipped the cold-load 60→16s fix);
  **and** (2) the scene `.task` (`JotApp.swift:598-614`: `warmIfNeeded()` + the bootstrap
  `TranscriptHistoryMirror.refresh`), which is also launch-sensitive. It must **NOT** sit in
  front of the `onOpenURL` early-returns. Inject the Router alongside the services; don't touch
  either chain's order or the URL-routing guards.
- **Gate:** every flow (open/close Settings/Help/Ask; row→Detail→back; FAB→Hero→stop;
  keyboard bounce→Hero; deep links; re-run wizard) behaves identically; **cold-launch model
  load time is unchanged** (neither launch chain was perturbed).

### Step 2 — Extract `HomeScreen`; `ContentView` → `AppRootView`
Pull Home content into `HomeScreen`. `AppRootView` keeps only the `NavigationStack` +
modal presenters + Router. Home is now a routed screen with no privilege.
- **Gate:** Step-1 checklist + selection mode + donation / warm-hold-nudge cards.

### Step 3 — Push volatile reads down to leaves (kills the render cascade)
First, a free no-op cleanup: `ContentView` declares `@Environment(StreamingPartial.self)`
(`:128`) but **never reads it in the body** — delete the vestigial **declaration** (the
streaming preview only renders inside `RecordingHeroView`).
- **Delete the declaration ONLY — keep the injection (N3, recon 2026-06-24).** Remove the
  `@Environment(StreamingPartial.self)` property at `ContentView.swift:128`, but **KEEP** the
  production `.environment(StreamingPartial())` injection at **`JotApp.swift:173`**
  (`let streamingPartial = StreamingPartial()` → injected into the scene) — `RecordingHeroView`
  reads it downstream. (Note: `ContentView.swift:1329` is also a `.environment(StreamingPartial())`
  but it lives in the `#Preview` block at `:1324`, not production — leave it.) Deleting the
  injection would blank the live streaming preview.

The real shell-level volatile read is `recordingService.isRecording` (drives `.animation`
`:342`, `isLiveRecordingInline` `:578`). Push that (plus the donation flag and warm-hold nudge)
into the leaf that renders each, so `AppRootView`'s body reads only the Router.
- **Honest about testing:** Step 3's *only* observable effect IS the field-perturbation it
  fixes, so "zero behavior change" is circular here. The real gate = the same on-device
  check as Step 4: **with a Jot field focused (Edit/Feedback/Settings), a recording stop
  must not steal focus or re-mount the field.** Steps 3 and 4 share this gate.

### Step 4 — Validate field isolation; decide the bridge's fate
No new entry abstraction (see Decision A — the only crossing bit, `pendingExternalKeyboardHero`,
already moved into the Router in Step 1). Step 4 is purely the **paste-delivery test**: after
Step 3 isolates the field, does the in-app field stop re-mounting on stop? If yes, delete
`FocusedFieldInsert` and the proxy guards (one paste path). If it still re-mounts, keep the
bridge — and record the residual cause as the lead for the deferred keyboard bug.
- **Framing (recon 2026-06-24):** the in-app duplicate-paste is **currently contained** by
  the clear-pending-before-publish bridge — it is **not a live bug today**. So Step 4 is a
  **delete-the-bridge SIMPLIFICATION** (gated on the on-device field-isolation test), **not a
  bug-fix**. If the test shows the field no longer re-mounts, deleting the bridge collapses
  two paste paths into one; if it still re-mounts, the bridge stays and nothing regresses.
  Frame the gate as "can we remove containment?", not "does paste work?".
- **Gate:** full dictation matrix — Edit, Feedback, Wizard W5, other-app (Messages + a
  custom field) — each pastes exactly once; **save only when stopped outside a Jot field**
  (the preserved feature); Hero shows only per the entry table.

> Save-vs-no-save (Decision B) is **not** changed by any step — it stays at the stop site.

---

## Acceptance criteria

- [ ] **Locality:** adding an in-app screen touches a fixed, documented set (Route case +
      screen + one destination arm), +1 documented file per external entry point — verified
      by writing the "how to add a feature" section and dog-fooding it on one trivial screen.
- [ ] `ARCHITECTURE.md` Code-map reflects the new layers and stays short/true.
- [ ] Hero/Return-to-app presentation reads the Router's single `Route.hero(intent)`; the
      nav Bools and the 3 hack-comments are gone. (No new entry abstraction was added.)
- [ ] **`TranscriptStore` is the sole writer of the `Transcript` entity + mirror.** No view
      touches `modelContext` for transcript CRUD (**ContentView AND TranscriptDetailView**),
      **and** the two non-view writers route through it too: `CorrectionReviewModel` (inbox
      drain) and `PhoneSideWCSession.saveTranscript` (Watch sync). "No view touches
      `modelContext`" alone is necessary but not sufficient — the non-view paths must also
      go through the Repository or the duplication survives.
      - **Carve-out (N2):** the Repository owns the **`Transcript` entity + the keyboard
        mirror only.** `TranscriptChunk` (derived-data search index) has its own
        `ChunkStore` (`Shared/DerivedData/ChunkStore.swift:60-81`/`:142-148`), which writes
        on its own context and posts **no** mirror — that's correct and **out of scope** for
        Step 0. Don't fold `ChunkStore` into `TranscriptStore`.
- [ ] A recording stop re-renders only the status-bar leaf, not presented screens.
- [ ] The **no-save-in-Jot-fields feature is preserved**, decided at the stop site.
- [ ] Every existing flow behaves identically; no visual change.

## Open questions (resolved unless noted)

1. **Decide-at-stop vs start** — RESOLVED: save stays at stop (data-loss otherwise);
   Hero/Return-to-app is a source-based entry decision the keyboard mostly resolves itself. ✓
2. **Can the bridge be deleted?** — OPEN, validated on device in Step 4, not assumed.
6. **Is a `DictationEntryContext` needed?** — RESOLVED: NO. The keyboard's warm/foreground
   decision is an async cross-process handshake resolved keyboard-side; the only bit that
   crosses is "external-keyboard open" (`pendingExternalKeyboardHero`), which already exists
   and just moves into the Router. Adding a multi-field entry context would be over-engineering. ✓
3. **`KeyboardRewriteRouter` merge?** — RESOLVED: it can't (keyboard links it); it's a
   permanent cross-process inbox that hands off to the Router. ✓
4. **Wizard placement** — RESOLVED: stays a `fullScreenCover` at `JotApp` level. ✓
5. **Empty `cover` slot** — RESOLVED: dropped; only the wizard exists and it stays
   app-level. Don't add the slot until a second cover exists. ✓
7. **Does the cold-load serialize chain constrain Router injection or Step 0's cross-context
   writes?** — LIKELY FINE, gate item (recon 2026-06-24). The two launch-sensitive paths —
   the `init` serialize Task (`JotApp.swift` ≈ `:205–225`: `awaitWarmSettled` → vocab
   `prepare` → embedding prewarm — the chain behind the 60→16s cold-load fix) and the scene
   `.task` (`:598-614`: `warmIfNeeded` + bootstrap mirror refresh) — run independently of
   transcript persistence.
   Step 0 mutates a fresh `JotModelContainer.shared` context (unchanged from today), and
   Router injection is additive `@State` (Step 1 guardrail). Neither should touch the chain's
   order or the `onOpenURL` early-returns — but because a regression here is silent and
   expensive, **confirm on device:** Step 1's gate includes "cold-launch model-load time
   unchanged." ⏳

## Sources (expert grounding)

- Naumov, *Clean Architecture for SwiftUI* — View/Interactor/Repository layering, single
  source of truth incl. navigation, no-ViewModel rationale.
  <https://nalexn.github.io/clean-architecture-swiftui/>
- *SwiftUI — MV + Router* — ViewModel redundant in SwiftUI; Router = Coordinator done the
  SwiftUI way. <https://medium.com/@chuntachen/swiftui-mv-router-74dc21474e5f>

**Adaptation note:** we take the layering (View/Service/Repository/Router) but reject the
single mega-`AppState` in favor of fine-grained `@Observable` services — the iOS-17+
refinement that keeps the Router small and avoids recreating a god object.
