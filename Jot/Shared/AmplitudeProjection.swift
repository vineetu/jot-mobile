import Foundation

/// Cross-process projection of `RecordingService.currentAmplitude`.
/// Written by the main app from a MainActor hop at ~10 Hz while
/// recording is active; read by the keyboard extension on a ~15 Hz
/// polling loop to drive the mic CTA pulse. Cleared by the main app
/// when recording stops.
///
/// **Why off the audio thread.** The audio tap fires on a real-time
/// render thread (Apple QA1715); even thread-safe APIs like
/// UserDefaults can introduce non-deterministic latency that causes
/// audio glitches. The existing publication hops to MainActor first;
/// this projection rides along on that hop.
///
/// **Encoding.** Timestamp is milliseconds-since-1970 stored as a
/// Double. We deliberately avoid `Date` + `JSONEncoder.iso8601` here
/// because Foundation's ISO8601 encoder truncates subsecond
/// precision, which would break the 1 s staleness window.
struct AmplitudeProjection: Codable, Sendable, Equatable {
    let amplitude: Float           // 0.0 - 1.0
    let lastUpdatedAtMS: Double    // milliseconds since 1970-01-01

    private static let key = AppGroup.Keys.recordingAmplitude

    /// Tighter than RecordingStateProjection's 5 min: a frozen
    /// amplitude pill is a UX bug (it suggests speech volume that
    /// isn't there). With ~10 Hz writes, 1 s = ~10 missed updates,
    /// which is the right "writer probably died" threshold.
    static let staleThreshold: TimeInterval = 1.0

    static func write(amplitude: Float) {
        let projection = AmplitudeProjection(
            amplitude: amplitude,
            lastUpdatedAtMS: Date().timeIntervalSince1970 * 1000
        )
        guard let data = try? encoder.encode(projection) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }

    static func read() -> AmplitudeProjection? {
        guard
            let data = AppGroup.defaults.data(forKey: key),
            let projection = try? decoder.decode(AmplitudeProjection.self, from: data)
        else { return nil }

        let nowMS = Date().timeIntervalSince1970 * 1000
        let ageMS = nowMS - projection.lastUpdatedAtMS
        guard ageMS >= 0, ageMS < staleThreshold * 1000 else { return nil }
        return projection
    }

    static func clear() {
        AppGroup.defaults.removeObject(forKey: key)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
