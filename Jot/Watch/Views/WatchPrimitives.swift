import SwiftUI
import WatchKit

// MARK: - WatchMetrics

/// Screen-proportional sizing for the watch UI. The handoff's absolute sizes
/// (132 hero) are a 2× pixel *suggestion*, not a fixed point value — a literal
/// 116–132pt crowds the 40mm case and looks oversized on 44mm. Instead we size
/// the hero as a fraction of the real screen width so it reads dominant-but-
/// balanced on every case (40mm ≈ 162pt … 49mm Ultra ≈ 205pt).
@MainActor
enum WatchMetrics {
    /// Dictate / record hero diameter: ~50% of screen width, clamped to a sane
    /// band. 40mm→~80, 41mm→~88, 44mm→~92, 45mm→~99, 49mm→~103.
    static var heroDiameter: CGFloat {
        let w = WKInterfaceDevice.current().screenBounds.width
        return min(max(w * 0.50, 78), 104)
    }

    /// Mic glyph point size inside the dictate hero.
    static var heroGlyph: CGFloat { (heroDiameter * 0.38).rounded() }

    /// Recording timer point size inside the record hero (matches the handoff's
    /// 34/132 ≈ 0.26 ratio so it stays prominent at any hero size).
    static var heroTimer: CGFloat { (heroDiameter * 0.27).rounded() }
}

// MARK: - WatchCard

/// Watch-native echo of the iOS `LiquidGlassCard`.
///
/// Single layered fill + hairline border. No `.regularMaterial`, no
/// multi-layer blurs, no drop shadow — watchOS AMOLED can't render any
/// of those cleanly, and a 40mm tile is too small to host the iOS
/// card's full visual stack. ~5x cheaper to render than a port of
/// `LiquidGlassCard` would be.
///
/// Use as the standard "grouped surface" wrapper on the watch — frames
/// related rows the same way `LiquidGlassCard` does on iOS.
struct WatchCard<Content: View>: View {
    var paddingH: CGFloat = JotDesignWatchSafe.watchCardPaddingH
    var paddingV: CGFloat = JotDesignWatchSafe.watchCardPaddingV
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: JotDesignWatchSafe.watchCardRadius,
                    style: .continuous
                )
                .fill(JotDesignWatchSafe.watchCardFill)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: JotDesignWatchSafe.watchCardRadius,
                    style: .continuous
                )
                .strokeBorder(JotDesignWatchSafe.watchHairline, lineWidth: 0.5)
            )
    }
}

// MARK: - WatchSectionLabel

/// Watch-native echo of the iOS `SectionLabel`. UPPERCASE caption2,
/// tracking 1.0, secondary color. Marks the boundary between regions
/// of the root scroll surface.
struct WatchSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.0)
            .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - WatchUtilityRow

/// Single-row utility entry — used for "Sync diagnostics" footer link
/// at the bottom of the root scroll. Deliberately low-contrast (uses
/// `watchUtilityInk`) so the user reads it as "below the fold of normal
/// usage." Full-width tap target via `.contentShape(Rectangle())`.
struct WatchUtilityRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
            Text(title)
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.watchUtilityInk)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - WatchTranscriptRow

/// Single transcript row — used both inline on `RootView` and inside
/// `RecentTranscriptsView`'s card. Same content as the prior private
/// `TranscriptRow` in `RecentTranscriptsView`, with `.contentShape`
/// applied so the tap region covers the full row width (defensive
/// against the hit-test gap that mis-routed taps in build 46-48).
struct WatchTranscriptRow: View {
    let transcript: WatchTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transcript.preview)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                Text(transcript.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                if transcript.source == "watch" {
                    Image(systemName: "applewatch")
                        .font(.caption2)
                        .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                }
            }
        }
        .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
        .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - WatchSurfaceCard (redesign)

/// Translucent rounded card used by the redesigned per-note cells.
/// Light-on-true-black gradient fill + a hairline edge, radius 22 to match
/// the handoff. Distinct from `WatchCard` (which groups multiple rows with
/// internal dividers); the redesign uses **one card per note** with an 8pt
/// gap between them.
private struct WatchSurfaceCard: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Apply the redesigned translucent note-card surface (radius 22).
    func watchSurfaceCard(radius: CGFloat = 22) -> some View {
        modifier(WatchSurfaceCard(radius: radius))
    }
}

// MARK: - WatchHeroCircle (redesign)

