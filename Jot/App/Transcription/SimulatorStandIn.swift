import Foundation

@MainActor
protocol TranscriptionStandIn {
    func transcribe(samples: [Float]) async throws -> String
}

enum TranscriptionStandInFactory {
    @MainActor
    static func make() -> (any TranscriptionStandIn)? {
        #if targetEnvironment(simulator)
        SimulatorStandIn()
        #else
        nil
        #endif
    }
}

#if targetEnvironment(simulator)
@MainActor
struct SimulatorStandIn: TranscriptionStandIn {
    private static let sentences = [
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
        "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
        "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
        "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
        "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
    ]

    func transcribe(samples: [Float]) async throws -> String {
        try await Task.sleep(for: .milliseconds(1_500))

        let count = Int.random(in: 1...3)
        return Self.sentences
            .shuffled()
            .prefix(count)
            .joined(separator: " ")
    }
}
#endif
