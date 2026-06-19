import Foundation

/// **App-Group bridge for the keyboard correction quick-review.**
/// The keyboard extension is a separate process that cannot read the main app's
/// vocabulary provenance (app-local sandbox, SwiftData). So after a saved
/// dictation the MAIN APP publishes the small set of "asks" (≤3 highest-value
/// gated words worth reviewing) into the shared App-Group suite, keyed by the
/// dictation's `sessionID`; the keyboard reads them to show its post-dictation
/// nudge. When the owner adjudicates in the keyboard, the keyboard ENQUEUES
/// verdict events back into the App Group; the main app drains + applies them
/// (`CorrectionInbox`) into provenance + `CorrectionStore` next time it's active.
///
/// Self-contained Codable shapes (no App-target types) so both processes compile
/// against it. `recordKey` is the provenance `Record.key` string — the keyboard
/// treats it as an opaque id; the app maps it back to the occurrence.
enum CorrectionBridge {

    // MARK: - Shapes

    struct Ask: Codable, Sendable, Equatable {
        let recordKey: String
        let original: String        // what TDT wrote ("Jamie")
        let term: String            // the vocab term ("Jamy")
        let outcome: String         // "applied" | "kept"
        let contextBefore: String   // ~24 chars before the word (ellipsized)
        let contextAfter: String    // ~24 chars after
        /// Char offset + length of the gated word in the published text — lets the
        /// keyboard splice the chosen word deterministically for ask-before-paste
        /// (Thread 2), instead of fragile context-matching. Optional: a blob encoded
        /// before Thread 2 has no key, so the SYNTHESIZED decode yields nil (the
        /// post-paste nudge path doesn't need it). The explicit init defaults keep
        /// pre-Thread-2 call sites compiling.
        let publishedStart: Int?
        let publishedLength: Int?

        init(recordKey: String, original: String, term: String, outcome: String,
             contextBefore: String, contextAfter: String,
             publishedStart: Int? = nil, publishedLength: Int? = nil) {
            self.recordKey = recordKey
            self.original = original
            self.term = term
            self.outcome = outcome
            self.contextBefore = contextBefore
            self.contextAfter = contextAfter
            self.publishedStart = publishedStart
            self.publishedLength = publishedLength
        }
    }

    struct Asks: Codable, Sendable {
        let sessionID: UUID
        let transcriptID: UUID
        let asks: [Ask]
        /// Total UNRESOLVED proposals on the transcript (not just the ≤3 asks).
        /// Drives the keyboard "Done" stage's "N more guesses are on the
        /// transcript in Jot." second line. Optional for back-compat with any
        /// previously-encoded payload (decodes to 0).
        let totalUnresolved: Int

        init(sessionID: UUID, transcriptID: UUID, asks: [Ask], totalUnresolved: Int) {
            self.sessionID = sessionID
            self.transcriptID = transcriptID
            self.asks = asks
            self.totalUnresolved = totalUnresolved
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try c.decode(UUID.self, forKey: .sessionID)
            transcriptID = try c.decode(UUID.self, forKey: .transcriptID)
            asks = try c.decode([Ask].self, forKey: .asks)
            totalUnresolved = try c.decodeIfPresent(Int.self, forKey: .totalUnresolved) ?? asks.count
        }
    }

    struct VerdictEvent: Codable, Sendable {
        let transcriptID: UUID
        let recordKey: String
        let verdict: String         // "term" | "original"
    }

    // MARK: - Keys (local to the bridge; same suite as the rest)

    private static let asksKey = "jot.correction.asks"
    private static let verdictsKey = "jot.correction.verdicts"

    // MARK: - App → keyboard (asks)

    /// Publish the asks for the just-saved dictation (overwrites the prior set —
    /// only the most recent dictation's nudge is ever relevant).
    static func publishAsks(_ asks: Asks) {
        guard !asks.asks.isEmpty, let data = try? JSONEncoder().encode(asks) else {
            AppGroup.defaults.removeObject(forKey: asksKey)
            return
        }
        AppGroup.defaults.set(data, forKey: asksKey)
    }

    /// Read the asks IF they match `sessionID` (so the keyboard only nudges for
    /// the dictation it just completed, not a stale one).
    static func readAsks(sessionID: UUID) -> Asks? {
        guard
            let data = AppGroup.defaults.data(forKey: asksKey),
            let asks = try? JSONDecoder().decode(Asks.self, from: data),
            asks.sessionID == sessionID
        else { return nil }
        return asks
    }

    /// The latest published asks, regardless of session — used by the keyboard's
    /// `correctionAsksReady` handler, which fires right after the app publishes
    /// them for the dictation the keyboard just handled (so "latest" IS this one).
    static func readLatestAsks() -> Asks? {
        guard
            let data = AppGroup.defaults.data(forKey: asksKey),
            let asks = try? JSONDecoder().decode(Asks.self, from: data)
        else { return nil }
        return asks
    }

    static func clearAsks() {
        AppGroup.defaults.removeObject(forKey: asksKey)
    }

    // MARK: - Keyboard → app (verdict queue)

    /// Append a verdict the owner gave in the keyboard. The app drains these when
    /// it next becomes active.
    static func enqueueVerdict(_ event: VerdictEvent) {
        var queue = pendingVerdicts()
        queue.append(event)
        if let data = try? JSONEncoder().encode(queue) {
            AppGroup.defaults.set(data, forKey: verdictsKey)
        }
    }

    /// Read the verdict queue WITHOUT clearing — the app applies these, then
    /// calls `removeVerdicts(count:)` for exactly the ones it processed. Apply-
    /// then-remove (vs read-and-clear) means a crash mid-apply leaves the queue
    /// intact → retried next foreground (at-least-once; the inbox's "already
    /// adjudicated?" guard makes a re-apply a no-op), and a verdict enqueued
    /// DURING apply (index ≥ count) survives the remove.
    static func peekVerdicts() -> [VerdictEvent] {
        pendingVerdicts()
    }

    /// Drop the first `count` verdicts (the ones just applied); anything enqueued
    /// since is preserved.
    static func removeVerdicts(count: Int) {
        guard count > 0 else { return }
        var queue = pendingVerdicts()
        queue.removeFirst(min(count, queue.count))
        if queue.isEmpty {
            AppGroup.defaults.removeObject(forKey: verdictsKey)
        } else if let data = try? JSONEncoder().encode(queue) {
            AppGroup.defaults.set(data, forKey: verdictsKey)
        }
    }

    private static func pendingVerdicts() -> [VerdictEvent] {
        guard
            let data = AppGroup.defaults.data(forKey: verdictsKey),
            let queue = try? JSONDecoder().decode([VerdictEvent].self, from: data)
        else { return [] }
        return queue
    }
}
