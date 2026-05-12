import SwiftUI

/// Streaming-state top strip — rebuilt 2026-05-11 per
/// `Jot/tmp/keyboard-design-reference.html`.
///
/// Anatomy:
/// - Header row: blue pulsing recording dot (`#007AFF`, 8×8pt, 1.4s
///   ease-in-out) + SF-Mono timer (`#3C5A99`) + animated waveform
///   bars (6 vertical bars, blue, varying heights, 0.5-0.9 opacity).
///   The prior "..." placeholder + black amplitude-meter shimmer are
///   gone — the waveform is the spec.
/// - Streaming pane: fixed 154pt height Liquid Glass card with a
///   scrollable interior. Streaming text is `#3C5A99` at full
///   opacity (NO per-line opacity ladder), 13pt, line-height 1.55.
/// - Top-edge fade via `.mask(LinearGradient(...))` so older content
///   eases out as it scrolls off the top.
/// - Custom 3pt-wide blue scroll indicator on the right, always
///   visible during recording. Height + Y are bound proportionally
///   to viewport / content size.
/// - Auto-follow scroll: pins to bottom as new content streams. If
///   the user scrolls up manually, auto-follow pauses and a "↓ live"
///   pill appears at the bottom-right. Tapping the pill re-enables
///   auto-follow + scrolls to bottom.
/// - Blue caret (`#007AFF`, 2×14pt, 1s blink) at the trailing edge
///   of the newest line.
///
/// Read-only consumer of `streamingPartialText` (App Group projection)
/// and `recordingAmplitude` (also App Group, via `AmplitudeProjection`).
struct StreamingStrip: View {
    let partialText: String
    /// Wall-clock start of the active recording.
    let startedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed 154pt height for the scrollable streaming pane per spec.
    private static let paneHeight: CGFloat = 154

