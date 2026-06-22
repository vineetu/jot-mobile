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
/// subset. Blue brand CTAs (`jotAccent`), red live-recording cue (`jotRecord`
/// + `jotRecordingDot`), amber for pending-sync, plus the standard page
/// inks. No keyboard-blue, no semantic icon tile palette — those aren't
/// needed on watch.
///
/// **Single source of truth contract:** when adding or changing a color
/// here, also update `JotDesign.swift` to match exactly (and vice versa).
/// The values must stay synchronized; this file is not a fork.
enum JotDesignWatchSafe {
    // MARK: - Brand accents

    /// Brand accent (blue `#1A8CFF`). Mirrors `JotDesign.jotAccent` at
    /// `Jot/App/Design/JotDesign.swift:35`. Was coral historically; now the
    /// canonical blue accent matching the iOS brand. Coral survives only in
    /// the explicit `jotCoralTop`/`jotCoralBottom` tokens (Settings + AI).
    static let jotAccent = Color(red: 0x1A / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)

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

    // MARK: - Watch redesign heroes (2026 watch refresh)
    //
    // Round-hero gradients + glows for the Dictate (blue) and Recording
    // (coral) circles, plus the blue pill gradient. These are watch-only —
    // the iOS DictateFAB uses its own gradient — so they intentionally do
    // NOT mirror into `JotDesign.swift`. Hex values come straight from the
    // `design_handoff_watch_redesign` spec.

    /// Dictate hero radial fill. `#5BB4FF → #1B86F0 (52%) → #0061C8`,
    /// light source high (center y = 0.3) so the sphere reads lit from above.
    static let watchDictateHero = RadialGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 0x5B / 255.0, green: 0xB4 / 255.0, blue: 0xFF / 255.0), location: 0.0),
            .init(color: Color(red: 0x1B / 255.0, green: 0x86 / 255.0, blue: 0xF0 / 255.0), location: 0.52),
            .init(color: Color(red: 0x00 / 255.0, green: 0x61 / 255.0, blue: 0xC8 / 255.0), location: 1.0)
        ]),
        center: UnitPoint(x: 0.5, y: 0.3),
        startRadius: 0,
        endRadius: 96
    )

    /// Recording hero radial fill (coral). `#FF8E7A → #FF6B57 (52%) → #E0533F`.
    static let watchRecordHero = RadialGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 0xFF / 255.0, green: 0x8E / 255.0, blue: 0x7A / 255.0), location: 0.0),
            .init(color: Color(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x57 / 255.0), location: 0.52),
            .init(color: Color(red: 0xE0 / 255.0, green: 0x53 / 255.0, blue: 0x3F / 255.0), location: 1.0)
        ]),
        center: UnitPoint(x: 0.5, y: 0.3),
        startRadius: 0,
        endRadius: 96
    )

    /// Coral waveform bar color while recording. `#FF6B57` — matches the
    /// record hero so the level meter reads as part of the same moment
    /// (replaces the old blue `jotAccent` bars).
    static let watchRecordWave = Color(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x57 / 255.0)

    /// Soft glow behind the Dictate hero. `#1A8CFF @ 0.30`.
    static let watchDictateGlow = Color(red: 0x1A / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0).opacity(0.30)

    /// Soft glow behind the Recording hero. `#FF6B57 @ 0.32`.
    static let watchRecordGlow = Color(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x57 / 255.0).opacity(0.32)

    /// Full-width blue pill gradient (Reset sync). `168°: #3AA0FF → #1483F2 → #0064CC`.
    /// SwiftUI has no angle param on `LinearGradient`; 168° ≈ top→bottom with a
    /// slight lean, approximated topLeading→bottomTrailing.
    static let jotBlueGrad = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 0x3A / 255.0, green: 0xA0 / 255.0, blue: 0xFF / 255.0), location: 0.0),
            .init(color: Color(red: 0x14 / 255.0, green: 0x83 / 255.0, blue: 0xF2 / 255.0), location: 0.5),
            .init(color: Color(red: 0x00 / 255.0, green: 0x64 / 255.0, blue: 0xCC / 255.0), location: 1.0)
        ]),
        startPoint: .top,
        endPoint: .bottom
    )

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
