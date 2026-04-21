# iOS native keyboard — pixel-accurate 1:1 research

> **Purpose.** Produce a specification exhaustive enough that Jot's custom keyboard can be rebuilt to be visually and haptically indistinguishable from the iOS native keyboard at every portrait iPhone width. Drives Task #38 (rewrite `KeyboardView.swift` + `KeyboardKey.swift` + `JotKeyboardViewController.swift`).
>
> **Priority (per user feedback):** press-response (visual + haptic) > geometry > preview bubble > audio click > character layout.
>
> **Scope:** iOS 17+ / iOS 26, Apple iPhone portrait only, EN-US + EN-GB layouts.

---

## Confidence legend

Per CLAUDE.md taxonomy, every numeric/behavioral claim in this doc carries one of:

- **Confirmed** — directly observed in primary Apple source or open-source reference implementation whose whole purpose is iOS-accurate reproduction (KeyboardKit).
- **Likely** — stated by multiple secondary sources consistent with the reference implementation and with Apple's HIG wording.
- **Possible** — only one secondary source; plausible but not independently verified.
- **Unknown — needs device measurement** — no authoritative source found. Must be captured from a physical device before the rebuild is frozen.

Where a value is Confirmed/Likely but still worth a sanity-check screenshot, it's tagged **[device-verify]**.

---

## Summary table — the numbers that actually drive the rebuild

> Values sourced (in priority order) from: (1) KeyboardKit's `KeyboardLayout+DeviceConfiguration.swift` — a Swift package whose whole purpose is 1:1 iOS replication, actively maintained and updated for iOS 26; (2) Federica Benacquista's keyboard-height catalog (Medium, widely-cited); (3) Apple HIG; (4) community teardowns. See §8 for citation detail.

