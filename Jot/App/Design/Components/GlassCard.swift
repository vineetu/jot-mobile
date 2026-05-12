//
//  GlassCard.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §3.
//

import SwiftUI

/// Glass-surface tier exposed by `GlassCard`. Mirrors the cases of
/// `JotDesign.Surface`. Phase 1 punch-list FIX 4: `.key` is now exposed
/// because plan §3 names three card-shaped tiers (regular / heavy / key).
/// `.keyDim` is reachable via the underlying `JotDesign.Surface` directly
/// — the only consumer of the dimmed state is `KeyboardKeyView` (Phase 2),
/// which doesn't compose through `GlassCard`.
enum SurfaceTier {
    case regular
    case heavy
    case key

    var underlying: JotDesign.Surface {
        switch self {
        case .regular: return .regular
        case .heavy:   return .heavy
        case .key:     return .key
        }
    }
}

/// Rounded glass-material wrapper. Drop arbitrary content inside; the card
/// supplies the corner radius, padding, material fill, border, and shadow per
/// the tier.
///
/// ```swift
/// GlassCard(tier: .regular) {
///     Text("Hello, world")
/// }
/// ```
struct GlassCard<Content: View>: View {
    let tier: SurfaceTier
    let padding: CGFloat
    let content: () -> Content

    init(
        tier: SurfaceTier = .regular,
        padding: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tier = tier
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .modifier(tier.underlying.modifier(cornerRadius: JotDesign.Spacing.cardRadius))
    }
}
