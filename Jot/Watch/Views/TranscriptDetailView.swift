import SwiftUI

/// Full-text reading view for a single transcript. Pushed from the
/// root inline transcript rows or from `RecentTranscriptsView`.
/// Read-only — no edit, no actions. Crown-scrolls via standard
/// `ScrollView`. Body wrapped in a `WatchCard` (build 49) for visual
/// consistency with the rest of the watch surface.
struct TranscriptDetailView: View {
    let transcript: WatchTranscript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if transcript.source == "watch" {
                    HStack(spacing: 4) {
                        Image(systemName: "applewatch")
                            .font(.caption2)
                        Text("Recorded on watch")
                            .font(.caption2)
                    }
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                }
                WatchCard {
                    Text(transcript.fullText)
                        .font(.body)
                        .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, JotDesignWatchSafe.watchPageGutter)
            .padding(.vertical, 6)
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(transcript.createdAt, style: .date)
            Text("·")
            Text(transcript.createdAt, style: .time)
        }
        .font(.caption2)
        .foregroundStyle(JotDesignWatchSafe.jotPageInkCaption)
    }
}
