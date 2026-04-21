import Foundation
import SwiftData

/// Process-wide SwiftData container for Jot's transcript history.
///
/// ## Why a singleton and not `.modelContainer(for: Transcript.self)`
///
/// The scene-scoped `.modelContainer(for:)` modifier only constructs its
/// container on scene activation. Jot has two **headless** callers that must
/// append transcripts without foregrounding the app:
///
/// - `TranscribeAudioFileIntent` (Shortcuts, iOS 17 path)
/// - `RecordAndTranscribeIntent` (Action Button, iOS 18+ `AudioRecordingIntent`)
///
/// Both set `openAppWhenRun = false`. If the ledger wiring depended on a
/// scene, a user who only ever uses the Action Button would never see their
/// own history — the first time they opened the app, nothing would be there
/// because the intent had been writing to a container that never existed.
///
/// A `@MainActor static let` singleton sidesteps that: the first access
/// (whether from an intent's `perform()` or from `JotApp.body`) constructs
/// the on-disk store, and every subsequent caller reuses the same handle.
///
/// ## Why the store lives under the App Group container
///
/// Keyboard history rendering goes through `TranscriptHistoryMirror` (a bounded
/// JSON projection), so the keyboard extension does not open this SwiftData
/// stack directly. However, the *JSON mirror writer* runs in the main app and
/// writes into the App Group container, and the widget target compiles
/// `TranscriptStore` as part of `Shared/`. Keeping the underlying SQLite file
/// inside the App Group container (rather than the main app's private sandbox)
/// means future features — the widget quickly glancing the last N entries, a
/// share extension appending a transcribed file — can be enabled without a
/// second migration to move the store. It costs nothing today: the App Group
/// path is on the same volume, and `.none` CloudKit means nothing replicates
/// off-device either way.
///
/// Resolution via `groupContainer: .identifier(_:)` rather than an explicit
/// `url:` lets SwiftData own naming, versioning, and WAL-sibling layout
/// (`JotTranscripts.store`, `-shm`, `-wal`) — matching how it already manages
/// the default location.
///
/// `ModelContainer` is `Sendable` on iOS 17+, so holding it in a
/// `static let` is safe under strict concurrency. `ModelContext` is **not**
/// `Sendable` — callers must instantiate a fresh context on `@MainActor` per
/// append, which is cheap and exactly what `TranscriptStore.append` does.
@MainActor
enum JotModelContainer {
    static let shared: ModelContainer = {
        do {
            // Pre-create `Library/Application Support/` inside the App Group
            // container so SwiftData's `ModelContainer` construction finds
            // the intermediate directory on first launch. Without this, a
            // fresh install triggers a ~140-line `CoreData: error: ...
            // NSCocoaErrorDomain 512 / errno 2 (ENOENT)` storm in the
            // launch console before CoreData's internal recovery path
            // creates the missing dir and retries. The store ends up
            // functional either way — this is pure log-noise reduction.
            // `withIntermediateDirectories: true` is idempotent on warm
            // launches (returns immediately if the dir already exists).
            if let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.identifier
            ) {
                try? FileManager.default.createDirectory(
                    at: appGroupURL.appendingPathComponent("Library/Application Support"),
                    withIntermediateDirectories: true
                )
            }

            let schema = Schema([Transcript.self])
            let config = ModelConfiguration(
                "JotTranscripts",
                schema: schema,
                // Cross-process-reachable SQLite location. See class doc for
                // why this lives in the App Group rather than the main app's
                // sandbox — short version: future widget/share-extension
                // readers shouldn't need a second migration to find it.
                groupContainer: .identifier(AppGroup.identifier),
                // On-device only. We do not sync transcripts anywhere —
                // keeping the privacy promise symmetric with audio + model
                // cache, neither of which leave the device.
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Failure here means the on-disk store is corrupt or the schema
            // can't be instantiated. There's no meaningful recovery at
            // runtime — the ledger is a core surface. Fail loud so build /
            // test picks it up; in the field this would manifest as a crash
            // on first launch after a botched migration.
            fatalError("Unable to construct JotModelContainer: \(error)")
        }
    }()
}

/// One-line append path for finished transcripts.
///
/// ## Callers
///
/// - `ContentView` (in-app record → transcribe pipeline)
/// - `TranscribeAudioFileIntent.perform()` — after its transcription completes
/// - `RecordAndTranscribeIntent.endDictation(...)` — after cleanup+clipboard
///
/// Both intent call sites already run on `@MainActor` (the `perform()`
/// bodies are `@MainActor func`), so they can call `TranscriptStore.append`
/// directly with no hop.
///
/// ## Drops, not throws
///
/// This is fire-and-forget on purpose: throwing from a Shortcuts intent
/// surface after the user already saw a successful transcription copied to
/// their clipboard would be the worst of both worlds — they got the value
/// but also a confusing error chrome. We log+drop instead. The only
/// preventable failure mode (empty raw transcript) is filtered at the top.
@MainActor
enum TranscriptStore {
    /// `UserDefaults`-backed counter for the ledger number. Survives deletes
    /// so a given transcript's `#NNNN` label doesn't shift around as earlier
    /// rows are removed. Per-device, not synced — matches the rest of the
    /// ledger's on-device-only contract.
    private static let ledgerCounterKey = "jot.ledger.nextIndex"