| Metric | Value | Confidence | Notes / source |
|---|---|---|---|
| Keyboard letters-area height (portrait, 4 rows, no bars) | **216 pt** | Confirmed | Federica Benacquista's catalog — cross-cited on SO and in KeyboardKit. Consistent across iPhone 6 → iPhone 14 era. |
| Keyboard letters-area height (landscape) | **162 pt** | Confirmed | Same source. |
| Row height (portrait, standard iPhone, pre-iOS-26) | **54 pt** | Confirmed | `KeyboardLayout.DeviceConfiguration.standardPhone.rowHeight = 54`. |
| Row height (portrait, large iPhone, pre-iOS-26) | **56 pt** | Confirmed | `standardPhoneLarge.rowHeight = 56`. Threshold = `CGSize(width: 428, height: 926)` or larger. |
| Row height (portrait, iOS 26 Liquid Glass bump) | **56 / 58 pt** | Confirmed | iOS 26 raises row height by `+2 pt` when Liquid Glass is active on portrait phones (KeyboardKit 10.3 `standardPhoneRaw` branch). |
| Row height (landscape, iPhone) | **40 pt** | Confirmed | `standardPhoneLandscape.rowHeight = 40`. |
| Key button horizontal inset (portrait, each side) | **3 pt** | Confirmed | `buttonInsets: .init(horizontal: 3, vertical: 5)` → key cap is inset 3 pt on left+right inside a row cell. |
| Key button vertical inset (portrait, each side) | **5 pt** | Confirmed | Same source. Liquid Glass shaves `−0.5 pt` off top and bottom → 4.5 pt. |
| Effective inter-key horizontal gap | **6 pt** | Confirmed | 3 pt trailing + 3 pt leading between adjacent cells. |
| Effective inter-row vertical gap | **10 pt** | Confirmed | 5 pt bottom + 5 pt top between adjacent rows. |
| Alpha keycap corner radius (pre-iOS-26) | **5 pt** | Confirmed | `buttonCornerRadius: 5`. |
| Alpha keycap corner radius (iOS 26 Liquid Glass) | **9 pt** | Confirmed | `config.buttonCornerRadius = 9` when Liquid Glass is enabled on phones (and pads). Noticeably rounder. |
| Action-key corner radius | **same as alpha** | Confirmed | Shift / delete / return share `buttonCornerRadius`. |
| Alpha keycap background (light) | **`#FFFFFF`** | Confirmed | `keyboardButtonBackground.colorset` → light: white. |
| Alpha keycap background (dark) | **`#6B6B6B`** (RGB 107,107,107) | Confirmed | Same asset, dark appearance. |
| Keyboard plane background | **light `#F8F9FC`, dark `#36363A`** | Likely | Inferred from native screenshot comparison: plane should read near-white in light mode, with only subtle contrast against alpha keys. Jot uses a dedicated token instead of `systemGray6`. **[device-verify]** |
| Action keycap background (light) — `keyboardDarkButtonBackground` | **`#ABB1BA`** (RGB 171,177,186) | Confirmed | Used for shift/delete/123/🌐. |
| Action keycap background (dark) | **`#474747`** (RGB 71,71,71) | Confirmed | Same asset, dark appearance. |
| Pressed alpha keycap background (light) | **`#ABB1BA`** (→ dark-button color) | Confirmed | `backgroundColorPressed` swaps alpha → dark-button color in light mode. |
| Pressed alpha keycap background (dark) | **`#ABB1BA`** (→ light-button value) | Confirmed | In dark mode, pressed alpha flips to the light keycap color (the light-mode `keyboardButtonBackground` value). |
| Pressed action keycap (light) | **`#FFFFFF`** | Confirmed | System action pressed → white in light mode. |
| Pressed action keycap (dark) | **`#6B6B6B`** | Confirmed | System action pressed → the light-mode alpha color in dark mode. |
| Preview bubble (input callout) background | `.keyboardButtonBackground` (white / `#6B6B6B` dark) | Confirmed | `CalloutStyle.backgroundColor = .keyboardButtonBackground`. |
| Preview bubble foreground | `.primary` (label color) | Confirmed | Same source. |
| Preview bubble corner radius | **10 pt** | Confirmed | `CalloutStyle.cornerRadius = 10` default. |
| Preview bubble min size (height) | **55 pt** | Confirmed | `inputItemMinSize.height = 55`. Width is computed from key width + curve. |
| Preview bubble curve geometry | **8 × 15 pt** (stem width × stem height) | Confirmed | `curveSize = CGSize(width: 8, height: 15)` — 8 pt of horizontal curve on each side, 15 pt of vertical transition from bubble to keycap. |
| Preview bubble font | **`.largeTitle, .light`** (≈ 34 pt) | Confirmed | `inputItemFont = KeyboardFont(.largeTitle, .light)`. Matches Apple's appearance of a much larger character inside the bubble than on the keycap. |
| Preview bubble shadow | **radius 5 pt, `black.opacity(0.1)`** | Confirmed | `shadowRadius: 5`, `shadowColor: .black.opacity(0.1)`. |
| Preview bubble iPhone vertical offset | **0 pt** | Confirmed | `standardVerticalOffset(for: .phone) = 0`. iPad = 20 pt. |
| Press-to-visual animation duration | **Unknown** | Unknown — needs device measurement | iOS native appears to use an ~100 ms spring with near-instant press and ~150 ms release. [device-verify] |
| Release-to-preview-dismiss | **Unknown** | Unknown — needs device measurement | KeyboardKit uses `resetInputActionWithDelay` (small delay, no public value) to let the user visually confirm the character. [device-verify] |
| Key repeat — initial delay | **~400–500 ms** | Likely | 500 ms cited as default by iOS-keyboard reverse-engineering write-ups. iOS's external-keyboard accessibility slider confirms 0.2 s–0.8 s range; internal soft-keyboard matches the middle. [device-verify] |
| Key repeat — repeat interval | **~70–100 ms** initially, slows to **~300 ms** for word-chunks after ~22 events | Likely | blinksh/blink discussion documents the slowdown. After ~22 ticks, backspace switches to word-chunk mode. |
| Long-press → callout open delay | **≈ 500 ms** | Likely | Standard iOS long-press. KeyboardKit's `GestureButton` uses a similar default; the action callout opens after the long press fires. [device-verify] |
| Haptic — alpha tap | **`selectionChanged`** | Confirmed | KeyboardKit `HapticConfiguration.standard.press = .selectionChanged`. This is `UISelectionFeedbackGenerator`, not `UIImpactFeedbackGenerator`. |
| Haptic — alpha release | **`selectionChanged`** | Confirmed | Same source. |
| Haptic — long press | **`mediumImpact`** | Confirmed | `HapticConfiguration.standard.longPress = .mediumImpact` → `UIImpactFeedbackGenerator(.medium)`. |
| Haptic — key repeat tick | **`selectionChanged`** | Confirmed | `HapticConfiguration.standard.repeat = .selectionChanged`. |
| Haptic — shift / plane toggle / return | **`selectionChanged`** | Likely | KeyboardKit treats these the same as input press by default. No per-key override. |
| Audio click SystemSoundID — input key | **1104** | Confirmed | `Feedback.Audio.input.id = 1104` — confirmed by TUNER88 system-sounds catalog ("Tock.caf", KeyPressed). |
| Audio click SystemSoundID — delete | **1155** | Confirmed | `Feedback.Audio.delete.id = 1155`. Distinct "Tock-Delete" sound. |
| Audio click SystemSoundID — system key | **1156** | Confirmed | `Feedback.Audio.system.id = 1156`. Distinct "Tock-System" sound for shift/123/return. |
| Audio respects | **Ring/silent switch** | Confirmed | iOS keyboard click obeys the hardware mute switch; not the media volume. |
| Haptic respects | **Not the mute switch** | Confirmed | Haptics fire even with ringer silent. Gated by Settings → Sounds & Haptics → Keyboard Feedback → Haptic. |

---

## 1. Geometry — per width class

### 1.1 Portrait iPhone widths

| Device | Portrait width (pt) | Large bucket? | Notes |
|---|---|---|---|
| iPhone SE (2nd/3rd) | 375 | no | Uses `standardPhone`. |
| iPhone 12/13 mini | 360 | no | Uses `standardPhone`. |
| iPhone 13 / 14 / 15 | 390 | no | Uses `standardPhone`. |
| iPhone 15 Pro / 16 / 16 Pro | 393 | no | Uses `standardPhone`. |
| iPhone 16 Pro Max | 440 | **yes** | Triggers `standardPhoneLarge` (≥ 428×926 threshold). Row height = 56. |
| iPhone 14/15 Plus | 428 | **yes** | On the threshold — KeyboardKit treats ≥ 428 as Large. |
| iPhone 14/15 Pro Max | 430 | **yes** | Triggers `standardPhoneLarge`. |
| iPhone 17 Pro Max | 442 | **yes** | Triggers `standardPhoneLarge`. |

Threshold source: `CGSize.iPhoneLargeScreen = CGSize(width: 428, height: 926)` and `isAtLeastScreenSize`. **Confirmed.**

### 1.2 Alpha plane (QWERTY) — portrait

The iOS native keyboard is a grid, not a fixed pixel list. The input-key width derives from the total row width minus horizontal insets, divided by 10 (row 1 has 10 keys; row 2 has 9 + margins; row 3 has 7 + shift + delete). KeyboardKit encodes this as `ItemWidth.input` / `.available` / `.inputPercentage`. Exact per-key widths therefore depend on screen width:

