import SwiftUI
import UIKit

/// Compact Jot keyboard surface for dictation, paste, and punctuation
/// input. The view stays stateless: controller-owned callbacks perform document
/// mutations, app launch, and App Group reads.
struct KeyboardView: View {
    let hasFullAccess: Bool
    let hasPasteboardContent: Bool
    let hasSelection: Bool
    let availableSavedPrompts: [SavedPrompt]
    let isRewritingSelection: Bool
    let recordingState: KeyboardRecordingState
    let needsInputModeSwitchKey: Bool
    let returnKeyType: UIReturnKeyType
    let historyEntries: [TranscriptHistoryMirror.Entry]
    let showHistory: Bool
    let canUndoLastInsertion: Bool
    let canRedoInsertion: Bool

    /// True when the user's selected rewrite provider is Apple Intelligence
    /// AND the system reports it as unavailable (device ineligible, AI not
    /// enabled in Settings, or model not ready). Retained for the next
    /// keyboard rewrite affordance.
    let aiUnavailable: Bool
    /// Transient status banner text (e.g. "Rewrite timed out"). Renders a
    /// brief auto-fading banner above the streaming preview strip when set.
    let statusBanner: String?

    let onCopy: () -> Void
    let onPaste: () -> Void
    let onUndoLastInsertion: () -> Void
    let onRedoInsertion: () -> Void
    let onSelectPromptForSelection: (SavedPrompt) -> Void
    let onTapToSpeak: () -> Void
    let onShowHistory: () -> Void
    let onInsertHistoryEntry: (TranscriptHistoryMirror.Entry) -> Void
    let onDismissHistory: () -> Void
    let onKey: (KeyboardKeyDescriptor) -> Void
    let onKeyPressChange: (KeyboardKeyDescriptor, Bool) -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onOpenFullAccess: () -> Void
    let onStatusBannerRendered: () -> Void

