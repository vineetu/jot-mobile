@preconcurrency import AVFoundation
import Foundation
import FluidAudio
import os.log

/// A friendly, user-facing TTS voice (built-in Supertonic preset or a clone).
///
/// `id` is the Supertonic voice-style preset name (e.g. `M1`, `F3`); it is also
/// the bundle file stem of the preset JSON under `Resources/SupertonicVoices/`.
/// `language` is the BCP-47-ish code used by `TranslationGateway` to decide
/// whether the transcript needs an on-device translation before synthesis
/// (English voices skip translation — every built-in Supertonic preset is `en`).
struct TTSVoice: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// ISO-639 language code of the *spoken* output. `"en"` voices read the
    /// transcript verbatim; any other code triggers a translate-then-speak loop.
    let language: String

    /// `nil` ⇒ this is a bundled Supertonic preset (`id` is the preset / bundle
    /// file stem), synthesized through `Supertonic3Manager`. Non-`nil` ⇒ a
    /// user-cloned PocketTTS voice; the value is the on-disk `.bin` file name
    /// under `ApplicationSupport/TTSVoices/`, loaded via `PocketTtsManager`.
    var clonedFileName: String? = nil

    var isEnglish: Bool { language == "en" }
    var isCloned: Bool { clonedFileName != nil }
}

/// Thin `@MainActor` facade over FluidAudio's `Supertonic3Manager` for the
/// hidden "TTS Lab" (see `docs/tts-lab/design.md`).
///
/// Responsibilities:
///   * Own the single Supertonic-3 manager that drives all 10 bundled built-in
///     voices (Female 1–5 / Male 1–5). Each voice is a Supertonic voice-style
///     preset bundled at `Resources/SupertonicVoices/{F1…M5}.json`; only the
///     loaded `Supertonic3VoiceStyle` differs, not the model.
///   * Download the ~398 MB Supertonic model on user opt-in.
///   * Synthesize text → 44.1 kHz mono PCM (built-in) / 24 kHz (clones) and play
///     it through a short-lived `.playback` audio session, **yielding to
///     recording** — it refuses to speak while `RecordingService.shared.isRecording`,
///     and tears its session down on `stop()` so it never fights the mic /
///     warm-hold.
///   * Chunk long transcripts by sentence, playing chunks back-to-back.
@MainActor
@Observable
final class TTSService {

    static let shared = TTSService()

    enum DownloadState: Equatable {
        case notStarted
        case downloading
        case ready
        case failed(String)
    }

    /// Progress of a voice-clone operation, surfaced to `VoiceCloneRecorderView`.
    enum CloneState: Equatable {
        case idle
        /// The PocketTTS model is downloading on first clone (one-time).
        case preparingModel
        /// Encoding the recorded sample into voice-conditioning data.
        case cloning
        case failed(String)
    }

    private(set) var downloadState: DownloadState = .notStarted
    private(set) var isSpeaking: Bool = false
    private(set) var cloneState: CloneState = .idle

    /// The user's cloned voices, loaded from the App Group registry on first
    /// access and kept in sync on add/delete. Each maps a display name to a
    /// `.bin` conditioning file under `ApplicationSupport/TTSVoices/`.
    private(set) var clonedVoices: [TTSVoice] = []

    /// Every voice the picker should offer: the 10 bundled Supertonic presets
    /// first, then the user's cloned voices in insertion order.
    var allVoices: [TTSVoice] { Self.voices + clonedVoices }

    /// The 10 bundled built-in voices — Supertonic-3 voice-style presets shipped
    /// at `Resources/SupertonicVoices/{F1…F5,M1…M5}.json`. `id` is the preset
    /// name AND the bundle file stem; all presets read English so `language`
    /// is `"en"` (the translate-then-speak path is a no-op for them).
    static let voices: [TTSVoice] = [
        TTSVoice(id: "F1", label: "Female 1", language: "en"),
        TTSVoice(id: "F2", label: "Female 2", language: "en"),
        TTSVoice(id: "F3", label: "Female 3", language: "en"),
        TTSVoice(id: "F4", label: "Female 4", language: "en"),
        TTSVoice(id: "F5", label: "Female 5", language: "en"),
        TTSVoice(id: "M1", label: "Male 1", language: "en"),
        TTSVoice(id: "M2", label: "Male 2", language: "en"),
        TTSVoice(id: "M3", label: "Male 3", language: "en"),
        TTSVoice(id: "M4", label: "Male 4", language: "en"),
        TTSVoice(id: "M5", label: "Male 5", language: "en"),
    ]

