import Combine
import Foundation
import SwiftData
import WatchConnectivity
import os.log

/// iPhone-side `WCSession` delegate. Bridges:
/// - **Incoming audio files** (`session(_:didReceive:)`): copies the
///   file to a staging directory, kicks off `TranscriptionService.transcribe(audioFileURL:)`,
///   saves the resulting `Transcript` with `source = "watch"` +
///   `watchOriginUUID = <uuid from metadata>`, sends an ack back to the
///   watch so it can delete its local copy.
/// - **Top-10 sync to watch** (`transferUserInfo`): pushed proactively
///   whenever the iPhone's transcript library changes (new entry, edit,
///   delete). `transferUserInfo` is FIFO + guaranteed-delivery, so
///   updates aren't lost when the watch is unreachable.
/// - **Helo-fresh handshake** (received `transferUserInfo` of type
///   `helloFresh`): pushes the current top-10 to the watch immediately.
///   Triggered when the watch first launches after iCloud restore.
@MainActor
final class PhoneSideWCSession: NSObject, WCSessionDelegate {
    static let shared = PhoneSideWCSession()

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "watch-connectivity")
    private var session: WCSession?
    /// Phone-side dedup: UUIDs of recently-received audio files.
    /// Bounded to last 100 entries.
    private var recentlyReceivedUUIDs: [String] = []

    /// Diagnostic state (surfaced in Settings → Watch Diagnostics).
    /// Updated whenever significant events occur (activation, file
    /// received, transcription completed/failed). Read by the phone's
    /// DiagnosticsWatchView.
    private(set) var lastActivatedAt: Date?
    private(set) var lastReceivedFileAt: Date?
    private(set) var lastReceivedFileUUID: String?
    private(set) var lastTranscriptionSuccessAt: Date?
    private(set) var lastTranscriptionError: String?

    /// Number of consecutive `resetSync()` invocations the user has
    /// made WITHOUT an intervening successful file receive. Used by
    /// DiagnosticsWatchView to escalate from "tap Reset sync" to
    /// "restart your Apple Watch" after the soft fix demonstrably
    /// hasn't helped.
    private(set) var consecutiveResetAttempts: Int = 0
    private(set) var lastResetAttempt: Date?

    /// User-initiated reset. Re-activates the WCSession + re-pushes
    /// top-10 to the watch. Known workaround for the watchOS
    /// WCSession daemon stalling (see Apple Dev Forums #733155,
    /// #83612, #63744) — re-activate sometimes kicks the daemon out
    /// of a wedged state.
    func resetSync() {
        consecutiveResetAttempts += 1
        lastResetAttempt = Date()
        log.info("resetSync() — attempt #\(self.consecutiveResetAttempts, privacy: .public)")
        guard WCSession.isSupported() else {
            log.error("resetSync() — WCSession.isSupported() == false")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        pushTopTranscripts()
    }
    /// Stage tracker for the receive→transcribe→save pipeline. Updated
    /// before each await/throw point so the diagnostics view shows
    /// EXACTLY where the chain stalls when "transcription OK = never"
    /// and no error is captured. Without this we can't distinguish
    /// "hung in Parakeet inference" from "early-returned at stageFile"
    /// from "never reached transcribe because of an actor deadlock."
    private(set) var lastStage: String?
    private(set) var lastStageAt: Date?

    private func setStage(_ stage: String) {
        lastStage = stage
        lastStageAt = Date()
        log.info("stage: \(stage, privacy: .public)")
    }

    /// Live snapshot of the iPhone-side WCSession state. iPhone WCSession
    /// exposes additional properties unavailable on watch (`isPaired`,
    /// `isWatchAppInstalled`) which directly answer "does iOS see a
    /// paired watch with our app installed."
    struct StateSnapshot {
        let activationState: WCSessionActivationState
        let isReachable: Bool
        let isPaired: Bool
        let isWatchAppInstalled: Bool
        let outstandingFileTransfers: Int
        let outstandingUserInfoTransfers: Int
    }

    func snapshot() -> StateSnapshot {
        guard let session else {
            return StateSnapshot(activationState: .notActivated, isReachable: false, isPaired: false, isWatchAppInstalled: false, outstandingFileTransfers: 0, outstandingUserInfoTransfers: 0)
        }
        return StateSnapshot(
            activationState: session.activationState,
            isReachable: session.isReachable,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled,
            outstandingFileTransfers: session.outstandingFileTransfers.count,
            outstandingUserInfoTransfers: session.outstandingUserInfoTransfers.count
        )
    }
    /// Held strong reference to the cross-process notification observer
    /// so it stays alive for the singleton's lifetime. Auto-deregisters
    /// when this property is set to nil (or on deinit, which never
    /// happens for the shared singleton).
    private var mirrorObserver: CrossProcessNotification.Observer?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            log.info("WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        log.info("PhoneSideWCSession activated")

        // Subscribe to history-mirror-updated Darwin cross-process
        // notification. This fires whenever TranscriptStore.append (or
        // edits/deletes) refreshes the keyboard's JSON mirror —
        // i.e., whenever the library changes. Push fresh top-10 to the
        // watch on every change so the watch's recent list stays in sync.
        mirrorObserver = CrossProcessNotification.addObserver(
            name: CrossProcessNotification.historyMirrorUpdated
        ) { [weak self] in
            self?.pushTopTranscripts()
        }
    }

    /// Push the current top-10 transcripts to the watch. Called whenever
    /// the library changes. Safe to call when the watch is unreachable —
    /// `transferUserInfo` queues for next session activation.
    ///
    /// **Debounce:** scheduled with a 250ms coalescing window so a burst
    /// of saves (e.g., chained follow-up dictations) collapses to one
    /// push instead of N. Without this, every transcript write fired a
    /// full top-10 payload over WCSession — wasted radio + battery.
    func pushTopTranscripts() {
        pendingPushTask?.cancel()
        pendingPushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await actuallyPushTopTranscripts()
        }
    }

    @MainActor
    private func actuallyPushTopTranscripts() async {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else {
            return
        }
        let top = await fetchTop10()
        let payload: [String: Any] = [
            "type": "topTranscripts",
            "schemaVersion": 1,
            "transcripts": top.map { transcript -> [String: Any] in
                // Encode `source` as String OR omit the key entirely —
                // never wrap an Optional<String> in Any, because the
                // watch parser does `dict["source"] as? String` which
                // returns nil for an Any-wrapped Optional.
                var dict: [String: Any] = [
                    "id": transcript.id.uuidString,
                    "preview": String(transcript.displayText.prefix(200)),
                    "fullText": transcript.displayText,
                    "createdAt": Self.iso8601Formatter.string(from: transcript.createdAt)
                ]
                if let source = transcript.source {
                    dict["source"] = source
                }
                return dict
            }
        ]
        session.transferUserInfo(payload)
        log.info("Pushed top-\(top.count, privacy: .public) transcripts to watch")
    }

    /// Pending debounced push. Cancelled + replaced on every
    /// `pushTopTranscripts()` call so bursts coalesce.
    private var pendingPushTask: Task<Void, Never>?

    /// Hoisted formatter — `ISO8601DateFormatter()` allocation is
    /// expensive; reusing one instance saves CPU on bursts of pushes
    /// and acks. `nonisolated(unsafe)` because `ISO8601DateFormatter` is
    /// documented as thread-safe for parsing.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            if activationState == .activated {
                self.lastActivatedAt = Date()
                self.log.info("WCSession activated; pushing initial top-10 to watch if installed")
                self.pushTopTranscripts()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // No-op. iOS-only callback for pairing changes.
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so future pairs work.
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // CRITICAL: per Apple's WCSession docs, the file at `file.fileURL`
        // is deleted the moment this delegate method returns. Previously
        // we spawned a `Task { @MainActor in ... }` and returned, which
        // meant iOS reclaimed the source file BEFORE our async Task ran
        // `copyItem(at:to:)` — so every transfer failed with "no such
        // file." The retry path then hit our in-memory dedup check
        // (UUID was appended pre-transcribe) and silently acked without
        // transcribing, producing the "watch synced but no transcript
        // on phone" mystery.
        //
        // Fix: do the file move synchronously inside the nonisolated
        // delegate, BEFORE returning. The Task then operates on a
        // file path we own.
        let sourceURL = file.fileURL
        let raw = file.metadata ?? [:]
        let uuid = raw["uuid"] as? String
        let capturedAtString = raw["capturedAt"] as? String
        let durationSeconds = raw["durationSeconds"] as? Double

        var stagedURL: URL?
        var stageError: String?
        if let uuid {
            do {
                stagedURL = try Self.stageFileSync(at: sourceURL, uuid: uuid)
            } catch {
                stageError = error.localizedDescription
            }
        }

        let finalStagedURL = stagedURL
        let finalStageError = stageError
        Task { @MainActor in
            self.lastReceivedFileAt = Date()
            self.lastReceivedFileUUID = uuid
            self.log.info("didReceive file uuid=\(uuid ?? "nil", privacy: .public) staged=\(finalStagedURL?.path ?? "nil", privacy: .public) error=\(finalStageError ?? "<none>", privacy: .public)")
            await self.handleIncomingAudio(
                stagedURL: finalStagedURL,
                stageError: finalStageError,
                uuid: uuid,
                capturedAtString: capturedAtString,
                durationSeconds: durationSeconds
            )
        }
    }

    /// Synchronous file move that MUST run before the WCSession delegate
    /// returns. iOS reclaims the source path immediately after; this
    /// method establishes a stable local copy we own. Called from the
    /// nonisolated delegate before any actor hop.
    private nonisolated static func stageFileSync(at url: URL, uuid: String) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("WatchAudioStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dest = stagingDir.appendingPathComponent("\(uuid).m4a")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Same Sendable concern as didReceive(file:) — extract typed
        // values before crossing the actor boundary.
        let type = userInfo["type"] as? String
        Task { @MainActor in
            guard let type else { return }
            switch type {
            case "helloFresh":
                self.log.info("Watch reported fresh install; pushing top-10")
                self.pushTopTranscripts()
            default:
                self.log.debug("Received unknown userInfo type=\(type, privacy: .public)")
            }
        }
    }

    // MARK: - Audio handling

    private func handleIncomingAudio(
        stagedURL: URL?,
        stageError: String?,
        uuid: String?,
        capturedAtString: String?,
        durationSeconds: Double?
    ) async {
        setStage("handleIncomingAudio entry")
        guard let uuid else {
            setStage("aborted: no uuid in metadata")
            lastTranscriptionError = "missing uuid metadata"
            return
        }

        // If synchronous staging failed inside the delegate, surface that
        // — no point continuing, the source file is already gone.
        if let stageError {
            setStage("stageFile threw (sync)")
            lastTranscriptionError = "stageFile: \(stageError)"
            return
        }
        guard let stagedURL else {
            setStage("aborted: no staged URL and no error")
            lastTranscriptionError = "no staged URL"
            return
        }

        // Idempotency check #1: in-memory dedup. Note we DON'T add to
        // `recentlyReceivedUUIDs` here — that only happens after the
        // pipeline actually completes. So a failed transcribe doesn't
        // poison the retry path (which was the previous bug: stageFile
        // failed → next retry hit in-memory dedup → silent ack → watch
        // thought it succeeded).
        if recentlyReceivedUUIDs.contains(uuid) {
            setStage("dedup: in-memory hit, acking")
            sendAck(uuid: uuid)
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        setStage("checking SwiftData dedup")
        if await transcriptExists(watchOriginUUID: uuid) {
            setStage("dedup: SwiftData hit, acking")
            sendAck(uuid: uuid)
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }

        // Parse capturedAt from metadata; fall back to now if missing.
        let capturedAt: Date = {
            if let s = capturedAtString,
               let d = Self.iso8601Formatter.date(from: s) {
                return d
            }
            return Date()
        }()

        setStage("sending transcribing userInfo")
        sendTranscribing(uuid: uuid, capturedAt: capturedAt)

        setStage("calling TranscriptionService.transcribe")
        do {
            let transcript = try await TranscriptionService.shared.transcribe(audioFileURL: stagedURL)
            setStage("transcribe returned chars=\(transcript.count)")
            try await saveTranscript(
                text: transcript,
                createdAt: capturedAt,
                durationSeconds: durationSeconds,
                watchOriginUUID: uuid
            )
            setStage("saveTranscript OK")
            log.info("Transcribed watch audio UUID=\(uuid, privacy: .public) chars=\(transcript.count, privacy: .public)")
            lastTranscriptionSuccessAt = Date()
            lastTranscriptionError = nil
            // A working file-receive + transcription means sync is
            // healthy — clear the escalation counter so the user isn't
            // nagged to restart their watch after the soft fix works.
            consecutiveResetAttempts = 0
            // Only NOW mark as processed — a successful save guarantees
            // SwiftData dedup will catch any future retry too, so the
            // in-memory list is just a fast-path hint.
            recentlyReceivedUUIDs.append(uuid)
            if recentlyReceivedUUIDs.count > 100 {
                recentlyReceivedUUIDs.removeFirst(recentlyReceivedUUIDs.count - 100)
            }
            pushTopTranscripts()
            setStage("pushed top-10")
            sendAck(uuid: uuid)
            setStage("done")
        } catch {
            setStage("transcribe/save threw")
            log.error("Failed to transcribe watch audio UUID=\(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastTranscriptionError = "\(uuid.prefix(8)): \(error.localizedDescription)"
        }

        // Cleanup the staged file.
        try? FileManager.default.removeItem(at: stagedURL)
    }

    private func transcriptExists(watchOriginUUID: String) async -> Bool {
        let context = ModelContext(JotModelContainer.shared)
        let descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.watchOriginUUID == watchOriginUUID }
        )
        let count = (try? context.fetchCount(descriptor)) ?? 0
        return count > 0
    }

    private func saveTranscript(text: String, createdAt: Date, durationSeconds: Double?, watchOriginUUID: String) async throws {
        // Route through the Repository (the sole writer of the Transcript
        // entity + the keyboard mirror) instead of hand-reimplementing
        // append. `append` owns the insert, ledger index, save, mirror
        // refresh, Darwin notification, and the TranscriptIndexer embed/
        // classify hop — so the watch path can no longer drift from the
        // main-app path. The original recording time and the dedup key are
        // forwarded; the `transcriptExists(watchOriginUUID:)` pre-insert
        // check stays at the call site.
        try TranscriptStore.append(
            raw: text,
            duration: durationSeconds,
            source: "watch",
            createdAt: createdAt,
            watchOriginUUID: watchOriginUUID
        )
    }

    private func sendAck(uuid: String) {
        guard let session, session.activationState == .activated else { return }
        let payload: [String: Any] = [
            "type": "ack",
            "uuid": uuid,
            "schemaVersion": 1
        ]
        session.transferUserInfo(payload)
    }

    private func sendTranscribing(uuid: String, capturedAt: Date) {
        guard let session, session.activationState == .activated else { return }
        let payload: [String: Any] = [
            "type": "transcribing",
            "uuid": uuid,
            "capturedAt": Self.iso8601Formatter.string(from: capturedAt),
            "schemaVersion": 1
        ]
        session.transferUserInfo(payload)
    }

    // MARK: - Top-10 fetch

    private func fetchTop10() async -> [Transcript] {
        let context = ModelContext(JotModelContainer.shared)
        var descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.supersededAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        return (try? context.fetch(descriptor)) ?? []
    }
}
