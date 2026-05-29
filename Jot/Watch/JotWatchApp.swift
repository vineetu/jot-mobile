import SwiftUI
import WatchKit

/// Standalone watchOS app entry. Hosts `RootView` (mic button + queue
/// badge + nav to recent transcripts) and handles deep-links from the
/// widget / complication to launch directly into recording.
///
/// Design doc: `docs/plans/watch-dictation-design.md`
/// Architecture doc: `docs/plans/watch-dictation.md`
@main
struct JotWatchApp: App {
    @State private var transcriptStore = WatchTranscriptStore.shared
    @State private var queue = WatchSyncQueue.shared
    @State private var pendingTranscribing = WatchPendingTranscribingStore.shared
    /// Deep-link router: set to `true` when a `jot-watch://record` URL
    /// is opened (from widget or complication). `RootView` watches this
    /// and pushes RecordingView automatically.
    @State private var pendingRecordRequest: Bool = false

    var body: some Scene {
        WindowGroup {
            RootView(pendingRecordRequest: $pendingRecordRequest)
                .environment(transcriptStore)
                .environment(queue)
                .environment(pendingTranscribing)
                .onOpenURL { url in
                    // jot-watch://record from widget or complication.
                    // RootView observes pendingRecordRequest and shows
                    // RecordingView when this flips true.
                    if url.scheme == "jot-watch" && url.host == "record" {
                        pendingRecordRequest = true
                    }
                }
                .task {
                    // Activate the WCSession on launch. Top-10
                    // transcripts and ack messages start flowing in
                    // once the session activates.
                    WatchConnectivityClient.shared.activate()
                }
        }
    }
}
