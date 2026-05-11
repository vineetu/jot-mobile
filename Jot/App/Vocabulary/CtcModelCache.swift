import FluidAudio
import Foundation

/// Process-wide coalescing lock so two concurrent setup/Settings/Vocab
/// taps for the boost-model download don't race on the same files.
/// FluidAudio's `DownloadUtils` has no in-flight lock — it checks
/// existence then proceeds, so two simultaneous calls into
/// `CtcModels.downloadAndLoad` can both start fetching the same
/// CoreML packages in parallel. The wrapper below funnels concurrent
/// callers into a single Task that the second tap simply awaits.
@MainActor
private final class CtcDownloadCoordinator {
    static let shared = CtcDownloadCoordinator()
    private var inFlight: Task<CtcModels, Error>?

    func ensureLoaded(directory: URL, variant: CtcModelVariant) async throws -> CtcModels {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<CtcModels, Error> {
            try await CtcModels.downloadAndLoad(to: directory, variant: variant)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// On-disk location for the Parakeet CTC 110M bundle used by the
/// vocabulary-boosting pipeline.
///
/// Mirrors the main TDT model's `MLModelConfigurationUtils.defaultModelsDirectory`
/// pattern: the CTC encoder lives under the app's own Application
/// Support subtree so "delete Jot's data" is a single directory remove
/// and users don't see an orphan "FluidAudio" folder in their iOS
/// Files app.
///
/// The CTC bundle is ≈100 MB (MelSpectrogram + AudioEncoder + CtcHead
/// CoreML packages + vocabulary/tokenizer JSON) and is **separate from
/// the primary TDT model** — downloading one does not imply the other.
/// On iOS, the user must explicitly opt in to this download via the
/// Vocabulary pane (App Store 4.2.3(ii) consent).
///
/// Ported from `jot/Sources/Transcription/CtcModelCache.swift`.
public struct CtcModelCache: Sendable {
    public let root: URL
    public let variant: CtcModelVariant

    public init(root: URL, variant: CtcModelVariant = .ctc110m) {
        self.root = root
        self.variant = variant
    }

    public static let shared: CtcModelCache = {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Mobile keeps the Application Support root flat — the app
        // sandbox already isolates per-app data, so a "Jot" subdir
        // would be redundant. Models live under "Models/" alongside
        // the TDT and EOU caches.
        return CtcModelCache(
            root: appSupport.appendingPathComponent("Models", isDirectory: true)
        )
    }()

    /// Directory FluidAudio reads from / writes to for the configured
    /// variant. FluidAudio's own layout is `<parent>/<repo-name>/*.mlmodelc`
    /// — we hand its API the parent directory and let it manage the subtree.
    public var directory: URL {
        switch variant {
        case .ctc110m:
            return root.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
        case .ctc06b:
            return root.appendingPathComponent("parakeet-ctc-06b-coreml", isDirectory: true)
        }
    }

    /// True when every file FluidAudio requires is on disk. Delegates to
    /// the SDK — only it knows the exact required file set. A bare
    /// "directory exists" check would falsely claim success on a partial
    /// download.
    public var isCached: Bool {
        CtcModels.modelsExist(at: directory)
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Download + load in one step. If the files are already cached this
    /// is a hot load from disk (no network). On cold start this is the
    /// ≈100 MB download.
    ///
    /// Coalesced: concurrent callers (setup wizard fire-and-forget +
    /// Settings re-download + Vocab pane Download tap) all funnel
    /// through `CtcDownloadCoordinator` so only one download runs in
    /// flight against FluidAudio's `DownloadUtils` at a time.
    public func ensureLoaded() async throws -> CtcModels {
        try ensureRootExists()
        return try await CtcDownloadCoordinator.shared.ensureLoaded(
            directory: directory,
            variant: variant
        )
    }

    /// Remove the cached bundle. Used after a failed download so the
    /// next retry starts from a known-empty state.
    func removeCache() {
        try? FileManager.default.removeItem(at: directory)
    }
}
