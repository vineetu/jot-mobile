import Foundation
import FoundationModels
import os

/// On-device rewrite for the actions pane's **Rewrite** tile (features.md
/// §5.6 / §7.15): runs the user's Cleanup prompt over the host field's
/// selected text with Apple's on-device model and hands the result back for
/// an in-place replacement.
///
/// Inference runs in the system's model service, not in this process, so the
/// keyboard's memory ceiling is untouched; the framework client is tiny. No
/// network, no Full Access needed for the model itself (Full Access is only
/// what lets the keyboard read the user's saved prompts from the App Group —
/// without it the built-in Cleanup prompt runs).
///
/// Same prompt discipline as the app's `RewriteClient`: the prompt is trusted
/// (instructions), the selected text is not (user turn), and `@Generable
/// Rewrite` guided generation means the model can only return the rewritten
/// body — never a preamble.
@MainActor
final class KeyboardRewriter {
    static let shared = KeyboardRewriter()

    /// A rewrite of a keyboard selection is short; past this the tile gives up
    /// so the keyboard never sits on a spinner.
    static let timeout: Duration = .seconds(20)

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot.Keyboard",
        category: "rewriter"
    )

    enum Failure: LocalizedError {
        case unavailable
        case emptyOutput
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Intelligence isn't available right now"
            case .emptyOutput: return "the model returned nothing"
            case .timedOut: return "it took too long"
            }
        }
    }

    /// Whether the on-device model can run right now (Apple Intelligence on,
    /// eligible device, model ready). Read when the actions pane opens.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private var task: Task<String, Error>?

    var isRunning: Bool { task != nil }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Rewrite `text` under `prompt`. Throws `Failure` or the model's error.
    func rewrite(_ text: String, prompt: String) async throws -> String {
        guard Self.isAvailable else { throw Failure.unavailable }
        cancel()
        let instructions = RewriteInstructions.compose(prompt, source: .selection)
        let work = Task { @MainActor () throws -> String in
            let started = Date()
            // The selection is quoted as data; the instructions carry the rule.
            let out = try await Self.respond(instructions: instructions, text: text)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Self.log.info("keyboard rewrite in \(ms) ms — in \(text.count) chars, out \(out.count) chars")
            return out
        }
        task = work
        defer { if task == work { task = nil } }

        // Race against the cap; cancelling the group's children never cancels
        // `work` itself, so cancel it explicitly on timeout.
        let outcome: Result<String, Error> = await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask { await work.result }
            group.addTask {
                do {
                    try await Task.sleep(for: Self.timeout)
                    return .failure(Failure.timedOut)
                } catch {
                    return .failure(CancellationError())
                }
            }
            let first = await group.next() ?? .failure(CancellationError())
            group.cancelAll()
            return first
        }
        if case .failure(let error) = outcome, error is Failure { work.cancel() }
        return try outcome.get()
    }

    private static func respond(instructions: String, text: String) async throws -> String {
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: { instructions }
        )
        let response = try await session.respond(to: RewriteInstructions.userTurn(text), generating: Rewrite.self)
        let out = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw Failure.emptyOutput }
        return out
    }
}
