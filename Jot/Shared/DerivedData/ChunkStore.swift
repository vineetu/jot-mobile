#if JOT_APP_HOST
import Foundation
import OSLog
import SwiftData

/// Typed wrapper around the `TranscriptChunk` SwiftData entity.
///
/// Mirrors `EmbeddingStore`'s shape: `@MainActor enum` with static
/// methods, fresh `ModelContext` per call (SwiftData contexts are
/// actor-bound and cheap to construct).
///
/// ## Read shape
/// - `allChunks(modelVersion:)` — every chunk row at the current
///   `modelVersion`. Used by the retrieval cosine scan + BM25 index build.
/// - `transcriptIDsMissingChunks(modelVersion:limit:)` — Transcripts whose
///   ID has no chunk row for the given `modelVersion`, most-recent first.
///   Drives the rebuild backlog.
/// - `count(modelVersion:)` — diagnostic count for Settings.
///
/// ## Write shape
/// - `replaceChunks(...)` — delete-then-insert ALL chunks for one
///   `(transcriptID, modelVersion)` pair in a single `save()`. No
///   `@Attribute(.unique)` on the join key (lightweight migration on a
///   new-entity `.unique` constraint is inconsistent across iOS versions).
/// - `deleteAll(modelVersion:)` — drop every chunk row at a model version
///   for a from-scratch rebuild.
///
/// ## Storage shape
/// N float32 values packed little-endian into `Data`. Same packing is
/// unpacked by the `TranscriptChunk.vector: [Float]` extension.
@MainActor
enum ChunkStore {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "chunk-store"
    )

    /// Replaces ALL chunks for one transcript at the given `modelVersion`:
    /// deletes the existing rows under `(transcriptID, modelVersion)`, inserts
    /// the supplied set, and persists with one `context.save()` at the end.
    ///
    /// `createdAt` / `durationSeconds` / `source` are the parent transcript's
    /// fields, denormalized onto every chunk row so the retrieval pre-filter
    /// can scope the chunk pool without a per-chunk `Transcript` join.
    static func replaceChunks(
        transcriptID: UUID,
        chunks: [(chunkIndex: Int, text: String, vector: [Float], charStart: Int, charEnd: Int)],
        modelVersion: String,
        createdAt: Date,
        durationSeconds: Double?,
        source: String?
    ) throws {
        let context = ModelContext(JotModelContainer.shared)

        let existingDescriptor = FetchDescriptor<TranscriptChunk>(
            predicate: #Predicate<TranscriptChunk> {
                $0.transcriptID == transcriptID && $0.modelVersion == modelVersion
            }
        )
        for existing in try context.fetch(existingDescriptor) {
            context.delete(existing)
        }

        let now = Date()
        for chunk in chunks {
            let blob = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
            context.insert(TranscriptChunk(
                transcriptID: transcriptID,
                chunkIndex: chunk.chunkIndex,
                text: chunk.text,
                vectorData: blob,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                modelVersion: modelVersion,
                embeddedAt: now,
                createdAt: createdAt,
                durationSeconds: durationSeconds,
                source: source
            ))
        }
        try context.save()
    }

    /// All chunk rows at the given `modelVersion`. Full-row fetch (the cosine
    /// scan + BM25 build need `vectorData` and `text`), so callers should pull
    /// this once and reuse rather than per-query.
    static func allChunks(modelVersion: String) -> [TranscriptChunk] {
        let context = ModelContext(JotModelContainer.shared)
        let descriptor = FetchDescriptor<TranscriptChunk>(
            predicate: #Predicate<TranscriptChunk> {
                $0.modelVersion == modelVersion
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Returns up to `limit` Transcript IDs that do NOT yet have any chunk row
    /// under `modelVersion`, most-recent first. Two ID-only fetches via
    /// `propertiesToFetch` + a Set diff — full-row fetches would pull each
    /// chunk's vector blob every call, which adds up across a rebuild backlog.
    static func transcriptIDsMissingChunks(modelVersion: String, limit: Int) -> [UUID] {
        let context = ModelContext(JotModelContainer.shared)

        var chunkedDescriptor = FetchDescriptor<TranscriptChunk>(
            predicate: #Predicate<TranscriptChunk> {
                $0.modelVersion == modelVersion
            }
        )
        chunkedDescriptor.propertiesToFetch = [\.transcriptID]
        let chunked = (try? context.fetch(chunkedDescriptor)) ?? []
        let chunkedIDs = Set(chunked.map { $0.transcriptID })

        var transcriptDescriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        transcriptDescriptor.propertiesToFetch = [\.id]
        let transcripts = (try? context.fetch(transcriptDescriptor)) ?? []

        var missing: [UUID] = []
        for transcript in transcripts {
            if chunkedIDs.contains(transcript.id) { continue }
            missing.append(transcript.id)
            if missing.count >= limit { break }
        }
        return missing
    }

    static func count(modelVersion: String) -> Int {
        let context = ModelContext(JotModelContainer.shared)
        let descriptor = FetchDescriptor<TranscriptChunk>(
            predicate: #Predicate<TranscriptChunk> {
                $0.modelVersion == modelVersion
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Deletes every chunk row at the given `modelVersion`. Used for a
    /// from-scratch rebuild (e.g. after a chunker or model-version change).
    static func deleteAll(modelVersion: String) throws {
        let context = ModelContext(JotModelContainer.shared)
        try context.delete(
            model: TranscriptChunk.self,
            where: #Predicate<TranscriptChunk> {
                $0.modelVersion == modelVersion
            }
        )
        try context.save()
    }
}
#endif
