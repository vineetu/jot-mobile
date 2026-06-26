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
        /// Post-stop warm-hold window: the mic engine stays warm (ready for an
        /// instant warm-resume) but is NOT capturing. Was previously implicit —
        /// signalled by the separate `warmHoldExpiresAt`/`warmHoldHeartbeat`
        /// App-Group keys (removed in B4). Now a first-class state inside the
        /// record (carrying `warmExpiresAt` + a fresh `liveness`); the keyboard
        /// reads warm-vs-cold from this one blob (`recordStartDecision`).
        case warmIdle
        /// Start requested, engine coming up, first real audio buffer NOT yet
        /// confirmed (the verified-recording gate state — §2.3 / A3). The record
        /// advertises `recording` only AFTER a first buffer routes; between
        /// "start requested" and "first buffer confirmed" it is `arming`. The
        /// keyboard renders `arming` as idle/home until its dedicated
        /// "starting…" affordance lands in Build B (N4).
        case arming
        case recording
        /// Mid-dictation pause (UX-overhaul round 2, §10). The audio engine
        /// keeps running and the mic stays warm, but the slice router drops
        /// buffers so nothing is captured. Distinct from `.recording` so the
        /// hero and keyboard can both render a paused UI (Resume control,
        /// frozen elapsed clock) cross-process. `isRecording` stays `true`
        /// while paused — it is a sub-state of an active recording, terminated
        /// only by Resume or Stop/Cancel. The keyboard treats `.paused` as a
        /// live-but-not-capturing state (mic CTA shows Resume, not the in-
        /// flight spinner).
        case paused
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

        /// True for any phase where the app still owes the keyboard a terminal
        /// (`.idle`/`.failed`) — i.e. a recording control OR the in-flight tail.
        /// The keyboard's dead-app watchdog recovers when ANY of these is frozen
        /// (no heartbeat advance), so a suspended app can't hang the keyboard in
        /// either a recording-control state or mid-transcription. Centralised here
        /// so the controller + `KeyboardStreamingHub` agree on the set.
        var isActiveNonTerminal: Bool {
            switch self {
            case .arming, .recording, .paused, .transcribing, .processing,
                 .cleaning, .rewriting, .publishing:
                // `arming` owes a terminal too — it resolves to `.recording`
                // (first buffer) or `.failed` (timeout, §2.3), so a frozen
                // `arming` writer must be recoverable like any other in-flight
                // phase.
                return true
            case .idle, .warmIdle, .failed:
                // `warmIdle` is quasi-idle: a dead warm writer is simply
                // "not warm anymore" (reads as idle via `read()`), never a
                // synth-`.failed`. So it is NOT active-non-terminal.
                return false
            }
        }
    }

    let phase: Phase
    let sessionID: UUID?
    let recordingStartedAt: Date?
    let lastUpdatedAt: Date
    let failureReason: String?

    /// Non-nil ONLY in `.warmIdle` — folded in the old `warmHoldExpiresAt` key
    /// (removed in B4). The wall-clock instant the warm window expires; the
    /// keyboard's `recordStartDecision` gates `.warmResume` on it.
    let warmExpiresAt: Date?

    /// Single liveness stamp, refreshed on ONE cadence (~1s) in EVERY non-idle
    /// state — including `.warmIdle` (§2.2). The single answer to "is the writer
    /// alive right now?" (`now − liveness < livenessFresh`), which REPLACED the
    /// pipeline heartbeat (#2), the warm heartbeat (#4) and ping/pong (#7) — all
    /// removed in B4. Optional for backward-compatibility: a blob written by a
    /// pre-liveness build (or the legacy initializer) has no `liveness`; readers
    /// fall back to `lastUpdatedAt` via `livenessOrLegacy`.
    let liveness: Date?

    init(
        phase: Phase,
        sessionID: UUID?,
        recordingStartedAt: Date?,
        lastUpdatedAt: Date,
        failureReason: String?,
        warmExpiresAt: Date? = nil,
        liveness: Date? = nil
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.recordingStartedAt = recordingStartedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.failureReason = failureReason
        self.warmExpiresAt = warmExpiresAt
        self.liveness = liveness
    }

    /// Decoding tolerates a pre-A2 blob that lacks `warmExpiresAt` / `liveness`
    /// (both decoded as nil / absent). Custom so the new fields are
    /// `decodeIfPresent` rather than required — a missing field would otherwise
    /// fail the whole decode and the keyboard would read `nil` (idle), losing
    /// state across the upgrade boundary.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(Phase.self, forKey: .phase)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        recordingStartedAt = try c.decodeIfPresent(Date.self, forKey: .recordingStartedAt)
        lastUpdatedAt = try c.decode(Date.self, forKey: .lastUpdatedAt)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        warmExpiresAt = try c.decodeIfPresent(Date.self, forKey: .warmExpiresAt)
        liveness = try c.decodeIfPresent(Date.self, forKey: .liveness)
    }

    private enum CodingKeys: String, CodingKey {
        case phase, sessionID, recordingStartedAt, lastUpdatedAt
        case failureReason, warmExpiresAt, liveness
    }

    /// Convenience: the effective liveness instant for staleness math —
    /// `liveness` when present (A2+), else the legacy `lastUpdatedAt`.
    var livenessOrLegacy: Date { liveness ?? lastUpdatedAt }

    /// Heartbeat: every 3s while non-idle, the writer process refreshes
    /// `lastUpdatedAt`. A fast cadence (well under the keyboard's 5s
    /// control-tap liveness ceiling) lets the keyboard treat "no refresh
    /// within 5s of a control tap" as a clean dead-app signal — a live app,
    /// foreground or background, always stamps within 3s. The reader still
    /// treats a non-idle projection older than `heartbeatStaleThreshold` as
    /// the writer being dead and synthesizes a `.failed` view without
    /// mutating storage (the passive, non-tap recovery path).
    static let heartbeatInterval: TimeInterval = 3
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
        case .warmIdle:
            // A dead warm writer is simply "not warm anymore" — synthesize
            // `.idle` (NOT `.failed`) when the warm liveness is stale, so the
            // ghost-warm-hold cleanup the keyboard does today becomes a property
            // of `read()` (§2.2 / §4). Uses the unified liveness stamp when
            // present, else the legacy `lastUpdatedAt`. Nothing reads `warmIdle`
            // for a decision until Build B; this keeps `read()` self-consistent
            // now that A2 writes the state.
            let age = Date().timeIntervalSince(projection.livenessOrLegacy)
            if age > heartbeatStaleThreshold {
                return PipelinePhaseProjection(
                    phase: .idle,
                    sessionID: nil,
                    recordingStartedAt: nil,
                    lastUpdatedAt: projection.lastUpdatedAt,
                    failureReason: nil
                )
            }
            return projection
        case .arming, .recording, .paused, .transcribing, .processing, .cleaning, .rewriting, .publishing:
            let age = Date().timeIntervalSince(projection.livenessOrLegacy)
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

    /// The blob AS WRITTEN, with NO staleness synthesis — preserving the real
    /// `liveness`/`lastUpdatedAt`/`phase`. `read()` rewrites a stale non-idle
    /// record to a synthetic `.failed`/`.idle` (and drops `liveness`), which is
    /// what the keyboard wants. The app's own M2 next-foreground reconciliation
    /// (`RecordingService.reconcileOrphanedSessionOnForeground`) instead needs the
    /// UNsynthesized liveness to decide "was I suspended mid-session?" — so it
    /// reads raw. Storage is never mutated here either.
    static func readRaw() -> PipelinePhaseProjection? {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.pipelinePhase),
            let projection = try? decoder.decode(PipelinePhaseProjection.self, from: data)
        else { return nil }
        return projection
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
