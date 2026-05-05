import SwiftUI
import UIKit

/// Compact Jot keyboard surface for dictation, rewrite, paste, and punctuation
/// input. The view stays stateless: controller-owned callbacks perform document
/// mutations, app launch, and App Group reads.
struct KeyboardView: View {
    let hasFullAccess: Bool
    let hasPasteboardContent: Bool
    let hasSelection: Bool
    let recordingState: KeyboardRecordingState
    let needsInputModeSwitchKey: Bool
    let returnKeyType: UIReturnKeyType
    let historyEntries: [TranscriptHistoryMirror.Entry]
    let showHistory: Bool

    let onCopy: () -> Void
    let onPaste: () -> Void
    let onTapToSpeak: () -> Void
    let onShowHistory: () -> Void
    let onInsertHistoryEntry: (TranscriptHistoryMirror.Entry) -> Void
    let onDismissHistory: () -> Void
    let onKey: (KeyboardKeyDescriptor) -> Void
    let onKeyPressChange: (KeyboardKeyDescriptor, Bool) -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onOpenFullAccess: () -> Void

    let feedback: KeyboardFeedback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var displayedAmplitude: Float = 0

    private let punctuationKeys: [KeyboardKeyDescriptor] = [
        .literal("@"),
        .literal("."),
        .literal(","),
        .literal("?"),
        .literal("!"),
        .literal("'"),
        .backspace,
    ]

    var body: some View {
        GeometryReader { proxy in
            let metrics = KeyboardMetrics(availableWidth: proxy.size.width)
            ZStack(alignment: .bottom) {
                VStack(spacing: metrics.rowSpacing) {
                    streamingPreviewStrip
                    actionAndMicRow
                    punctuationRow(metrics: metrics)
                    bottomRow(metrics: metrics)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, metrics.sideInset)
                .padding(.vertical, metrics.verticalInset)

                if showHistory && hasFullAccess {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDismissHistory)
                        .transition(.opacity)

                    HistoryOverlay(
                        entries: Array(historyEntries.prefix(10)),
                        onInsert: onInsertHistoryEntry,
                        onDismiss: onDismissHistory
                    )
                    .frame(maxHeight: 280)
                    .padding(.horizontal, metrics.sideInset)
                    .padding(.bottom, metrics.verticalInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showHistory)
        }
        .frame(minHeight: 250)
        .task(id: recordingState.isRecording) {
            guard recordingState.isRecording else {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.15)) {
                        displayedAmplitude = 0
                    }
                }
                return
            }

            while !Task.isCancelled && recordingState.isRecording {
                let amp = AmplitudeProjection.read()?.amplitude ?? 0
                await MainActor.run {
                    // Skip the per-tick animation when the user has reduce
                    // motion on — the halo / icon scale visuals already
                    // short-circuit, so the animation wrapper is a pure
                    // no-op cost otherwise.
                    if reduceMotion {
                        displayedAmplitude = amp
                    } else {
                        withAnimation(.easeOut(duration: 0.067)) {
                            displayedAmplitude = amp
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(67))
            }
        }
    }

    // MARK: - Rows

