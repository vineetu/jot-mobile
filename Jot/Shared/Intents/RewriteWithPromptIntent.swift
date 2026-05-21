import AppIntents
import Foundation

/// AppIntent that performs an LLM rewrite of a selection using a
/// saved prompt's system prompt.
///
/// ## What this is
///
/// An `AppIntent` invoked programmatically by the keyboard extension when
/// the user taps a saved-prompt row inside the Magic menu. The keyboard
/// fires the intent with `(promptID, selection)`; the body running in the
/// main app does the prompt lookup, drives `LLMClientFactory.active.rewrite(...)`,
/// and writes the terminal result back through the App Group + posts a
/// Darwin notification so the keyboard can render the result.
///
/// Today no caller fires this intent's `perform()` directly — the
/// keyboard hands rewrite requests off via `jot://rewrite?session=<uuid>`
/// URL bounce, which the main-app `onOpenURL` handler routes to
/// `RewriteRequestDispatcher.dispatch(sessionID:)`. The intent body is
/// preserved as dead code so a future Shortcuts step can wire up against it
/// without re-writing the dispatch glue.
///
/// ## Why this lives in `Jot/Shared/Intents/`
///
/// The keyboard extension target must see this type to instantiate it
/// (`RewriteWithPromptIntent(promptID: selection:)`). But the body needs to
/// call into main-app-only code (`LLMClientFactory`, `Qwen35Client`, etc.).
/// The fix is the `JOT_APP_HOST` compile flag set on the main-app target
/// only — the keyboard compiles the `#else` stub, the main-app process
/// compiles the real `#if JOT_APP_HOST` body.
///
/// ## Job-ID guard
///
/// The intent stamps a fresh `UUID` into `AppGroup.rewriteJobID` at start,
/// then re-checks it before writing the terminal slots. If the user fires
/// a second rewrite while the first is mid-flight, the older job's
/// `LLMClient.rewrite(...)` may resolve after the new job has overwritten
/// the slot — the guard discards that stale tail. This is the rewrite-side
/// analogue of `DictationPostProcessingCoordinator.cancel()`.
///
/// ## Cancellation
///
/// User-initiated cancel goes through `AppGroup.rewriteCancelRequested`,
/// which the active `LLMClient`'s chunk loop polls between decoded chunks
/// (the polling helper lives in `RewriteCancelPolling.swift`). When the
/// loop calls `Task.cancel()`, the intent's `do/catch` converts the
/// resulting `CancellationError` into a `rewriteError = "Cancelled"`
/// write. The keyboard reads that special string and suppresses the
/// toast — a user-initiated cancel is not a failure to surface.
struct RewriteWithPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Rewrite Selection"

    static let description = IntentDescription(
        """
        Rewrite the selected text using a saved Jot prompt and copy the \
        result back to the keyboard.
        """,
        categoryName: "Rewrite"
    )

    static let openAppWhenRun: Bool = false

    /// Rewrite must fire on a locked phone — there's no confidentiality
    /// boundary the intent itself crosses (the user already typed the
    /// selection into the host app, and the rewrite runs against an
    /// already-saved prompt). Default `requiresAuthentication` would
    /// silently break the keyboard's tap-row flow when the device is locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Not user-discoverable in Shortcuts/Siri — this is a programmatic
    /// fire from the keyboard, not a surface a user would ever wire into a
    /// shortcut graph by hand. The two parameters are opaque IDs/raw text;
    /// exposing them in the Shortcuts editor would just confuse users.
    static let isDiscoverable: Bool = false

    /// Even non-discoverable intents declare a summary on iOS 26 — its
    /// absence surfaces a generic "Something went wrong" error during the
    /// Shortcuts daemon's binding commit step. Kept fixed-string (no
    /// parameter interpolation) because exposing `selection`'s raw text
    /// in a Shortcuts preview row would leak host-app content.
    static var parameterSummary: some ParameterSummary {
        Summary("Rewrite Selection With Prompt")
    }

    /// String-encoded UUID of the saved prompt to apply. The intent looks
    /// the prompt up via `SavedPromptStore.all()` (Stage 3) at the start of
    /// `perform()` — if the prompt has been deleted between the keyboard
    /// fire and the main-app body running, we surface a "Prompt not found"
    /// error rather than silently no-op.
    @Parameter(title: "Prompt ID")
    var promptID: String

    /// The raw selected text from the host app. The intent does not
    /// pre-clean or trim this — the LLM sees exactly what the user
    /// selected, so the rewrite reflects the user's actual intent (e.g.
    /// preserved leading/trailing whitespace inside a code comment).
    @Parameter(title: "Selection")
    var selection: String

    init() {}

    init(promptID: String, selection: String) {
        self.promptID = promptID
        self.selection = selection
    }

    /// Two-target body. The main-app target compiles the real `JOT_APP_HOST`
    /// branch and routes through `RewriteRequestDispatcher`; the keyboard
    /// extension compiles the `#else` no-op stub so the type is still
    /// instantiable from the keyboard process.
    ///
    /// Today no caller fires this intent's `perform()` directly — the
    /// keyboard hands rewrite requests off via `jot://rewrite?session=<uuid>`
    /// URL bounce, which the main-app `onOpenURL` handler routes to
    /// `RewriteRequestDispatcher.dispatch(sessionID:)`. The intent body is
    /// preserved as dead code so a future surface (Shortcuts step,
    /// Live-Activity-button) can wire up against it without re-writing the
    /// dispatch glue.
    func perform() async throws -> some IntentResult {
        #if JOT_APP_HOST
        if #available(iOS 26.0, *) {
            // Allocate a fresh job ID so the slot guard inside the dispatcher
            // can drop a stale tail if the user fires a second rewrite while
            // this one is in flight. Mirrors `RewriteRequestDispatcher`'s
            // pre-dispatch slot hygiene.
            guard let promptUUID = UUID(uuidString: promptID),
                  let prompt = SavedPromptStore.all().first(where: { $0.id == promptUUID })
            else {
                AppGroup.rewriteResult = nil
                AppGroup.rewriteError = "Prompt not found"
                AppGroup.rewriteJobID = nil
                RewriteNotifications.postCompleted()
                return .result()
            }

            let jobID = UUID()
            await MainActor.run {
                AppGroup.rewriteJobID = jobID
                AppGroup.rewriteResult = nil
                AppGroup.rewriteError = nil
                AppGroup.rewriteCancelRequested = false
            }

            do {
                let client = await MainActor.run { LLMClientFactory.shared.client() }
                let result = try await client.rewrite(
                    text: selection,
                    systemPrompt: prompt.systemPrompt
                )

                await MainActor.run {
                    guard AppGroup.rewriteJobID == jobID else { return }
                    AppGroup.rewriteResult = result
                    AppGroup.rewriteError = nil
                    AppGroup.rewriteJobID = nil
                    RewriteNotifications.postCompleted()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard AppGroup.rewriteJobID == jobID else { return }
                    AppGroup.rewriteError = RewriteNotifications.cancelledSentinel
                    AppGroup.rewriteResult = nil
                    AppGroup.rewriteJobID = nil
                    RewriteNotifications.postCompleted()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard AppGroup.rewriteJobID == jobID else { return }
                    AppGroup.rewriteError = message
                    AppGroup.rewriteResult = nil
                    AppGroup.rewriteJobID = nil
                    RewriteNotifications.postCompleted()
                }
            }
        }
        return .result()
        #else
        // Keyboard-extension stub. The keyboard never invokes `perform()`
        // directly today — it goes through `jot://rewrite?session=<uuid>`
        // URL bounce. If a future surface fires the intent from the
        // extension target, returning `.result()` is the safe no-op.
        return .result()
        #endif
    }
}
