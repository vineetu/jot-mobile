#if JOT_APP_HOST
import BackgroundTasks
import Foundation
import OSLog
import SwiftData

/// `BGAppRefreshTask` handler that backfills `TranscriptEmbedding` rows
/// for any transcripts whose inline embedding write missed (app
/// backgrounded between save and encode completion, encode threw,
/// embeddings toggle previously off, etc).
///
/// ## Why `BGAppRefreshTask` (not `BGProcessingTask`)
///
/// The prior Qwen classifier used `BGProcessingTask` with
/// `requiresExternalPower = true` because 2.5 GB Qwen + 2-5s per-item
/// inferences needed charging to avoid jetsam. MiniLM is 22 MB and
/// ~30-50 ms per encode — fits inside `BGAppRefreshTask`'s 30s budget,
/// and shouldn't require the user to plug in to flush a backlog. iOS
/// schedules `BGAppRefreshTask` opportunistically several times per day
/// independent of charging state, so non-charging users get fresh
/// embeddings within hours rather than days.
///
/// ## Cold-prewarm budget
///
/// On a cold BG fire (app fully suspended), `EmbeddingGemmaService`'s
/// bundle is nil and `prewarm()` must reload the model — observed range
/// 3-10s. With `batchSize = 25` at ~50 ms per encode (~1.25s total) we
/// fit inside the 30s budget with margin, but a 15s `prewarm()` timeout
/// guard fires if the cold-load tail blows out (which would otherwise
/// eat the entire budget and get the encode loop killed mid-batch by
/// `expirationHandler`).
@available(iOS 26.0, *)
@MainActor
enum EmbeddingBackfillTask {
    static let identifier = "com.vineetu.jot.mobile.Jot.backfill-embeddings"

    /// Max rows embedded per BG fire. 25 is the post-§Memory measurement
    /// gate default — halves the encode time vs. the original 50 so the
    /// cold-prewarm tax has room inside the 30s budget. Bump to 50 only
    /// after a week of field data shows the prewarm tail is bounded.
    private static let batchSize = 25

    /// Hard timeout on the cold `prewarm()` call. If the model load
    /// exceeds this, abort the batch (next BG fire retries with a fresh
    /// 30s budget) rather than burning the entire window on bundle
    /// loading and getting the encode loop killed mid-batch by iOS.
    private static let prewarmTimeoutSeconds: TimeInterval = 15

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "embedding-backfill-task"
    )

    /// First-call registration. `JotApp.init` calls this once at process
    /// startup. iOS requires registration before any submission.
    static func register() {
        _ = registerOnce
    }

    private static let registerOnce: Void = {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let workBox = TaskBox<Bool>()
            refreshTask.expirationHandler = {
                log.notice("fire EXPIRED; cancelling mid-batch")
                workBox.task?.cancel()
            }
            let taskBox = BGAppRefreshTaskBox(refreshTask)
            Task { @MainActor in
                await Self.run(taskBox.task, workBox: workBox)
            }
        }
        log.info("Registered BG task identifier")
    }()

    /// Enqueue a backfill request if (a) the Lab toggle is ON (default)
    /// and (b) there's at least one untagged Transcript. Safe to call
    /// repeatedly; `BGTaskScheduler` dedups by identifier.
    static func submitIfBacklog() {
        guard AppGroup.isEmbeddingsEnabled else {
            log.debug("submitIfBacklog: kill switch off; skipping")
            return
        }
        let missing = ChunkStore.transcriptIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: 1
        )
        guard !missing.isEmpty else {
            log.debug("submitIfBacklog: nothing untagged; skipping")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("submitIfBacklog: submitted")
        } catch {
            log.error(
                "submitIfBacklog: BGTaskScheduler.submit FAILED error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Task body

    private static func run(_ task: BGAppRefreshTask, workBox: TaskBox<Bool>) async {
        let started = Date()
        log.info("fire start")

        let work = Task<Bool, Never> { @MainActor in
            await Self.drainBatch()
        }
        workBox.task = work
        let madeProgress = await work.value
        let elapsed = Date().timeIntervalSince(started)

        let remaining = ChunkStore.transcriptIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: 1
        ).isEmpty ? 0 : 1
        log.info(
            "fire done elapsed=\(elapsed, format: .fixed(precision: 1), privacy: .public)s madeProgress=\(madeProgress, privacy: .public) hasBacklog=\(remaining, privacy: .public)"
        )

        // Report success only when the batch actually completed. iOS
        // uses this signal to shape future scheduling; falsely
        // reporting success on a cancelled/no-op fire degrades the
        // task's wake heuristics over time.
        task.setTaskCompleted(success: madeProgress)

        // Re-submit only if (a) we made some progress this fire (avoids
        // an infinite chain when encode is permanently broken) AND
        // (b) backlog remains.
        if madeProgress && remaining > 0 {
            submitIfBacklog()
        }
    }

    private static func drainBatch() async -> Bool {
        guard AppGroup.isEmbeddingsEnabled else {
            log.notice("drainBatch: kill switch off; bailing")
            return false
        }

        let missing = ChunkStore.transcriptIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: batchSize
        )
        if missing.isEmpty {
            log.debug("drainBatch: nothing missing")
            return false
        }

        // 15s prewarm guard. If model load blows out the budget, bail
        // before the encode loop ever runs — next BG fire retries fresh.
        let prewarmStart = Date()
        let prewarmed = await Self.prewarmWithTimeout(prewarmTimeoutSeconds)
        let prewarmElapsed = Date().timeIntervalSince(prewarmStart)
        log.info("drainBatch: prewarm elapsed=\(prewarmElapsed, format: .fixed(precision: 2), privacy: .public)s ok=\(prewarmed, privacy: .public)")
        if !prewarmed { return false }

        let context = ModelContext(JotModelContainer.shared)
        let modelVersion = EmbeddingGemmaService.modelVersion
        var processed = 0

        _ = modelVersion  // suppress unused; modelVersion lives inside TranscriptIndexer

        for id in missing {
            if Task.isCancelled {
                log.notice("drainBatch: cancelled at processed=\(processed, privacy: .public)")
                break
            }

            var descriptor = FetchDescriptor<Transcript>(
                predicate: #Predicate<Transcript> { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard let transcript = try? context.fetch(descriptor).first else { continue }
            let text = transcript.text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Use the shared embed+classify pipeline so backfilled rows
            // also get a category if the user has seeded centroids.
            await TranscriptIndexer.indexAwait(transcriptID: id, text: text)
            if Task.isCancelled { break }
            processed += 1
        }

        log.info("drainBatch: done processed=\(processed, privacy: .public)/\(missing.count, privacy: .public)")
        return processed > 0
    }

    /// Calls `prewarm()` with a hard wall-clock timeout. Returns `true`
    /// on success, `false` on timeout or throw.
    private static func prewarmWithTimeout(_ seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await EmbeddingGemmaService.shared.prewarm()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

@available(iOS 26.0, *)
private final class TaskBox<Success: Sendable>: @unchecked Sendable {
    var task: Task<Success, Never>?
}

@available(iOS 26.0, *)
private final class BGAppRefreshTaskBox: @unchecked Sendable {
    let task: BGAppRefreshTask
    init(_ t: BGAppRefreshTask) { self.task = t }
}
#endif
