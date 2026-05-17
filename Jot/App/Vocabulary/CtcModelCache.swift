import FluidAudio
import Foundation

/// Process-wide coalescing lock so two concurrent setup/Settings/Vocab
/// taps for the boost-model load don't compile the same CoreML packages
/// twice in parallel. The bundle resources are read-only and the
/// `loadDirect` path doesn't touch the network, but the underlying
/// `MLModel(contentsOf:)` calls are non-trivial and we keep a single
/// in-flight load for symmetry with the old download-coordinator.
@MainActor
private final class CtcLoadCoordinator {
    static let shared = CtcLoadCoordinator()
    private var inFlight: Task<CtcModels, Error>?

    func ensureLoaded(directory: URL, variant: CtcModelVariant) async throws -> CtcModels {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<CtcModels, Error> {
            try await CtcModels.loadDirect(from: directory, variant: variant)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Bundle location for the Parakeet CTC 110M bundle used by the
/// vocabulary-boosting pipeline.
///
/// The CTC aux bundle (~100 MB — MelSpectrogram + AudioEncoder +
/// CtcHead CoreML packages + vocabulary/tokenizer JSON) ships inside
/// the IPA at
/// `<Bundle>/Models/Parakeet/parakeet-ctc-110m-coreml/`, so
/// vocabulary biasing is available immediately on install with no
/// separate user-initiated download. `CtcModels.loadDirect(from:)`
/// reads the `.mlmodelc` packages straight from the bundle —
/// `DownloadUtils` is bypassed entirely.
public struct CtcModelCache: Sendable {
    public let root: URL
    public let variant: CtcModelVariant

    public init(root: URL, variant: CtcModelVariant = .ctc110m) {
        self.root = root
        self.variant = variant
    }

    public static let shared: CtcModelCache = {
        let bundleRoot = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)
        return CtcModelCache(root: bundleRoot)
    }()

    /// Directory containing the CTC `.mlmodelc` packages and `vocab.json`.
    /// `CtcModels.loadDirect(from:)` reads
    /// `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc`, and
    /// `vocab.json` relative to this URL.
    public var directory: URL {
        switch variant {
        case .ctc110m:
            return root.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
        case .ctc06b:
            return root.appendingPathComponent("parakeet-ctc-06b-coreml", isDirectory: true)
        }
    }

    /// True when every file FluidAudio requires is on disk. Delegates to
    /// the SDK — only it knows the exact required file set. On a healthy
    /// install this is always true because the bundle ships the full
    /// required-set.
    public var isCached: Bool {
        CtcModels.modelsExist(at: directory)
    }

    public func ensureRootExists() throws {
        // Bundle resources are read-only; nothing to create.
    }

    /// Load the CTC aux models from the bundled directory. On healthy
    /// installs this is a pure in-process CoreML load; there is no
    /// network or download branch — `CtcModels.loadDirect(from:)` reads
    /// the `.mlmodelc` packages straight from the bundle.
    ///
    /// Coalesced via `CtcLoadCoordinator` so concurrent callers (vocab
    /// pane, settings re-warm, transcription pipeline) share a single
    /// in-flight load.
    public func ensureLoaded() async throws -> CtcModels {
        return try await CtcLoadCoordinator.shared.ensureLoaded(
            directory: directory,
            variant: variant
        )
    }

    /// No-op for bundled resources — the bundle is read-only.
    /// Retained for source-compatibility with callers that previously
    /// drove a re-download via this method.
    func removeCache() {
        // No-op.
    }
}
