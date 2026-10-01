import FluidAudio
import Foundation
import OSLog

/// Owns the NVIDIA Nemotron 3 speaker diarizer (FluidAudio `Nemotron3Diarizer`,
/// `fast128` preset, ~190 MB one-time download) — the engine behind "Detect
/// speakers" and the share-import auto-diarize. Replaces the pyannote/VBx
/// pipeline, as Jot for Mac did (its `docs/speaker-diarization/nemotron-migration.md`:
/// AMI speaker confusion 10.1 % → 0.9 %; VBx collapsed whole meetings to one
/// speaker). Nemotron separates voices inside one mixed stream, so it works on
/// one-mic meetings and calls, up to 8 speakers. It has no voice fingerprint:
/// speakers are anonymous ("Speaker 1", "Speaker 2", …).
///
/// The only file that touches FluidAudio's diarization types: `diarize` hands
/// back Jot-owned `DiarSegment`s (`DiarizationProjection`).
///
/// Mirrors the actor + monotonic-`generation` shape of `VocabularyRescorerHolder`
/// so a stale/cancelled prepare can't clobber a newer one's state.
actor DiarizerHolder {
    static let shared = DiarizerHolder()

    enum ModelState: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .notLoaded
    private(set) var isProcessing = false
    private var models: ModelsBox?
    private var generation = 0

    /// Monolithic `fast128`: 10.24 s of audio per model call, the largest chunk
    /// that still compiles for the ANE, and the best-measured preset (Mac bench:
    /// 0.9 % speaker confusion on AMI).
    nonisolated static let config: Nemotron3Config = .fast128

    /// Audio fed per detached inference block. Cancellation is checked between
    /// blocks, so a cancelled import never waits on a whole hour-long file.
    nonisolated static let blockSeconds: Double = 45

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "Diarizer")

    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// `<Application Support>/Models/Diarizer/` — FluidAudio nests
    /// `nemotron-3-diarization/` inside it.
    nonisolated static var cacheDirectory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Models/Diarizer", isDirectory: true)
    }

    nonisolated static var repoDirectory: URL {
        cacheDirectory.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }

    /// Whether a complete copy of the CURRENT weights is on disk: the compiled
    /// bundle's manifest, the silence embedding, and a weights-version marker
    /// whose content matches this FluidAudio build (an older checkpoint reads
    /// as "not downloaded" — the loader would purge and re-fetch it).
    /// `nonisolated` so the launch prefetch can consult it synchronously.
    nonisolated static var modelsAreDownloaded: Bool {
        let fm = FileManager.default
        let repo = repoDirectory
        let manifest = repo
            .appendingPathComponent(config.hubSubdirectory, isDirectory: true)
            .appendingPathComponent(config.modelFileName, isDirectory: true)
            .appendingPathComponent("coremldata.bin")
        let silence = repo.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
        let marker = repo.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        guard fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: silence.path) else { return false }
        let cached = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cached == ModelNames.Nemotron3.weightsVersion
    }

    /// Downloads (first run only — cached after) and loads the diarizer. Safe
    /// to call repeatedly; a second caller mid-flight no-ops until the first
    /// completes.
    func prepareIfNeeded() async {
        switch modelState {
        case .ready, .downloading, .loading: return
        case .notLoaded, .failed: break
        }
        generation += 1
        let myGeneration = generation
        modelState = Self.modelsAreDownloaded ? .loading : .downloading(0)
        do {
            let loaded = try await Nemotron3Models.loadFromHuggingFace(
                config: Self.config,
                cacheDirectory: Self.cacheDirectory,
                computeUnits: .all,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateDownloadProgress(progress.fractionCompleted, generation: myGeneration) }
                }
            )
            guard myGeneration == generation else { return }
            models = ModelsBox(models: loaded)
            modelState = .ready
            log.info("Nemotron 3 diarizer ready")
        } catch {
            guard myGeneration == generation else { return }
            modelState = .failed(error.localizedDescription)
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateDownloadProgress(_ fraction: Double, generation myGeneration: Int) {
        guard myGeneration == generation, case .downloading = modelState else { return }
        // Subdirectory downloads report 0…1 with no compile phase; at 1 the
        // model load is what's left.
        modelState = fraction >= 1 ? .loading : .downloading(fraction)
    }

    /// Diarize a retained-audio file into exclusive speech runs
    /// (`DiarizationProjection.project`) plus the audio duration. Callers turn
    /// the runs into a speaker timeline with `DiarizationProjection.speakerRuns`
    /// (nil = single speaker).
    ///
    /// Single-in-flight, mirroring `TranscriptionService.isTranscribing`.
    /// Callers should also check `TranscriptionService.shared.isBusy` first:
    /// two CoreML graphs from different pipelines must not run concurrently.
    /// Runs the streaming API (`appendAudio` / `processBufferedAudio` /
    /// `finishStream` — frame-exact with `processComplete`) in `blockSeconds`
    /// blocks off the actor, checking cancellation between blocks.
    func diarize(audioFileURL url: URL) async throws -> (runs: [DiarSegment], duration: Double) {
        guard !isProcessing else { throw DiarizerHolderError.busy }
        await prepareIfNeeded()
        guard let models, isReady else { throw DiarizerHolderError.notReady }
        isProcessing = true
        defer { isProcessing = false }

        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioConverter().resampleAudioFile(url)
        }.value
        let duration = Double(samples.count) / 16_000
        let run = BlockRun(diarizer: Nemotron3Diarizer(config: Self.config, models: models.models))
        let blockSize = Int(Self.blockSeconds * 16_000)

        var probabilities: [Float] = []
        var frameCount = 0
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let end = min(offset + blockSize, samples.count)
            let block = Array(samples[offset..<end])
            let isLast = end == samples.count
            let chunks = try await Task.detached(priority: .userInitiated) {
                try run.feed(block, finish: isLast)
            }.value
            for chunk in chunks {
                probabilities.append(contentsOf: chunk.probabilities)
                frameCount += chunk.frameCount
            }
            offset = end
        } while offset < samples.count
        try Task.checkCancellation()

        let runs = DiarizationProjection.project(
            probabilities: probabilities,
            frameCount: frameCount,
            numSpeakers: Self.config.numSpeakers
        )
        return (runs, duration)
    }

    /// One run's `Nemotron3Diarizer` (a synchronous, non-`Sendable` class
    /// holding the streaming state). `diarize` hands it to exactly one detached
    /// task at a time and awaits each before the next, so it is never touched
    /// concurrently — hence `@unchecked`.
    private final class BlockRun: @unchecked Sendable {
        private let diarizer: Nemotron3Diarizer
        init(diarizer: Nemotron3Diarizer) { self.diarizer = diarizer }

        func feed(_ samples: [Float], finish: Bool) throws -> [Nemotron3ChunkResult] {
            diarizer.appendAudio(samples)
            var results = try diarizer.processBufferedAudio()
            if finish {
                results += try diarizer.finishStream()
            }
            return results
        }
    }
}

/// `@unchecked Sendable` wrapper: `Nemotron3Models` holds the loaded `MLModel`
/// and preallocated I/O buffers; it is written once in `prepareIfNeeded` and
/// only read afterwards, and every model call happens inside `diarize`'s
/// single-in-flight guard.
private struct ModelsBox: @unchecked Sendable {
    let models: Nemotron3Models
}

enum DiarizerHolderError: Error, LocalizedError {
    case notReady
    case busy

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speaker-recognition model isn't ready yet."
        case .busy: return "Already detecting speakers in another recording."
        }
    }
}