    /// Live partial-transcript caption rendered above the action+mic row
    /// while a recording is in flight. Mirrored from the main app via the
    /// `streamingPartialText` App Group projection (see
    /// `JotKeyboardViewController.refreshStreamingPartialFromProjection`).
    ///
    /// Real `ScrollView` with a fixed-height frame so the strip never
    /// collapses when the text is short and never grows when the text gets
    /// long. Auto-scrolls to the trailing tail on every text change so the
    /// latest words stay visible.
    @ViewBuilder
    private var streamingPreviewStrip: some View {
        // Landscape iPhone keyboards live in a ~162-216pt vertical envelope.
        // Including the 64pt strip plus spacing pushes the stack over the
        // budget and clips the bottom row (return/globe/space). Landscape
        // dictation is rare and the user can read partials in the in-app
        // live preview or by switching to portrait, so we hide the strip
        // entirely in compact-height layouts (cleanest of the two options
        // considered — see kb-fixer round 2 / Issue 3).
        if verticalSizeClass == .compact {
            EmptyView()
        } else if recordingState.isRecording, !recordingState.streamingPartialText.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(recordingState.streamingPartialText)
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .label))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .id("streamingTail")
                        // Cap the VoiceOver label to the last ~200 chars so a
                        // multi-minute dictation doesn't make VO read the
                        // entire buffer when focus lands. Matches what the
                        // visual scroll-to-tail already shows
                        // (kb-fixer round 3 / Issue B).
                        .accessibilityLabel("Live transcript: \(String(recordingState.streamingPartialText.suffix(200)))")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .frame(height: 64)
                // Vertical edge fade so partials enter and exit the strip
                // softly rather than hard-clipping against the rounded
                // corners — Messages-style caption affordance.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .black, location: 0.14),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .background(
                    // `Color(.systemGray6)` is intentionally low-contrast in
                    // dark mode — matches Apple's Messages composer
                    // reference for a soft, recessed caption strip. Don't
                    // bump the contrast without revisiting that comparison
                    // (kb-fixer round 2 / Issue 8 verdict).
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .systemGray6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        )
                )
                .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top)))
                .onAppear {
                    // First appearance can already have many words — `onChange`
                    // won't fire if the projection arrived before the view
                    // mounted. Snap to the tail without animation so the
                    // initial frame doesn't show the start of a long buffer.
                    proxy.scrollTo("streamingTail", anchor: .bottom)
                }
                .onChange(of: recordingState.streamingPartialText) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo("streamingTail", anchor: .bottom)
                    }
                }
            }
        } else {
            // Reserve the same 64pt slot whether streaming text is showing
            // or not so the keyboard total height stays constant and the
            // bottom row never reflows. Resting state shows a subtle
            // italic caption affordance — communicates the strip's purpose
            // without competing for attention. Hidden from VoiceOver because
            // the mic button already carries the actionable hint.
            //
            // Placeholder copy is phase-aware: while a recording exists but
            // no partials have arrived yet ("warming up"), or while the
            // pipeline is mid-transcription, the strip says so. Otherwise
            // the strip nudges the user toward dictation.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemGray6).opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
                    )
                Text(streamingPlaceholderText)
                    .font(.subheadline.italic())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 16)
            }
            .frame(height: 64)
            .accessibilityHidden(true)
        }
    }

    /// Idle placeholder copy. Phase-aware so the strip narrates the
    /// in-flight pipeline state when partials haven't arrived yet — keeps
    /// the user oriented after they tap the mic without flooding them with
    /// motion.
    private var streamingPlaceholderText: String {
        if recordingState.isRecording {
            return "Listening…"
        }
        switch recordingState.phase {
        case .transcribing, .processing, .cleaning, .publishing:
            return "Transcribing…"
        case .failed:
            return "Recording failed — tap mic to retry"
        case .idle, .recording:
            return "Speak to dictate"
        }
    }

    /// Combined chip-row-plus-compact-mic row.
    ///
    /// Replaces the previous full-width 64pt mic CTA + separate 44pt chip
    /// row (≈118pt of stack). The compact mic sits right of the
    /// horizontally-scrollable chip row, both at 44pt — a ~30% height
    /// reduction that returns enough vertical budget to the bottom row so
    /// `return` / globe / space stay visible after the streaming preview
    /// strip is added on top.
    private var actionAndMicRow: some View {
        HStack(spacing: 10) {
            actionChipRow
                .frame(maxWidth: .infinity)
            compactMicCTA
        }
        .frame(height: 44)
    }

    private var actionChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    enabled: hasFullAccess && hasSelection,
                    action: onCopy
                )

                chip(
                    title: "Paste",
                    systemImage: "doc.on.clipboard",
                    enabled: hasFullAccess && hasPasteboardContent,
                    action: onPaste
                )
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 44)
    }

    /// Compact mic CTA pinned to the right of the action chip row.
    ///
    /// Replaces the previous full-width 64pt-tall pill. Same tap targets
    /// (Full Access prompt fallthrough; tap-to-stop while recording),
    /// same accessibility surface — just packed into an 84×44 rectangle so
    /// the keyboard reclaims ~74pt of vertical real estate for the streaming
    /// preview strip + bottom row, and the action chip row gains ~36pt of
    /// horizontal budget so Copy / Paste fit at 393pt iPhone width without
    /// horizontal scrolling.
    ///
    /// At 84pt the label uses `minimumScaleFactor` to absorb the longer
    /// localizations (DE "Aufnehmen", FR "Enregistrer"). The English
    /// "Speak" / "Unlock" idle labels fit comfortably alongside the icon.
    private var compactMicCTA: some View {
        Button {
            feedback.longPressImpact()
            if hasFullAccess {
                onTapToSpeak()
            } else {
                onOpenFullAccess()
            }
        } label: {
            Group {
                if hasFullAccess, recordingState.isRecording {
                    let startedAt = recordingState.startedAt ?? Date()
                    TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text(elapsedText(now: context.date))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .scaleEffect(iconScale)
                } else if hasFullAccess, recordingState.isInflightPostRecording {
                    // In-flight after stop: show a small progress spinner +
                    // label so the user understands the tap landed and the
                    // pipeline is still working. Disabled at the controller
                    // level (mic taps are ignored during in-flight phases),
                    // but the visual signal closes the feedback loop.
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Working")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: hasFullAccess ? "mic.fill" : "lock.shield")
                            .font(.system(size: 16, weight: .semibold))
                        Text(hasFullAccess ? "Speak" : "Unlock")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .foregroundStyle(hasFullAccess ? .white : Color(uiColor: .label))
            .padding(.horizontal, 8)
            .frame(width: 84, height: 44)
            .background(micBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { compactMicHalo }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: recordingState.isRecording)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: recordingState.isInflightPostRecording)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityAddTraits(recordingState.isRecording
                                ? [.isButton, .startsMediaSession]
                                : .isButton)
    }

    @ViewBuilder
    private var compactMicHalo: some View {
        if hasFullAccess, recordingState.isRecording, !reduceMotion {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.white.opacity(0.15 + Double(displayedAmplitude) * 0.5),
                    lineWidth: 1 + CGFloat(displayedAmplitude) * 2
                )
        }
    }

    private func punctuationRow(metrics: KeyboardMetrics) -> some View {
        let keyWidth = max(
            32,
            (metrics.innerWidth - metrics.keySpacing * CGFloat(punctuationKeys.count - 1))
                / CGFloat(punctuationKeys.count)
        )

        return HStack(spacing: metrics.keySpacing) {
            ForEach(Array(punctuationKeys.enumerated()), id: \.offset) { _, key in
                KeyboardKey(
                    descriptor: key,
                    width: keyWidth,
                    height: metrics.keyHeight,
                    cornerRadius: metrics.buttonCornerRadius,
                    feedback: feedback,
                    onTap: onKey,
                    onPressChanged: onKeyPressChange
                )
            }
        }
    }

    private func bottomRow(metrics: KeyboardMetrics) -> some View {
        let actionWidth = max(42, metrics.letterKeyWidth * 1.25)
        let returnWidth = max(78, metrics.letterKeyWidth * 2.2)

        return HStack(spacing: metrics.keySpacing) {
            keyButton(
                width: actionWidth,
                metrics: metrics,
                style: .action,
                enabled: needsInputModeSwitchKey,
                accessibilityLabel: "Next keyboard",
                action: onAdvanceToNextInputMode
            ) {
                Image(systemName: "globe")
                    .imageScale(.medium)
            }

            keyButton(
                width: actionWidth,
                metrics: metrics,
                style: .action,
                enabled: hasFullAccess,
                accessibilityLabel: "Transcript history",
                action: onShowHistory
            ) {
                Image(systemName: "clock.arrow.circlepath")
                    .imageScale(.medium)
            }

            keyButton(
                metrics: metrics,
                style: .primary,
                accessibilityLabel: "space",
                action: { onKey(.space) }
            ) {
                HStack(spacing: 7) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("space")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            keyButton(
                width: returnWidth,
                metrics: metrics,
                style: .returnAccent,
                accessibilityLabel: returnTitle.lowercased(),
                action: { onKey(.returnKey) }
            ) {
                Text(returnTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .frame(height: metrics.keyHeight)
    }

    // MARK: - Components

    private func chip(
        title: String,
        systemImage: String,
        enabled: Bool,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            feedback.systemClick()
            action()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.accentColor)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
        }
        .buttonStyle(ChipButtonStyle(enabled: enabled, isLoading: isLoading))
        .disabled(!enabled || isLoading)
        .opacity((enabled || isLoading) ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private func keyButton<Content: View>(
        width: CGFloat? = nil,
        metrics: KeyboardMetrics,
        style: KeyboardKeyStyle,
        enabled: Bool = true,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            fireFeedback(for: style)
            action()
        } label: {
            content()
                .font(font(for: style))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(
            KeyButtonStyle(
                keyStyle: style,
                cornerRadius: metrics.buttonCornerRadius
            )
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .frame(width: width, height: metrics.keyHeight)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - Styling

    private var micBackground: AnyShapeStyle {
        if hasFullAccess, recordingState.isRecording {
            return AnyShapeStyle(Color(uiColor: .systemRed))
        }

        if hasFullAccess, recordingState.isInflightPostRecording {
            // Slightly muted accent so the in-flight state reads as "still
            // working, don't tap" without flashing back to idle. Avoids a
            // second hue (red → orange → blue) that would confuse the user
            // about whether the recording succeeded.
            return AnyShapeStyle(Color.accentColor.opacity(0.65))
        }

        if hasFullAccess {
            return reduceMotion
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(Color.accentColor.gradient)
        } else {
            return AnyShapeStyle(Color(uiColor: .secondarySystemFill))
        }
    }

    /// Subtle scale on the icon+text label group only, not the whole pill.
    private var iconScale: CGFloat {
        guard hasFullAccess, recordingState.isRecording, !reduceMotion else {
            return 1.0
        }
        return 1.0 + CGFloat(displayedAmplitude) * 0.08
    }

    private var micAccessibilityLabel: String {
        guard hasFullAccess else { return "Enable Full Access" }
        return recordingState.isRecording ? "Stop recording" : "Tap to speak"
    }

    private var micAccessibilityHint: String {
        guard hasFullAccess else { return "Opens the Jot settings page" }
        return recordingState.isRecording
            ? "Requests Jot to stop the active recording"
            : "Opens Jot and starts dictation"
    }

    private func elapsedText(now: Date) -> String {
        guard let startedAt = recordingState.startedAt else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var returnTitle: String {
        switch returnKeyType {
        case .default:        return "Return"
        case .go:             return "Go"
        case .google:         return "Search"
        case .join:           return "Join"
        case .next:           return "Next"
        case .route:          return "Route"
        case .search:         return "Search"
        case .send:           return "Send"
        case .yahoo:          return "Search"
        case .done:           return "Done"
        case .emergencyCall:  return "Emergency"
        case .continue:       return "Continue"
        @unknown default:     return "Return"
        }
    }

    private func font(for style: KeyboardKeyStyle) -> Font {
        switch style {
        case .primary:
            return .system(size: 14, weight: .regular, design: .default)
        case .action:
            return .system(size: 15, weight: .regular, design: .default)
        case .returnAccent:
            return .system(size: 15, weight: .semibold, design: .default)
        }
    }

    private func fireFeedback(for style: KeyboardKeyStyle) {
        switch style {
        case .primary:
            feedback.inputClick()
        case .action, .returnAccent:
            feedback.systemClick()
        }
        feedback.selectionTick()
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let enabled: Bool
    let isLoading: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isLoading ? Color.accentColor : Color(uiColor: .label))
            .background(background(pressed: configuration.isPressed), in: Capsule())
    }

    private func background(pressed: Bool) -> some ShapeStyle {
        if isLoading {
            return Color.accentColor.opacity(0.14)
        }
        if !enabled {
            return Color(uiColor: .tertiarySystemFill)
        }
        return pressed
            ? Color(uiColor: .keyboardButtonBackground)
            : Color(uiColor: .secondarySystemFill)
    }
}

private struct KeyButtonStyle: ButtonStyle {
    let keyStyle: KeyboardKeyStyle
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(
                background(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.28),
                    radius: 0, x: 0, y: 1)
    }

    private var foreground: Color {
        switch keyStyle {
        case .primary, .action:
            return Color(uiColor: .label)
        case .returnAccent:
            return .white
        }
    }

    private func background(pressed: Bool) -> Color {
        switch keyStyle {
        case .primary:
            return Color(uiColor: pressed ? .keyboardDarkButtonBackground : .keyboardButtonBackground)
        case .action:
            return Color(uiColor: pressed ? .keyboardButtonBackground : .keyboardDarkButtonBackground)
        case .returnAccent:
            return Color.accentColor.opacity(pressed ? 0.72 : 0.92)
        }
    }
}
