# Plan: Donation Milestone Re-Prompt — Evolving the Existing Donation Card

> **Source:** [docs/deferred-engineering.md §4](../deferred-engineering.md)
> **CRITICAL CORRECTION:** A DonationCard already ships. The original draft of this plan was written without reading `DonationCard.swift` + `DictationStats.shouldShowDonationCard`. This revision corrects that premise and reframes the work as **evolving** the existing single-shot card into a multi-milestone re-prompt, not building from scratch.

---

## What already exists (must read before changing anything)

- `Jot/App/Donation/DonationCard.swift` — a Liquid-Glass-styled card with "See donations" / "Not now" buttons. Renders inside `ContentView.swift:191-196`.
- `Jot/Shared/DictationStats.swift`:
  - Single threshold: `donationThresholdSeconds = 2 * 60 * 60` (2 hours).
  - Persistent state machine via `donationCardState`: `.unseen → .dismissed → .donated`. `.donated` is **terminal** ("unconditional don't-re-ask is friendlier than a webhook-backed confirmation," per code comment).
  - Gate: `shouldShowDonationCard` returns true only when `donationCardState == .unseen` AND `totalSeconds >= donationThresholdSeconds`.
- **Not documented in features.md.** Grep confirms no entry for the existing card. This is a documentation gap independent of this plan and worth fixing as part of any change here.
- Existing 2h threshold was the result of an explicit tuning decision documented in code — the prior 10-hour figure was rejected as "too aspirational, would hide the card from the casual majority." Any new threshold list should respect this prior reasoning.

## Problem

Today's card is **one-shot**: a user dismisses it once and never sees it again. There is no re-prompt at later milestones. A user who hits 2h and says "not now," then puts in another 20h of dictation, never gets a second chance to discover donations from the home screen.

But the inverse-problem also matters: the existing code's terminal `.donated` (and even `.dismissed`) state was a deliberate "don't nag" choice. Any plan that adds re-prompts must avoid the Wikipedia-banner anti-pattern the existing code consciously rejects.

## Goal

Evolve the single-shot card into a milestone-aware re-prompt that is:

1. **Generous** in framing — "Jot has saved you N hours" leads, donation ask follows.
2. **Bounded** in frequency — long gaps between prompts so users never feel nagged.
3. **Terminal-respecting** — a user who has already donated (`donationCardState == .donated`) is never re-prompted.
4. **Respectful of prior dismissals** — a user who dismissed at 2h must wait until both (a) they cross a meaningfully higher milestone AND (b) significant time has elapsed.

## Non-Goals

- Not replacing the existing `DonationCard.swift` component — extending its visibility logic only.
- Not adding push notifications or modals.
- Not making the card user-configurable (no "remind me later" picker — just generic dismiss).

---

## Design

### State machine (revised, additive)

Keep `donationCardState` as the global terminal-state flag (`.unseen / .dismissed / .donated`). Layer a multi-milestone tracker on top:

```swift
// New in DictationStats.swift
struct DonationMilestoneTracker: Codable {
    /// Threshold-seconds → timestamp when the user dismissed or tapped through.
    /// Both actions end the prompt the same way; no need to distinguish for re-prompt logic.
    var dismissedAt: [Int: Date] = [:]
    var neverAskAgain: Bool = false
}

static var donationMilestoneTracker: DonationMilestoneTracker { ... }
```

Persisted under a new key `jot.stats.donationMilestoneTracker`. Coexists with the existing `donationCardState`. A user who *taps through* to Donations from a milestone card is stamped the same way as a *dismiss* — both pass the cooldown gate equally.

### Show logic (revised `shouldShowDonationCard`)

```swift
static var donationCardMilestone: DonationCardMilestone? {
    // Hard stops first
    guard donationCardState != .donated else { return nil }       // terminal
    guard !donationMilestoneTracker.neverAskAgain else { return nil }

    // Compute the highest milestone the user has crossed
    let saved = totalSeconds  // raw, not multiplier-applied (see below)
    let crossed = DonationCardMilestone.allCases
        .filter { saved >= $0.thresholdSeconds }
        .last
    guard let milestone = crossed else { return nil }

    // If donationCardState is .unseen and they haven't crossed the
    // FIRST milestone yet → use existing semantics (no prompt).
    // If they've crossed any milestone they've already dismissed:
    //   - need 90 days since dismiss AND a new higher milestone
    if let lastDismissAt = donationMilestoneTracker.dismissedAt[milestone.thresholdSeconds] {
        let cooldownElapsed = Date().timeIntervalSince(lastDismissAt) > (90 * 86400)
        let higherMilestoneAvailable = saved >= (milestone.next?.thresholdSeconds ?? .infinity)
        return cooldownElapsed && higherMilestoneAvailable ? milestone.next : nil
    }

    return milestone
}
```

