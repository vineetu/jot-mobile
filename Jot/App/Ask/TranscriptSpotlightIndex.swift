#if JOT_APP_HOST
import CoreSpotlight
import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers

/// Core Spotlight index of the user's transcripts.
///
/// Two consumers:
///
/// 1. **System Spotlight** — every note is findable from the Home Screen
///    search; tapping a result opens it in Jot (see `JotApp`'s
///    `.onContinueUserActivity(CSSearchableItemActionType)`).
/// 2. **Ask** (iOS 27) — the Foundation Models `SpotlightSearchTool` retrieves
///    over this same index, so Ask's model can search the user's notes by
///    meaning, keyword and date with no Jot-owned embedder or vector store.
///
/// The index is a derived projection of the SwiftData store — never a source
/// of truth. `TranscriptStore` (the sole writer of `Transcript`) calls
/// `index(ids:)` / `delete(ids:)` on every mutation, and
/// `reindexAllIfNeeded()` rebuilds the projection at launch whenever
/// `indexVersion` changes (a bump re-projects every note after a mapping
/// change). Spotlight itself may also ask for a rebuild through the
/// `CSSearchableIndexDelegate` methods below.
///
/// Items never expire (Core Spotlight's default is one month) and carry the
/// full displayed text as `textContent` so both consumers see the note the
/// user sees (`Transcript.displayText`: user edit → rewrite → raw).
final class TranscriptSpotlightIndex: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    static let shared = TranscriptSpotlightIndex()

    /// Domain for every transcript item — lets a full reset delete only ours.
    static let domainIdentifier = "com.vineetu.jot.mobile.transcripts"

    /// Bump when the attribute mapping in `makeItem` changes so existing
    /// installs re-project every note on next launch.
    static let indexVersion = 1
    private static let indexVersionKey = "jot.spotlight.indexVersion"

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "spotlight-index"
    )

    /// Serialises index writes so a launch-time rebuild and a fresh append
    /// can't interleave into a stale projection.
    private static let queue = IndexQueue()

    // MARK: - Mutation hooks (called by TranscriptStore)

    /// (Re)project the given transcripts. Fire-and-forget; safe from any
    /// actor. Missing ids (deleted between the call and the fetch) are
    /// simply skipped.
    static func index(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            await queue.run {
                let items = await fetchItems(ids: ids)
                guard !items.isEmpty else { return }
                do {
                    try await CSSearchableIndex.default().indexSearchableItems(items)
                } catch {
                    log.error("index \(ids.count) item(s) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Remove the given transcripts from the index.
    static func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let identifiers = ids.map(\.uuidString)
        Task.detached(priority: .utility) {
            await queue.run {
                do {
                    try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
                } catch {
                    log.error("delete \(identifiers.count) item(s) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Full rebuild

    /// Rebuild the whole projection once per `indexVersion`. Call once per
    /// launch (after the store is open); a no-op when the version matches.
    static func reindexAllIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: indexVersionKey) != indexVersion else { return }
        Task.detached(priority: .utility) {
            let ok = await reindexAll()
            if ok { defaults.set(indexVersion, forKey: indexVersionKey) }
        }
    }

    /// Delete our domain and re-project every transcript in batches.
    /// Returns whether the rebuild completed without an indexing error.
    @discardableResult
    static func reindexAll() async -> Bool {
        await queue.run {
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
            } catch {
                log.error("reindexAll: domain delete failed: \(error.localizedDescription, privacy: .public)")
            }
            // The container is MainActor-owned; a fresh context on it is safe
            // from this executor once the container reference is in hand.
            let container = await MainActor.run { JotModelContainer.shared }
            let context = ModelContext(container)
            let all = (try? context.fetch(FetchDescriptor<Transcript>())) ?? []
            var indexed = 0
            var failed = false
            for batch in stride(from: 0, to: all.count, by: 200) {
                let slice = all[batch..<min(batch + 200, all.count)]
                let items = slice.map(makeItem)
                do {
                    try await index.indexSearchableItems(items)
                    indexed += items.count
                } catch {
                    failed = true
                    log.error("reindexAll: batch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            log.notice("reindexAll: \(indexed)/\(all.count) transcript(s) projected (version \(indexVersion))")
            return !failed
        }
    }

    // MARK: - Lookups for Ask

    /// Resolve Spotlight item identifiers (transcript UUID strings) back to
    /// transcripts, preserving the given order and dropping unknown ids.
    @MainActor
    static func fetchTranscripts(ids: [UUID]) -> [Transcript] {
        guard !ids.isEmpty else { return [] }
        let context = ModelContext(JotModelContainer.shared)
        let wanted = ids
        let descriptor = FetchDescriptor<Transcript>(predicate: #Predicate { wanted.contains($0.id) })
        let fetched = (try? context.fetch(descriptor)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    // MARK: - Item mapping

    /// Read `ids` on a fresh context and map to searchable items. Runs on
    /// whichever executor calls it — every caller owns its own context; only
    /// the (Sendable) container reference is fetched from the main actor.
    private static func fetchItems(ids: [UUID]) async -> [CSSearchableItem] {
        let container = await MainActor.run { JotModelContainer.shared }
        let context = ModelContext(container)
        let wanted = ids
        let descriptor = FetchDescriptor<Transcript>(predicate: #Predicate { wanted.contains($0.id) })
        let fetched = (try? context.fetch(descriptor)) ?? []
        return fetched.map(makeItem)
    }

    private static func makeItem(_ transcript: Transcript) -> CSSearchableItem {
        let text = transcript.displayText
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = Self.title(for: text, createdAt: transcript.createdAt)
        attributes.contentDescription = String(text.prefix(240))
        attributes.textContent = text
        attributes.contentCreationDate = transcript.createdAt
        attributes.contentModificationDate = transcript.createdAt
        attributes.identifier = transcript.id.uuidString
        if let language = transcript.language, !language.isEmpty {
            attributes.languages = [language]
        }
        let item = CSSearchableItem(
            uniqueIdentifier: transcript.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Transcripts have no titles; use the first sentence-ish (≤ 60 chars)
    /// so a Spotlight row reads like a note, with the date as a fallback.
    private static func title(for text: String, createdAt: Date) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else {
            return "Note · \(titleDateFormatter.string(from: createdAt))"
        }
        if firstLine.count <= 60 { return firstLine }
        let cut = firstLine.prefix(60)
        if let space = cut.lastIndex(where: { $0.isWhitespace }) {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    // MARK: - CSSearchableIndexDelegate

    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        // The ObjC acknowledgement block is imported non-Sendable; Spotlight
        // only requires it be called once, from any thread.
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        Task.detached(priority: .utility) {
            await Self.reindexAll()
            acknowledge()
        }
    }

    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        let ids = identifiers.compactMap(UUID.init(uuidString:))
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        Task.detached(priority: .utility) {
            await Self.queue.run {
                let items = await Self.fetchItems(ids: ids)
                if !items.isEmpty {
                    try? await CSSearchableIndex.default().indexSearchableItems(items)
                }
            }
            acknowledge()
        }
    }

    /// Full-item hydration for the Foundation Models Spotlight search tool —
    /// Spotlight stores long `textContent` in a compact, non-returnable form
    /// and asks us for the complete item when the model needs the body.
    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        searchableItemsForIdentifiers identifiers: [String],
        searchableItemsHandler: @escaping ([CSSearchableItem]) -> Void
    ) {
        let ids = identifiers.compactMap(UUID.init(uuidString:))
        nonisolated(unsafe) let deliver = searchableItemsHandler
        Task.detached(priority: .userInitiated) {
            deliver(await Self.fetchItems(ids: ids))
        }
    }
}

/// Tiny FIFO so index writes never interleave.
private actor IndexQueue {
    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await body()
    }
}
#endif
