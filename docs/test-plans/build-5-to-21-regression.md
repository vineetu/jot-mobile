# Test Plan: Build 5 → Build 21 Regression Sweep

> **Public:** 1.0.2 (5) — what users have on the App Store today.
> **Latest TestFlight:** 1.0.2 (21) — staged but not promoted.
>
> Walk this list end-to-end before promoting build 21 to public. Each row is **one path, one tap sequence, one expected outcome.** Tick as you go.

---

## Known-bug ticket (separate from this list)

- [ ] **Hero page rendering** — user reported the recording hero only shows half the screen sometimes. Investigate separately; not in scope for this regression sweep but worth a manual repro session with logs while you're at it.

---

## 1. iCloud Backup (build 6)

- [ ] Open **Settings → About**. Confirm a row says "Backed up with iCloud (when iCloud Backup is enabled in iOS Settings)". Tap doesn't do anything destructive.
- [ ] iCloud Backup on real device → "Back Up Now" → check Settings → iCloud → Manage Storage → Backups → iPhone → Jot. Confirm the **Jot** entry is in the **MB range, NOT GB** (verifies Qwen + Parakeet 600M v2 weights are excluded).

## 2. SwiftData schema foundation (build 8)

- [ ] **Fresh install over build 5** (delete app first, install build 21). Existing transcripts must load — no data loss.
- [ ] **Upgrade install (build 5 → build 21 in-place)**. Existing transcripts must load — no data loss.
- [ ] Open Console.app, filter for `[SCHEMA-FALLBACK]`. **Must NOT appear** on a healthy install. If it does, the V1 → V4 migration chain broke and we're on the inference fallback.

## 3. Editable transcripts — Original tab (build 9)

- [ ] Open any transcript with Original tab visible. **Edit pencil** in bottom action bar.
- [ ] Tap Edit → Original text becomes a `TextEditor`, keyboard pops, cursor at end.
- [ ] Tap text, modify it.
- [ ] Tap **Save** → edit persists. Recents list row updates immediately to reflect new text.
- [ ] Keyboard's RecentsStrip on next presentation also shows the new text.
- [ ] Tap Edit again → modify → tap **Cancel** → original (now-edited) text remains; the in-flight modification is discarded.
- [ ] Empty Original → tap Save → see "Original text can't be empty" warning; editor stays open.

## 4. Editable transcripts — Rewrite tab (build 9)

- [ ] Take any transcript that has a Rewrite. Tap Edit on Rewrite tab.
- [ ] Modify the rewrite. Save.
- [ ] Rewrite tab shows your edit. **`displayText` falls back: rewriteUserEdit → cleanedText → text.** Confirm Recents row + keyboard RecentsStrip reflect the edit.
- [ ] Discard rewrite (Detail → Discard) → both `cleanedText` AND `rewriteUserEdit` cleared. Tab disappears, Original visible.
- [ ] Tap Transform to re-generate → new rewrite produced, **prior user-edit is cleared** (the new cleanedText starts fresh, no inherited override).

## 5. ActionBar layout (build 10–11)

- [ ] Detail view bottom bar reads (left → right): **🗑 Delete · ✏️ Edit · ✨ Transform pill · 📋 Copy**. Four buttons, Transform is the blue pill, centered-ish.
- [ ] **Copy** glyph (top-right of bar): tap → checkmark flashes → reverts after ~1.3 s. Clipboard contains the active tab's text.
- [ ] **Edit** disabled if mid-rewrite (Transform was just tapped) — verify by tapping Transform then immediately trying Edit.
- [ ] **Delete** confirmation dialog appears, with "Delete rewrite only" sub-option if rewrite exists.

## 6. Edit-mode bar (Save / Cancel layout, build 10)

- [ ] In edit mode, the bottom bar swaps to Cancel | Editing Original/Rewrite | Save.
- [ ] **"Save" must NOT wrap to two lines** — even on the smallest iPhone you have. This was a real bug in build 10; verify the build 11+ fix held.

## 7. 👍/👎 rewrite feedback (build 11)

- [ ] Open a transcript with a rewrite. Look at the attribution row (sparkles + "Rewritten with Qwen…").
- [ ] To the LEFT of "Discard": two thumb icons — 👍 and 👎.
- [ ] Tap 👍 → glyph fills (blue tint), light haptic, persists across reopens.
- [ ] Tap 👍 again → clears to outlined (unrated state).
- [ ] Tap 👎 → fills (red tint).
- [ ] Tap 👍 while 👎 is active → swaps to up.
- [ ] **Re-Transform** → both `cleanedText` and rating are CLEARED. The new rewrite starts unrated.
- [ ] **Discard rewrite** → clears rewrite + edit + rating together.

## 8. Move up / Move down (build 11)

- [ ] Long dictated text in a host field (try in Notes, Slack, Messages, browser address bar — different hosts behave differently).
- [ ] Tap Move up from the keyboard's Actions menu. Cursor should move backward through the field, including when only a few words remain before the cursor. **Should NOT "stick" near the start.**
- [ ] Tap Move down. Same — cursor moves forward, including near the end with only a few words ahead.
- [ ] Try on Slack specifically — this was the failure case (WebView-backed host that refuses out-of-range offsets).

