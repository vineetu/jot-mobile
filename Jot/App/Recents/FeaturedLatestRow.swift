import SwiftUI

struct FeaturedLatestRow: View {
    let transcript: Transcript
    let isCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("LATEST")
                    .font(.system(size: 9.5, weight: .bold, design: .default))
                    .tracking(1.5)
                    .foregroundStyle(Color.jotBlueTop)

                if isCopied {
                    RecentsCopiedBadge()
                }

                Spacer(minLength: 8)

                if transcript.cleanedText != nil {
                    RecentsRewriteBadge()
                }

                Text(metaText)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
            }

            Text("\u{201C}\(transcript.displayText)\u{201D}")
                .font(.system(size: 17, weight: .regular, design: .serif).italic())
                .foregroundStyle(Color.jotPageInk)
                .tracking(-0.2)
                .lineSpacing(2)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metaText: String {
        if let duration = RecentsFormatting.durationText(for: transcript) {
            return "\(RecentsFormatting.timeText(for: transcript)) · \(duration)"
        }
        return RecentsFormatting.timeText(for: transcript)
    }

    private var accessibilityLabel: String {
        if let duration = RecentsFormatting.durationText(for: transcript) {
            return "Note, \(transcript.displayText), latest entry, \(duration)"
        }
        return "Note, \(transcript.displayText), latest entry"
    }
}
