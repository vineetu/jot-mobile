//
//  IconBox.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §3.
//

import SwiftUI

/// 36pt or 44pt rounded-square gradient tile with an SF Symbol centered inside.
/// Used by settings rows, picker rows, the AI download pitch sheet, etc.
///
/// `tint` controls the gradient stops — passed in by the caller so each row
/// (Speech model = teal, Vocabulary = teal, AI = coral, etc.) reads as a
/// distinct surface without us hard-coding a palette in the component itself.
struct IconBox: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    init(symbol: String, tint: Color, size: CGFloat = 36) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    private var cornerRadius: CGFloat {
        // 36pt tile → 10pt radius, 44pt tile → 12pt radius. Continuous curve.
        size >= 44 ? 12 : 10
    }

    private var symbolFont: Font {
        // ~52% of the tile feels right for an SF Symbol bubble.
        .system(size: size * 0.52, weight: .semibold)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.92),
                            tint.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Subtle top inset highlight for the glass feel.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: symbol)
                .font(symbolFont)
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.25), radius: 4, x: 0, y: 2)
    }
}
