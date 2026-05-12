//
//  JotDesign.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §2.
//
//  Top-level namespace for color tokens, typography, spacing, and the
//  three+ glass-surface tiers used across the app + keyboard extension.
//  Pure infrastructure: no integration into existing surfaces yet.
//
//  Custom font note (CODEX-CAUGHT, Phase-1 punch-list revisited):
//  Fraunces ships only optical-size-keyed static TTFs. The Google Fonts
//  Fraunces repo (`googlefonts/fraunces`, branch `master`,
//  `fonts/static/ttf/`) provides three opsz cuts: 9pt, 72pt, 144pt.
//  There is no 14pt opsz static (the plan asked for 14pt). We use:
//    - Fraunces 72pt-opsz for the display sizes (24-38pt).
//    - Fraunces 9pt-opsz Italic for the 19pt body italic — 9pt is the
//      text-optimised cut and reads correctly at 19pt without the
//      tall-x-height / tight-spacing of the 72pt display italic.
//  Fraunces also ships no Medium (500) static cut — the lightest "above
//  Regular" weight in the static set is SemiBold (600). We therefore
//  expose the SemiBold cut under the honest name `frauncesSemiBold`
//  (was previously aliased as `frauncesMedium` — fixed in Phase 1
//  punch list FIX 2).
//

import SwiftUI
import UIKit

// MARK: - Color tokens

extension Color {
    /// `#FF6B5C` — Rewrite + Dictate + recent-marker. The single brand accent.
    static let jotAccent = Color(red: 1.00, green: 0.42, blue: 0.36)

    /// `#FF3B30` — recording dot, stop button, draft caret. System red, kept distinct
    /// from `jotAccent` so a recording state never reads as a generic CTA.
    static let jotRecord = Color(red: 1.00, green: 0.23, blue: 0.19)

    /// `#1C1C1E` — primary editorial text.
    static let jotInk = Color(red: 0.11, green: 0.11, blue: 0.12)

    /// `#8B8B95` — secondary text, sub-labels.
    static let jotMute = Color(red: 0.55, green: 0.55, blue: 0.58)

    /// `#C7C7CC` — chevrons, dividers.
    static let jotMuteWeak = Color(red: 0.78, green: 0.78, blue: 0.80)

    /// `#34C759` — system green for status pills, AI-ready toast.
    static let jotSuccess = Color(red: 0.20, green: 0.78, blue: 0.35)

    /// `#1B8E3E` — darker green for text/ink on top of a green-tinted background.
    static let jotSuccessInk = Color(red: 0.11, green: 0.56, blue: 0.24)

    /// `#FF9F30` — system orange-ish, used for `StatusPill` warning dot/border.
    /// Phase 1 punch-list FIX 8: replaces ad-hoc `Color(red:green:blue:)` calls
    /// that were sitting inside `StatusPill.swift`.
    static let jotWarning = Color(red: 1.00, green: 0.62, blue: 0.18)

    /// `#B87314` — darker amber for warning text on top of warning-tinted background.
    static let jotWarningInk = Color(red: 0.72, green: 0.45, blue: 0.08)

    // MARK: - Keyboard retheme v2 (2026-05-11, iOS-system-gray + dark mode)
    //
    // v2 strategy: chrome matches iOS system gray (the color of the
    // iOS-rendered bottom system bar — which we don't control). The seam
    // disappears. Cards use Liquid Glass over gray. Recording state adds
    // a subtle blue overlay tint on top of the same gray chrome — not a
    // separate gradient — so the surface still reads "neutral keyboard"
    // rather than "blue editorial". Every token below is adaptive: each
    // resolves to a light-mode value or a dark-mode value based on the
    // effective scheme (SwiftUI's `colorScheme` env OR the host's
    // `keyboardAppearance` proxy hint, whichever says dark).
    //
    // Reference: `Jot/tmp/keyboard-retheme-v2-spec.md` for verbatim hex
    // values per surface.
    //
    // The Dictate pill keeps its hard-coded `#007AFF → #0064CC` gradient
    // in both modes — iOS blue reads cleanly on both gray backgrounds and
    // we want a single, recognizable CTA across light/dark.

