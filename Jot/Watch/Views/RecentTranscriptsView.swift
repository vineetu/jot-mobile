import SwiftUI
import WatchKit

/// Pushed from `RootView`'s "All N" affordance when there are more than 3
/// transcripts. Transcripts are read-only (tap a row to push
/// `TranscriptDetailView`). Non-synced pending recordings appear at the top
/// as "Waiting to sync" cards — **tap to play** the queued audio, **swipe
/// left to delete** it (same affordances as the home list).
struct RecentTranscriptsView: View {
    @Environment(WatchTranscriptStore.self) private var store
    @Environment(WatchSyncQueue.self) private var queue
    private let player = WatchPendingAudioPlayer.shared

    private let cardInsets = EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)

    var body: some View {
        List {
            let pendingItems = WatchPending.waitingToSync(queue: queue)

            if store.transcripts.isEmpty && pendingItems.isEmpty {
                emptyContent
                    .listRowBackground(WatchListCard())
                    .listRowInsets(cardInsets)
            } else {
                ForEach(pendingItems) { item in
                    WatchPendingCell(item: item, isPlaying: player.isPlaying(item.id))
                        .listRowBackground(WatchListCard())
                        .listRowInsets(cardInsets)
                        .onTapGesture { player.toggle(item.id) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if player.isPlaying(item.id) { player.stop() }
                                queue.remove(uuid: item.id)
                                WKInterfaceDevice.current().play(.click)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                ForEach(store.transcripts) { transcript in
                    NavigationLink {
                        TranscriptDetailView(transcript: transcript)
                    } label: {
                        WatchNoteCell(transcript: transcript)
                    }
                    .listRowBackground(WatchListCard())
                    .listRowInsets(cardInsets)
                }
            }

            if let lastSynced = store.lastSyncedAt {
                lastSyncedFooter(date: lastSynced)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyContent: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "mic.slash")
                .font(.title3)
                .foregroundStyle(JotDesignWatchSafe.jotPageInkCaption)
            Text("No transcripts yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
            Text("Tap to dictate one.")
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
