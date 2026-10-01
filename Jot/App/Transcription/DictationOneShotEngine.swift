@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech
import Synchronization
import os.log

/// One-shot stop-pass engine using Apple's `DictationTranscriber` — the peer
/// engine Apple's own docs say to fall back to when
/// `SpeechTranscriber.isAvailable == false`: older/under-6GB-RAM hardware
/// (e.g. the 2020 A12Z iPad Pro) has no on-device model for the newer
/// engine and fails every `SpeechTranscriber` dictation with
/// `SFSpeechErrorDomain Code=1 "...is not subscribed to transcription.en"`.
/// `DictationTranscriber` conforms to the same `SpeechModule`/
/// `LocaleDependentSpeechModule` protocols as `SpeechTranscriber` (confirmed
/// against the real iOS 26 SDK .swiftinterface, not guessed) — so this
/// mirrors `AppleDictationEngine.transcribe(samples:)` line-for-line (same
/// buffer-construction/format-conversion facts proven against real hardware
/// there, same finalize-then-drain-results pattern, same `Word`/`ASRResult`
/// shape). Only the concrete transcriber type and preset differ: `.longDictation`
/// (no `.volatileResults` — this is a one-shot batch pass, not live-preview),
/// and locale reservation goes through `AppleStreamingSession.
/// resolveReservedLocale` generically rather than `makeReservedTranscriber`
/// (which is typed to `SpeechTranscriber`).
enum DictationOneShotEngine {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "DictationOneShotEngine"
    )

    /// Feed raw 16kHz mono samples through Apple's `DictationTranscriber`
    /// and return the same `ASRResult` shape `AppleDictationEngine.transcribe`
    /// and FluidAudio's `AsrManager.transcribe` produce, so every downstream
    /// caller (vocab merge, provenance, diagnostics) is unaffected by which
    /// engine ran.
    static func transcribe(samples: [Float]) async throws -> ASRResult {
        let startedAt = Date()
        log.info("step=start sampleCount=\(samples.count, privacy: .public)")
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation, message: "DictationTranscriber fallback started",
            metadata: ["sampleCount": "\(samples.count)"]
        )
        // Threaded from the active dictation language, same as
        // AppleDictationEngine — falls back to `en-US` for every language
        // that doesn't set `appleLocaleIdentifier`.
        let localeIdentifier = LanguageChoice.current.appleLocaleIdentifier ?? "en-US"
        let requestedLocale = Locale(identifier: localeIdentifier)
        let transcriber: DictationTranscriber
        do {
            let supported = try await AppleStreamingSession.resolveReservedLocale(
                for: DictationTranscriber.self, requestedLocale: requestedLocale
            )
            transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
        } catch {
            log.error("step=locale-reserve-FAILED locale=\(localeIdentifier, privacy: .public) error=\(String(describing: error), privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "DictationTranscriber fallback FAILED reserving the locale",
                metadata: ["locale": localeIdentifier, "error": "\(error)"]
            )
            throw error
        }
        log.info("step=transcriber-created locale=\(localeIdentifier, privacy: .public)")

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log.info("step=asset-install-needed — downloading")
                try await request.downloadAndInstall()
                log.info("step=asset-install-done")
            } else {
                log.info("step=asset-already-installed")
            }
        } catch {
            log.error("step=asset-install-FAILED error=\(String(describing: error), privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation, message: "DictationTranscriber fallback FAILED at asset install",
                metadata: ["error": "\(error)"]
            )
            throw error
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Same crash/format facts proven in AppleDictationEngine: must ask
        // for and convert into the analyzer's own required format rather
        // than assuming 16kHz mono (Jot's own pipeline format) is acceptable.
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let sourceDst = sourceBuffer.floatChannelData?[0]
        else {
            log.error("step=buffer-construction-FAILED")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "DictationTranscriber fallback FAILED building the audio buffer"
            )
            throw AppleDictationEngine.AppleDictationError.bufferConstructionFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { sourceDst.update(from: base, count: samples.count) }
        }
        log.info("step=source-buffer-built frameLength=\(sourceBuffer.frameLength, privacy: .public)")

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            log.error("step=best-format-FAILED — analyzer returned no compatible format")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "DictationTranscriber fallback FAILED — no compatible audio format"
            )
            throw AppleDictationEngine.AppleDictationError.noCompatibleAudioFormat
        }
        log.info("step=best-format sampleRate=\(targetFormat.sampleRate, privacy: .public) channels=\(targetFormat.channelCount, privacy: .public)")
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation,
            message: "DictationTranscriber fallback discovered required audio format",
            metadata: [
                "sourceSampleRate": "\(sourceFormat.sampleRate)", "sourceChannels": "\(sourceFormat.channelCount)",
                "requiredSampleRate": "\(targetFormat.sampleRate)", "requiredChannels": "\(targetFormat.channelCount)",
                "needsConversion": "\(targetFormat != sourceFormat)",
            ]
        )

        let buffer: AVAudioPCMBuffer
        if targetFormat == sourceFormat {
            buffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                log.error("step=converter-construction-FAILED")
                DiagnosticsLog.record(
                    source: "main-app", category: .appleDictation,
                    message: "DictationTranscriber fallback FAILED building the format converter"
                )
                throw AppleDictationEngine.AppleDictationError.bufferConstructionFailed
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let targetFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else {
                log.error("step=converted-buffer-construction-FAILED")
                DiagnosticsLog.record(
                    source: "main-app", category: .appleDictation,
                    message: "DictationTranscriber fallback FAILED building the converted buffer"
                )
                throw AppleDictationEngine.AppleDictationError.bufferConstructionFailed
            }
            var error: NSError?
            // `Mutex` (not a plain `var`) because `AVAudioConverterInputBlock`
            // is annotated `@Sendable` — same reasoning as `AppleDictationEngine`.
            // `OSAllocatedUnfairLock` rather than `Mutex`: the Swift 6.4 (Xcode 27)
            // compiler rejects capturing the noncopyable `Mutex` in this
            // `@Sendable` input block ("copy of noncopyable typed value").
            let suppliedSource = OSAllocatedUnfairLock(initialState: false)
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                let firstCall = suppliedSource.withLock { supplied -> Bool in
                    if supplied { return false }
                    supplied = true
                    return true
                }
                guard firstCall else {
                    // `.endOfStream`, not `.noDataNow` — one-shot conversion
                    // of a buffer already fully in hand (see
                    // AppleDictationEngine's identical comment for why
                    // `.noDataNow` here would hang forever).
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let error {
                log.error("step=convert-FAILED error=\(String(describing: error), privacy: .public)")
                DiagnosticsLog.record(
                    source: "main-app", category: .appleDictation,
                    message: "DictationTranscriber fallback FAILED converting audio format", metadata: ["error": "\(error)"]
                )
                throw error
            }
            buffer = convertedBuffer
            log.info("step=buffer-converted frameLength=\(buffer.frameLength, privacy: .public)")
        }

        let inputSequence = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: nil))
            continuation.finish()
        }

        var fullText = ""
        var words: [AppleDictationEngine.Word] = []

        // `start(inputSequence:)` needs an EXPLICIT finalize call (same
        // fact AppleDictationEngine established against real audio) — the
        // sequence-based entry point does not auto-finalize a trailing
        // segment on its own.
        async let startTask: Void = try analyzer.start(inputSequence: inputSequence)
        async let finalizeTask: Void = try analyzer.finalizeAndFinishThroughEndOfInput()
        log.info("step=analyze-started")

        do {
            for try await result in transcriber.results {
                let text = result.text
                fullText += text.characters.map(String.init).joined()
                words.append(contentsOf: AppleDictationEngine.words(from: text))
            }
        } catch {
            log.error("step=results-loop-FAILED error=\(String(describing: error), privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation, message: "DictationTranscriber fallback FAILED during transcription",
                metadata: ["error": "\(error)"]
            )
            throw error
        }
        log.info("step=results-loop-done chars=\(fullText.count, privacy: .public) words=\(words.count, privacy: .public)")

        do {
            _ = try await startTask
            _ = try await finalizeTask
            log.info("step=analyze-finished")
        } catch {
            log.error("step=analyze-FAILED error=\(String(describing: error), privacy: .public)")
        }

        let processingTime = Date().timeIntervalSince(startedAt)
        let audioDuration = Double(samples.count) / 16_000.0
        let tokenTimings = words.map { w in
            TokenTiming(token: " " + w.text, tokenId: 0, startTime: w.start, endTime: w.end, confidence: 1.0)
        }

        log.info(
            "DictationTranscriber fallback complete — chars=\(fullText.count, privacy: .public) words=\(words.count, privacy: .public) processingMS=\(processingTime * 1000, privacy: .public) audioDurationS=\(audioDuration, privacy: .public)"
        )
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation, message: "DictationTranscriber fallback completed",
            metadata: [
                "chars": "\(fullText.count)", "words": "\(words.count)",
                "processingMS": "\(Int(processingTime * 1000))", "audioDurationS": String(format: "%.1f", audioDuration),
            ]
        )

        return ASRResult(
            text: fullText,
            confidence: 1.0,
            duration: audioDuration,
            processingTime: processingTime,
            tokenTimings: tokenTimings
        )
    }
}
