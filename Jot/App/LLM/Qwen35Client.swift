import Foundation
import UIKit
import os.log

#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import MLXStructured
#endif

/// Errors specific to the Qwen 3.5 backend.
///
/// `malformedOutput` carries the raw JSON buffer the model produced when
/// decoding into `Rewrite` fails; grammar-constrained decoding *should*
/// make this impossible (the schema forbids invalid JSON), but we still
/// surface the buffer rather than silently throwing a generic decode error.
enum Qwen35Error: Error, Sendable, LocalizedError {
    case malformedOutput(rawBuffer: String)
    case containerNotLoaded
    /// 45s rewrite-stage timeout — used by the dictation pipeline to bound
    /// the post-transcription rewrite branch so a stuck generate stream
    /// can't strand the dictation publish forever. Surfaces as "Rewrite timed
    /// out" in the keyboard's status banner.
    case timeout

    var errorDescription: String? {
        switch self {
        case .malformedOutput:
            return "The model returned malformed output."
        case .containerNotLoaded:
            return "The model is not loaded."
        case .timeout:
            return "Rewrite timed out"
        }
    }
}

/// `LLMClient` backed by Qwen 3.5 4B (4-bit) running on MLX with
/// grammar-constrained structured output via the vendored
/// `mlx-swift-structured` fork.
///
/// This is the only rewrite backend.
///
/// ## Why Qwen needs special handling
///
/// Qwen 3.5's chat template defaults to emitting a `<think>...</think>`
/// chain-of-thought block before the actual response. The model literally
/// cannot answer without producing a thinking trace first — which would
/// leak preamble into the rewrite output.
///
/// The official suppression mechanism is documented in the model's own
/// `chat_template.jinja`:
///
/// ```jinja
/// {% if enable_thinking is defined and enable_thinking is false %}
///     <think>\n\n</think>\n\n   {# pre-fills empty thinking block #}
/// {% else %}
///     <think>\n                 {# model must produce its own CoT trace #}
/// {% endif %}
/// ```
///
/// We pass `additionalContext: ["enable_thinking": false]` into
/// `UserInput(...)`. This routes through
/// `UserInputProcessor.prepare(input:)` →
/// `Tokenizer.applyChatTemplate(messages:tools:additionalContext:)` →
/// swift-transformers's Jinja renderer with `enable_thinking=false` in scope,
/// which short-circuits the model's CoT trace by emitting an empty
/// `<think></think>` block as part of the *prompt* (not the generation).
///
/// The Mac CLI prototype (see `tmp/qwen-prototype-cli/`) validated this
/// mechanism end-to-end on five real Jot dictations. Empirical Mac
/// latency: 7.28s mean on M-series — well under the 10s rewrite budget
/// the keyboard tolerates.
///
/// Concurrency: this class is `@MainActor` to keep `observableStatus` safe to
/// read from SwiftUI views without an `await`. Inference runs inside
/// `ModelContainer.perform`, which hops to the container's actor.
///
/// `@Observable` gives SwiftUI a direct observation path on
/// `observableStatus`, so `AIRewriteSettingsView` can render the
/// download-progress / loading / ready / error rows without manual `@State`
/// mirroring. We expose `observableStatus` (synchronous getter) alongside the
/// protocol-required `status: LLMClientStatus { get async }` — both read from
/// the same backing var.
@available(iOS 26.0, *)
@MainActor
@Observable
final class Qwen35Client: LLMClient {

    static let modelID = "mlx-community/Qwen3.5-4B-4bit"

