@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech
import Synchronization
import os.log

/// Runs dictation through Apple's on-device `SpeechTranscriber` (iOS 26+)
/// instead of FluidAudio's Parakeet TDT, while leaving the CTC
/// vocabulary-boost path completely untouched: this returns a normal
/// `ASRResult` with synthetic `tokenTimings` built from Apple's own per-word
/// `audioTimeRange`, so `TranscriptionService`'s existing vocab-merge code
/// runs unmodified on whichever engine produced the transcript (vocab is
/// itself gated OFF upstream for the non-Latin-script languages below).
///
/// Two independent callers route here, both via `TranscriptionService.
/// useAppleEngine`: English (gated by
/// `AppGroup.Keys.useAppleDictationForEnglish`, falls back to FluidAudio on
/// failure), and Japanese/Korean/Mandarin/Cantonese
/// (`LanguageChoice.isAppleOnly`, permanent — FluidAudio has no model for
/// these at all, so there is no fallback and a failure here fails the whole
/// dictation). Locale is `LanguageChoice.current.appleLocaleIdentifier`,
/// falling back to `en-US`.
enum AppleDictationEngine {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "AppleDictationEngine"
    )

    struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    /// Shared timing-synthesis helper (docs/dictation-engine-rework/
    /// implementation-plan.md Step 6a): apportions each run's
    /// `audioTimeRange` across its space-separated words by character share.
    /// Used by BOTH the one-shot `transcribe` below (each `results` element
    /// covers the whole recording) and `AppleStreamingSession.consumeResults()`
    /// (each `isFinal` result covers one finalized segment) — same math,
    /// different callers, so it is factored here rather than duplicated.
    static func words(from text: AttributedString) -> [Word] {
        var words: [Word] = []
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let runText = String(text[run.range].characters)
            let start = timeRange.start.seconds
            let end = timeRange.end.seconds
            let pieces = runText.split(separator: " ").map(String.init)
            guard !pieces.isEmpty else { continue }
            let totalChars = max(1, pieces.reduce(0) { $0 + $1.count })
            var cursor = start
            let duration = end - start
            for piece in pieces {
                let share = duration * Double(piece.count) / Double(totalChars)
                words.append(Word(text: piece, start: cursor, end: cursor + share))
                cursor += share
            }
        }
        return words
    }

    /// Feed raw 16kHz mono samples through Apple's SpeechTranscriber and
    /// return the same `ASRResult` shape FluidAudio's `AsrManager.transcribe`
    /// produces, so every downstream caller (vocab merge, provenance,
    /// diagnostics) is unaffected by which engine ran.
    static func transcribe(samples: [Float]) async throws -> ASRResult {
        let startedAt = Date()
        log.info("step=start sampleCount=\(samples.count, privacy: .public)")
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation, message: "Apple dictation started",
            metadata: ["sampleCount": "\(samples.count)"]
        )
        // Threaded from the active dictation language (Japanese/Korean/
        // Mandarin/Cantonese each carry their own BCP-47 identifier via
        // `appleLocaleIdentifier`); falls back to `en-US` for every language
        // that doesn't set one.
        let localeIdentifier = LanguageChoice.current.appleLocaleIdentifier ?? "en-US"
        let requestedLocale = Locale(identifier: localeIdentifier)
        // `makeReservedTranscriber` normalizes to a locale Apple actually
        // supports AND reserves (subscribes) it — REQUIRED on real iOS
        // hardware, or the asset-install call below throws "not subscribed
        // to transcription.<locale>" on every dictation (found on-device
        // 2026-07-06). Shared with `AppleStreamingSession` so the two Apple
        // engines can't drift on this.
        let transcriber: SpeechTranscriber
        do {
            transcriber = try await AppleStreamingSession.makeReservedTranscriber(
                requestedLocale: requestedLocale,
                preset: .timeIndexedTranscriptionWithAlternatives
            )
        } catch {
            log.error("step=locale-reserve-FAILED locale=\(localeIdentifier, privacy: .public) error=\(String(describing: error), privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "Apple dictation FAILED reserving the locale",
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
                source: "main-app", category: .appleDictation, message: "Apple dictation FAILED at asset install",
                metadata: ["error": "\(error)"]
            )
            throw error
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The analyzer traps internally (EXC_BREAKPOINT in
        // SpeechRecognizerWorker.preRunRecognition) if fed a buffer whose
        // format doesn't match what it actually wants — confirmed via real
        // device crash logs across builds 237-240, all at the same frame.
        // Must ask for and convert into its own required format rather than
        // assuming 16kHz mono (Jot's own pipeline format) is acceptable.
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let sourceDst = sourceBuffer.floatChannelData?[0]
        else {
            log.error("step=buffer-construction-FAILED")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation,
                message: "Apple dictation FAILED building the audio buffer"
            )
            throw AppleDictationError.bufferConstructionFailed
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
                message: "Apple dictation FAILED — no compatible audio format"
            )
            throw AppleDictationError.noCompatibleAudioFormat
        }
        log.info("step=best-format sampleRate=\(targetFormat.sampleRate, privacy: .public) channels=\(targetFormat.channelCount, privacy: .public)")
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation,
            message: "Apple dictation discovered required audio format",
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
                    message: "Apple dictation FAILED building the format converter"
                )
                throw AppleDictationError.bufferConstructionFailed
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let targetFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else {
                log.error("step=converted-buffer-construction-FAILED")
                DiagnosticsLog.record(
                    source: "main-app", category: .appleDictation,
                    message: "Apple dictation FAILED building the converted buffer"
                )
                throw AppleDictationError.bufferConstructionFailed
            }
            var error: NSError?
            // `Mutex` (not a plain `var`) because `AVAudioConverterInputBlock`
            // is annotated `@Sendable` — same reasoning as `CaptureContext.
            // ingest` in RecordingService.swift.
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
                    // `.endOfStream`, not `.noDataNow` — this is a one-shot
                    // conversion of a buffer we already have in full, not a
                    // live/streaming producer. `.noDataNow` tells the
                    // converter more data might arrive later and it should
                    // keep waiting — with nothing ever calling it again,
                    // that hangs the conversion forever (confirmed: user
                    // reports it now hangs indefinitely instead of crashing,
                    // exactly matching this bug).
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
                    message: "Apple dictation FAILED converting audio format", metadata: ["error": "\(error)"]
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
        var words: [Word] = []

        // `start(inputSequence:)` drives the analyzer over the input;
        // `transcriber.results` is drained concurrently to collect the final
        // text + word timings. Unlike the file-based `start(inputAudioFile:
        // finishAfterFile: true)` (which auto-finalizes when the file ends),
        // the sequence-based entry point needs an EXPLICIT finalize call —
        // without it, the last (only) segment stays "volatile"/pending and
        // `transcriber.results` ends having yielded nothing at all. Verified
        // locally against 7 real retained recordings: converted audio was
        // confirmed non-silent, yet produced 0 words until this finalize
        // call was added — all 7 then transcribed correctly.
        async let startTask: Void = try analyzer.start(inputSequence: inputSequence)
        async let finalizeTask: Void = try analyzer.finalizeAndFinishThroughEndOfInput()
        log.info("step=analyze-started")

        do {
            for try await result in transcriber.results {
                let text = result.text
                fullText += text.characters.map(String.init).joined()
                words.append(contentsOf: Self.words(from: text))
            }
        } catch {
            log.error("step=results-loop-FAILED error=\(String(describing: error), privacy: .public)")
            DiagnosticsLog.record(
                source: "main-app", category: .appleDictation, message: "Apple dictation FAILED during transcription",
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
            "Apple dictation complete — chars=\(fullText.count, privacy: .public) words=\(words.count, privacy: .public) processingMS=\(processingTime * 1000, privacy: .public) audioDurationS=\(audioDuration, privacy: .public)"
        )
        DiagnosticsLog.record(
            source: "main-app", category: .appleDictation, message: "Apple dictation completed",
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

    enum AppleDictationError: Error {
        case bufferConstructionFailed
        case noCompatibleAudioFormat
    }
}
