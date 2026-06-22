import SwiftUI

/// Default screen when the Jot watch app opens.
///
/// ## IA (2026 watch refresh)
///
/// One vertically-scrollable surface (Crown-driven), opening directly on the
/// record button — no app-name title (we're already in the Watch app):
///
/// 1. **Dictate hero** — a large round glowing blue button (`WatchHeroCircle`)
///    that slowly breathes; tap to record. "Tap to dictate" caption below.
/// 2. **"Recent" section** — a header row with the section name and an
///    "All N" link (→ full list, only when > 3 transcripts). Then any
///    **pending recordings** (textless — queued or transcribing) as
///    subtle-tag cards at the TOP, followed by the most recent 3
///    transcripts, each its own card → `TranscriptDetailView`.
/// 3. **"Sync diagnostics ›"** — a single muted footer row at the very
///    bottom, only discoverable by scrolling past the transcripts. Sync is
///    automatic; this is the deliberate, quiet path to the status surface +
///    Reset sync.
///
/// The old top-of-screen amber "N pending sync" ribbon and the transient
/// green "✓ synced" ribbon were removed — pending now lives in the Recents
/// list, and a pending row quietly becoming a transcript IS the success
/// signal. See `docs/watch-redesign/design.md`.
struct RootView: View {
    @Environment(WatchTranscriptStore.self) private var transcriptStore
    @Environment(WatchSyncQueue.self) private var queue
    @Binding var pendingRecordRequest: Bool

    @State private var showingRecording: Bool = false
    @State private var showingFullAlert: Bool = false

    /// Playback of non-synced recordings (tap a pending row to hear it).
    private let player = WatchPendingAudioPlayer.shared

    /// How many transcripts to inline on the root before the "All N" link
    /// takes over.
    private let inlinePreviewCount = 3

    /// Insets for a card row — horizontal margin from the screen edge; the
    /// `WatchListCard` background adds its own vertical inset for the gap.
    private let cardInsets = EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)

    var body: some View {
        NavigationStack {
            List {
                dictateHero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))

                recentRows

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    WatchUtilityRow(title: "Sync diagnostics", systemImage: "stethoscope")
                }
                .accessibilityHint("Live sync state and Reset sync button.")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 8, trailing: 4))
            }
            .listStyle(.plain)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingRecording) {
                RecordingView()
            }
            .alert("Watch storage full", isPresented: $showingFullAlert) {
                Button("OK") {}
            } message: {
                Text("Open Jot on iPhone to sync the 50 pending recordings before you can record more.")
            }
            .onChange(of: pendingRecordRequest) { _, newValue in
                if newValue {
                    showingRecording = true
                    WKInterfaceDevice.current().play(.start)
                    pendingRecordRequest = false
                }
            }
        }
    }

    // MARK: - Hero

    private var dictateHero: some View {
        let diameter = WatchMetrics.heroDiameter
        return VStack(spacing: 22) {
            Button {
                if queue.isFull {
                    showingFullAlert = true
                    WKInterfaceDevice.current().play(.failure)
                    return
                }
                showingRecording = true
                WKInterfaceDevice.current().play(.start)
            } label: {
                WatchHeroCircle(
                    fill: JotDesignWatchSafe.watchDictateHero,
                    glow: JotDesignWatchSafe.watchDictateGlow,
                    diameter: diameter
                ) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: WatchMetrics.heroGlyph))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(HeroPressStyle())
            .accessibilityIdentifier("micButton")
            .accessibilityLabel("Dictate")
            .accessibilityHint("Double-tap to begin recording.")

            Text("Tap to dictate")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: - Recent rows

    @ViewBuilder
    private var recentRows: some View {
        let pending = WatchPending.waitingToSync(queue: queue)
        let transcripts = transcriptStore.transcripts

        recentHeaderRow(count: transcripts.count)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))

        if transcripts.isEmpty && pending.isEmpty {
            emptyRecentRow
                .listRowBackground(WatchListCard())
                .listRowInsets(cardInsets)
        } else {
            ForEach(pending) { item in
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

            ForEach(Array(transcripts.prefix(inlinePreviewCount))) { transcript in
                NavigationLink {
                    TranscriptDetailView(transcript: transcript)
                } label: {
                    WatchNoteCell(transcript: transcript)
                }
                .listRowBackground(WatchListCard())
                .listRowInsets(cardInsets)
            }
        }
    }

    /// "Recent" + (when there are more than the inlined few) a trailing
    /// "All N" that opens the full list. The whole header row is the link so
    /// it works reliably inside `List` (an inline `NavigationLink` in a row's
    /// subview is unreliable on watchOS).
    @ViewBuilder
    private func recentHeaderRow(count: Int) -> some View {
        if count > inlinePreviewCount {
            NavigationLink {
                RecentTranscriptsView()
            } label: {
                headerLabel(count: count)
            }
            .accessibilityHint("Opens the full transcript list.")
        } else {
            headerLabel(count: count)
        }
    }

    private func headerLabel(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
            Spacer()
            if count > inlinePreviewCount {
                Text("All \(count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JotDesignWatchSafe.jotBlueTop)
            }
        }
    }

    private var emptyRecentRow: some View {
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
        .padding(.vertical, 6)
    }
}
