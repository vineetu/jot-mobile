# Unify keyboard dictation — one stop path everywhere (no custom inline engine)

> Status: **design / requirements captured, not yet implemented.**
> Consolidates and retires two earlier plans (deleted 2026-06-02):
> `in-app-dictation-no-save.md` (kept the inline path + a transient hero intent) and
> `in-app-tap-to-record.md` (the "don't push the hero inside Jot" precursor — its
> locked cross-boundary table is folded into §3a below). This plan deletes the custom
> inline path instead. Ask is explicitly out of scope and stays as-is.

## 1. The rule (in the user's words)

> "When someone starts recording from anywhere, no one cares. You stop wherever
> you are and it pastes there. If you stop inside the app — feedback, transcription
> edit, wizard, settings — it pastes there but does **not** save a transcript. If you
> stop in another app it pastes there and saves. It should all be the same — Jot's
> own fields just act like the keyboard in any other app. Only Ask is unique."

Three obligations on **every** stop, no matter where dictation started:

1. **End the transcription** — flip the app's recording *state* to not-recording, so
   the home screen stops showing "recording" and the keyboard's Dictate button is
   armed to start a **fresh** recording.
2. **Paste** the text into whatever field is focused (the standard keyboard insert).
3. **Save a transcript only if you are NOT inside a Jot field** (i.e. you're in
   another app). Inside Jot → paste, no save.

## 2. The distinction that matters most: *end the transcription* ≠ *release the mic*

These are two **independent axes**. The previous design conflated them; this design
must not.

| Axis | What it means | What we do on an in-Jot stop |
|---|---|---|
| **End the transcription** (state) | Stop capturing/transcribing this utterance; flip recording state off so home + keyboard reset and the next Dictate tap starts fresh. | **Do it** — same as a normal keyboard stop. |
| **Release the mic / warm-hold** (engine) | Whether the audio engine stays warm afterward for a quick re-dictation, then releases on its own cooldown. | **Leave it exactly as today.** Mic stays warm. Do **not** `forceStop`. Do **not** change or delete warm-hold. |

**Proof this is the right split (the current bug):**
- A **normal keyboard stop** ends the transcription cleanly — home shows
  not-recording and you can immediately tap Dictate again — *even though the mic is
  still warm*. So the warm mic is not the problem; that's correct behavior.
- The **Feedback (inline) stop** pastes the text but **never flips the recording
  state off**, so home still shows "recording" and the keyboard thinks it's still
  going → Dictate is dead. It does the paste but skips "end the transcription."

So the fix is **not** about warm-hold. It is: make the in-Jot stop end the
transcription the same way a normal keyboard stop already does, while the mic
warm-holds identically. Warm-hold is orthogonal and untouched.

## 3. Per-surface behavior (the one rule, applied)

| Surface | Pastes into | Saves a transcript? | Ends transcription cleanly + warm-holds? |
|---|---|---|---|
| Keyboard in **any other app** (Messages, Notes…) | that app's field | **Yes** (outside Jot) | Yes — today's baseline, already works |
| **Feedback** (Settings → Send Feedback) | the feedback field | **No** | Yes |
| **Transcription edit** | the edit field | **No** — you persist via the edit panel's own Save button; dictation never creates a *new* transcript | Yes |
| **Settings** (any other text field) | that field | **No** | Yes |
| **Wizard (W5 keyboard test)** | the wizard's test field | **No** (it's a test) | Yes |

Everything except Ask becomes *just a field*. No registration, no inline session,
no hero fallback. Warm-hold runs identically everywhere because they all use the
**one** keyboard stop path.

### 3a. Cross-boundary (start in app A, stop in app B) — locked behaviors