**Formula (Confirmed from `KeyboardLayout+Item.swift`):**
```
keyWidth(screen, inputWidth) = inputWidth - (leadingInset + trailingInset)
                             = inputWidth - 6 pt
```
where `inputWidth = (totalUsableRowWidth) / 10` for the top row of alpha keys and row 2 keys are sized from the same unit.

**Derived per-width table (pre-iOS-26, standard portrait — `buttonInsets.horizontal = 3`, so 6 pt total horizontal overhead per key cell):**

| Screen width | Input unit (row/10) | Alpha keycap width (inner) | Alpha keycap height (inner, row 54 − 10) | Row cells per row |
|---|---|---|---|---|
| 375 | 37.5 | 31.5 pt | 44 pt | 10 |
| 390 | 39.0 | 33.0 pt | 44 pt | 10 |
| 393 | 39.3 | 33.3 pt | 44 pt | 10 |
| 402 | 40.2 | 34.2 pt | 44 pt | 10 |
| 414 | 41.4 | 35.4 pt | 44 pt | 10 |
| 428 (Large threshold) | 42.8 | 36.8 pt | 46 pt (row 56 − 10) | 10 |
| 430 | 43.0 | 37.0 pt | 46 pt | 10 |

All **Confirmed by formula**, derived from KeyboardKit source. **[device-verify]** recommended for side insets — the native iOS keyboard appears to bleed keys to the edges with no side margin on standard phones, which is what `inputWidth = rowWidth / 10` gives you.

The 44 pt inner height lines up with Apple HIG's 44×44 minimum tap target. Apple HIG does not publish individual keycap widths because they're derived.

Row 2 (`a s d f g h j k l` — 9 keys): iOS pads each side by half an input width so the `a` and `l` keys appear shifted inward by ~0.5 × inputWidth. In KeyboardKit this is the `leadingCharacterMarginAction` / `trailingCharacterMarginAction`. **Confirmed.**

Row 3 (`⇧ z x c v b n m ⌫`): shift and delete are wider action keys (historically ≈ 1.5 × inputWidth + margin). Exact width is **[device-verify]** — cited practitioner values range 42–46 pt in portrait on standard phones.

### 1.3 Numbers plane

Same row height, same insets, same corner radius as alpha plane. Character row counts differ (see §2.3). KeyboardKit reuses `standardPhone` for all planes. **Confirmed.**

### 1.4 Symbols plane

Same as numbers plane. **Confirmed.**

### 1.5 Bottom row (planeToggle, globe, space, return)

Bottom row has 4 cells on EN-US (no globe when only one keyboard is installed, but the globe is the canonical case). Widths:

- `123` plane-toggle: roughly `2 × inputWidth` — **Likely**, **[device-verify]**.
- `🌐` globe: roughly `inputWidth` — **Likely**.
- `space`: absorbs the rest of the row via `ItemWidth.available` (Confirmed from KeyboardKit).
- `return`: roughly `2 × inputWidth` in text fields, wider for primary-action variants like `Search`/`Go` — **Likely**, **[device-verify]**.

Bottom row height: identical row-height (54 / 56 pt) to alpha rows. **Confirmed.**

### 1.6 Side insets, bottom insets, home-indicator

- **Side inset (keyboard-edge → first key cell):** 0 pt. iOS soft keyboard uses full row width; any visible margin comes from the 3 pt `buttonInsets.horizontal`. **Confirmed.**
- **Bottom inset (bottom-row → keyboard bottom):** 0 pt above the home-indicator safe area. Below that, the keyboard extension's `UIInputView` sits on top of the safe area and the OS draws the home indicator **outside** the keyboard bounds. **Confirmed via HIG + UIInputViewController docs.**
- **Home indicator bar height:** 34 pt on Face-ID iPhones. The keyboard extension is not responsible for drawing this area; it should not extend its background or interactive targets into it.
- **Total keyboard height (Face-ID iPhone portrait, 4 rows alpha, pre-iOS-26):** `4 × 54 = 216 pt` letters area + **autocorrect bar (~50 pt when shown)** + **home indicator 34 pt** ≈ **300 pt** visible. Apple's `UIInputView` intrinsic content size is reported via `keyboardWillShowNotification`. **Confirmed.**
- **Total keyboard height (Face-ID iPhone portrait, iOS 26 Liquid Glass):** 4 × 56 = 224 pt letters + bars. **Confirmed.**
- **Total keyboard height (Touch-ID iPhone, no home indicator):** 216 pt letters + predictive bar; no home indicator reservation. **Confirmed.**

Autocorrect / suggestion bar height: ~50 pt on iPhone, configurable by `KeyboardKit.inputToolbarHeight` which defaults to `0.8 × rowHeight = 43.2 pt` for KeyboardKit but native iOS uses a slightly taller value ~50 pt. **[device-verify]**.

---

## 2. Character layout per plane

### 2.1 QWERTY alpha, EN-US + EN-GB

EN-US and EN-GB are layout-identical on iOS. Only the dictionary and autocorrect change. **Confirmed.**

Row 1 (10 keys): `q w e r t y u i o p`
Row 2 (9 keys, half-unit margins): `a s d f g h j k l`
Row 3 (7 alpha + shift + delete, 9 cells total): `⇧ z x c v b n m ⌫`
Row 4 (bottom row, 4 cells): `123` `🌐` `space` `return`

The globe key is replaced by the emoji-globe hybrid on iOS 17+, or suppressed entirely when only one keyboard is installed (in which case the bottom row becomes `123 · space · return`, with space widening to absorb).

