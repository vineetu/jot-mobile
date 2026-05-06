import Foundation
import os.log

#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import MLXStructured
import FoundationModels
#endif

/// Grammar-constrained rewrite payload. The `@Generable` macro projects this
/// into a JSON schema that `mlx-swift-structured` enforces during decoding,
/// so the model literally cannot emit preamble like "Here is the rewritten
/// text:" — only valid JSON matching this shape.
#if !targetEnvironment(simulator)
@available(iOS 26.0, *)
@Generable
struct Rewrite: Codable {
    @Guide(description: "The rewritten text only — no preamble, no quotes, no explanation")
    let text: String
}
#endif

struct RunStats: Equatable, Sendable {
    var timeToFirstTokenMS: Int
    var totalMS: Int
    var tokensGenerated: Int
    var tokensPerSecond: Double
    var availableMemoryMinMB: Int
    var availableMemoryBaselineMB: Int
    var coldLoad: Bool
}

@MainActor
@Observable
final class Phi4Engine {
    enum Status: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case loading
        case ready
        case evicted
        case error(String)
    }

    private(set) var status: Status = .notDownloaded
    private(set) var lastStats: RunStats?

    static let modelID = "mlx-community/Phi-4-mini-instruct-4bit"

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot.Phi4Prototype", category: "Phi4Engine")

    #if !targetEnvironment(simulator)
    private var container: ModelContainer?
    #endif

    init() {
        #if !targetEnvironment(simulator)
        // Cap MLX cache so the OS can reclaim memory when other workloads (Parakeet) co-resident.
        Memory.cacheLimit = 32 * 1024 * 1024
        #endif
        // Initial status: probe whether the snapshot already exists in the HF cache.
        if isCachedSnapshotPresent() {
            status = .evicted // weights on disk, but model not loaded into memory
        } else {
            status = .notDownloaded
        }
    }

    // MARK: - Public API

    func download() async {
        #if targetEnvironment(simulator)
        status = .downloading(fraction: 0.5)
        try? await Task.sleep(nanoseconds: 300_000_000)
        status = .evicted
        #else
        status = .downloading(fraction: 0)
        do {
            _ = try await loadContainer(progress: { fraction in
                Task { @MainActor in
                    self.status = .downloading(fraction: fraction)
                }
            })
            status = .ready
        } catch {
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
        #endif
    }

    @discardableResult
    func ensureLoaded() async throws -> Bool {
        // Returns true if this call performed a cold load (model loaded from disk),
        // false if model was already warm.
        #if targetEnvironment(simulator)
        if status != .ready {
            status = .loading
            try? await Task.sleep(nanoseconds: 200_000_000)
            status = .ready
            return true
        }
        return false
        #else
        if container != nil {
            return false
        }
        status = .loading
        let _ = try await loadContainer(progress: nil)
        status = .ready
        return true
        #endif
    }

    func rewrite(text: String, systemPrompt: String, instruction: String) async throws -> String {
        // Grammar-constrained decoding makes the "return only the rewritten text"
        // tail unnecessary — the JSON schema forbids preamble entirely.
        let userPrompt = """
            <instruction>
            \(instruction)
            </instruction>

            <selection>
            \(text)
            </selection>

            Follow the <instruction> above. Rewrite the <selection>.
            """

        let baselineMB = availableMemoryMB()
        let minHolder = MinHolder(initial: baselineMB)

        // Run a 100 ms ticker to sample memory during inference.
        let sampler = MemorySampler { sample in
            minHolder.update(sample)
        }
        sampler.start()
        defer { sampler.stop() }

        let coldLoad = try await ensureLoaded()
        let runStart = ContinuousClock.now

        #if targetEnvironment(simulator)
        try await Task.sleep(nanoseconds: 250_000_000)
        let output = "[simulator stand-in] \(text)"
        let totalMS = Int(runStart.duration(to: .now).milliseconds)
        let stats = RunStats(
            timeToFirstTokenMS: 0,
            totalMS: totalMS,
            tokensGenerated: output.split(separator: " ").count,
            tokensPerSecond: 0,
            availableMemoryMinMB: minHolder.value,
            availableMemoryBaselineMB: baselineMB,
            coldLoad: coldLoad
        )
        self.lastStats = stats
        return output
        #else
        guard let container else {
            throw NSError(domain: "Phi4Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Container not loaded"])
        }

        // Grammar-constrained generation. The Phi-4 chat template needs system + user
        // messages; we shape them into model-specific message dicts and let the
        // configured `UserInputProcessor` apply the chat template inside the actor.
        // We keep streaming so we can measure TTFT, then JSON-decode the accumulated
        // payload at the end.
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        // Run the entire structured-generation loop inside `container.perform`
        // so the non-Sendable ModelContext stays inside actor isolation.
        // We return the (output, ttftMS) pair from the closure. JSON-decode happens
        // outside so any decoding error surfaces with a useful message.
        struct GenerationOutcome: Sendable {
            let rawOutput: String
            let ttftMS: Int
        }

        let runStartCopy = runStart
        let outcome: GenerationOutcome = try await container.perform { ctx in
            let input = try await ctx.processor.prepare(input: UserInput(messages: messages))

            let grammar = try Grammar.generable(Rewrite.self)
            let stream = try await generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 1024, temperature: 0.4),
                context: ctx,
                grammar: grammar
            )

            var buf = ""
            var firstAt: ContinuousClock.Instant?
            for await event in stream {
                if Task.isCancelled { break }
                if let chunk = event.chunk {
                    if firstAt == nil { firstAt = .now }
                    buf += chunk
                }
            }
            let ttft = firstAt.map { Int(runStartCopy.duration(to: $0).milliseconds) } ?? 0
            return GenerationOutcome(rawOutput: buf, ttftMS: ttft)
        }

        // Decode the JSON payload (forced by the schema) into the typed Rewrite.
        // If decoding fails we still surface the raw output for diagnostics.
        let output: String
        do {
            let decoded = try JSONDecoder().decode(Rewrite.self, from: Data(outcome.rawOutput.utf8))
            output = decoded.text
        } catch {
            log.error("Rewrite JSON decode failed: \(error.localizedDescription, privacy: .public). Raw=\(outcome.rawOutput, privacy: .public)")
            throw error
        }

        let endAt = ContinuousClock.now
        let totalMS = Int(runStart.duration(to: endAt).milliseconds)

        // Token count: tokenize the raw (JSON) output via the container's tokenizer.
        // We count tokens of the model's actual emission, not the post-decoded text.
        let raw = outcome.rawOutput
        let tokens = await container.perform { ctx in
            ctx.tokenizer.encode(text: raw, addSpecialTokens: false)
        }
        let tokenCount = tokens.count
        let seconds = max(0.001, Double(totalMS) / 1000.0)
        let tps = Double(tokenCount) / seconds

        let stats = RunStats(
            timeToFirstTokenMS: outcome.ttftMS,
            totalMS: totalMS,
            tokensGenerated: tokenCount,
            tokensPerSecond: tps,
            availableMemoryMinMB: minHolder.value,
            availableMemoryBaselineMB: baselineMB,
            coldLoad: coldLoad
        )
        self.lastStats = stats
        log.info("Run done: ttft=\(outcome.ttftMS)ms total=\(totalMS)ms tokens=\(tokenCount) tps=\(tps, format: .fixed(precision: 2))")
        return output
        #endif
    }

    func evict() {
        #if !targetEnvironment(simulator)
        container = nil
        Memory.clearCache()
        #else
        // No-op on simulator
        #endif
        status = .evicted
        lastStats = nil
        log.info("Model evicted")
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

    /// Best-effort check for an already-downloaded snapshot in the HF cache.
    /// Note: the MLX Hugging Face bridge owns its cache root; we can't perfectly
    /// probe it without depending on internals. We treat the engine as `.notDownloaded`
    /// at first launch and let the first `download()` decide.
    private func isCachedSnapshotPresent() -> Bool {
        // Conservative: return false. The download() call will short-circuit if
        // snapshot is already cached.
        return false
    }
}

/// Thread-safe minimum tracker used during inference to find the worst-case
/// available-memory snapshot from a background sampler.
final class MinHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(initial: Int) { self._value = initial }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func update(_ sample: Int) {
        lock.lock(); defer { lock.unlock() }
        if sample < _value { _value = sample }
    }
}

/// Lightweight foreground-only memory sampler. Owns a private dispatch source.
/// Callbacks hop to the main actor before invoking the user closure.
final class MemorySampler: @unchecked Sendable {
    private let interval: TimeInterval
    private let onSample: @Sendable (Int) -> Void
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval = 0.1, onSample: @Sendable @escaping (Int) -> Void) {
        self.interval = interval
        self.onSample = onSample
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: interval)
        let cb = onSample
        t.setEventHandler {
            cb(availableMemoryMB())
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

extension Duration {
    /// Total milliseconds as a Double.
    var milliseconds: Double {
        let comps = self.components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1.0e15
    }
}