### Milestone list (revised)

Original draft proposed `[30m, 2h, 5h, 10h]`. Adversarial review correctly flagged:
- 30m is too aggressive — first-week users haven't decided whether to keep the app yet.
- 10h was previously rejected as "too aspirational."

**Revised list (respecting prior decisions):**

```swift
enum DonationCardMilestone: CaseIterable {
    case h2     // 2h — matches existing donationThresholdSeconds
    case h10    // 10h — re-prompt for engaged users
    case h25    // 25h — re-prompt for power users
}
```

- 2h: the existing first-prompt threshold (no change to the first-show behavior).
- 10h: respectful of the prior "10h is too aspirational as a *first* prompt" decision — it's still a fine threshold for a *re-prompt* in a multi-stage model, because the user has already engaged with the card once and not been turned off.
- 25h: a power-user threshold; the user has clearly built dictation into their workflow.

Each re-prompt requires both: 90-day cooldown since prior dismiss AND threshold crossed.

### Card copy variants

The existing card's "Jot is genuinely free" framing stays. For re-prompts, add a milestone-specific headline:

| Milestone | Headline copy |
|---|---|
| 2h (first ask, existing) | unchanged from current `DonationCard` |
| 10h (re-prompt) | *"Jot has saved you about 10 hours."* |
| 25h (re-prompt) | *"Jot has saved you about 25 hours."* |

The "Not now" + "See donations" buttons stay (existing layout). No removal of the existing two-button shape — the original draft's "tap-anywhere + × dismiss + long-press menu" was a new design that didn't read the existing UI.

### Persistence migration

Adding new field; no destructive change. `donationCardState` continues to be the terminal-state flag. The new `donationMilestoneTracker` starts empty on existing installs. First-time behavior for an upgrading user who has already dismissed at 2h:

- `donationCardState == .dismissed`, `donationMilestoneTracker == empty`
- On show-logic eval after upgrade, the code can't tell whether that 2h dismiss was last week or last year. Two options:
  - (a) Treat the upgrade as "fresh dismiss" — populate `dismissedAt[2h] = .now`. Effectively delays the 10h re-prompt by 90 days from the upgrade.
  - (b) Treat it as "ancient dismiss" — populate `dismissedAt[2h] = Date(timeIntervalSince1970: 0)`. Allows the 10h re-prompt to fire as soon as the user crosses 10h.
- **Recommendation: (a).** Safer; never surprises a user with a sudden re-prompt on upgrade. Per the existing code's "friendliness" framing.

### Never-ask-again UX

Existing card has no never-ask-again option — `.dismissed` is the only "no" path. The plan adds a long-press affordance:

- Long-press on the card → context menu with one item: **"Never show again."**
- Tap → sets `donationMilestoneTracker.neverAskAgain = true` → card disappears.
- Implementation: SwiftUI `.contextMenu { ... }` modifier on the card view.

The long-press is **additive** — not replacing the existing `.dismissed` flow. Quick dismiss is still the primary path.

### features.md updates

Two updates needed:

1. **Add §1.12 Donation Milestone Card** — documenting the existing + new behavior in one entry. Cross-link from §1.1 (Editorial Header, since the card sits above the recents list) and §6.7 (Donations, since the card is the entry point).
2. **Update §6.7** — add a sentence noting the home-screen card surfaces the Donations screen at thresholds; back-link to §1.12.

The plan's earlier "no features.md update" gap is corrected here.

---

## Implementation Outline

