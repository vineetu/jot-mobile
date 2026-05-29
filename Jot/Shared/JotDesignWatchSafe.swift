import SwiftUI

/// Platform-agnostic subset of Jot's design tokens, safe to compile into
/// both the iOS app target AND the watchOS app + widget targets.
///
/// **Why this exists:** `Jot/App/Design/JotDesign.swift` imports `UIKit`
/// (for `UIColor` dynamic-provider blocks). UIKit isn't available on
/// watchOS, so the watch target can't link `JotDesign.swift` directly.
/// This file re-exports the same color values using SwiftUI `Color(red:,
/// green:, blue:)` literals — no `UIColor`, no `import UIKit`. iOS-side
/// callers can use either file; values are identical.
///
/// **Tokens covered:** the watch-app surface uses a deliberately narrow
/// subset. Coral CTAs (`jotAccent`), red live-recording cue (`jotRecord`
/// + `jotRecordingDot`), amber for pending-sync, plus the standard page
/// inks. No keyboard-blue, no semantic icon tile palette — those aren't
/// needed on watch.
///
/// **Single source of truth contract:** when adding or changing a color
/// here, also update `JotDesign.swift` to match exactly (and vice versa).
/// The values must stay synchronized; this file is not a fork.
enum JotDesignWatchSafe {
    // MARK: - Brand accents

    /// Coral CTA color. Mirrors `JotDesign.jotAccent` at
    /// `Jot/App/Design/JotDesign.swift:35`. Legacy — the actual brand
    /// CTA across iOS uses the blue gradient (`jotBlueTop` → `jotBlueBottom`)
    /// per `Jot/App/Design/Components/DictateFAB.swift`. Kept as a
    /// secondary accent token; new watch surfaces should prefer the
    /// blue gradient for primary CTAs to match the iOS brand.
    static let jotAccent = Color(red: 1.00, green: 0.42, blue: 0.36)

    /// Top stop of the brand blue gradient. Mirrors `JotDesign.jotBlueTop`
    /// at `Jot/App/Design/JotDesign.swift:622`. `#1A8CFF`. Used for the
    /// Dictate/mic CTAs to match the iOS DictateFAB.
    static let jotBlueTop = Color(red: 0x1A / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)

    /// Bottom stop of the brand blue gradient. Mirrors `JotDesign.jotBlueBottom`
    /// at `Jot/App/Design/JotDesign.swift:625`. `#0064CC`.
    static let jotBlueBottom = Color(red: 0x00 / 255.0, green: 0x64 / 255.0, blue: 0xCC / 255.0)

    /// Distinct from `jotAccent` so a recording state never reads as a
    /// generic CTA. Mirrors `JotDesign.jotRecord` at
    /// `Jot/App/Design/JotDesign.swift:39`. Used on the watch's Stop
    /// button while recording.
    static let jotRecord = Color(red: 1.00, green: 0.23, blue: 0.19)

    /// Pulsing-dot red — slightly darker than `jotRecord` so the dot
    /// reads as alive against the Stop button. Mirrors
    /// `JotDesign.jotRecordingDot` at `Jot/App/Design/JotDesign.swift:677`.
    /// Used for the watch's live-recording dot indicator.
    static let jotRecordingDot = Color(red: 0xE0 / 255.0, green: 0x17 / 255.0, blue: 0x3B / 255.0)

    /// Soft halo behind the recording dot. Mirrors
    /// `JotDesign.jotRecordingHalo` at `Jot/App/Design/JotDesign.swift:680`.
    static let jotRecordingHalo = Color(red: 0xE0 / 255.0, green: 0x17 / 255.0, blue: 0x3B / 255.0).opacity(0.18)

    /// Amber accent for pending-sync state indicators. Resolves to the
    /// system `.orange` Color (consistent with iOS's warning palette).
    /// Spec'd as a named token rather than inline `.orange` so the watch
    /// design language stays explicit + searchable.
    static let jotPendingAmber = Color.orange

    /// Success green for the "Just synced" ribbon and synced indicators.
    /// Resolves to system `.green`.
    static let jotSyncSuccess = Color.green

    // MARK: - Page inks (light/dark adaptive)
    //
    // The `Color.primary` / `Color.secondary` semantic colors handle most
    // of what we need; defining them here as named tokens keeps the watch
    // call sites readable and ensures any future override is centralized.

    /// Primary text color. Adapts to light/dark via `Color.primary`.
    static let jotPageInk = Color.primary

    /// Subtitle text color. Adapts to light/dark via `Color.secondary`.
    static let jotPageInkSecondary = Color.secondary

    /// Caption / fine-print color. Use `.foregroundStyle(.tertiary)` at
    /// the call site if you want this; the token alias is for parity
    /// with the iOS design system naming.
    static let jotPageInkCaption = Color.secondary.opacity(0.8)

    // MARK: - Watch surface tokens (added build 49)
    //
    // Watch-native echoes of the iOS `LiquidGlassCard` / `IconTile` /
    // `SectionLabel` system. Tuned for 40mm + 45mm AMOLED — tighter
    // padding than iOS, no shadow (smudges on true-black backdrop),
    // no `.regularMaterial` (UIKit-only).

    /// Card corner radius. Softer than iOS's 16 — smaller surface,
    /// smaller radius reads cleaner at watch scale.
    static let watchCardRadius: CGFloat = 12

    /// Horizontal inset inside a `WatchCard`.
    static let watchCardPaddingH: CGFloat = 10

    /// Vertical inset inside a `WatchCard`.
    static let watchCardPaddingV: CGFloat = 8

    /// Page-level horizontal gutter for the root scroll surface.
    static let watchPageGutter: CGFloat = 8

    /// Vertical spacing between sibling rows in a scrollable page.
    static let watchRowSpacing: CGFloat = 6

    /// Hairline border for `WatchCard`. Adaptive via `Color.primary`
    /// opacity so it reads in both light and dark.
    static let watchHairline = Color.primary.opacity(0.10)

    /// Inside-card top highlight. Currently unused but reserved for a
    /// future inset-highlight stroke if `WatchCard` reads as too flat.
    static let watchHighlight = Color.white.opacity(0.06)

    /// `WatchCard` fill — slightly translucent over the system black/
    /// white page background. No `.regularMaterial` (iOS-only and too
    /// heavy on watchOS).
    static let watchCardFill = Color.primary.opacity(0.06)

    /// Muted utility row tint (used by the buried "Sync diagnostics"
    /// footer row). Visibly de-emphasized vs. transcript rows so the
    /// user reads it as "below the fold of normal usage."
    static let watchUtilityInk = Color.secondary.opacity(0.65)
}