The paste lands wherever the cursor is **at Stop time**, because the keyboard is
app-agnostic at the `UITextDocumentProxy` level (it doesn't know which app's field
it's typing into). Save follows the same "are you inside Jot at stop?" rule.
(Folded in from the retired `in-app-tap-to-record.md`.)

| # | Scenario | Paste lands | Saves? |
|---|---|---|---|
| A | Start in Slack → end in Jot's feedback / prompt / vocab field → Stop | the Jot field | **No** (stopped inside Jot) |
| B | Start in Jot's vocab editor → end in Messages → Stop | the Messages field | **Yes** (stopped outside Jot) |
| C | Start in Jot field A → switch to Jot field B → Stop | field B | **No** |
| D | Start in Jot field → stay in same field → Stop | same field | **No** |
| E | Start in Jot field → swipe home → open Messages → back to Jot → Stop | whatever field the cursor is on at Stop | per where you stop |

## 4. Fate is decided at the stop, not stamped at the start

A recording carries **no** "I won't be saved" identity from birth. What happens to
the audio is decided **where and how you stop it**:

- **Stop via the keyboard while focused in a Jot field** → paste, **no** save.
- **Stop via the keyboard while in another app** → paste, **save**.
- **Stop via the hero** (reached from the home pill) → **save** (you left the field;
  the hero's save is the right outcome). Confirmed already true: the hero's
  `stopTapped()` calls `completeEndOfRecording` directly and never checks how the
  recording started (`RecordingHeroView.swift:938-944`).

This removes the start-time `ownsActiveRecording` "no-save birth flag" as an
identity. The save/no-save decision lives at the stop site: *"is a Jot field focused
(Jot foreground) when the stop happens?"*

## 5. Home pill — show "recording" for any live recording

Today the home recording pill only appears when you started **on the hero** and
explicitly **backed out** of it — gated on `userDismissedHeroDuringRecording`
(`ContentView.swift:613-618`). Broaden it: the pill shows for **any** live recording
while home is visible, so the Dictate FAB never lies by showing "Start" while
something is recording. Tapping the pill opens the hero, which can adopt any running
recording (`adoptInFlightRecording()` just attaches to whatever's live —
`RecordingHeroView.swift:886-890`), where you can pause / cancel / stop.

**Keep the one guard the old gate also provided:** suppress the pill for the
one-frame window on a `jot://dictate` cold start where `isRecording` flips true
*before* `.onAppear` pushes the hero (`ContentView.swift:317-321`). Re-key that
suppression on "the hero is about to present," not on "user backed out."

## 6. What gets deleted

- `InlineDictationReceiver` (the whole registration layer) and its
  `register`/`deregister`/`heroFallbackRequest`.
- Use of `InlineDictationSession` by **Edit, Feedback, Wizard** (Ask keeps its own).
- The `keyboardDictateTapped`-routes-to-inline path; in-Jot keyboard taps instead
  start a normal background capture (no hero) and the keyboard inserts the result on
  stop, exactly like the cold-from-another-app path.
- The edit-panel dictation cage — **already done**: `TranscriptDetailView.swift:608`
  is now `isEditable: true` (the editor stays editable so the keyboard + its Stop
  stay available). The matching `.disabled(isDictating)` on Cancel/Save and the
  "Listening…" label become moot once the inline session is gone.
- The `TranscriptDetailView` `.onDisappear` `discard()` and the `scenePhase`
  finalize that only existed to babysit the inline session.

## 7. What must NOT change (regression guards for review)

- **Warm-hold** — identical everywhere. Not deleted, not forceStopped, not retimed.
- **Dictate FAB / hero** capture → still **saves**.
- **Cold keyboard from another app** → still pastes **and saves**.
- **Action Button / DictateIntent / warm-resume** captures → still **save**.
- **Ask** → keeps its own `InlineDictationSession`; never saves (it's a query).
- **Wizard teardown contract** — if the wizard is dismissed *mid-recording without
  stopping*, that recording is **discarded** (not leaked to the home pill). This is
  the one place a recording is intentionally dropped on navigation (onboarding modal).
  See `CLAUDE.md` → "Wizard / setup-flow conventions."
- **Italics for unsaved edits** in the transcript editor — independent of editability,
  stays (`TranscriptDetailView.swift:597-601`, see `inline-edit-italics.md`).

## 8. The linchpin — verify FIRST, before deleting anything

The whole design rests on one unproven assumption:

> **The Jot keyboard can insert text into Jot's *own* focused field via the standard
> keyboard insert (the same mechanism it uses in every other app).**

It almost certainly can — a custom keyboard inserts into whatever field it is active
in — but the previous devs built the custom inline path instead, possibly because of
this, possibly only for live word-by-word streaming (which the user does not want).
**Stage 0 is a throwaway prototype that proves the keyboard insert lands in a Jot
field.** If it does, proceed. If it genuinely cannot, stop — the design needs rework.

## 9. Staged implementation order

Each stage is independently testable on-device before the next. Sub-agents
implement; the lead reviews each diff. Touching the stop core / nav teardown is the
risky part — do it only after Stage 0.

- **Stage 0 — Prove the linchpin.** Throwaway: confirm the keyboard insert lands in a
  Jot field (Feedback). Make/break for everything below.
- **Stage 1 — Home pill for any live recording.** Broaden `isLiveRecordingInline`;
  keep the cold-start-flash suppression. Safe, independent, no stop-core changes.
  *(Already shipped half of the un-caging: `isEditable: true`.)*
- **Stage 2 — Route in-Jot keyboard taps through the normal capture path.** Background
  capture (no hero), keyboard inserts on stop, ending the transcription cleanly +
  warm-holding like any other app.
- **Stage 3 — Move save/no-save to the stop site.** Skip the transcript save when a
  Jot field is focused at stop (Jot foreground); retire the `ownsActiveRecording`
  birth flag as an identity. Hero stop always saves.
- **Stage 4 — Delete the dead inline machinery.** `InlineDictationReceiver`, the
  Edit/Feedback/Wizard registration, the hero fallback, the now-moot Edit guards.

## 10. Acceptance criteria

For **each** of: another app, Feedback, transcription edit, settings field, wizard test:
1. Start dictation; text streams/pastes into the focused field on stop.
2. After stop: **home does not show "recording"**, and **tapping Dictate again starts
   a fresh recording** (no dead tap). *(This is the bug being fixed.)*
3. Inside Jot → **no new transcript** is written. Another app → transcript **is** saved.
4. Mic warm-hold behaves exactly as it does today (unchanged).
5. If you instead walk to home and stop from the **hero** → the recording **is saved**.
6. Wizard dismissed mid-recording → recording discarded, nothing leaks to home.

## 11. Schema impact

**None.** No `@Model` fields, entities, renames, or migrations. This is recording
control-flow + UI state only; the SwiftData `Transcript` shape is untouched.
