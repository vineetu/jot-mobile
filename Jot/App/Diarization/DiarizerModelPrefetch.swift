import FluidAudio
import Foundation
import Network
import OSLog

/// Opportunistic launch-time prefetch of the ~190 MB Nemotron 3 diarizer so
/// Speaker Notes works instantly the moment it's announced (owner: "downloaded
/// at night, so it's ready"). Only downloads on an UNMETERED path (effectively
/// Wi-Fi) and only when the weights aren't already on disk. Kicked from the very
/// tail of `JotApp`'s serial ANE warm chain — see
/// `docs/plans/speaker-notes-productization.md` "Model availability".
///
/// ## Two review must-fixes baked in
///
/// - The `NWPathMonitor` is RETAINED in a static: a local monitor is torn down
///   before its first async `pathUpdateHandler` callback ever fires.
/// - The prefetch decision is made INSIDE `pathUpdateHandler`, never via a
///   synchronous `currentPath` read right after `start()` — that read reports
///   `.unsatisfied` because the monitor hasn't evaluated the path yet.
@MainActor
enum DiarizerModelPrefetch {
    private static let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "DiarizerPrefetch")

    /// Retained monitor. Held for the app lifetime until it fires once (then
    /// cancelled). `nil` = not started / already fired.
    private static var monitor: NWPathMonitor?
    /// One-shot latch: once we've kicked `prepareIfNeeded`, never do it again.
    private static var didKick = false

    /// Start watching for an unmetered path and prefetch the diarizer models the
    /// first time one appears while the device is otherwise idle. No-op if
    /// already watching, already kicked, or the weights are already downloaded
    /// (on-demand load then happens the first time the user diarizes — the gate
    /// exists to avoid a metered download, not to force a load at launch).
    static func prefetchWhenOnUnmeteredWiFi() {
        guard monitor == nil, !didKick else { return }
        guard !DiarizerHolder.modelsAreDownloaded else { return }

        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { path in
            // Decide INSIDE the handler. `isExpensive` covers cellular +
            // Personal Hotspot; `isConstrained` covers Low Data Mode.
            guard path.status == .satisfied, !path.isExpensive, !path.isConstrained else { return }
            Task { @MainActor in
                guard !didKick else { return }
                // Bail if a recording/transcription is in flight —
                // `prepareIfNeeded` downloads AND loads the CoreML graph, and
                // must never contend with the model the user's active dictation
                // needs (same posture as `warmNonSelectedDictationModelsWhenIdle`).
                guard !RecordingService.shared.isRecording,
                      !TranscriptionService.shared.isBusy else { return }
                didKick = true
                stop()
                log.info("prefetching offline diarizer models on unmetered path")
                await DiarizerHolder.shared.prepareIfNeeded()
            }
        }
        m.start(queue: DispatchQueue(label: "com.vineetu.jot.diarizer-prefetch"))
    }

    private static func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
