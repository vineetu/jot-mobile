import SwiftUI

/// Reusable v0.9 wallpaper layer for every app surface, with a neutral page
/// base (`Color.jotPageBase`, matches the keyboard chrome), three soft radial
/// ambient gradients per the design handoff, and an optional recording-state
/// tint wash applied on top.
///
/// Use `WallpaperBackground.recordingTint()` as the `tintOverlay` parameter
/// on the in-app recording surface — that produces the `rgba(0,122,255,0.06)`
/// blue wash Reference v3 calls for.
///
/// Access is module-internal (consistent with the other Phase 1 components);
/// the whole module is the single Jot app target, so `public` would be noise.
struct WallpaperBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private let tintOverlay: Color?

    init(tintOverlay: Color? = nil) {
        self.tintOverlay = tintOverlay
    }

    /// Recording-state blue tint per Reference v3: `rgba(0,122,255,0.06)`.
    /// Pass into `WallpaperBackground(tintOverlay:)` on the in-app recording
    /// surface.
    ///
    /// NOTE: This literal `#007AFF` is intentional and is NOT the semantic
    /// `Color.jotBlueTop` token (`#1A8CFF`). The Reference v3 design handoff
    /// specifies this exact system-blue value for the recording wash; using
    /// `jotBlueTop` here would shift the hue.
    static func recordingTint() -> Color {
        Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255).opacity(0.06)
    }

    var body: some View {
        ZStack {
            Color.jotPageBase

            if colorScheme == .dark {
                // Dark wallpaper drops the third radial entirely and uses two
                // higher-opacity blue radials at top-left and bottom-right
                // over a #15171C base (jotPageBase in dark).
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 31 / 255, green: 71 / 255, blue: 171 / 255).opacity(0.45),
                        .clear
                    ]),
                    center: UnitPoint(x: 0.20, y: 0.10),
                    startRadius: 0,
                    endRadius: 460
                )

                RadialGradient(
                    colors: [
                        Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255).opacity(0.30),
                        .clear
                    ],
                    center: UnitPoint(x: 0.90, y: 0.80),
                    startRadius: 0,
                    endRadius: 420
                )
            } else {
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255).opacity(0.18),
                        .clear
                    ]),
                    center: UnitPoint(x: 0.15, y: 0.10),
                    startRadius: 0,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [
                        Color(red: 255 / 255, green: 200 / 255, blue: 140 / 255).opacity(0.16),
                        .clear
                    ],
                    center: UnitPoint(x: 0.95, y: 0.95),
                    startRadius: 0,
                    endRadius: 460
                )

                RadialGradient(
                    colors: [
                        Color(red: 180 / 255, green: 200 / 255, blue: 240 / 255).opacity(0.30),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 1.0),
                    startRadius: 0,
                    endRadius: 480
                )
            }

            if let tintOverlay {
                tintOverlay
            }
        }
        .ignoresSafeArea()
    }
}

#Preview("Wallpaper Background") {
    HStack(spacing: 16) {
        WallpaperBackground()
            .overlay(alignment: .bottom) {
                Text("Default")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.jotPageInk)
                    .padding(8)
            }
            .frame(width: 150, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadiusV09, style: .continuous))

        WallpaperBackground(tintOverlay: WallpaperBackground.recordingTint())
            .overlay(alignment: .bottom) {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.jotPageInk)
                    .padding(8)
            }
            .frame(width: 150, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadiusV09, style: .continuous))
    }
    .padding()
    .background(Color.jotPageBase)
}
