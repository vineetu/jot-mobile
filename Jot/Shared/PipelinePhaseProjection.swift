import Foundation

/// App-Group-projected pipeline phase. Single source of truth for cross-process
/// observation of "where is the dictation pipeline RIGHT NOW?". Written by the
/// app process (`RecordingService`); read by the keyboard extension. Changes
/// are signalled by `CrossProcessNotification.pipelinePhaseChanged`; correctness
/// must come from the projection state itself, never from the signal alone.
///
/// The writer-process refreshes `lastUpdatedAt` every `heartbeatInterval` while
/// non-terminal, so the keyboard's reader can synthesize a `.failed` view when
/// the projection is non-idle and stale (older than `heartbeatStaleThreshold`).
/// This is the dead-writer recovery: app crashed mid-pipeline, no further
/// heartbeat ever arrives, the keyboard's bounded stale-deadline task fires
/// and re-reads — `read()` synthesizes `.failed` and the keyboard's terminal
/// cleanup branch runs.
struct PipelinePhaseProjection: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle
        case recording
        case transcribing
        case processing
        case cleaning
        /// Chained LLM rewrite running between Parakeet finalize and the
        /// final clipboard publish. Treated by the keyboard exactly like
        /// `.transcribing / .processing / .cleaning` (in-flight, mic CTA
        /// disabled, streaming preview placeholder reads "Working on it…").
        case rewriting
        case publishing
        case failed
    }

    let phase: Phase
    let sessionID: UUID?
    let recordingStartedAt: Date?
    let lastUpdatedAt: Date
    let failureReason: String?

    /// Heartbeat: every 10s while non-idle, the writer process refreshes
    /// `lastUpdatedAt`. The reader treats a non-idle projection older than
    /// 30s (3× heartbeat) as the writer being dead and synthesizes a
    /// `.failed` view without mutating storage.
    static let heartbeatInterval: TimeInterval = 10
    static let heartbeatStaleThreshold: TimeInterval = 30

    static func write(_ projection: PipelinePhaseProjection) {
        guard let data = try? encoder.encode(projection) else { return }
        AppGroup.defaults.set(data, forKey: AppGroup.Keys.pipelinePhase)
    }

    /// Returns the projection AS WRITTEN, except: if the projection is
    /// non-idle, non-failed, and older than `heartbeatStaleThreshold`, a
    /// synthetic `.failed` projection is returned (the keyboard reacts to
    /// that the same way it reacts to an explicit `.failed`). Storage is not
    /// mutated by the reader — only the writer-process owns clears.
    static func read() -> PipelinePhaseProjection? {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.pipelinePhase),
            let projection = try? decoder.decode(PipelinePhaseProjection.self, from: data)
        else { return nil }

        switch projection.phase {
        case .idle, .failed:
            return projection
        case .recording, .transcribing, .processing, .cleaning, .rewriting, .publishing:
            let age = Date().timeIntervalSince(projection.lastUpdatedAt)
            if age > heartbeatStaleThreshold {
                return PipelinePhaseProjection(
                    phase: .failed,
                    sessionID: projection.sessionID,
                    recordingStartedAt: nil,
                    lastUpdatedAt: projection.lastUpdatedAt,
                    failureReason: "stale heartbeat"
                )
            }
            return projection
        }
    }

    /// Called by the writer-process at app boot to clear any leftover from a
    /// crashed previous launch, regardless of age.
    static func reset() {
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.pipelinePhase)
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