## 9. Classifier — Lab toggle off (build 12+)

- [ ] **Settings → Lab features** (bottom of Settings). Toggle is OFF by default.
- [ ] With toggle OFF: nothing classifies. No `[CLASSIFY]` logs in Console. Category chips don't appear in Detail view.
- [ ] Toggle should appear visible but with the "experimental" caveat caption.

## 10. Classifier — Lab toggle on, no Qwen weights (build 12+)

- [ ] If Qwen weights aren't downloaded: toggle ON, open dashboard.
- [ ] Should see "Download Qwen to classify — open AI Settings" instead of the blue CTA. **Tap should navigate to AI Settings** (build 15 fix — disabled button is a real link, not a dead-end).

## 11. Classifier — foreground "Classify now" (build 15+)

- [ ] Lab toggle ON, Qwen downloaded. Open dashboard. Some unclassified rows present.
- [ ] Memory readout visible at top: `Memory: X MB used · Y MB available`. Color-coded dot.
- [ ] Watch memory readout while tapping **Classify N unclassified now**:
  - On tap: dictation models pre-evict → drop in used MB.
  - During classify: rises as Qwen warms.
  - Between items: dips again (eviction).
- [ ] Progress text updates: "Classifying 1 of N… 2 of N…"
- [ ] **Cancel** mid-run: classify aborts WITHIN ~1–2 seconds (the App Group cancel flag — build 15 fix), not waiting up to 5s.
- [ ] **Help → Diagnostics**: confirm `CLASSIFY/START`, `CLASSIFY/END` entries with `reason=completed` / `cancelled`. No `CLASSIFY/MEM` unless iOS actually sent a memory warning.

## 12. Classifier — per-row classify (build 19+)

- [ ] On an unclassified row in the dashboard: a small ✨ wand button to the right of the chip.
- [ ] Tap wand → that single row classifies (header progress shows "Classifying 1 of 1…").
- [ ] Tap the **chip** of an unclassified row → menu opens with **"Classify automatically"** at the top above the 5 manual categories. Tap it → same effect as the wand.
- [ ] After classify, both wand and the menu entry disappear (row is now tagged).

## 13. Classifier — manual override (build 13+)

- [ ] Tap any chip → menu with 5 categories + "Unclassified" → select different one. Row moves to the new bucket.
- [ ] Detail view subline: chip is also visible (when Lab toggle is on). Tap it → same picker. Edits propagate to dashboard.
- [ ] Manual override is **sticky** — once you set a category, the BG task won't overwrite it. Verify by leaving the app, backgrounding for a while, returning — your manual picks survive.

## 14. Classifier — BG task on charging (build 12+)

- [ ] Plug iPhone in. Background Jot. Leave overnight.
- [ ] In the morning: Help → Diagnostics → look for `CLASSIFY/START`, `CLASSIFY/END` from the BG task path (these show up alongside the foreground ones; the source/time tells you which).
- [ ] Untagged transcripts should have been classified.

## 15. Lab dashboard navigation (build 14+)

- [ ] Tap dashboard row's text region → pushes to TranscriptDetailView. NOT the chip — chip taps must NOT navigate (this was a build 13 BLOCKING bug).
- [ ] Tap chip on a row → menu opens, no navigation.
- [ ] Toggle Lab OFF while dashboard is open → dashboard auto-dismisses back to Settings.

## 16. Memory entitlement (build 21)

- [ ] Run classify on a 6 GB+ iPhone. Memory readout should show higher peak available MB than build 16 did (entitlement gives ~1.5–2 GB more headroom).
- [ ] No regression on 4 GB devices (if you have one to test) — they were already memory-constrained before; entitlement is silently ignored there.

## 17. Classifier truncation (build 21)

- [ ] Classify a transcript longer than ~500 words. Diagnostics log should show `truncated=true` for that item.
- [ ] Category result should still be plausible — truncation is invisible to the user (the full transcript remains stored / displayed everywhere).

## 18. TestFlight artifact retention (build 21 onward)

- [ ] Run `bash scripts/testflight.sh all` once → confirm `tmp/releases/` and `tmp/DerivedData-testflight-*` keep only the most recent 3 of each. No more disk-full panics.

---

## Regression-prone surfaces NOT touched but worth a smoke test

- [ ] **Recording hero** — open dictation, record, stop. Confirm hero renders full-screen (the bug you mentioned).
- [ ] **Auto-paste from keyboard** — dictate from the Jot keyboard inside any host app. Final transcript should paste at cursor. No "PASTE/SKIP" entries in Diagnostics on the success path.
- [ ] **AI Rewrite Transform** — Detail → Transform → pick a prompt → confirm Qwen generates and `cleanedText` updates.
- [ ] **Setup wizard re-run** — Settings → "Re-run setup wizard." Verify W1–W7 still walk cleanly, especially W3 (Full Access) detection.

---

## After you finish

Tell me which rows passed, which failed, which had surprises. I'll triage. If everything passes, you're clear to promote build 21 to the public App Store track.
