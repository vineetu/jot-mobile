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
                    // Reserve 2 lines ALWAYS so every row is the same height
                    // regardless of text length — rows no longer resize/shrink to
                    // one line (matches selection mode). User request.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCopied {
                    RecentsCopiedBadge()
                }
            }

            HStack(spacing: 4) {
                if CleanupActivity.shared.isCleaning(transcript.id) {
                    RecentsCleaningBadge()
                } else if transcript.cleanedText != nil {
                    RecentsRewriteBadge()
                }
                Text(metadataText)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        // A background cleanup landing (§7.14) swaps the row's text and its
        // badge — fade rather than snap, so the change reads as "the cleaned
        // version arrived", not a glitch.
        .animation(.easeInOut(duration: 0.35), value: transcript.cleanedText)
        .animation(.easeInOut(duration: 0.35), value: CleanupActivity.shared.isCleaning(transcript.id))
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

/// Tiny coral sparkles glyph that flags a transcript as having been
/// AI-rewritten. Used in the home Recents rows ([`AliveRow`],
/// [`FeaturedLatestRow`]) and the keyboard Recents strip. The single static
/// coral tint (`Color.jotCoralTop`) reads on both light and dark surfaces;
/// it matches the AI iconography used in Settings + Wizard so the visual
/// language stays consistent across surfaces.
struct RecentsRewriteBadge: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.jotCoralTop)
            .accessibilityLabel("Rewritten")
    }
}

/// Shown in place of the rewrite badge while Automatic cleanup (§7.14, paste-
/// right-away mode) is still producing this note's cleaned text.
struct RecentsCleaningBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(Color.jotPageInkSecondary)
            Text("Cleaning up")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineLimit(1)
        }
        .accessibilityLabel("Cleaning up")
    }
}
