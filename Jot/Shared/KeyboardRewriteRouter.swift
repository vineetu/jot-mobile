import Foundation
import Observation

@MainActor
@Observable
final class KeyboardRewriteRouter {
    var pendingTarget: KeyboardRewriteTarget?

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
}