    /// Outer card height = header (~22pt) + spacing (6pt) + pane (154pt)
    /// + vertical padding (10pt × 2) = 192pt.
    private static let outerHeight: CGFloat = paneHeight + 22 + 6 + 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            StreamingPane(
                partialText: partialText,
                paneHeight: Self.paneHeight,
                reduceMotion: reduceMotion
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: Self.outerHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassSurface)
        .overlay(
            // Inset top highlight — spec's bright top hairline.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            PulsingBlueDot(reduceMotion: reduceMotion)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                    Text(elapsedString(now: context.date, since: startedAt))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .monospacedDigit()
                }
            } else {
                Text("0:00")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.jotKeyboardStreamText)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            WaveformBars(reduceMotion: reduceMotion)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Surface

    /// Same Liquid Glass recipe as `RecentsStrip` so the morph between
    /// idle ↔ recording reads as the same card surface, just a different
    /// chrome behind it.
    @ViewBuilder
    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.jotKeyboardGlassFill1,
                            Color.jotKeyboardGlassFill2,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - Helpers

    private func elapsedString(now: Date, since: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(since).rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Streaming pane

/// The scrollable streaming-text pane. Auto-follows by default; pauses
/// and surfaces a "↓ live" pill when the user scrolls up manually.
///
/// We use `ScrollViewReader` + `scrollTo(bottomAnchor)` to pin the
/// bottom whenever `partialText` extends, and a `PreferenceKey` driven
/// off a `GeometryReader` inside the scroll content to track the live
/// content height + scroll offset. Both are needed for the custom
/// indicator math (height + Y bound proportionally to viewport /
/// content) and for the scroll-up detection that pauses auto-follow.
private struct StreamingPane: View {
    let partialText: String
    let paneHeight: CGFloat
    let reduceMotion: Bool

    /// Live content height inside the ScrollView (text + padding).
    @State private var contentHeight: CGFloat = 0

    /// Live scroll offset — Y position of the top of the content
    /// inside the scroll viewport, in the viewport's coordinate space.
    @State private var scrollOffset: CGFloat = 0

    /// `true` once the user has manually scrolled up away from the
    /// bottom. Set by `onScrollGesture`, cleared when the user taps
    /// the "↓ live" pill or returns to the bottom on their own.
    @State private var userScrolledUp: Bool = false

    /// Stable anchor at the very bottom of the streaming text — used
    /// by `ScrollViewReader.scrollTo(.bottomAnchor, anchor: .bottom)`
    /// to pin auto-follow.
    private let bottomAnchor = "streaming-bottom"

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size.height

            // ScrollViewReader wraps the whole ZStack so `scrollProxy` is
            // available both for the auto-follow `onChange` AND for the
            // "↓ live" pill's tap handler — without it, tapping the pill
            // only clears `userScrolledUp` and waits for the next
            // partial-extend to actually scroll the pane.
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: false) {
                        // Inner content — single Text + caret. We measure
                        // its height via `.background(GeometryReader { ... })`
                        // so the custom scroll indicator can size itself.
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(partialText.isEmpty ? "Listening…" : partialText)
                                    .font(.system(size: 13, weight: .regular))
                                    .lineSpacing(13 * 0.55) // ~line-height 1.55
                                    .foregroundStyle(Color.jotKeyboardStreamText)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                BlinkingCaret(reduceMotion: reduceMotion)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                            .background(
                                GeometryReader { innerProxy in
                                    Color.clear
                                        .preference(
                                            key: ContentHeightKey.self,
                                            value: innerProxy.size.height
                                        )
                                }
                            )

                            // Stable bottom-edge anchor for auto-follow.
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                        }
                        .padding(.trailing, 12) // leave room for the custom indicator
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: ScrollOffsetKey.self,
                                        value: -geo.frame(in: .named("streamingPane")).minY
                                    )
                            }
                        )
                    }
                    .coordinateSpace(name: "streamingPane")
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        contentHeight = height
                    }
                    .onPreferenceChange(ScrollOffsetKey.self) { offset in
                        let prev = scrollOffset
                        scrollOffset = offset
                        // If the user is dragging back UP (offset
                        // decreasing) AND we still have overflow below,
                        // pause auto-follow. If they return to the
                        // bottom on their own, resume.
                        let maxOffset = max(0, contentHeight - paneHeight)
                        let atBottom = (maxOffset - offset) < 4
                        if offset < prev - 2, !atBottom {
                            userScrolledUp = true
                        } else if atBottom {
                            userScrolledUp = false
                        }
                    }
                    .onChange(of: partialText) { _, _ in
                        guard !userScrolledUp else { return }
                        // Auto-follow: pin to the bottom anchor on every
                        // partial-extend. The .animation wrapper keeps the
                        // scroll smooth — Reduce Motion users get the
                        // jump-cut.
                        if reduceMotion {
                            scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) {
                                scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        // First-frame pin so the pane opens at the bottom.
                        scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                    .frame(height: paneHeight)
                    .mask(
                        // Top-edge fade — `transparent 0% → black 18% →
                        // black 100%`. Older content eases out at the
                        // top edge as it scrolls off.
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.18),
                                .init(color: .black, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Custom scroll indicator — always visible during
                    // recording per spec. Height + Y bound proportionally
                    // to viewport / content.
                    ScrollIndicator(
                        paneHeight: paneHeight,
                        contentHeight: contentHeight,
                        scrollOffset: scrollOffset
                    )
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)

                    // "↓ live" pill — shown only while auto-follow is
                    // paused. Tap to resume auto-follow + scroll to
                    // bottom. Without the explicit `scrollProxy.scrollTo`,
                    // the pill would only clear the pause flag and the
                    // pane would sit scrolled up until the NEXT partial-
                    // extend triggered auto-follow — a confusing one-tick
                    // delay.
                    if userScrolledUp {
                        LivePill {
                            if reduceMotion {
                                userScrolledUp = false
                                scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    userScrolledUp = false
                                    scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                                }
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(width: proxy.size.width, height: viewport)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                           value: userScrolledUp)
            }
        }
        .frame(height: paneHeight)
        .accessibilityLabel(captionAccessibilityLabel)
    }

    /// VoiceOver: cap to the last ~200 chars so long dictations don't
    /// flood the screen reader.
    private var captionAccessibilityLabel: String {
        let tail = String(partialText.suffix(200))
        return tail.isEmpty ? "Listening for dictation" : "Live transcript: \(tail)"
    }
}

// MARK: - Custom scroll indicator

/// 3pt-wide blue indicator pinned to the right edge of the streaming
/// pane. Height + Y bound proportionally to viewport / content:
///   - height = paneHeight × (paneHeight / contentHeight) clamped
///     to [24, paneHeight - 16].
///   - y      = scrollOffset × (paneHeight - height) / (contentHeight - paneHeight)
///
/// Always visible during recording per spec — fades to half opacity
/// when content fits in the viewport (nothing to indicate).
private struct ScrollIndicator: View {
    let paneHeight: CGFloat
    let contentHeight: CGFloat
    let scrollOffset: CGFloat

    var body: some View {
        let hasOverflow = contentHeight > paneHeight + 1
        let ratio = hasOverflow ? min(1, paneHeight / contentHeight) : 1
        let rawHeight = paneHeight * ratio
        let height = min(max(24, rawHeight), paneHeight - 16)
        let overflow = max(1, contentHeight - paneHeight)
        let progress = hasOverflow
            ? min(1, max(0, scrollOffset / overflow))
            : 0
        let y = progress * (paneHeight - height)

        return VStack {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.jotKeyboardAccent.opacity(hasOverflow ? 0.32 : 0.16))
                .frame(width: 3, height: height)
                .offset(y: y)
            Spacer(minLength: 0)
        }
        .frame(width: 3, height: paneHeight, alignment: .top)
    }
}

// MARK: - "↓ live" pill

