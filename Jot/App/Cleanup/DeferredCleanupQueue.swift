import Foundation
import OSLog

/// Automatic cleanups that could not run because Apple's on-device model
/// rate-limited Jot while it was in the background (features.md §7.14): the
/// raw words already pasted, the note is saved raw, and the cleanup is owed.
/// The queue is drained the next time Jot comes to the foreground
/// (`DictationPipeline.drainDeferredCleanups`), where the rate limit does not
/// apply, and the cleaned text lands on the note's Rewrite tab. Nothing here
/// waits or retries in the background.
///
/// Persisted as JSON in Application Support (same pattern as
/// `RewriteProvenance`), so it survives a relaunch. FIFO, de-duplicated.
/// Main app only.
@MainActor
enum DeferredCleanupQueue {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "deferred-cleanup"
    )

    private static var cache: [UUID]?

    /// Oldest first.
    static var pending: [UUID] { load() }

    static func enqueue(_ transcriptID: UUID) {
        var ids = load()
        guard !ids.contains(transcriptID) else { return }
        ids.append(transcriptID)
        persist(ids)
    }

    static func remove(_ transcriptID: UUID) {
        var ids = load()
        guard let i = ids.firstIndex(of: transcriptID) else { return }
        ids.remove(at: i)
        persist(ids)
    }

    static func removeAll() {
        guard !load().isEmpty else { return }
        persist([])
    }

    // MARK: - Storage

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("DeferredCleanupQueue.json", isDirectory: false)
    }

    private static func load() -> [UUID] {
        if let cache { return cache }
        var ids: [UUID] = []
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            ids = (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
        }
        cache = ids
        return ids
    }

    private static func persist(_ ids: [UUID]) {
        cache = ids
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ids).write(to: url, options: .atomic)
        } catch {
            log.error("deferred cleanup queue save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