    /// Idle chrome — top gradient stop. Matches the iOS system bar gray.
    ///   - light: `#D5D7DE`
    ///   - dark:  `#25252A`
    static let jotKeyboardChromeIdleTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 37/255, green: 37/255, blue: 42/255, alpha: 1.0)
            : UIColor(red: 213/255, green: 215/255, blue: 222/255, alpha: 1.0)
    })

    /// Idle chrome — bottom gradient stop. Matches the iOS system bar gray.
    ///   - light: `#C9CCD3`
    ///   - dark:  `#1A1A1D`
    static let jotKeyboardChromeIdleBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 26/255, green: 26/255, blue: 29/255, alpha: 1.0)
            : UIColor(red: 201/255, green: 204/255, blue: 211/255, alpha: 1.0)
    })

    /// Recording-state tint overlay. Layered ON TOP of the idle chrome —
    /// NOT a replacement gradient. Subtle blue wash signals "recording"
    /// without breaking the system-neutral feel.
    ///   - light: `rgba(0,122,255,0.06)`
    ///   - dark:  `rgba(10,132,255,0.10)`
    static let jotKeyboardChromeRecordingTint = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 10/255, green: 132/255, blue: 255/255, alpha: 0.10)
            : UIColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 0.06)
    })

    /// Recording-state top hairline. Only drawn while recording —
    /// idle has no hairline because the chrome already matches the
    /// system bar, no seam to hide.
    ///   - light: `rgba(0,122,255,0.10)`
    ///   - dark:  `rgba(10,132,255,0.18)`
    static let jotKeyboardChromeRecordingHairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 10/255, green: 132/255, blue: 255/255, alpha: 0.18)
            : UIColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 0.10)
    })

    /// Streaming + recents body text — soft navy that adapts to dark mode.
    ///   - light: `#3C5A99`
    ///   - dark:  `#9CB3E5`
    static let jotKeyboardStreamText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 156/255, green: 179/255, blue: 229/255, alpha: 1.0)
            : UIColor(red: 60/255, green: 90/255, blue: 153/255, alpha: 1.0)
    })

    /// Liquid Glass card top stop.
    ///   - light: `rgba(255,255,255,0.78)`
    ///   - dark:  `rgba(70,72,82,0.62)`
    static let jotKeyboardGlassFill1 = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 70/255, green: 72/255, blue: 82/255, alpha: 0.62)
            : UIColor(white: 1.0, alpha: 0.78)
    })

    /// Liquid Glass card bottom stop.
    ///   - light: `rgba(255,255,255,0.58)`
    ///   - dark:  `rgba(54,56,66,0.42)`
    static let jotKeyboardGlassFill2 = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 54/255, green: 56/255, blue: 66/255, alpha: 0.42)
            : UIColor(white: 1.0, alpha: 0.58)
    })

    /// Liquid Glass inset top highlight.
    ///   - light: `rgba(255,255,255,0.85)`
    ///   - dark:  `rgba(255,255,255,0.10)`
    static let jotKeyboardGlassHighlight = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(white: 1.0, alpha: 0.85)
    })

    /// Liquid Glass hairline border.
    ///   - light: `rgba(0,0,0,0.04)`
    ///   - dark:  `rgba(255,255,255,0.06)`
    static let jotKeyboardGlassHairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.06)
            : UIColor(white: 0.0, alpha: 0.04)
    })

    /// Legacy alias — retained so non-keyboard surfaces or any code
    /// referencing the prior `jotKeyboardSurface` token still compiles.
    /// New code should branch on idle vs recording chrome via the
    /// gradient-stop tokens above + the recording tint overlay.
    static let jotKeyboardSurface = Color.blue.opacity(0.06)

    /// Solid iOS system blue for the keyboard's Dictate CTA pill. `Color.blue`
    /// auto-adapts to `#007AFF` (light) / `#0A84FF` (dark) — exactly the
    /// spec's wand / dot / caret / waveform color in both modes.
    static let jotKeyboardAccent = Color.blue

    /// Deeper blue used as the Dictate / Stop pill's bottom gradient
    /// stop — `#0064CC` per spec. Stays the same in light + dark; iOS
    /// blue reads well on both gray chrome backgrounds.
    static let jotKeyboardAccentDeep = Color(red: 0/255, green: 100/255, blue: 204/255)

    // MARK: Key faces (v2 adaptive)
    //
    // Per spec, key surfaces have explicit light/dark hex values that
    // don't match `UIColor.keyboardButtonBackground` (system asset).
    // We hand-roll the adaptive pairs so the keyboard reads as a single
    // designed object instead of a system-default keyboard with
    // mismatched chrome.

    /// Punctuation + space + util key fill.
    ///   - light: `#FFFFFF`
    ///   - dark:  `rgba(110,114,126,0.42)`
    static let jotKeyboardKeyFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 110/255, green: 114/255, blue: 126/255, alpha: 0.42)
            : UIColor(white: 1.0, alpha: 1.0)
    })

    /// Punctuation key ink (the glyph color).
    ///   - light: `Color.jotInk` (#1C1C1E)
    ///   - dark:  `rgba(255,255,255,0.92)`
    static let jotKeyboardKeyInk = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.92)
            : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
    })

    /// Backspace key fill — a touch darker than punctuation so the
    /// modifier reads as "different role".
    ///   - light: `rgba(170,170,180,0.30)`
    ///   - dark:  `rgba(75,78,88,0.6)`
    static let jotKeyboardBackspaceFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 75/255, green: 78/255, blue: 88/255, alpha: 0.6)
            : UIColor(red: 170/255, green: 170/255, blue: 180/255, alpha: 0.30)
    })

    /// Space-bar label color. Lighter than the punctuation ink because
    /// the "space" word is a soft hint, not a primary glyph.
    ///   - light: `Color.jotMute` (#6B6B75)
    ///   - dark:  `rgba(255,255,255,0.6)`
    static let jotKeyboardSpaceLabel = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.6)
            : UIColor(red: 107/255, green: 107/255, blue: 117/255, alpha: 1.0)
    })

    /// Return key fill — softened blue in light, neutral gray in dark.
    /// Deliberately not the solid accent: the dictate pill owns "primary
    /// blue"; the return key reads as a tinted secondary action.
    ///   - light: `rgba(170,190,220,0.55)`
    ///   - dark:  `rgba(105,110,124,0.7)`
    static let jotKeyboardReturnFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 105/255, green: 110/255, blue: 124/255, alpha: 0.7)
            : UIColor(red: 170/255, green: 190/255, blue: 220/255, alpha: 0.55)
    })

    /// Return key label color.
    ///   - light: `Color.jotInk`
    ///   - dark:  white
    static let jotKeyboardReturnInk = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
    })

    /// Recents time-mono stamp color — muted, slightly transparent so
    /// the body text on the same row stays primary.
    ///   - light: `Color.jotMuteWeak` (≈ #C7C7CC)
    ///   - dark:  `rgba(255,255,255,0.4)`
    static let jotKeyboardTimeMute = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.4)
            : UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1.0)
    })

    /// Legacy pressed-state return tint — retained so any external call
    /// site that imported `jotKeyboardReturnTintPressed` still compiles.
    /// v2 derives pressed state at the call site via `.opacity(0.7)` on
    /// `jotKeyboardReturnFill`.
    static let jotKeyboardReturnTint = Color.blue.opacity(0.18)
    static let jotKeyboardReturnTintPressed = Color.blue.opacity(0.32)

    /// Soft-ink color for the Actions button label (`#3a3a45` light /
    /// `rgba(255,255,255,0.85)` dark). Adaptive so the Actions / wand /
    /// collapse-chevron glyphs read correctly against the dark chrome.
    static let jotKeyboardActionsInk = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.85)
            : UIColor(red: 58/255, green: 58/255, blue: 69/255, alpha: 1.0)
    })
}

