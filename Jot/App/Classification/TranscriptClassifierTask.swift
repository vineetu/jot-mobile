import BackgroundTasks
import Foundation
import OSLog
import SwiftData

/// `BGProcessingTask` handler that drains the queue of untagged transcripts
/// by running them through `TranscriptClassifier`.
///
/// ## Lifecycle
///
/// 1. `JotApp.init` calls `register()` once at process startup. This
///    associates the task identifier with our handler — required by
///    `BGTaskScheduler` before any submission.
/// 2. `JotApp` calls `submitIfEnabled()` whenever the app backgrounds
///    (and once on cold launch if the Lab toggle is on). This enqueues
///    a `BGProcessingTaskRequest` with `requiresExternalPower = true`,
///    asking iOS to fire the task during a charging window.
/// 3. iOS fires the task opportunistically. The handler:
///    - Fetches up to `batchSize` untagged transcripts (`category == nil`).
///    - Classifies each via Qwen 3.5 4B (~2-5s per transcript).
///    - Honors `task.expirationHandler` so iOS-reclaim doesn't lose work.
///    - Re-submits itself at the end if a backlog remains.
///
/// ## Lab gating
///
/// All scheduling is gated by `AppGroup.defaults.bool(forKey: labKey)`.
/// The Lab toggle in Settings flips this; default false. Code ships in
/// every binary but only runs when the user opts in.
///
/// ## Failure modes & telemetry
///
/// Every fire writes a structured `os.log` line so Vineet can pull the
/// Console log on his device and see firing patterns + per-item outcomes
/// without instrumenting Xcode. The classifier itself logs at `.info` /
/// `.error` level via its own subsystem.
@available(iOS 26.0, *)
@MainActor
enum TranscriptClassifierTask {
    /// Task identifier registered in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers`. iOS requires this string
    /// to match exactly across registration, submission, and the
    /// Info.plist declaration.
    static let identifier = "com.vineetu.jot.mobile.Jot.classify-transcripts"

    /// `UserDefaults` key that gates scheduling. Read by `submitIfEnabled()`
    /// before any BG task work. Lab Settings toggle binds to this key.
    static let labKey = "jot.classifier.enabled"