/// The big round hero used for Dictate (blue) and Recording (coral). A
/// radial-gradient sphere with a soft colored glow behind it, a top
/// highlight rim, and a slow `breathe` scale loop. Breathing is disabled
/// under Reduce Motion or Always-On Display (luminance-reduced) — the
/// sphere then sits static.
///
/// `content` is overlaid centered (the mic glyph for Dictate, the running
/// timer for Recording). Press feedback is supplied by the caller via
/// `HeroPressStyle` on the enclosing `Button`.
struct WatchHeroCircle<Content: View>: View {
    let fill: RadialGradient
    let glow: Color
    /// Dominant but safe on the smallest shipping watch (40mm ≈ 162pt wide).
    /// The handoff's 132 is at 2× pixel scale; 116pt + a tight glow keeps the
    /// bloom from clipping at the screen edge.
    var diameter: CGFloat = 116
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Freeze the breathe under Reduce Motion or Always-On Display.
    private var staticVisuals: Bool { reduceMotion || isLuminanceReduced }

    /// Seconds per full breathe cycle (in → out). 3.0s — 20% faster than the
    /// original 3.6s, per owner preference.
    private let period: Double = 3.0

    var body: some View {
        // Drive the breathe off the frame clock via `TimelineView`, NOT an
        // `onAppear` + `repeatForever` toggle. Computing scale/opacity from
        // `context.date` every frame means the loop CANNOT fail to start, can't
        // be dropped on first appearance, and survives living inside a `List`
        // row (where lazy row recycling broke the state-toggle form on device —
        // the "breathe isn't there" report). `paused:` freezes it for Reduce
        // Motion / AOD.
        TimelineView(.animation(paused: staticVisuals)) { context in
            let phase = staticVisuals ? 0.0 : breathePhase(at: context.date)
            // Sphere grows ~6%; the glow swells ~18% and brightens — so it
            // reads as "glowing AND growing," not a barely-there scale.
            let sphereScale = 1.0 + 0.06 * phase
            let glowScale = 0.92 + 0.18 * phase
            let glowOpacity = 0.62 + 0.38 * phase

            ZStack {
                // Soft radial glow bleeding past the sphere edge.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [glow, Color.clear]),
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter * 0.78
                        )
                    )
                    .frame(width: diameter + 60, height: diameter + 60)
                    .blur(radius: 8)
                    .scaleEffect(glowScale)
                    .opacity(glowOpacity)

                // The lit sphere.
                Circle()
                    .fill(fill)
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                    )
                    .overlay(content())
                    .frame(width: diameter, height: diameter)
                    .shadow(color: glow, radius: 16)
                    .scaleEffect(sphereScale)
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
    }

    /// 0…1 eased breathe phase from the wall clock (smooth sine, no easing
    /// discontinuity at the loop seam).
    private func breathePhase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2 * .pi / period) + 1) / 2
    }
}

/// Press-down scale for the hero buttons (0.95). Separate from the breathe
/// loop so the two compose cleanly.
struct HeroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - List card background (redesign)

/// The translucent rounded card used as a `List` row background, with a
/// small inset so adjacent cards read as separate tiles with a gap. Pair
/// with `.listRowBackground(WatchListCard())` + `.listRowSeparator(.hidden)`.
struct WatchListCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            )
            .padding(.vertical, 3)
    }
}

// MARK: - WatchNoteCell + WatchPendingCell (redesign, List-row content)

/// A single transcript's row content (the `List` row provides the card via
/// `.listRowBackground(WatchListCard())`).
struct WatchNoteCell: View {
    let transcript: WatchTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(transcript.preview)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                Text(transcript.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 13))
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                if transcript.source == "watch" {
                    Image(systemName: "applewatch")
                        .font(.caption2)
                        .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A non-synced recording's row content: a leading play/stop affordance
/// (tap the row to hear the queued `.m4a`), the "Waiting to sync" status,
/// the relative capture time, and a trailing amber dot. Swipe-to-delete +
/// tap-to-play are wired at the `List` call site. The `List` row provides
/// the card via `.listRowBackground(WatchListCard())`.
struct WatchPendingCell: View {
    let item: WatchPendingItem
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(JotDesignWatchSafe.jotBlueTop.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(JotDesignWatchSafe.jotBlueTop)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isPlaying ? "Playing…" : "Waiting to sync")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(item.capturedAt, format: .relative(presentation: .named))
                    .font(.system(size: 13))
                    .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isPlaying ? "Playing" : "Waiting to sync"), \(item.capturedAt.formatted(.relative(presentation: .named))). Tap to play, swipe left to delete.")
    }
}

// MARK: - WatchPillButton (redesign)

/// Full-width blue gradient pill (used for Reset sync). Mirrors the
/// handoff's `Pill`.
struct WatchPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(JotDesignWatchSafe.jotBlueGrad))
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - WatchInlineDivider

/// Thin 0.5pt divider for stacked rows inside a `WatchCard`. Adaptive
/// via `Color.primary.opacity(...)` so it reads in both schemes.
struct WatchInlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}
