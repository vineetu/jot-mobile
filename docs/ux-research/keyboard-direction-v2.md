# Keyboard direction — updated for MVP 2

**Status:** Direction confirmed by user via reference screenshot (Wispr Flow keyboard pattern). Supersedes the earlier "small mic-only keyboard" call in `03-keyboard.md`.

Last touched: 2026-05-03.

---

## What changed

Earlier MVP 2 scope was "small keyboard with just a mic button (no QWERTY)." User has shifted to a feature-rich Wispr-Flow-style keyboard pattern. Reference: Wispr Flow iOS keyboard layout — chip row across the top, big tap-to-speak CTA in the middle, quick punctuation row, ABC fallback to QWERTY, globe + mic in the corners.

## Layout (from top to bottom)

1. **Action chip row** — 4 chips, scrollable horizontally if needed:
   - **Rewrite** (the renamed Articulate prompt — fixed Mac Jot prompt)
   - **Shorter** ("Make it shorter")
   - **Professional** ("Make it more professional")
   - **Paste** — pastes whatever's currently on the clipboard (or the freshest Jot transcript if available)
2. **Big "Tap to speak" mic** — primary CTA, full keyboard width, ~56pt tall, accent-tinted background. Tap launches Jot app + auto-starts dictation. Stop returns to host with transcript inserted.
3. **Quick punctuation row** — 7 keys: `@ . , ? ! '` + delete (backspace). Common punctuation without going to a symbols layer.
4. **Bottom row** — `ABC` (switches into full QWERTY), space bar (with Jot logo glyph), Return (or Search depending on host context).
5. **Bottom corners** — globe (next-keyboard) on the left, system-mic on the right. (Open question: do we need both our mic CTA AND a system mic? Probably not — drop the bottom-right mic if we keep the central CTA.)

## States

- **Idle, no fresh transcript** — Paste chip dimmed; other chips dimmed (no selection); mic CTA prominent.
- **Idle, fresh transcript on clipboard** — Paste chip illuminated.
- **Selection in host** — Rewrite / Shorter / Professional chips illuminated; tap any to apply LLM rewrite.
- **Recording** — mic CTA morphs into stop affordance + amplitude visual; chips dimmed.
- **Warm-resume window (60s after stop)** — mic CTA shows subtle warm ring (per earlier research).
- **No Full Access** — mic + chips disabled with copy "Enable Full Access in Settings → Keyboards"; punctuation + ABC + space + Return still work.

## What this reuses from Tejas's existing keyboard

- `ClipboardHandoff.swift` — paste behavior (now wired to a chip instead of a pill)
- `KeyboardAccessoryBar.swift` — accessory-row layout pattern
- His full QWERTY layout — accessed via the ABC button (don't rebuild)
- `KeyboardFeedback.swift` — haptics + audio click behavior
- `KeyPreviewBubble.swift` — the press-feedback bubble (apply to chips + punctuation + ABC keys)

## What's new

- The 4-chip action row (Rewrite / Shorter / Professional / Paste)
- The big tap-to-speak mic CTA (replaces the mic glyph elsewhere)
- The quick-punctuation row (between mic and ABC row)

## Open questions

1. Bottom-right mic (system dictation glyph in the reference screenshot) — keep or drop? Recommendation: drop, central CTA is enough.
2. ABC button — does it instantly switch to full QWERTY, or expand the keyboard to show QWERTY below the existing layout? Recommendation: full switch (replace the Wispr-style layout with QWERTY when ABC tapped; tap ABC again to switch back).
3. Chip overflow — if we ever add a 5th chip (vocabulary etc.), do they scroll horizontally or wrap? Recommendation: scroll horizontally; keeps the layout single-row.
4. Rewrite chips behavior — does tapping Rewrite immediately apply to the selection, or does it open a "speak your rewrite instruction" mode (per the earlier voice-rewrite design)? Two options:
   - **Tap = apply preset prompt instantly** (Rewrite chip = Mac's `.rewrite` v1.5 fixed-prompt path)
   - **Tap = enter voice-instruction mode** (Mac's `.rewriteWithVoice` v1.4 path)
   - Recommendation: tap = apply preset instantly (matches the "3 preset prompts" guidance). Voice-instruction-rewrite would need a 5th affordance.

## Not yet built

This is direction only — no code yet. MVP 2 keyboard implementation will land after MVP 1 (in-app dictation) ships and you've used it on device for a few days.