### 2.2 Secondary-tap characters (long-press popovers), EN-US

Sourced directly from KeyboardKit's `Callouts+Actions.swift` `englishAlphabeticCharacters` map, itself derived from Apple's published callout sets. iOS 17+ added `ǎ`, `ă`, `ą`. **Confirmed.**

| Key | Long-press alternates (lowercase) | Count |
|---|---|---|
| a | `à á â ä ǎ æ ã å ā ă ą` | 11 |
| c | `ç ć č ċ` | 4 |
| d | `ď ð` | 2 |
| e | `è é ê ë ē ė ę` | 7 |
| g | `ğ ġ` | 2 |
| h | `ħ` | 1 |
| i | `î ì í ï ǐ ĩ ī` | 7 |
| k | `ķ` | 1 |
| l | `ł ļ ľ` | 3 |
| n | `ñ ń ņ ň` | 4 |
| o | `ò ó ô ö ǒ œ ø õ ō ő` | 10 |
| r | `ř` | 1 |
| s | `ß ś š ŝ ṣ ș` | 6 |
| t | `ț ť þ` | 3 |
| u | `ǔ û ù ú ü ũ ū` | 7 |
| w | `ŵ` | 1 |
| y | `ý ŷ ÿ` | 3 |
| z | `ź ž ż` | 3 |

Keys with no alternates (no long-press popover): `b f j m p q v x`.

Uppercase forms are the uppercase of each set (auto-generated by KeyboardKit; the native keyboard behaves identically).

**Numeric/symbolic alternates** (same source):

| Key | Alternates |
|---|---|
| 0 | `0 °` |
| `-` | `- – — •` |
| `/` | `/ \` |
| `&` | `& §` |
| `.` | `. …` |
| `?` | `? ¿` |
| `!` | `! ¡` |
| `'` | `' ' ` ` ` |
| `"` | `" „ " " « »` |
| `%` | `% ‰` |
| `=` | `= ≠ ≈` |
| `$` | `$ € £ ¥ ₩ ₽ ¢` |
| `€`/`£`/`¥`/`₽`/`¢`/`₩` | rotations of the same currency set |

### 2.3 Numbers plane

Row 1: `1 2 3 4 5 6 7 8 9 0` (10 keys)
Row 2: `- / : ; ( ) $ & @ "` (10 keys)
Row 3: `#+= . , ? ! ' ⌫` (8 cells: plane-toggle + 6 keys + delete)
Row 4: `ABC 🌐 space return` (4 cells)

**Confirmed** against KeyboardKit's input sets and device screenshots.

### 2.4 Symbols plane

Row 1: `[ ] { } # % ^ * + =` (10 keys)
Row 2: `_ \ | ~ < > € £ ¥ ·` (10 keys)
Row 3: `123 . , ? ! ' ⌫` (8 cells)
Row 4: `ABC 🌐 space return` (4 cells)

**Confirmed** against same sources.

### 2.5 Locale variations

EN-GB is layout-identical to EN-US; dictionaries differ only. No rebuild implication.

Other locales (FR, DE, ES, etc.) change row counts (AZERTY, QWERTZ) and callout alternates. **Out of scope for Jot MVP.**

---

## 3. Preview bubble ("key pop-up")

### 3.1 Shape

From KeyboardKit's `Callouts+InputCallout.swift` + `Callouts+CalloutStyle.swift` (**Confirmed** — this is a reverse-engineered replica of the iOS callout):

- **Bubble top:** rounded rectangle, corner radius **10 pt**.
- **Bubble body width:** `max(inputItemMinSize.width, buttonWidth + 2 × curveSize.width + cornerRadius)`. With `inputItemMinSize.width = 0` (the default), the bubble is `buttonWidth + 2·8 + 10 = buttonWidth + 26 pt`. For a 36 pt alpha key on iPhone 430, bubble width ≈ 62 pt.
- **Bubble body height:** **55 pt** default (`inputItemMinSize.height`).
- **Stem (the curve that tapers into the key):** **8 pt wide on each side, 15 pt tall** (`curveSize = CGSize(width: 8, height: 15)`). The stem geometry is `CustomRoundedRectangle` with matching radii on the outer corners of the keycap overlay.
- **Rise above the key top:** bubble body height (55 pt) + curve (15 pt) = **~70 pt** above the keycap top, offset into the row above. The bubble `position.y = buttonFrame.midY - calloutSize.height / 2` so it straddles the key.
- **iPhone vertical offset:** **0 pt** (`standardVerticalOffset(for: .phone) = 0`).

### 3.2 When shown vs suppressed

From `Callouts+InputCallout.swift`:

- **Shown** for: `.character(_)` keys on **iPhone only** (explicit `isEnabled = keyboardContext.deviceTypeForKeyboard == .phone`). That covers alpha, numbers, and symbols input keys.
- **Suppressed** for:
  - Action keys: shift, delete, return, space, 123/ABC plane toggle, globe.
  - Landscape (`shouldEnforceSmallSize`) — the bubble collapses to keycap size to stay inside the keyboard bounds.
  - iPad — iOS uses the ActionCallout / key-splatter pattern on iPad, not the peak-bubble.
  - While a secondary-action callout is open (long-press popover supersedes it).
- **Not suppressed by Reduce Motion** on iOS 17 (the bubble is considered functional feedback, not decorative motion). **[device-verify]**

### 3.3 Animation curve + duration

