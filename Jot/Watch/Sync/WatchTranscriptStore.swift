import Foundation
import Observation

/// Watch-side cache of the most recent 10 transcripts, pushed from the
/// iPhone via `WCSession.transferUserInfo`. Persists to a JSON file in
/// the watch app's container so the list survives app launches even
/// when the iPhone is unreachable.
///
/// **Read-only on watch.** The watch app never mutates transcripts —
/// only the iPhone writes via the existing TranscriptStore. The watch
/// is a passive viewer.
@MainActor
@Observable
final class WatchTranscriptStore {
    static let shared = WatchTranscriptStore()

    private(set) var transcripts: [WatchTranscript] = []
    private(set) var lastSyncedAt: Date?

    private let key = "watch.topTranscripts.v1"
    private let lastSyncedKey = "watch.lastSyncedAt.v1"
    private let defaults = UserDefaults.standard

    private init() {
        load()
    }

    /// Replace the cached list with the latest payload pushed from the
    /// iPhone. `received` is treated as "the newest known top-10";
    /// existing entries not in the payload are dropped.
    func replaceAll(with received: [WatchTranscript]) {
        transcripts = received.sorted { $0.createdAt > $1.createdAt }
        lastSyncedAt = Date()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WatchTranscript].self, from: data) {
            transcripts = decoded.sorted { $0.createdAt > $1.createdAt }
        }
        if let date = defaults.object(forKey: lastSyncedKey) as? Date {
            lastSyncedAt = date
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(transcripts) {
            defaults.set(data, forKey: key)
        }
        if let last = lastSyncedAt {
            defaults.set(last, forKey: lastSyncedKey)
        }
    }
}

/// A single transcript entry in the watch's cached top-10 list. Mirror
/// of just enough fields from `Transcript` to render the watch UI —
/// not the full SwiftData model.
struct WatchTranscript: Identifiable, Codable, Hashable {
    let id: String  // matches Transcript.id.uuidString on phone side
    let preview: String  // first ~200 chars of displayText
    let fullText: String  // displayText in full
    let createdAt: Date
    let source: String?  // "watch", "app", "keyboard", "shortcut", "file", or nil
}

/// Watch-side cache of "I have an audio file the phone is currently
/// transcribing." Populated by phone's `transferUserInfo({"type":
/// "transcribing", "uuid": ..., "capturedAt": ...})` message; cleared
/// when the corresponding ack arrives (the transcript shows up in the
/// top-10 payload).
@MainActor
@Observable
final class WatchPendingTranscribingStore {
    static let shared = WatchPendingTranscribingStore()

    private(set) var entries: [WatchPendingTranscribing] = []

    private let key = "watch.pendingTranscribing.v1"
    private let defaults = UserDefaults.standard

    private init() {
        load()
        pruneZombies()
    }

    func add(uuid: String, capturedAt: Date) {
        guard !entries.contains(where: { $0.id == uuid }) else { return }
        entries.append(WatchPendingTranscribing(id: uuid, capturedAt: capturedAt))
        entries.sort { $0.capturedAt > $1.capturedAt }
        persist()
    }

    func remove(uuid: String) {
        entries.removeAll { $0.id == uuid }
        persist()
    }

    /// Drop any pending-transcribing entries older than 5 minutes.
    /// Real transcriptions complete in seconds — anything older is a
    /// zombie from a session where the ack path was broken (e.g., the
    /// pre-build-46 cleanup bug that keyed by the wrong UUID). Called
    /// on launch from `init` to clean up after past bugs.
    private func pruneZombies() {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let before = entries.count
        entries.removeAll { $0.capturedAt < cutoff }
        if entries.count != before {
            persist()
        }
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WatchPendingTranscribing].self, from: data) {
            entries = decoded.sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}

struct WatchPendingTranscribing: Identifiable, Codable, Hashable {
    let id: String  // uuid of the audio file being transcribed
    let capturedAt: Date
}

/// A textless recording the watch is waiting on — surfaced as a subtle-tag
/// row at the top of Recents. Unifies the two pending sub-states so the UI
/// renders a single de-duplicated list:
/// - `.transcribing`: the phone has the audio and is producing text
///   (`WatchPendingTranscribingStore`).
/// - `.waiting`: queued on the watch, not yet acked (`WatchSyncQueue`) —
///   typically because the phone is out of range.
struct WatchPendingItem: Identifiable, Hashable {
    enum State { case waiting, transcribing }
    let id: String
    let capturedAt: Date
    let state: State
}

@MainActor
enum WatchPending {
    /// Pending = the watch's **reliable, file-backed sync queue ONLY**, newest
    /// first. An entry exists iff an unacked `.m4a` is still on disk, and it
    /// clears deterministically the moment the phone acks receipt (the ack
    /// deletes the file). It cannot orphan.
    ///
    /// We deliberately do NOT surface `WatchPendingTranscribingStore` here. That
    /// "Transcribing…" placeholder is keyed by the audio-file UUID and its ONLY
    /// clear signal is a separate app-level ack — so it orphans **permanently**
    /// whenever the phone's transcribe step throws (it sends "transcribing" but
    /// never the ack: `PhoneSideWCSession.swift`), or the ack is lost / arrives
    /// out of order (`topTranscripts` cleanup can't help — it keys on the
    /// SwiftData `transcript.id`, a different UUID space). That was the
    /// "stuck Transcribing… forever" bug. The queue is the honest source of
    /// "what hasn't reached your phone yet"; once the phone has it, a real
    /// transcript follows within seconds.
    static func waitingToSync(queue: WatchSyncQueue) -> [WatchPendingItem] {
        queue.pendingFiles
            .map { WatchPendingItem(id: $0.uuid, capturedAt: $0.capturedAt, state: .waiting) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
