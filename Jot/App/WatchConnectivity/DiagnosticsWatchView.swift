import SwiftUI
import WatchConnectivity

/// Simple watch-sync surface for iPhone Settings. Replaces the prior
/// verbose diagnostics page that exposed every WCSession internal
/// (activation state, paired, isWatchAppInstalled, outstanding
/// transfers, last events table, pipeline stage, transcription error
/// rows). End users don't need or want that level of detail — they
/// want the answer to ONE question: "is my watch in sync, and if not,
/// what do I do?"
///
/// Surface elements:
/// - Connection status (one line, plain English)
/// - Pending recording count if any are queued
/// - Reset sync button (re-activates WCSession + re-pushes top-10)
/// - Escalation banner after two consecutive resets without a
///   successful transfer ("restart your Apple Watch")
struct DiagnosticsWatchView: View {
    @State private var snapshot: PhoneSideWCSession.StateSnapshot = PhoneSideWCSession.shared.snapshot()
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        snapshot.activationState == .activated && snapshot.isPaired && snapshot.isWatchAppInstalled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                    .padding(.top, 4)

                Button {
                    PhoneSideWCSession.shared.resetSync()
                    snapshot = PhoneSideWCSession.shared.snapshot()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Reset sync")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color.jotBlueTop, Color.jotBlueBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Re-activates Watch Connectivity and re-pushes recent transcripts to the watch.")

                if PhoneSideWCSession.shared.consecutiveResetAttempts >= 2 {
                    escalationBanner
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snapshot = PhoneSideWCSession.shared.snapshot()
            refreshTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        snapshot = PhoneSideWCSession.shared.snapshot()
                    }
                }
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isConnected ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isConnected ? "Connected" : "Not connected")
                        .font(.headline)
                        .foregroundStyle(Color.jotInk)
                    if !isConnected {
                        Text(notConnectedSubtitle)
                            .font(.footnote)
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                }
            }

            if snapshot.outstandingFileTransfers > 0 {
                Text("\(snapshot.outstandingFileTransfers) recording\(snapshot.outstandingFileTransfers == 1 ? "" : "s") waiting to sync from watch.")
                    .font(.footnote)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var notConnectedSubtitle: String {
        if !snapshot.isPaired {
            return "iPhone doesn't see a paired Apple Watch."
        }
        if !snapshot.isWatchAppInstalled {
            return "Open Jot on your Apple Watch to install it."
        }
        if snapshot.activationState != .activated {
            return "Watch Connectivity isn't active yet."
        }
        return "Couldn't reach your Apple Watch."
    }

    private var escalationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Still stuck?")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.jotInk)
            }
            Text("This is a known watchOS bug. Restart your Apple Watch: hold the side button, slide to Power Off, then power back on. Open Jot on the watch after it boots and the queued recordings should flush within ~30 seconds.")
                .font(.footnote)
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        )
    }
}