// MARK: - Typography

/// Editorial + chrome typography tokens (plan §2.3).
///
/// Editorial faces use opsz-keyed Fraunces statics referenced by PostScript
/// name. The 72pt-opsz cut is used for display sizes (≥24pt); the 9pt-opsz
/// cut is used for the 19pt body italic so the strokes don't read as
/// over-contrasted at running-text size. Chrome faces fall through to the
/// system font (SF Pro) so they pick up Dynamic Type automatically.
enum JotType {

    // MARK: Fraunces PostScript names

    /// PostScript name of the bundled Fraunces 72pt-opsz Regular cut.
    static let frauncesRegular = "Fraunces72pt-Regular"

    /// PostScript name of the bundled Fraunces 72pt-opsz SemiBold cut.
    /// Fraunces ships no Medium (500) static — SemiBold (600) is the next
    /// weight up from Regular. Phase 1 punch-list FIX 2: renamed from
    /// `frauncesMedium` so the token doesn't lie about its weight.
    static let frauncesSemiBold = "Fraunces72pt-SemiBold"

    /// PostScript name of the bundled Fraunces 72pt-opsz Italic cut.
    /// Used by `editorialDisplay`/`editorialTitle`/`editorialBody` italic
    /// runs at display sizes (≥24pt). For body italic (19pt) use
    /// `frauncesItalicText` instead — its strokes are tuned for text size.
    static let frauncesItalic = "Fraunces72pt-Italic"

