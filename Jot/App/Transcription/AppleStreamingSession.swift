@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech
import Synchronization
import os.log

/// Live-preview transcription driven by a persistent Apple `SpeechAnalyzer`/
/// `SpeechTranscriber` session, fed live audio chunks as they arrive during
/// recording. This is genuinely different from FluidAudio's `PreviewScheduler`
/// (which re-transcribes a trailing overlap window on each pause/timer tick,
/// because FluidAudio has no incremental streaming API) — Apple's engine
/// natively streams: feed it chunks continuously, and it reports both
/// `isFinal == false` volatile text (may still change) and `isFinal == true`
/// finalized text (locked in) on the same `results` sequence, keyed by
/// `SpeechModuleResult.isFinal`. See `docs/dictation-engine-rework/design.md`.
///
/// Reuses the exact format-detection/conversion facts proven in
/// `AppleDictationEngine.swift`'s one-shot path (query
/// `SpeechAnalyzer.bestAvailableAudioFormat`, convert only if it differs from
/// Jot's 16kHz mono Float32 capture format) — but the conversion itself must
/// run continuously across many small chunks rather than once over a single
/// complete buffer, so a single `AVAudioConverter` is kept alive for the
/// whole session (resampling state must carry across chunk boundaries) and
/// each `feed(_:)` call supplies `.noDataNow` (not `.endOfStream` — more
/// chunks ARE coming later in this session) when its one chunk is exhausted.
///
/// NOT YET VERIFIED against real hardware — the one-shot engine's three real
/// bugs (format mismatch, converter hang, missing finalize) were all found by
/// running against real audio locally, not by code review alone. Verify this
/// continuous-conversion path the same way before relying on it on-device.
actor AppleStreamingSession: StreamingSession {
    enum SessionError: Error {
        case noCompatibleAudioFormat
        case converterConstructionFailed
        /// `SpeechTranscriber.supportedLocale(equivalentTo:)` returned `nil`
        /// — Apple has no model for this locale at all (distinct from
        /// reserve/asset-install failing for a locale it DOES support).
        case unsupportedLocale(Locale)
        /// Speech Recognition permission not granted. On a real device the app
        /// must hold Speech authorization before it can subscribe to / install
        /// a transcription-locale asset — otherwise `AssetInventory` throws
        /// "is not subscribed to transcription.<locale>". Found on-device
        /// 2026-07-06 (the Mac harness is auto-authorized, which masked it).
        case notAuthorized(SFSpeechRecognizerAuthorizationStatus)
    }

    /// Ensure Speech Recognition is authorized, prompting once if undetermined.
    /// REQUIRED before any `AssetInventory` reserve/install on a real device —
    /// the transcription-asset subscription is gated on this permission (the
    /// prompt uses `NSSpeechRecognitionUsageDescription`). Idempotent: returns
    /// immediately once a decision has been made.
    static func ensureSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "AppleStreamingSession"
    )

    private let queue: StreamingBufferQueue
    private let presenter: StreamingPartial
    private let sessionID: UUID

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    /// `nil` when `targetFormat == sourceFormat` — no conversion needed.
    private let converter: AVAudioConverter?
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    /// Bound on how many un-consumed `AnalyzerInput` chunks the analyzer's
    /// input stream will hold before dropping the oldest. Without a cap the
    /// stream is unbounded `AsyncStream` (the default), so if `feed(_:)`
    /// outpaces `SpeechAnalyzer` on slow hardware (e.g. the A12Z), buffered
    /// chunks accumulate without limit → memory growth → jetsam. Each chunk
    /// is one AVAudioEngine tap callback (~4096 hardware frames, ≈85–93ms at
    /// the mic's native rate — see `RecordingService.installTap`), so 64
    /// chunks is ≈5.5s of backlog headroom: enough to absorb normal jitter
    /// (GC pauses, brief scheduling hiccups) without ever engaging on the
    /// happy path, but bounded so genuine sustained backlog can't grow
    /// memory forever. Shared with `DictationStreamingSession` so both Apple
    /// engines cap identically.
    static let inputBufferCapacity = 64
    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?

    private var finalizedText = ""
    private var volatileText = ""

    /// Source-sample count consumed so far (16kHz mono, pre-conversion units —
    /// matching `CaptureContext.ingest`'s accounting). Incremented at the top
    /// of `feed(_:)`, before any conversion. The stop-pass's D2 coverage gate
    /// (Step 6) compares this to `capture.drain().count` to prove this
    /// session heard the ENTIRE recording before promoting its text.
    private var consumedSampleCount = 0
    /// Per-word timings synthesized from each `isFinal` result, using the
    /// same char-share pattern as the one-shot `AppleDictationEngine`
    /// (factored into `AppleDictationEngine.words(from:)`).
    private var words: [AppleDictationEngine.Word] = []
    /// Poison flag for the D2 coverage gate (Opus Step-6 review FINDING 1).
    /// `consumedSampleCount` is bumped at the TOP of `feed(_:)`, but three
    /// paths there can drop a chunk WITHOUT yielding it to the analyzer
    /// (buffer alloc failure, a mid-stream converter error, an empty
    /// conversion). A dropped INTERIOR chunk would leave a hole in the
    /// transcript while `consumedSampleCount` still equalled the capture
    /// count AND the trailing volatile was empty — defeating both promote
    /// guards and saving a partial note. Any such drop flips this false, and
    /// `stopArtifact()` then refuses to vouch → the stop-pass runs the
    /// one-shot re-transcribe. Kept as a flag (not "count only yielded
    /// samples") so the count stays in exact pre-conversion source-sample
    /// units aligned with capture.
    private var coverageComplete = true

    /// Resolves a requested locale to one Apple's `SpeechTranscriber` actually
    /// supports and reserves (subscribes) it, then constructs a transcriber
    /// against the RESOLVED locale — never the raw requested one, since a
    /// bare/mismatched identifier (e.g. a hypothetical "zh" vs. the real
    /// "zh-CN") must be normalized before a model can be reserved for it.
    ///
    /// REQUIRED on real iOS hardware (found on-device 2026-07-06): without
    /// reserving the locale first, `AssetInventory.assetInstallationRequest`
    /// throws `SFSpeechErrorDomain Code=1 "...is not subscribed to
    /// transcription.<locale>"` on EVERY call — silently masked until now
    /// because every failure fell back to FluidAudio (fatal for the 4
    /// Apple-only languages, which have no FluidAudio fallback at all; see
    /// `LanguageChoice.isAppleOnly`). Reservation is a limited pool
    /// (`maximumReservedLocales`); this evicts one already-reserved locale
    /// (`reservedLocales` is an unordered Set, so `.first` is arbitrary, not
    /// the oldest) only when the pool is full and the target isn't already
    /// reserved.
    ///
    /// Shared by both Apple engines (`makeConfiguredTranscriber` below and
    /// `AppleDictationEngine.transcribe`) so the reserve/normalize logic
    /// can't drift between the streaming and one-shot paths. Callers still
    /// own their own `AssetInventory.assetInstallationRequest` +
    /// `downloadAndInstall()` step afterward — that part legitimately
    /// differs per caller's logging/diagnostics.
    /// Auth-gate + normalize + reserve, generic over any Apple engine that
    /// conforms to `LocaleDependentSpeechModule` (`SpeechTranscriber` AND
    /// `DictationTranscriber` both do — confirmed against the real iOS 26
    /// SDK .swiftinterface). Factored out of `makeReservedTranscriber` below
    /// so `DictationStreamingSession`/`DictationOneShotEngine` (the peer
    /// engine used when `SpeechTranscriber.isAvailable == false` — older/
    /// under-6GB-RAM hardware with no on-device model for the newer engine)
    /// share this EXACT reserve/normalize logic instead of re-deriving it —
    /// only the concrete transcriber construction differs per caller.
    static func resolveReservedLocale<T: LocaleDependentSpeechModule>(
        for moduleType: T.Type,
        requestedLocale: Locale
    ) async throws -> Locale {
        // REQUIRED on real devices: without Speech authorization the app
        // can't subscribe to the transcription asset → "not subscribed to
        // transcription.<locale>". Prompt once here (uses
        // NSSpeechRecognitionUsageDescription).
        let auth = await ensureSpeechAuthorization()
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation,
            message: "Speech authorization status",
            metadata: ["status": "\(auth.rawValue)"]
        )
        guard auth == .authorized else {
            throw SessionError.notAuthorized(auth)
        }
        guard let supported = await moduleType.supportedLocale(equivalentTo: requestedLocale) else {
            throw SessionError.unsupportedLocale(requestedLocale)
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(supported) {
            if reserved.count >= AssetInventory.maximumReservedLocales, let victim = reserved.first {
                _ = await AssetInventory.release(reservedLocale: victim)
            }
            let didReserve = try await AssetInventory.reserve(locale: supported)
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "Reserved transcription locale",
                metadata: [
                    "locale": supported.identifier(.bcp47),
                    "didReserve": "\(didReserve)",
                    "maxReserved": "\(AssetInventory.maximumReservedLocales)",
                    "priorReservedCount": "\(reserved.count)",
                ]
            )
        }
        return supported
    }

    /// `SpeechTranscriber`-specific wrapper around `resolveReservedLocale` —
    /// call sites and behavior unchanged from before that helper was
    /// factored out.
    static func makeReservedTranscriber(
        requestedLocale: Locale,
        preset: SpeechTranscriber.Preset
    ) async throws -> SpeechTranscriber {
        let supported = try await resolveReservedLocale(for: SpeechTranscriber.self, requestedLocale: requestedLocale)
        return SpeechTranscriber(locale: supported, preset: preset)
    }

    /// Locale + preset + transcriber construction, factored out (Step 7,
    /// docs/dictation-engine-rework/implementation-plan.md) so
    /// `TranscriptionService.preinstallAppleAssets()` can build an
    /// IDENTICALLY-configured transcriber purely to compute/install its
    /// required assets at toggle-flip time, ahead of any recording.
    static func makeConfiguredTranscriber() async throws -> SpeechTranscriber {
        // Threaded from the active dictation language (Japanese/Korean/
        // Mandarin/Cantonese each carry their own BCP-47 identifier via
        // `appleLocaleIdentifier`); falls back to `en-US` for every language
        // that doesn't set one (English itself, and the European set which
        // never reaches this call at all — see `useAppleEngine`).
        let requestedLocale = Locale(identifier: LanguageChoice.current.appleLocaleIdentifier ?? "en-US")
        // `.volatileResults` is NOT requested by the one-shot
        // `AppleDictationEngine` (it finalizes immediately, so it never needs
        // an in-progress guess) — required here so `transcriber.results`
        // yields `isFinal == false` updates as speech is still being
        // recognized, not just the final locked-in text. `init(locale:preset:)`
        // has no separate `reportingOptions:` parameter (confirmed against the
        // real SDK interface, not guessed) — so extend the proven-working
        // `.timeIndexedTranscriptionWithAlternatives` preset's own option sets
        // rather than reconstructing them from scratch.
        let basePreset = SpeechTranscriber.Preset.timeIndexedTranscriptionWithAlternatives
        let preset = SpeechTranscriber.Preset(
            transcriptionOptions: basePreset.transcriptionOptions,
            reportingOptions: basePreset.reportingOptions.union([.volatileResults]),
            attributeOptions: basePreset.attributeOptions
        )
        return try await Self.makeReservedTranscriber(requestedLocale: requestedLocale, preset: preset)
    }

    /// Async factory — asset install + format discovery are both async and
    /// throwing; the caller (`TranscriptionService.makeStreamingSession`)
    /// falls back to FluidAudio's `PreviewScheduler` on any failure here,
    /// mirroring the stop-pass's existing Apple-engine resilience.
    static func make(
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID
    ) async throws -> AppleStreamingSession {
        let transcriber = try await Self.makeConfiguredTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw SessionError.noCompatibleAudioFormat
        }
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SessionError.noCompatibleAudioFormat
        }
        var converter: AVAudioConverter?
        if targetFormat != sourceFormat {
            guard let built = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw SessionError.converterConstructionFailed
            }
            converter = built
        }

        // `.bufferingNewest` drops the OLDEST buffered chunk once full rather
        // than growing unbounded — keeps the app alive under sustained
        // backlog at the cost of a small transcript gap (see
        // `inputBufferCapacity`'s doc comment for why 64 / the tradeoff).
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.inputBufferCapacity)
        )
        let session = AppleStreamingSession(
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
        // from `init` itself) — assigning `self.startTask`/`self.resultsTask`
        // inside a plain synchronous actor init is rejected by the compiler
        // ("cannot access property here in nonisolated initializer").
        await session.begin(inputSequence: inputSequence)
        return session
    }

    private init(
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID,
        transcriber: SpeechTranscriber,
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
        // Mirrors the one-shot engine's bug #3 fix: `start(inputSequence:)`
        // doesn't auto-finalize a trailing volatile segment on its own —
        // without this call the last few words never arrive as `isFinal`.
        // Safe to call here because every caller (`RecordingService`'s three
        // teardown sites) awaits `drain()` — which already ended the input
        // sequence — before calling `quiesce()`.
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

    /// Save-quality artifact for the stop-pass, valid only after `quiesce()`.
    /// `nil` when this session cannot vouch for a complete, fully-finalized
    /// transcript — the caller then runs the one-shot pass instead (D2,
    /// docs/dictation-engine-rework/implementation-plan.md Step 6).
    /// `volatileText` empty is guaranteed post-quiesce when finalize
    /// succeeded; if finalize FAILED (the existing catch in `quiesce()`), a
    /// trailing volatile remains and this correctly returns `nil`.
    /// `coverageComplete` guards the INTERIOR-gap case (a chunk counted but
    /// dropped inside `feed`, Opus Step-6 review FINDING 1) that the
    /// count/volatile guards alone would miss.
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
    /// involved, so RecordingService must not warm it or mirror its load
    /// state to the keyboard for this session (Step 5g).
    nonisolated var usesBatchModel: Bool { false }

    // MARK: - Feeding

    /// Converts one chunk (if needed) and yields it into the analyzer's live
    /// input sequence. The converter (when present) is the SAME instance for
    /// the whole session so resampling state carries across chunk
    /// boundaries — rebuilding it per chunk would reset its internal filter
    /// at every boundary.
    private func feed(_ chunk: [Float]) {
        // D2 coverage accounting (Step 6): count every source sample handed
        // to this session, BEFORE conversion, so it stays in the same units
        // as the capture's sample count regardless of whether/how this
        // chunk converts.
        consumedSampleCount += chunk.count
        guard !chunk.isEmpty else { return }
        guard let sourceBuffer = Self.makeBuffer(from: chunk, format: sourceFormat) else {
            log.error("feed: failed to build source buffer, dropping chunk")
            coverageComplete = false   // dropped a counted chunk → can't promote (FINDING 1)
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
            coverageComplete = false   // dropped a counted chunk → can't promote (FINDING 1)
            return
        }
        // `Mutex` (not a plain `var`) because `AVAudioConverterInputBlock` is
        // annotated `@Sendable`, so a captured mutable var trips Swift 6's
        // concurrent-capture check even though the block runs synchronously
        // inline. Mirrors `CaptureContext.ingest` in RecordingService.swift.
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
                // same session (that's the one-shot engine's terminal
                // signal, not this continuous one's per-chunk signal).
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            log.error("feed: conversion failed — \(conversionError.localizedDescription, privacy: .public)")
            coverageComplete = false   // dropped a counted chunk → can't promote (FINDING 1)
            return
        }
        // `.inputRanDry` is the NORMAL terminal status for a per-chunk
        // convert here — the output buffer is deliberately over-provisioned,
        // so it never fills to capacity (which is what `.haveData` means) —
        // and it CARRIES the converted data. Discarding on `.inputRanDry`
        // silently drops every chunk (adversarial review C1). This mirrors
        // the battle-tested `CaptureContext.ingest` pattern in
        // RecordingService, which treats `.haveData`/`.inputRanDry`
        // identically and trusts `frameLength`.
        switch status {
        case .haveData, .inputRanDry:
            if outputBuffer.frameLength > 0 {
                inputContinuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: nil))
            } else {
                // Converted to zero frames — the counted source samples never
                // reached the analyzer, so this session can't vouch for full
                // coverage (FINDING 1).
                coverageComplete = false
            }
        default:
            coverageComplete = false   // unexpected status → chunk not yielded (FINDING 1)
        }
    }

    /// One terminal convert with `.endOfStream` so a resampling converter's
    /// internally-buffered tail frames (filter delay) reach the analyzer.
    /// No-op when no conversion is active. For the empirical same-rate Int16
    /// target this yields 0–few frames; if `bestAvailableAudioFormat` ever
    /// returns a different sample rate on some device, this is the last
    /// ~tens of ms of the user's final word (adversarial review M4).
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
