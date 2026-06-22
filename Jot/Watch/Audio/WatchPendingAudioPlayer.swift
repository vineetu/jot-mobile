import AVFoundation
import Observation
import WatchKit
import os

private let playerLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "WatchPendingAudioPlayer")

/// Plays back a **non-synced** recording's local `.m4a` on the watch
/// speaker — the "tap to play" affordance on a "Waiting to sync" row. Lets
/// the owner hear a queued (or stuck) recording before deciding to keep
/// waiting or delete it.
///
/// Single-track: starting a new playback stops any current one. Uses the
/// `.playback` audio session, deactivated on stop so it never holds the
/// route open (and never collides with the `.record` session the recorder
/// uses — the two are never active at once).
@MainActor
@Observable
final class WatchPendingAudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = WatchPendingAudioPlayer()

    /// UUID of the recording currently playing, or nil. Drives the row's
    /// play/stop icon.
    private(set) var playingUUID: String?

    private var player: AVAudioPlayer?

    private override init() { super.init() }

    func isPlaying(_ uuid: String) -> Bool { playingUUID == uuid }

    /// Tap behavior: tap a playing row to stop it, tap any other to play it.
    func toggle(_ uuid: String) {
        if playingUUID == uuid { stop() } else { play(uuid) }
    }

    func play(_ uuid: String) {
        stop()
        guard let url = WatchSyncQueue.shared.fileURL(for: uuid) else {
            playerLog.error("play — no file for uuid=\(uuid, privacy: .public)")
            WKInterfaceDevice.current().play(.failure)
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            guard p.play() else {
                playerLog.error("play — AVAudioPlayer.play() returned false uuid=\(uuid, privacy: .public)")
                deactivateSession()
                return
            }
            player = p
            playingUUID = uuid
            WKInterfaceDevice.current().play(.click)
            playerLog.info("play — started uuid=\(uuid, privacy: .public) dur=\(p.duration, privacy: .public)")
        } catch {
            playerLog.error("play — FAILED uuid=\(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            WKInterfaceDevice.current().play(.failure)
            deactivateSession()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if playingUUID != nil {
            playingUUID = nil
        }
        deactivateSession()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in self.stop() }
    }
}