    /// Returns the next ledger index and increments the counter atomically.
    /// `UserDefaults.integer(forKey:)` returns 0 for missing keys, so the
    /// very first append becomes `#1`.
    private static func nextLedgerIndex() -> Int {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: ledgerCounterKey)
        let next = current + 1
        defaults.set(next, forKey: ledgerCounterKey)
        return next
    }

    /// Append a completed transcript to the ledger.
    ///
    /// Returns the inserted `Transcript` so the chained-follow-up caller
    /// can hand its `.id` to the next `append(derivedFrom:)`, and so the
    /// intent pipeline can surface the new row's `createdAt` / `ledgerIndex`
    /// in the Live Activity or other immediate UI. The return is
    /// `@discardableResult`, so fire-and-forget callers don't change.
    ///
    /// After a successful save, refreshes the App Group JSON history mirror
    /// so the keyboard extension sees the new row on its next
    /// `viewWillAppear`. Refresh failures are swallowed by
    /// `TranscriptHistoryMirror.write` — a broken mirror never blocks the
    /// successful SwiftData insert.
    ///
    /// ## Lifetime note on the return value
    ///
    /// The returned `Transcript` is bound to a short-lived `ModelContext`
    /// constructed inline. Retaining the `Transcript` keeps the context
    /// alive (the object holds a reference back), so synchronous property
    /// reads on `@MainActor` immediately after the call are safe. Do not
    /// hand the reference across actors or hold it past the enclosing
    /// function — snapshot the fields you need (`.id`, `.text`, etc.) if
    /// you need to cross boundaries.
    ///
    /// - Parameters:
    ///   - raw: the Parakeet transcript before any LLM post-processing.
    ///     If this is empty/whitespace only, the call is a no-op — the user
    ///     didn't actually speak.
    ///   - cleaned: the optional post-cleanup output, or `nil` when cleanup
    ///     was disabled or failed. The UI shows `cleaned ?? raw`.
    ///   - duration: wall-clock recording duration, if known. Pass `nil`
    ///     from file-transcription intents where "duration" is ambiguous.
    ///   - derivedFrom: the ID of the transcript this one was "derived from"
    ///     via a chained voice command. Pass `nil` for fresh dictation;
    ///     pass the prior transcript's `id` for a follow-up (e.g. when the
    ///     user said "make this more casual" against transcript `X`, this
    ///     is `X.id`). The UI renders derived transcripts as indented
    ///     children of their parent in the Ledger log.
    ///   - instruction: the user's voice command that produced the
    ///     follow-up (e.g. "make this more casual"). Only meaningful when
    ///     `derivedFrom != nil`; pass `nil` on fresh dictation.
    /// - Returns: the inserted `Transcript`, or `nil` if the raw input was
    ///   empty/whitespace-only and the call was a no-op.
    @discardableResult
    static func append(
        raw: String,
        cleaned: String? = nil,
        duration: TimeInterval? = nil,
        derivedFrom: UUID? = nil,
        instruction: String? = nil
    ) -> Transcript? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let context = ModelContext(JotModelContainer.shared)
        let transcript = Transcript(
            text: raw,
            cleanedText: cleaned,
            durationSeconds: duration,
            ledgerIndex: nextLedgerIndex(),
            derivedFromID: derivedFrom,
            instruction: instruction
        )
        context.insert(transcript)
        try? context.save()

        // Refresh the keyboard's JSON mirror so the next keyboard
        // presentation sees the new entry without a round-trip through
        // SwiftData. Best-effort — a failure here is silent and does not
        // invalidate the successful insert.
        TranscriptHistoryMirror.refresh(from: context)

        return transcript
    }

    /// Most recent transcript inserted within the last `window` seconds,
    /// or `nil` if the store is empty or the newest row is older than the
    /// window. Used by the chained-follow-up pipeline to decide whether a
    /// fresh utterance should be classified as a command against the prior
    /// transcript or treated as a brand-new dictation.
    ///
    /// See `ChainedFollowUp.freshnessWindow` for the team-lead-set value
    /// of 45 seconds and the rationale.
    ///
    /// Same lifetime caveat as `append`: the returned `Transcript` is bound
    /// to a short-lived context. Retain the reference for the duration of
    /// synchronous `@MainActor` reads, or snapshot fields if you need to
    /// cross actor boundaries.
    ///
    /// - Parameter window: freshness window in seconds. Rows older than
    ///   `now - window` are treated as stale.
    /// - Returns: the newest in-window `Transcript`, or `nil`.
    static func mostRecent(within window: TimeInterval) -> Transcript? {
        let context = ModelContext(JotModelContainer.shared)
        var descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return nil }
        let age = -row.createdAt.timeIntervalSinceNow
        return age <= window ? row : nil
    }

    /// Mark a transcript as superseded — i.e., explicitly replaced by a
    /// later command-result. Sets `supersededAt = Date()` on the row with
    /// the given `id`. No-op if no matching row exists, or if the row is
    /// already marked (we don't refresh the timestamp — first-mark wins).
    ///
    /// Ledger rendering keys off `Transcript.isSuperseded` to dim the row
    /// and show a `SUPERSEDED` chip. The keyboard's mirror currently
    /// doesn't carry this flag (Entry schema stays lean), so supersession
    /// is a main-app-only visual. If keyboard-engineer-2 wants parity, the
    /// mirror's Entry schema can grow a `supersededAt: Date?` later.
    ///
    /// - Parameter id: the transcript to mark. Typically the prior
    ///   transcript in a chained-command result pair.
    static func markSuperseded(id: UUID) {
        let context = ModelContext(JotModelContainer.shared)
        var descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate<Transcript> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let transcript = try? context.fetch(descriptor).first else { return }
        // First-mark wins. Re-marking would re-stamp the timestamp which is
        // never what the caller wants (and would churn the mirror refresh).
        guard transcript.supersededAt == nil else { return }
        transcript.supersededAt = Date()
        try? context.save()
    }
}
