#if JOT_APP_HOST
import CoreSpotlight
import Foundation
import FoundationModels
import OSLog

/// The one Ask question→answer pipeline, shared by the on-screen
/// `AskController` (streaming) and the headless `AskEngine` (Siri /
/// Shortcuts). Both surfaces get byte-identical retrieval, prompts and error
/// handling; only delivery differs (the controller mirrors `onPartial` into
/// `@Observable` state, the engine ignores it).
///
/// ## How an answer is produced (iOS 27)
///
/// The model is Apple's **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`,
/// 32K context, end-to-end private, nothing stored). Two shapes of question:
///
/// - **Pure date summary** ("summarize last week", "what did I say yesterday") —
///   a deterministic window: the in-window notes are fetched locally in
///   chronological order and handed to the model with the numbered
///   `[cite: N]` contract, so the citation chips work exactly as before.
/// - **Everything else** — tool-driven. The session carries Apple's
///   `SpotlightSearchTool` (over `TranscriptSpotlightIndex`, so the model
///   searches the user's notes by meaning, keyword and date) and
///   `JotHelpSearchTool` (product help). The model searches, reads, and
///   answers; the notes it retrieved become the sources footer. No numbered
///   citations in this shape — the tool output is Apple-formatted.
///
/// Below iOS 27 there is no Private Cloud Compute or Spotlight search tool,
/// so the outcome is `.unavailable(.needsIOS27)` and the Ask entry point is
/// hidden (`AskController.isAvailable`).
@MainActor
enum AskPipeline {

    struct Answer {
        let text: String
        let segments: [AskAnswerSegment]
        let sources: [Transcript]
        let citedIDs: Set<UUID>
        let corpus: AskController.AnswerCorpus
    }

