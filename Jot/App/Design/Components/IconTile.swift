import SwiftUI

/// Semantic v0.9 icon tile for settings and wizard rows, using caller-supplied
/// design-token color pairs from `JotDesign.JotSemanticIcon`.
struct IconTile: View {
    private let systemImage: String
    private let tint: Color
    private let shaded: Color
    private let size: CGFloat

    init(
        systemImage: String,
        tint: Color,
        shaded: Color,
        size: CGFloat = JotDesign.Spacing.tileRowSize
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.shaded = shaded
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)

        ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: [tint, shaded],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            shape
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                .blendMode(.plusLighter)

            shape
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
    }
}

#Preview("Icon Tile") {
    HStack(spacing: 14) {
        IconTile(
            systemImage: "waveform",
            tint: JotDesign.JotSemanticIcon.speechModel,
            shaded: JotDesign.JotSemanticIcon.speechModelShaded
        )

        IconTile(
            systemImage: "sparkles",
            tint: JotDesign.JotSemanticIcon.ai,
            shaded: JotDesign.JotSemanticIcon.aiShaded,
            size: JotDesign.Spacing.tileHeroSize
        )
    }
    .padding()
    .background(Color.jotPageBase)
}