| Component | Location | Work |
|---|---|---|
| Milestone enum + tracker struct | `Jot/Shared/DictationStats.swift` | Additive. ~40 LOC. |
| `shouldShowDonationCard` → `donationCardMilestone` | `Jot/Shared/DictationStats.swift` | Replace bool with optional enum; update callers. |
| Card headline binding | `Jot/App/Donation/DonationCard.swift` | Accept milestone parameter, pick headline. |
| Long-press context menu | `Jot/App/Donation/DonationCard.swift` | Add `.contextMenu { ... }`. |
| ContentView call-site | `Jot/App/ContentView.swift:191-196` | Pass milestone into card. |
| Upgrade-migration sentinel | `Jot/Shared/DictationStats.swift` initial-read code | Detect "dismissed-without-tracker" once, stamp `dismissedAt[2h] = .now`. |
| features.md entries | `Jot/features.md` | Add §1.12, update §1.1 and §6.7. |
| Tests | `Jot/Tests/DictationStatsTests.swift` | Show-logic permutations. |

**Total size: S** (~1 day).

---

## Edge Cases

- **User dismisses at 2h, then crosses 10h before 90 days elapse.** No re-prompt — must wait 90 days from dismiss timestamp. Test 2 covers.
- **User who is already `donationCardState == .donated`** never sees re-prompts. Terminal state respected.
- **iOS Settings → clear Jot data.** All UserDefaults reset → state machine + tracker both back to initial → existing single-shot logic re-engages.
- **Time-saved tracker grows past 25h with no dismissals (user never opens home screen).** When they finally do, show the highest milestone they qualify for (25h). Don't backshow earlier milestones.
- **`totalSeconds` is recorded but `timeSavedMultiplier` is applied for headline display.** Recommend: use raw `totalSeconds` for the threshold check (matches existing code), but display the multiplier-applied number in the headline ("saved you N hours"). The threshold is internal logic; the user sees the friendly figure.
- **Card surface treatment.** Existing card uses `RoundedRectangle.fill(Color.jotInk.opacity(0.04))` + 0.5pt stroke — **not** Liquid Glass. Original draft incorrectly claimed Liquid Glass. Keep existing styling unchanged.
- **VoiceOver.** Existing two-button layout is already accessible (each button is announced separately). Adding long-press → context menu adds a new accessibility-action — the SwiftUI `.contextMenu` modifier handles this via the "Actions" rotor.

---

## Test Plan

1. Fresh install, totalSeconds = 0 → no card.
2. totalSeconds = 1h → no card.
3. totalSeconds = 2h → existing 2h card (unchanged behavior).
4. Dismiss the 2h card → `donationCardState = .dismissed`, `dismissedAt[2h] = .now`. Card gone.
5. Reopen home → no card.
6. Advance simulated `.now` by 89 days, totalSeconds = 11h → no card (cooldown not elapsed).
7. Advance simulated `.now` by 91 days, totalSeconds = 11h → 10h re-prompt card visible.
8. Dismiss the 10h card → `dismissedAt[10h] = .now`. Card gone.
9. Advance to totalSeconds = 26h, time + 91 days from 10h dismiss → 25h card.
10. Long-press card → "Never show again" → `neverAskAgain = true` → card gone permanently across all milestones.
11. User on `.donated` terminal state → no card ever.
12. Upgrade scenario: existing user already `.dismissed` at 2h → migration stamps `dismissedAt[2h] = .now` → no 10h prompt until 90 days from upgrade.
13. VoiceOver: card announced; long-press exposes "Never show again" as a rotor action.

---

## Open Questions

> Each question is explored with all alternative paths in [open-questions-deep-dive.md#d4--donation-milestone-card](./open-questions-deep-dive.md#d4--donation-milestone-card).

1. **Milestone list — 2h / 10h / 25h or different?** Confirm the recommendation. Alternatives: keep just 2h + 10h (two stages), or add a 50h stage for very long-term users.
2. **90-day cooldown OR longer / shorter?** 90 days is a sketch; could be 180 days for the "really don't nag" version. Confirm.
3. **Upgrade migration: option (a) "fresh dismiss" or (b) "ancient dismiss"?** Recommend (a). Confirm.
4. **Should the 10h+ re-prompt have different copy emphasis** (e.g. "It's been a while...")? Could feel personable but also creepy. Recommend: stick with the milestone-only headline, no time-since-dismiss copy.

---

## Cross-Links

- Existing code: `Jot/App/Donation/DonationCard.swift`, `Jot/Shared/DictationStats.swift:28-200`, `Jot/App/ContentView.swift:191-196`
- features.md updates required: new §1.12, update §1.1, update §6.7
- Memory ref: existing code's "unconditional don't-re-ask is friendlier than a webhook-backed confirmation" comment is the design constraint this plan respects via `.donated` terminal state + 90-day cooldowns
