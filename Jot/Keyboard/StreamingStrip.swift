import SwiftUI

/// Streaming-state top strip — rebuilt 2026-05-11 per
/// `Jot/tmp/keyboard-design-reference.html`; re-capped + italicized in the
/// UX-overhaul round 2 WS-A pass (capped fading stream, hero parity).
///
/// Anatomy:
/// - Header row: blue pulsing recording dot (`#007AFF`, 8×8pt) + an optional
///   relocated SF-Mono timer (WS-D — only when controls + Enter share a row)
///   + animated waveform bars (6 blue bars). While paused (WS-C / §10) the
///   header swaps to a static hollow dot + frozen clock + "mic ready, not
///   capturing" and the waveform hides.
/// - Streaming pane: ~3.5-line capped Liquid Glass card with a scrollable
///   interior. Live text renders in the bundled Fraunces ITALIC (italic =
///   "live" only), `#3C5A99`, line-height ~1.55.
/// - Top-edge fade via `.mask(LinearGradient(...))` so older content
///   eases out as it scrolls off the top.
/// - Custom 3pt-wide blue scroll indicator on the right, always
///   visible during recording. Height + Y are bound proportionally
///   to viewport / content size.
/// - Auto-follow scroll: pins to bottom as new content streams. If
///   the user scrolls up manually, auto-follow pauses and a "↓ live"
///   pill appears at the bottom-right. Tapping the pill re-enables
///   auto-follow + scrolls to bottom.
/// - Stepping ellipsis tail (`TranscribingText`) inline after the newest
///   word — the batch preview delivers text in chunks, so the tail keeps
///   signalling "still transcribing, text is catching up" between chunks.
///   Hidden while paused. (Replaced the old blinking caret, which an
///   HStack pinned to the block edge — not the last word — once lines
///   wrapped.)
///
/// Read-only consumer of `streamingPartialText` (App Group projection)
/// and `recordingAmplitude` (also App Group, via `AmplitudeProjection`).
struct StreamingStrip: View {
    let partialText: String
    /// Wall-clock start of the active recording.
    let startedAt: Date?
    /// WS-C / §10 — true while the dictation is paused. Freezes the header
    /// clock and swaps the live recording cue for a static "Paused · mic
    /// ready, not capturing" treatment so the orange mic indicator never reads
    /// as covert recording.
    var isPaused: Bool = false
    /// Frozen elapsed seconds the app pinned at pause (active-time total, pause
    /// gaps excluded). Rendered in the header clock while paused instead of the
    /// live ticking value. Nil while actively recording.
    var pausedElapsedSeconds: TimeInterval? = nil
    /// WS-D — when the controls + adaptive Enter share one row (large widths),
    /// the Stop pill drops its inline timer and the elapsed clock relocates
    /// here to the strip header. Below 428 the pill keeps the timer and this is
    /// `false`, so the header omits the clock to avoid showing it twice.
    var showsHeaderTimer: Bool = false
    /// Pre-composed "Loading [variant]…" copy mirrored from the main
    /// app's `StreamingTranscriptionService.sessionLoadState`. Non-nil
    /// only while the streaming graph is in its per-session ANE load
    /// window. When set AND `partialText` is empty, the pane replaces
    /// its idle "Listening…" copy with this label + an inline spinner
    /// so the user sees recording is active but the model hasn't
    /// started consuming audio yet. Cleared by the controller the
    /// instant the load completes; the pane re-renders to "Listening…"
    /// (or the first partial, whichever arrives first).
    var loadingLabel: String? = nil