    let feedback: KeyboardFeedback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
                .overlay(alignment: .top) {
                    statusBannerOverlay
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, metrics.verticalInset)
                }

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
    /// motion. Also surfaces the wand-button selection-rewrite state so the
    /// user has a visible signal while the rewrite races against the 45s
    /// timeout (the wand button itself stays a static greyed glyph).
    private var streamingPlaceholderText: String {
        if isRewritingSelection {
            return "Rewriting…"
        }
        if recordingState.isRecording {
            return "Listening…"
        }
        switch recordingState.phase {
        case .rewriting:
            return "Rewriting…"
        case .transcribing, .processing, .cleaning, .publishing:
            return "Transcribing…"
        case .failed:
            return "Recording failed — tap mic to retry"
        case .idle, .recording:
            return "Speak to dictate"
        }
    }

    /// Auto-fading banner surfaced above the streaming preview strip when
    /// the most recent dictation fell back from rewrite to raw paste
    /// (Phi-4 timeout, model error, etc.). The keyboard owns the fade-out
    /// timing — `onStatusBannerRendered` clears the App Group slot once
    /// the banner has been on-screen long enough for the user to read it
    /// (~2.5s). Severity styling: orange for transient issues like
    /// timeout, red for hard errors. Heuristic: anything containing the
    /// word "timed" / "timeout" reads as orange; everything else as red.
    @ViewBuilder
    private var statusBannerOverlay: some View {
        if let banner = statusBanner, !banner.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: bannerIsWarning(banner)
                      ? "exclamationmark.triangle.fill"
                      : "xmark.octagon.fill")
                    .imageScale(.small)
                Text(banner)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bannerIsWarning(banner)
                          ? Color(uiColor: .systemOrange)
                          : Color(uiColor: .systemRed))
            )
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel(banner)
            .accessibilityAddTraits(.isStaticText)
            .task(id: banner) {
                guard banner != "Rewriting…" else { return }
                // Fade-out window: render for 2.5s, then signal the
                // controller to clear the App Group slot. The next
                // re-render observes `statusBanner == nil` and the
                // overlay branches to `EmptyView()`.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                onStatusBannerRendered()
            }
        } else {
            EmptyView()
        }
    }

    private func bannerIsWarning(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timed") || lower.contains("timeout")
    }

    /// Primary controls row - selection rewrite, Speak CTA, and Actions menu.
    private var actionAndMicRow: some View {
        HStack(spacing: 10) {
            wandButton
            speakButton
                .frame(maxWidth: .infinity)
            actionsButton
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var wandButton: some View {
        if aiUnavailable {
            Button {} label: {
                secondaryControlLabel(
                    title: "AI off",
                    systemImage: "exclamationmark.triangle",
                    enabled: true,
                    lit: false
                )
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.45)
            .accessibilityLabel("Apple Intelligence is not enabled")
            .accessibilityAddTraits(.isButton)
        } else {
            // Single wand affordance for the AI-on case. Interactive when
            // there is a selection AND no rewrite is in flight; otherwise
            // greyed out as a disabled button. The rewrite in-flight state
            // surfaces in the streaming display panel ("Rewriting…") rather
            // than swapping the wand glyph for a spinner — keeps the row
            // visually stable and matches the dictation placeholder
            // convention.
            let isInteractive = hasSelection && !isRewritingSelection
            if isInteractive {
                Menu {
                    ForEach(availableSavedPrompts) { prompt in
                        Button {
                            feedback.systemClick()
                            feedback.selectionTick()
                            onSelectPromptForSelection(prompt)
                        } label: {
                            Text(prompt.name)
                        }
                    }
                } label: {
                    secondaryControlLabel(
                        title: "",
                        systemImage: "wand.and.stars",
                        enabled: true,
                        lit: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewrite selection — choose a prompt")
                .accessibilityAddTraits(.isButton)
            } else {
                Button {} label: {
                    secondaryControlLabel(
                        title: "",
                        systemImage: "wand.and.stars",
                        enabled: true,
                        lit: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.45)
                .accessibilityLabel(isRewritingSelection
                                    ? "Rewriting selection…"
                                    : "Rewrite — select text to enable")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private var speakButton: some View {
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
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 20, weight: .semibold))
                            Text(elapsedText(now: context.date))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            PulsingRecordingDot()
                        }
                    }
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
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: hasFullAccess ? "mic.fill" : "lock.shield")
                            .font(.system(size: 20, weight: .semibold))
                        Text(hasFullAccess ? "Speak" : "Unlock")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .foregroundStyle(hasFullAccess ? .white : Color(uiColor: .label))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(speakBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: speakShadow, radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    private var actionsButton: some View {
        Menu {
            if hasSelection {
                copyMenuItem(highlighted: true)
                pasteMenuItem(highlighted: false)
            } else {
                pasteMenuItem(highlighted: true)
                copyMenuItem(highlighted: false)
            }

            Button(action: onUndoLastInsertion) {
                Label("Undo last insertion", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canUndoLastInsertion)

            Button(action: onRedoInsertion) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!canRedoInsertion)
        } label: {
            secondaryControlLabel(
                title: "Actions",
                systemImage: "ellipsis",
                enabled: true,
                lit: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions")
        .accessibilityHint(actionsAccessibilityHint)
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

    @ViewBuilder
    private func copyMenuItem(highlighted: Bool) -> some View {
        if highlighted {
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
                    .foregroundStyle(Color.accentColor)
            }
            .tint(Color.accentColor)
            .disabled(!hasSelection)
        } else {
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(!hasSelection)
        }
    }

    @ViewBuilder
    private func pasteMenuItem(highlighted: Bool) -> some View {
        if highlighted {
            Button(action: onPaste) {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .foregroundStyle(Color.accentColor)
            }
            .tint(Color.accentColor)
        } else {
            Button(action: onPaste) {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        }
    }

    private func secondaryControlLabel(
        title: String,
        systemImage: String,
        enabled: Bool,
        lit: Bool
    ) -> some View {
        secondaryControlLabel(
            title: title,
            enabled: enabled,
            lit: lit
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        }
    }

    private func secondaryControlLabel<Icon: View>(
        title: String,
        enabled: Bool,
        lit: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 6) {
            icon()
            if !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .foregroundStyle(secondaryForeground(lit: lit))
        .padding(.horizontal, 16)
        .frame(minWidth: 52, minHeight: 52)
        .background(
            secondaryBackground(lit: lit),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .opacity(enabled ? 1 : 0.32)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var speakBackground: Color {
        if hasFullAccess, recordingState.isRecording {
            return Color(uiColor: .systemRed)
        }

        if hasFullAccess, recordingState.isInflightPostRecording {
            // Slightly muted accent so the in-flight state reads as "still
            // working, don't tap" without flashing back to idle. Avoids a
            // second hue (red → orange → blue) that would confuse the user
            // about whether the recording succeeded.
            return Color.accentColor.opacity(0.65)
        }

        if hasFullAccess {
            return Color.accentColor
        } else {
            return Color(uiColor: .secondarySystemFill)
        }
    }

    private var speakShadow: Color {
        if hasFullAccess, recordingState.isRecording {
            return Color(uiColor: .systemRed).opacity(0.3)
        }
        if hasFullAccess {
            return Color.accentColor.opacity(0.25)
        }
        return .clear
    }

    private func secondaryBackground(lit: Bool) -> Color {
        lit ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill)
    }

    private func secondaryForeground(lit: Bool) -> Color {
        lit ? Color.accentColor : Color(uiColor: .label)
    }

    private var actionsAccessibilityHint: String {
        "Opens Copy, Paste, Undo last insertion, and Redo actions."
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

private struct PulsingRecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (isLit ? 1 : 0.32))
            .onAppear {
                guard !reduceMotion else { return }
                isLit = true
            }
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isLit
            )
    }
}
