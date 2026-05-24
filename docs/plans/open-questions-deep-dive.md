# Open Questions Deep Dive — All Paths Explored

> **Status:** Companion to the 10 plans in `docs/plans/`. For every open question, this doc walks each option's pros, cons, who it's good for, second-order effects, and (where applicable) a recommendation. Read this when you're ready to make decisions; come back to each plan after.
>
> **Reading order:** by plan, alphabetically by file. Quick-scan: bold **Recommendation** at the bottom of each question.

---

## Table of contents

- [A1 — Keyboard Magic Wand Entry](#a1--keyboard-magic-wand-entry)
- [A2 — Transcript Titles and Tags](#a2--transcript-titles-and-tags)
- [D1 — Migration System](#d1--migration-system)
- [D2 — In-App Tap-to-Record](#d2--in-app-tap-to-record)
- [D3 — Feature Catalog + Release Log](#d3--feature-catalog--release-log)
- [D4 — Donation Milestone Card](#d4--donation-milestone-card)
- [B1 — Cold-Start Dictation Race](#b1--cold-start-dictation-race)
- [B2 — Keyboard Auto-Switch](#b2--keyboard-auto-switch)
- [B3 — Slack Silent Paste](#b3--slack-silent-paste)
- [B4 — User-Prompt No Preview](#b4--user-prompt-no-preview)

---

## A1 — Keyboard Magic Wand Entry

### Q1. Should the keyboard wand popover show just the 4 built-in defaults, or also include user-created prompts?

**Option a — Built-ins only (Articulate, AI prompt, Action Items, Email).**
- *Pros:* Small popover, fast tap target, predictable surface area. Onboarding-friendly — no decision paralysis for new users. Keyboard binary footprint stays minimal (don't need to render variable-length user-prompt lists).
- *Cons:* A user who's built a "Translate to French" custom prompt has to open the main app, navigate to detail view, and use Transform there to use it from a host. Defeats the wand's "fast in-place rewrite" value.
- *Good for:* Users who never customize prompts. The casual majority.

**Option b — Built-ins + user prompts (LIFO, capped at 5).**
- *Pros:* The user's most-recent custom prompts are one tap away from any host app — peak value-add. Cap-of-5 keeps the popover scannable.
- *Cons:* Decisions: how to sort user prompts (by edit time? by use count?). LIFO is intuitive but a prompt the user edited once a month ago is still "recent" in LIFO terms even though they haven't used it. Edge case: what if user has 5 user prompts AND custom-prompt-only intent? They never see built-ins from the wand. Probably fine but worth naming.
- *Good for:* Power users who write custom prompts and use them frequently.

**Option c — Built-ins + ALL user prompts (scrollable popover).**
- *Pros:* Full parity with the main-app Prompt Picker. No "where's my prompt?" surprise.
- *Cons:* Popover gets long; scrolling in a keyboard-anchored popover is awkward (the keyboard already occupies the bottom; popover needs to grow upward and the user's eye traverses farther). Memory and render cost in the keyboard process grow with prompt count — small but real per the 60 MB ceiling.
- *Good for:* Users with 3-5 user prompts (small enough that the popover doesn't bloat).

**Option d — Configurable in Settings: "Show in keyboard wand: [defaults / defaults + favorites / all]".**
- *Pros:* User chooses. No wrong answer.
- *Cons:* New Settings surface. "Favorites" requires a star/pin affordance on each prompt — adds chrome to the Prompt Picker. Onboarding cost: another decision the user might not want to make.

**Recommendation:** **b (Built-ins + LIFO user prompts, capped at 5).** Reasoning: peak value-add for users who customize, while keeping the keyboard popover tight. If real usage shows the LIFO doesn't match user intent, layer in a "pinned" affordance later (option d-light).

**Sub-decision if b:** sort order within the popover.
- Built-ins always first (in their canonical order: Articulate, AI prompt, Action Items, Email).
- Then user prompts, ordered by most-recent-edit timestamp.
- If a user prompt has a `lastSample` (see [B4](#b4--user-prompt-no-preview)), preview the prompt's name + a single-line `lastSample.afterText` snippet (the "what this does" hint). Otherwise just name.

---

### Q2. Completed-rewrite banner: auto-dismiss vs. stay-until-tapped?

**Option a — Auto-dismiss at ~4 seconds.**
- *Pros:* No banner persistence eating keyboard real estate. Matches existing keyboard banner cadence (transcription results auto-clear at ~2.5 s per §5.10). User can ignore and continue.
- *Cons:* If the user looked away during the rewrite (e.g. checked their phone screen back to the host app), they may miss the banner entirely. The result is in the transcript library, but they don't know to look.

**Option b — Stay-until-tapped (banner persists indefinitely).**
- *Pros:* Guaranteed visibility — user can't miss it.
- *Cons:* Banner occupies the keyboard's status banner slot, blocking subsequent banner messages (e.g. a microphone-permission notice on next dictation). Has to dismiss-clean on next user interaction with the keyboard, which adds banner-management complexity.

**Option c — Auto-dismiss at a longer interval (~10 s) with explicit dismiss on tap.**
- *Pros:* Compromise: more time to read, but doesn't permanently block other banners.
- *Cons:* 10 s is forever in keyboard time. Other banners during that window get queued (more state) or override (worse UX) or are dropped (lossy).

**Option d — Persistent dot on the wand button itself (no banner).**
- *Pros:* Doesn't occupy the banner slot. The dot ("you have a pending rewrite to review") survives keyboard re-presentation. Tap on the wand opens the result.
- *Cons:* Subtle — easy to miss. The "review" flow is unclear — does tap open the transcript detail in main app, or surface the result inline?

**Recommendation:** **a (auto-dismiss at 4 s)** for v1, paired with the existing `KeyboardPendingRewriteState` resurrection path. If the user shows up later (in a new keyboard presentation) and there's a fresh-but-unviewed rewrite, surface the banner once on that next-appear too. Combination of "fast feedback now" + "second-chance signal later" without the binary "permanent / never" extremes.

**Concrete copy:**
- Banner on completion: *"Rewritten with \<prompt name\>"* — tap to open in the main app.
- If user navigates away before tap and comes back: same banner re-fires once on next `viewDidAppear` (covered by `KeyboardPendingRewriteState`).

---

### Q3. §7.3 caveat removal — at what point?

**Option a — Remove caveat in Phase 0 (when Help copy is fixed).**
- *Pros:* features.md immediately accurate to the in-app state.
- *Cons:* But the wand is still not built. So features.md says "wand exists" while user can't find one in the keyboard. Worse than the current caveat.

**Option b — Keep caveat through Phase 0, remove only when Phase 1 ships.**
- *Pros:* features.md remains accurate at every moment — caveat documents "we say wand-in-keyboard but it isn't there" until the wand IS there.
- *Cons:* features.md and Help copy briefly drift (Help says "transcript only" while features.md still mentions "or in the keyboard"). Reader has to read both.

**Option c — Remove caveat in Phase 0, also remove the §7.3 mention of "keyboard wand" entirely.**
- *Pros:* features.md and Help both honest — neither mentions a keyboard wand until it exists.
- *Cons:* Adds a future doc edit when Phase 1 lands (re-introducing the keyboard-wand mention). Reversible drift.

**Recommendation:** **b.** features.md's purpose is to document reality, and the §7.3 caveat sentence ("the keyboard wand/Magic entry point is advertised but not yet present") is the most accurate possible documentation between Phase 0 and Phase 1. Once Phase 1 ships, the caveat goes away in the same PR.

---

## A2 — Transcript Titles and Tags

### Q1. Path A (delete), B (titles only), or C (titles + tags)?

This is the major decision for the plan. Below: a deeper exploration than the plan's Phase 0 matrix.

**Option a — Delete (remove §7.11 footnote + drop the aspirational claim).**
- *Pros:* XS work. No SwiftData migration. No new background-task complexity. Doesn't mislead users about a feature that doesn't exist.
- *Cons:* Loses the discovery value of titles for users who already organize their notes by topic. Stalls a path the user once thought was worth claiming in Settings copy.
- *Good for:* Pre-launch decision when there's no user demand evidence and the user wants to ship 1.x without scope creep.

**Option b — Build titles only.**
- *Pros:* Concrete user value: "what is this transcript about" at a glance in the library. Detail view header becomes a real title. SwiftData migration scaffolding is real work but it's also work we'll need eventually for any future field add. Apple FM infra exists.
- *Cons:* Coupled to SwiftData schema versioning (which is deferred — see D1 + the note in A2). Background-task complexity for warm-hold path (need to queue title generation when main app is backgrounded). Apple-Intelligence-off devices see no titles (graceful but a feature-gap on lower-tier hardware).
- *Good for:* Users with growing libraries (50+ transcripts) where text excerpts start blurring together.

**Option c — Build titles + tags.**
- *Pros:* Tags add a second axis of organization — search by topic, future filter UI. Differentiates from competitors (most dictation apps don't tag).
- *Cons:* Tag taxonomy is ambiguous (free-form vs. closed-set), tag UI in the row is more visual debt, tag-based search ties to the live-search semantics in §1.3. Phase 2 effort = doubles the build cost. And the user hasn't expressed need for tags.
- *Good for:* If the user is committed to making Jot a "second-brain" tool over time. Probably not at v1.x.

**Option d — Build titles, NOT-build tags, AND defer to D1 first.**
- *Pros:* Sequencing is honest — D1 (migration system) lays the SwiftData schema-versioning groundwork properly, then A2-titles ships cleanly on top. Avoids the "we built titles with a hacky pre-launch overwrite migration and now we're stuck with that hack post-launch" scenario.
- *Cons:* Longer wait for titles to appear in-app. The user has to live with the §7.11 footnote (or remove it via option a first).
- *Good for:* The disciplined version of option b.

**Option e — Build user-editable titles (no AI), tap-to-add.**
- *Pros:* Lower complexity: no Apple FM, no background queue, no privacy questions. User has full control. Works on every device.
- *Cons:* Friction: every transcript requires a manual title tap. Most users won't bother. Defeats the "zero-friction dictation" pillar.
- *Good for:* Users who title only their important transcripts and leave the rest titled-by-excerpt.

**Option f — Hybrid: AI auto-titles by default, user can edit.**
- *Pros:* Best of b + e. AI does the heavy lifting; user corrects when wrong.
- *Cons:* Most expensive option. Requires the AI path AND the user-edit UI.
- *Good for:* Post-launch maturity, not v1.

**Recommendation:** **a** for now, with the explicit understanding that if titles get user demand, **d** is the sequenced way to add them (D1 first, then A2-titles). Reasoning:
- No evidence users want titles today.
- The §7.11 footnote is the only real user-facing pain — fix it by deleting.
- If demand emerges, the work happens on a proper foundation, not a pre-launch shortcut.

**Sub-question if a is chosen:** what does §7.11 look like after?

Most precise rewrite: delete §7.11 entirely (the discrepancy is gone once both the footnote and the absence agree). §3.2 stays as-is (no title surface).

---

### Q2. If B (or D): pre-launch ship vs. post-launch ship?

(Only relevant if Q1 picks b/c/d.)

**Option a — Pre-launch ship with the always-overwrite policy intact.**
- *Pros:* Fast. Doesn't need the full `VersionedSchema` + `SchemaMigrationPlan` SwiftData scaffolding because the user has explicitly accepted "wipe and rebuild" pre-launch.
- *Cons:* Creates technical debt — the post-launch shape needs to support real schema versioning, so we'd have to rewrite the migration handling later anyway. Also gambles: if the App Store reviewer trips on the title generation path, we'd be reworking under pressure.

**Option b — Post-launch with proper SwiftData migration plan.**
- *Pros:* Durable. The schema versioning is in place from day one. Lessons from D1's migration plan are applied.
- *Cons:* Longer wait. The §7.11 footnote stays misleading for longer (unless you also delete it via Q1's option a first as a stopgap).

**Option c — Pre-launch ship a placeholder (`title: String?` field added, set to nil always) and wire up generation post-launch.**
- *Pros:* Schema is in place pre-launch — the post-launch generation work doesn't require another schema bump. Avoids the "wipe and rebuild" gamble.
- *Cons:* Two ships needed to land the user-visible feature. The placeholder field doesn't justify itself if generation never lands.

**Recommendation if Q1 is b/d:** **c (placeholder pre-launch, generation post-launch).** Sequences the schema work safely while keeping the post-launch generation as a clean feature ship.

---

### Q3. If B: how visible is "title generating…" state?

**Option a — Excerpt fallback (no indicator).**
- *Pros:* Simplest. User sees the text excerpt until the title arrives. When the title arrives, it fades in over the excerpt.
- *Cons:* User doesn't know a title is coming. May think their device doesn't support titles (Apple-Intelligence-off case looks identical).

**Option b — Subtle pulsing placeholder.**
- *Pros:* Signals "title is generating, hold on" without being alarming.
- *Cons:* Tying the placeholder to actual generation lifecycle adds state. If the main app is backgrounded (warm-hold path), the placeholder pulses... forever? Or until app-foreground? Edge cases.

**Option c — "Generating title…" italic label in the title slot.**
- *Pros:* Explicit. User understands what's happening.
- *Cons:* Visual noise on the library list — every recent transcript flashes "Generating title…" briefly. Compared to excerpt-fallback, this is more obvious but worse-looking.

**Option d — Show excerpt; on title arrival, animate the transition smoothly.**
- *Pros:* Honest about state: there is no title yet, so we show the excerpt. When it arrives, the row morphs.
- *Cons:* The animation has to handle "title arrives 5 minutes later because user backgrounded" gracefully.

**Recommendation if Q1 is b/d:** **a + d combined** — start with excerpt; animate to title when it arrives. Subtle enough to not be noisy; clear enough to feel like progress.

---

### Q4. If A: do we keep §7.11 as a historical record or remove it entirely?

**Option a — Remove §7.11 entirely. Remove the §3.2 "intentionally absent" caveat too.**
- *Pros:* features.md describes the present, not history. Clean.
- *Cons:* Loses the documented intent. If a future reader asks "why no titles in Jot?", there's no in-doc answer.

**Option b — Keep §7.11 but rewrite as "Title surface deferred."**
- *Pros:* Documents the deliberate non-ship. Useful for future contributors.
- *Cons:* Doesn't match features.md's stated scope ("user-facing features only" — a non-feature is not a feature).

**Option c — Move the historical note to `docs/deferred-engineering.md`.**
- *Pros:* Historical context goes in the right place. features.md stays clean.
- *Cons:* Trivial maintenance addition to deferred-engineering.md.

**Recommendation if Q1 is a:** **c.** features.md describes what ships; `docs/deferred-engineering.md` already exists for "things we chose not to build" — natural home.

---

## D1 — Migration System

### Q1. Does the detached pattern survive the runner conversion intact for Phi-4?

The current Phi4WeightsPurge flow is:
1. Check disk exists.
2. If exists, flip the flag.
3. Dispatch detached delete (fire-and-forget).
4. If didn't exist, also flip the flag (so we don't re-poll filesystem).

The runner's `.detached` branch needs to preserve all four steps. Concretely:

**Option a — Migration.apply() does the disk check + flag-flip + dispatch internally; runner just calls apply.**
- *Pros:* Each migration is self-contained. The runner doesn't have to know about disk semantics.
- *Cons:* Every detached migration repeats the same scaffolding. Boilerplate.

**Option b — Runner separates "is this still needed?" probe from "do the work."**
- *Pros:* DRY: the probe and the dispatch are runner concerns.
- *Cons:* Forces every detached migration into a shape that may not fit (some migrations have complex "still needed?" checks).

**Option c — Hybrid: protocol has `needsToRun()` (optional, defaults true) + `apply()`. Runner calls `needsToRun()` first; if false, marks applied without `apply()` running.**
- *Pros:* Clean. Handles the "nothing on disk, skip work but mark done" Phi-4 case.
- *Cons:* Slight protocol bloat.

**Recommendation:** **c.** Add `var needsToRun: Bool { get }` to the Migration protocol with default `true`. Phi-4's implementation returns false when the directory doesn't exist. Runner short-circuits the apply call but marks applied.

This also helps other migrations: if `sweepLegacyAppSupportWeights` finds nothing, it doesn't need to do anything but should still mark applied to avoid filesystem re-scanning.

---

### Q2. Circuit-broken migrations: UI banner or only diagnostics?

**Option a — Diagnostics only (silent failure for the user).**
- *Pros:* Doesn't surface a scary banner to a confused user.
- *Cons:* User has no idea something broke. If the broken migration's purpose mattered (e.g. AI prompt seeding), the user just sees missing functionality with no explanation.

**Option b — One-shot banner with "send diagnostic" action.**
- *Pros:* User knows something happened; we get actionable telemetry.
- *Cons:* Adds a "something is wrong" surface to an otherwise quiet app. Banner copy is hard to get right.

**Option c — Silent for migration system, but the migration's owner (the affected feature) surfaces the consequence.**
- *Pros:* If "AI prompt insert" fails 3x and circuit-breaks, the AI Settings screen could show "Couldn't seed default prompts — tap to retry" the next time the user lands there. Localized, contextual.
- *Cons:* Each migration needs its own surface for failure consequences. More wiring.

**Recommendation:** **a (diagnostics only) for v1**, escalate to **c** only if real user reports surface from circuit-breaks. Reasoning: in practice, with the work-then-flag pattern + circuit breaker, migrations should rarely break — surfacing a generic banner for a rare-and-mostly-recoverable case is more friction than value. Diagnostics is enough to let support investigate when needed.

**If c is later adopted:** the consequences-per-feature are small additions, not architectural changes.

---

### Q3. Where does device_install_id get stamped?

**Option a — Bootstrap migration at version 0.**
- *Pros:* Stamps on the first-ever `MigrationRunner.runPending()` call. Self-bootstrapping; lives in the same file as other migrations.
- *Cons:* The boot loop has to handle "applied-list is empty AND this is the bootstrap migration" specially — the bootstrap can't itself be "applied" or it would never run again on a fresh container.

**Option b — Stamp in App Group's first read (whoever opens `AppGroup` first).**
- *Pros:* No special-case in the migration runner. Independent of migrations entirely.
- *Cons:* Couples App Group access to a lifecycle event. The keyboard process could be first to open App Group (e.g. user installs Jot, never opens it, then taps Jot keyboard in a host app first) — does the keyboard stamp the id? Probably fine but worth naming.

**Option c — Stamp during the first `JotApp.init`.**
- *Pros:* Predictable: main app always stamps. Keyboard never has to.
- *Cons:* Same edge case as b — what if keyboard process opens App Group before main app ever runs? Now `device_install_id` is nil until main app runs.

**Recommendation:** **a (bootstrap migration v0).** Cleanest separation of concerns:
- v0: `StampDeviceInstallID` (always-apply, sets the id if absent).
- v1+: actual migrations.

The "always-apply, sets if absent" pattern is idempotent and tolerates multiple processes.

---

## D2 — In-App Tap-to-Record

### Q1. Selection replacement vs. insert at cursor?

When the user has selected text in the in-app field and triggers in-place dictation, what happens to the selection?

**Option a — Replace selection with the dictation result.**
- *Pros:* Matches macOS dictation. "I selected this paragraph; I want to dictate a new version" maps cleanly to "select → speak → replaces."
- *Cons:* If the user accidentally has text selected (e.g. double-tap selected a word), their selected word is destroyed and replaced.

**Option b — Drop selection, insert at cursor (treat selection as just a cursor position).**
- *Pros:* Matches iOS dictation. Less destructive; user's selected text survives.
- *Cons:* "Replace my notes with this new dictation" is harder to achieve in one motion.

**Option c — Don't insert at all if there's a selection; surface a banner: "Selection detected — clear it to dictate."**
- *Pros:* Safest. User makes an explicit choice.
- *Cons:* Adds friction. Defeats some of the "fast in-place" value.

**Option d — Smart: replace if selection is > N chars, insert at cursor if < N chars.**
- *Pros:* Heuristic that matches intent: large selections are "I want to redo this," small ones are "I tapped here." Threshold could be ~10 chars.
- *Cons:* Magic-feeling. Users hit cases where they intended one and got the other.

**Recommendation:** **a (replace selection).** Reasoning:
- The in-place flow is intentional — user focused, then chose dictation. They knew what they were doing.
- Matches macOS dictation, which more users are familiar with than they realize.
- If users complain about accidental replacement, we can add a confirmation banner for large selections (>200 chars), which is a small additive change.

---

### Q2. ACK handshake design — Darwin round-trip vs. AppGroup poll?

When the keyboard posts `inAppDictationRequested`, it needs to know the main app received it.

**Option a — Darwin notification ACK (`inAppDictationAcknowledged`).**
- *Pros:* Lighter weight; matches the existing Darwin-based IPC pattern in the codebase.
- *Cons:* If the main app is paused (suspended but not killed), Darwin notifications queue but don't fire until resumed. Keyboard's timeout fires, fallback to URL bounce kicks in. User sees a flash of the Hero — not ideal but recoverable.

**Option b — Keyboard polls AppGroup for an `acknowledgedAt` timestamp.**
- *Pros:* Polling tolerates main-app suspension better — when it resumes, it writes the timestamp synchronously.
- *Cons:* Polling burns CPU + keyboard has limited time to wait. Adds AppGroup keys.

**Option c — Combined: post Darwin AND write a "pending in-app request" to AppGroup with a TTL. Keyboard waits for ACK Darwin notification OR observes the request being consumed (removed from AppGroup by main app).**
- *Pros:* Belt and suspenders. ACK arrives via Darwin in the common case; main app consuming the request flag is a fallback signal.
- *Cons:* More state to manage.

**Option d — No ACK; optimistic dispatch with a "did the recording start?" probe.**
- *Pros:* Simplest. Keyboard fires-and-forgets; if recording doesn't start within ~1 s, fall back to URL bounce.
- *Cons:* Probe shape — keyboard would have to read `AppGroup.recordingActive` or similar. Adds an indirection.

**Recommendation:** **d (optimistic + probe).** Reasoning:
- The actual user-observable signal is "did recording start?" — the keyboard's UI changes when it does (streaming strip appears).
- If recording doesn't start in 1 s, the user is already wondering "did my tap register?" Falling back to URL bounce at that moment is the right escape.
- Avoids over-engineering Darwin ACKs that may not be observable under suspension anyway.

**Concrete shape:**
```swift
// In keyboard, after posting inAppDictationRequested:
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
    guard let self else { return }
    if !AppGroup.recordingActive {
        // No response — fall back to URL bounce as if from a cold path.
        self.openHostingAppURL("jot://dictate")
    }
}
```

---

### Q3. Cancel-replaces-Actions UX during in-place recording?

**Option a — Actions slot shows Cancel button (label "Cancel," X icon).**
- *Pros:* Reuses an existing button slot. Keyboard layout doesn't change. Cancel is clearly available.
- *Cons:* Actions button has its own meaning ("open the Actions popover"). Swapping its function is contextually surprising for the user who taps expecting Actions and gets Cancel.

**Option b — Hide Actions entirely during in-place recording; show no Cancel.**
- *Pros:* Cleaner — no contextual swap.
- *Cons:* No Cancel affordance. User has to swipe back / cancel via app — but app might be a Settings screen with no Cancel of its own. Bad UX.

**Option c — Add Cancel as a fourth action-row button just for in-place recording.**
- *Pros:* Explicit. No swap.
- *Cons:* Keyboard action row is already crowded (Minimize, Dictate, Actions). A fourth button requires layout work; the keyboard's height is fixed.

**Option d — Cancel inside the streaming strip (top strip, not action row).**
- *Pros:* The streaming strip already changes shape during recording. Adding a small X button at the strip's top-right is consistent and doesn't crowd the action row.
- *Cons:* Mixes "stop/cancel" controls — streaming strip is about visualizing audio, not controls. Slightly unusual.

**Recommendation:** **d.** Streaming strip gets a small X (cancel) button anchored top-right. Distinct from the Stop button in the action row. Doesn't crowd existing controls; doesn't repurpose an existing button.

**Visual:**
```
┌──────────────────────────────────────────────────┐
│ 🔴 0:08  ▂▃▆▅▃▂▁  Hello, this is dict...  [↓live] X│ ← streaming strip, X = cancel
├──────────────────────────────────────────────────┤
│ Punctuation row (hidden during recording)         │
├──────────────────────────────────────────────────┤
│ ⌂  ⏹ Stop (0:08)  ⚙  ⌫                            │ ← action row; Stop only
└──────────────────────────────────────────────────┘
```

X in the streaming strip = cancel. Stop in the action row = stop+save.

---

### Q4. Focus mirror — JSON blob or split keys?

**Option a — JSON-encoded `InAppDictationTarget` in a single AppGroup key.**
- *Pros:* Atomic write — either the whole blob is in place or nothing is. No mid-update race.
- *Cons:* JSON encode/decode on every read. Marginal CPU cost.

**Option b — Three separate keys: `fieldID`, `purpose`, `stampedAt`.**
- *Pros:* Slightly faster reads (no decode).
- *Cons:* Non-atomic write — keyboard could read a partial mid-update (new fieldID + old stampedAt). Especially bad during fast focus changes.

**Option c — JSON blob + a separate `stampedAt` key as a fast-path check.**
- *Pros:* Keyboard can check freshness without decoding the full blob.
- *Cons:* Two-write inconsistency window. Slightly more code.

**Recommendation:** **a (JSON blob).** The cost of JSON encode/decode is negligible (<1 ms per read on iPhone hardware), and atomicity guarantees are worth it. Pattern matches the existing `PendingRewriteRequest` shape in the codebase.

---

## D3 — Feature Catalog + Release Log

### Q1. Catalog "Show me" deep links — how aggressive to be?

**Option a — Deep link every item that's reachable in-app.**
- *Pros:* Maximum discoverability — every catalog item is a tap to its actual surface.
- *Cons:* Lots of new URL routes to implement (settings sub-sections, wizard steps, recording surfaces, etc.). Each route needs a navigation handler tolerant of mid-state.

**Option b — Deep link only "destination" surfaces (Settings sub-sections, Help anchors).**
- *Pros:* Bounded URL router work. Catalog entries for transient surfaces (Recording Hero, in-progress states) skip deep linking.
- *Cons:* The catalog is somewhat less interactive — some entries are info-only.

**Option c — No deep links in v1. Catalog is purely informational.**
- *Pros:* No URL router work needed beyond what already exists.
- *Cons:* Catalog feels static — "what's in Jot" with no "show me where" affordance. Less discoverable.

**Option d — Deep link only the top 10-15 most-frequently-asked-about features.**
- *Pros:* Pareto-optimal: most discovery value, least implementation cost.
- *Cons:* "Most asked" is hard to determine without telemetry. Some guessing.

**Recommendation:** **b (destination surfaces only).** Concretely:
- All Settings sub-sections (`jot://settings/<section>`).
- Wizard step replay (`jot://wizard?step=<N>`).
- Help anchors (`jot://help?id=<N.M>`).

Skip: Recording Hero entries, transient banners, in-progress states. These either fire in user-driven flows or are visible-by-doing.

---

### Q2. First-launch sheet length cap?

If a user skips three versions, the merged diff could be 20+ items.

**Option a — No cap; show everything.**
- *Pros:* Honest. User sees the full change log.
- *Cons:* Wall of text. User scrolls + dismisses without reading.

**Option b — Cap at ~10 items with a "View all" link to the always-readable Help section.**
- *Pros:* Sheet stays scannable. "View all" preserves the option to dig deeper.
- *Cons:* Pick-the-10 logic — by recency? By "headline"-flagged items? Arbitrary.

**Option c — Cap at ~5 items per version, ALL versions; cap total at ~15.**
- *Pros:* Per-version balance — recent change isn't drowned in older versions' changes.
- *Cons:* Arbitrary numbers.

**Option d — Show ONE version's worth (the most recent skipped) with explicit "you also skipped 2 prior versions" hint.**
- *Pros:* Minimal cognitive load. The latest is what they care about most.
- *Cons:* Hides intermediate versions; user has to actively dig.

**Recommendation:** **b (cap at 10 + View all link).** Sheet stays readable; the always-readable Help section is the escape valve.

**Sheet layout:**
```
What's new in 1.0.2
───────────────────────
• Logos in Donations    ← items, newest first
• Slack paste fix
• ... (up to 10)
───────────────────────
[View all changes →]    ← link to Help
[Got it]                ← dismiss
```

---

### Q3. Should the catalog be searchable?

**Option a — No search; rely on iOS Find-in-Page (long press on Help screen).**
- *Pros:* Zero new chrome. iOS native.
- *Cons:* Not discoverable. Most users don't know about Find-in-Page in SwiftUI.

**Option b — Inline search bar at top of catalog.**
- *Pros:* Discoverable.
- *Cons:* Settings screen already has a search; Help screen would gain one — pattern proliferation.

**Option c — Quick-filter chips by section (Home, Recording, Keyboard, AI, etc.).**
- *Pros:* No text input; lower friction. Good for "what does the keyboard do?" use case.
- *Cons:* Doesn't help "I'm looking for the feature where ____."

**Recommendation:** **a (no search) for v1.** The catalog has ~100 items; section grouping is enough navigation. If users complain about not finding things, add **c** in v1.1.

---

### Q4. feature-catalog.json curation cadence?

**Option a — Every PR that touches features.md updates feature-catalog.json.**
- *Pros:* Always in sync.
- *Cons:* Friction on every PR; CI check enforces but slows merges.

**Option b — Batch-update once per release.**
- *Pros:* Less PR friction.
- *Cons:* Catalog goes stale between releases; CI check would have to be turned off in main.

**Option c — feature-catalog.json updates are part of the same CI-required check; PRs that change features.md must include the catalog update.**
- *Pros:* Strict; never drifts.
- *Cons:* Same as a, framed differently.

**Option d — Auto-generate catalog from features.md via a deterministic algorithm + manually-editable override file for summaries.**
- *Pros:* Reduces curation cost — the structure (section IDs, titles) is auto-generated; only summaries need hand-curation.
- *Cons:* Build script complexity. Hybrid file is more complex.

**Recommendation:** **a + CI check that fails the PR.** Same effective cost as c. The catalog is a small file; updating it alongside features.md is a 1-minute task. Strict-by-default avoids drift.

---

## D4 — Donation Milestone Card

### Q1. Milestone list — 2h / 10h / 25h, or different?

The plan recommends `[2h, 10h, 25h]`. Alternatives:

**Option a — `[2h, 10h, 25h]` (recommended).**
- *Pros:* Respects existing 2h tuning decision; 10h matches "engaged" threshold; 25h is "deeply engaged."
- *Cons:* 25h is high — many casual users will never hit it.

**Option b — `[2h, 5h, 10h]` (closer spacing).**
- *Pros:* More frequent re-prompts; doesn't strand engaged-but-not-power users.
- *Cons:* 5h → 10h is a 2x jump, which feels arbitrary. The existing code's comment explicitly rejected high thresholds as too aspirational; doubling 5h to 10h reintroduces the same concern.

**Option c — `[2h]` (no re-prompts).**
- *Pros:* Maximally conservative. Single ask, no follow-up.
- *Cons:* Defeats the plan's purpose. No new value beyond existing.

**Option d — `[2h, 8h, 20h, 50h]` (logarithmic spacing).**
- *Pros:* Spacing reflects the value curve — each milestone represents a meaningful new commitment level.
- *Cons:* 50h is extreme; very few users hit it. Could be motivating ("look how far you've come") or discouraging ("I have to do *more*").

**Option e — `[2h, 10h, 25h]` AND introduce a "engaged-user-only" subset of milestones based on whether the user has at least started using AI Rewrite or vocab boost.**
- *Pros:* The "10h" prompt is more likely to convert if the user has already shown engagement signals.
- *Cons:* Conditional logic on multiple state variables; harder to reason about.

**Recommendation:** **a (2h, 10h, 25h)** as the v1 list. Reasoning:
- 2h is the proven threshold.
- 10h is the natural "casual majority who came back" milestone.
- 25h is "this app is part of my workflow."
- Three milestones is enough for the plan's "multi-stage" goal without nag-ifying.

If telemetry post-launch shows 10h → 25h is too sparse, add an 18h intermediate.

---

### Q2. 90-day cooldown — too long, too short, just right?

**Option a — 90 days (recommended).**
- *Pros:* Long enough that re-prompts feel rare. Quarterly cadence aligns with how people think about subscriptions/donations.
- *Cons:* User who dismissed at 2h on day 1 and hits 10h on day 30 has to wait 60 more days to see the next prompt, even though their engagement just doubled.

**Option b — 30 days.**
- *Pros:* Faster cycle; matches "monthly check-in" mental model.
- *Cons:* Risk of feeling nag-y. The existing code explicitly avoids this.

**Option c — 60 days.**
- *Pros:* Compromise.
- *Cons:* No strong reason to pick 60 over 90.

**Option d — No fixed cooldown; gate purely on "new higher milestone reached."**
- *Pros:* Simplest. If the user dismisses at 2h and hits 10h, show 10h prompt immediately.
- *Cons:* User who dismisses at 2h and quickly hits 10h (heavy first week) gets two prompts within a week — feels naggy.

**Option e — 90 days minimum + double the cooldown each subsequent dismiss (90 → 180 → 360).**
- *Pros:* Escalating respect for the dismiss signal. Power users who keep dismissing get less-and-less-frequent prompts.
- *Cons:* Persistence shape gets complex.

**Recommendation:** **a (90 days).** Aligns with quarterly cadence; matches the existing code's "be friendly, don't nag" philosophy. If post-launch metrics suggest re-engagement is high after dismiss, consider **e**.

---

### Q3. Upgrade migration: option (a) "fresh dismiss" or option (b) "ancient dismiss"?

When existing users (who dismissed the single-shot 2h card) upgrade to the multi-milestone build:

**Option a — "Fresh dismiss" — stamp `dismissedAt[2h] = upgrade timestamp`.**
- *Pros:* No surprises. User won't see a re-prompt for 90 days after upgrade.
- *Cons:* Slightly extends the wait for engaged users.

**Option b — "Ancient dismiss" — stamp `dismissedAt[2h] = Date(timeIntervalSince1970: 0)`.**
- *Pros:* Engaged users see the 10h re-prompt as soon as they cross 10h, no extra wait.
- *Cons:* User who dismissed *yesterday* sees a new prompt the day after upgrade — feels naggy and inconsistent.

**Option c — Detect actual dismiss time if available (we may have logged it somewhere).**
- *Pros:* Honest.
- *Cons:* We probably didn't log dismiss timestamps in the single-shot version. Would require digging through any old logs or accepting that we just don't know.

**Recommendation:** **a (fresh dismiss).** Safer; user-friendly; the "extra 90 days" wait is minor and predictable.

---

### Q4. Re-prompt copy — same as 2h ask, or different?

**Option a — Same copy regardless of milestone.**
- *Pros:* Simplest. Less copy to maintain.
- *Cons:* Re-prompts feel mechanical — "Jot has saved you 10 hours, want to give back?" reads identical in structure to the 2h ask.

**Option b — Per-milestone copy emphasis.**
- *Pros:* Each ask has its own framing. 10h: "Jot is part of your routine now." 25h: "You've made Jot a core tool." More personal.
- *Cons:* Risk of feeling presumptuous — "core tool" when user just hit 25h once but doesn't actually use it that often.

**Option c — Milestone in the headline, generic ask in the sub-line.**
- *Pros:* The plan's current proposal: *"Jot has saved you about 10 hours."* + *"Want to give back? See where Jot raises money →"*. Honest, minimal personalization.
- *Cons:* Bland-by-design.

**Option d — Time-since-dismiss copy ("It's been a while...").**
- *Pros:* Personal touch.
- *Cons:* Creepy — feels like the app is tracking the user. The existing code's "be friendly" tone is harder to maintain with time-aware messaging.

**Recommendation:** **c (milestone in headline, generic ask).** The plan's current proposal. Honest, scannable, low risk of misfire.

---

## B1 — Cold-Start Dictation Race

### Q1. Has the user reproduced this since the diagnostic build?

**Awaiting user data.** Cannot explore further without confirmation that the §14.1 symptom is still reproducible on the latest build. If it's no longer reproducing, the bug may have been fixed by an unrelated change.

If reproducing: prioritize the diagnostic instrumentation patch (Step 1) immediately.

If NOT reproducing: deprioritize and watch for recurrence. The one-line `warmUp()` fix is still worth shipping as a defensive measure since the code reads as if the race exists even if it's not currently triggering on the user's device.

---

### Q2. Does the same bug appear in the warm-hold path?

§14.1 says "Cold-start only." But if warm-hold path also shows the symptom occasionally, the `warmUp()` fix won't help — warm-hold doesn't go through `triggerAutoStart`.

**Awaiting user confirmation.** Two paths:
- If warm-hold is unaffected → fix is the `warmUp()` defer kick. Done.
- If warm-hold ALSO shows the bug occasionally → bug is broader; need to instrument the warm-resume Darwin notification path (`warmResumeRequested`) and the direct `RecordingService.shared.start()` call from `JotApp.swift:64`.

The plan's diagnostic patch should add instrumentation to BOTH paths so the user's next repro is informative regardless of which path they hit.

---

### Q3. Action Button result?

**Awaiting user test.** This is THE most important diagnostic step. The Action Button shortcut goes through `DictationControllerImpl` (a separate code path) and reaches `RecordingService.shared.start()` directly, bypassing `triggerAutoStart`.

**If Action Button works:**
- The bug is in the URL-bounce → `triggerAutoStart` chain.
- Primary fix is the deferred `warmUp()` kick.

**If Action Button ALSO fails:**
- The bug is in `RecordingService.start()` itself.
- The fix is deeper — likely in `AVAudioSession` activation, audio engine setup, or interruption handler installation.
- The `warmUp()` fix won't help; need to debug the engine bring-up.

This test costs the user ~30 seconds and halves the search space. Schedule it.

---

## B2 — Keyboard Auto-Switch

### Q1. Which host app does the user report this in?

**Awaiting user data.** If host-specific:
- **Slack (or other custom-compose hosts):** suggests Hypothesis B (main-app jetsam reacting to a host-side focus perturbation). Host has unusual focus behavior that triggers something on Jot's side.
- **iOS Notes / Mail / Safari (system hosts):** suggests Hypothesis A (keyboard kill). System hosts have standard input behavior; the bug isn't host-specific.

If host-agnostic (happens across all apps): leans toward Hypothesis A.

---

### Q2. iOS-version specific?

**Awaiting user data.** If only iOS 26.x:
- May correlate with iOS-26 changes to memory pressure handling or keyboard extension scheduling.
- Apple's release notes would be worth checking for any documented behavior changes.

If iOS 25 also: the bug predates iOS 26 → general memory pressure issue.

---

### Q3. Confirm hypothesis after first capture.

**Process commitment, not a decision question.** When the next failure capture lands with the new instrumentation, the team commits to:
1. Reading the logs through to a definitive A/B conclusion (or "neither — something else").
2. NOT shipping Path A + B blindly before confirmation.
3. Documenting the conclusion in this plan + features.md.

---

### Q4. Resurrection UX — Dictate-button overlay, or something subtler?

**Option a — Dictate-button overlay (checkmark glyph for ~3 s).**
- *Pros:* Visible without intruding. Works in both standard and collapsed keyboard states (escapes the §5.10 banner bug).
- *Cons:* Brief — user might still miss it if they look down for half a second.

**Option b — Persistent dot on the Dictate button until next interaction.**
- *Pros:* Survives long looks-away. User definitely notices on next tap.
- *Cons:* Adds "unread" state to a control that's otherwise stateless.

**Option c — Recents strip row "just-paste" highlight (using existing `stampJustNowMarker` infra).**
- *Pros:* Reuses existing visual language.
- *Cons:* Recents strip is hidden in collapsed state — same as the banner problem. Doesn't work universally.

**Option d — Subtle haptic on next keyboard appear post-paste.**
- *Pros:* Survives both keyboard states. Non-visual; doesn't compete with other UI.
- *Cons:* User may not connect the haptic to the paste. Easy to misinterpret as "iOS did a thing."

**Option e — Combined: button overlay (~3 s) + haptic.**
- *Pros:* Multi-modal — visual for sighted users, haptic for visually-occupied users.
- *Cons:* Slightly more complex; more state to manage.

**Recommendation:** **a (button overlay).** Reasoning:
- Works in both keyboard states.
- 3-second visibility is enough for users who happen to be looking.
- Users who miss it still find the text in the host field — the resurrection banner is confirmation, not delivery.
- Haptic addition can be a v1.1 enhancement if real user reports suggest the overlay alone is missed.

---

## B3 — Slack Silent Paste

### Q1. Banner duration — 4 s right?

**Option a — 2.5 s (matches existing keyboard banner cadence per §5.10).**
- *Pros:* Consistent with other keyboard banners.
- *Cons:* Failure cases warrant a longer read — user needs to understand "saved to clipboard" and act on it.

**Option b — 4 s (recommended in plan).**
- *Pros:* Enough to read + decide.
- *Cons:* Longer than the existing pattern; inconsistent.

**Option c — 6 s.**
- *Pros:* More forgiving for slow readers.
- *Cons:* Blocks subsequent banners for too long.

**Option d — Persistent until user dismisses or starts a new dictation.**
- *Pros:* Guaranteed visibility.
- *Cons:* Persistent banner state to manage.

**Recommendation:** **b (4 s).** Reasoning: failure cases warrant slightly longer than success cases. The existing 2.5 s is for "transcription complete" — quick informational. "Paste failed" requires the user to remember to act on the clipboard fallback.

---

### Q2. Clipboard expiration — 1 hour right?

**Option a — No expiration (matches default).**
- *Pros:* Simplest.
- *Cons:* Dictation text remains readable by other apps until next clipboard write. iOS 16+ "Pasted from Jot" pill fires for that text even days later.

**Option b — 5 minutes.**
- *Pros:* Minimal leak window. User has just enough time to manually paste.
- *Cons:* If user gets distracted and returns 10 minutes later, the clipboard is empty — bad UX. They'd have to re-dictate.

**Option c — 1 hour (recommended).**
- *Pros:* Balance — long enough for distracted users, short enough to bound leak risk.
- *Cons:* Arbitrary.

**Option d — Until next clipboard write.**
- *Pros:* Implicit cleanup.
- *Cons:* Requires hooking pasteboard change notifications. Adds complexity. iOS may already do this somehow.

**Option e — 24 hours.**
- *Pros:* User comes back the next day, can still paste.
- *Cons:* Longer leak window.

**Recommendation:** **c (1 hour).** 1 hour is the sweet spot — long enough that "got distracted" users don't lose work, short enough to limit cross-app exposure. iOS's `UIPasteboard.setItems(_:options:)` supports `.expirationDate` natively.

---

### Q3. Should `pasteSkipProxyDisconnected` banner have a "Try again" button?

**Option a — Banner with just the message + tap-to-open-in-Jot affordance.**
- *Pros:* Minimal chrome. Clipboard fallback is enough.
- *Cons:* User has to manually paste from clipboard — extra step.

**Option b — Banner with a "Retry" button.**
- *Pros:* One-tap recovery if the proxy is now connected.
- *Cons:* "Retry" semantics — does it re-insert from clipboard? Re-run the original session? Where does the keyboard insert? Complex.

**Option c — Banner with a "Try again" button that re-attempts insert at current cursor.**
- *Pros:* Clear semantic — insert here, now.
- *Cons:* Needs to coordinate with the keyboard's current focus state, which may have changed.

**Option d — Banner only; banner is itself tappable to invoke retry.**
- *Pros:* Smaller surface than an embedded button. Tap-on-banner = retry.
- *Cons:* Discoverability — users may not realize the whole banner is tappable.

**Recommendation:** **a (no retry button).** Reasoning:
- The fix at this layer is best-effort. If proxy was disconnected, retry might also fail.
- Clipboard fallback is reliable; user pastes manually.
- Banner clutter is bad in a constrained surface like the keyboard.

If post-launch metrics show high silent-paste rate AND users complain about manual-paste friction: add **c (smart retry)** in v1.1.

---

## B4 — User-Prompt No Preview

### Q1. Snapshot match — strict equality or fuzzy (trim whitespace, etc.)?

**Option a — Strict equality on the system prompt string.**
- *Pros:* Predictable. No edge cases.
- *Cons:* User edits a single space → snapshot mismatches → sample dropped. Surprising.

**Option b — Trim whitespace before comparing.**
- *Pros:* Slightly more forgiving — leading/trailing whitespace doesn't invalidate.
- *Cons:* Still strict on internal changes. Doesn't help most edit cases.

**Option c — Trim + collapse whitespace (multiple spaces → one).**
- *Pros:* Forgiving against most "I just retyped a word" edits.
- *Cons:* Diverges from "what the model actually saw" — if the user added a meaningful double-space (markdown line break?), we'd consider the snapshot still valid even though the rewrite output may differ.

**Option d — Diff-based fuzzy match (Levenshtein < N chars).**
- *Pros:* Very forgiving.
- *Cons:* Overkill. Hard to pick N.

**Option e — Always invalidate on Save (snapshot match is sufficient for visual consistency, no fuzzy).**
- *Pros:* Simpler — no equality check at all. On Save, the sample is either set (if a fresh Try-This ran) or unchanged.
- *Cons:* Misses the case where user runs Try-This, edits without re-running, saves → stale sample persists despite edit.

**Recommendation:** **a (strict equality).** Reasoning:
- Predictable behavior > forgiving behavior in this context.
- A dropped sample is recoverable (re-run Try-This); a stale sample is silently misleading.
- The Save → snapshot mismatch path is rare (user runs, edits, saves anyway) — when it happens, dropping is the safer behavior.

---

### Q2. Context-menu "Clear sample" affordance — yes or no?

**Option a — Yes, add the context menu.**
- *Pros:* User can purge a regrettable sample without opening the editor + running Try-This with a different recording.
- *Cons:* Chrome on every prompt row. Discoverability question: do users find the context menu?

**Option b — No; user must re-run Try-This to overwrite.**
- *Pros:* No new chrome.
- *Cons:* "I want to clear this sample" is a real use case; no path to do it cleanly.

**Option c — Yes, but only via Settings → AI → some "manage samples" sub-screen.**
- *Pros:* Hidden, doesn't crowd the main UI.
- *Cons:* Adds a new screen. Probably not worth.

**Option d — Yes, accessible via long-press on the sample's before/after text.**
- *Pros:* Local affordance.
- *Cons:* Long-press on text in iOS conflicts with text-selection. Bad UX.

**Recommendation:** **a (yes, context menu on prompt row).** Reasoning:
- Cheap to add (`.contextMenu { ... }` on the row).
- Users who care will discover it.
- Provides an escape hatch for the "regrettable sample" case.

---

### Q3. Re-generate button on the prompt row?

**Option a — Yes, small re-run button on the row.**
- *Pros:* One-tap regeneration without opening the editor.
- *Cons:* "Regenerate" requires picking a recording — the row isn't the right surface for that decision. Either we pick the user's most-recent recording (potentially wrong fit) or we present a picker (more chrome).

**Option b — No; user opens editor → runs Try-This → saves.**
- *Pros:* The full editor surface is where regeneration belongs (model picker, recording picker, etc.).
- *Cons:* More taps.

**Option c — Yes, but only auto-regenerates with the most-recent recording (no picker).**
- *Pros:* One tap, predictable.
- *Cons:* If "most recent" isn't representative of the prompt's intent (e.g. prompt is "Email" and most recent dictation is a shopping list), the sample is bad.

**Recommendation:** **b (no row-level regenerate).** Reasoning:
- Regeneration requires a recording choice; the row doesn't have space for that.
- Tapping the row to open the editor is the right gesture for the small minority of users who want to regenerate.

---

## Decision Summary (TL;DR)

If you want to skim:

| Plan | Top decision | Recommendation |
|---|---|---|
| A1 Q1 | Wand popover contents | **b** — built-ins + LIFO user prompts (cap 5) |
| A1 Q2 | Banner persistence | **a** — auto-dismiss 4s, re-fire on next viewDidAppear if unviewed |
| A1 Q3 | §7.3 caveat removal | **b** — keep until Phase 1 ships, remove with the wand UI |
| A2 Q1 | Build vs. delete | **a** — delete (path A) — until user demand |
| A2 Q4 | If A: §7.11 fate | **c** — move historical note to deferred-engineering.md |
| D1 Q1 | Detached pattern shape | **c** — add `needsToRun: Bool` to protocol |
| D1 Q2 | Circuit-break UI | **a** — diagnostics only v1; localize to feature if needed later |
| D1 Q3 | device_install_id stamp | **a** — bootstrap migration v0 |
| D2 Q1 | Selection on dictate | **a** — replace selection |
| D2 Q2 | ACK design | **d** — optimistic + recording-active probe (1s timeout) |
| D2 Q3 | Cancel placement | **d** — X in streaming strip top-right |
| D2 Q4 | Focus mirror shape | **a** — JSON blob in single key |
| D3 Q1 | Deep links scope | **b** — destinations only (Settings sub-sections, Help anchors, wizard steps) |
| D3 Q2 | Sheet length cap | **b** — cap 10 + "View all" link |
| D3 Q3 | Catalog searchable | **a** — no search v1 |
| D3 Q4 | JSON curation | **a** — every PR; CI check enforces |
| D4 Q1 | Milestone list | **a** — 2h / 10h / 25h |
| D4 Q2 | Cooldown | **a** — 90 days |
| D4 Q3 | Upgrade migration | **a** — "fresh dismiss" |
| D4 Q4 | Re-prompt copy | **c** — milestone in headline, generic ask |
| B1 Q1-3 | All | **Awaiting user data** — see plan |
| B2 Q1-3 | All | **Awaiting user data** — see plan |
| B2 Q4 | Resurrection UX | **a** — Dictate-button overlay 3s |
| B3 Q1 | Banner duration | **b** — 4s |
| B3 Q2 | Clipboard expiration | **c** — 1 hour |
| B3 Q3 | Retry button | **a** — no retry; clipboard fallback only |
| B4 Q1 | Snapshot match | **a** — strict equality |
| B4 Q2 | Clear-sample affordance | **a** — yes, context menu |
| B4 Q3 | Row-level regenerate | **b** — no; editor is the right surface |

---

## How to use this doc

1. Read in any order — sections are independent.
2. When you make a decision, the corresponding plan doc's "Open Questions" section can be marked "resolved per [open-questions-deep-dive.md#qX](#)."
3. Open questions left unanswered should stay surfaced — they're real decisions, not noise.
