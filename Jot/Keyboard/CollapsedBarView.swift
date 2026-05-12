import SwiftUI

/// Phase 2.5 of the UX overhaul — collapsed-keyboard mode.
///
/// A 58pt low-profile bar the user can collapse the standard keyboard
/// into (mockup 04 idle, mockup 05 recording). Layout per plan §4.4:
///
///     [chevron-up toggle] [flex] [Dictate / Stop pill] [flex]
///
/// Stateless mirror of `KeyboardView`'s philosophy — every action is a
/// controller callback. Only the dictation pill is preserved; no recents,
/// no streaming caption, no punctuation, no globe key. Recording remains
/// fully functional in collapsed mode — the partial-transcript buffer
/// accumulates silently behind the bar (per plan §14.2).
///
/// Visual surface matches the standard keyboard chrome so toggling does
/// not feel like switching apps. Reduce-Motion compliant: the cross-fade
/// and the press-state animations both short-circuit when the
/// `accessibilityReduceMotion` environment is true.
struct CollapsedBarView: View {
    let hasFullAccess: Bool
    let recordingState: KeyboardRecordingState
    let isStopRequestPending: Bool

    /// v2 retheme (2026-05-11) — host's `keyboardAppearance` hint.
    /// Mirrors `KeyboardView.keyboardAppearance`. Either this OR the
    /// SwiftUI `colorScheme` env saying dark resolves the collapsed
    /// bar to its dark variant.
    let keyboardAppearance: UIKeyboardAppearance

    let onTapToSpeak: () -> Void
    let onOpenFullAccess: () -> Void
    let onToggleCollapsed: () -> Void

    let feedback: KeyboardFeedback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme

    /// Total bar height per plan §4.4. The host UIView's
    /// `heightAnchor` constraint pins the geometry to 58pt regardless of
    /// SwiftUI's intrinsic-size signaling — this is the visual envelope.
    static let height: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            expandButton
            Spacer(minLength: 0)
            speakButton
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            // Symmetry placeholder so the speak pill stays centered without
            // depending on the trailing edge of the chevron. 44pt matches
            // the leading chevron-toggle's footprint.
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(barBackground)
        // v2 retheme: pin the SwiftUI scheme to the resolved effective
        // scheme so every adaptive token below the collapsed bar
        // resolves consistently with the standard mode.
        .environment(\.colorScheme, effectiveColorScheme)
    }

    /// v2 retheme: dark wins if either the host or the system says dark.
    private var effectiveColorScheme: ColorScheme {
        if keyboardAppearance == .dark { return .dark }
        return systemColorScheme
    }

    // MARK: - Toggle

    /// `chevron.compact.up` — taps return to the standard 450pt layout.
    private var expandButton: some View {
        Button {
            feedback.systemClick()
            feedback.selectionTick()
            onToggleCollapsed()
        } label: {
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 22, weight: .semibold))
                // v2 retheme: adaptive ink so the chevron reads on both
                // light gray and dark chrome.
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand keyboard")
        .accessibilityHint("Returns to the full Jot keyboard")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Speak pill
    //
    // Mirrors the standard mode's `speakButton` recording-state machine:
    //   - idle (full access)        → coral `Dictate` pill + mic icon
    //   - recording                  → red `[■] mm:ss [•]` stop pill
    //   - in-flight post-recording   → `Working` spinner pill
    //   - full access denied         → secondary `Unlock` pill
    //
    // Geometry shrinks (44pt-tall vs 52pt) so the pill fits within the
    // 58pt bar with breathing room. Recording timer + accessibility
    // labels are identical to the standard mode — recording in
    // collapsed mode is a first-class state, not a degraded one.
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
                        // Stop pill content matches the standard mode's
                        // spec — white 12×12 rounded square + SF Mono
                        // timer + pulsing white dot.
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Text(elapsedText(now: context.date))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            PulsingDot(color: .white)
                        }
                    }
                } else if hasFullAccess, recordingState.isInflightPostRecording {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Working")
                            .font(JotType.chromeBold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: hasFullAccess ? "mic.fill" : "lock.shield")
                            .font(.system(size: 16, weight: .semibold))
                        // Bug A fix (2026-05-11): mirror KeyboardView's
                        // change from "Unlock" to "Enable Full Access" so
                        // the collapsed bar's no-Full-Access pill matches
                        // the standard mode's copy. See speakButton
                        // docblock in KeyboardView.swift for the full
                        // root-cause writeup.
                        Text(hasFullAccess ? "Dictate" : "Enable Full Access")
                            .font(JotType.chromeBold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            // Always white-on-blue (no-Full-Access branch included). Bug A:
            // pre-fix the no-Full-Access state used `Color.jotInk` on a
            // grey pill which read as "disabled". White-on-blue reads as
            // a primary CTA.
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(speakBackground, in: Capsule(style: .continuous))
            .shadow(color: speakShadow, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .disabled(hasFullAccess
                  && (recordingState.isInflightPostRecording
                      || isStopRequestPending))
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

    // MARK: - Backgrounds

    /// v2 retheme: collapsed bar uses the same iOS-system-gray gradient
    /// as the standard mode + the same blue-tint overlay during
    /// recording. Idle has no top hairline (chrome matches the system
    /// bar — no seam to hide); recording keeps the soft blue hairline.
    private var barBackground: some View {
        LinearGradient(
            colors: [
                Color.jotKeyboardChromeIdleTop,
                Color.jotKeyboardChromeIdleBottom,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            recordingState.isRecording
                ? Color.jotKeyboardChromeRecordingTint
                : Color.clear
        )
        .overlay(alignment: .top) {
            if recordingState.isRecording {
                Rectangle()
                    .fill(Color.jotKeyboardChromeRecordingHairline)
                    .frame(height: 0.5)
            }
        }
    }

    /// Dictate / Stop pill background — STATIC blue gradient
    /// (`#007AFF → #0064CC`) in idle + recording. In-flight dims to 65%.
    /// Hardcoding the top stop (vs `Color.jotKeyboardAccent` which adapts
    /// to dark system blue) keeps the pill pixel-identical across light
    /// and dark modes per spec.
    private static let pillTopBlue = Color(red: 0/255, green: 122/255, blue: 255/255)
    private var speakBackground: AnyShapeStyle {
        if hasFullAccess, recordingState.isInflightPostRecording {
            return AnyShapeStyle(CollapsedBarView.pillTopBlue.opacity(0.65))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    CollapsedBarView.pillTopBlue,
                    Color.jotKeyboardAccentDeep,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var speakShadow: Color {
        if hasFullAccess, recordingState.isRecording {
            return Color.jotKeyboardAccent.opacity(0.40)
        }
        return Color.jotKeyboardAccent.opacity(0.32)
    }

    // MARK: - Accessibility

    private var micAccessibilityLabel: String {
        guard hasFullAccess else { return "Enable Full Access" }
        return recordingState.isRecording ? "Stop recording" : "Tap to dictate"
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
}

// MARK: - PulsingDot (mirrored from KeyboardView)
//
// Kept local to this file so the collapsed bar has no compile-time
// dependency on KeyboardView's private types. Identical to the
// `PulsingDot` in `KeyboardView.swift` (intentional copy-paste — both
// are tiny, and the Phase 2 file is locked).
private struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false

    var body: some View {
        Circle()
            .fill(color)
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
