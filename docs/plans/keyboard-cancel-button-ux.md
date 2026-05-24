# UX Plan: Cancel Button During Recording (Color, Icon, Anatomy)

> **Companion to:** [docs/plans/keyboard-cancel-during-recording.md](./keyboard-cancel-during-recording.md)
> **Scope:** visual + interaction design for the Cancel button that replaces the Actions button while a dictation is actively recording.

---

## Where the Cancel button lives

Action row, third slot (where the Actions button normally lives). Layout context:

```
┌──────────────────────────────────────────────────────────────┐
│ 🔴 0:08  ▂▃▆▅▃▂▁  Hello, this is dict...  [↓live]              │ ← streaming strip
├──────────────────────────────────────────────────────────────┤
│ (punctuation row hidden during recording — per §5.1)            │
├──────────────────────────────────────────────────────────────┤
│  ⌂            ⏹  Stop (0:08)              ✕                  │
│  Minimize     primary action               Cancel               │
└──────────────────────────────────────────────────────────────┘
```

Cancel inherits the **icon-button shape** of Actions — same hit target, same alignment. Different color + icon.

---

## Color choice — research against the existing palette

Current tokens that could plausibly apply (from `Jot/App/Design/JotDesign.swift`):

| Token | Value | Where it's used today | Suitability for Cancel |
|---|---|---|---|
| `jotBlueTop` / `jotBlueBottom` | `#1A8CFF` / `#0064CC` (blue gradient) | Stop button gradient; CTAs | ❌ — would collide with Stop. The whole point of Cancel is to be distinct. |
| `jotRecord` | `#FF3B30` (red) | Recording state, error banners | ⚠️ — already in use for "recording active" indicators. Reusing as a button fill could read as "Stop again" rather than Cancel. |
| `jotAccent` | `#FF6B5C` (coral) | Coral CTA buttons elsewhere (CoralActionButton, sparkles glyph for AI-rewrite affordance in row §1.2 / §5.2) | ❌ — coral reads as "AI feature" in Jot's language. Wrong semantic. |
| `jotWarning` | `#FFA02E` (orange) | Status banner warnings | ❌ — too eye-catching for a quiet abort. |
| `jotInk` | adaptive black/white | Body text, key fills | ⚠️ — possible neutral choice; reads as low-emphasis. |
| `jotMute` | adaptive mid-gray | Secondary text | ⚠️ — too low contrast for a button. |

**No existing token cleanly maps to "destructive secondary action."** This is the design gap.

## Three candidate treatments (pick one)

### Treatment A — Subdued red, outlined

Icon: `xmark` (SF Symbol) in red, **no fill**. Border: 1pt stroke in `jotRecord.opacity(0.65)`.

```
   ╭──────╮
   │  ✕   │  ← red xmark on transparent/glass background, red stroke
   ╰──────╯
```

**Pros:**
- Clearly destructive (red).
- Outlined treatment differentiates from Stop's solid-fill primary.
- Echoes iOS's standard "destructive secondary action" pattern (think iOS Mail's outlined delete).

**Cons:**
- Two red elements in close proximity (Stop pill is `jotRecord` when active, Cancel is red outlined). Could read as "two stop buttons."

**When it's right:** if Stop is rendered in blue (jotBlue gradient) during recording rather than red. Need to confirm: today's keyboard renders Stop in what color during the recording state?

### Treatment B — Glass treatment with red `xmark`

Icon: `xmark` filled in red (`jotRecord`). Background: glass / `.regularMaterial` blur. No stroke.

```
   ╭──────╮
   │░ ✕ ░ │  ← red xmark on frosted-glass background
   ╰──────╯
```

**Pros:**
- Consistent with Jot's Liquid-Glass design language (other surfaces use `.regularMaterial`).
- Soft visual weight — doesn't compete with Stop.
- Light + dark mode adaptive automatically via the material.

**Cons:**
- Frosted glass over a colored keyboard surface can read muddy on certain hosts (some hosts have non-standard keyboard backgrounds in dark mode).

**When it's right:** matches Jot's existing visual idiom. Probably the cleanest fit.

### Treatment C — Neutral gray, red `xmark`

Icon: `xmark` in red (`jotRecord`). Background: `Color.jotInk.opacity(0.08)` (light neutral) / `Color.jotInk.opacity(0.16)` (dark mode).

```
   ╭──────╮
   │ ▓✕▓ │  ← red xmark on neutral gray pill
   ╰──────╯
```

**Pros:**
- Maximum visual distinction from Stop's bright fill.
- Quiet — doesn't dominate the action row.
- Predictable contrast in both light and dark.

**Cons:**
- Less "destructive" feeling at a glance. User might miss the red xmark on a quick scan.

**When it's right:** if user-testing shows Treatment B reads as muddy.

## Decision: Treatment B (chosen)

**Treatment B — glass + red `xmark`** is the chosen design.

