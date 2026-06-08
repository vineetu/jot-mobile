import SwiftUI

/// Default screen when the Jot watch app opens.
///
/// ## IA (build 49)
///
/// One vertically-scrollable surface (Crown-driven):
///
/// 1. **Dictate hero** (above the fold, always visible on cold open).
/// 2. **Sync ribbons** — amber "N pending sync" / green "✓ N synced",
///    only rendered when relevant. The amber ribbon grows a
///    "Sync stuck? ›" subline after 30s of unresolved pending so the
///    user can one-tap into Diagnostics when sync is actually broken.
/// 3. **"RECENT" section** — top 5 transcripts inlined, each row a
///    `NavigationLink` to `TranscriptDetailView`. "Show all (N) ›"
///    row pushes the full list when count > 5.
/// 4. **Last synced caption** — dimmed footnote.
/// 5. **"Sync diagnostics ›"** — single muted footer row, only
///    discoverable by scrolling past the transcripts. The "Sync stuck?"
///    affordance (#2 above) is the primary discovery path when sync
///    is broken.
///
/// Pre-build-49, Recents and Diagnostics were peer `NavigationLink`s on
/// a non-scrolling root. The flat `HStack { Text; Spacer; Image }`
/// labels lacked `.contentShape(Rectangle())`, so taps in the right
/// half of the Recent row often fell through and the next-nearest
/// hit-test grabbed Diagnostics — the user's "tapping Recent opens
/// Diagnostics" report. See `docs/plans/watch-ux-overhaul.md` §2.3.
struct RootView: View {
    @Environment(WatchTranscriptStore.self) private var transcriptStore
    @Environment(WatchSyncQueue.self) private var queue
    @Binding var pendingRecordRequest: Bool

    @State private var showingRecording: Bool = false
    @State private var lastSyncedCount: Int = 0
    @State private var showSyncRibbon: Bool = false
    @State private var syncRibbonTask: Task<Void, Never>?
    @State private var showingFullAlert: Bool = false

    /// True once `queue.pendingCount` has stayed > 0 for the threshold
    /// duration without an ack. Drives the "Sync stuck? ›" subline on
    /// the amber pending ribbon.
    @State private var syncStuck: Bool = false
    @State private var stuckTask: Task<Void, Never>?

    /// Empirically-chosen "stuck" threshold. Under normal phone
    /// reachability acks land in 1-5s; 30s + still pending is a strong
    /// signal that sync is genuinely broken.
    private let stuckThresholdSeconds: TimeInterval = 30

