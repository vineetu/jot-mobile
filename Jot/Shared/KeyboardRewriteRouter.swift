import Foundation
import Observation

@MainActor
@Observable
final class KeyboardRewriteRouter {
    var pendingTarget: KeyboardRewriteTarget?

    /// Set by `JotApp.onOpenURL` when the keyboard taps the row-trailing
    /// "open in app" affordance on a recents row. ContentView observes this
    /// and pushes the transcript onto its NavigationPath via the existing
    /// `.navigationDestination(for: UUID.self)` handler. Distinct from
    /// `pendingTarget` (the rewrite-handoff path) because the user is NOT
    /// running a rewrite — they want to read or edit the transcript.
    var pendingOpenTranscriptID: UUID?

    struct KeyboardRewriteTarget: Identifiable, Hashable, Equatable {
        let id: UUID
        let sessionID: UUID
        let jobID: UUID
        let promptID: UUID
        let selectionLength: Int
    }

    func setPending(_ target: KeyboardRewriteTarget) {
        pendingTarget = target
    }

    func consumePending() -> KeyboardRewriteTarget? {
        let target = pendingTarget
        pendingTarget = nil
        return target
    }

    func setPendingOpenTranscript(id: UUID) {
        pendingOpenTranscriptID = id
    }

    func consumePendingOpenTranscript() -> UUID? {
        let id = pendingOpenTranscriptID
        pendingOpenTranscriptID = nil
        return id
    }
}
