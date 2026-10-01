import Foundation
import Observation

/// Cross-process navigation requests the keyboard makes of the main app.
///
/// Today there is exactly one: "open this transcript" (`jot://transcript?id=…`),
/// optionally with the rewrite flow started on arrival. The former
/// saved-prompt rewrite HANDOFF (`jot://rewrite?session=…`, where the keyboard
/// picked a prompt and waited on a pasteback from the on-device Qwen model)
/// was retired with that model; the keyboard never runs a language model.
@MainActor
@Observable
final class KeyboardRewriteRouter {
    /// Set by `JotApp.onOpenURL` when the keyboard taps the row-trailing
    /// affordance on a recents row. ContentView observes this and pushes the
    /// target onto its NavigationPath via
    /// `.navigationDestination(for: OpenTranscriptTarget.self)`.
    var pendingOpenTranscript: OpenTranscriptTarget?

    /// A transcript the keyboard asked the app to open.
    ///
    /// `autoRewrite` carries the recents row's Apple Intelligence tap
    /// (`jot://transcript?id=…&ai=1`): the detail view opens and, if the note
    /// has no rewrite yet, starts one immediately with the Cleanup prompt —
    /// otherwise it lands on the Rewrite tab (features.md §5.2). False = plain
    /// open (Spotlight, "See all", any non-AI caller).
    struct OpenTranscriptTarget: Identifiable, Hashable {
        let id: UUID
        let autoRewrite: Bool
    }

    func setPendingOpenTranscript(id: UUID, autoRewrite: Bool) {
        pendingOpenTranscript = OpenTranscriptTarget(id: id, autoRewrite: autoRewrite)
    }

    func consumePendingOpenTranscript() -> OpenTranscriptTarget? {
        let target = pendingOpenTranscript
        pendingOpenTranscript = nil
        return target
    }
}