    /// How many transcripts to inline on the root before falling back
    /// to the "Show all" push.
    private let inlinePreviewCount = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JotDesignWatchSafe.watchRowSpacing + 4) {
                    dictateHero
                    syncRibbons
                    recentSection
                    diagnosticsFooter
                }
                .padding(.horizontal, JotDesignWatchSafe.watchPageGutter)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .navigationTitle("Jot")
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
            .onChange(of: queue.pendingCount, initial: true) { _, newCount in
                manageStuckWatcher(pendingCount: newCount)
            }
            .onReceive(WatchConnectivityClient.shared.ackPublisher) { count in
                showSyncRibbonForCount(count)
                // An ack means sync is alive — clear the stuck flag
                // even if pendingCount is still > 0 (more to drain).
                syncStuck = false
            }
        }
    }

    // MARK: - Hero

    private var dictateHero: some View {
        VStack(spacing: 0) {
            MicButton {
                if queue.isFull {
                    showingFullAlert = true
                    WKInterfaceDevice.current().play(.failure)
                    return
                }
                showingRecording = true
                WKInterfaceDevice.current().play(.start)
            }
            .accessibilityIdentifier("micButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Sync ribbons

    @ViewBuilder
    private var syncRibbons: some View {
        if queue.pendingCount > 0 {
            pendingRibbon
        }
        if showSyncRibbon {
            Text("✓ \(lastSyncedCount) synced")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.jotSyncSuccess)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }
    }

    private var pendingRibbon: some View {
        NavigationLink {
            DiagnosticsView()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
                Text("\(queue.pendingCount) pending sync")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
                if syncStuck {
                    Text("· Sync stuck?")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
                }
                Spacer()
            }
            .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
            .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            syncStuck
                ? "\(queue.pendingCount) recordings pending sync. Sync stuck. Double-tap to open diagnostics."
                : "\(queue.pendingCount) recordings pending sync to iPhone."
        )
        // Until the stuck signal fires, the ribbon is informational —
        // disable the NavigationLink to avoid surprising the user with
        // an unexpected push on a casual glance.
        .disabled(!syncStuck)
    }

    // MARK: - Recent section

    @ViewBuilder
    private var recentSection: some View {
        WatchSectionLabel("Recent")
        if transcriptStore.transcripts.isEmpty {
            WatchCard {
                emptyRecentRow
            }
        } else {
            WatchCard {
                VStack(spacing: 0) {
                    let visible = Array(transcriptStore.transcripts.prefix(inlinePreviewCount))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, transcript in
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

            if transcriptStore.transcripts.count > inlinePreviewCount {
                NavigationLink {
                    RecentTranscriptsView()
                } label: {
                    HStack(spacing: 6) {
                        Text("Show all (\(transcriptStore.transcripts.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(JotDesignWatchSafe.jotBlueTop)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(JotDesignWatchSafe.jotBlueTop)
                    }
                    .padding(.horizontal, JotDesignWatchSafe.watchCardPaddingH)
                    .padding(.vertical, JotDesignWatchSafe.watchCardPaddingV)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full transcript list.")
            }

            if let lastSynced = transcriptStore.lastSyncedAt {
                let staleHours = Date().timeIntervalSince(lastSynced) / 3600
                let isStale = staleHours > 24
                Text("Last synced \(lastSynced.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(
                        isStale
                            ? JotDesignWatchSafe.jotPendingAmber
                            : JotDesignWatchSafe.jotPageInkCaption
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
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
            Text("Tap Jot down to record one.")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.jotPageInkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Diagnostics footer

    private var diagnosticsFooter: some View {
        NavigationLink {
            DiagnosticsView()
        } label: {
            WatchUtilityRow(title: "Sync diagnostics", systemImage: "stethoscope")
        }
        .buttonStyle(.plain)
        .accessibilityHint("Live sync state and Reset sync button.")
        .padding(.top, 8)
    }

    // MARK: - Stuck watcher

    /// Starts / cancels the "Sync stuck?" timer based on `pendingCount`.
    /// Fires once when the count first goes >0; cancels when the count
    /// drops to 0 or an ack arrives.
    private func manageStuckWatcher(pendingCount: Int) {
        stuckTask?.cancel()
        if pendingCount == 0 {
            syncStuck = false
            return
        }
        stuckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(stuckThresholdSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if queue.pendingCount > 0 {
                syncStuck = true
            }
        }
    }

    // MARK: - Sync ribbon animation

    private func showSyncRibbonForCount(_ count: Int) {
        if showSyncRibbon {
            lastSyncedCount += count
        } else {
            lastSyncedCount = count
            withAnimation(.easeIn(duration: 0.2)) {
                showSyncRibbon = true
            }
        }
        syncRibbonTask?.cancel()
        syncRibbonTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    showSyncRibbon = false
                }
                lastSyncedCount = 0
            }
        }
    }
}

/// The "Dictate" capsule button. Brand blue gradient, mic glyph + label,
/// ~96×64 (well above the 44pt minimum target). Unchanged from build 48.
private struct MicButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                Text("Jot down")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(width: 96, height: 64)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [
                            JotDesignWatchSafe.jotBlueTop,
                            JotDesignWatchSafe.jotBlueBottom
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jot down")
        .accessibilityHint("Double-tap to begin recording.")
    }
}