    enum Outcome {
        case answer(Answer)
        case unavailable(AskController.UnavailableReason)
        case failed(String)
        case cancelled
    }

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "ask-pipeline"
    )

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Run the pipeline. `onSources` fires whenever the set of notes the
    /// answer draws on changes (once for the date shape, incrementally as the
    /// search tool returns for the tool shape). `onPartial` fires with the
    /// renderable segments of the answer so far.
    static func run(
        question: String,
        style: AskEngine.AnswerStyle,
        onSources: @escaping @MainActor ([Transcript]) -> Void,
        onPartial: @escaping @MainActor ([AskAnswerSegment]) -> Void
    ) async -> Outcome {
        guard #available(iOS 27.0, *) else { return .unavailable(.needsIOS27) }
        if case .unavailable(let reason) = AskController.availability() {
            return .unavailable(reason)
        }
        let cloud = PrivateCloudComputeLanguageModel()
        let sanitized = AskController.stripControlCharacters(from: question)
        let dateScope = AskController.parseDateScope(from: question, now: Date())

        // Shape 1 — pure date window, no topic: deterministic chronological
        // retrieval + the numbered citation contract.
        if let scope = dateScope, !AskController.queryHasTopicBeyondDate(question) {
            let retrieved = AskController.retrieveByDate(scope, k: AskController.retrievalK)
            if retrieved.isEmpty {
                let text = "You don't have any notes from \(scope.label)."
                return .answer(Answer(text: text, segments: [.text(text)], sources: [], citedIDs: [], corpus: .notes))
            }
            onSources(retrieved)
            let orderedIDs = retrieved.map(\.id)
            let transcriptsByID = Dictionary(uniqueKeysWithValues: retrieved.map { ($0.id, $0) })
            let userTurn = AskController.buildUserTurn(
                question: sanitized,
                transcripts: retrieved,
                charLimit: AskController.userTurnCharLimit
            )
            let instructions = styled(AskController.instructionsBlock, style)
            let session = LanguageModelSession(model: cloud, instructions: { instructions })
            do {
                var accumulated = ""
                var tick = 0
                for try await partial in session.streamResponse(to: userTurn) {
                    try Task.checkCancellation()
                    accumulated = partial.content
                    tick += 1
                    if tick % 4 == 0 {
                        onPartial(AskCitationParser.parseStreaming(
                            cumulative: accumulated,
                            orderedIDs: orderedIDs,
                            transcriptsByID: transcriptsByID,
                            dateFormatter: dateFormatter
                        ))
                    }
                }
                let segments = AskCitationParser.finalize(
                    cumulative: accumulated,
                    orderedIDs: orderedIDs,
                    transcriptsByID: transcriptsByID,
                    dateFormatter: dateFormatter
                )
                let cited = AskController.extractCitedIDs(from: segments)
                let text = (style == .spoken
                    ? AskCitationParser.stripMarkers(from: accumulated)
                    : accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
                log.info("Ask (date window \(scope.label, privacy: .public)): \(retrieved.count) note(s), \(text.count) chars")
                return .answer(Answer(text: text, segments: segments, sources: retrieved, citedIDs: cited, corpus: .notes))
            } catch is CancellationError {
                return .cancelled
            } catch {
                log.error("Ask date-window call failed: \(error.localizedDescription, privacy: .public)")
                return .failed(describe(error))
            }
        }

        // Shape 2 — tool-driven: Spotlight over the user's notes + Jot help.
        let notesSource = CoreSpotlightSource(
            searchableIndexDelegate: TranscriptSpotlightIndex.shared,
            fetchAttributes: [.title, .textContent, .contentCreationDate]
        )
        let spotlight = SpotlightSearchTool(
            configuration: .init(sources: [.coreSpotlight(notesSource)])
        )
        let help = JotHelpSearchTool()
        let instructions = styled(AskController.toolInstructionsBlock, style)
        let session = LanguageModelSession(
            model: cloud,
            tools: [spotlight, help],
            instructions: { instructions }
        )

        // Mirror the notes the search tool returns into the sources list as
        // they arrive. Both this task and `run` are MainActor-bound, so the
        // collector is plain state.
        let collector = SourceCollector()
        let sourcesTask = Task { @MainActor in
            for await reply in spotlight.searchResults {
                let ids = identifiers(in: reply.content)
                if collector.add(ids) {
                    onSources(TranscriptSpotlightIndex.fetchTranscripts(ids: collector.ids))
                }
            }
        }
        defer { sourcesTask.cancel() }

        do {
            var accumulated = ""
            for try await partial in session.streamResponse(to: sanitized) {
                try Task.checkCancellation()
                accumulated = partial.content
                onPartial([.text(AskCitationParser.stripMarkers(from: accumulated))])
            }
            let text = AskCitationParser.stripMarkers(from: accumulated)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sources = TranscriptSpotlightIndex.fetchTranscripts(ids: collector.ids)
            let corpus: AskController.AnswerCorpus = (help.wasCalled && sources.isEmpty) ? .help : .notes
            log.info("Ask (tools): \(sources.count) note(s) retrieved, help=\(help.wasCalled), \(text.count) chars")
            return .answer(Answer(
                text: text,
                segments: [.text(text)],
                sources: sources,
                citedIDs: Set(sources.map(\.id)),
                corpus: corpus
            ))
        } catch is CancellationError {
            return .cancelled
        } catch {
            log.error("Ask tool call failed: \(error.localizedDescription, privacy: .public)")
            return .failed(describe(error))
        }
    }

    // MARK: - Helpers

    @MainActor
    private final class SourceCollector {
        private(set) var ids: [UUID] = []
        /// Append unseen ids; returns whether anything new was added.
        func add(_ new: [UUID]) -> Bool {
            var added = false
            for id in new where !ids.contains(id) {
                ids.append(id)
                added = true
            }
            return added
        }
    }

    @available(iOS 27.0, *)
    private static func identifiers(in content: SpotlightSearchTool.SearchReply.Content) -> [UUID] {
        let raw: [String]
        switch content {
        case .items(let items):
            raw = items.map { $0.item.uniqueIdentifier }
        case .scoredItems(let scored):
            raw = scored.map { $0.item.item.uniqueIdentifier }
        case .groupedItems(let groups):
            raw = groups.values.flatMap { $0.map { $0.item.uniqueIdentifier } }
        default:
            raw = []
        }
        return raw.compactMap(UUID.init(uuidString:))
    }

    /// Prepend the concise-spoken directive for `.spoken`, leaving the shared
    /// instruction block otherwise byte-identical so the on-screen and
    /// headless answers stay consistent.
    private static func styled(_ base: String, _ style: AskEngine.AnswerStyle) -> String {
        switch style {
        case .full: return base
        case .spoken: return AskEngine.spokenStylePreamble + "\n\n" + base
        }
    }

    /// User-facing failure copy. Private Cloud Compute's own errors get
    /// specific, actionable lines; anything else gets the generic retry.
    private static func describe(_ error: Error) -> String {
        if #available(iOS 27.0, *), let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloudError {
            case .networkFailure:
                return "You're offline. Ask needs a connection to Apple's Private Cloud Compute."
            case .quotaLimitReached:
                return "You've reached today's Ask limit. Try again tomorrow."
            case .serviceUnavailable:
                return "Apple's servers are busy right now. Try again in a moment."
            @unknown default:
                break
            }
        }
        return "Couldn't generate an answer. Try again."
    }
}
#endif