    /// Convenience accessor for the first bundled voice (Female 1).
    static var defaultVoice: TTSVoice { voices[0] }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "tts-lab"
    )

    /// FluidAudio's Supertonic-3 facade. `nil` until the first `download()`
    /// succeeds (we don't construct the actor / pin any state when the Lab is
    /// off). Drives all 10 built-in voices.
    private var manager: Supertonic3Manager?

    /// Loaded `Supertonic3VoiceStyle`s, cached by preset id (e.g. `M1`) so we
    /// parse each ~290 KB preset JSON from the bundle at most once per process.
    private var voiceStyleCache: [String: Supertonic3VoiceStyle] = [:]

    /// FluidAudio's PocketTTS facade — the engine behind voice cloning AND the
    /// synthesizer for cloned voices. Built lazily on the first clone / first
    /// cloned-voice playback; `initialize()` downloads its model once. We keep
    /// it separate from `manager` so the Supertonic path is untouched.
    private var pocket: PocketTtsManager?

    /// Persisted name ⇄ file mapping for cloned voices (App Group JSON). The
    /// in-memory `clonedVoices` is derived from this; `.bin` payloads live on
    /// disk under `ApplicationSupport/TTSVoices/`.
    private struct ClonedVoiceRecord: Codable, Hashable {
        let name: String
        let fileName: String
    }

    /// The engine + player node we route synthesized PCM through. Built lazily
    /// on first `speak()` and torn down on `stop()` so the Lab never holds an
    /// audio graph while idle.
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Token to cancel an in-flight multi-chunk `speak()` when `stop()` (or a
    /// new `speak()`) supersedes it.
    private var speakGeneration: Int = 0

    var isReady: Bool { downloadState == .ready }

    private init() {
        clonedVoices = Self.loadClonedRegistry()
    }

    // MARK: - Cloned-voice registry & storage

    /// `ApplicationSupport/TTSVoices/`, created on demand. Voice `.bin` files
    /// live here. Excluded from iCloud backup is unnecessary (small, derivable
    /// only from the user's own sample), but the directory is app-private and
    /// never leaves the device — consistent with Jot's "only feedback leaves"
    /// posture.
    private static func voicesDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("TTSVoices", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Absolute URL of a cloned voice's `.bin` from its registry file name.
    private static func voiceFileURL(_ fileName: String) throws -> URL {
        try voicesDirectory().appendingPathComponent(fileName)
    }

    private static func loadClonedRegistry() -> [TTSVoice] {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.ttsClonedVoices),
            let records = try? JSONDecoder().decode([ClonedVoiceRecord].self, from: data)
        else { return [] }
        return records.map {
            TTSVoice(id: $0.fileName, label: $0.name, language: "en", clonedFileName: $0.fileName)
        }
    }

    private func persistClonedRegistry() {
        let records = clonedVoices.map {
            ClonedVoiceRecord(name: $0.label, fileName: $0.clonedFileName ?? $0.id)
        }
        if let data = try? JSONEncoder().encode(records) {
            AppGroup.defaults.set(data, forKey: AppGroup.Keys.ttsClonedVoices)
        }
    }

    /// Lazily build + initialize the PocketTTS manager (downloads its model the
    /// first time). Returns the ready manager. `@MainActor`-safe: the manager is
    /// an `actor`, so all calls hop off the main actor automatically.
    private func ensurePocket() async throws -> PocketTtsManager {
        if let pocket { return pocket }
        let mgr = PocketTtsManager()
        try await mgr.initialize()
        pocket = mgr
        return mgr
    }

    // MARK: - Voice cloning

    /// Clone the user's voice from a recorded sample and register it under
    /// `name`. Ensures the PocketTTS model is downloaded, encodes the sample to
    /// a `.bin` on disk, and adds it to `clonedVoices`. Surfaces progress via
    /// `cloneState`; throws on failure (with `cloneState` set to `.failed`).
    func cloneVoice(sampleURL: URL, name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceName = trimmedName.isEmpty ? "My voice" : trimmedName

        cloneState = .preparingModel
        do {
            let mgr = try await ensurePocket()

            cloneState = .cloning
            let fileName = "\(UUID().uuidString).bin"
            let binURL = try Self.voiceFileURL(fileName)

            // Encode the sample → conditioning data → persist to `binURL`.
            // (A harmless `E5RT … STL exception` may log during PocketTTS work;
            // valid output still comes out — see the build report.)
            try await mgr.cloneVoiceToFile(from: sampleURL, to: binURL)

            let voice = TTSVoice(
                id: fileName, label: voiceName, language: "en", clonedFileName: fileName)
            clonedVoices.append(voice)
            persistClonedRegistry()
            cloneState = .idle
            logger.info("Cloned voice registered (\(self.clonedVoices.count) total)")
        } catch {
            let message = error.localizedDescription
            cloneState = .failed(message)
            logger.error("Voice clone failed: \(message, privacy: .public)")
            throw error
        }
    }

    /// Remove a cloned voice: delete its `.bin` and drop it from the registry.
    /// No-op for a bundled built-in voice (which has no `clonedFileName`).
    func deleteClonedVoice(_ voice: TTSVoice) {
        guard let fileName = voice.clonedFileName else { return }
        if let url = try? Self.voiceFileURL(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
        clonedVoices.removeAll { $0.clonedFileName == fileName }
        persistClonedRegistry()
    }

    // MARK: - Free up space — delete downloaded TTS models

    /// The TTS model cache — `Caches/fluidaudio/Models/` (Supertonic + PocketTTS).
    /// DISTINCT from the ASR/dictation models, which FluidAudio keeps in
    /// `ApplicationSupport/FluidAudio/Models/`. Deleting this cache frees the big
    /// voice downloads and provably can NOT affect transcription.
    private static func ttsModelCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("fluidaudio/Models", isDirectory: true)
    }

    /// Bytes currently used by the downloaded TTS models (for the "Delete
    /// downloaded voices (N MB)" affordance). 0 when nothing is downloaded.
    static func downloadedModelsByteSize() -> Int64 {
        guard
            let cache = ttsModelCacheURL(),
            let walker = FileManager.default.enumerator(
                at: cache, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Delete the downloaded TTS voice models to free space. SAFE: only the TTS
    /// cache (`Caches/fluidaudio/Models/`) is removed — never the ASR/dictation
    /// models — so transcription is untouched. Resets the Lab to "not
    /// downloaded" (re-downloadable on demand); your cloned voices are kept.
    @discardableResult
    func deleteDownloadedModels() -> Int64 {
        stop()
        manager = nil
        pocket = nil
        let freed = Self.downloadedModelsByteSize()
        if let cache = Self.ttsModelCacheURL() {
            try? FileManager.default.removeItem(at: cache)
        }
        downloadState = .notStarted
        logger.info("deleted downloaded TTS models (freed \(freed, privacy: .public) bytes)")
        return freed
    }

    // MARK: - Download

    /// User-initiated model + voice-pack download. Idempotent; safe to call
    /// again after a failure to retry. Surfaces progress via `downloadState`.
    func download() async {
        if downloadState == .downloading || downloadState == .ready { return }
        downloadState = .downloading

        do {
            // `downloadAndCreate` fetches (if missing) the four Supertonic-3
            // `.mlmodelc` stages + companion JSON and calls `initialize()`
            // internally, so the returned actor is ready to synthesize. The 10
            // voice-style presets are bundled, not downloaded — they load
            // lazily on first `speak()` (see `loadVoiceStyle`).
            let mgr = try await Supertonic3Manager.downloadAndCreate(
                computeUnits: .cpuAndNeuralEngine)
            manager = mgr
            downloadState = .ready
            logger.info("TTS Lab Supertonic model ready (\(Self.voices.count) built-in voices)")
        } catch {
            let message = error.localizedDescription
            downloadState = .failed(message)
            logger.error("TTS Lab download failed: \(message, privacy: .public)")
        }
    }

    // MARK: - Voice-style loading

    /// Load and cache the bundled `Supertonic3VoiceStyle` for a built-in voice
    /// id (e.g. `M1`). Throws `TTSError.voiceMissing` if the preset JSON isn't
    /// in the bundle. Cached after the first load so repeat playback is cheap.
    private func loadVoiceStyle(for id: String) throws -> Supertonic3VoiceStyle {
        if let cached = voiceStyleCache[id] { return cached }
        // xcodegen adds `Resources/SupertonicVoices` files as individual bundle
        // resources (flattened to the app-bundle ROOT), NOT a folder reference —
        // so look up with NO subdirectory first. Fall back to the subdir form in
        // case a future build preserves the folder. (Without this, every voice
        // threw "That voice isn't available" and playback was silent.)
        guard let url = Bundle.main.url(forResource: id, withExtension: "json")
            ?? Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "SupertonicVoices")
        else {
            throw TTSError.voiceMissing
        }
        let style = try Supertonic3VoiceStyle.load(from: url)
        voiceStyleCache[id] = style
        return style
    }

    // MARK: - Speak

    /// Synthesize `text` with `voice` and play it. Chunks by sentence, playing
    /// chunks back-to-back. No-ops (and logs) if the mic is live — TTS always
    /// yields to recording. Throws on synthesis failure.
    func speak(text: String, voice: TTSVoice) async throws {
        // Hard yield to recording / warm-hold. We never open a playback session
        // while the mic is active — that would fight the record session iOS
        // pins process-wide (see RecordingService's singleton rationale).
        guard !RecordingService.shared.isRecording else {
            logger.info("speak() suppressed — recording is active")
            DiagnosticsLog.record(source: "tts", category: .tts, message: "suppressed — recording active")
            return
        }
        // Cloned voices run on PocketTTS, which has its own model + lifecycle —
        // they don't require the Supertonic `download()` / `isReady` gate. Only
        // the built-in voices need the Supertonic manager ready.
        if !voice.isCloned {
            guard manager != nil, isReady else {
                DiagnosticsLog.record(source: "tts", category: .tts, message: "not ready", metadata: ["manager": "\(manager != nil)", "ready": "\(isReady)"])
                throw TTSError.notReady
            }
        }

        // Supersede any in-flight playback.
        stop()

        speakGeneration &+= 1
        let generation = speakGeneration
        isSpeaking = true
        defer {
            if generation == speakGeneration { isSpeaking = false }
        }

        let chunks = Self.sentenceChunks(text)
        guard !chunks.isEmpty else { return }
        DiagnosticsLog.record(
            source: "tts", category: .tts, message: "speak start",
            metadata: ["voice": voice.label, "cloned": "\(voice.isCloned)", "chunks": "\(chunks.count)"]
        )

        // Resolve the synthesis backend once. Built-in voices load their
        // Supertonic voice style from the bundle (cached); cloned voices load
        // their conditioning data from disk a single time (not per chunk).
        let supertonic = manager
        var supertonicStyle: Supertonic3VoiceStyle?
        let supertonicSampleRate = Double(Supertonic3Constants.sampleRate)
        var pocketMgr: PocketTtsManager?
        var pocketVoiceData: PocketTtsVoiceData?
        let pocketSampleRate = Double(PocketTtsConstants.audioSampleRate)
        if let fileName = voice.clonedFileName {
            let mgr = try await ensurePocket()
            let binURL = try Self.voiceFileURL(fileName)
            pocketVoiceData = try mgr.loadClonedVoice(from: binURL)
            pocketMgr = mgr
        } else {
            supertonicStyle = try loadVoiceStyle(for: voice.id)
        }

        // Register our teardown so a recording start can make us yield the shared
        // audio session BEFORE it takes `.record` (the arbiter never touches the
        // session itself — see AudioSessionArbiter). Identity-keyed by `generation`
        // so a superseding speak() isn't clobbered when this task's defer resigns.
        AudioSessionArbiter.shared.registerPlayback(token: generation) { [weak self] in
            self?.stop()
        }
        defer { AudioSessionArbiter.shared.resignPlayback(token: generation) }

        try activatePlaybackSession()
        let (engine, player) = try ensureEngine()

        for chunk in chunks {
            // A `stop()` or a newer `speak()` bumps the generation — bail.
            if generation != speakGeneration { break }
            // Re-check the mic between chunks: a recording could have started
            // mid-readback. Yield immediately if so.
            if RecordingService.shared.isRecording { break }

            let samples: [Float]
            let sampleRate: Double
            if let pocketMgr, let pocketVoiceData {
                // Cloned voice → PocketTTS. `synthesize(text:voiceData:)`
                // returns a 24 kHz WAV `Data`; decode it to fp32 samples and
                // feed the SAME playback plumbing as the built-in path.
                let wav = try await pocketMgr.synthesize(text: chunk, voiceData: pocketVoiceData)
                samples = Self.samplesFromWAV(wav)
                sampleRate = pocketSampleRate
            } else if let supertonic, let supertonicStyle {
                // Built-in voice → Supertonic-3. Returns 44.1 kHz mono fp32
                // samples directly (no WAV wrapper to decode).
                samples = try await supertonic.synthesize(
                    text: chunk, language: voice.language, style: supertonicStyle
                ).samples
                sampleRate = supertonicSampleRate
            } else {
                throw TTSError.notReady
            }
            if generation != speakGeneration { break }
            guard !samples.isEmpty else {
                DiagnosticsLog.record(source: "tts", category: .tts, message: "synth returned 0 samples — chunk skipped")
                continue
            }
            DiagnosticsLog.record(
                source: "tts", category: .tts, message: "synth ok",
                metadata: ["samples": "\(samples.count)", "rate": "\(Int(sampleRate))"]
            )

            let buffer = try Self.pcmBuffer(
                from: samples,
                sampleRate: sampleRate
            )
            // Engine format must match the buffer's; (re)attach the player to
            // the engine's output at the model's sample rate.
            try await play(buffer: buffer, engine: engine, player: player, generation: generation)
        }

        // Done (or interrupted) — release the session so the mic path is clear.
        if generation == speakGeneration {
            DiagnosticsLog.record(source: "tts", category: .tts, message: "speak done")
            teardownEngine()
            deactivatePlaybackSession()
        }
    }

    /// Stop any in-flight playback and release the audio session. Gentle:
    /// stops the player node and deactivates the short-lived `.playback`
    /// session — it does NOT touch the recording session.
    func stop() {
        speakGeneration &+= 1
        isSpeaking = false
        teardownEngine()
        deactivatePlaybackSession()
    }

    // MARK: - Playback plumbing

    /// Schedule `buffer` on the player and await its completion (or supersession).
    private func play(
        buffer: AVAudioPCMBuffer,
        engine: AVAudioEngine,
        player: AVAudioPlayerNode,
        generation: Int
    ) async throws {
        // Connect + start the engine ONCE (a voice's chunks share the same
        // format — sample rate / channels). Accessing `mainMixerNode` also
        // establishes the mixer→output connection; `prepare()` allocates render
        // resources before `start()`.
        if !engine.isRunning {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            engine.prepare()
            try engine.start()
            DiagnosticsLog.record(
                source: "tts", category: .tts,
                message: "engine started running=\(engine.isRunning)",
                metadata: ["rate": "\(Int(buffer.format.sampleRate))", "frames": "\(buffer.frameLength)"]
            )
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // `.dataPlayedBack` fires AFTER the audio has actually rendered out
            // (not merely been consumed) — so a stuck await is a clear signal the
            // engine isn't producing output.
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
            player.play()
        }
    }

    private func ensureEngine() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let playerNode {
            return (engine, playerNode)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        self.engine = engine
        self.playerNode = player
        return (engine, player)
    }

    private func teardownEngine() {
        playerNode?.stop()
        engine?.stop()
        if let player = playerNode, let engine {
            engine.detach(player)
        }
        playerNode = nil
        engine = nil
    }

    // MARK: - Audio session

    /// Briefly take a `.playback` session for readback. We use
    /// `.duckOthers` so background audio dims rather than stops, and never
    /// `.mixWithOthers` against the mic — `speak()` already refused to run
    /// while recording, so there is no live record session to coexist with.
    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    /// Hand the session back. `.notifyOthersOnDeactivation` lets ducked apps
    /// restore their level; if another Jot subsystem needs the mic next, it
    /// reconfigures the category from scratch (RecordingService always sets
    /// `.record` on start), so we don't try to restore a "prior" category here.
    private func deactivatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Helpers

    /// Decode a WAV `Data` blob into fp32 mono samples in [-1, 1].
    ///
    /// PocketTTS hands back a self-contained 24 kHz WAV from
    /// `synthesize(text:voiceData:)`. Rather than round-trip through a temp file
    /// + `AVAudioFile`, we parse the RIFF chunks directly and convert the `data`
    /// chunk's PCM frames. Handles the two formats PocketTTS can emit:
    /// 16-bit signed integer (`fmt` audioFormat 1) and 32-bit float (3). If the
    /// stream is multi-channel we average to mono (PocketTTS is mono, so this is
    /// defensive). Returns `[]` on any malformed header rather than throwing —
    /// the speak loop simply skips an empty chunk.
    static func samplesFromWAV(_ data: Data) -> [Float] {
        // Minimum: "RIFF"(4) size(4) "WAVE"(4) = 12 bytes.
        guard data.count > 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46  // "RIFF"
        else { return [] }

        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }

        var audioFormat = 1      // 1 = PCM int, 3 = IEEE float
        var channels = 1
        var bitsPerSample = 16
        var offset = 12          // past "RIFF"+size+"WAVE"

        // Walk the chunk list to find `fmt ` then `data`.
        var dataRange: Range<Int>?
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset ..< offset + 4)
            let chunkSize = u32(offset + 4)
            let bodyStart = offset + 8
            guard chunkSize >= 0, bodyStart + chunkSize <= data.count else { break }

            if id == Data("fmt ".utf8), chunkSize >= 16 {
                audioFormat = u16(bodyStart)
                channels = max(1, u16(bodyStart + 2))
                bitsPerSample = u16(bodyStart + 14)
            } else if id == Data("data".utf8) {
                dataRange = bodyStart ..< (bodyStart + chunkSize)
                break
            }
            // Chunks are word-aligned (pad byte when odd).
            offset = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard let dataRange else { return [] }
        let body = data.subdata(in: dataRange)

        var mono: [Float] = []
        if audioFormat == 3, bitsPerSample == 32 {
            let frameStride = 4 * channels
            let frames = body.count / frameStride
            mono.reserveCapacity(frames)
            body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for f in 0 ..< frames {
                    var acc: Float = 0
                    for c in 0 ..< channels {
                        acc += raw.loadUnaligned(fromByteOffset: f * frameStride + c * 4, as: Float.self)
                    }
                    mono.append(acc / Float(channels))
                }
            }
        } else if audioFormat == 1, bitsPerSample == 16 {
            let frameStride = 2 * channels
            let frames = body.count / frameStride
            mono.reserveCapacity(frames)
            body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for f in 0 ..< frames {
                    var acc: Float = 0
                    for c in 0 ..< channels {
                        let s = raw.loadUnaligned(fromByteOffset: f * frameStride + c * 2, as: Int16.self)
                        acc += Float(s) / 32768.0
                    }
                    mono.append(acc / Float(channels))
                }
            }
        }
        return mono
    }

    /// Wrap raw fp32 mono PCM into an `AVAudioPCMBuffer` at `sampleRate`.
    static func pcmBuffer(from samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw TTSError.audioFormat
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// Split text into utterance-sized chunks at sentence boundaries, then
    /// hard-split any over-long sentence. We budget on characters and play
    /// chunks back-to-back. Supertonic chunks internally too, but feeding it
    /// bounded chunks keeps memory low and lets `stop()` interrupt promptly
    /// between chunks; the PocketTTS clone path relies on this chunking.
    static func sentenceChunks(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Conservative character budget per utterance, well within what either
        // engine handles, so multi-phoneme graphemes can't overflow.
        let budget = 300

        var sentences: [String] = []
        var current = ""
        for scalar in trimmed.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if scalar == "." || scalar == "!" || scalar == "?" || scalar == "\n" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }

        // Pack short sentences together and hard-split any over-budget one.
        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            if sentence.count > budget {
                if !buffer.isEmpty { chunks.append(buffer); buffer = "" }
                chunks.append(contentsOf: hardSplit(sentence, budget: budget))
                continue
            }
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + 1 + sentence.count <= budget {
                buffer += " " + sentence
            } else {
                chunks.append(buffer)
                buffer = sentence
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    /// Word-boundary hard split for a single over-budget sentence.
    private static func hardSplit(_ sentence: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if buffer.isEmpty {
                buffer = word
            } else if buffer.count + 1 + word.count <= budget {
                buffer += " " + word
            } else {
                pieces.append(buffer)
                buffer = word
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }

    enum TTSError: LocalizedError {
        case notReady
        case audioFormat
        case voiceMissing

        var errorDescription: String? {
            switch self {
            case .notReady: return "The voice model isn't ready yet."
            case .audioFormat: return "Couldn't prepare audio for playback."
            case .voiceMissing: return "That voice isn't available."
            }
        }
    }
}
