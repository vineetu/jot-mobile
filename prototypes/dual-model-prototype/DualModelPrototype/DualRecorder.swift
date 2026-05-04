@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.log
import Synchronization

private let logger = Logger(subsystem: "com.vineetu.jot.mobile.dualmodelprototype", category: "recorder")

/// Standalone prototype recorder. Captures one audio stream and feeds it
/// concurrently to:
///   - FluidAudio `StreamingEouAsrManager` (Parakeet EOU 120M @ 320ms) for
///     live partial-transcript display.
///   - FluidAudio `AsrManager` (Parakeet TDT 0.6B v2) for the final
///     high-accuracy transcript at stop.
///
/// Goal: validate iPhone 17 / iOS 26 ANE concurrency between the two CoreML
/// models. Not production code — minimum viable harness.
@MainActor
@Observable
final class DualRecorder {

    // MARK: - Observable state

    private(set) var isRecording: Bool = false
    private(set) var isStopInFlight: Bool = false
    private(set) var streamingText: String = ""
    private(set) var streamingIsVolatile: Bool = false
    private(set) var finalText: String = ""
    private(set) var status: String = "Loading models…"
    private(set) var bothModelsReady: Bool = false
    private(set) var elapsedSeconds: Double = 0

    /// Generation token for the active session. Set on `start()`, cleared
    /// on `stop()`. Late partial-transcript callbacks from a previous
    /// session compare against this — if mismatched, they no-op rather
    /// than flipping `streamingIsVolatile` back to `true` after we'd
    /// already promoted the text to finalized in `finish()`.
    private var currentSessionID: UUID?

    // MARK: - Models

    private var batchManager: AsrManager?
    private var streamingManager: (any StreamingAsrManager)?

    // MARK: - Audio capture

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var hardwareFormat: AVAudioFormat?
    private static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Lock-protected accumulator for the batch path.
    private let batchSamples = SamplesBox()

    /// FIFO queue of converted PCM buffers waiting to be ingested by the
    /// streaming actor. The audio tap pushes here (cheap, lock-only). A
    /// single serial drain task pulls + awaits `appendAudio` +
    /// `processBufferedAudio` strictly in order. This avoids the actor
    /// reentrancy race the per-tap-detached-task design had: multiple
    /// detached tasks would suspend on `processBufferedAudio`'s CoreML
    /// await and interleave decoder state, AND would arrive at the actor
    /// in scheduler order rather than tap order.
    private let streamingQueue = StreamingBufferQueue()
    private var streamingDrainTask: Task<Void, Never>?

    private var startedAt: Date?

    // MARK: - Lifecycle

