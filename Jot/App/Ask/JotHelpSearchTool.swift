#if JOT_APP_HOST
import Foundation
import FoundationModels
import os

/// Foundation Models tool that lets Ask's model look up how Jot works.
///
/// Wraps `HelpCorpusIndex` (the bundled, text-only distillation of
/// `features.md`) as a tool the model calls when the question is about the
/// app rather than the user's notes — "how do I pause a recording?", "what
/// does Warm Hold do?". The model decides when to call it; there is no
/// heuristic router any more (the former cosine-based lane picker went with
/// the embedder). See `docs/ask-product-help/design.md`.
///
/// `wasCalled` lets the caller label the answer's provenance ("Answered from
/// Jot's Help") — the tool is a value handed to the session, so the flag lives
/// behind a lock rather than as a mutated stored property.
final class JotHelpSearchTool: Tool, @unchecked Sendable {
    let name = "searchJotHelp"
    let description = """
        Search Jot's built-in help for how to use the Jot app: its features, \
        buttons, settings, keyboard, Apple Watch app, dictation engines and \
        privacy. Use this for questions about Jot itself — not for questions \
        about the user's own notes.
        """

    @Generable
    struct Arguments {
        @Guide(description: "What the user wants to know about using Jot, as a short search query.")
        var query: String
    }

    private let called = OSAllocatedUnfairLock(initialState: false)

    /// Whether the model invoked this tool during the current answer.
    var wasCalled: Bool { called.withLock { $0 } }

    func call(arguments: Arguments) async throws -> String {
        called.withLock { $0 = true }
        let chunks = await HelpCorpusIndex.shared.retrieve(query: arguments.query, k: 6)
        guard !chunks.isEmpty else {
            return "Jot's help has nothing about that."
        }
        return chunks
            .map { "§\($0.id) \($0.title)\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
#endif
