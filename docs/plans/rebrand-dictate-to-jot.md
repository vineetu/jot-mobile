# Plan: rebrand the "Dictate" action to "Jot" (+ coral copy cleanup)

Status: **IMPLEMENTED (2026-06-04, uncommitted).** Owner decisions locked:
**Narrow** scope · label **"Jot down"** · **Watch included** · **Siri renamed**.
Build green (iOS + keyboard + Watch + intents). Part B (coral→blue) folded in.
Part C (date cap) already shipped earlier this session (builds 100/101). See the
"Decisions & as-built" section at the bottom. Original plan preserved below.

Three things the owner asked for, tracked together but **independent**:
- **A.** Rebrand the user-facing **"Dictate"** action/button to **"Jot"** (use the
  brand name as the verb). Copy-only; not a code refactor.
- **B.** Remove the stale **"coral"** wording in Help (the element is blue now).
- **C.** Fix the date-retrieval **"last 15" cap** ("last two weeks" → only 15
  notes) — see the companion research doc; summarized here as the "alongside" item.

---

## Adversarial review — incorporated (2026-06-03)

An independent reviewer read the code and corrected the plan. Key changes folded
in below:

1. **[HIGH] Apple Watch was missing from scope.** The Watch has the same
   "Dictate" button + empty-states (`Jot/Watch/Views/RootView.swift:316,336,239`,
   `RecentTranscriptsView.swift:80`, features.md §2.13). Added to A.2 as an
   explicit decision (rebrand or defer).
2. **[HIGH] Don't rename the features.md headings.** Renaming §1.6 "Floating
   Dictate Button" / §5.4 "Dictate / Stop Control" breaks inbound anchors at
   features.md lines 28/184/200/220/233 **and** `known-bugs-and-plans.md:105`.
   Keep headings as stable doc anchors; change only **inline UI-label** mentions.
   Grep BOTH anchors across all `.md` (not just features.md) before any heading edit.
3. **[HIGH] Grammar: use the noun-phrase "the Jot button", never bare "Tap Jot".**
   Bare "Jot" collides with the app name. The A.2 wordings are corrected below.
4. **[HIGH] Keep accessibility labels as "Dictate".** On-screen label ≠ a11y
   label. VoiceOver "Jot, button" is worse/ambiguous than "Dictate, button".
   (The first draft contradicted itself; resolved in favor of functional a11y.)
5. **[CLOSED] Coral in features.md = change NOTHING.** All three "coral `sparkles`"
   mentions are still genuinely coral in code (`AliveRow.swift:77`,
   `RecentsStrip.swift:264`, `EditPromptWithTestSheet.swift:776` /
   `AIRewriteSettingsView.swift:915` all `jotCoralTop`). Only `HelpView.swift:192`
   is stale. (B narrowed accordingly.)
6. **[HIGH] C is NOT copy-only.** Uncapping `fetchLimit` just re-caps at the 12k
   `buildUserTurn` trimmer — which for the date path (`.reversed()` → oldest-first
   + `removeLast()`) drops the **newest** in-window notes, and its comment is
   wrong for this path. C now lists the trimmer-ordering fix + "N of M" as
   prerequisites, not options.

**Reviewer verdict:** structurally sound and scope-disciplined, but must (a) add
or defer Watch, (b) use noun-phrase wordings + keep a11y as "Dictate", (c) not
rename doc headings, (d) treat C as a real retrieval fix, not a one-liner.

---

## A. Dictate → Jot rebrand

### A.0 The core decision (NEEDS OWNER INPUT before implementing)

Two scopes, very different blast radius:

