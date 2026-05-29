#if JOT_APP_HOST
import Foundation
import OSLog
import SwiftData

/// Shared chunk-embedding pipeline. ONE call site for `TranscriptStore.append`,
/// `PhoneSideWCSession.saveTranscript`, the BG backfill, and the manual
/// "Rebuild index" button — so they can never drift on guard / chunking /
/// persistence semantics.
///
/// ## Pipeline (per transcript)
///
/// 1. Bail if `AppGroup.isEmbeddingsEnabled` is off (default ON).
/// 2. Split the text into chunks (`TranscriptChunker`) — length-adaptive,
///    short notes stay a single chunk.
/// 3. Embed each chunk with **EmbeddingGemma** (`role: .document`).
/// 4. Persist the chunk set via `ChunkStore.replaceChunks(...)`, denormalizing
///    the parent transcript's `createdAt` / `durationSeconds` / `source` onto
///    each chunk so the retrieval pre-filter needs no per-chunk join.
///
/// ## Why a detached top-level task
///
/// Capture-time callers run on `@MainActor`; holding Main across the embed
/// hitches scrolling. `Task.detached(.utility)` gets the encode genuinely
/// off-Main (a structured `Task {}` would inherit MainActor and round-trip).
@MainActor
enum TranscriptIndexer {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "transcript-indexer"
    )

    /// Fire-and-forget. Returns immediately; chunk + embed + persist runs on a
    /// detached `.utility` task. Failure is logged + swallowed — the BG
    /// backfill / manual rebuild are the durable backstops.
    static func index(transcriptID: UUID, text: String) {
        guard AppGroup.isEmbeddingsEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached(priority: .utility) {
            await runIndexPipeline(transcriptID: transcriptID, text: text)
        }
    }

    /// Await variant for the BG sweep / rebuild loop (already off-Main).
    static func indexAwait(transcriptID: UUID, text: String) async {
        guard AppGroup.isEmbeddingsEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runIndexPipeline(transcriptID: transcriptID, text: text)
    }

    /// One-shot full re-index for the manual "Rebuild index" button: chunks +
    /// re-embeds EVERY transcript with the current model. `progress(done,
    /// total)` is invoked on the MainActor after each transcript. Honors
    /// cancellation between transcripts.
    static func rebuildAll(progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async {
        guard AppGroup.isEmbeddingsEnabled else { return }
        let items: [(id: UUID, text: String)] = await MainActor.run {
            let context = ModelContext(JotModelContainer.shared)
            let descriptor = FetchDescriptor<Transcript>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let transcripts = (try? context.fetch(descriptor)) ?? []
            return transcripts.map { ($0.id, $0.displayText) }
        }
        let total = items.count
        log.info("Rebuild index: \(total, privacy: .public) transcripts")
        var done = 0
        for item in items {
            if Task.isCancelled { return }
            await runIndexPipeline(transcriptID: item.id, text: item.text)
            done += 1
            if let progress {
                let snapshot = done
                await MainActor.run { progress(snapshot, total) }
            }
        }
        log.info("Rebuild index complete: \(done, privacy: .public)/\(total, privacy: .public)")
    }

    /// Number of transcripts that have NO chunks at the current model version
    /// AND have indexable text. Drives the "index your notes" prompt in Ask.
    /// Empty/whitespace notes are excluded — the chunker yields nothing for
    /// them, so they can never gain chunks; counting them left the prompt
    /// stuck at "N notes aren't indexed" forever with an Index button that
    /// appeared to do nothing.
    static func unindexedCount() -> Int {
        let missing = Set(ChunkStore.transcriptIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: Int.max
        ))
        guard !missing.isEmpty else { return 0 }
        let context = ModelContext(JotModelContainer.shared)
        let all = (try? context.fetch(FetchDescriptor<Transcript>())) ?? []
        return all.filter { transcript in
            missing.contains(transcript.id)
                && !transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// Index ONLY the transcripts that currently lack chunks (the backfill the
    /// Ask sheet offers when it finds unindexed notes). Same per-transcript
    /// pipeline as `index`, just scoped to the missing set. `progress(done, total)`.
    static func indexMissing(progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async {
        guard AppGroup.isEmbeddingsEnabled else { return }
        let items: [(id: UUID, text: String)] = await MainActor.run {
            let missing = Set(ChunkStore.transcriptIDsMissingChunks(
                modelVersion: EmbeddingGemmaService.modelVersion, limit: Int.max
            ))
            guard !missing.isEmpty else { return [] }
            let context = ModelContext(JotModelContainer.shared)
            let descriptor = FetchDescriptor<Transcript>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let all = (try? context.fetch(descriptor)) ?? []
            return all.filter { missing.contains($0.id) }.map { ($0.id, $0.displayText) }
        }
        let total = items.count
        var done = 0
        for item in items {
            if Task.isCancelled { return }
            await runIndexPipeline(transcriptID: item.id, text: item.text)
            done += 1
            if let progress {
                let snapshot = done
                await MainActor.run { progress(snapshot, total) }
            }
        }
    }

    // MARK: - Pipeline body

    private static func runIndexPipeline(transcriptID: UUID, text: String) async {
        // Chunk to ~110 tokens, NOT the chunker's 256 default: the bundled
        // EmbeddingGemma model has `max_seq_len = 128`, so anything longer is
        // silently truncated by the model (losing the chunk's tail). 110 leaves
        // headroom for the task-prefix tokens the encoder prepends. Verified via
        // the embeddinggemma-demo CLI (max_seq_len=128).
        let drafts = TranscriptChunker.chunk(text, targetTokens: 110)
        guard !drafts.isEmpty else { return }
        do {
            var embedded: [(chunkIndex: Int, text: String, vector: [Float], charStart: Int, charEnd: Int)] = []
            embedded.reserveCapacity(drafts.count)
            for draft in drafts {
                if Task.isCancelled { return }
                let vector = try await EmbeddingGemmaService.shared.encode(draft.text, role: .document)
                embedded.append((draft.chunkIndex, draft.text, vector, draft.charStart, draft.charEnd))
            }
            let chunks = embedded
            try await MainActor.run {
                let context = ModelContext(JotModelContainer.shared)
                var descriptor = FetchDescriptor<Transcript>(
                    predicate: #Predicate<Transcript> { $0.id == transcriptID }
                )
                descriptor.fetchLimit = 1
                let parent = try? context.fetch(descriptor).first
                try ChunkStore.replaceChunks(
                    transcriptID: transcriptID,
                    chunks: chunks,
                    modelVersion: EmbeddingGemmaService.modelVersion,
                    createdAt: parent?.createdAt ?? Date(),
                    durationSeconds: parent?.durationSeconds,
                    source: parent?.source
                )
            }
        } catch {
            log.debug(
                "index pipeline failed id=\(transcriptID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
#endif
