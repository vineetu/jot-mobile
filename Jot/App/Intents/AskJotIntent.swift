import AppIntents
import Foundation

/// Headless "ask your notes" Q&A: take a spoken/typed question, answer it from
/// the user's own notes (and the bundled product-help corpus) via the
/// view-free `AskEngine`, and read the answer back — **no mic, no recording,
/// no app foregrounding.**
///
/// ## Why this is NOT a recording intent
///
/// This is question-answering, not capture. The question already exists as text
/// (the voice runtime did the STT, or a prior Shortcut step produced it), so
/// there is no mic and no foreground-gate to fight: it runs headless in the
/// Shortcuts/voice runtime exactly like `CaptureTextIntent`. The answer is
/// synthesized on-device by `AskEngine`, which reuses `AskController`'s exact
/// retrieval + prompt construction — only the delivery differs (non-streaming,
/// view-free, concise `.spoken` style suited to read-aloud).
///
/// ## Availability is RETURNED, not thrown
///
/// `AskEngine.answer` never throws for unavailability — it returns
/// `.unavailable(reason)`. We map each `AskController.UnavailableReason` to a
/// friendly spoken line that guides the user to finish setting up on-device AI,
/// rather than surfacing a raw error. `.failed(_)` carries an internal message
/// we deliberately do NOT read aloud (it isn't user-facing copy); we speak a
/// generic "try again" instead.
///
/// ## Discoverability — Shortcuts only, NOT an AppShortcut tile
///
/// `isDiscoverable = true` surfaces it as a Shortcuts action. It is deliberately
/// NOT registered in `JotAppShortcuts.appShortcuts` and carries no auto-phrase:
/// an extra tile / multi-phrase change risks the Action-Button binding Jot's
/// primary capture path rides on. Phrase wiring is a separate, gated step.
///
/// ## Shape decisions (mirror `CaptureTextIntent`)
///
/// - **`openAppWhenRun = false`** — load-bearing; runs in-process headless, the
///   user never leaves their current app.
/// - **No struct-level `@MainActor`** — historically un-bindable on the Action
///   Button picker. `perform()` is method-level `@MainActor` (the engine is
///   `@MainActor`), so the call hops cleanly.
/// - **`parameterSummary` present** — the Shortcuts daemon renders it during the
///   binding commit; its absence can surface a generic "Something went wrong".
///
/// ## App Store copy constraint
///
/// An App Intent's `title`/`description` must NOT contain the word "Siri" — the
/// App Store rejects it with ITMS-90626 / "Invalid Siri Support" (build 155 was
/// rejected for exactly this). All copy below is deliberately Siri-free.
///
/// Lives in the main-app target: `AskEngine` is `#if JOT_APP_HOST`-gated and
/// AppIntents without a separate extension run in the app process.
struct AskJotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask your notes"

    static let description = IntentDescription(
        // NOTE: an App Intent description must NOT contain the word "Siri"
        // (App Store rejects with ITMS-90626 / "Invalid Siri Support"). Keep
        // this copy free of that word.
        """
        Ask a question and get an answer drawn from your notes in Jot. \
        Fully local — your notes never leave your device.
        """,
        categoryName: "Ask"
    )

    /// Load-bearing. Headless — no foreground, no mic. See class doc.
    static let openAppWhenRun: Bool = false

    /// Surface in the Shortcuts action catalog (NOT as an AppShortcut tile —
    /// see class doc). Pinned so a future SDK default flip can't hide it.
    static let isDiscoverable: Bool = true

    @Parameter(
        title: "Question",
        description: "What to ask about your notes.",
        requestValueDialog: "What do you want to know about your notes?"
    )
    var question: String

    /// Rendered as the action body in the Shortcuts editor; also the prompt
    /// read back if `question` is missing. Present even with a single parameter
    /// (see class doc on the daemon binding commit).
    static var parameterSummary: some ParameterSummary {
        Summary("Ask your notes \(\.$question)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "There was no question to answer.")
        }

        let outcome = await AskEngine().answer(question: trimmed, style: .spoken)

        switch outcome {
        case .answer(let answer):
            // The synthesized, read-aloud answer (citation markers are already
            // stripped from `.spoken` output by contract).
            return .result(dialog: IntentDialog(stringLiteral: answer.text))

        case .vague:
            return .result(dialog: "I couldn't find anything about that in your notes.")

        case .unavailable(let reason):
            return .result(dialog: IntentDialog(stringLiteral: Self.dialog(for: reason)))

        case .failed:
            // `.failed` carries an internal diagnostic string, not user-facing
            // copy — never read it aloud. Speak a generic retry line instead.
            return .result(dialog: "Something went wrong answering that. Try again.")
        }
    }

    /// A friendly, action-guiding line per unavailability reason. Each points the
    /// user at the one thing that unblocks Ask, without surfacing internals.
    private static func dialog(for reason: AskController.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceOff:
            return "Ask needs on-device AI turned on. Open Jot to finish setting it up."
        case .deviceNotEligible:
            return "This device can't run Ask's on-device AI yet."
        case .modelDownloading:
            return "Ask's AI is still downloading. Try again in a little while."
        case .qwenNotDownloaded:
            return "Ask isn't available right now — open Jot to finish setting up AI."
        case .unknown:
            return "Ask isn't available right now — open Jot to finish setting up AI."
        }
    }
}
