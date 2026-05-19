import Foundation

/// App Group–backed projection of the most recent transcripts so the keyboard
/// extension can render history without initializing the SwiftData stack.
///
/// ## Why a JSON mirror instead of reading SwiftData from the keyboard
///
/// Keyboard extensions run under a ~50–66 MB memory ceiling and must draw the
/// first frame as fast as possible on every `viewWillAppear`. Opening the
/// shared SwiftData store from the extension is technically possible but costs
/// three things we can't afford:
///
/// 1. **Cold-start latency.** `ModelContainer(for:)` + schema validation on
///    first access is an unbounded cost on the hot keyboard-present path.
/// 2. **Schema-migration blast radius.** Any model change triggers automatic
///    migration twice (main app + keyboard); a mid-migration crash in the
///    keyboard takes down every app that uses Jot as its active keyboard —
///    a far worse failure mode than a main-app crash.
/// 3. **Memory pressure.** CoreData's row cache grows with query history and
///    the keyboard has no headroom for surprises.
///
/// A bounded JSON file (20 rows, < 8 KB typical) solves all three: zero
/// schema surface, sub-millisecond decode, predictable footprint. SwiftData
/// stays the source of truth in the main app; this is a read-only projection.
///
/// ## Contract
///
/// - **Main app** (via `TranscriptStore.append`) calls `refresh(from:)` —
///   declared in a main-app-only extension — after each insert and on cold
///   launch. That method queries SwiftData for the last `maxEntries` rows
///   and writes this JSON atomically to the App Group container.
/// - **Keyboard** calls `load()` on `viewWillAppear`. Result is cached for
///   the duration of the presentation; next appearance reloads.
/// - Write failures are silent — the mirror is a convenience, never a
///   correctness dependency. A missing mirror simply hides history until the
///   next append refreshes it.
public enum TranscriptHistoryMirror {
    /// Maximum rows persisted in the mirror. Balances "useful window of
    /// recent dictations" against memory + disk cost in the keyboard. The
    /// list is already bounded by what fits on a phone screen before
    /// scrolling becomes unwieldy.
    public static let maxEntries = 20

    /// Flattened projection of a `Transcript` — no `@Model` machinery, no
    /// SwiftData dependency. Keyboard never sees a SwiftData type.
    public struct Entry: Codable, Identifiable, Sendable, Hashable {
        public let id: UUID
        /// Preferred display text (cleaned if cleanup was applied, else raw).
        public let text: String
        public let createdAt: Date
        /// Stable user-visible ledger number (`#NNNN` chip in the main app).
        public let ledgerIndex: Int
        /// `true` when the source transcript has an AI rewrite
        /// (`cleanedText != nil`). Drives the small sparkles affordance in
        /// the keyboard recents row. Optional + default-false at decode
        /// time so a stale on-disk mirror written by an older build still
        /// decodes — the next `refresh(from:)` overwrites with the real
        /// value.
        public let hasRewrite: Bool

        public init(
            id: UUID,
            text: String,
            createdAt: Date,
            ledgerIndex: Int,
            hasRewrite: Bool = false
        ) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.ledgerIndex = ledgerIndex
            self.hasRewrite = hasRewrite
        }

        private enum CodingKeys: String, CodingKey {
            case id, text, createdAt, ledgerIndex, hasRewrite
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.text = try c.decode(String.self, forKey: .text)
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
            self.ledgerIndex = try c.decode(Int.self, forKey: .ledgerIndex)
            self.hasRewrite = try c.decodeIfPresent(Bool.self, forKey: .hasRewrite) ?? false
        }
    }

    // MARK: - File location

    private static let filename = "transcript-history.json"

    /// URL of the mirror inside the App Group container. Returns `nil` if the
    /// App Group entitlement resolution failed — in practice this only
    /// happens when the keyboard is loaded without Full Access granted yet.
    private static var fileURL: URL? {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else { return nil }
        return root.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - Read (keyboard side)

    /// Load the mirrored history, newest first. Returns an empty array if
    /// the mirror doesn't exist yet, the file is empty, or decoding fails.
    /// Never throws — callers get a best-effort snapshot or nothing at all.
    public static func load() -> [Entry] {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let entries = try? decoder.decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - Write (main-app side; invoked from extension in `App/`)

    /// Atomically persist an already-sorted (newest first) array to the App
    /// Group mirror. Truncated to `maxEntries`. Callers in the main app are
    /// responsible for building the array from SwiftData — see the
    /// `refresh(from:)` extension in the main-app target.
    public static func write(_ entries: [Entry]) {
        guard let url = fileURL else { return }
        let truncated = Array(entries.prefix(maxEntries))
        guard let data = try? encoder.encode(truncated) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Remove the mirror entirely. Intended for "wipe history" flows in the
    /// main app's settings — the keyboard side simply treats a missing file
    /// as empty history.
    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Coders

    /// ISO-8601 dates round-trip cleanly across target boundaries and are
    /// human-readable if the mirror is ever inspected during debugging.
    /// `.sortedKeys` keeps the on-disk form deterministic so diffs between
    /// successive refreshes are meaningful.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
