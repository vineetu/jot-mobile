import SwiftUI
import UIKit

/// Generic v0.9 material card wrapper that gives content the redesign's
/// rounded glass surface, card padding, hairline border, highlight, and shadow.
struct LiquidGlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.liquidGlassShadowScale) private var shadowScale

    private let cornerRadius: CGFloat
    private let paddingH: CGFloat
    private let paddingV: CGFloat
    private let content: () -> Content

    init(
        cornerRadius: CGFloat = JotDesign.Spacing.cardRadiusV09,
        paddingH: CGFloat = JotDesign.Spacing.cardPaddingH,
        paddingV: CGFloat = JotDesign.Spacing.cardPaddingV,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.paddingH = paddingH
        self.paddingV = paddingV
        self.content = content
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark

        // Light: black hairline + small drop shadow + white top highlight
        //   — sits over the cool-gray wallpaper.
        // Dark: white hairline + omit the dark-on-dark drop shadow + brighter
        //   white top highlight — sits over the deep #15171C wallpaper. The
        //   material itself (regularMaterial) auto-adapts to dark; only the
        //   surrounding chrome (which is hand-rolled with literal black/white)
        //   needs adaptation here.
        let hairlineColor: Color = isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
        let highlightColor: Color = isDark
            ? Color.white.opacity(0.18)
            : Color.white.opacity(0.7)
        // Dark mode omits the drop shadow entirely; light mode's 0.30 can be
        // softened per-surface via `liquidGlassShadowScale` (Settings sets 0.5).
        let shadowOpacity: Double = (isDark ? 0.0 : 0.30) * shadowScale

        content()
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .background(.regularMaterial, in: shape)
            .overlay {
                shape
                    .strokeBorder(hairlineColor, lineWidth: 0.5)
            }
            .overlay {
                shape
                    .inset(by: 0.5)
                    .stroke(highlightColor, lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                                .frame(height: 2)
                            Spacer(minLength: 0)
                        }
                    }
            }
            .clipShape(shape)
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: 18,
                x: 0,
                y: 14
            )
    }
}

// MARK: - Shadow-scale environment

private struct LiquidGlassShadowScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    /// Multiplier on `LiquidGlassCard`'s light-mode drop-shadow opacity (default
    /// 1.0). Settings sets 0.5 to lighten its denser stack of cards. Dark mode
    /// already omits the shadow, so this only affects light mode.
    var liquidGlassShadowScale: Double {
        get { self[LiquidGlassShadowScaleKey.self] }
        set { self[LiquidGlassShadowScaleKey.self] = newValue }
    }
}

#Preview("Liquid Glass Card") {
    ZStack {
        Color.jotPageBase
            .ignoresSafeArea()

        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speech Model")
                    .font(JotType.rowTitle)
                    .foregroundStyle(Color.jotPageInk)
                Text("Ready for on-device dictation")
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(JotDesign.Spacing.pageGutter)
    }
}
