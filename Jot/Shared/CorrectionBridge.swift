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

    /// **F3 — a producer-validated exact edit descriptor.** The app resolves,
    /// against the immutable text it is about to hand to the keyboard, EXACTLY
    /// which characters a paste-changing choice would replace, and ships that
    /// here. `start` is a CHARACTER offset (`Array(text)` index, the unit both
    /// sides already splice in); `text` is the substring standing at
    /// `[start, start + text.count)` VERBATIM — the consumer re-verifies it
    /// against its own copy of the baseline before editing, so a descriptor that
    /// was resolved against a different string can only fail closed.
    ///
    /// `text` is not necessarily the ask's word: resolution is case-insensitive
    /// and Unicode case folds vary in length, so the baseline's own casing is
    /// what gets carried.
    struct EditSpan: Codable, Sendable, Equatable {
        let start: Int
        /// Exclusive end. Carried explicitly (rather than derived from
        /// `text.count`) so the two sides can DISAGREE loudly: a descriptor
        /// whose `end` doesn't match its own text is malformed and is refused
        /// at both the emit and the apply site rather than silently reinterpreted.
        let end: Int
        let text: String

        init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        /// Half-open character range this descriptor claims.
        var range: Range<Int> { start..<end }

        /// A descriptor that replaces NO characters is not an edit — it is an
        /// insertion, and an empty range is invisible to overlap validation, so
        /// it would rewrite text nobody checked. The producer asserts this
        /// before publishing and the consumer re-checks it before applying.
        var isWellFormed: Bool {
            start >= 0 && end > start && end - start == text.count
        }

        // `end` is additive on a field that has never shipped in a payload, but
        // decode it defensively anyway: a blob written without it derives the
        // same value the old `range` did.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Int.self, forKey: .start)
            text = try c.decode(String.self, forKey: .text)
            end = try c.decodeIfPresent(Int.self, forKey: .end) ?? (start + text.count)
        }
    }

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
        /// 3-option ask (2026-07-13): an alternate vocab term for the same
        /// span ("Claude Code" when "Claude" won). `altFind` is the exact
        /// in-text string the alternate replaces (winner + following words).
        /// Optional — nil keeps the familiar 2-option card, and blobs encoded
        /// before this field decode to nil. Plain strings (not the gate's
        /// Alternate type) because this file compiles into the keyboard
        /// target, which doesn't build the vocabulary subsystem.
        let altTerm: String?
        let altFind: String?
        /// V2-3: true for teach-only asks (split-word merge class) that must
        /// NEVER hold the paste — they surface via the post-paste teach strip
        /// instead. Optional/nil = normal ask (back-compat decode).
        let postPasteOnly: Bool?
        /// **F3 exact edit descriptors** (2026-08-30). The authoritative span the
        /// ask's paste-changing choices replace in the published baseline, as
        /// resolved and validated BY THE PRODUCER (`CorrectionAsksPublisher`):
        ///   - `baseEdit` — the span the in-text word occupies, i.e. what the
        ///     original↔term flip replaces (one span serves both directions);
        ///   - `altEdit` — the wider span `altFind` occupies, when the 3-option
        ///     alternate survived validation.
        /// Optional and additive: a payload encoded before F3 decodes both as nil
        /// and the keyboard keeps its own resolver (the consumer half of F3 lands
        /// in the next batch — see docs/plans/vocab-hold-deck-reliability.md).
        /// A NIL `baseEdit` on a paste-holding ask never occurs in a payload this
        /// version produces: an ask whose base edit cannot be honored is dropped
        /// before publish rather than offered.
        let baseEdit: EditSpan?
        let altEdit: EditSpan?

        init(recordKey: String, original: String, term: String, outcome: String,
             contextBefore: String, contextAfter: String,
             publishedStart: Int? = nil, publishedLength: Int? = nil,
             altTerm: String? = nil, altFind: String? = nil,
             postPasteOnly: Bool? = nil,
             baseEdit: EditSpan? = nil, altEdit: EditSpan? = nil) {
            self.recordKey = recordKey
            self.original = original
            self.term = term
            self.outcome = outcome
            self.contextBefore = contextBefore
            self.contextAfter = contextAfter
            self.publishedStart = publishedStart
            self.publishedLength = publishedLength
            self.altTerm = altTerm
            self.altFind = altFind
            self.postPasteOnly = postPasteOnly
            self.baseEdit = baseEdit
            self.altEdit = altEdit
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

    /// Clear the asks blob ONLY if it belongs to `sessionID`. The blob is a
    /// single global slot, so an unguarded clear from a path that is ending an
    /// OLD deck (supersession, stranded-deck sweeps) would delete a NEWER
    /// session's just-published asks. Deck-terminal cleanup goes through this;
    /// the unguarded `clearAsks()` stays for the owner-of-the-blob paths that
    /// already know the blob is theirs.
    static func clearAsks(matching sessionID: UUID) {
        guard
            let data = AppGroup.defaults.data(forKey: asksKey),
            let asks = try? JSONDecoder().decode(Asks.self, from: data),
            asks.sessionID == sessionID
        else { return }
        AppGroup.defaults.removeObject(forKey: asksKey)
    }

    // MARK: - Keyboard → app (verdict queue)

    /// Append a verdict the owner gave in the keyboard and tell the app. The
    /// app applies it at once if it is running (`correctionVerdictQueued`),
    /// otherwise the next time it becomes active.
    static func enqueueVerdict(_ event: VerdictEvent) {
        var queue = pendingVerdicts()
        queue.append(event)
        if let data = try? JSONEncoder().encode(queue) {
            AppGroup.defaults.set(data, forKey: verdictsKey)
        }
        CrossProcessNotification.post(name: CrossProcessNotification.correctionVerdictQueued)
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
