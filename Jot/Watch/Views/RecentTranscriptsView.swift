import SwiftUI

/// Pushed from `RootView`'s "Show all (N)" affordance when there are
/// more than 5 transcripts to display. Read-only — tap a row to push
/// `TranscriptDetailView`. No edit / share / delete (those flows live
/// on the iPhone).
///
/// While the iPhone is transcribing a watch-originated recording, a
/// "Transcribing…" placeholder appears in a top card (state stored in
/// `WatchPendingTranscribingStore`, pushed from phone via
/// `WCSession.transferUserInfo`).
///
/// Build 49 rewrote this view to `ScrollView { LazyVStack }` + `WatchCard`
/// groupings so it matches the new visual language on `RootView`. The
/// prior `List` couldn't host the `WatchCard` shape because the system
/// row chrome paints over the card background.
struct RecentTranscriptsView: View {
    @Environment(WatchTranscriptStore.self) private var store
    @Environment(WatchPendingTranscribingStore.self) private var pending

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: JotDesignWatchSafe.watchRowSpacing + 4) {
                if !pending.entries.isEmpty {
                    transcribingCard
                }
                if store.transcripts.isEmpty && pending.entries.isEmpty {
                    WatchCard { emptyContent }
                } else if !store.transcripts.isEmpty {
                    transcriptsCard
                }
                if let lastSynced = store.lastSyncedAt {
                    lastSyncedFooter(date: lastSynced)
                }
            }
            .padding(.horizontal, JotDesignWatchSafe.watchPageGutter)
            .padding(.vertical, 6)
        }
        .navigationTitle("Recent")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    private var transcribingCard: some View {
        WatchCard {
            VStack(spacing: 0) {
                ForEach(Array(pending.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { WatchInlineDivider() }
                    TranscribingRow(entry: entry)
                }
            }
        }
    }

    private var transcriptsCard: some View {
        WatchCard {
            VStack(spacing: 0) {
                ForEach(Array(store.transcripts.enumerated()), id: \.element.id) { index, transcript in
                    if index > 0 { WatchInlineDivider() }
                    NavigationLink {
                        TranscriptDetailView(transcript: transcript)
                    } label: {
                        WatchTranscriptRow(transcript: transcript)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "mic.slash")
                .font(.title3)
                .foregroundStyle(JotDesignWatchSafe.jotPageInkCaption)
            Text("No transcripts yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
            Text("Tap Dictate to record one.")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func lastSyncedFooter(date: Date) -> some View {
        let staleHours = Date().timeIntervalSince(date) / 3600
        let isStale = staleHours > 24
        return Text("Last synced \(date.formatted(.relative(presentation: .named)))")
            .font(.caption2)
            .foregroundStyle(
                isStale
                    ? JotDesignWatchSafe.jotPendingAmber
                    : JotDesignWatchSafe.jotPageInkCaption
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }
}

// MARK: - Transcribing row

private struct TranscribingRow: View {
    let entry: WatchPendingTranscribing
    @State private var breathing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Transcribing…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                .opacity(breathing ? 0.55 : 1.0)
                .animation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: breathing
                )
            HStack(spacing: 4) {
                Text("from watch · just now")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                Image(systemName: "applewatch")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
            }
        }
        .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
        .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Transcribing recording from watch, just now")
        .onAppear { breathing = true }
    }
}
