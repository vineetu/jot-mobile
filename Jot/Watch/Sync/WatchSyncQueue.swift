import Foundation
import Observation
import os

private let queueLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "WatchSyncQueue")

/// Tracks the watch's local queue of audio files pending sync to the
/// iPhone. Each `enqueue(_:)` adds a file URL to the queue; each
/// successful ack from the phone removes it (and deletes the file).
///
/// **50-recording cap (fail-closed):** when the queue reaches 50 entries,
/// new recordings are BLOCKED at the UI layer (`RootView` reads
/// `pendingCount >= 50` and shows a "watch storage full" alert when the
/// mic button is tapped). No silent drop-oldest. The user must sync via
/// iPhone before recording more.
///
/// State persisted to UserDefaults under
/// `watch.pendingQueue.v1` (array of file UUID strings + capture
/// timestamps). The actual `.m4a` files live in
/// `Documents/Pending/<uuid>.m4a`.
@MainActor
@Observable
final class WatchSyncQueue {
    static let shared = WatchSyncQueue()

    private let defaults = UserDefaults.standard
    private let key = "watch.pendingQueue.v1"

    private(set) var pendingCount: Int = 0
    private(set) var pendingFiles: [PendingFile] = []

    /// Maximum number of pending recordings before new recordings are
    /// blocked. Matches the design doc's "50 cap, fail-closed" policy.
    static let maxPendingCount = 50

    /// `true` when at the cap and new recordings should be blocked.
    var isFull: Bool { pendingCount >= Self.maxPendingCount }

    private init() {
        load()
    }

    /// Add a freshly-stopped recording to the queue. Caller (RecordingView)
    /// must ensure `isFull == false` before calling — the queue accepts
    /// regardless to avoid losing already-captured audio mid-cap-race.
    func enqueue(_ file: RecordedFile) {
        let pending = PendingFile(
            uuid: file.uuid,
            capturedAt: file.capturedAt,
            durationSeconds: file.durationSeconds
        )
        pendingFiles.append(pending)
        pendingCount = pendingFiles.count
        persist()
        queueLog.info("enqueue uuid=\(file.uuid, privacy: .public) durationS=\(file.durationSeconds, privacy: .public) newPendingCount=\(self.pendingCount, privacy: .public)")
    }

    /// Remove a file from the queue after the phone acks receipt.
    /// Deletes the underlying `.m4a` from disk. Idempotent (silently
    /// no-ops on already-deleted UUIDs, which handles duplicate-ack replay).
    func ack(uuid: String) {
        guard let index = pendingFiles.firstIndex(where: { $0.uuid == uuid }) else {
            return
        }
        let removed = pendingFiles.remove(at: index)
        pendingCount = pendingFiles.count

        let url = WatchRecorder.pendingDirectory.appendingPathComponent("\(removed.uuid).m4a")
        try? FileManager.default.removeItem(at: url)
        persist()
    }

    /// User-initiated discard of a queued recording: remove it from the
    /// queue AND delete its local `.m4a`. Distinct from `ack(uuid:)` — that's
    /// the PHONE confirming receipt; this is the OWNER choosing not to sync a
    /// recording (e.g. a stuck one they'd rather drop). Idempotent.
    func remove(uuid: String) {
        guard let index = pendingFiles.firstIndex(where: { $0.uuid == uuid }) else {
            return
        }
        let removed = pendingFiles.remove(at: index)
        pendingCount = pendingFiles.count
        let url = WatchRecorder.pendingDirectory.appendingPathComponent("\(removed.uuid).m4a")
        try? FileManager.default.removeItem(at: url)
        persist()
        queueLog.info("user removed uuid=\(removed.uuid, privacy: .public) newPendingCount=\(self.pendingCount, privacy: .public)")
    }

    /// Local `.m4a` URL for a queued recording, if it still exists on disk.
    /// Used by `WatchPendingAudioPlayer` for tap-to-play.
    func fileURL(for uuid: String) -> URL? {
        let url = WatchRecorder.pendingDirectory.appendingPathComponent("\(uuid).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns all queued files that have a local .m4a on disk and
    /// haven't been acked. Used by `WatchConnectivityClient` to drive
    /// `transferFile` calls.
    func filesPendingTransfer() -> [(file: PendingFile, url: URL)] {
        pendingFiles.compactMap { file in
            let url = WatchRecorder.pendingDirectory.appendingPathComponent("\(file.uuid).m4a")
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return (file, url)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PendingFile].self, from: data) else {
            pendingFiles = []
            pendingCount = 0
            return
        }
        pendingFiles = decoded
        pendingCount = decoded.count
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pendingFiles) else { return }
        defaults.set(data, forKey: key)
    }
}

struct PendingFile: Codable, Hashable {
    let uuid: String
    let capturedAt: Date
    let durationSeconds: TimeInterval
}
