import Foundation

/// App-Group-backed bounded array of recently-finished pipeline sessions.
///
/// Solves the keyboard's "did the session for which I'm waiting actually
/// finish?" question without depending on a one-slot projection field that
/// could be overwritten before the keyboard observes it. A bursty user (or
/// rapid app cycle) can produce N terminal transitions before the keyboard
/// next presents — all N appear in the log.
///
/// Capacity 64 is generous enough that a realistic burst between keyboard
/// presentations cannot evict a tombstone. Records older than `pruneAge`
/// (5 min) are pruned on every read — defence-in-depth on top of the FIFO
/// capacity bound.
///
/// `hadPublish` is retained on each record for diagnostic logging only — it
/// does NOT gate the keyboard's terminal cleanup. Per design Q2, the UUID
/// state machine alone is the source of truth; gating on `!hadPublish` would
/// leave pending stuck whenever `.idle` (hadPublish=true) was observed after
/// the 30s payload freshness window expired.
struct TerminalSessionRecord: Codable, Sendable, Equatable {
    let sessionID: UUID
    let finishedAt: Date
    let hadPublish: Bool
}

enum TerminalSessionLog {
    static let capacity = 64
    static let pruneAge: TimeInterval = 5 * 60

    static func append(_ record: TerminalSessionRecord) {
        var log = readRaw().filter { $0.finishedAt.timeIntervalSinceNow > -pruneAge }
        log.append(record)
        if log.count > capacity {
            log.removeFirst(log.count - capacity)
        }
        guard let data = try? encoder.encode(log) else { return }
        AppGroup.defaults.set(data, forKey: AppGroup.Keys.terminalSessionLog)
    }

    /// Public read — prunes age-stale records on every call.
    static func read() -> [TerminalSessionRecord] {
        readRaw().filter { $0.finishedAt.timeIntervalSinceNow > -pruneAge }
    }

    /// Whether the given session has appeared in the terminal log. The only
    /// gate the keyboard uses for sad-path cleanup. `hadPublish` is for
    /// diagnostics, not flow control.
    static func contains(sessionID: UUID) -> Bool {
        read().contains(where: { $0.sessionID == sessionID })
    }

    static func reset() {
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.terminalSessionLog)
    }

    private static func readRaw() -> [TerminalSessionRecord] {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.terminalSessionLog),
            let log = try? decoder.decode([TerminalSessionRecord].self, from: data)
        else { return [] }
        return log
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