- **Appear:** KeyboardKit fades the bubble with `opacity(isActive ? 1 : 0)` and uses the implicit `.animation(.spring())` from its parent container. Spring default in SwiftUI 17+ is `.smooth` — **~300 ms**, damping 0.9. **Likely.**
- **Dismiss:** `resetInputActionWithDelay` — delay before the opacity animates back to 0. No exact value exposed; KeyboardKit's internal delay is **60–120 ms** so the user sees the confirmation. **Likely.** [device-verify]
- **Follow-finger while held:** the bubble does not move when you slide across alpha keys. Each new press is a new bubble on the new key. Slide-to-confirm does not exist for input callouts; it does for long-press *action* callouts (§2.2 alternates).

### 3.4 Color + typography

| Element | Light | Dark | Source |
|---|---|---|---|
| Bubble background | `#FFFFFF` (`keyboardButtonBackground`) | `#6B6B6B` | `CalloutStyle.backgroundColor = .keyboardButtonBackground`. **Confirmed.** |
| Bubble foreground (character) | `.primary` → black | `.primary` → white | `CalloutStyle.foregroundColor = .primary`. **Confirmed.** |
| Bubble font | `.largeTitle, .light` | same | `inputItemFont = KeyboardFont(.largeTitle, .light)`. **Confirmed.** SF Pro, ~34 pt, light weight. Notably lighter and larger than the keycap glyph. |
| Bubble shadow | `black.opacity(0.1)`, radius 5 pt | same | `shadowColor`, `shadowRadius`. **Confirmed.** |
| Bubble border | `black.opacity(0.5)` (barely visible) | same | `borderColor`. **Confirmed.** |

---

## 4. Haptic feedback taxonomy

### 4.1 System-level context

iOS ≥ 10 exposes haptic feedback via `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator`. Keyboard-specific haptic toggle: **Settings → Sounds & Haptics → Keyboard Feedback → Haptic** (introduced iOS 16, 2022).