    /// PostScript name of the bundled Fraunces 9pt-opsz Italic cut.
    /// Phase 1 punch-list FIX 1: 19pt body italic was reading wrong at the
    /// 72pt-opsz cut (display-tuned strokes look spiky at running-text size).
    /// 9pt opsz is the text-optimised cut and reads correctly at 19pt.
    static let frauncesItalicText = "Fraunces9pt-Italic"

    // MARK: Editorial faces

    /// App home "Jot" — Fraunces 38pt SemiBold (72pt-opsz cut).
    static let editorialDisplay = Font.custom(frauncesSemiBold, size: 38)

    /// Transcript detail title — Fraunces 30pt SemiBold (72pt-opsz cut).
    static let editorialTitle = Font.custom(frauncesSemiBold, size: 30)

    /// Recording hero italic body — Fraunces 24pt Regular (72pt-opsz cut).
    static let editorialBody = Font.custom(frauncesRegular, size: 24)

    /// Rewrite output — Fraunces 19pt Italic (9pt-opsz text cut).
    static let editorialItalic = Font.custom(frauncesItalicText, size: 19)

    // MARK: Chrome faces (system / SF Pro)

    /// Default chrome body (rows, buttons, sheets). System body so Dynamic Type
    /// continues to work everywhere we use it.
    static let bodyChrome = Font.system(.body, design: .default)

    /// Chrome emphasis — semibold body for primary actions.
    static let chromeBold = Font.system(.body, design: .default).weight(.semibold)

    /// UPPERCASE section labels — 11pt bold (matches `SectionLabel`'s render).
    /// Apply `.tracking(JotDesign.Spacing.sectionLabelTracking)` at the call
    /// site (Font in SwiftUI doesn't carry tracking on its own).
    static let captionLabel = Font.system(size: 11, weight: .bold)

    /// Mono timestamp face — used in recents rows.
    static let monoTimestamp = Font.system(.caption, design: .monospaced)
}

// MARK: - Spacing + radii

extension JotDesign {

    /// Plan §2.4 spacing + radius numbers. Keep call sites referencing these
    /// constants so a single tweak ripples through every surface.
    enum Spacing {

        // MARK: Page-level margins

        /// 16pt — horizontal page margins.
        static let pageMargin: CGFloat = 16

        /// 12pt — vertical gap between stacked cards.
        static let cardGap: CGFloat = 12

        /// 20pt — vertical gap before the next section header.
        static let sectionGap: CGFloat = 20

        // MARK: Radii

        /// 16pt — corner radius for inline cards / rows.
        static let cardRadius: CGFloat = 16

        /// 24pt — corner radius for bottom-sheet headers and drawer chrome.
        static let sheetRadius: CGFloat = 24

        // MARK: Misc

        /// 0.6 — `.tracking(...)` value for the UPPERCASE section label
        /// (`0.06em` × 10pt baseline ≈ 0.6pt).
        static let sectionLabelTracking: CGFloat = 0.6

        /// 5pt — diameter of the LED dot on a `StatusPill`.
        static let statusDotDiameter: CGFloat = 5

        /// 28pt — pill height for `StatusPill`. Sub-44pt by design — hand-roll
        /// the glass, do not use `.glassEffect(...)`.
        static let statusPillHeight: CGFloat = 28

        /// Horizontal padding inside a `StatusPill` (plan §2.4 / §3 spec: 8×4).
        static let statusPillPaddingH: CGFloat = 8

        /// Vertical padding inside a `StatusPill` (plan §2.4 / §3 spec: 8×4).
        static let statusPillPaddingV: CGFloat = 4
    }
}

