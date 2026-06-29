#if JOT_APP_HOST
import Foundation
import OSLog
import SwiftData

/// Import / export of the **entire transcript library** as one portable JSON
/// file — an independent, fully on-device safety net that does not depend on
/// iCloud Device Backup. Export writes every transcript field; import is
/// **idempotent** — it dedups by `id`, so re-importing the same file (or merging
/// an old export into a populated library) never creates duplicates.
///
/// This is the user's "I won't lose my notes" guarantee: export to Files /
/// iCloud Drive before any risky test, and import to restore.
enum TranscriptBackup {
    /// Bump if the on-disk shape changes incompatibly. Readers should refuse a
    /// `version` newer than they understand.
    static let formatVersion = 1

    private static let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "TranscriptBackup")

    struct Envelope: Codable {
        var version: Int
        var exportedAt: Date
        var transcripts: [Item]
    }

    /// One transcript, flattened to its V8 stored fields. Embeddings / chunks /
    /// the dead `category` are intentionally omitted — they're re-derivable and
    /// not user data.
    struct Item: Codable {
        var id: UUID
        var text: String
        var cleanedText: String?
        var createdAt: Date
        var durationSeconds: Double?
        var ledgerIndex: Int
        var derivedFromID: UUID?
        var instruction: String?
        var supersededAt: Date?
        var rewriteUserEdit: String?
        var rewriteUpvoted: Bool?
        var source: String?
        var watchOriginUUID: String?
        var language: String?
    }

    // MARK: - Export

    /// Encode every transcript to pretty-printed JSON (ISO-8601 dates).
    /// `@MainActor` because the SwiftData container is main-actor-isolated.
    @MainActor
    static func exportData() throws -> Data {
        let context = ModelContext(JotModelContainer.shared)
        let rows = try context.fetch(
            FetchDescriptor<Transcript>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        let items = rows.map { t in
            Item(
                id: t.id, text: t.text, cleanedText: t.cleanedText, createdAt: t.createdAt,
                durationSeconds: t.durationSeconds, ledgerIndex: t.ledgerIndex,
                derivedFromID: t.derivedFromID, instruction: t.instruction,
                supersededAt: t.supersededAt, rewriteUserEdit: t.rewriteUserEdit,
                rewriteUpvoted: t.rewriteUpvoted, source: t.source,
                watchOriginUUID: t.watchOriginUUID, language: t.language
            )
        }
        let envelope = Envelope(version: formatVersion, exportedAt: Date(), transcripts: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        log.info("Exporting \(items.count, privacy: .public) transcript(s)")
        return try encoder.encode(envelope)
    }

    // MARK: - Import

    enum ImportError: Error, LocalizedError {
        case unreadable
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't a valid Jot transcript export."
            case .unsupportedVersion(let v): return "This export was made by a newer version of Jot (format \(v)). Update Jot and try again."
            }
        }
    }

    /// Decode + insert transcripts not already present (dedup by `id`). Returns
    /// how many were added vs skipped as duplicates. One save + one mirror
    /// refresh for the whole batch.
    @discardableResult
    @MainActor
    static func importData(_ data: Data) throws -> (imported: Int, skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw ImportError.unreadable
        }
        guard envelope.version <= formatVersion else {
            throw ImportError.unsupportedVersion(envelope.version)
        }

        let context = ModelContext(JotModelContainer.shared)
        let existing = Set(try context.fetch(FetchDescriptor<Transcript>()).map { $0.id })

        var imported = 0
        var skipped = 0
        for item in envelope.transcripts {
            if existing.contains(item.id) { skipped += 1; continue }
            let transcript = Transcript(
                id: item.id,
                text: item.text,
                cleanedText: item.cleanedText,
                createdAt: item.createdAt,
                durationSeconds: item.durationSeconds,
                ledgerIndex: item.ledgerIndex,
                derivedFromID: item.derivedFromID,
                instruction: item.instruction,
                supersededAt: item.supersededAt,
                rewriteUserEdit: item.rewriteUserEdit,
                rewriteUpvoted: item.rewriteUpvoted,
                category: nil,
                source: item.source,
                watchOriginUUID: item.watchOriginUUID,
                language: item.language
            )
            context.insert(transcript)
            imported += 1
        }

        if imported > 0 {
            try context.save()
            TranscriptHistoryMirror.refresh(from: context)
        }
        log.info("Imported \(imported, privacy: .public), skipped \(skipped, privacy: .public) duplicate(s)")
        return (imported, skipped)
    }
}
#endif  // JOT_APP_HOST
