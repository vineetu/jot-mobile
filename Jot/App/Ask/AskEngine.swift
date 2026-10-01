#if JOT_APP_HOST
import Foundation
import OSLog

/// Headless, view-free question→answer engine for Ask.
///
/// `AskController` is the on-screen Ask experience: `@MainActor @Observable`,
/// streaming, with progress phases driving the UI. But Siri / Shortcuts /
/// CarPlay need to *answer a question without the Ask view* — a plain
/// string-in / outcome-out call with no `@Observable` accumulation and no
/// token streaming. `AskEngine` is that entry point.
///
/// Both surfaces run the same `AskPipeline` (Private Cloud Compute + the
/// Spotlight and help tools on iOS 27), so a headless answer is built from
/// the byte-identical retrieval + prompts as the in-app one; the engine simply
/// ignores the streaming callbacks and returns the final outcome.
///
/// ## Availability is RETURNED, not thrown
///
/// When Ask can't run (below iOS 27, ineligible device, Apple Intelligence not
/// ready, daily quota reached) the pipeline's reason is surfaced as
/// `AskOutcome.unavailable(reason)` so the caller (a Siri intent, say) can
/// speak a graceful dialog rather than a raw error.
@MainActor
struct AskEngine {

    /// How the answer should read. `.full` is the on-screen Ask answer
    /// (citations, fuller synthesis). `.spoken` asks for a shorter, plainer
    /// answer suitable for a Siri/CarPlay read-aloud — see `spokenStylePreamble`.
    enum AnswerStyle {
        case full
        case spoken
    }

    /// The result of a headless Ask call. Carries EITHER an answer (with its
    /// citations + which corpus produced it) OR a reason it could not run.
    enum AskOutcome: Equatable {
        /// A synthesized answer. `citations` are the notes the answer drew on
        /// (empty for the help corpus, which is informational and uncited by
        /// contract). `corpus` distinguishes a notes answer from a
        /// help answer.
        case answer(AskAnswer)

        /// The pipeline found nothing to answer from — kept for callers that
        /// distinguish "be more specific" from a real answer.
        case vague

        /// Ask can't run right now — see `AskController.UnavailableReason`.
        case unavailable(AskController.UnavailableReason)

        /// Retrieval or generation failed (a thrown error, not unavailability).
        case failed(String)
    }

    /// A successful answer payload.
    struct AskAnswer: Equatable {
        let text: String
        /// Notes the answer drew on. Empty for help-corpus answers.
        let citations: [Citation]
        let corpus: AskController.AnswerCorpus
        /// Which model produced it — for provenance, mirrors `AskController`.
        let backend: AskController.AnswerBackend
    }

    /// A single cited transcript: its id (for deep-linking) and a short label.
    struct Citation: Equatable {
        let transcriptID: UUID
        let date: Date
        let snippet: String
    }

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "ask-engine"
    )

    // MARK: - Public entry point

    /// Answer `question` headlessly. Never throws for unavailability — that
    /// is returned as `.unavailable(reason)`.
    func answer(question: String, style: AnswerStyle = .full) async -> AskOutcome {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .vague }

        let outcome = await AskPipeline.run(
            question: trimmed,
            style: style,
            onSources: { _ in },
            onPartial: { _ in }
        )

        switch outcome {
        case .answer(let answer):
            let citations: [Citation] = answer.sources.compactMap { transcript in
                guard answer.citedIDs.contains(transcript.id) else { return nil }
                return Citation(
                    transcriptID: transcript.id,
                    date: transcript.createdAt,
                    snippet: String(transcript.displayText.prefix(140))
                )
            }
            return .answer(AskAnswer(
                text: answer.text,
                citations: style == .spoken ? [] : citations,
                corpus: answer.corpus,
                backend: .privateCloudCompute
            ))
        case .unavailable(let reason):
            return .unavailable(reason)
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return .failed("Cancelled.")
        }
    }

    // MARK: - Prompt style

    /// Concise read-aloud directive for the spoken surfaces (Siri/CarPlay).
    /// Shorter and plainer than the on-screen answer. Prepended to the shared
    /// instruction block by `AskPipeline` for `.spoken`.
    static let spokenStylePreamble: String = """
        This answer will be READ ALOUD, so keep it short and conversational: at most two or three sentences, plain spoken language, no lists, no headings, no markdown. Lead with the answer.
        """
}
#endif