// MARK: - Background gradient token

extension JotDesign {

    /// Phase 1 punch-list FIX 9: page-level background gradient previously
    /// hard-coded inside `JotDesignCatalog.swift`. Lives on the design
    /// namespace so any page chrome can opt into the same surface without
    /// re-deriving the stops.
    ///
    /// Two-stop light-grey gradient — top `#F5F5F5`, bottom `#E0E0E0` —
    /// matching the mockup's page background.
    static let background = LinearGradient(
        colors: [Color(white: 0.96), Color(white: 0.88)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - JotDesign namespace + surface tiers

/// Top-level namespace per plan §2 — colors live on `Color`, types live on
/// `JotType`, but spacing + surface modifiers hang off this enum so callers
/// can dot-complete from one place at the use site.
enum JotDesign {

    /// Glass-surface tiers (plan §2.2). Apply via `.modifier(JotDesign.Surface.regular.modifier(cornerRadius:))`
    /// or — more ergonomically — via the `GlassCard` wrapper view.
    ///
    /// - `regular`: cards, recents strip, drawer dividers. iOS 26 Glass, 0.5pt border, soft shadow.
    /// - `heavy`: action bars, bottom sheets, picker drawers. iOS 26 Glass with a heavier border + shadow stack.
    ///   (Apple's iOS 26 `Glass` struct exposes only `.regular`, `.clear`, `.identity` — there is no
    ///   `.thick` tier; we get the "heavier" feel from the border/shadow stack on top of the same Glass.)
    /// - `key`: keyboard key chrome. Hand-rolled gradient (no `.glassEffect()` — sub-44pt blurs to mush).
    /// - `keyDim`: dimmed/disabled key state.
    enum Surface {
        case regular
        case heavy
        case key
        case keyDim

        /// Returns a ready-to-apply `ViewModifier` for this tier at the given corner radius.
        ///
        /// Glass tiers (`regular`, `heavy`) use the iOS 26 `.glassEffect(_:in:)` API
        /// (deployment target is iOS 26.0). Key tiers (`key`, `keyDim`) stay
        /// hand-rolled gradients per plan §2.2 — sub-44pt glass blurs to mush.
        func modifier(cornerRadius: CGFloat = JotDesign.Spacing.cardRadius) -> some ViewModifier {
            SurfaceModifier(tier: self, cornerRadius: cornerRadius)
        }
    }
}

// MARK: - SurfaceModifier (fileprivate — wrapped by GlassCard / call-site .modifier)

/// Phase 1 punch-list FIX 7: scoped `fileprivate` so it doesn't leak into the
/// module API. Callers go through `JotDesign.Surface.modifier(...)` or the
/// `GlassCard` wrapper view instead of touching `SurfaceModifier` directly.
fileprivate struct SurfaceModifier: ViewModifier {
    let tier: JotDesign.Surface
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch tier {
        case .regular:
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 4)
        case .heavy:
            // iOS 26 Glass has no `.thick` accessor — the heavier feel comes from
            // a stronger border + deeper shadow on top of `.regular` glass.
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 8)
        case .key:
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.92),
                                    Color.white.opacity(0.78)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(
                    // 1pt top inset highlight
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(Color.white.opacity(0.7), lineWidth: 0.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
        case .keyDim:
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.white.opacity(0.42)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
        }
    }
}

// MARK: - Active rewrite model display name

extension JotDesign {
    /// Plan §11 — single source for the rewrite-model name surfaced in UI.
    /// Backend currently ships Phi-4 mini; mockup names "Gemma 4 2B". Keep the
    /// UI honest with the active provider until the backend swaps.
    static let activeRewriteModelDisplayName = "Phi-4 mini"

    /// Plan §6.3 / §10 — single source for the user-facing on-disk size of
    /// the active rewrite model. Surfaced in the download pitch sheet, the
    /// AI Rewrite settings page, and the download banner. Update here when
    /// the active provider's download size changes; all surfaces follow.
    static let activeRewriteModelSize: String = "2.4 GB"

    /// Numeric form of `activeRewriteModelSize` used for byte-progress
    /// math in the download banner ("0.9 of 2.4 GB").
    static let activeRewriteModelSizeGB: Double = 2.4
}
