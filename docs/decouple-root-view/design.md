# Jot architecture: decouple the root view + a pattern every feature follows

> **Status: DESIGN (pre-implementation).** Supersedes the seed at
> `docs/plans/refactor-decouple-root-view.md`. Rewritten 2026-06-09 after a long
> requirements pass with the owner and one adversarial review. Read this top to bottom
> before touching code.

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

### Step 0 — Extract the transcript Repository (independent, lands first)
Move **every** view-level transcript store-mutation into `TranscriptStore`, **including**
the `TranscriptHistoryMirror.refresh` + Darwin-notification fan-out (today hand-coded at
each site) so it lives in one place. Two views are affected, not one:
- `ContentView`: `delete` / `deleteSelectedTranscripts` / `combineSelectedTranscripts` /
  `fetchTranscript`.
- `TranscriptDetailView`: **5 sites** the first review caught — edit-save (`:1180`), rating
  (`:1256`), delete (`:1281`), discard-rewrite (`:1314`), rewrite-complete saves
  (`:1404`,`:1515`). Each hand-codes the same save→mirror→notify triplet. Add
  `TranscriptStore.update(...)` / `setRewriteRating(...)` / `delete(id:)` /
  `discardRewrite(id:)` / `setCleanedText(...)`.

Pure view-state funcs (selection, `copied!` flash, card visibility) stay on the view.
- **Note (cross-context):** `TranscriptStore` mutates on a fresh `JotModelContainer.shared`
  context, not the scene `@Environment(\.modelContext)` the `@Query` uses. That's fine but
  behavior-sensitive — the gate must confirm propagation.
- **Gate:** swipe-delete; bulk-delete; combine 2+ (keep vs delete originals); **edit-save,
  rate, delete, discard-rewrite from Detail**; after each, both the home `@Query` list AND
  the keyboard Recents mirror update immediately. Identical behavior.

### Step 1 — Introduce the Router; move nav state into it
Create app-owned `Router` `@Observable`, injected from `JotApp` (reachable in
`onOpenURL`). Migrate the 6 nav Bools + `pendingExternalKeyboardHero` one at a time;
replace the `navigationDestination` plumbing with the enum path; model `HeroIntent` as
`Route.hero(intent)`.
- **Deletes:** the double-push guard, the dual-modal race workaround, the
  defer-until-teardown hack (all boolean-soup symptoms).
- **Gate:** every flow (open/close Settings/Help/Ask; row→Detail→back; FAB→Hero→stop;
  keyboard bounce→Hero; deep links; re-run wizard) behaves identically.

### Step 2 — Extract `HomeScreen`; `ContentView` → `AppRootView`
Pull Home content into `HomeScreen`. `AppRootView` keeps only the `NavigationStack` +
modal presenters + Router. Home is now a routed screen with no privilege.
- **Gate:** Step-1 checklist + selection mode + donation / warm-hold-nudge cards.

### Step 3 — Push volatile reads down to leaves (kills the render cascade)
First, a free no-op cleanup: `ContentView` declares `@Environment(StreamingPartial.self)`
(`:128`) but **never reads it in the body** — delete the vestigial declaration (the
streaming preview only renders inside `RecordingHeroView`). The real shell-level volatile
read is `recordingService.isRecording` (drives `.animation` `:342`, `isLiveRecordingInline`
`:578`). Push that (plus the donation flag and warm-hold nudge) into the leaf that renders
each, so `AppRootView`'s body reads only the Router.
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
- [ ] No view touches `modelContext` for transcript CRUD — **ContentView AND
      TranscriptDetailView** — all via `TranscriptStore`.
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

## Sources (expert grounding)

- Naumov, *Clean Architecture for SwiftUI* — View/Interactor/Repository layering, single
  source of truth incl. navigation, no-ViewModel rationale.
  <https://nalexn.github.io/clean-architecture-swiftui/>
- *SwiftUI — MV + Router* — ViewModel redundant in SwiftUI; Router = Coordinator done the
  SwiftUI way. <https://medium.com/@chuntachen/swiftui-mv-router-74dc21474e5f>

**Adaptation note:** we take the layering (View/Service/Repository/Router) but reject the
single mega-`AppState` in favor of fine-grained `@Observable` services — the iOS-17+
refinement that keeps the Router small and avoids recreating a god object.