    func warmUp() async {
        status = "Loading models (batch + streaming)…"

        // Load both models in parallel. Both go through HuggingFace
        // download-then-load on first run.
        async let batchTask: Void = loadBatchModel()
        async let streamingTask: Void = loadStreamingModel()

        do {
            _ = try await (batchTask, streamingTask)
            bothModelsReady = true
            status = "Idle — tap to record"
            logger.info("Both models loaded")
        } catch {
            bothModelsReady = false
            status = "Model load failed: \(error.localizedDescription)"
            logger.error("Model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadBatchModel() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.batchManager = manager
    }

    private func loadStreamingModel() async throws {
        let manager = StreamingModelVariant.parakeetEou320ms.createManager()
        try await manager.loadModels()
        self.streamingManager = manager
    }

    /// Install a session-scoped partial-transcript callback. Called once per
    /// `start()`. The callback captures the session UUID and only applies the
    /// partial if it still matches `currentSessionID` — guards against late
    /// MainActor-queued tasks running after `finish()` finalized the tail.
    private func installPartialCallback(sessionID: UUID) async {
        guard let streamingManager else { return }
        await streamingManager.setPartialTranscriptCallback { [weak self, sessionID] partial in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentSessionID == sessionID else { return }
                self.streamingText = partial
                self.streamingIsVolatile = true
            }
        }
    }

    func start() async throws {
        // Block start while a previous stop() is still draining / batch-
        // transcribing. Without this guard the user can re-tap mid-stop
        // and reset the queue/manager underneath the suspended stop path.
        guard bothModelsReady, !isRecording, !isStopInFlight else { return }

        // Fresh session token. Late callbacks from any prior session will
        // compare against this and no-op.
        let sessionID = UUID()
        currentSessionID = sessionID

        // Reset transient state.
        streamingText = ""
        streamingIsVolatile = false
        finalText = ""
        elapsedSeconds = 0
        batchSamples.clear()
        streamingQueue.reset()
        if let streamingManager {
            try? await streamingManager.reset()
        }
        await installPartialCallback(sessionID: sessionID)

        // Spawn the serial drain task BEFORE starting the engine so the
        // tap callback never has to deal with a missing consumer. The
        // task exits when `streamingQueue.popOrEndOfStream()` returns
        // `.endOfStream` after `stop()` signals it.
        if let streamingManager {
            let queue = streamingQueue
            streamingDrainTask = Task.detached(priority: .userInitiated) {
                while true {
                    switch await queue.popOrEndOfStream() {
                    case .buffer(let pcm):
                        do {
                            try await streamingManager.appendAudio(pcm)
                            try await streamingManager.processBufferedAudio()
                        } catch {
                            logger.debug("streaming drain error: \(error.localizedDescription, privacy: .public)")
                        }
                    case .endOfStream:
                        return
                    }
                }
            }
        }

        try configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hardwareFormat, to: Self.target) else {
            throw NSError(domain: "DualRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }

        // Tap callback runs on the audio render thread. Must NOT inherit
        // MainActor isolation — explicit @Sendable on the closure type
        // breaks isolation inheritance. See Jot/App/Recording/RecordingService.swift:156
        // for the full rationale.
        let target = Self.target
        let batchSamples = self.batchSamples
        let streamingQueue = self.streamingQueue
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { pcm, _ in
            // Convert hardware-rate buffer to 16 kHz mono Float32.
            // Note: this prototype takes the QA1715-noncompliant shortcut
            // of allocating a fresh output buffer per tap. Acceptable for
            // a validation harness; production code should reuse a buffer
            // pool or move conversion off the audio thread.
            let ratio = target.sampleRate / pcm.format.sampleRate
            let estimatedFrames = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: estimatedFrames) else { return }

            let supplied = Mutex<Bool>(false)
            var err: NSError?
            let status = converter.convert(to: outBuffer, error: &err) { _, inputStatus in
                let firstCall = supplied.withLock { value -> Bool in
                    if value { return false }
                    value = true
                    return true
                }
                if !firstCall {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return pcm
            }
            guard status != .error, let channelData = outBuffer.floatChannelData else { return }

            // Batch: append converted samples to the lock-protected accumulator.
            let count = Int(outBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            batchSamples.append(samples)

            // Streaming: enqueue the converted buffer for the serial drain.
            // The drain task pulls strictly in order and serializes
            // appendAudio + processBufferedAudio against the streaming
            // actor — no per-tap detached tasks, no reentrancy.
            streamingQueue.push(outBuffer)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        self.converter = converter
        self.hardwareFormat = hardwareFormat
        self.startedAt = Date()
        self.isRecording = true
        self.status = "Recording…"
        logger.info("Recording started at \(Int(hardwareFormat.sampleRate))Hz/\(Int(hardwareFormat.channelCount))ch")
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        isStopInFlight = true
        defer { isStopInFlight = false }

        let engine = self.engine
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        self.engine = nil

        let stoppedAt = Date()
        let started = startedAt ?? stoppedAt
        elapsedSeconds = stoppedAt.timeIntervalSince(started)

        // Drain order matters:
        //   1. Signal end-of-stream to the streaming queue. Any buffers
        //      pushed after `removeTap` have already arrived; the queue
        //      flushes the rest.
        //   2. Await the drain task — guarantees every queued buffer has
        //      been fed through `appendAudio` + `processBufferedAudio`
        //      before we call `finish()`.
        //   3. THEN call `finish()` which decodes the full accumulated
        //      token sequence into the finalized streaming text.
        // Without this ordering, late drain-task iterations would append
        // after `finish()` cleared the manager state, and late partial
        // callbacks would flip `streamingIsVolatile` back to true after
        // we'd promoted to finalized.
        streamingQueue.endOfStream()
        await streamingDrainTask?.value
        streamingDrainTask = nil

        // Invalidate the session token NOW, before finish() — any
        // partial-callback Tasks queued by the drain's last
        // processBufferedAudio that haven't run yet will compare against
        // the cleared token and no-op, instead of flipping
        // streamingIsVolatile back to true after finish() promotes the
        // tail to finalized.
        currentSessionID = nil

        if let streamingManager {
            do {
                let finalStream = try await streamingManager.finish()
                streamingText = finalStream
                streamingIsVolatile = false
            } catch {
                logger.error("streaming finish failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Run the batch model on the full accumulated buffer.
        status = "Transcribing…"
        let allSamples = batchSamples.snapshot()
        if let batchManager, !allSamples.isEmpty {
            do {
                let result = try await batchManager.transcribe(allSamples, source: .microphone)
                finalText = result.text
                status = String(format: "Done in %.2fs", elapsedSeconds)
            } catch {
                finalText = ""
                status = "Batch transcribe failed: \(error.localizedDescription)"
                logger.error("batch transcribe failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            status = "No audio captured"
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])
        try session.setActive(true, options: [])
    }
}

/// Thread-safe Float-sample accumulator. The audio tap appends from the
/// render thread; `stop()` reads a snapshot from MainActor.
private final class SamplesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func append(_ samples: [Float]) {
        lock.lock()
        storage.append(contentsOf: samples)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        let out = storage
        lock.unlock()
        return out
    }

    func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// FIFO queue feeding the streaming actor's drain task. The tap callback
/// pushes converted PCM buffers; the drain task awaits `popOrEndOfStream`,
/// which suspends until either a buffer arrives or `endOfStream()` is
/// signaled. Delivers strict tap-order, single-consumer semantics —
/// avoids the actor-reentrancy race that per-tap detached tasks had.
private final class StreamingBufferQueue: @unchecked Sendable {
    enum Item { case buffer(AVAudioPCMBuffer); case endOfStream }

    private let lock = NSLock()
    private var queue: [AVAudioPCMBuffer] = []
    private var ended = false
    private var waiter: CheckedContinuation<Item, Never>?

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        // Discard post-EOS pushes. An in-flight audio tap callback can race
        // with `stop()`'s `endOfStream()`; without this guard the buffer
        // would be appended after the drain task has exited and never
        // consumed.
        if ended {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .buffer(buffer))
            return
        }
        queue.append(buffer)
        lock.unlock()
    }

    func endOfStream() {
        lock.lock()
        ended = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .endOfStream)
            return
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        queue.removeAll(keepingCapacity: true)
        ended = false
        // No waiter expected during reset (drain task only spawns AFTER reset
        // in start()), but defensively resume any with endOfStream so we
        // never strand a continuation.
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .endOfStream)
            return
        }
        lock.unlock()
    }

    func popOrEndOfStream() async -> Item {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let head = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: .buffer(head))
                return
            }
            if ended {
                lock.unlock()
                continuation.resume(returning: .endOfStream)
                return
            }
            // No buffer, not ended — park.
            self.waiter = continuation
            lock.unlock()
        }
    }
}