    /// Contextual status shown in the header between the recording cue and the
    /// waveform. A reusable slot — the caller decides what belongs here for the
    /// current context (e.g. "Tidied up when you stop" during a normal capture;
    /// later, "Won't be saved" for edit / feedback dictation). Nil hides it.
    /// One line, scales down before it ever truncates so the waveform keeps its
    /// space on narrow keyboards.
    var statusLine: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of the scrollable streaming pane. WS-A re-cap: trimmed from 130 →
    /// 76 so the live transcript shows ~3.5 lines (down from ~6½) — the
    /// "capped fading stream" treatment shared with the hero (plan §1 / WS-A).
    /// At 13pt with ~1.55 line-height (~20pt/line) the italic body fits ~3.5
    /// lines, bottom-anchored, older text scrolling up + fading at the top
    /// (the fade mask + auto-follow are unchanged below). Re-derive
    /// `outerHeight` whenever this changes and re-test the 310pt envelope
    /// (R15): header(22) + spacing(6) + pane(76) + vPadding(20) = 124pt, which
    /// leaves ample room for the control + Enter rows under 310pt.
    private static let paneHeight: CGFloat = 76

    /// Outer card height = header (~22pt) + spacing (6pt) + pane
    /// + vertical padding (10pt × 2).
    private static let outerHeight: CGFloat = paneHeight + 22 + 6 + 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            StreamingPane(
                partialText: partialText,
                loadingLabel: loadingLabel,
                isPaused: isPaused,
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
            if isPaused {
                // WS-C / §10 paused cue: static hollow dot (not pulsing) +
                // plain-language "mic ready, not capturing" so the held mic
                // never reads as covert recording. No waveform while paused.
                Circle()
                    .strokeBorder(Color.jotKeyboardStreamText, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                if showsHeaderTimer {
                    Text(pausedHeaderTime)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .monospacedDigit()
                }

                Text("Paused · mic ready, not capturing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.jotKeyboardStreamText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)
            } else {
                PulsingBlueDot(reduceMotion: reduceMotion)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                // WS-D: the live clock is shown here only when it has been
                // relocated off the Stop pill (large widths share controls +
                // Enter on one row). Below 428 the pill keeps the timer, so
                // the header omits it to avoid two ticking clocks.
                if showsHeaderTimer {
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
                }

                if let statusLine {
                    Text(statusLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.jotKeyboardStreamText.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.leading, showsHeaderTimer ? 4 : 0)
                        .accessibilityLabel(statusLine)
                }

                Spacer(minLength: 6)

                WaveformBars(reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Frozen MM:SS shown in the header while paused (§10.4).
    private var pausedHeaderTime: String {
        let total = max(0, Int((pausedElapsedSeconds ?? 0).rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
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
    /// See `StreamingStrip.loadingLabel`. When non-nil and
    /// `partialText` is empty, the pane renders a spinner +
    /// label pair instead of the idle "Listening…" placeholder.
    let loadingLabel: String?
    /// While paused the mic isn't capturing, so the trailing "still
    /// transcribing" ellipsis is dropped — nothing should promise more text.
    let isPaused: Bool
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

    /// Gates the cold-start line: `true` only once the in-flight model load has
    /// run past `ColdStartCopy.revealThreshold`. A warm load clears
    /// `loadingLabel` before this flips, so the line never flashes. Driven by
    /// the `.task(id: loadingLabel)` below.
    @State private var loadRevealed: Bool = false

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
                        // Inner content — a single text run. We measure
                        // its height via `.background(GeometryReader { ... })`
                        // so the custom scroll indicator can size itself.
                        VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if partialText.isEmpty, let loadingLabel, loadRevealed {
                                    // Cold-start line — shown ONLY after a load
                                    // passes `ColdStartCopy.revealThreshold` (the
                                    // `.task` below gates `loadRevealed`). A warm
                                    // load clears `loadingLabel` before then, so
                                    // it never flashes. No bar/waveform — the
                                    // strip header's pulsing dot is the only
                                    // motion (the design rule).
                                    KeyboardLoadingText(label: loadingLabel,
                                                        reduceMotion: reduceMotion)
                                } else if partialText.isEmpty {
                                    // Either no load, or a load still under the
                                    // reveal threshold: the same calm "Listening…"
                                    // as any other wait — alive from second one,
                                    // quiet (no waveform).
                                    listeningPlaceholder
                                } else {
                                    // WS-A / R15: live transcript renders in the
                                    // already-bundled Fraunces ITALIC (the
                                    // 9pt-opsz text cut, tuned for text size) —
                                    // italic exclusively signals "live", giving
                                    // hero parity. NOT synthetic system italic.
                                    // `TranscribingText` appends the stepping
                                    // ellipsis tail inline after the newest
                                    // word — the batch preview lags the voice,
                                    // and the tail keeps signalling "still
                                    // transcribing" between chunks. The tail
                                    // wears the accent blue: the keyboard's
                                    // "live" chrome color (pulsing dot,
                                    // waveform), hero parity in idiom.
                                    TranscribingText(
                                        text: partialText,
                                        font: Font.custom(JotType.frauncesItalicText, size: 14),
                                        textColor: Color.jotKeyboardStreamText,
                                        dotColor: Color.jotKeyboardAccent,
                                        isTranscribing: !isPaused,
                                        reduceMotion: reduceMotion
                                    )
                                    .lineSpacing(14 * 0.55) // ~line-height 1.55
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
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
                    .defaultScrollAnchor(.bottom)
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
        // Deferred reveal: when a load begins (`loadingLabel` non-nil), wait
        // out the remainder of `ColdStartCopy.revealThreshold` from the load's
        // real start, THEN reveal the line. A warm load clears `loadingLabel`
        // first → the task is cancelled and the line never shows.
        .task(id: loadingLabel) {
            guard loadingLabel != nil else { loadRevealed = false; return }
            let started = AppGroup.streamingLoadStartedAt ?? Date()
            let remaining = ColdStartCopy.revealThreshold - Date().timeIntervalSince(started)
            if remaining > 0 {
                loadRevealed = false
                try? await Task.sleep(for: .seconds(remaining))
                if Task.isCancelled { return }
            }
            loadRevealed = true
        }
    }

    /// The calm "Listening…" wait — the SAME stepping ellipsis as the
    /// live-transcript tail, so the waiting state breathes identically to the
    /// streaming text (alive from second one, quiet — no waveform). Shown both
    /// when idle-recording and while a load is still under the reveal threshold.
    private var listeningPlaceholder: some View {
        SteppingEllipsis(
            leading: "Listening",
            font: .system(size: 13, weight: .regular),
            textColor: Color.jotKeyboardStreamText,
            dotColor: Color.jotKeyboardAccent,
            reduceMotion: reduceMotion
        )
        .lineSpacing(13 * 0.55)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// VoiceOver: cap to the last ~200 chars so long dictations don't
    /// flood the screen reader.
    private var captionAccessibilityLabel: String {
        let tail = String(partialText.suffix(200))
        if tail.isEmpty {
            if let loadingLabel { return loadingLabel }
            return "Listening for dictation"
        }
        return "Live transcript: \(tail)"
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

/// Cold-start line for the keyboard's streaming pane — the single
/// editorial line (`ColdStartCopy`) shown while the model is doing a
/// genuinely slow load. NO progress bar, NO breathing: the strip header's
/// pulsing blue dot is the only motion (the design's rule). Rendered in the
/// same bundled Fraunces italic as the live transcript so it reads as Jot's
/// editorial voice, not a system loading primitive. The deferred-reveal gate
/// (this only appears once a load passes `ColdStartCopy.revealThreshold`)
/// lives in `StreamingPane`, so a warm load never flashes it.
private struct KeyboardLoadingText: View {
    let label: String
    let reduceMotion: Bool

    var body: some View {
        Text(label)
            .font(Font.custom(JotType.frauncesItalicText, size: 14))
            .lineSpacing(14 * 0.55)
            .foregroundStyle(Color.jotKeyboardStreamText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }
}
