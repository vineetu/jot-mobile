import Foundation

/// **Per-transcript correction provenance + per-occurrence resolution store.**
/// Stores the gate's full proposal list for each saved transcript (so the
/// transcript pane can show "here's what Jot corrected / considered") AND the
/// owner's per-occurrence verdicts (so an answered occurrence never re-asks).
///
/// Two stores, deliberately separate (plan §v2-C):
///   - **proposals (`records`)** — what the gate did, per OCCURRENCE. Each record
///     carries a STABLE identity (`originalStart`, the span's offset in the
///     original pre-rescore text) plus a published-text HINT range for rendering.
///   - **verdicts** — the owner's `term | original` pick per occurrence, keyed by
///     that stable identity. A verdict HIDES the row (resolved) and drives the
///     this-occurrence text edit. It is the ONLY thing that decides "answered."
///   - **mappingsTaught** — guard so a mapping (`original→term`) feeds the
///     MAPPING-level learning store (`CorrectionStore`) at most once per
///     transcript, regardless of how many occurrences the owner adjudicates.
///     Prevents three "name→Jamy" picks from inflating net to 3.
///
/// Timing (the gate runs BEFORE the transcript id exists): the gate fills a
/// transient `pending` slot at rescore time; `commit(transcriptID:)` moves it to
/// a side-JSON keyed by the real id once the transcript is saved. Dictation is
/// serial → the single pending slot is safe.
///
/// Storage: `Application Support/Vocabulary/provenance/<transcriptID>.json`.
actor CorrectionProvenance {
    static let shared = CorrectionProvenance()

    /// One gated occurrence. `originalStart`/`originalLength` are the stable
    /// identity (offset in the ORIGINAL text); `publishedStart`/`publishedLength`
    /// are a render/edit hint into the PUBLISHED text, re-validated at render.
    struct Record: Codable, Sendable, Equatable {
        let originalWord: String     // what TDT wrote ("Jamie")
        let term: String             // the vocab term ("Jamy")
        let decision: String         // "APPLY" | "BLOCK" | "OVERRIDE"
        let outcome: String          // "applied" | "kept"
        let confidence: Float
        let margin: Float
        let unsure: Bool
        let occurrenceIndex: Int     // display-only
        let originalStart: Int
        let originalLength: Int
        let publishedStart: Int
        let publishedLength: Int

        /// Stable per-occurrence identity key (verdict + mark lookup).
        var key: String { "\(originalWord.lowercased())|\(term.lowercased())|\(originalStart)" }
        /// Mapping key (shared by every occurrence of the same original→term).
        var mappingKey: String { "\(originalWord.lowercased())|\(term.lowercased())" }
    }

    /// On-disk shape: proposals + per-occurrence verdicts + this transcript's
    /// current contribution to each mapping's learning net (+1/−1, reversible).
    struct Payload: Codable, Sendable {
        var records: [Record] = []
        var verdicts: [String: String] = [:]      // record.key → "term" | "original"
        var contributions: [String: Int] = [:]    // record.mappingKey → this transcript's net contribution
    }

    /// What a verdict change does to a mapping's global learning net. The caller
    /// applies it to `CorrectionStore.adjust`. `delta == 0` ⇒ nothing to do.
    struct MappingDelta: Sendable {
        let originalWord: String
        let term: String
        let delta: Int
    }

    private var pending: [Record] = []

    // MARK: - Gate side (write)

    /// Called at rescore time (no transcript id yet) — stashes this dictation's
    /// proposals until the transcript is saved.
    func record(_ proposals: [VocabularyGate.Proposal]) {
        pending = proposals.map {
            Record(
                originalWord: $0.originalWord, term: $0.term, decision: $0.decision,
                outcome: $0.outcome, confidence: $0.confidence, margin: $0.margin,
                unsure: $0.unsure, occurrenceIndex: $0.occurrenceIndex,
                originalStart: $0.originalStart, originalLength: $0.originalLength,
                publishedStart: $0.publishedStart, publishedLength: $0.publishedLength)
        }
    }

    /// Clears the pending slot. Called at the START of every transcription so a
    /// no-proposal dictation — or a non-saving caller (Ask/watch/file-import) that
    /// filled the slot — can never have a stale `pending` committed under the next
    /// transcript's id.
    func clearPending() { pending = [] }

    /// Persist the pending records under the saved transcript id (fresh verdicts).
    func commit(transcriptID: UUID) {
        let records = pending
        pending = []
        guard !records.isEmpty, let url = fileURL(transcriptID) else {
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate, message: "provenance commit SKIPPED",
                metadata: ["records": "\(records.count)", "id": transcriptID.uuidString])
            return
        }
        // Commit is once-per-fresh-id, but be defensive: if a payload already
        // exists for this id (a re-commit / retry), PRESERVE the owner's verdicts
        // and the mapping-taught guard — only the records are (re)written. A blind
        // overwrite would silently wipe answered rows.
        let existing = payload(transcriptID: transcriptID)
        let payload = Payload(records: records, verdicts: existing.verdicts, contributions: existing.contributions)
        var wrote = false
        if let data = try? JSONEncoder().encode(payload) {
            do { try data.write(to: url, options: .atomic); wrote = true } catch {}
        }
        DiagnosticsLog.record(
            source: "main-app", category: .vocabularyGate, message: "provenance committed",
            metadata: ["records": "\(records.count)", "wrote": "\(wrote)", "id": transcriptID.uuidString])
    }

    // MARK: - Pane side (read + verdict)

    /// Full payload for a transcript (proposals + verdicts).
    func payload(transcriptID: UUID) -> Payload {
        guard
            let url = fileURL(transcriptID),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return decoded
    }

    /// Record a per-occurrence verdict and return how the mapping's global net
    /// should move (caller applies it to `CorrectionStore`). `verdict` ∈
    /// {"term","original"}. A transcript contributes at most ±1 per mapping
    /// (recomputed from ALL its verdicts), so three "name→Jamy" picks can't
    /// inflate net to 3, and a mixed transcript (some term, some revert) gives 0.
    func setVerdict(transcriptID: UUID, record: Record, verdict: String) -> MappingDelta? {
        var p = payload(transcriptID: transcriptID)
        p.verdicts[record.key] = verdict
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    /// Undo a verdict — clears the pick (row re-surfaces) and reverses this
    /// transcript's mapping contribution if no sibling verdict still supports it.
    func clearVerdict(transcriptID: UUID, record: Record) -> MappingDelta? {
        var p = payload(transcriptID: transcriptID)
        p.verdicts.removeValue(forKey: record.key)
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    /// Recompute this transcript's contribution to `record`'s mapping from its
    /// CURRENT verdicts, store it, and return the delta vs the stored value.
    private func finalize(_ p: inout Payload, transcriptID: UUID, record: Record) -> MappingDelta? {
        let mk = record.mappingKey
        let desired = desiredContribution(p, mappingKey: mk)
        let old = p.contributions[mk] ?? 0
        if desired == 0 { p.contributions[mk] = nil } else { p.contributions[mk] = desired }
        persist(transcriptID: transcriptID, p)
        let delta = desired - old
        return delta == 0 ? nil : MappingDelta(originalWord: record.originalWord, term: record.term, delta: delta)
    }

    /// +1 if the owner meant the term for this mapping (any "term", no revert),
    /// −1 if they reverted an applied one (any revert, no "term"), 0 if mixed or
    /// only "kept-original" (no learning signal).
    private func desiredContribution(_ p: Payload, mappingKey: String) -> Int {
        let occ = p.records.filter { $0.mappingKey == mappingKey }
        let anyTerm = occ.contains { p.verdicts[$0.key] == "term" }
        let anyDemote = occ.contains { p.verdicts[$0.key] == "original" && $0.outcome == "applied" }
        if anyTerm && !anyDemote { return 1 }
        if anyDemote && !anyTerm { return -1 }
        return 0
    }

    /// Drop a transcript's provenance (e.g. when the transcript is deleted).
    func discard(transcriptID: UUID) {
        guard let url = fileURL(transcriptID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Storage

    private func persist(transcriptID: UUID, _ p: Payload) {
        guard let url = fileURL(transcriptID), let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ id: UUID) -> URL? {
        guard
            let dir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        let prov = dir.appendingPathComponent("Vocabulary/provenance", isDirectory: true)
        try? FileManager.default.createDirectory(at: prov, withIntermediateDirectories: true)
        return prov.appendingPathComponent("\(id.uuidString).json")
    }
}
