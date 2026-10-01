import Foundation
import Observation
import OSLog

/// Sidecar record of *how* a note's rewrite was produced (features.md §3.4):
/// which saved prompt ran and whether it ran automatically after dictation
/// (§7.14) or from a tap in the note. Keyed by transcript id and stored beside
/// the app's data — NOT in the SwiftData schema — so it needs no schema
/// version. It is removed with the rewrite (discard) or the note (delete), and
/// a missing record is not an error: the attribution line falls back to the
/// engine name.
///
/// Main app only (the keyboard never attributes rewrites).
@MainActor
enum RewriteProvenance {
    struct Record: Codable, Equatable {
        /// Display name of the saved prompt that produced the rewrite.
        let promptName: String
        /// `true` when Automatic cleanup produced it; `false` for a manual
        /// Rewrite tap in the note.
        let automatic: Bool
        /// When the rewrite landed — the "· 2 minutes ago" half of the
        /// attribution line, which the frozen schema has no field for.
        let at: Date
    }

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "rewrite-provenance"
    )

    private static var cache: [String: Record]?

    static func record(transcriptID: UUID, promptName: String, automatic: Bool, at: Date = Date()) {
        var map = load()
        map[transcriptID.uuidString] = Record(promptName: promptName, automatic: automatic, at: at)
        persist(map)
    }

    static func lookup(_ transcriptID: UUID) -> Record? {
        load()[transcriptID.uuidString]
    }

    static func remove(_ transcriptIDs: [UUID]) {
        var map = load()
        var changed = false
        for id in transcriptIDs where map.removeValue(forKey: id.uuidString) != nil {
            changed = true
        }
        if changed { persist(map) }
    }

    // MARK: - Storage

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("RewriteProvenance.json", isDirectory: false)
    }

    private static func load() -> [String: Record] {
        if let cache { return cache }
        var map: [String: Record] = [:]
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            map = (try? decoder.decode([String: Record].self, from: data)) ?? [:]
        }
        cache = map
        return map
    }

    private static func persist(_ map: [String: Record]) {
        cache = map
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(map).write(to: url, options: .atomic)
        } catch {
            log.error("provenance save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Which notes have an automatic cleanup (§7.14, "paste right away" mode)
/// still running in the background — so the home row and the open note can
/// show "Cleaning up" until the cleaned text lands, instead of the rewrite
/// appearing out of nowhere a few seconds after the note did.
@MainActor
@Observable
final class CleanupActivity {
    static let shared = CleanupActivity()

    private(set) var inFlightIDs: Set<UUID> = []

    func begin(_ transcriptID: UUID) { inFlightIDs.insert(transcriptID) }
    func end(_ transcriptID: UUID) { inFlightIDs.remove(transcriptID) }
    func isCleaning(_ transcriptID: UUID) -> Bool { inFlightIDs.contains(transcriptID) }
}