- Icon: `xmark`, SF Symbol, weight `.medium`, size 17 pt.
- Icon color: `jotRecord` (#FF3B30, fixed in both modes — iOS-standard destructive red).
- Background: `.regularMaterial` (auto-adapts light/dark).
- Hairline: `jotKeyboardGlassHairline` (existing token, light/dark adaptive).

### Reasoning

- Matches the keyboard's existing Liquid-Glass surfaces (`jotKeyboardGlassFill1`, `jotKeyboardGlassFill2`, `jotKeyboardGlassHairline` tokens already in `JotDesign.swift:153-180`).
- Quiet enough that Cancel doesn't compete with Stop for attention — Stop remains the primary.
- Red xmark unambiguously signals "destructive abort."
- During-recording chrome is **blue-tinted** (`jotKeyboardChromeRecordingTint` is rgba 0,122,255 — not red as I initially worried). So red-Cancel-on-blue-tinted-chrome creates clean visual hierarchy with the blue Stop pill.

### Light + dark verification

- **Light mode:** light-gray chrome (~`#D5D7DE`) with subtle blue wash → white frosted glass (78% white) → red xmark. High contrast, clean.
- **Dark mode:** dark-gray chrome (~`#25252A`) with subtle blue wash → dark frosted glass (`#464852` at 62% alpha) → red xmark. Red icon stays high-contrast; **button outline is borderline against the chrome** and relies on the hairline border for shape definition.

### Dark-mode mitigations (apply at implementation time)

To make sure the button doesn't feel mushy in dark mode:

1. **Render the hairline at higher opacity for this button specifically** — `jotKeyboardGlassHairline` is `white(1.0, alpha: 0.06)` in dark mode; bump to `0.12` for the Cancel button to give a crisper edge.
2. **Bump glass fill opacity slightly** above the standard `jotKeyboardGlassFill1` (`0.62` in dark) — use `0.78` for this button so the surface stands off the chrome more clearly.
3. **Build a SwiftUI Preview first** that renders Cancel against both light and dark chrome side-by-side, before wiring it into the keyboard. If the dark-mode preview still feels mushy after mitigations 1+2, fall back to Treatment C (neutral pill, hard edges) — single-line change.

### If post-implementation testing rejects Treatment B

Switch to Treatment C (neutral gray pill + red xmark). One-line change.

---

## Icon

**`xmark` (SF Symbol)** at `font(.system(size: 17, weight: .medium))`.

Alternatives considered and rejected:
- `xmark.circle.fill` — too heavy; competes visually with Stop's filled pill.
- `arrow.uturn.backward` — semantic mismatch (this is abort, not undo).
- `trash` — wrong metaphor (we're not deleting saved data).
- `xmark.circle` — outlined circle is OK but visually busier than bare `xmark`.

The bare `xmark` is iOS-native for "dismiss / cancel" and matches the Cancel pill on the Recording Hero (§2.6).

---

## Hit target + sizing

- Frame: **44 × 44 pt** (Apple HIG minimum for hit targets — same as Actions button it replaces).
- Visible button: **40 × 40 pt** centered in the 44 × 44 frame (matches existing Actions visual size).
- Stroke (Treatment A only): **1 pt**.
- Corner radius: **20 pt** (continuous, full circle).

---

## Light + dark mode

Treatment B uses `.regularMaterial` which adapts automatically:
- Light mode: light frosted appearance.
- Dark mode: dark frosted appearance.

Icon color `jotRecord` is intentionally NOT adaptive — red reads as red in both modes. Apple's accessibility guidance: destructive actions are reddish in all appearances.

Verify against the keyboard's existing `jotKeyboardChromeRecordingTint` and `jotKeyboardChromeRecordingHairline` tokens (they're already adaptive) to make sure the glass treatment sits naturally on the recording chrome.

---

## Interaction states

| State | Appearance |
|---|---|
| Default (recording active) | Treatment B, full opacity. |
| Pressed | Scale 0.96, brightness 0.85. Same as other action-row buttons. |
| Disabled | Not used — Cancel is always actionable while recording. |

No haptic on tap (Cancel should feel weightless — pressing it is "I changed my mind," not a deliberate-commit gesture). The existing keyboard input-click sound is suppressed via `enableInputClicksWhenVisible` returning false for non-key controls.

---

## VoiceOver

- Label: *"Cancel recording. Discards what you've said so far."*
- Traits: `.button`, `.startsMediaSession` (since cancel-during-recording ends the recording session).

Distinct from:
- Stop button label: *"Stop and save."*
- Wizard W5 Cancel: *"Cancel try-it."*

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md](./open-questions-deep-dive.md). (No questions for this plan — visual choices are bounded by the existing palette.)

1. **What color is Stop rendered in while recording?** If Stop is `jotRecord` red during recording, Treatment A (red outlined Cancel) would create two red elements next to each other. Treatment B's glass treatment avoids this collision and is the safer pick regardless. Confirm Stop's recording-state color.
2. **Should the Cancel button be slightly smaller than Actions** to visually de-emphasize it? Pros: cleaner hierarchy. Cons: inconsistent hit target across recording / idle states. Recommend keeping it identical for muscle-memory consistency.

---

## Cross-Links

- Companion plan: [keyboard-cancel-during-recording.md](./keyboard-cancel-during-recording.md) (the feature itself)
- features.md: `§5.6` (Actions Popover — the slot we replace during recording), `§5.4` (Dictate/Stop control adjacent), `§2.6` (Cancel semantics from Hero)
- Color tokens: `Jot/App/Design/JotDesign.swift` (jotRecord, jotKeyboardGlassFill1/2, jotKeyboardGlassHairline)
