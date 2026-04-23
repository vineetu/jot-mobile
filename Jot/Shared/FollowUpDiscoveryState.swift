import Foundation

enum FollowUpDiscoveryState: String {
    case unseen
    case awaitingFirstFollowUp
    case learned
    case awaitingContextAck
    case dismissed
}

enum FollowUpDiscoveryStore {
    static let key = "followUpDiscoveryState"

    static var state: FollowUpDiscoveryState {
        get {
            let rawValue = UserDefaults.standard.string(forKey: key)
                ?? FollowUpDiscoveryState.unseen.rawValue
            return FollowUpDiscoveryState(rawValue: rawValue) ?? .unseen
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
