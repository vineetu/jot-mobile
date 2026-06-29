import Foundation
import os.log
import SwiftUI
import Translation

/// On-device English→target translation for the TTS Lab (see
/// `docs/tts-lab/design.md`). Non-English Kokoro voices read a *translated*
/// transcript, so before synthesis we run the published English text through
/// Apple's first-party `Translation` framework (free, offline after a one-time
/// language-pack download). Any pair Apple can't do offline falls back to the
/// existing Apple-Foundation-Models cleanup path with a "translate to <lang>"
/// instruction.
///
/// ## Why a gateway (and not a plain `await translate(...)`)
///
/// Apple's `TranslationSession` is **SwiftUI-bound**: you don't construct it —
/// you receive one inside the closure of a `.translationTask(_:action:)`
/// modifier attached to a view, and it's only valid for the lifetime of that
/// closure. To expose a flat `translate(_:to:) async` to non-SwiftUI callers
/// we keep an `@Observable` `configuration`; setting it drives a hidden
/// `.translationTask` host (`TranslationTaskHost`, below) that, when its
/// session becomes available, fulfils a pending continuation parked by
/// `translate(_:to:)`. One in-flight request at a time, which is all the Lab
/// needs (one Read-aloud tap → one translation).
@MainActor
@Observable
final class TranslationGateway {

    static let shared = TranslationGateway()

    /// Drives the hidden `.translationTask` host. Non-nil while a translation
    /// is in flight; the host clears nothing — we just retarget it per request.
    private(set) var configuration: TranslationSession.Configuration?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vineetu.jot.mobile.Jot",
        category: "tts-lab"
    )

    /// The text + target awaiting a session, and the continuation to resume
    /// once the session translates (or we fall back). Only one is parked at a
    /// time.
    private var pending: (text: String, language: String, continuation: CheckedContinuation<String, Error>)?

    private init() {}

    /// Translate `text` (assumed English) to `language` (ISO-639, e.g. `"fr"`).
    /// English targets return the input unchanged. Never throws — on any
    /// failure it returns the best available text (translated, FM-translated,
    /// or the original) so Read-aloud always has *something* to speak.
    /// `from` is the source-language ISO code (default `"en"`). With
    /// multilingual dictation a transcript can be non-English, so the caller
    /// passes the transcript's stored language as the source hint (more
    /// reliable than auto-detect for short notes). Translating to the same
    /// language is a no-op.
    func translate(_ text: String, from sourceCode: String = "en", to language: String) async -> String {
        if language == sourceCode { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: language)

        // Check the pair before committing to the SwiftUI session — if Apple
        // doesn't support it at all, go straight to the FM fallback.
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed, .supported:
            return await appleTranslate(trimmed, from: source, to: target, language: language)
        case .unsupported:
            logger.info("Apple Translation unsupported for \(sourceCode, privacy: .public)→\(language, privacy: .public) — FM fallback")
            return await fallbackTranslate(trimmed, to: language)
        @unknown default:
            return await fallbackTranslate(trimmed, to: language)
        }
    }

    // MARK: - Apple Translation

    /// Park a continuation and arm the hidden `.translationTask` host. The host
    /// resolves it via `fulfill(using:)` once SwiftUI hands us a live session.
    private func appleTranslate(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language,
        language: String
    ) async -> String {
        // Serialize: if a prior request is somehow still parked, fall back for
        // this one rather than clobbering it.
        if pending != nil {
            return await fallbackTranslate(text, to: language)
        }

        // Park the request + arm the hidden `.translationTask` host. The host
        // resumes this THROWING continuation DIRECTLY (continuations are
        // nonisolated — no actor hop, so the non-Sendable `TranslationSession`
        // never crosses into this `@MainActor`); on a translate failure it
        // resumes throwing and we fall back here, in the caller.
        let result: String
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                pending = (text, language, continuation)
                // Pass the explicit source language (the transcript's stored
                // dictation language) — more reliable than auto-detect on short
                // notes. (Pre-multilingual this was `source: nil` / auto-detect.)
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        } catch {
            logger.info("Apple Translation failed (\(error.localizedDescription, privacy: .public)) — FM fallback")
            result = await fallbackTranslate(text, to: language)
        }
        pending = nil
        configuration = nil
        return result
    }

    /// The parked request, for `TranslationTaskHost` to fulfil directly. Read-only
    /// (cleared by `appleTranslate` once the continuation resumes).
    var pendingRequest: (text: String, continuation: CheckedContinuation<String, Error>)? {
        pending.map { ($0.text, $0.continuation) }
    }

    // MARK: - Apple Foundation Models fallback

    /// Last-resort translation via the on-device Apple FM cleanup path. We
    /// reuse `CleanupService.clean(transcript:instructions:)` with a
    /// translate instruction; the transcript is sent as *data* (the cleanup
    /// preamble already treats it as untrusted), and we ask for the
    /// translation only.
    private func fallbackTranslate(_ text: String, to language: String) async -> String {
        let name = Self.languageName(for: language)
        let instructions =
            "Translate the user's text into \(name). Output ONLY the \(name) translation, "
            + "with no preamble, no quotes, and no commentary. Preserve paragraph breaks."
        do {
            let cleanup = CleanupService()
            let result = try await cleanup.clean(transcript: text, instructions: instructions)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch {
            logger.info(
                "FM translation fallback failed (\(error.localizedDescription, privacy: .public)) — speaking original"
            )
            // Speaking the English text in a non-English voice is degraded but
            // better than nothing for a Lab feature.
            return text
        }
    }

    private static func languageName(for code: String) -> String {
        switch code {
        case "es": return "Spanish"
        case "fr": return "French"
        case "hi": return "Hindi"
        default:
            return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }
}

/// Invisible SwiftUI host that owns the `.translationTask` modifier. Attach it
/// once (zero-size) inside the surface that triggers Read-aloud. When
/// `TranslationGateway.shared.configuration` is set, SwiftUI spins up a
/// `TranslationSession` and calls back into the gateway to perform the work.
struct TranslationTaskHost: View {
    @State private var gateway = TranslationGateway.shared

    var body: some View {
        // Read the parked request on the MainActor (`View.body` is MainActor) and
        // capture it. The closure resumes the continuation DIRECTLY (continuations
        // are nonisolated — no actor hop), so the non-Sendable `session` never
        // crosses an isolation boundary. The throwing continuation lets
        // `appleTranslate` run the FM fallback in the caller, not in here.
        let request = gateway.pendingRequest
        return Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // `@Sendable` is the documented fix for "sending 'session' risks
            // data races" (Apple DevForums 816900): it lets the framework run the
            // session off the MainActor. Safe here because the closure touches NO
            // MainActor state — only `session` and the captured (Sendable)
            // continuation; the FM fallback happens back in `appleTranslate`.
            .translationTask(gateway.configuration) { @Sendable session in
                guard let request else { return }
                do {
                    let response = try await session.translate(request.text)
                    request.continuation.resume(returning: response.targetText)
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
    }
}
