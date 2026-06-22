import AppIntents
import Foundation

/// Headless "jot down <text>" capture: take a string Siri/Shortcuts already
/// has as text and save it as a transcript — **no mic, no recording pipeline,
/// no app foregrounding.**
///
/// ## Why this is NOT a recording intent
///
/// `RecordAndTranscribeIntent` foregrounds Jot to start the mic (issue #3 —
/// iOS forbids cold-background mic start). This intent has *no mic*: the text
/// already exists (Siri did the STT, or a prior Shortcut step produced it), so
/// it sidesteps the foreground-gate entirely. It runs headless inside the
/// Shortcuts/Siri runtime, exactly like `TranscribeAudioFileIntent`.
///
/// ## Save path — direct `TranscriptStore.append`, NOT the dictation pipeline
///
/// We persist straight through `TranscriptStore.append(...)` rather than
/// `DictationPipeline.completeEndOfRecording`. The pipeline's end-of-recording
/// tail does clipboard publish, cross-process keyboard handoff, and chained
/// follow-up classification — all correct for a *dictation* UX, all wrong for a
/// pure text drop (nothing is listening for those cross-process notifications
/// here, and a Siri text note shouldn't hijack the clipboard). `append` is the
/// genuinely headless save: it inserts the row, refreshes the keyboard's JSON
/// mirror, and kicks off background indexing — nothing else. (Design B3 /
/// review VC-1.)
///
/// `duration: nil` — there was no recording, so wall-clock duration isn't
/// meaningful; the ledger renders a duration-less row cleanly (same as
/// `TranscribeAudioFileIntent`).
///
/// ## Discoverability — Shortcuts only, NOT an AppShortcut tile
///
/// `isDiscoverable = true` surfaces it as a Shortcuts action (with a `text`
/// input, so users chain "Get text → Save a note"). It is deliberately NOT
/// registered in `JotAppShortcuts.appShortcuts` and carries no Siri
/// auto-phrase: a multi-phrase / extra-tile change risks the Action-Button
/// binding that Jot's primary capture path rides on (review MF-4). Siri-phrase
/// wiring is a separate, gated step.
///
/// ## Shape decisions (mirror `TranscribeAudioFileIntent`)
///
/// - **`openAppWhenRun = false`** — load-bearing; runs in-process headless, the
///   user never leaves their current app.
/// - **No struct-level `@MainActor`** — historically un-bindable on the Action
///   Button picker. `perform()` hops to `@MainActor` only for the save call
///   (`TranscriptStore`/`JotModelContainer` are main-app, main-actor-touched).
/// - **`parameterSummary` present** — iOS 26.2's Shortcuts daemon renders it
///   during the binding commit; its absence can surface a generic "Something
///   went wrong" error.
///
/// Lives in the main-app target: `TranscriptStore` is `#if JOT_APP_HOST`-gated,
/// and AppIntents without a separate extension run in the app process
/// (review VC-1).
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a note"

    static let description = IntentDescription(
        // NOTE: an App Intent description must NOT contain the word "Siri"
        // (App Store rejects with ITMS-90626 / "Invalid Siri Support"). Keep
        // this copy Siri-free.
        """
        Save text as a note in Jot, with no recording. \
        Chain it after any action that produces text. \
        Fully local — nothing leaves your device.
        """,
        categoryName: "Capture"
    )

    /// Load-bearing. Headless — no foreground, no mic. See class doc.
    static let openAppWhenRun: Bool = false

    /// Surface in the Shortcuts action catalog (NOT as an AppShortcut tile —
    /// see class doc). Pinned so a future SDK default flip can't hide it.
    static let isDiscoverable: Bool = true

    @Parameter(
        title: "Note",
        description: "The text to save as a note.",
        requestValueDialog: "What should I jot down?"
    )
    var text: String

    /// Rendered as the action body in the Shortcuts editor; also the prompt
    /// Siri reads back if `text` is missing. See class doc on why this is
    /// present even though there's a single parameter.
    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) as a Jot note")
    }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // `append` would no-op on empty input anyway; short-circuit with a
            // clear spoken result rather than a silent "Saved" for nothing.
            return .result(dialog: "There was nothing to save.")
        }

        // Direct, headless append — see class doc on why we bypass
        // `DictationPipeline`. `TranscriptStore.append` returns a non-`Sendable`
        // `@Model`; swallow it with `_ =` so the closure's inferred type stays
        // `Void` and nothing crosses the actor boundary.
        try await MainActor.run {
            _ = try TranscriptStore.append(raw: trimmed, duration: nil)
        }

        return .result(dialog: "Saved.")
    }
}
