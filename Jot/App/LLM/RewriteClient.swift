import Foundation
import FoundationModels
import os

/// Runs the user's saved rewrite prompts on Apple Foundation Models.
///
/// This replaced the downloadable Qwen 3.5 (MLX) client: there is no model
/// download, no weights on disk and no in-process inference. Two routes, tried
/// in order:
///
/// 1. **On-device** — `SystemLanguageModel` (the model behind Apple
///    Intelligence). Offline, instant, no quota. On iOS 27 the prompt is
///    token-counted against the model's `contextSize` first, so a transcript
///    that can't fit skips straight to route 2 instead of failing.
/// 2. **Private Cloud Compute** (iOS 27+) — `PrivateCloudComputeLanguageModel`,
///    Apple's server model with a 32K context. Used when the on-device model is
///    unavailable, the transcript is too long for it, or it failed. Requires a
///    network and is subject to Apple's per-user daily quota; requests are
///    end-to-end private and never stored (see features.md §13.1).
///
/// Both routes use the same `@Generable Rewrite` guided-generation schema, so
/// the model can only ever return the rewritten body — never a preamble.
///
/// Availability mirrors `CleanupService`'s: Apple Intelligence off / device
/// not eligible / model still downloading. The settings screen and the detail
/// view's Rewrite pill both read `RewriteClient.availability` synchronously.
@MainActor
final class RewriteClient {
    static let shared = RewriteClient()

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "rewrite-client"
    )

    // MARK: - Availability

    enum Availability: Equatable, Sendable {
        case available
        /// A one-sentence, user-facing explanation.
        case unavailable(reason: String)
    }

    /// Private Cloud Compute is usable only when this build holds Apple's
    /// managed entitlement (`PrivateCloudComputeAccess`) AND the device reports
    /// it available (iOS 27). The framework alone says "available" on any
    /// eligible device and then fails every request without the entitlement.
    static var cloudIsUsable: Bool {
        guard PrivateCloudComputeAccess.isEntitled else { return false }
        if #available(iOS 27.0, *) { return PrivateCloudComputeLanguageModel().isAvailable }
        return false
    }

    /// Whether *some* route can run a rewrite right now.
    static var availability: Availability {
        if case .available = SystemLanguageModel.default.availability {
            return .available
        }
        if cloudIsUsable {
            return .available
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri to rewrite.")
            case .deviceNotEligible:
                return .unavailable(reason: "This iPhone doesn't support Apple Intelligence, which Jot's rewrite uses.")
            case .modelNotReady:
                return .unavailable(reason: "Apple Intelligence is still getting ready — try again in a few minutes.")
            @unknown default:
                return .unavailable(reason: "Apple Intelligence isn't available right now.")
            }
        }
    }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// Mirrors `isAvailable` into the App Group so the keyboard's Cleanup
    /// toggle (features.md §5.6) can say "turn on Apple Intelligence" instead
    /// of switching on a pass that can't run. The keyboard never links
    /// FoundationModels, so this is its only view of the engine.
    static func mirrorAvailabilityToAppGroup() {
        AppGroup.defaults.set(isAvailable, forKey: AppGroup.Keys.aiCleanupAvailable)
    }

    /// True when the on-device model can't serve and Private Cloud Compute
    /// would. Lets UI say "uses Private Cloud Compute" honestly.
    static var wouldUsePrivateCloudCompute: Bool {
        if case .available = SystemLanguageModel.default.availability { return false }
        return cloudIsUsable
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case unavailable(String)
        case emptyOutput
        /// Apple's on-device model rate-limits apps running in the background
        /// (its docs: this happens ONLY in the background, past a system-defined
        /// rate). `resetDate` is when the limit lifts, when the system says.
        case rateLimited(resetDate: Date?)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .emptyOutput: return "Rewrite returned no text."
            case .rateLimited: return "Apple Intelligence is rate-limited while Jot is in the background."
            }
        }
    }

    /// True for the background rate limit, whichever way the framework reports
    /// it (`LanguageModelError.rateLimited` on iOS 27, the session-level case on
    /// iOS 26) or after `rewrite` has already mapped it to `Failure.rateLimited`.
    static func isRateLimited(_ error: Error) -> Bool {
        if let f = error as? Failure, case .rateLimited = f { return true }
        if #available(iOS 27.0, *), let lm = error as? LanguageModelError, case .rateLimited = lm { return true }
        if let ge = error as? LanguageModelSession.GenerationError, case .rateLimited = ge { return true }
        return false
    }

    /// Map the framework's rate-limit errors to `Failure.rateLimited` (with the
    /// reset date when the system provides one); pass everything else through.
    private static func classified(_ error: Error) -> Error {
        if #available(iOS 27.0, *), let lm = error as? LanguageModelError, case .rateLimited(let info) = lm {
            return Failure.rateLimited(resetDate: info.resetDate)
        }
        if let ge = error as? LanguageModelSession.GenerationError, case .rateLimited = ge {
            return Failure.rateLimited(resetDate: nil)
        }
        return error
    }

    // MARK: - Rewrite

    /// Rewrite `text` according to `systemPrompt` (one of the user's saved
    /// prompts, or a spoken voice-prompt wrapped by the caller). Returns the
    /// trimmed rewritten body. Throws `Failure` or a Foundation Models error.
    func rewrite(text: String, systemPrompt: String) async throws -> String {
        let instructions = RewriteInstructions.compose(systemPrompt, source: .dictation)

        var onDeviceReady = false
        if case .available = SystemLanguageModel.default.availability { onDeviceReady = true }

        // iOS 27: budget the prompt against the on-device context up front so
        // a long transcript goes straight to Private Cloud Compute instead of
        // failing on-device first.
        // The token budget only matters when it can ROUTE somewhere: without a
        // usable cloud, counting tokens is two extra model requests per rewrite
        // that change nothing — and requests are what the background rate limit
        // counts. Skip it until Private Cloud Compute is entitled.
        var onDeviceFits = true
        if #available(iOS 27.0, *), onDeviceReady, Self.cloudIsUsable {
            onDeviceFits = await Self.fitsOnDevice(text: text, instructions: instructions)
        }

        // Without a usable cloud route, a too-long transcript still tries
        // on-device so the user sees the real context error, not "unavailable".
        if onDeviceReady, onDeviceFits || !Self.cloudIsUsable {
            do {
                return try await Self.run(
                    makeSession: { instr in
                        LanguageModelSession(model: Self.onDeviceModel, instructions: { instr })
                    },
                    instructions: instructions,
                    text: text,
                    route: "on-device"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to Private Cloud Compute when it can take over;
                // otherwise surface the on-device failure as-is.
                if Self.cloudIsUsable {
                    Self.log.notice("on-device rewrite failed (\(error.localizedDescription, privacy: .public)); retrying on Private Cloud Compute")
                } else {
                    throw error
                }
            }
        }

        if #available(iOS 27.0, *) {
            let cloud = PrivateCloudComputeLanguageModel()
            guard PrivateCloudComputeAccess.isEntitled, cloud.isAvailable else {
                throw Failure.unavailable(Self.unavailableReason)
            }
            return try await Self.run(
                makeSession: { instr in
                    LanguageModelSession(model: cloud, instructions: { instr })
                },
                instructions: instructions,
                text: text,
                route: "private-cloud-compute"
            )
        }

        throw Failure.unavailable(Self.unavailableReason)
    }

    // MARK: - Internals

    private static var unavailableReason: String {
        if case .unavailable(let reason) = availability { return reason }
        return "Apple Intelligence isn't available right now."
    }

    /// The on-device model with guardrails tuned for transforming the user's
    /// own text (fewer false-positive refusals on everyday dictation).
    private static var onDeviceModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Immutable framing around the user's prompt. The transcript itself goes
    @available(iOS 27.0, *)
    private static func fitsOnDevice(text: String, instructions: String) async -> Bool {
        let model = SystemLanguageModel.default
        do {
            let inputTokens = try await model.tokenCount(for: text)
            let instructionTokens = try await model.tokenCount(for: instructions)
            // The rewrite is roughly as long as its input, plus schema overhead.
            let needed = instructionTokens + (inputTokens * 2) + 256
            let fits = needed <= model.contextSize
            if !fits {
                log.notice("rewrite needs ~\(needed) tokens > on-device context \(model.contextSize); routing to Private Cloud Compute")
            }
            return fits
        } catch {
            // Counting failed — let the on-device attempt decide.
            return true
        }
    }

    /// One rewrite call: the text is quoted as data in the user turn
    /// (`RewriteInstructions.userTurn`); the instructions carry the rule.
    private static func run(
        makeSession: (String) -> LanguageModelSession,
        instructions: String,
        text: String,
        route: String
    ) async throws -> String {
        let started = Date()
        let out = try await respond(session: makeSession(instructions), text: text)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("rewrite via \(route, privacy: .public) in \(ms) ms — in \(text.count) chars, out \(out.count) chars")
        return out
    }

    private static func respond(session: LanguageModelSession, text: String) async throws -> String {
        do {
            let response = try await session.respond(to: RewriteInstructions.userTurn(text), generating: Rewrite.self)
            let trimmed = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.emptyOutput }
            return trimmed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = Self.classified(error)
            // Help → Diagnostics shows this; it is how "cleanup stopped working"
            // gets a cause instead of a guess (features.md §6.7).
            DiagnosticsLog.record(
                source: "main-app",
                category: .rewriteFailed,
                message: mapped.localizedDescription,
                metadata: [
                    "chars": String(text.count),
                    "rateLimited": Self.isRateLimited(mapped) ? "true" : "false",
                    "error": String(String(describing: error).prefix(300)),
                ]
            )
            throw mapped
        }
    }
}
