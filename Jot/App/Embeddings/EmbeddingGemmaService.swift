#if JOT_APP_HOST
import CoreMLLLM
import Foundation
import OSLog

/// On-device sentence-embedding encoder backed by **EmbeddingGemma-300M**
/// (Core ML / ANE via the `CoreMLLLM` package). Hides the library behind the
/// same single `encode(_:role:) -> [Float]` surface the old
/// `MiniLMEmbeddingService` exposed, so callers depend only on the `[Float]`
/// shape and a future model swap stays contained to this file.
///
/// ## Model
///
/// EmbeddingGemma-300M, **bundled in-app** under `Resources/Models/EmbeddingGemma/`
/// (folder reference, gitignored / placed out-of-band like the Parakeet speech
/// models — see `.gitignore`). No runtime download. Bundle layout the loader
/// expects (`EmbeddingGemma.load`): `encoder.mlmodelc` + `model_config.json` +
/// `hf_model/tokenizer.json`.
///
/// ## Output shape
///
/// 256-d float32, unit-norm (Matryoshka truncation of the native 768-d — the
/// `dim` arg does the truncate + L2-renormalize inside the package). Replaces
/// MiniLM's 384-d. The asymmetric `role` maps to EmbeddingGemma's task prefixes
/// (`retrieval_query` vs `retrieval_document`) — queries and documents are
/// encoded differently, which materially improves retrieval.
///
/// ## Why an `actor`
///
/// Pure transform, no UI state; the `model` + `loadTask` shared state is exactly
/// what an `actor` is for. Callers `await` from any context; encode runs on the
/// actor's executor; `[Float]` is `Sendable`.
///
/// ## Pre-warm
///
/// `JotApp.init` fires a non-blocking prewarm. First load compiles + loads the
/// Core ML model into the ANE (seconds); subsequent encodes are fast. Concurrent
/// cold callers coalesce onto one in-flight `loadTask`.
actor EmbeddingGemmaService {
    static let shared = EmbeddingGemmaService()

    /// Discriminator stamped on every embedding row written by this service.
    /// Bump when swapping the model or output dim so old rows stay
    /// distinguishable and retrieval can filter to the current version.
    static let modelVersion = "embeddinggemma-300m-256"

    /// Matryoshka output dimension. 256 balances quality vs storage/scan cost
    /// (native is 768; 128/256/512/768 are the supported truncations).
    static let outputDim = 256

    /// Asymmetric encoding role. EmbeddingGemma was trained with task prefixes;
    /// encoding a query vs a stored document differently improves recall.
    enum Role { case query, document }

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "gemma-embedding"
    )

    /// `EmbeddingGemma` is a non-`Sendable` class (it wraps an `MLModel` +
    /// tokenizer). We only ever touch it from this actor's executor, so it's
    /// effectively serialized — box it as `@unchecked Sendable` so the load
    /// `Task`'s result can cross back into actor-isolated state safely.
    private struct LoadedModel: @unchecked Sendable { let model: EmbeddingGemma }

    private var loaded: LoadedModel?
    private var loadTask: Task<LoadedModel, Error>?

    /// Force-load the bundled model. Idempotent; coalesces concurrent callers.
    func prewarm() async throws {
        _ = try await ensureModel()
    }

    /// Encode `text` into a 256-d unit-norm embedding. `role` selects the
    /// task prefix (`.query` for the question, `.document` for stored chunks).
    func encode(_ text: String, role: Role = .document) async throws -> [Float] {
        let model = try await ensureModel()
        let task: EmbeddingGemma.Task = (role == .query) ? .retrievalQuery : .retrievalDocument
        return try model.encode(text: text, task: task, dim: Self.outputDim)
    }

    private func ensureModel() async throws -> EmbeddingGemma {
        if let loaded { return loaded.model }
        if let loadTask { return try await loadTask.value.model }

        let task = Task<LoadedModel, Error> {
            let dir = try Self.bundledModelDirectory()
            Self.log.info("Loading EmbeddingGemma from bundle: \(dir.path, privacy: .public)")
            let started = Date()
            // computeUnits defaults to `.cpuAndNeuralEngine` in the package.
            let model = try await EmbeddingGemma.load(bundleURL: dir)
            let elapsed = Date().timeIntervalSince(started)
            Self.log.info("EmbeddingGemma loaded elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s")
            return LoadedModel(model: model)
        }
        loadTask = task
        do {
            let box = try await task.value
            self.loaded = box
            self.loadTask = nil
            return box.model
        } catch {
            self.loadTask = nil
            Self.log.error("EmbeddingGemma load FAILED error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Resolves the bundled model directory. The `Resources/Models` folder
    /// reference ships as `<bundle>/Models/...`, so the EmbeddingGemma bundle
    /// lands at `<bundle>/Models/EmbeddingGemma/`.
    private static func bundledModelDirectory() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw EmbeddingGemmaError.modelNotBundled("Bundle.main has no resourceURL")
        }
        let dir = resourceURL.appendingPathComponent("Models/EmbeddingGemma", isDirectory: true)
        let encoder = dir.appendingPathComponent("encoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: encoder.path) else {
            throw EmbeddingGemmaError.modelNotBundled(
                "encoder.mlmodelc not found under \(dir.path) — is the model placed in Resources/Models/EmbeddingGemma?"
            )
        }
        return dir
    }
}

enum EmbeddingGemmaError: Error, LocalizedError {
    case modelNotBundled(String)

    var errorDescription: String? {
        switch self {
        case .modelNotBundled(let detail): return "EmbeddingGemma model not bundled: \(detail)"
        }
    }
}
#endif
