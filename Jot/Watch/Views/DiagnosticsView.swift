import SwiftUI
import WatchConnectivity

/// Simple watch-side sync surface. Surfaces only what the end user
/// needs to act on: "am I in sync, and if not, what do I do?"
///
/// - Connection status (one line, plain English)
/// - Pending recording count when any are queued
/// - Reset sync button (re-activates WCSession + re-fires queue)
/// - Escalation banner after two consecutive resets without a
///   successful transfer ("restart your Apple Watch")
///
/// Build 49 wrapped the status + Reset card in `WatchCard`s and
/// relocated entry to a buried "Sync diagnostics" footer row on
/// `RootView` (was a peer of Recents pre-build-49).
struct DiagnosticsView: View {
    @Environment(WatchSyncQueue.self) private var queue
    @State private var snapshot: WatchConnectivityClient.StateSnapshot = WatchConnectivityClient.shared.snapshot()
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        snapshot.activationState == .activated && snapshot.isCompanionAppInstalled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JotDesignWatchSafe.watchRowSpacing + 4) {
                WatchCard { statusContent }

                WatchCard(paddingH: 6, paddingV: 6) {
                    Button {
                        WatchConnectivityClient.shared.resetSync()
                        snapshot = WatchConnectivityClient.shared.snapshot()
                    } label: {
                        Text("Reset sync")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(JotDesignWatchSafe.jotBlueBottom)
                }

                if WatchConnectivityClient.shared.consecutiveResetAttempts >= 2 {
                    escalationBanner
                }
            }
            .padding(.horizontal, JotDesignWatchSafe.watchPageGutter)
            .padding(.vertical, 6)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snapshot = WatchConnectivityClient.shared.snapshot()
            refreshTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        snapshot = WatchConnectivityClient.shared.snapshot()
                    }
                }
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isConnected ? JotDesignWatchSafe.jotSyncSuccess : JotDesignWatchSafe.jotPendingAmber)
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JotDesignWatchSafe.jotPageInk)
            }
            if queue.pendingCount > 0 {
                Text("\(queue.pendingCount) waiting to sync")
                    .font(.caption2)
                    .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
            }
        }
    }

    private var escalationBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Still stuck?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(JotDesignWatchSafe.jotPendingAmber)
            Text("Known watchOS bug. Restart your Apple Watch (hold side button → Power Off → power back on).")
                .font(.caption2)
                .foregroundStyle(JotDesignWatchSafe.jotPageInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(JotDesignWatchSafe.jotPendingAmber.opacity(0.12))
        )
    }
}