    @ObservationIgnored
    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "Qwen35Client"
    )

    @ObservationIgnored
    nonisolated private static let qwenLog = Logger(
        subsystem: "com.vineetu.jot.mobile",
        category: "rewrite"
    )

    /// SwiftUI-observable status. Changes here drive the AIRewriteSettings
    /// download/cancel/delete row state. Mutated only on `MainActor`.
    private(set) var observableStatus: LLMClientStatus = .notReady

    /// Currently-running warm Task. Held so `cancelDownload()` can cancel
    /// it. `withTaskCancellationHandler` wraps the body so the HF
    /// downloader sees a real cancellation through Swift Concurrency
    /// (the downloader respects `Task.isCancelled` checks at progress
    /// callbacks; partial chunks already on disk survive for a future
    /// resume).
    @ObservationIgnored
    private var warmTask: Task<Void, Error>?

    #if !targetEnvironment(simulator)
    @ObservationIgnored
    private var container: ModelContainer?
    #endif

    init() {
        #if !targetEnvironment(simulator)
        // Cap MLX cache so the OS can reclaim memory when other workloads
        // (Parakeet dictation, Foundation Models) are co-resident.
        Memory.cacheLimit = 32 * 1024 * 1024
        #endif
        // Probe the HF hub cache synchronously so an already-downloaded
        // Qwen snapshot starts as `.evicted`: weights are on disk, but the
        // ModelContainer has not been loaded into memory yet.
        if Self.isQwenSnapshotPresentOnDisk() {
            observableStatus = .evicted
        } else {
            observableStatus = .notReady
        }
    }

    // MARK: - LLMClient

    nonisolated var status: LLMClientStatus {
        get async {
            await MainActor.run { observableStatus }
        }
    }

    func warm() async throws {
        // If a warm Task is already in flight (e.g. user tapped Download
        // twice), join it rather than spawning a parallel download.
        if let existing = warmTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> { [weak self] in
            try await self?.runWarm()
        }
        warmTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            warmTask = nil
        } catch {
            warmTask = nil
            throw error
        }
    }

    /// Cancel an in-flight download / load. Idempotent: a no-op if no
    /// warm is running. Sets status to `.notReady` so the settings UI
    /// flips back to the download CTA. Partial download chunks already on
    /// disk survive — the HF cache resumes from where it left off on the
    /// next `warm()`.
    func cancelDownload() {
        warmTask?.cancel()
        warmTask = nil
        observableStatus = .notReady
        log.info("Qwen 3.5 download cancelled by user")
    }

    private func runWarm() async throws {
        #if targetEnvironment(simulator)
        // Simulator stand-in: pretend we loaded.
        if observableStatus != .ready {
            observableStatus = .loading
            try? await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
            observableStatus = .ready
        }
        #else
        if container != nil {
            observableStatus = .ready
            return
        }
        observableStatus = .loading
        // Request a background-grace task while `loadContainer` runs. The
        // download path inside MLX → swift-transformers' `HubApi` uses
        // `URLSession.shared` (foreground), so iOS would otherwise
        // suspend the transfer ~5s after the user backgrounds the app.
        // `beginBackgroundTask` extends that to ~30s of grace, which is
        // typically enough to either finish or hand off cleanly. NOT a
        // replacement for a real background URLSession — that's tracked
        // as a follow-up — but covers the common "user glances at
        // notifications during download" case.
        let bgTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "Qwen35.warm") { }
        }
        defer {
            Task { @MainActor in
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
        }
        do {
            // Capture the parent Task so the progress callback (running on
            // the HF downloader's queue, not Swift Concurrency) can poll
            // cancellation. The MLX loader's downloader doesn't always
            // honor `Task.checkCancellation()` internally, so we surface
            // a synthetic cancel by throwing from the progress hook on
            // each chunk arrival when the parent has been cancelled.
            _ = try await loadContainer(progress: { [weak self] fraction in
                Task { @MainActor in
                    self?.observableStatus = .downloading(fraction: fraction)
                }
            })
            try Task.checkCancellation()
            observableStatus = .ready
        } catch is CancellationError {
            log.info("Qwen 3.5 warm cancelled mid-flight")
            observableStatus = .notReady
            throw CancellationError()
        } catch {
            // If we got cancelled during the download, the underlying HF
            // bridge may surface this as a generic NSError rather than
            // CancellationError. Re-check the parent task and remap.
            if Task.isCancelled {
                log.info("Qwen 3.5 warm cancelled (remapped from \(error.localizedDescription, privacy: .public))")
                observableStatus = .notReady
                throw CancellationError()
            }
            log.error("Qwen 3.5 warm failed: \(error.localizedDescription, privacy: .public)")
            observableStatus = .error(error.localizedDescription)
            throw error
        }
        #endif
    }

    func evict() async {
        #if !targetEnvironment(simulator)
        container = nil
        Memory.clearCache()
        #endif
        observableStatus = .evicted
        log.info("Qwen 3.5 model evicted")
    }

    /// Public mirror of the on-disk snapshot probe — used by
    /// `LLMClientFactory` to gate the "Download" CTA in AI Settings.
    nonisolated static func snapshotPresentOnDisk() -> Bool {
        isQwenSnapshotPresentOnDisk()
    }

    nonisolated private static func isQwenSnapshotPresentOnDisk() -> Bool {
        let environment = ProcessInfo.processInfo.environment

        func expandedDirectoryURL(for path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }

        let cacheBase: URL
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            cacheBase = expandedDirectoryURL(for: hubCache)
        } else if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            cacheBase = expandedDirectoryURL(for: hfHome)
                .appendingPathComponent("hub", isDirectory: true)
        } else {
            cacheBase = URL.cachesDirectory
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }

        let repoDirectory = cacheBase
            .appendingPathComponent("models--mlx-community--Qwen3.5-4B-4bit", isDirectory: true)
        let refFile = repoDirectory
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("main")

        guard let commitHash = try? String(contentsOf: refFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commitHash.isEmpty
        else {
            return false
        }

        let snapshotDirectory = repoDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commitHash, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: snapshotDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path) else {
            return false
        }
        return !entries.isEmpty
    }

    func rewrite(text: String, systemPrompt: String) async throws -> String {
        Self.qwenLog.notice("Qwen35.rewrite: ENTRY chars=\(text.count, privacy: .public)")

        // Grammar-constrained decoding makes the "return only the rewritten
        // text" tail unnecessary — the JSON schema forbids preamble entirely.
        // Combined with `enable_thinking=false` below, Qwen produces clean
        // single-pass JSON: the template injects an empty `<think></think>`
        // block into the PROMPT (not the generation), and the grammar forces
        // the first generated token to be `{`, so the chain-of-thought trace
        // never appears in output.
        let userPrompt = """
            <selection>
            \(text)
            </selection>

            Rewrite the <selection> following the instructions in the system message.
            """

        Self.qwenLog.notice("Qwen35.rewrite: WARM start")
        try await warm()
        Self.qwenLog.notice("Qwen35.rewrite: WARM done")

        #if targetEnvironment(simulator)
        // Simulator: there's no MLX backend; return a clearly-marked stand-in.
        try await Task.sleep(nanoseconds: 250_000_000)
        return "[simulator stand-in] \(text)"
        #else
        guard let container else {
            throw Qwen35Error.containerNotLoaded
        }

        // Wrap the rewrite body in an inner `Task<String, Error>` so the
        // cancel-polling helper has a concrete `Task` handle to call
        // `cancel()` on when `AppGroup.rewriteCancelRequested` flips. The
        // inner task's chunk loop calls `try Task.checkCancellation()`
        // between events, so a cancel surfaces as `CancellationError` —
        // which propagates back through `try await rewriteTask.value` to
        // the intent's `catch is CancellationError` branch.
        //
        // The polling token is torn down on every exit path via `defer`.
        // Without that the polling task would survive the rewrite and
        // keep reading App Group defaults until process death.
        let rewriteTask = Task<String, Error> { [container, log] in
            struct GenerationOutcome: Sendable {
                let rawOutput: String
                let info: GenerateCompletionInfo?
            }

            Self.qwenLog.notice("Qwen35.rewrite: CONTAINER perform start")
            let outcome: GenerationOutcome = try await container.perform { ctx in
                // CRITICAL: `additionalContext: ["enable_thinking": false]`
                // is the Qwen 3.5 suppression mechanism — see class doc for
                // template branch details. This flows through to
                // `applyChatTemplate(messages:tools:additionalContext:)` and
                // pre-fills the empty `<think></think>` block in the prompt.
                let chat: [Chat.Message] = [
                    .system(systemPrompt),
                    .user(userPrompt)
                ]
                let input = try await ctx.processor.prepare(
                    input: UserInput(
                        chat: chat,
                        additionalContext: ["enable_thinking": false]
                    )
                )

                let grammar = try Grammar.generable(Rewrite.self)
                let stream = try await generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: 1024, temperature: 0.4),
                    context: ctx,
                    grammar: grammar
                )

                var buf = ""
                var info: GenerateCompletionInfo?
                var chunkCount = 0
                for await event in stream {
                    // Surface cancellation as `CancellationError` rather
                    // than silently terminating mid-stream — the intent's
                    // `catch is CancellationError` branch depends on this
                    // to write the cancellation sentinel.
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let chunk):
                        buf += chunk
                        chunkCount += 1
                        if chunkCount % 32 == 0 {
                            Self.qwenLog.notice("Qwen35.rewrite: chunks=\(chunkCount, privacy: .public)")
                        }
                    case .info(let i):
                        info = i
                    case .toolCall:
                        break
                    }
                }
                return GenerationOutcome(rawOutput: buf, info: info)
            }

            let decoded: Rewrite
            do {
                decoded = try JSONDecoder().decode(Rewrite.self, from: Data(outcome.rawOutput.utf8))
            } catch {
                Self.qwenLog.error("Qwen35.rewrite: ERROR \(error.localizedDescription, privacy: .public)")
                log.error(
                    "Rewrite JSON decode failed: \(error.localizedDescription, privacy: .public). Raw=\(outcome.rawOutput, privacy: .public)"
                )
                throw Qwen35Error.malformedOutput(rawBuffer: outcome.rawOutput)
            }

            if let info = outcome.info {
                log.info(
                    "Qwen 3.5 run: tokens=\(info.generationTokenCount) tps=\(info.tokensPerSecond, format: .fixed(precision: 2))"
                )
            } else {
                log.info("Qwen 3.5 run: no GenerateCompletionInfo emitted by stream")
            }
            Self.qwenLog.notice("Qwen35.rewrite: DECODED, returning chars=\(decoded.text.count, privacy: .public)")
            return decoded.text
        }

        // Spawn the AppGroup cancel-polling task and ensure it tears down
        // on every exit path (success, error, cancel). `withTaskCancellationHandler`
        // additionally forwards an outer cancel (e.g. structured-concurrency
        // parent cancel) into the inner task so both cancellation paths
        // converge on the same `try Task.checkCancellation()` site.
        let pollingToken = RewriteCancelPolling.observe(parent: rewriteTask)
        return try await withTaskCancellationHandler {
            defer { pollingToken.cancel() }
            return try await rewriteTask.value
        } onCancel: {
            rewriteTask.cancel()
            pollingToken.cancel()
        }
        #endif
    }

    // MARK: - Internal

    #if !targetEnvironment(simulator)
    private func loadContainer(progress: (@Sendable (Double) -> Void)?) async throws -> ModelContainer {
        if let container { return container }
        let configuration = ModelConfiguration(id: Self.modelID)
        let progressHandler: @Sendable (Progress) -> Void = { p in
            progress?(p.fractionCompleted)
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: progressHandler
        )
        self.container = loaded
        return loaded
    }
    #endif
}
