import SwiftUI

/// First-row state shown in the Recents list while a recording is in
/// progress and the user has backed out of the hero. Mirrors the soft blue
/// gradient of `FeaturedLatestRow` and mutates the header into a pulsing
/// "RECORDING" badge with the live elapsed timer, and shows the streaming
/// partial transcript (no caret) in place of the cleaned quote body. The
/// only coral element remaining on Recents lives in `RecordingReturnPill`
/// (in `ContentView.swift`), which is a separate surface.
struct LiveStreamingRow: View {
    let streamingText: String

    /// Drives the pulsing dot. Animation is applied via a value-keyed
    /// `.animation` modifier scoped to the `Circle` alone (NOT via an
    /// imperative animation transaction in `.onAppear`), so it cannot
    /// bleed into the RECORDING tag, timer, streaming body, or card
    /// background — same safe pattern that fixed the hero recording-caret
    /// bug. Keep this file free of the imperative transaction API; an
    /// external grep contract enforces zero hits.
    @State private var dotPulseOn: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(Color.jotBlueTop)
                    .frame(width: 6, height: 6)
                    .scaleEffect(dotPulseOn ? 1.0 : 0.85)
                    .opacity(dotPulseOn ? 1.0 : 0.55)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: dotPulseOn
                    )
                    .onAppear {
                        guard !reduceMotion else { return }
                        dotPulseOn = true
                    }
                    .accessibilityHidden(true)

                Text("RECORDING")
                    .font(.system(size: 9.5, weight: .bold, design: .default))
                    .tracking(1.5)
                    .foregroundStyle(Color.jotBlueTop)

                Spacer(minLength: 8)

                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("\(elapsedString(from: startedAt, to: context.date)) · streaming")
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(Color.jotBlueTop)
                            .lineLimit(1)
                    }
                } else {
                    Text("streaming")
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(Color.jotBlueTop)
                        .lineLimit(1)
                }
            }

            LiveStreamingBody(streamingText: streamingText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [
                    Color.jotBlueTop.opacity(0.10),
                    Color.jotBlueTop.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            // Subtle blue inner-ring (mirrors the original "0 0 0 0.5px coral33
            // inset" spec, retoned to the Recents blue family) — signals the
            // card is live without dominating.
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .strokeBorder(Color.jotBlueTop.opacity(0.20), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording in progress. \(streamingText)")
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Streaming body for `LiveStreamingRow`. No caret — the previous blinking
/// caret implementation opened an animation transaction on `.onAppear` that
/// captured the entire `Text` concat (including the streaming `displayBody`),
/// producing the same "text sweeping / disappearing" symptom previously seen
/// on `RecordingHeroView`. Bare streaming text only.
private struct LiveStreamingBody: View {
    let streamingText: String

    /// Above this character count, the streaming text is split into a short
    /// head + truncated tail so the row stays compact in the list. At 17pt
    /// serif italic these values fit comfortably in 3 rendered lines.
    private static let overflowThreshold: Int = 90
    private static let headTargetChars: Int = 25
    private static let tailTargetChars: Int = 50
    /// How far past the target we'll walk to find a word boundary before
    /// giving up and cutting mid-word.
    private static let boundarySearchSlack: Int = 15

    var body: some View {
        let displayBody = Self.makeDisplayBody(from: streamingText)

        Text("\u{201C}\(displayBody)")
            .foregroundColor(Color.jotPageInk)
            .font(.system(size: 17, weight: .regular, design: .serif).italic())
            .tracking(-0.2)
            .lineSpacing(2)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: displayBody)
    }

    /// Produces the visible body string, splitting long streaming text into
    /// `<head> … <tail>` so the row stays compact while still letting the
    /// caret-end of the live transcript breathe at the bottom of the row.
    private static func makeDisplayBody(from text: String) -> String {
        guard text.count > overflowThreshold else { return text }

        let head = headSlice(of: text)
        let tail = tailSlice(of: text)
        let marker = " \u{2026} "
        let composed = head + marker + tail
        guard composed.count > 110 else { return composed }

        let tailBudget = max(0, 110 - head.count - marker.count)
        let clampedTail = String(tail.suffix(tailBudget))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + marker + clampedTail
    }

    private static func headSlice(of text: String) -> String {
        guard text.count > headTargetChars else { return text }
        let startIndex = text.startIndex
        let targetIndex = text.index(startIndex, offsetBy: headTargetChars)
        let searchEnd = text.index(targetIndex, offsetBy: boundarySearchSlack, limitedBy: text.endIndex)
            ?? text.endIndex
        let boundary = text[targetIndex..<searchEnd].firstIndex { ch in
            ch.isWhitespace || ch.isPunctuation
        }
        let cutoff = boundary ?? targetIndex
        return text[startIndex..<cutoff].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tailSlice(of text: String) -> String {
        guard text.count > tailTargetChars else { return text }
        let endIndex = text.endIndex
        let targetIndex = text.index(endIndex, offsetBy: -tailTargetChars)
        let searchStart = text.index(targetIndex, offsetBy: -boundarySearchSlack, limitedBy: text.startIndex)
            ?? text.startIndex
        let boundary = text[searchStart..<targetIndex].lastIndex { ch in
            ch.isWhitespace || ch.isPunctuation
        }
        let cutoff = boundary.flatMap { text.index($0, offsetBy: 1, limitedBy: endIndex) } ?? targetIndex
        return text[cutoff..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
