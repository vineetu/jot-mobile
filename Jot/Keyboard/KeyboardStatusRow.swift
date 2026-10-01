import SwiftUI

/// A status the keyboard reports INSIDE the surface it concerns (features.md
/// §5.10, "Option B"): the message plus a severity derived from it. Never an
/// overlay — the row is inserted into the Recents card (dictation outcomes)
/// or the actions pane (rewrite / translate outcomes) between the header and
/// the content, so nothing floats over anything.
struct KeyboardStatus: Equatable {
    enum Severity: Equatable {
        case success, warning, error, progress

        /// Tint for the row fill, hairline and icon.
        var tint: Color {
            switch self {
            case .success: return .jotSuccess
            case .warning: return .jotWarning
            case .error: return .jotRecord
            case .progress: return .jotAccent
            }
        }

        /// Readable ink for the message on the tinted row.
        var ink: Color {
            switch self {
            case .success: return .jotSuccessInk
            case .warning: return .jotWarningInk
            case .error: return .jotRecord
            case .progress: return .jotAccent
            }
        }

        var iconName: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .progress: return "arrow.triangle.2.circlepath"
            }
        }
    }

    let message: String
    let severity: Severity

    /// Classify a status message. The message set is small and fixed (the
    /// keyboard's own `setStatusBanner` calls + the cross-process dictation
    /// status), so substring matching is reliable; an unknown message defaults
    /// to a neutral heads-up — never a false success, never a red alarm.
    init(message: String) {
        self.message = message
        let m = message.lowercased()
        if m.contains("rewriting") || m.contains("translating") {
            severity = .progress
        } else if (m.contains("added") && m.contains("dictionary"))
                    || m.hasPrefix("rewritten") || m.hasPrefix("translated") {
            severity = .success
        } else if m.contains("couldn't") || m.contains("can't") || m.contains("cannot")
                    || m.contains("failed") || m.contains("error") || m.contains("no speech") {
            severity = .error
        } else {
            severity = .warning
        }
    }

    /// How long the row holds before leaving on its own. A success or a
    /// heads-up leaves after a few seconds, an error after a few more (long
    /// enough to read, never parked for good); progress stays until its
    /// outcome replaces it. A tap dismisses any of them early.
    var holdDuration: Duration? {
        switch severity {
        case .success, .warning: return .seconds(3)
        case .error: return .seconds(6)
        case .progress: return nil
        }
    }
}

/// The slim tinted status row. Grows out of the top edge of the card or pane
/// it lives in (the host animates the insertion), holds, then leaves the same
/// way; a tap dismisses it. Reduce Motion crossfades in place.
struct KeyboardStatusRow: View {
    let status: KeyboardStatus
    let reduceMotion: Bool
    let onDismiss: () -> Void

    /// The row's height — hosts subtract it from the content they push down.
    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if status.severity == .progress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(status.severity.tint)
                } else {
                    Image(systemName: status.severity.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status.severity.tint)
                }
            }
            .frame(width: 16)

            Text(status.message)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(status.severity.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(status.severity.tint.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(status.severity.tint.opacity(0.35), lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.message)
        .accessibilityHint("Double-tap to dismiss")
        .accessibilityAddTraits(.isStaticText)
        .task(id: status.message) {
            guard let hold = status.holdDuration else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    /// Insertion/removal for the host's `if let status` slot: the row slides
    /// out from under the header (the host clips that region) and fades; the
    /// reverse on the way out. Reduce Motion: opacity only.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.24)
    }
}
