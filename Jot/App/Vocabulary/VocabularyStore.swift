import Foundation
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

    func load() {
        guard let url = fileURL,
              let data = try? String(contentsOf: url, encoding: .utf8)
        else {
            terms = []
            return
        }
        terms = Self.parse(data)
    }

    func save() {
        guard let url = fileURL else { return }
        let body = Self.serialize(terms)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Swallow for now — surface in Settings status row in a
            // follow-up. Blocking the UI on a persistence failure is
            // worse than the silent drop for the MVP.
        }
        // Nudge the rescorer to re-tokenize against the updated file.
        // Cheap when the rescorer is already prepared; throws
        // `.notPrepared` (swallowed) otherwise, so a save with vocab
        // boosting disabled is a no-op. Keeps the "edit vocab, record
        // immediately" UX promised by the desktop's same hook.
        if isEnabled {
            Task {
                try? await VocabularyRescorerHolder.shared.rebuildVocabulary(from: url)
            }
        }
    }

    // MARK: - Mutations (each writes through)

    @discardableResult
    func addBlankTerm() -> VocabTerm {
        let new = VocabTerm(text: "")
        terms.append(new)
        save()
        return new
    }

    /// Add `text` as a term (dedup, case-insensitive), optionally attaching the
    /// mis-transcription it was `heardAs` as a "sounds like" alias — the alias
    /// feeds the rescorer's string matching directly, so the same mis-hear gets
    /// caught acoustically next time. If the term already exists, only the alias
    /// is merged in. Returns the CANONICAL stored term text (post file-format
    /// sanitizing — callers recording learning mappings must key on this, not on
    /// what was typed), or nil when nothing valid was stored. Drives the
    /// transcript pane's selection-menu "Add to Vocabulary" (the mobile
    /// Vocabulary UI has no aliases field — currently the only alias writer).
    @discardableResult
    func addTerm(_ text: String, heardAs: String? = nil) -> String? {
        // The plain-text simple format has structural characters — ":" splits
        // term from aliases, "," splits aliases, leading "#" comments the line
        // out. A typed term carrying them would corrupt the file on the next
        // parse (silently mutating or DELETING entries), so they're stripped
        // here at the single write choke point.
        let trimmed = Self.fileSafe(text, isAlias: false)
        guard !trimmed.isEmpty else { return nil }
        let alias: String? = heardAs.map { Self.fileSafe($0, isAlias: true) }

        var changed = false
        if let idx = terms.firstIndex(where: {
            !$0.isBlank && $0.text.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            if let alias, !alias.isEmpty,
               alias.compare(trimmed, options: .caseInsensitive) != .orderedSame,
               !terms[idx].aliases.contains(where: { $0.compare(alias, options: .caseInsensitive) == .orderedSame }) {
                terms[idx].aliases.append(alias)
                changed = true
            }
        } else {
            let aliases: [String] = {
                guard let alias, !alias.isEmpty,
                      alias.compare(trimmed, options: .caseInsensitive) != .orderedSame else { return [] }
                return [alias]
            }()
            terms.append(VocabTerm(text: trimmed, aliases: aliases))
            changed = true
        }
        if changed { save() }
        return trimmed
    }

    /// Strip the simple format's structural characters from a term/alias value:
    /// ":" always (term/alias delimiter), "," for aliases (alias separator),
    /// leading "#" (comment marker), then collapse whitespace. NOTE: the
    /// Settings rows' free-text editing (`update(id:text:)`) predates this and
    /// is NOT yet routed through here — tracked with the vocabulary-section
    /// overhaul (plan §12).
    private static func fileSafe(_ s: String, isAlias: Bool) -> String {
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

    func update(id: VocabTerm.ID, text: String? = nil, aliases: [String]? = nil) {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        if let text { terms[idx].text = text }
        if let aliases { terms[idx].aliases = aliases }
        save()
    }

    // MARK: - Simple-format parser / serializer (identical to desktop)

    /// Parse the plain-text format. Lines starting with `#` are treated
    /// as comments. Empty lines are skipped. Terms with duplicate text
    /// are preserved.
    static func parse(_ body: String) -> [VocabTerm] {
        var result: [VocabTerm] = []
        let lines = body.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let text = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            let aliases: [String] = parts.count > 1
                ? parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                : []

            result.append(VocabTerm(text: text, aliases: aliases))
        }
        return result
    }

    static func serialize(_ terms: [VocabTerm]) -> String {
        var lines: [String] = []
        for t in terms where !t.isBlank {
            let trimmedText = t.text.trimmingCharacters(in: .whitespaces)
            if t.aliases.isEmpty {
                lines.append(trimmedText)
            } else {
                lines.append("\(trimmedText): \(t.aliases.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
