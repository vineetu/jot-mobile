import Foundation

enum SetupCompletion {
    static let key = "jot.setup.completed"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.set(false, forKey: key)
    }
}

@MainActor
@Observable
final class SettingsRerunTrigger {
    static let shared = SettingsRerunTrigger()

    private(set) var requestID = UUID()

    private init() {}

    func requestRerun() {
        SetupCompletion.reset()
        requestID = UUID()
    }
}