/// Compact blue capsule shown at the bottom-right of the streaming
/// pane when auto-follow is paused. Tap to resume.
private struct LivePill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("live")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotKeyboardAccent,
                                Color.jotKeyboardAccentDeep,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: Color.jotKeyboardAccent.opacity(0.35),
                    radius: 6, x: 0, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume live scrolling")
        .accessibilityHint("Scrolls back to the newest transcript content")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Preference keys

private struct ContentHeightKey: PreferenceKey {
    // `nonisolated(unsafe)` is the documented Swift 6 escape hatch for a
    // `PreferenceKey` default — SwiftUI only reads the default once on
    // the main actor at view-tree build time, so the mutability is
    // actor-confined in practice.
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Pulsing blue dot

private struct PulsingBlueDot: View {
    let reduceMotion: Bool
    @State private var isLit = false

    var body: some View {
        Circle()
            .fill(Color.jotKeyboardAccent)
            .opacity(reduceMotion ? 1.0 : (isLit ? 1.0 : 0.45))
            .shadow(color: Color.jotKeyboardAccent.opacity(0.6),
                    radius: 4, x: 0, y: 0)
            .onAppear {
                guard !reduceMotion else { return }
                isLit = true
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: isLit
            )
    }
}

// MARK: - Blinking blue caret

private struct BlinkingCaret: View {
    let reduceMotion: Bool
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.jotKeyboardAccent)
            .frame(width: 2, height: 14)
            .opacity(reduceMotion ? 1.0 : (visible ? 1.0 : 0.2))
            .onAppear {
                guard !reduceMotion else { return }
                visible.toggle()
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
    }
}

// MARK: - Animated waveform bars (header)

/// Six vertical blue bars, varying heights 4-13pt, opacities 0.5-0.9.
/// Replaces the prior 14-bar amplitude meter — spec wants a smaller
/// visual cue in the header, not a full meter. Amplitude is still
/// available via `AmplitudeProjection.read()` (used to scale the bars
/// gently, so a quieter mic shows softer bars).
private struct WaveformBars: View {
    let reduceMotion: Bool
    private static let barCount = 6
    private static let refreshInterval: TimeInterval = 0.11
    private static let baseHeights: [CGFloat] = [6, 10, 13, 11, 8, 5]
    private static let baseOpacities: [Double] = [0.6, 0.75, 0.9, 0.85, 0.7, 0.5]

    var body: some View {
        TimelineView(.periodic(from: Date(), by: Self.refreshInterval)) { context in
            HStack(alignment: .center, spacing: 2) {
                let amplitude = Double(AmplitudeProjection.read()?.amplitude ?? 0)
                ForEach(0..<Self.barCount, id: \.self) { index in
                    bar(index: index, amplitude: amplitude, tick: context.date)
                }
            }
            .frame(height: 14)
        }
    }

    private func bar(index: Int, amplitude: Double, tick: Date) -> some View {
        let base = Self.baseHeights[index]
        let opacity = Self.baseOpacities[index]
        // Gentle shimmer: phase-offset per bar so the row reads as a
        // live waveform, not a static graphic.
        let phase = (tick.timeIntervalSince1970 + Double(index) * 0.17)
            .truncatingRemainder(dividingBy: .pi * 2)
        let shimmer = reduceMotion ? 1.0 : (0.85 + 0.15 * sin(phase))
        let amp = 0.6 + 0.4 * max(0, min(1, amplitude))
        let height = max(2, base * CGFloat(shimmer * amp))
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.jotKeyboardAccent.opacity(opacity))
            .frame(width: 2, height: height)
    }
}

// MARK: - Legacy amplitude meter
//
// Retained as a publicly-typed view so any other call site that
// imported `AmplitudeMeter` continues to compile. New keyboard chrome
// uses `WaveformBars` (above). Both read the same projection.

struct AmplitudeMeter: View {
    private static let barCount = 14
    private static let refreshInterval: TimeInterval = 0.11

    var body: some View {
        TimelineView(.periodic(from: Date(), by: Self.refreshInterval)) { context in
            HStack(spacing: 2) {
                let amplitude = currentAmplitude()
                ForEach(0..<Self.barCount, id: \.self) { index in
                    bar(index: index, amplitude: amplitude, tick: context.date)
                }
            }
            .frame(height: 18)
        }
    }

    private func currentAmplitude() -> Float {
        AmplitudeProjection.read()?.amplitude ?? 0
    }

    private func bar(index: Int, amplitude: Float, tick: Date) -> some View {
        let normalized = max(0, min(1, CGFloat(amplitude)))
        let phase = (tick.timeIntervalSince1970 + Double(index) * 0.13)
            .truncatingRemainder(dividingBy: .pi * 2)
        let shimmer = 0.85 + 0.15 * sin(phase)
        let center = Double(Self.barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - 0.35 * distance
        let height = max(2, normalized * 18 * shimmer * envelope)
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.jotKeyboardAccent.opacity(0.65))
            .frame(width: 2, height: height)
    }
}
