import Foundation
import JotVocabCore
import Observation
import SwiftUI

/// Loads, mutates, and persists the user's custom vocabulary list.
///
/// Ported from `jot/Sources/Vocabulary/VocabularyStore.swift` with two
/// adaptations for the mobile target:
///   1. `@MainActor @Observable` instead of `ObservableObject` —
///      matches the rest of the mobile app's SwiftUI state shape.
///   2. Persistence path is the main app's
///      `Application Support/Vocabulary/vocabulary.txt`. The keyboard
///      extension doesn't read or write this file — vocabulary biasing
///      runs only inside the main app's transcription path. If a
///      future feature needs the keyboard to see the list, move the
///      file into the App Group container.
///
/// Persistence format (one term per line, optional aliases after a
/// colon separator) is identical to the desktop:
///
/// ```
/// UJET: you jet, ew jet
/// Osiris
/// D'Andre: dandre, dahndray
/// Parakeet
/// ```
///
/// Colon (not pipe) because that's what FluidAudio's
/// `CustomVocabularyContext.loadFromSimpleFormat(from:)` consumes
/// directly — when the on-device rescorer wires in, it points at this
/// exact file. Format rules: `#` for line comments, comma-separated
/// aliases, all whitespace/newlines trimmed.
///
/// Writes serialize through the MainActor barrier; the vocab file is
/// small enough (<4 KB at 100 terms) that synchronous writes are well
/// inside the frame budget.
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var terms: [VocabTerm] = []

    /// Set when the most recent `save()` failed to write the vocabulary
    /// file to disk; `nil` once a later save succeeds. Surfaced as a
    /// footnote in `VocabularySettingsView` — previously this failure
    /// was swallowed entirely, silently dropping the user's edit.
    private(set) var lastSaveError: String?

    /// Master toggle. When off, the vocabulary file is still preserved
    /// and editable; it's just not applied to transcription. Stored in
    /// UserDefaults so the preference survives reinstalls (provided the
    /// user's iCloud Settings backup is on).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "jot.vocabulary.enabled"

    /// Location of the user's vocabulary file. `nil` only if the
    /// Application Support directory is unavailable, which we don't
    /// expect in the shipping app. Resolved once per process lifetime.
    @ObservationIgnored
    private(set) lazy var fileURL: URL? = {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("Vocabulary", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    private init() {
        load()
    }

    // MARK: - Load / save

    /// The file exists but could not be read. Saving would replace the user's
    /// list with whatever is in memory (nothing), so no write lands until a
    /// load works — the `VocabularyListWriting.isWritable` contract.
    @ObservationIgnored
    private(set) var loadFailed = false

    func load() {
        guard let url = fileURL,
              let data = try? String(contentsOf: url, encoding: .utf8)
        else {
            loadFailed = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if loadFailed {
                lastSaveError = "Your vocabulary file couldn't be read, so changes aren't being saved."
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .vocabularySaveFailed,
                    message: "Vocabulary load failed: file exists but is unreadable; writes disabled"
                )
            }
            terms = []
            return
        }
        loadFailed = false
        terms = VocabularyFile.parse(data)
    }

    func save() {
        guard let url = writeToDisk() else { return }
        // Nudge the rescorer to re-tokenize against the updated file.
        // Cheap when the rescorer is already prepared; throws
        // `.notPrepared` (swallowed) otherwise, so a save with vocab
        // boosting disabled is a no-op. Keeps the "edit vocab, record
        // immediately" UX promised by the desktop's same hook.
        //
        // FIRE-AND-FORGET on purpose — a keystroke in the Vocabulary pane must
        // not wait on a CoreML rescorer build. A caller that needs the rebuild
        // to have LANDED before it records (voice teaching's sentence test)
        // uses `updateAwaitingRescorer` instead; this path's semantics are
        // unchanged for everyone else.
        //
        // DEBOUNCED + single-flight: every term-field keystroke writes through
        // this method, and each rebuild is a full `VocabularyRescorer.create`
        // (CoreML). Typing a ten-character term used to queue ten of them, nine
        // of which the holder's `generation` guard then threw away after paying
        // for them. The delay is short enough to keep the desktop's "edit vocab,
        // record immediately" promise, and the last write always wins.
        if isEnabled {
            rebuildTask?.cancel()
            rebuildTask = Task {
                try? await Task.sleep(nanoseconds: Self.rebuildDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                try? await VocabularyRescorerHolder.shared.rebuildVocabulary(from: url)
            }
        }
    }

    /// Coalesces the keystroke storm described in `save()`.
    @ObservationIgnored
    private var rebuildTask: Task<Void, Never>?
    private static let rebuildDebounceNanoseconds: UInt64 = 400_000_000

    /// `update(id:aliases:)` + a rebuild the caller can AWAIT.
    ///
    /// The two vocabulary paths read different sources: the model-free
    /// corrector reads `terms` in memory, but the acoustic path reads the FILE
    /// through `CustomVocabularyContext.loadFromSimpleFormat` and only picks up
    /// a change when `rebuildVocabulary` has finished building a new CoreML
    /// rescorer. `save()`'s unstructured Task gives no completion signal, and
    /// `VocabularyRescorerHolder.awaitReady` can't stand in for one — it polls
    /// `isReady`, which is already true for the STALE vocabulary. So a flow
    /// that writes aliases and immediately records would test the vocabulary it
    /// just replaced. This is the awaitable path for those flows.
    ///
    /// Returns once the write is on disk and the rebuild has settled (or thrown
    /// — `.notPrepared` simply means the acoustic path is not in play on this
    /// device, and the model-free corrector already sees the in-memory change).
    /// A concurrent `save()` can still supersede this rebuild via the holder's
    /// `generation` guard; callers that care hold the only editing surface for
    /// the duration.
    func updateAwaitingRescorer(id: VocabTerm.ID, aliases: [String]) async {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[idx].aliases = aliases
        guard let url = writeToDisk(), isEnabled else { return }
        // Cancel any debounced rebuild from a pending keystroke: it would fire
        // mid-recording and, being later, would win the holder's generation
        // arbitration against the rebuild awaited here.
        rebuildTask?.cancel()
        rebuildTask = nil
        try? await VocabularyRescorerHolder.shared.rebuildVocabulary(from: url)
    }

    /// Serializes `terms` to the vocabulary file. Returns the URL written on
    /// success so callers can drive the rescorer rebuild themselves; `nil` when
    /// there is nothing to write to or the write failed — a failed write leaves
    /// the file holding the OLD terms, and rebuilding the rescorer from those
    /// would only re-install what is already loaded.
    @discardableResult
    private func writeToDisk() -> URL? {
        guard let url = fileURL, !loadFailed else { return nil }
        let body = VocabularyFile.serialize(terms)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            lastSaveError = nil
        } catch {
            // Blocking the UI on a persistence failure is worse than
            // letting the app carry on — but the failure must be visible
            // somewhere, so it's recorded to Diagnostics and surfaced as
            // a status footnote in VocabularySettingsView rather than
            // dropped silently.
            lastSaveError = error.localizedDescription
            DiagnosticsLog.record(
                source: "main-app",
                category: .vocabularySaveFailed,
                message: "Vocabulary save failed: \(error.localizedDescription)"
            )
            return nil
        }
        return url
    }

    // MARK: - Mutations (each writes through)

    @discardableResult
    func addBlankTerm() -> VocabTerm {
        let new = VocabTerm(text: "")
        terms.append(new)
        save()
        return new
    }

    /// Strip the simple format's structural characters from a term/alias value:
    /// ":" always (term/alias delimiter), "," for aliases (alias separator),
    /// leading "#" (comment marker), then collapse whitespace. NOTE: the
    /// Settings rows' free-text editing (`update(id:text:)`) predates this and
    /// is NOT yet routed through here — tracked with the vocabulary-section
    /// overhaul (plan §12).
    ///
    /// Alias-only form of the existing persistence guard. Voice teaching keeps
    /// the recognizer's raw text for review, but candidates entering the simple
    /// file must not be allowed to change its line/field structure.
    nonisolated static func fileSafeAlias(_ value: String) -> String {
        fileSafe(value, isAlias: true)
    }

    nonisolated private static func fileSafe(_ s: String, isAlias: Bool) -> String {
        var out = s.replacingOccurrences(of: ":", with: " ")
        if isAlias { out = out.replacingOccurrences(of: ",", with: " ") }
        out = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while out.hasPrefix("#") { out.removeFirst() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    func delete(id: VocabTerm.ID) {
        terms.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        terms.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Plain row write (the Settings term field fires this per keystroke;
    /// voice teaching's provisional test list). A learned sounds-like never
    /// comes through here: every correction surface calls
    /// `VocabularyLearning.shared.apply`, which writes through the
    /// `VocabularyListWriting` seam below.
    func update(id: VocabTerm.ID, text: String? = nil, aliases: [String]? = nil) {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        if let text { terms[idx].text = text }
        if let aliases { terms[idx].aliases = aliases }
        save()
    }

    // The simple-format parser/serializer moved verbatim into the package as
    // `JotVocabCore.VocabularyFile` (byte-identical across apps and to
    // FluidAudio's `loadFromSimpleFormat`); `load()`/`save()` call it directly.
}

/// The list seam of `JotVocabCore.VocabularyLearning` (Learn from Corrections):
/// plain row writes by id. Matching, dedupe and casing rules live in the shared
/// code; every correction surface goes through `VocabularyLearning.shared.apply`,
/// never these.
extension VocabularyStore: VocabularyListWriting {
    /// Longest term / sounds-like (whitespace tokens) the list accepts — the
    /// shared edit learner's term cap. A sounds-like re-spells the term, so the
    /// same ceiling applies; a longer selection is a mis-drag, not a term.
    static let maxTermWords = EditLearner.maxTermWords

    var isWritable: Bool { !loadFailed }

    /// The store's own file-safe scrub (":" / "," / leading "#" stripped,
    /// whitespace collapsed), capped at `maxTermWords`. Serves a term and a
    /// sounds-like alike.
    func cleanEntry(_ raw: String) -> String? {
        let cleaned = Self.fileSafeAlias(raw)
        guard !cleaned.isEmpty,
              cleaned.split(whereSeparator: { $0 == " " }).count <= Self.maxTermWords
        else { return nil }
        return cleaned
    }

    func addTerm(_ text: String) -> VocabTerm.ID {
        let term = VocabTerm(text: text)
        terms.append(term)
        save()
        return term.id
    }

    func removeTerm(id: VocabTerm.ID) {
        delete(id: id)
    }

    func setText(_ text: String, id: VocabTerm.ID) {
        update(id: id, text: text)
    }

    func setSoundsLikes(_ soundsLikes: [String], id: VocabTerm.ID) {
        update(id: id, aliases: soundsLikes)
    }
}
