import Foundation

struct RecordingStateProjection: Codable, Sendable, Equatable {
    let isRecording: Bool
    let startedAt: Date?
    let lastUpdatedAt: Date

    private static let key = "jot.recording.state"

    /// If a recording-active projection's `lastUpdatedAt` is older than this,
    /// treat it as stale (the app likely crashed / was killed mid-recording
    /// without updating the flag back to false). The keyboard must NOT keep
    /// thinking a recording is in flight forever — that would route every
    /// mic-tap to "stop" instead of "open the app".
    static let staleThreshold: TimeInterval = 300  // 5 minutes

    static func write(state: RecordingStateProjection) {
        guard let data = try? encoder.encode(state) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }

    static func read() -> RecordingStateProjection? {
        guard
            let data = AppGroup.defaults.data(forKey: key),
            let state = try? decoder.decode(RecordingStateProjection.self, from: data)
        else { return nil }

        // Defensively reset stale recording state. If isRecording is true but
        // the projection hasn't been refreshed in 5 minutes, the writing
        // process almost certainly died without clearing it. Returning a
        // forced-idle projection keeps the keyboard mic CTA usable.
        if state.isRecording {
            let age = Date().timeIntervalSince(state.lastUpdatedAt)
            if age > staleThreshold {
                clear()
                return RecordingStateProjection(
                    isRecording: false,
                    startedAt: nil,
                    lastUpdatedAt: Date()
                )
            }
        }

        return state
    }

    static func clear() {
        AppGroup.defaults.removeObject(forKey: key)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