    /// Max rows classified per BG task fire. Smaller than wall-clock
    /// would allow because the bigger constraint is iOS jetsam — Qwen
    /// + MLX accumulate KV cache + intermediate buffers across
    /// inferences, and the BG memory ceiling is meaner than the
    /// foreground one. Eviction between each call (see `drainBatch`)
    /// helps, but doesn't fully eliminate the climb. 5 items per
    /// fire is the empirical "always survives" point on a 6 GB
    /// device. The task re-submits if there's a backlog, so a fresh
    /// BG window picks up the next 5 a few hours later.
    private static let batchSize = 5

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "classifier-task"
    )

    // MARK: - Registration / submission

    /// Tracks whether `register()` has already been called this process.
    /// `BGTaskScheduler.register(forTaskWithIdentifier:)` raises an
    /// exception when the same identifier is re-registered — see
    /// Apple's BGTaskScheduler docs. The SwiftUI lifecycle can re-enter
    /// `JotApp.init` for scene reconnection on some iOS versions, so
    /// guarding here is cheap insurance.
    private static let registerOnce: Void = {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            // Install the expiration handler SYNCHRONOUSLY before
            // dispatching the async body — iOS may fire expiration
            // immediately on tight budget, and a missing handler at
            // that point is a runaway-task strike against the app's
            // BG budget. The handler captures a Task box that the
            // async body fills in below, so calling .cancel() before
            // the body has started is a no-op (Optional.cancel()),
            // and calling it after cancels cleanly.
            let workBox = TaskBox<Int>()
            processingTask.expirationHandler = {
                log.notice("fire EXPIRED; cancelling mid-batch")
                workBox.task?.cancel()
            }

            // Wrap `processingTask` for the async body — `BGProcessingTask`
            // isn't Sendable, but Apple's docs guarantee the registration
            // handler is invoked on the main thread, and we hop to MainActor
            // immediately. The box is `@unchecked Sendable` for the same
            // single-writer-on-MainActor / single-reader reason TaskBox is.
            let taskBox = BGProcessingTaskBox(processingTask)
            Task { @MainActor in
                await Self.run(taskBox.task, workBox: workBox)
            }
        }
        log.info("Registered BG task identifier")
    }()

    /// Wires the identifier to our handler. Called from `JotApp.init`.
    /// First call performs registration; subsequent calls are no-ops
    /// (the `static let` is dispatch_once-equivalent in Swift).
    static func register() {
        _ = registerOnce
    }

    /// Submits a `BGProcessingTaskRequest`. No-op when the Lab toggle is
    /// off, weights aren't on disk, or there's nothing to classify.
    /// Safe to call repeatedly; `BGTaskScheduler` deduplicates by
    /// identifier (a second submission while one is pending updates the
    /// existing request).
    static func submitIfEnabled() {
        guard AppGroup.defaults.bool(forKey: labKey) else {
            log.debug("submitIfEnabled: Lab toggle off; skipping")
            return
        }

        // Mutex with the foreground "Classify now" path in the Lab
        // dashboard. Both paths iterate untagged rows and call
        // `TranscriptClassifier.classify(...)`. If both fire on the
        // same row concurrently, we waste a Qwen inference AND get a
        // last-save-wins flicker where one path's category overwrites
        // the other's. The foreground side sets this flag for the
        // duration of its loop and clears it in `defer`; BG bails
        // while set.
        guard !AppGroup.defaults.bool(forKey: AppGroup.Keys.classifierForegroundInFlight) else {
            log.notice("submitIfEnabled: foreground classifier in flight; skipping")
            return
        }

        // Don't submit if Qwen weights haven't been downloaded yet.
        // `Qwen35Client.warm()` from inside a BG task would try to
        // fetch ~2.5 GB from HuggingFace under iOS's BG memory + time
        // budget (~30s of `beginBackgroundTask`), which won't finish.
        // The user has to download Qwen explicitly via AI Settings
        // first; only then is the BG classifier viable.
        guard LLMClientFactory.shared.currentProviderWeightsOnDisk else {
            log.notice("submitIfEnabled: Qwen weights not on disk; skipping")
            return
        }

        // Skip submission entirely when there's nothing to do. Avoids
        // wasting an iOS opportunistic-scheduling slot on an empty queue.
        let queueDepth = untaggedCount()
        guard queueDepth > 0 else {
            log.debug("submitIfEnabled: queue empty; skipping")
            return
        }

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        // No `earliestBeginDate` — let iOS pick the moment based on
        // charging + idle signals.

        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("submitIfEnabled: submitted, queueDepth=\(queueDepth, privacy: .public)")
        } catch {
            log.error(
                "submitIfEnabled: BGTaskScheduler.submit FAILED error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Task body

    /// Handler invoked by iOS when the BG task fires. Drains up to
    /// `batchSize` untagged transcripts, then re-submits if a backlog
    /// remains. Hooks `expirationHandler` so iOS reclamation cancels
    /// cleanly mid-batch.
    private static func run(_ task: BGProcessingTask, workBox: TaskBox<Int>) async {
        let started = Date()
        let startDepth = untaggedCount()

        log.info(
            "fire start queueDepth=\(startDepth, privacy: .public)"
        )

        // Spawn the body and publish it to the box BEFORE awaiting so
        // the expirationHandler (installed synchronously at registration
        // time) can cancel it. If iOS fires expiration before we publish,
        // the handler's .cancel() on the box is a no-op; if after, it
        // cancels the running drain.
        let work = Task<Int, Never> { @MainActor in
            await Self.drainBatch()
        }
        workBox.task = work

        let processed = await work.value

        let elapsed = Date().timeIntervalSince(started)
        let remaining = untaggedCount()
        log.info(
            "fire done elapsed=\(elapsed, format: .fixed(precision: 1), privacy: .public)s processed=\(processed, privacy: .public) remaining=\(remaining, privacy: .public)"
        )

        task.setTaskCompleted(success: true)

        // Re-submit ONLY if we made meaningful progress AND backlog
        // remains. The `processed > 0` gate prevents an infinite
        // chain when every classification fails (parse errors,
        // Qwen unavailable, etc.) — without it, `remaining` stays at
        // startDepth and we'd ask iOS to keep firing the same broken
        // batch forever, burning user battery.
        if processed > 0 && remaining > 0 {
            submitIfEnabled()
        } else if remaining > 0 {
            log.notice("fire complete but processed=0; NOT re-submitting (likely error condition; user can re-toggle Lab to retry)")
        }
    }

    /// Drains up to `batchSize` untagged transcripts. Saves after each
    /// item so a mid-batch cancel keeps partial progress. Each
    /// `Task.checkCancellation()` check is between items so an
    /// in-flight Qwen call can finish (we'd rather wait the 2-5s than
    /// abandon a half-run inference).
    /// Returns the number of rows successfully classified + saved in
    /// this batch.
    private static func drainBatch() async -> Int {
        let context = ModelContext(JotModelContainer.shared)
        var descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate<Transcript> { $0.category == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = batchSize

        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else {
            log.notice("drainBatch: nothing untagged")
            return 0
        }

        log.info("drainBatch: \(rows.count, privacy: .public) row(s) to classify")

        let client = LLMClientFactory.shared.client()

        var processed = 0
        for row in rows {
            if Task.isCancelled {
                let snapshot = processed
                log.notice("drainBatch: cancelled at processed=\(snapshot, privacy: .public)")
                return snapshot
            }

            let category = await TranscriptClassifier.classify(text: row.text)

            // Re-check cancel AFTER the (long) classify await. The classifier
            // catches `CancellationError` internally and returns `.general` as
            // a "safe default" — but if the BG-task expiration handler fired
            // mid-await and triggered that catch, persisting `.general` would
            // permanently mis-tag the row (the fetch predicate is
            // `category == nil`, so a cancelled-substituted `.general` is
            // never reconsidered). Mirrors the post-await cancel check the
            // foreground `ClassificationsDashboardView.kickoffClassify` has.
            if Task.isCancelled {
                let snapshot = processed
                log.notice("drainBatch: cancelled post-classify at processed=\(snapshot, privacy: .public)")
                return snapshot
            }

            row.category = category.rawValue

            do {
                try context.save()
                processed += 1
            } catch {
                log.error(
                    "drainBatch: save failed id=\(row.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                context.rollback()
            }

            // Jetsam safeguard: evict Qwen between iterations. MLX
            // accumulates KV cache across inferences, and a BG task has
            // a meaner memory ceiling than the foreground app. Without
            // this, the BG task is reliably jetsammed after 3-6
            // classifications. Cold reload costs ~3-5s per item, which
            // is fine inside a BGProcessingTask budget while charging.
            // Same eviction strategy as the foreground "Classify now"
            // loop in `ClassificationsDashboardView`.
            await client.evict()
        }

        return processed
    }

    // MARK: - Queue depth probe

    /// Counts untagged transcripts. Cheap fetch, used to decide whether
    /// to bother submitting / re-submitting.
    private static func untaggedCount() -> Int {
        let context = ModelContext(JotModelContainer.shared)
        let descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate<Transcript> { $0.category == nil }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}

/// Mutable container for an `@Sendable`-captured `Task` reference.
///
/// The `BGTaskScheduler` registration closure must install
/// `task.expirationHandler` synchronously (before iOS has a chance to
/// expire the task and find no handler installed). But the work `Task`
/// is created later — inside the async body. This box lets us hand the
/// expiration handler a stable reference now and fill in the actual
/// `Task` once we spawn it; the handler can safely call `.cancel()`
/// either before or after the Task is published (Optional.cancel() is
/// a no-op on nil).
///
/// `@unchecked Sendable` because the box is mutated once on the main
/// actor (where the BG handler is dispatched) and read once on whatever
/// thread iOS invokes `expirationHandler` on. The single-writer /
/// single-reader contract via a class reference is safe for this use.
@available(iOS 26.0, *)
private final class TaskBox<Success: Sendable>: @unchecked Sendable {
    var task: Task<Success, Never>?
}

/// `@unchecked Sendable` wrapper for `BGProcessingTask`. iOS invokes the
/// `BGTaskScheduler` registration handler on the main thread, and we hop
/// to `@MainActor` immediately; the wrapper is read once on that hop and
/// never again, so the safety contract holds even though `BGProcessingTask`
/// isn't itself `Sendable`.
@available(iOS 26.0, *)
private final class BGProcessingTaskBox: @unchecked Sendable {
    let task: BGProcessingTask
    init(_ t: BGProcessingTask) { self.task = t }
}
