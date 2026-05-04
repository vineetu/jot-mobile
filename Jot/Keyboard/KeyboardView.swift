import SwiftUI
import UIKit

/// Compact Jot keyboard surface for dictation, rewrite, paste, and punctuation
/// input. The view stays stateless: controller-owned callbacks perform document
/// mutations, app launch, and App Group reads.
struct KeyboardView: View {
    let hasFullAccess: Bool
    let hasPasteboardContent: Bool
    let canRewriteSelection: Bool
    let activeRewritePresetID: String?
    let recordingState: KeyboardRecordingState
    let needsInputModeSwitchKey: Bool
    let returnKeyType: UIReturnKeyType
    let historyEntries: [TranscriptHistoryMirror.Entry]
    let showHistory: Bool

    let onRewrite: (RewritePreset) -> Void
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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    actionChipRow
                    micCTA
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
                    withAnimation(.easeOut(duration: 0.067)) {
                        displayedAmplitude = amp
                    }
                }
                try? await Task.sleep(for: .milliseconds(67))
            }
        }
    }

    // MARK: - Rows

    private var actionChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RewritePreset.allCases) { preset in
                    let isRewriting = activeRewritePresetID == preset.id
                    chip(
                        title: preset.title,
                        systemImage: preset.iconName,
                        enabled: canRewriteSelection,
                        isLoading: isRewriting
                    ) {
                        onRewrite(preset)
                    }
                }

                chip(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    enabled: hasFullAccess && canRewriteSelection,
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

    private var micCTA: some View {
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
                        micLabel(
                            systemImage: "stop.fill",
                            title: "Recording · \(elapsedText(now: context.date))",
                            subtitle: "tap to stop"
                        )
                    }
                    .scaleEffect(iconScale)
                } else {
                    micLabel(
                        systemImage: hasFullAccess ? "mic.fill" : "lock.shield",
                        title: hasFullAccess ? "Tap to speak" : "Enable Full Access",
                        subtitle: nil
                    )
                }
            }
            .foregroundStyle(hasFullAccess ? .white : Color(uiColor: .label))
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(micBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { micHalo }
            .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.16), radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityAddTraits(.isButton)
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

    private func micLabel(systemImage: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 24)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .monospacedDigit()

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .opacity(0.88)
                }
            }
        }
        .padding(.horizontal, 14)
    }

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
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 76, minHeight: 40)
        }
        .buttonStyle(ChipButtonStyle(enabled: enabled, isLoading: isLoading))
        .disabled(!enabled || isLoading)
        .opacity((enabled || isLoading) ? 1 : 0.38)
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

    /// Outer glow ring driven by amplitude. Lives inside `.overlay` so it
    /// does not affect the pill's layout.
    @ViewBuilder
    private var micHalo: some View {
        if hasFullAccess, recordingState.isRecording, !reduceMotion {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color.white.opacity(0.15 + Double(displayedAmplitude) * 0.5),
                    lineWidth: 1 + CGFloat(displayedAmplitude) * 2
                )
        }
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

private extension RewritePreset {
    var iconName: String {
        switch self {
        case .rewrite: return "sparkles"
        }
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
