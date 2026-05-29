import Combine
import Foundation
import os
import WatchConnectivity

private let wcLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "WatchConnectivityClient")

/// Watch-side `WCSession` plumbing. Bridges:
/// - **Outgoing audio files** (`transferFile`) — drained from
///   `WatchSyncQueue` whenever the phone is reachable. Persists across
///   app suspension; iOS guarantees delivery.
/// - **Incoming top-10 transcripts** (`transferUserInfo` of type
///   `topTranscripts`) — replaces `WatchTranscriptStore`.
/// - **Incoming acks** (`transferUserInfo` of type `ack`) — removes
///   the matching UUID from `WatchSyncQueue` and emits a `Just synced`
///   ribbon event via `ackPublisher` for `RootView` to display.
/// - **Incoming transcribing state** (`transferUserInfo` of type
///   `transcribing`) — adds a placeholder row to the recent list.
final class WatchConnectivityClient: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityClient()

    /// Emits the count of acks received in a coalescing window (used
    /// by `RootView` for the "✓ N synced" ribbon).
    let ackPublisher = PassthroughSubject<Int, Never>()

    /// Last error string from a `didFinish fileTransfer` callback.
    /// Cleared on a successful finish. Surfaced in DiagnosticsView so
    /// the user can see what iOS reported when a transfer fails (the
    /// root cause of "1 pending sync that never clears").
    private(set) var lastTransferError: String?
    /// Timestamp of the last `transferQueuedFiles` invocation.
    private(set) var lastTransferAttempt: Date?
    /// Timestamp of the last successful `didFinish` (error == nil).
    private(set) var lastTransferSuccess: Date?
    /// Number of consecutive `resetSync()` invocations the user has
    /// made WITHOUT an intervening successful transfer. Used by
    /// DiagnosticsView to escalate from "tap Reset sync" to "restart
    /// your Apple Watch" guidance after the soft fix demonstrably
    /// hasn't helped — the known watchOS WCSession daemon bug
    /// (Apple Dev Forums #733155, #83612, #63744) requires a watch
    /// reboot to clear the stuck queue in some cases.
    private(set) var consecutiveResetAttempts: Int = 0
    /// Timestamp of the last `resetSync()` invocation. nil = never.
    private(set) var lastResetAttempt: Date?

    /// Snapshot of the live WCSession state for the diagnostics view.
    /// Reads off the default session directly; safe to call from any
    /// context (WCSession's state properties are documented as
    /// thread-safe for reads).
    struct StateSnapshot {
        let activationState: WCSessionActivationState
        let isReachable: Bool
        let isCompanionAppInstalled: Bool
        let outstandingFileTransfers: Int
        let outstandingUserInfoTransfers: Int
    }

    func snapshot() -> StateSnapshot {
        guard let session else {
            return StateSnapshot(activationState: .notActivated, isReachable: false, isCompanionAppInstalled: false, outstandingFileTransfers: 0, outstandingUserInfoTransfers: 0)
        }
        return StateSnapshot(
            activationState: session.activationState,
            isReachable: session.isReachable,
            isCompanionAppInstalled: session.isCompanionAppInstalled,
            outstandingFileTransfers: session.outstandingFileTransfers.count,
            outstandingUserInfoTransfers: session.outstandingUserInfoTransfers.count
        )
    }

    private var session: WCSession?
    /// Watch-side ack idempotency: UUIDs we've already processed.
    /// Prevents duplicate-ack replay from removing a queue entry twice.
    /// Stored as an ordered array + companion set so we can bound the
    /// memory + drop the OLDEST entry deterministically (a `Set.dropFirst`
    /// drops in arbitrary hash order — could drop the entry we just
    /// inserted and defeat dedup under hash collision).
    private var seenAcksOrder: [String] = []
    private var seenAcks: Set<String> = []
    /// Serializes access to `seenAcks` from arbitrary WCSession delivery
    /// queues. Without this two concurrent acks race the Set.
    private let ackLock = NSLock()
    /// Hoisted formatter — `ISO8601DateFormatter()` allocation is
    /// expensive per call; reuse one instance for all parses.
    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is thread-safe
    /// for parsing (documented by Apple), so the compiler's Sendable
    /// concern is overcautious here.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            wcLog.error("activate() — WCSession.isSupported() == false; not activating")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        wcLog.info("activate() — WCSession activate called")
    }

    /// Drain the local pending queue: for each `.m4a` file on disk,
    /// fire `WCSession.transferFile(url:metadata:)` with the metadata
    /// the phone needs to look up + de-dup.
    @MainActor
    func transferQueuedFiles() {
        guard let session else {
            wcLog.error("transferQueuedFiles() — no session (activate not called)")
            return
        }
        guard session.activationState == .activated else {
            wcLog.error("transferQueuedFiles() — session.activationState=\(session.activationState.rawValue, privacy: .public) (not activated)")
            return
        }
        lastTransferAttempt = Date()
        wcLog.info("transferQueuedFiles() — isReachable=\(session.isReachable, privacy: .public) isCompanionAppInstalled=\(session.isCompanionAppInstalled, privacy: .public) outstanding=\(session.outstandingFileTransfers.count, privacy: .public)")
        let pending = WatchSyncQueue.shared.filesPendingTransfer()
        wcLog.info("transferQueuedFiles() — pending=\(pending.count, privacy: .public)")
        // Avoid re-queueing files that are already in-flight. WCSession
        // exposes `outstandingFileTransfers` for exactly this.
        let inFlightURLs = Set(session.outstandingFileTransfers.map { $0.file.fileURL })
        for (file, url) in pending {
            guard !inFlightURLs.contains(url) else {
                wcLog.info("transferQueuedFiles() — skip uuid=\(file.uuid, privacy: .public) already in-flight")
                continue
            }
            let metadata: [String: Any] = [
                "uuid": file.uuid,
                "capturedAt": Self.iso8601Formatter.string(from: file.capturedAt),
                "durationSeconds": file.durationSeconds,
                "schemaVersion": 1
            ]
            session.transferFile(url, metadata: metadata)
            wcLog.info("transferQueuedFiles() — transferFile fired uuid=\(file.uuid, privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let uuid = fileTransfer.file.metadata?["uuid"] as? String ?? "unknown"
        if let error {
            wcLog.error("didFinish fileTransfer uuid=\(uuid, privacy: .public) ERROR=\(error.localizedDescription, privacy: .public)")
            let msg = "\(uuid): \(error.localizedDescription)"
            DispatchQueue.main.async { self.lastTransferError = msg }
        } else {
            wcLog.info("didFinish fileTransfer uuid=\(uuid, privacy: .public) OK")
            DispatchQueue.main.async {
                self.lastTransferError = nil
                self.lastTransferSuccess = Date()
                // Any successful transfer resets the escalation counter:
                // a working delivery means we don't need to nag the user
                // to restart their watch.
                self.consecutiveResetAttempts = 0
            }
        }
    }

    /// User-initiated reset. Re-activates the WCSession (a known
    /// workaround for the watchOS WCSession daemon stalling at
    /// `isReachable=NO` / `transferFile` not delivering even though
    /// `didReceive(file:)` is never invoked on the phone side), then
    /// re-fires any queued file transfers. Surfaced via the "Reset
    /// sync" button in `DiagnosticsView`. Tracks `consecutiveResetAttempts`
    /// so the UI can escalate to "restart your Apple Watch" guidance
    /// after two unsuccessful retries.
    @MainActor
    func resetSync() {
        consecutiveResetAttempts += 1
        lastResetAttempt = Date()
        wcLog.info("resetSync() invoked — attempt #\(self.consecutiveResetAttempts, privacy: .public)")
        guard WCSession.isSupported() else {
            wcLog.error("resetSync() — WCSession.isSupported() == false")
            return
        }
        // Re-call activate(). Documented as safe on an already-active
        // session; some users report it kicks the daemon to renegotiate
        // a stalled link.
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        // Re-fire queued transfers immediately. If the daemon was just
        // confused about pending state, this drains it.
        transferQueuedFiles()
    }

    /// On a fresh install (no `lastSyncedAt`), nudge the phone to send
    /// us the current top-10. Phone responds whenever WCSession is
    /// active (FIFO + queued via `transferUserInfo`).
    func requestInitialState() {
        guard let session else { return }
        let payload: [String: Any] = [
            "type": "helloFresh",
            "watchInstallTime": Self.iso8601Formatter.string(from: Date()),
            "schemaVersion": 1
        ]
        session.transferUserInfo(payload)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if activationState == .activated {
            // On every activation, attempt to drain the queue (in case
            // we have files that didn't sync during the previous run).
            DispatchQueue.main.async {
                self.transferQueuedFiles()
                // If this is a fresh install (no top-10 cached yet),
                // ask the phone for the current state.
                if WatchTranscriptStore.shared.lastSyncedAt == nil {
                    self.requestInitialState()
                }
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let type = userInfo["type"] as? String else { return }
        switch type {
        case "topTranscripts":
            handleTopTranscripts(userInfo)
        case "ack":
            handleAck(userInfo)
        case "transcribing":
            handleTranscribing(userInfo)
        default:
            // Unknown message type — log and ignore. Version mismatch
            // handling lives in future schemaVersion bumps.
            break
        }
    }

    // MARK: - Message handlers

    private func handleTopTranscripts(_ userInfo: [String: Any]) {
        guard let raw = userInfo["transcripts"] as? [[String: Any]] else { return }
        let parsed: [WatchTranscript] = raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let preview = dict["preview"] as? String,
                  let fullText = dict["fullText"] as? String,
                  let createdAtString = dict["createdAt"] as? String,
                  let createdAt = Self.iso8601Formatter.date(from: createdAtString)
            else { return nil }
            return WatchTranscript(
                id: id,
                preview: preview,
                fullText: fullText,
                createdAt: createdAt,
                source: dict["source"] as? String
            )
        }
        DispatchQueue.main.async {
            WatchTranscriptStore.shared.replaceAll(with: parsed)
            // Any pending-transcribing entries whose UUID is now in the
            // top-10 get cleared.
            for transcript in parsed {
                WatchPendingTranscribingStore.shared.remove(uuid: transcript.id)
            }
        }
    }

    private func handleAck(_ userInfo: [String: Any]) {
        guard let uuid = userInfo["uuid"] as? String else { return }
        // Idempotency check under lock — multiple acks can arrive
        // concurrently on different WCSession delivery threads, and a
        // racy Set check + insert would defeat dedup. Bounded to 100
        // entries; oldest dropped first (ordered list, not Set).
        ackLock.lock()
        if seenAcks.contains(uuid) {
            ackLock.unlock()
            return
        }
        seenAcks.insert(uuid)
        seenAcksOrder.append(uuid)
        while seenAcksOrder.count > 100 {
            let oldest = seenAcksOrder.removeFirst()
            seenAcks.remove(oldest)
        }
        ackLock.unlock()

        DispatchQueue.main.async {
            WatchSyncQueue.shared.ack(uuid: uuid)
            // Also clear the "transcribing..." placeholder for this UUID.
            // Without this, the placeholder accumulates forever — the
            // top-10 push from phone uses `transcript.id` (the SwiftData
            // UUID) for cleanup, but the placeholder is keyed by the
            // AUDIO FILE UUID. The two never match. The ack DOES carry
            // the audio file UUID, so it's the right cleanup signal.
            WatchPendingTranscribingStore.shared.remove(uuid: uuid)
            self.ackPublisher.send(1)
        }
    }

    private func handleTranscribing(_ userInfo: [String: Any]) {
        guard let uuid = userInfo["uuid"] as? String,
              let capturedAtString = userInfo["capturedAt"] as? String,
              let capturedAt = Self.iso8601Formatter.date(from: capturedAtString)
        else { return }
        DispatchQueue.main.async {
            WatchPendingTranscribingStore.shared.add(uuid: uuid, capturedAt: capturedAt)
        }
    }
}
