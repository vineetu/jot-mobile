import SwiftUI

struct AliveRow: View {
    let transcript: Transcript
    let isCopied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transcript.displayText)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(Color.jotPageInk)
                    .tracking(-0.1)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCopied {
                    RecentsCopiedBadge()
                }
            }

            Text(metadataText)
                .font(.system(size: 11, weight: .medium, design: .default))
                .monospacedDigit()
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var metadataText: String {
        if let duration = RecentsFormatting.durationText(for: transcript) {
            return "\(RecentsFormatting.timeText(for: transcript)) · \(duration)"
        }
        return RecentsFormatting.timeText(for: transcript)
    }
}

struct RecentsCopiedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("Copied")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.jotSuccessInk)
        .accessibilityLabel("Copied")
    }
}
