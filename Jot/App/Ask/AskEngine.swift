#if JOT_APP_HOST
import FoundationModels
import OSLog

/// Headless, view-free question→answer engine for Ask.
///
/// `AskController` is the on-screen Ask experience: `@MainActor @Observable`,
/// streaming, with progress phases driving the UI. But Siri / Shortcuts /
/// CarPlay need to *answer a question without the Ask view* — a plain
/// string-in / outcome-out call with no `@Observable` accumulation and no
/// token streaming. `AskEngine` is that entry point.
///
/// ## Relationship to `AskController` (shared logic, no fork)
///
/// The engine deliberately does NOT re-implement retrieval, date parsing,
/// backend selection, or prompt construction. It reuses the exact same
/// helpers `AskController` runs (now `static` on the controller), so a
/// headless answer is built from the byte-identical retrieval + prompts as
/// the in-app one. The only thing that differs is the *delivery*: the engine
/// awaits the final string via the **non-streaming** `LLMClient.ask`
/// (`Shared/LLM/LLMClient.swift:61`) / `LanguageModelSession.respond`, rather
/// than `askStreaming` + `@Observable` mirroring.
///
/// ## Availability is RETURNED, not thrown (review MF-1)
///
/// Ask is NOT Qwen-gated — it defaults to Apple Intelligence and is available
/// whenever *either* Apple FM is available OR Qwen weights are on disk
/// (`AskController.isAvailable`). When no backend is usable, the engine maps
/// `AskController.pickBackend()`'s `.none(reason)` cases to a distinct
/// `AskOutcome.unavailable(reason)` so the caller (a Siri intent, say) can
/// speak a graceful dialog. It does NOT surface unavailability as a bare
/// `throw`.
///
/// ## Concurrency
///
/// `@MainActor`, because the reused retrieval helpers construct a
/// `ModelContext(JotModelContainer.shared)` and the embedding/help services are
/// awaited from the main actor in `AskController` today. An intent's
/// `perform()` is itself `@MainActor` (or auto-hops on `await`), so there is no
/// deadlock — every hop here is an `async` suspension, never a blocking
/// `MainActor.run` re-entry (review NTH-2).
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
        /// A synthesized answer. `citations` are the transcript refs the answer
        /// drew on (empty for the help corpus, which is informational and
        /// uncited by contract). `corpus` distinguishes a notes answer from an
        /// auto-routed product-help answer.
        case answer(AskAnswer)

        /// Retrieval found too few plausibly-relevant notes to answer (the
        /// in-app "be more specific" case). Distinct from "no notes from <date>",
        /// which is itself a perfectly good `.answer`.
        case vague

        /// No usable LLM backend. Maps `pickBackend()`'s `.none(reason)`.
        case unavailable(AskController.UnavailableReason)

        /// Retrieval or generation failed (a thrown error, not unavailability).
        case failed(String)
    }

    /// A successful answer payload.
    struct AskAnswer: Equatable {
        let text: String
        /// Transcript refs the answer cited. Empty for help-corpus answers.
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Public entry point

    /// Answer `question` headlessly. Never throws for unavailability — that
    /// is returned as `.unavailable(reason)`. Mirrors `AskController.runPipeline`
    /// but non-streaming and view-free.
    func answer(question: String, style: AnswerStyle = .full) async -> AskOutcome {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .vague }

        // Size retrieval to the effective backend (Qwen's larger context window
        // takes more sources / a bigger prompt budget) — identical to the
        // controller's up-front sizing.
        let backend = AskController.pickBackend()
        let k: Int
        let charLimit: Int
        if case .qwen = backend {
            k = AskController.retrievalKQwen
            charLimit = AskController.userTurnCharLimitQwen
        } else {
            k = AskController.retrievalK
            charLimit = AskController.userTurnCharLimit
        }

        let dateScope = AskController.parseDateScope(from: trimmed, now: Date())

        // Product-help auto-route (same routing logic + thresholds as the
        // controller). A date-scoped query is always about the user's own
        // notes, so it never routes to help.
        if dateScope == nil,
           let qv = try? await EmbeddingGemmaService.shared.encode(trimmed, role: .query) {
            let nq = AskController.normalize(qv)
            if !nq.isEmpty {
                let helpBest = await HelpCorpusIndex.shared.bestCosine(nq)
                if helpBest > AskController.helpRouteFloor {
                    let notesBest = AskController.bestTranscriptCosine(nq)
                    if helpBest > notesBest + AskController.helpRouteMargin {
                        Self.log.info("AskEngine routed to help lane (helpBest=\(helpBest, format: .fixed(precision: 3)) notesBest=\(notesBest, format: .fixed(precision: 3)))")
                        return await answerHelp(
                            question: trimmed, queryVector: nq, charLimit: charLimit, style: style)
                    }
                }
            }
        }

        // Retrieve candidates — identical branching to the controller.
        let retrieved: [Transcript]
        if let scope = dateScope {
            if AskController.queryHasTopicBeyondDate(trimmed) {
                do {
                    let ranked = try await AskController.retrieveTopK(
                        forQuery: trimmed, k: k, dateInterval: scope.interval)
                    retrieved = ranked.isEmpty ? AskController.retrieveByDate(scope, k: k) : ranked
                } catch {
                    Self.log.error("In-window retrieval failed; using chronological: \(error.localizedDescription, privacy: .public)")
                    retrieved = AskController.retrieveByDate(scope, k: k)
                }
            } else {
                retrieved = AskController.retrieveByDate(scope, k: k)
            }
        } else {
            do {
                retrieved = try await AskController.retrieveTopK(forQuery: trimmed, k: k)
            } catch {
                Self.log.error("Retrieval failed: \(error.localizedDescription, privacy: .public)")
                return .failed("Couldn't search your transcripts.")
            }
        }

        // A date query that matches nothing is a clean, informative answer —
        // no model call needed (mirrors the controller).
        if let scope = dateScope, retrieved.isEmpty {
            let text = "You don't have any notes from \(scope.label)."
            return .answer(AskAnswer(text: text, citations: [], corpus: .notes, backend: .appleIntelligence))
        }

        // The vague gate applies only to semantic (non-date) queries.
        if dateScope == nil && retrieved.count < AskController.vagueThreshold {
            return .vague
        }

        // Surface unavailability AFTER the local date-empty answer above — so
        // "you have no notes from X" still works on a backendless device.
        switch backend {
        case .none(let reason):
            return .unavailable(reason)
        case .appleFM, .qwen:
            break
        }

        // Build the prompt + call the chosen backend (non-streaming).
        let orderedIDs = retrieved.map { $0.id }
        let transcriptsByID = Dictionary(uniqueKeysWithValues: retrieved.map { ($0.id, $0) })
        let sanitizedQuestion = AskController.stripControlCharacters(from: trimmed)
        let userTurn = AskController.buildUserTurn(
            question: sanitizedQuestion, transcripts: retrieved, charLimit: charLimit)
        let instructions = Self.instructions(base: AskController.instructionsBlock, style: style)

        let answerText: String
        let usedBackend: AskController.AnswerBackend
        do {
            switch backend {
            case .appleFM:
                usedBackend = .appleIntelligence
                Self.log.info("AskEngine: answering with Apple Intelligence")
                let session = LanguageModelSession(instructions: { instructions })
                answerText = try await session.respond(to: userTurn).content
            case .qwen:
                usedBackend = .qwen
                Self.log.info("AskEngine: answering with Qwen")
                let client = LLMClientFactory.shared.client()
                if await client.status != .ready { try await client.warm() }
                answerText = try await client.ask(systemPrompt: instructions, userPrompt: userTurn)
            case .none:
                return .unavailable(.unknown)  // unreachable; guarded above
            }
        } catch {
            Self.log.error("AskEngine call failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't generate an answer.")
        }

        // Parse citation markers into transcript refs (reusing the in-app
        // parser so the citation contract is identical), then map to refs.
        let segments = AskCitationParser.finalize(
            cumulative: answerText,
            orderedIDs: orderedIDs,
            transcriptsByID: transcriptsByID,
            dateFormatter: Self.dateFormatter
        )
        let citedIDs = AskController.extractCitedIDs(from: segments)
        let citations: [Citation] = orderedIDs.compactMap { id in
            guard citedIDs.contains(id), let t = transcriptsByID[id] else { return nil }
            return Citation(
                transcriptID: id,
                date: t.createdAt,
                snippet: String(t.displayText.prefix(140))
            )
        }

        // `.spoken` (Shortcuts / read-aloud) has nowhere to render citation
        // chips, so strip the `[cite: N]` markers to clean prose. The in-app
        // `.full` path keeps them (AskView renders the chips).
        let answerTrimmed = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = style == .spoken
            ? AskCitationParser.stripMarkers(from: answerTrimmed)
            : answerTrimmed
        return .answer(AskAnswer(
            text: finalText,
            citations: style == .spoken ? [] : citations,
            corpus: .notes,
            backend: usedBackend
        ))
    }

    // MARK: - Help lane

    /// Answer a "how do I use Jot" question from the bundled help corpus —
    /// plain prose, no citations (informational by contract). Mirrors
    /// `AskController.runHelpLane`, non-streaming.
    private func answerHelp(
        question: String, queryVector: [Float], charLimit: Int, style: AnswerStyle
    ) async -> AskOutcome {
        let helpChunks = await HelpCorpusIndex.shared.retrieve(
            query: question, queryVector: queryVector, k: 8)
        guard !helpChunks.isEmpty else {
            return .answer(AskAnswer(
                text: "Jot's help doesn't cover that.",
                citations: [], corpus: .help, backend: .appleIntelligence))
        }

        let backend = AskController.pickBackend()
        switch backend {
        case .none(let reason): return .unavailable(reason)
        case .appleFM, .qwen: break
        }

        let sanitizedQuestion = AskController.stripControlCharacters(from: question)
        let userTurn = AskController.buildHelpUserTurn(
            question: sanitizedQuestion, chunks: helpChunks, charLimit: charLimit)
        let instructions = Self.instructions(base: AskController.helpInstructionsBlock, style: style)

        let answerText: String
        let usedBackend: AskController.AnswerBackend
        do {
            switch backend {
            case .appleFM:
                usedBackend = .appleIntelligence
                Self.log.info("AskEngine help: answering with Apple Intelligence")
                let session = LanguageModelSession(instructions: { instructions })
                answerText = try await session.respond(to: userTurn).content
            case .qwen:
                usedBackend = .qwen
                Self.log.info("AskEngine help: answering with Qwen")
                let client = LLMClientFactory.shared.client()
                if await client.status != .ready { try await client.warm() }
                answerText = try await client.ask(systemPrompt: instructions, userPrompt: userTurn)
            case .none:
                return .unavailable(.unknown)  // unreachable; guarded above
            }
        } catch {
            Self.log.error("AskEngine help-lane failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't generate an answer.")
        }

        return .answer(AskAnswer(
            text: answerText.trimmingCharacters(in: .whitespacesAndNewlines),
            citations: [], corpus: .help, backend: usedBackend))
    }

    // MARK: - Prompt style

    /// Prepend the concise-spoken directive for `.spoken`, leaving the shared
    /// instruction block otherwise byte-identical so the on-screen and headless
    /// answers stay consistent. `.full` returns the base unchanged.
    private static func instructions(base: String, style: AnswerStyle) -> String {
        switch style {
        case .full:
            return base
        case .spoken:
            return spokenStylePreamble + "\n\n" + base
        }
    }

    /// Concise read-aloud directive for the spoken surfaces (Siri/CarPlay).
    /// Shorter and plainer than the on-screen answer; citation markers are
    /// still emitted per the base contract (a spoken caller simply ignores
    /// them — they're stripped from what's read), so notes-vs-help provenance
    /// and the citation parse still work.
    private static let spokenStylePreamble: String = """
        This answer will be READ ALOUD, so keep it short and conversational: at most two or three sentences, plain spoken language, no lists, no headings, no markdown. Lead with the answer.
        """
}
#endif
