import Foundation
import FoundationModels
import os.log

/// `LLMClient` backed by Apple Foundation Models (Apple Intelligence).
///
/// This is the alternate backend. The user can pick it in Settings, but the
/// product default is Phi-4. We choose to keep this implementation as thin as
/// possible — the system manages download, eviction, and concurrency for us,
/// so `warm()` and `evict()` are effectively no-ops at the app layer.
///
/// Only available on iOS 26 and on devices that support Apple Intelligence.
/// Availability is enforced at the type level via `@available(iOS 26.0, *)`.
@available(iOS 26.0, *)
final class AppleIntelligenceClient: LLMClient, @unchecked Sendable {

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "AppleIntelligenceClient"
    )

    nonisolated private static let aiLog = Logger(
        subsystem: "com.vineetu.jot.mobile",
        category: "rewrite"
    )

    // The session is cheap to recreate per call, but we cache one to avoid
    // re-binding the system prompt on every rewrite. `LanguageModelSession` is
    // an actor under the hood — `@unchecked Sendable` is fine because we only
    // ever access it from `await` contexts in this class.
    private var cachedSession: LanguageModelSession?
    private var cachedSystemPrompt: String?

    init() {
        // No init-time work. FM is system-managed; warming is the OS's job.
    }

    /// Whether Apple Intelligence is currently usable for rewrite calls.
    ///
    /// `SystemLanguageModel.default.availability` returns `.available` when the
    /// device is eligible (iPhone 15 Pro+) AND the user has enabled Apple
    /// Intelligence in Settings AND the model is ready. Anything else (device
    /// ineligible, AI not enabled, model not ready) means a `rewrite(...)`
    /// call would throw at runtime — so we surface the gate up to the
    /// keyboard mode picker so it can grey out instead of failing silently.
    static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    var status: LLMClientStatus {
        get async {
            // Foundation Models is system-managed. If the framework is loaded
            // and the device supports it, we treat the client as `.ready`. We
            // do NOT attempt to probe Apple Intelligence availability here —
            // that's a Settings-screen concern, not a runtime gate.
            return .ready
        }
    }

    func warm() async throws {
        // No-op: the system handles model residency. We could pre-create a
        // dummy session here, but that would bind a system prompt prematurely.
        // The first `rewrite(...)` will pay the (small) session-creation cost.
    }

    func evict() async {
        // No-op: we cannot evict Apple Intelligence's model from the app
        // process. The cached session is dropped to release any per-session
        // state; the underlying model remains under OS control.
        cachedSession = nil
        cachedSystemPrompt = nil
    }

    func rewrite(text: String, systemPrompt: String) async throws -> String {
        Self.aiLog.notice("AI.rewrite: ENTRY chars=\(text.count, privacy: .public)")

        let session: LanguageModelSession
        if let cached = cachedSession, cachedSystemPrompt == systemPrompt {
            session = cached
        } else {
            // Re-instantiate when the caller-supplied system prompt changes.
            // The Settings screen edits the prompt; binding it on the session
            // means we don't have to repeat it inside the user message.
            let fresh = LanguageModelSession(instructions: systemPrompt)
            cachedSession = fresh
            cachedSystemPrompt = systemPrompt
            session = fresh
        }

        do {
            Self.aiLog.notice("AI.rewrite: SESSION respond start")
            let result = try await session.respond(to: text, generating: Rewrite.self)
            Self.aiLog.notice("AI.rewrite: SESSION done outputChars=\(result.content.text.count, privacy: .public)")
            Self.aiLog.notice("AI.rewrite: returning")
            return result.content.text
        } catch {
            Self.aiLog.error("AI.rewrite: ERROR \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
