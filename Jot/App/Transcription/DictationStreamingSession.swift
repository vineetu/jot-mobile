@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech
import Synchronization
import os.log

/// Peer of `AppleStreamingSession` using Apple's `DictationTranscriber`
/// instead of `SpeechTranscriber` — the engine Apple's own docs say to fall
/// back to when `SpeechTranscriber.isAvailable == false`: older/under-6GB-RAM
/// hardware (e.g. the 2020 A12Z iPad Pro) has no on-device model for the
/// newer engine and fails every `SpeechTranscriber` dictation with
/// `SFSpeechErrorDomain Code=1 "...is not subscribed to transcription.en"`.
///
/// `DictationTranscriber` conforms to the same `SpeechModule`/
/// `LocaleDependentSpeechModule` protocols as `SpeechTranscriber` (confirmed
/// against the real iOS 26 SDK .swiftinterface, not guessed), so this is a
/// structural mirror of `AppleStreamingSession`: same AVAudioConverter feed
/// path (a single converter instance kept alive for the whole session), same
/// D2 coverage/`stopArtifact` semantics (Step 6 of
/// docs/dictation-engine-rework/implementation-plan.md), same
/// `StreamingSession` conformance. See `AppleStreamingSession.swift` for the
/// full reasoning behind each piece — this file only swaps the concrete
/// transcriber type + preset construction (`DictationTranscriber.Preset`'s
/// initializer requires `contentHints` explicitly, unlike
/// `SpeechTranscriber.Preset`'s 3-arg overload used there).
actor DictationStreamingSession: StreamingSession {
    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "DictationStreamingSession"
    )

    private let queue: StreamingBufferQueue
    private let presenter: StreamingPartial
    private let sessionID: UUID

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    /// `nil` when `targetFormat == sourceFormat` — no conversion needed.
    private let converter: AVAudioConverter?
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?

    private var finalizedText = ""
    private var volatileText = ""

    /// Source-sample count consumed so far — same D2 coverage accounting as
    /// `AppleStreamingSession.consumedSampleCount`.
    private var consumedSampleCount = 0
    /// Per-word timings synthesized from each `isFinal` result, using the
    /// same char-share helper as `AppleStreamingSession`/`AppleDictationEngine`
    /// (`AppleDictationEngine.words(from:)` — generic over `AttributedString`,
    /// so it applies unchanged to `DictationTranscriber.Result.text`).
    private var words: [AppleDictationEngine.Word] = []
    /// Poison flag for the D2 coverage gate — same semantics as
    /// `AppleStreamingSession.coverageComplete` (see its doc comment for the
    /// three drop paths this guards against).
    private var coverageComplete = true

    /// Locale + preset construction, mirroring `AppleStreamingSession.
    /// makeConfiguredTranscriber`. `DictationTranscriber.Preset`'s
    /// initializer (confirmed against the real SDK) requires `contentHints`
    /// explicitly — so this carries the base preset's `contentHints` through
    /// unchanged rather than omitting it, unlike the `SpeechTranscriber`
    /// 3-arg preset init used on the sibling path.
    static func makeConfiguredTranscriber() async throws -> DictationTranscriber {
        // Threaded from the active dictation language, same as
        // AppleStreamingSession — falls back to `en-US` for every language
        // that doesn't set `appleLocaleIdentifier`.
        let requestedLocale = Locale(identifier: LanguageChoice.current.appleLocaleIdentifier ?? "en-US")
        // `.progressiveLongDictation` is Dictation's live-preview-shaped
        // preset (mirrors `.timeIndexedTranscriptionWithAlternatives` on the
        // SpeechTranscriber side); `.volatileResults` is unioned in so
        // `transcriber.results` yields in-progress guesses, not just
        // finalized text.
        let basePreset = DictationTranscriber.Preset.progressiveLongDictation
        let preset = DictationTranscriber.Preset(
            contentHints: basePreset.contentHints,
            transcriptionOptions: basePreset.transcriptionOptions,
            reportingOptions: basePreset.reportingOptions.union([.volatileResults]),
            attributeOptions: basePreset.attributeOptions
        )
        let supported = try await AppleStreamingSession.resolveReservedLocale(
            for: DictationTranscriber.self, requestedLocale: requestedLocale
        )
        return DictationTranscriber(locale: supported, preset: preset)
    }

    /// Async factory — mirrors `AppleStreamingSession.make`. The caller
    /// (`TranscriptionService.makeStreamingSession`) falls back to
    /// FluidAudio's `PreviewScheduler` on any failure here.
    static func make(
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID
    ) async throws -> DictationStreamingSession {
        let transcriber = try await Self.makeConfiguredTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw AppleStreamingSession.SessionError.noCompatibleAudioFormat
        }
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleStreamingSession.SessionError.noCompatibleAudioFormat
        }
        var converter: AVAudioConverter?
        if targetFormat != sourceFormat {
            guard let built = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AppleStreamingSession.SessionError.converterConstructionFailed
            }
            converter = built
        }

        // Bounded the same way as `AppleStreamingSession.make` — see
        // `AppleStreamingSession.inputBufferCapacity`'s doc comment for the
        // slow-device memory-safety rationale and the drop-oldest tradeoff.
        // Shared constant (not re-derived) so both Apple engines cap
        // identically.
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(AppleStreamingSession.inputBufferCapacity)
        )
        let session = DictationStreamingSession(
            queue: queue,
            presenter: presenter,
            sessionID: sessionID,
            transcriber: transcriber,
            analyzer: analyzer,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            converter: converter,
            inputContinuation: continuation
        )
        // Spawning the background tasks from an actor-isolated method (not
        // from `init` itself) — same compiler constraint noted on
        // AppleStreamingSession.make.
        await session.begin(inputSequence: inputSequence)
        return session
    }

    private init(
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID,
        transcriber: DictationTranscriber,
        analyzer: SpeechAnalyzer,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.queue = queue
        self.presenter = presenter
        self.sessionID = sessionID
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.inputContinuation = inputContinuation
    }

    private func begin(inputSequence: AsyncStream<AnalyzerInput>) {
        let analyzer = self.analyzer
        self.startTask = Task { try await analyzer.start(inputSequence: inputSequence) }
        self.resultsTask = Task { [weak self] in await self?.consumeResults() }
    }

    // MARK: - StreamingSession

    func drain() async {
        while true {
            switch await queue.popOrEndOfStream() {
            case .samples(let chunk):
                feed(chunk)
            case .endOfStream:
                flushConverterTail()
                inputContinuation.finish()
                return
            }
        }
    }

    func quiesce() async {
        // Mirrors AppleStreamingSession.quiesce — `start(inputSequence:)`
        // doesn't auto-finalize a trailing volatile segment on its own.
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("finalize failed — \(error.localizedDescription, privacy: .public)")
        }
        await resultsTask?.value
        if let startTask {
            _ = try? await startTask.value
        }
    }

    func assembledText() -> String {
        Self.join(finalizedText, volatileText)
    }

    /// Save-quality artifact for the stop-pass — same D2 semantics as
    /// `AppleStreamingSession.stopArtifact`.
    func stopArtifact() -> StreamingStopArtifact? {
        guard coverageComplete, volatileText.isEmpty, !finalizedText.isEmpty else { return nil }
        return StreamingStopArtifact(
            text: finalizedText,
            tokenTimings: words.map {
                TokenTiming(token: " " + $0.text, tokenId: 0, startTime: $0.start, endTime: $0.end, confidence: 1.0)
            },
            sourceSampleCount: consumedSampleCount
        )
    }

    /// Apple's `SpeechAnalyzer` streams natively — no FluidAudio batch model
    /// involved (same as `AppleStreamingSession`).
    nonisolated var usesBatchModel: Bool { false }

    // MARK: - Feeding

    /// Converts one chunk (if needed) and yields it into the analyzer's live
    /// input sequence. Byte-identical logic to `AppleStreamingSession.feed`
    /// — format-agnostic, doesn't reference the concrete transcriber type.
    private func feed(_ chunk: [Float]) {
        consumedSampleCount += chunk.count
        guard !chunk.isEmpty else { return }
        guard let sourceBuffer = Self.makeBuffer(from: chunk, format: sourceFormat) else {
            log.error("feed: failed to build source buffer, dropping chunk")
            coverageComplete = false
            return
        }
        guard let converter else {
            inputContinuation.yield(AnalyzerInput(buffer: sourceBuffer, bufferStartTime: nil))
            return
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            log.error("feed: failed to build output buffer, dropping chunk")
            coverageComplete = false
            return
        }
        // `Mutex` (not a plain `var`) because `AVAudioConverterInputBlock` is
        // annotated `@Sendable` — same reasoning as `AppleStreamingSession.feed`
        // and `CaptureContext.ingest`.
        let suppliedSource = OSAllocatedUnfairLock<Bool>(initialState: false)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            let firstCall = suppliedSource.withLock { supplied -> Bool in
                if supplied { return false }
                supplied = true
                return true
            }
            guard firstCall else {
                // NOT `.endOfStream` — more chunks are coming later in this
                // same session.
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            log.error("feed: conversion failed — \(conversionError.localizedDescription, privacy: .public)")
            coverageComplete = false
            return
        }
        switch status {
        case .haveData, .inputRanDry:
            if outputBuffer.frameLength > 0 {
                inputContinuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: nil))
            } else {
                coverageComplete = false
            }
        default:
            coverageComplete = false
        }
    }

    /// One terminal convert with `.endOfStream` — same tail-flush logic as
    /// `AppleStreamingSession.flushConverterTail`.
    private func flushConverterTail() {
        guard let converter else { return }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if conversionError != nil { return }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength > 0 {
                inputContinuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: nil))
            }
        default:
            break
        }
    }

    private func consumeResults() async {
        do {
            for try await result in transcriber.results {
                let text = result.text.characters.map(String.init).joined()
                if result.isFinal {
                    finalizedText = Self.join(finalizedText, text)
                    volatileText = ""
                    words.append(contentsOf: AppleDictationEngine.words(from: result.text))
                } else {
                    volatileText = text
                }
                let display = Self.join(finalizedText, volatileText)
                guard !display.isEmpty else { continue }
                let presenter = self.presenter
                let sessionID = self.sessionID
                await MainActor.run {
                    presenter.update(text: display, isFinal: false, sessionID: sessionID)
                }
            }
        } catch {
            log.error("results loop failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst.update(from: base, count: samples.count) }
        }
        return buffer
    }

    private static func join(_ a: String, _ b: String) -> String {
        let lhs = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return lhs + " " + rhs
    }
}