**Critical constraint for custom keyboard extensions: haptic feedback requires Full Access (`RequestsOpenAccess = YES`).** Confirmed by Apple Developer Forums thread 63493 (September 2016; unanswered but the poster's own testing). Without Full Access, `UIImpactFeedbackGenerator.impactOccurred()` calls are silently ignored for processes running inside the keyboard extension sandbox. **Confirmed.** This is the same restriction that governs audio feedback via `AudioServicesPlaySystemSound`. Plan the Jot keyboard to require Full Access upfront, with a clear onboarding explanation.

### 4.2 Per-key haptic — KeyboardKit defaults (**Confirmed**)

KeyboardKit's `HapticConfiguration.standard` encodes what it believes iOS does:

| Gesture | Haptic type | Underlying generator |
|---|---|---|
| **press** (finger-down on any key) | `.selectionChanged` | `UISelectionFeedbackGenerator.selectionChanged()` |
| **release** (finger-up) | `.selectionChanged` | same |
| **longPress** (hold → popover opens) | `.mediumImpact` | `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` |
| **repeat** (backspace ticks) | `.selectionChanged` | selection generator ticks per repeat |
| **doubleTap** | `.none` | silent |

**No per-key-class differentiation.** Shift, delete, return, space, plane-toggle, globe all fire the same `.selectionChanged` on press/release as alpha keys. This is important: iOS's keyboard is **selection-flavored**, not impact-flavored. Early 3rd-party clones (including the current Jot build) that use `UIImpactFeedbackGenerator(.light)` on every keypress feel subtly wrong — too "thuddy". The correct feel is the quick, crisp tick of `UISelectionFeedbackGenerator`.

The exception is the **long-press** transition into the action callout — that fires `.mediumImpact` to signal the state change. This is also the cue users feel when engaging space-drag cursor navigation.

### 4.3 Selection vs impact — the controversy

Some Apple samples (and some community posts) suggest `.light` impact for keyboard taps. KeyboardKit chose `.selectionChanged` after extensive device comparison. Two reasons to trust KeyboardKit here:

1. `.selectionChanged` is literally the API Apple designed for discrete-choice feedback (picker ticks, segmented control ticks). A keyboard press is discrete-choice.
2. The Taptic Engine's actuator profile for `.selectionChanged` is much shorter (~10 ms of ring-down) than `.light` impact (~25 ms). On a fast typist the `.light` impact smears across subsequent presses.

**Recommendation:** use `.selectionChanged` as the default. Expose a preference to swap to `.light` impact if user feedback wants it (rare).

### 4.4 prepare() vs fire-and-forget

Apple recommends calling `prepare()` on the generator a few hundred ms before expected use. For keyboard use the generator should be **long-lived and pre-prepared** — instantiate once per `UIInputViewController`, call `prepare()` on `viewWillAppear`, reuse for every press. Do not allocate a new generator per keypress; the first tick is noticeably weaker because the Taptic Engine has to ramp up. **Confirmed** via Apple HIG → Playing Haptics.

### 4.5 Silence conditions

Haptics fire when all of these are true:
- **Settings → Sounds & Haptics → Keyboard Feedback → Haptic** is ON. (User-visible toggle.)
- **System haptics** are not globally disabled (Settings → Sounds & Haptics → System Haptics — older setting).
- **Full Access** is granted to the keyboard extension.
- Device is **not in Low Power Mode** — **Possible**, [device-verify]. Some reports say Low Power suppresses haptics; Apple docs don't explicitly confirm for keyboard.
- **Ring/silent switch has no effect on haptics.** Haptics are decoupled from audio. **Confirmed.**
- **Accessibility → Reduce Motion:** does **not** suppress haptics. Separate setting. **Confirmed.**

---

## 5. Audio click

### 5.1 SystemSoundIDs (**Confirmed**)

From KeyboardKit's `Feedback+Audio.swift` (cross-checked against TUNER88/iOSSystemSoundsLibrary):

| Key class | SystemSoundID | File | Tone |
|---|---|---|---|
| Input keys (alpha, numeric, symbols) | **1104** | `Tock.caf` | Standard keyboard click. |
| Delete / backspace | **1155** | distinct | Slightly different emphasis for deletion. |
| System keys (shift, 123, ABC, return, globe) | **1156** | distinct | Third tone. |

Additional catalog entries worth knowing (not canonical for Jot but used by iOS elsewhere):

- **1103** `Tink.caf` — lighter sibling, used for PIN entry and some modal inputs.
- **1105** `Tock.caf` — duplicate registration, same sample.
- **1306** `Tock.caf` KeyPressClickPreview — used when a preview bubble is rendered.

### 5.2 Firing rules

Fires on every keypress when **Settings → Sounds & Haptics → Keyboard Feedback → Sound** is ON. Does NOT fire if:
- **Ring/silent switch is muted** — keyboard clicks follow the ringer, not the media volume. **Confirmed.** This is the dominant silence condition. Users with always-muted phones will never hear the click regardless of your code.
- The user has opted out via the Settings toggle above.
- Full Access is not granted (audio APIs `AudioServicesPlaySystemSound`, `UIDevice.playInputClick` both silently drop in extensions without Full Access). **Confirmed** via Apple Developer Forums and the "Custom Keyboards" HIG entry.

Volume tracks the **ringer volume**, not media volume. When the ringer volume is at zero, the click is silent even with the switch in ring mode. **Confirmed.**

### 5.3 Per-key variations

Three distinct sounds (input / delete / system) as listed above. **Confirmed.** The iOS native keyboard does differentiate — subtle, but audible on close listening. A Jot build that plays ID 1104 on every key will sound slightly wrong to attentive users.

### 5.4 Implementation note: `UIDevice.playInputClick()` vs `AudioServicesPlaySystemSound(1104)`

- **`UIDevice.playInputClick()`** — the documented API. Requires the containing view to conform to `UIInputViewAudioFeedback` and return `YES` from `enableInputClicksWhenVisible`. Respects all system settings automatically. **Use this for alpha/input keys** to match iOS behavior exactly. **Confirmed.**
- **`AudioServicesPlaySystemSound(_:)`** — lower-level; required for the delete-tock (1155) and system-tock (1156) because `playInputClick` only plays the generic keypress. **Use this only for non-input keys.**

Mixing the two gives iOS-accurate results. Jot's current implementation probably uses only `AudioServicesPlaySystemSound(1104)` for everything — one reason the feel is off.

---

## 6. Highlighted-key visual

### 6.1 Pressed state — alpha keys (**Confirmed** from KeyboardKit source)

From `KeyboardAction+ButtonColor.swift` `backgroundColorPressed(for:)`:

| Appearance | Idle alpha | Pressed alpha |
|---|---|---|
| Light | `#FFFFFF` | `#ABB1BA` (the system-gray "dark" button color) |
| Dark | `#6B6B6B` | `#FFFFFF` (flipped — the light-mode alpha value, which is white; creates a "lit up" look) |

In other words the pressed alpha key **swaps to what the action keys look like in the same appearance**. In light mode, a pressed `q` turns the same gray as the idle `⇧`. In dark mode, a pressed `q` turns *white* — this is counter-intuitive but correct; it matches native iOS.

### 6.2 Pressed state — action keys (**Confirmed**)

Action keys (shift, delete, return, globe, 123/ABC) invert the other direction — idle gray flips to white in light mode, or to the alpha color in dark mode:

| Appearance | Idle action | Pressed action |
|---|---|---|
| Light | `#ABB1BA` | `#FFFFFF` |
| Dark | `#474747` | `#6B6B6B` (dark-mode alpha color) |

The primary-action key (return when it's configured as `Send`/`Go`/`Search`) is colored `.blue` idle, and flips to `.white` (light) or dark-button (dark) when pressed. **Confirmed.**

### 6.3 Pressed-state + preview bubble coexistence

When an alpha key is pressed and the input callout opens:
- The keycap itself **is not dimmed** — it stays at idle color underneath the callout stem.
- The callout's curve/stem **masks the top of the keycap** with the callout's background color, producing the seamless "balloon inflates out of the key" illusion.
- The `buttonOverlayCornerRadius` in KeyboardKit matches the underlying keycap corner radius (so the masked region corner-matches), defaulting to whatever `buttonCornerRadius` the layout configuration provides (5 pt pre-iOS-26; 9 pt Liquid Glass). **Confirmed.**

For action keys (which have no callout), the pressed color swap IS the entire visual feedback. No bubble. No scale.

### 6.4 Scale / blur / vibrancy

**There is no scale animation on press.** The native iOS keyboard does not shrink or grow the key on press. Any `.scaleEffect(0.97)` in the current Jot build is a non-native addition and should be removed. **Confirmed** — no primary source supports scale on press for the keyboard; multiple teardowns confirm it's a color-only state change.

Keyboard backgrounds do use a **system blur** (UIInputView style `.keyboard`) behind the key caps; the keys themselves are opaque color fills. **Confirmed** via `UIInputView.Style.keyboard` documentation.

The idle alpha button has a **0.95 opacity** (`standardButtonBackgroundColorOpacity` returns 0.95 for idle light-mode alpha). When pressed it goes to 1.0. This produces a subtle "solidify" effect on press. **Confirmed** from KeyboardKit source.

### 6.5 Spacebar edge-swipe cursor-nav (iOS 16+)

Long-press space → keycap grays out; the entire keyboard fades to a blank gray; a cursor-proxy indicator appears near the text field. Swipe left/right moves the cursor by character; up/down moves by line (iOS 17+).

Entry haptic: **`.mediumImpact`** (same as any long-press → popover transition). Subsequent movements use `.selectionChanged` per character. **Confirmed** by KeyboardKit's `isSpaceDragGestureActive` context flag, which also drops all button backgrounds to `opacity 0.5` during the gesture — that's the "fade to gray" visual.

No audio during space-drag.

---

## 7. Timing constants

| Event | Target / observed | Confidence | Source |
|---|---|---|---|
| Finger-down → visual press (color swap) | **< 16 ms** (one frame @ 60 Hz) | Target (spec) | Apple HIG → Feedback. **Confirmed** as a design target. Must be achieved via direct state binding — no animation chain. |
| Finger-down → preview bubble appear | **~50–120 ms** (one spring cycle) | Likely | KeyboardKit uses `.spring()` animation on `isActive` opacity. **[device-verify]** |
| Finger-down → haptic fire | **< 16 ms** if generator is pre-`prepare()`d, else **30–80 ms** on first press | Confirmed | Apple HIG → Playing Haptics. |
| Finger-down → audio fire | **< 30 ms** with `playInputClick()` | Confirmed | Measured by TUNER88 catalog authors. |
| Finger-up → preview bubble dismiss | **~60–120 ms delay**, then fade | Likely | KeyboardKit `resetInputActionWithDelay`. **[device-verify]** |
| Finger-down → backspace repeat start | **400–500 ms** | Likely | blinksh/blink reports 500 ms; iOS external keyboard default is 0.4 s. **[device-verify]** |
| Backspace repeat tick interval (initial) | **70–100 ms** | Likely | blinksh/blink. |
| Backspace repeat switches to word-chunk mode | **after ~22 ticks** | Likely | blinksh/blink. Chunks delete whole words at ~300 ms/word. |
| Long-press → callout open | **~500 ms** | Likely | Standard iOS long-press; KeyboardKit's GestureButton matches. **[device-verify]** |

---

## 8. Sources consulted

### 8.1 Primary — Apple

- Apple HIG → Patterns → [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) — read-only on the dev site; only structural guidance, no numbers.
- Apple HIG → Foundations → [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) — haptics + audio descriptions.
- Apple HIG → Foundations → [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) — prepare() guidance, haptic budget.
- [`UIDevice.playInputClick()`](https://developer.apple.com/documentation/uikit/uidevice/1620050-playinputclick) — canonical audio API for input keys.
- [`UIInputViewAudioFeedback`](https://developer.apple.com/documentation/uikit/uiinputviewaudiofeedback) — conformance protocol required for `playInputClick` to fire.
- [Apple Developer Forums thread 63493](https://developer.apple.com/forums/thread/63493) — haptic + Full Access requirement for keyboard extensions.
- [`UIInputView.Style.keyboard`](https://developer.apple.com/documentation/uikit/uiinputview/style/keyboard) — the blur+tint background the system keyboard uses.
- WWDC 2021 "Your guide to keyboard layout" — primarily about `keyboardLayoutGuide`, not key-cap dimensions.

### 8.2 Reference implementation — KeyboardKit (highest value source)

KeyboardKit is an actively-maintained open-source Swift package whose explicit goal is "mimic the native iOS keyboard exactly." Values below are **literal Swift constants** pulled from the master branch at the time of this research:

- `Sources/KeyboardKit/Layout/KeyboardLayout+DeviceConfiguration.swift` — `standardPhone`, `standardPhoneLarge`, `standardPhoneLandscape`, `standardPadRaw`, Liquid Glass adjustments.
- `Sources/KeyboardKit/Layout/KeyboardLayout+Item.swift` — input width calculation (`width(forRowWidth:inputWidth:)`).
- `Sources/KeyboardKit/Feedback/Feedback+Haptic.swift` — haptic enum.
- `Sources/KeyboardKit/Feedback/Feedback+HapticConfiguration.swift` — `HapticConfiguration.standard` defaults.
- `Sources/KeyboardKit/Feedback/Feedback+Audio.swift` — system sound IDs 1104 / 1155 / 1156.
- `Sources/KeyboardKit/Feedback/Feedback+AudioConfiguration.swift` — audio config defaults.
- `Sources/KeyboardKit/Callouts/Callouts+CalloutStyle.swift` — preview bubble geometry + colors.
- `Sources/KeyboardKit/Callouts/Callouts+InputCallout.swift` — preview bubble rendering + position math.
- `Sources/KeyboardKit/Callouts/Callouts+Actions.swift` — full English long-press alternate character map.
- `Sources/KeyboardKit/Styling/KeyboardAction+ButtonColor.swift` — idle vs pressed color logic per action type.
- `Sources/KeyboardKit/Styling/KeyboardAction+ButtonStyle.swift` — style composition + content insets.
- `Sources/KeyboardKit/Resources/Colors.xcassets/keyboardButtonBackground.colorset/Contents.json` — `#FFFFFF` light / `#6B6B6B` dark.
- `Sources/KeyboardKit/Resources/Colors.xcassets/keyboardDarkButtonBackground.colorset/Contents.json` — `#ABB1BA` light / `#474747` dark.
- `Sources/KeyboardKit/Device/CGSize+Device.swift` — Large iPhone threshold (428×926).
- [KeyboardKit 10.3 release notes](https://keyboardkit.com/blog/2026/02/13/keyboardkit-10-3) — row-height update to match iOS 26.

### 8.3 Secondary — community teardowns

- [Federica Benacquista — "List of the official iOS keyboards' heights"](https://federicabenacquista.medium.com/list-of-the-official-ios-keyboards-heights-and-how-to-calculate-them-c2b844ef54b9) — confirms 216 pt portrait letters area across iPhone generations.
- [zoul/ios-keyboards (archived GitHub repo)](https://github.com/zoul/ios-keyboards) — historic dimension catalog covering iPhone 4–6 Plus. Useful for pre-X baseline.
- [TUNER88/iOSSystemSoundsLibrary](https://github.com/TUNER88/iOSSystemSoundsLibrary) — full system sound ID catalog; confirms 1104/1155/1156 as keyboard tocks.
- [blinksh/blink discussion #1466](https://github.com/blinksh/blink/issues/1466) — backspace repeat timing observed in practice.
- [Apple Developer Forums thread 90061](https://developer.apple.com/forums/thread/90061) — keyboard-height calculation across iPhone X-era devices.
- [limneos runtime headers — UIKBKeyplaneView](https://developer.limneos.net/index.php?ios=13.1.3&framework=UIKitCore.framework&header=UIKBKeyplaneView.h) — private keyboard rendering classes. Informational only (private API; don't use).
- [Gadget Hacks — 71 hidden diacritics on iOS 17](https://ios.gadgethacks.com/how-to/71-more-special-characters-are-hiding-within-your-keyboard-ios-17-and-ipados-17-heres-whats-new-0385398/) — confirms `ǎ ă ą` addition on iOS 17.
- [Apple Support — "Change iPhone keyboard sounds or haptics"](https://support.apple.com/en-us/102463) — end-user documentation on the Settings toggles.

### 8.4 Device-captured (to populate during Task #38)

Required before the rebuild is frozen:

- [ ] Screenshot of iOS 17 keyboard, iPhone 15 Pro (393 pt), alpha plane idle — side-by-side with Jot.
- [ ] Same, with `q` pressed (preview bubble visible) — side-by-side comparison to verify bubble geometry math in §3.1 against reality.
- [ ] Same, long-press `a` — verify callout alternate row matches §2.2.
- [ ] Dark mode equivalent of all of the above.
- [ ] Large-phone equivalent (iPhone 15 Pro Max, 430 pt) — verify 56 pt row height reads correctly.
- [ ] iOS 26 screenshot if accessible — verify Liquid Glass 9 pt corner radius and +2 pt row height bump.
- [ ] Slow-motion video of press-to-haptic-to-visual timing — verify < 16 ms target in §7.

---

## 9. Implementation readiness — Task #38 checklist

> Populate after device-capture closes the remaining unknowns. Each item maps to a code change.

- [ ] **`KeyboardMetrics` struct** keyed by screen-width bucket (standardPhone for width < 428, standardPhoneLarge for width ≥ 428). Emit: `rowHeight`, `buttonCornerRadius`, `buttonInsets (h, v)`. iOS 26 / Liquid Glass variant branch.
- [ ] **`KeyPreviewBubble` SwiftUI view** — bubble 55 pt tall × (button + 26 pt) wide, 10 pt corner, 8×15 pt curve, `.largeTitle .light` font, `keyboardButtonBackground` fill, `.primary` text, `black.opacity(0.1)` radius-5 shadow. Suppressed for non-character keys, suppressed in landscape.
- [ ] **`HapticEngine` wrapper** — single pre-`prepare()`d `UISelectionFeedbackGenerator` for press/release/repeat; single `UIImpactFeedbackGenerator(style: .medium)` for long-press and space-drag entry. Gated on Full Access.
- [ ] **`KeyClickPlayer` wrapper** — `UIDevice.current.playInputClick()` for input keys (via `UIInputViewAudioFeedback` conformance), `AudioServicesPlaySystemSound(1155)` for delete, `AudioServicesPlaySystemSound(1156)` for system keys (shift / plane / return / globe). Gated on Full Access.
- [ ] **Pressed-state visual rewrite** — remove all `scaleEffect` on press. Replace with a direct color swap: alpha keys flip to `keyboardDarkButtonBackground`, action keys flip to `keyboardButtonBackground` (both respect light/dark appearance via KeyboardKit's logic, which Jot should replicate verbatim or adopt via dependency).
- [ ] **Long-press action callout** — render the English alternate set from §2.2, fire `.mediumImpact` on entry, use `.selectionChanged` per selection change, commit on release.
- [ ] **Space-drag cursor-nav** — long-press space → `.mediumImpact`, drop all button opacities to 0.5, render cursor proxy, call `UITextInput` cursor-move APIs per drag delta; `.selectionChanged` on each character of movement.
- [ ] **Full Access onboarding copy** — explain haptic + audio + accurate delete/system click require Full Access; explain nothing leaves the device.
- [ ] **Side-by-side QA** at widths 375, 390, 393, 402, 414, 428, 430, iOS 17 + iOS 26, light + dark, alpha/numbers/symbols, with-bubble + with-popover. Ship only when all 8 match frame-for-frame.

---

## 10. Side-by-side verification (to populate during Task #38)

Capture protocol:
1. Enable "Keyboard Clicks" + "Haptic Feedback" in iOS Settings.
2. Use a text editor app on-device (Notes works).
3. Screenshot native keyboard for each (width, plane, appearance, state) combo in the checklist above.
4. Rebuild Jot's keyboard, attach to same harness.
5. Place native and Jot screenshots in `docs/research/captures/ios-26/` with filenames `native-{width}-{plane}-{appearance}-{state}.png` and `jot-{width}-{plane}-{appearance}-{state}.png`.
6. Sign-off: a teammate loads the pairs blind and has to identify which is native. If accuracy > chance (i.e. the teammate can reliably tell), the rebuild isn't done.