- **Narrow (recommended to start):** rename only the **action label** — the
  tappable "Dictate" button/affordance — to "Jot". Keep the descriptive feature
  word "dictation/dictate" where it explains the *speech* mechanic ("your
  dictations", "start dictating"). Lower risk, preserves meaning.
- **Broad:** rename **every** user-facing "dictate/dictation" → "jot/jotting".
  More on-brand but introduces grammar strain ("your dictations" → "your jots"?,
  "start dictating" → "start jotting"?) and can lose the "you speak" signal that
  onboarding relies on.

**Recommendation:** do the **Narrow** rename first (the buttons, which is what was
asked — "rename the buttons"), and treat the broad noun-rebrand as a separate
follow-up after seeing the buttons in context.

### A.1 Grammar / readability watch-outs (for the reviewer)

"Jot" is both the **app name** and a **noun**, so "Jot" as a bare verb can be
ambiguous:
- ✅ Good: a labelled **button** reading "Jot" (icon + word), prose "tap the **Jot**
  button".
- ⚠️ Risky: bare "Tap Jot" (reads as "tap [the app] Jot"), "Tap to Jot"
  (capitalised verb mid-sentence), accessibility "Tap to dictate" → "Tap to Jot".
- ❌ Absurd if mechanical: Siri/Shortcut title "**Dictate** with Jot" → "Jot with
  Jot"; "Start Jot **Dictation**" → "Start Jot Jot".

Rule of thumb for the rename: **noun-phrase "the Jot button"** in prose; **bare
"Jot"** only as an actual on-screen button label next to an icon; keep
accessibility hints functional and unambiguous.

### A.2 RENAME — user-facing action labels (Narrow scope)

**Visible label = "Jot"; in prose use "the Jot button"; keep a11y = "Dictate".**

| File:line | Current | Proposed | Note |
|---|---|---|---|
| `Design/Components/DictateFAB.swift:43` | `Text("Dictate")` | visible label `"Jot"` | Home FAB. **a11y (:80) stays `"Dictate"`** (VoiceOver "Jot, button" is ambiguous). |
| `Keyboard/KeyboardView.swift:699` | `"Dictate"` (Full-Access state) | `"Jot"` | Keyboard key (visible). a11y (:1057 `"Tap to dictate"`, :1064) **stays functional**. |
| `Recents/RecentsListCard.swift:199` | `"Tap Dictate to record your first note."` | `"Tap the Jot button to record your first note."` | noun-phrase (avoid bare "Tap Jot") |
| `SetupWizard/Steps/HowItWorksStep.swift:36` | `"Tap Dictate on your keyboard"` | `"Tap the Jot button on your keyboard"` | a11y :244 **stays "tap Dictate"** (already says "Jot records" → tautology) |
| `SetupWizard/Steps/WarmHoldStep.swift:52` | `"…until you tap Dictate."` | `"…until you tap the Jot button."` | |
| `Help/HelpView.swift:192-194` | `"Tap the coral "` + bold `"Dictate"` + `" button…"` | `"Tap the blue "` + bold `"Jot"` + `" button…"` | **both edits in one bullet; also fixes B** |
| `Help/HelpView.swift:204-206` | `"…tap Dictate on the Jot keyboard."` | `"…tap the Jot button on the Jot keyboard."` | avoids "Jot on the Jot" tautology |
| **Apple Watch (DECIDE: rebrand or defer)** | `Watch/Views/RootView.swift:316` `Text("Dictate")`, `:336` a11y, `:239` + `RecentTranscriptsView.swift:80` `"Tap Dictate to record one."` (features.md §2.13) | `"Jot"` / `"Tap the Jot button to record one."` | Same button on watchOS; in-scope for "rename the buttons" unless explicitly deferred. |

### A.3 features.md (user-facing doc — must stay in sync, bidirectional links)

- **Do NOT rename the headings** §1.6 "Floating Dictate Button" or §5.4 "Dictate /
  Stop Control". They are stable doc anchors; renaming breaks inbound links at
  features.md **28 (TOC), 184, 200, 220, 233** AND `known-bugs-and-plans.md:105`.
  Before touching ANY heading, grep both `#1-6-floating-dictate-button` and
  `#5-4-dictate--stop-control` across **all** `.md` files (not just features.md).
  Headings are doc structure, not UI copy — leaving them stable sidesteps the
  whole anchor-breakage class.
- Change only **inline UI-label** mentions: "tap Dictate", "the Dictate button is
  replaced…" (§5.5, **§5.11 line 361**), "Dictate key", the
  "TAP DICTATE → SWIPE BACK → …" caption (§9.x). The post-stop **"Working"** label
  (§5 line 341) is unaffected (not "Dictate").
- Keep "dictation"/"recording" as the feature noun under Narrow scope.

### A.4 LEAVE — do NOT rename (code, logs, Siri, internals)

- **Code symbols / filenames**: `DictateFAB`, `DictateIntent`,
  `RecordAndTranscribeIntent`, `DictationPipeline`, `DictationStats`, AppGroup
  keys (`jot.stats.dictationCount`), enum cases, `os.log` strings, `RECORDING
  START FROM:` lines. Zero user-facing value, high churn/risk.
- **Siri / Shortcuts intent titles & phrases** — `DictateIntent.title "Dictate
  with Jot"`, `RecordAndTranscribeIntent "Start Jot Dictation"`,
  `JotAppShortcuts "Start Dictation"`, `categoryName: "Dictation"`. **Renaming
  these can break users' existing shortcuts and Siri phrases.** Treat as a
  separate, explicit decision; default = leave.
- **Prompt text sent to the model** (`SavedPrompt` "Rewrite this dictation…") —
  not shown to the user; leave.

### A.5 Risks
- features.md anchor breakage if a heading is renamed without fixing inbound links.
- "Jot/Jot" tautology in any string that already contains "Jot".
- Accessibility strings going ambiguous.
- Shortcuts/Siri breakage if A.4 intents are touched.

### A.6 Open questions for the owner
1. **Scope**: Narrow (buttons only) or Broad (all "dictate/dictation" copy)?
2. **Verb form** on the button: `Jot` vs `Jot it` vs `Jot down`?
3. **Siri/Shortcuts** intent titles — rename (breaking) or leave?
4. Keep the word **"dictation"** in explanatory onboarding so users still grasp
   that they *speak*?

---

## B. Coral copy cleanup (independent)

The app is **not** fully coral-free — coral is still used deliberately in the
AI/prompt-editing surfaces (`jotCoralTop/Bottom`, `CoralActionButton`,
`CompactCoralPill`, the prompt-editor caret). So this is **not** a blanket coral
purge — only the spots where the copy says "coral" but the element is actually
**blue**:

- **`Help/HelpView.swift:192` — CONFIRMED stale.** Says "Tap the **coral**
  Dictate button"; the home FAB (`DictateFAB.swift`) is a `jotBlueTop→Bottom`
  gradient = **blue**. Fix "coral" → "blue" (folds into A.2).
- **features.md "coral `sparkles` glyph" — VERIFIED, change NOTHING.** All three
  are genuinely still coral in code: §1.2 home library → `AliveRow.swift:77`
  `jotCoralTop`; §5.2 keyboard recents → `RecentsStrip.swift:264` `jotCoralTop`;
  §7 prompt picker "coral checkmark" → `EditPromptWithTestSheet.swift:776` /
  `AIRewriteSettingsView.swift:915` `jotCoralTop`. (Do NOT confuse with the BLUE
  checkmark at `RecentsListCard.swift:332`, which is the swipe-to-**Select**
  action, not the prompt picker.) **So B = exactly one edit: `HelpView.swift:192`.**

---

## C. Date retrieval — the "last 15" problem ("last two weeks" → 15 notes)

Confirmed: `AskController.retrieveByDate` sets `descriptor.fetchLimit = k` where
`k = retrievalK = 15` (`AskController.swift:637`). So **any** date window only
returns the **15 most-recent** in-window notes — "last two weeks" with 30+ notes
silently drops the older two-thirds, with no "N of M" signal.

**This is NOT a copy-only quick win.** Uncapping `fetchLimit` alone just moves
the cap to the `buildUserTurn` 12k-char trimmer (`userTurnCharLimit`, snippet cap
500/note → ~24 full notes max). Worse, on the date path `retrieveByDate` returns
`.reversed()` = **oldest-first** (`AskController.swift:640`), so the trimmer's
`transcriptBlocks.removeLast()` drops the **NEWEST** in-window notes — and its
comment ("drop the lowest-similarity transcripts at the end", ~line 667) is
**wrong for this path** (there's no similarity order, it's chronological). So
uncapping trades "drop oldest 15+" for "drop newest past ~12k chars," still silent.

The companion research doc **[ask-retrieval-source-limit-and-date-scope.md](ask-retrieval-source-limit-and-date-scope.md)**
covers the budget math and the empirical finding that Apple FM is **unreliable**
at resolving dates (keep the deterministic parser). The actionable "better way",
with the **prerequisites first**:
1. **Fix the trimmer ordering for the date path** — drop the *least relevant*
   (or oldest) deliberately, not "whatever `removeLast` happens to hit", and fix
   the misleading comment. *(prerequisite)*
2. **Surface "N of M notes in this window"** whenever anything is dropped, so the
   omission is never silent. *(prerequisite)*
3. **Map-reduce summarize** large windows (summarize each note/cluster, then
   synthesize) so the count isn't bounded by the context window.
4. Then **raise / remove the date-scope cap** on top of 1–3.
5. Add **topic-within-window** ranking (the `ask-time-retrieval.md` `RetrievalPlan`).
6. **Expand the deterministic date grammar** in Swift (ranges, weekdays,
   "N weeks/months ago") — reliable, instant, free; NOT via the LLM.

Tracked as its own item; sizing **M** (it's a real retrieval change, not a flag flip).

---

## Implementation order (next session)
1. B (coral copy) — trivial, unblocks the Help sentence.
2. A Narrow rename (buttons + features.md sync) — after the owner answers A.6.
3. C (date cap) — independent, can run in parallel.

---

## Decisions & as-built (2026-06-04)

**A.6 answered:** (1) Scope = **Narrow** (buttons only; descriptive "dictate/
dictation" verb kept). (2) Label = **"Jot down"**. (3) Watch = **included now**.
(4) Siri/Shortcuts = **renamed** (visible titles + spoken phrase).

**A11y change from plan:** the plan said keep a11y as "Dictate" because bare "Jot,
button" is ambiguous. "Jot down" is NOT ambiguous, so a11y labels were set to
**"Jot down"** too (satisfies WCAG label-in-name; avoids sighted-vs-VoiceOver
mismatch). Applies to FAB, keyboard mic, Watch button, wizard animation.

**Files changed (visible label → "Jot down"):**
- `Design/Components/DictateFAB.swift` — Text + a11y label.
- `Keyboard/KeyboardView.swift` — key label (Full-Access) + a11y (`micAccessibilityLabel`).
- `Recents/RecentsListCard.swift` — empty-state copy.
- `SetupWizard/Steps/HowItWorksStep.swift` — step copy + animation a11y.
- `SetupWizard/Steps/WarmHoldStep.swift`, `TryKeyboardStep.swift` — body copy.
- `Help/HelpView.swift` — "What it's for" + 2 getting-started bullets; **coral→blue** (Part B done here).
- `Watch/Views/RootView.swift` — button label + a11y + empty state.
- `Watch/Views/RecentTranscriptsView.swift` — empty state.

**Siri / Shortcuts (renamed):**
- `RecordAndTranscribeIntent.title` + `Summary` → **"Jot down a note"**.
- `DictateIntent.title` → **"Jot down a note"**.
- `JotAppShortcuts` spoken phrase → **"New \(.applicationName) note"** (must keep
  the app-name placeholder); `shortTitle` → **"Jot down"**.
- LEFT: `categoryName: "Dictation"` (×3, internal grouping);
  `TranscribeAudioFileIntent` title (transcribes a file, not the Dictate action).

**features.md:** 4 inline mentions updated (§5.5 "Working" button, §5.11 list label,
§2.x "Dictate key", §9.2 getting-started). Headings §1.6 / §5.4 LEFT as anchors.

**Deliberately kept as "dictate/dictation" (Narrow scope):** code symbols, file
names, logs, `RECORDING START FROM:`, and the descriptive verb in prose incl.
`EditPromptWithTestSheet` "Dictate something to test the prompt".

**Not done (out of the requested scope):** Broad noun rebrand ("your dictations"
→ "your jots"); optional date-cap polish items C.2 ("N of M notes" signal) and
C.1 trimmer-order comment fix (the retrieval architecture itself shipped 100/101).
