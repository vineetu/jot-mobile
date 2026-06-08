import AVFoundation
import Foundation
import os
import WatchKit

private let recorderLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot.watch", category: "WatchRecorder")

/// Wraps `AVAudioRecorder` for the watch app. Captures AAC 16kHz mono
/// audio (matches Parakeet's input rate so no resampling required on the
/// iPhone side), writes to `Documents/Pending/<UUID>.m4a`, returns the
/// file URL on stop.
///
/// **Extended runtime session:** uses `WKExtendedRuntimeSession` with
/// `sessionType = .audioRecording` to keep `AVAudioRecorder` running
/// while the wrist is lowered during long recordings (default watch apps
/// suspend within ~3 minutes — without the extended session, recording
/// silently dies).
///
/// **`@MainActor`-isolated** — all state is read + written from MainActor.
/// WatchKit delegate callbacks arrive on an arbitrary queue; we dispatch
/// them onto MainActor before touching any state to keep Swift 6 strict
/// concurrency happy + avoid real data races.
///
/// **Auto-enqueue-on-expiry:** if the extended runtime session expires
/// mid-recording (rare — should hit the 15-min cap first), the recorder
/// stops + saves + enqueues into `WatchSyncQueue` directly. Without
/// this auto-enqueue path, the saved file would sit in `Pending/` with
/// no queue entry and never sync.
@MainActor
@Observable
final class WatchRecorder: NSObject, AVAudioRecorderDelegate, WKExtendedRuntimeSessionDelegate {
    static let shared = WatchRecorder()

    private(set) var isRecording: Bool = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var currentFileURL: URL?
    @ObservationIgnored private var capturedAt: Date?
    @ObservationIgnored private var runtimeSession: WKExtendedRuntimeSession?

    // Diagnostic state (surfaced in watch DiagnosticsView).
    /// Last time the extended runtime session was invalidated by the
    /// system. Populated by `extendedRuntimeSession(_:didInvalidateWith:_)`.
    private(set) var lastInvalidationAt: Date?
    /// Raw invalidation reason value. `0=none, 1=sessionInProgress, 2=expired, 3=resignedFrontmost, 4=suppressedBySystem, 5=error`.
    private(set) var lastInvalidationReason: Int?
    /// Description string from the invalidation error if any.
    private(set) var lastInvalidationError: String?
    /// Time `AVAudioRecorderDelegate.audioRecorderDidFinishRecording` fired
    /// and whether it was a successful finish. If iOS forcibly stops the
    /// recorder mid-take, `flag = false` and the file may be truncated.
    private(set) var lastRecorderFinishAt: Date?
    private(set) var lastRecorderFinishSuccess: Bool?
    /// Stats from the most recent stop. Reveals "UI said 10s but file is
    /// 1s" mismatches at a glance.
    private(set) var lastStopReportedDuration: Double?
    private(set) var lastStopFileBytes: Int?

    /// Settings dictionary for AAC 16kHz mono @ ~32 kbps.
    private static let recorderSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    /// Begin a recording. Throws if the audio session cannot be activated,
    /// the file URL cannot be created, or `AVAudioRecorder` cannot start.
    func start() throws {
        guard !isRecording else { return }
        recorderLog.info("start() begin")

        // 1. Activate the audio session for recording. `.allowBluetoothHFP`
        // is the watchOS 26 replacement for the deprecated `.allowBluetooth`
        // option.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        // 2. Build the pending-file URL.
        let uuid = UUID().uuidString
        let url = try WatchRecorder.pendingFileURL(for: uuid)
        recorderLog.info("start() — uuid=\(uuid, privacy: .public) path=\(url.path, privacy: .public)")

        // 3. Construct the recorder.
        let recorder = try AVAudioRecorder(url: url, settings: WatchRecorder.recorderSettings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            throw RecorderError.prepareFailed
        }
        guard recorder.record() else {
            throw RecorderError.startFailed
        }

        // 4. Start the extended runtime session — without this the
        //    recorder dies when the wrist lowers.
        let runtimeSession = WKExtendedRuntimeSession()
        runtimeSession.delegate = self
        runtimeSession.start()

        // 5. Commit state.
        self.recorder = recorder
        self.currentFileURL = url
        self.capturedAt = Date()
        self.runtimeSession = runtimeSession
        self.isRecording = true
    }

    /// Stop recording, finalize the file, and return its URL + capture
    /// timestamp. Caller is responsible for enqueueing for transfer.
    func stopAndSave() async throws -> RecordedFile {
        // Snapshot state — these may be nil if the system invalidated the
        // extended runtime session mid-take, or if the @State view was
        // recreated. In those cases we fall through to disk recovery
        // below: the AAC file may STILL be on disk waiting to be enqueued.
        let snapRecorder = recorder
        let snapURL = currentFileURL
        let snapCapturedAt = capturedAt
        recorderLog.info("stopAndSave() begin — hasRecorder=\(snapRecorder != nil, privacy: .public) hasURL=\(snapURL != nil, privacy: .public)")

        // Capture duration BEFORE `.stop()` — per Apple's
        // AVAudioRecorder docs, `currentTime` returns 0 when the recorder
        // is not recording, so reading it after stop loses the value.
        // Bug noticed in build 48: every watch-originated transcript
        // landed on the phone with `durationSeconds = 0` (the recovery
        // path's documented limitation, but the primary path had the
        // same symptom for an unrelated reason — read-after-stop here).
        let duration = snapRecorder?.currentTime ?? 0

        snapRecorder?.stop()
        // Give AVAudioRecorder a moment to flush + finalize the file.
        try? await Task.sleep(nanoseconds: 100_000_000)

        runtimeSession?.invalidate()
        runtimeSession = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recorder = nil
        self.currentFileURL = nil
        self.capturedAt = nil
        self.isRecording = false

        // Happy path: we have the URL from state.
        if let url = snapURL, let capturedAt = snapCapturedAt {
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            recorderLog.info("stopAndSave() — primary path — exists=\(fileExists, privacy: .public) bytes=\(bytes, privacy: .public) duration=\(duration, privacy: .public)")
            self.lastStopReportedDuration = duration
            self.lastStopFileBytes = bytes
            if fileExists && bytes > 0 {
                return RecordedFile(
                    uuid: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    capturedAt: capturedAt,
                    durationSeconds: duration
                )
            }
            recorderLog.error("stopAndSave() — primary file missing/empty, attempting disk recovery")
        } else {
            recorderLog.error("stopAndSave() — recorder state was nil (likely invalidation race); attempting disk recovery")
        }

        // Recovery path: state was wiped (extended runtime session
        // invalidated mid-take, or SwiftUI rebuilt the @State recorder).
        // Scan Pending/ for an .m4a authored in the last 5 minutes that
        // hasn't yet been enqueued. If we find one, return it so the
        // user's audio isn't lost. This is the difference between "your
        // recording is gone" and "your recording synced silently after
        // a glitch."
        if let recovered = Self.recoverMostRecentPendingFile(maxAgeSeconds: 5 * 60) {
            recorderLog.info("stopAndSave() — disk recovery succeeded uuid=\(recovered.uuid, privacy: .public) bytes=\(((try? FileManager.default.attributesOfItem(atPath: recovered.url.path))?[.size] as? NSNumber)?.intValue ?? -1, privacy: .public)")
            return recovered
        }

        recorderLog.error("stopAndSave() — no recoverable file on disk, giving up")
        throw RecorderError.saveFailed
    }

    /// Scan `Pending/` for the most recent `.m4a` whose UUID is not already
    /// in `WatchSyncQueue`. Used by `stopAndSave` when in-memory state was
    /// lost mid-recording but the file may still be on disk. Returns nil
    /// if no candidate exists (file truly never landed, or all recent
    /// files are already queued).
    @MainActor
    private static func recoverMostRecentPendingFile(maxAgeSeconds: TimeInterval) -> RecordedFile? {
        let pendingDir = pendingDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let queuedUUIDs = Set(WatchSyncQueue.shared.pendingFiles.map(\.uuid))
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)

        let candidate = entries
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> (URL, Date, Int)? in
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mtime = vals?.contentModificationDate, mtime >= cutoff else { return nil }
                let size = vals?.fileSize ?? 0
                guard size > 0 else { return nil }
                let uuid = url.deletingPathExtension().lastPathComponent
                guard !queuedUUIDs.contains(uuid) else { return nil }
                return (url, mtime, size)
            }
            .max(by: { $0.1 < $1.1 })

        guard let (url, mtime, _) = candidate else { return nil }
        return RecordedFile(
            uuid: url.deletingPathExtension().lastPathComponent,
            url: url,
            capturedAt: mtime,
            durationSeconds: 0  // Unknown — we lost the live duration.
        )
    }

    /// Discard the in-flight recording without saving. Used when the
    /// view is dismissed unexpectedly (system interruption, etc.).
    func cancelIfActive() {
        guard isRecording else { return }
        recorder?.stop()
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        runtimeSession?.invalidate()
        runtimeSession = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recorder = nil
        currentFileURL = nil
        capturedAt = nil
        isRecording = false
    }

    /// Returns the average power level normalized to 0.0...1.0 for
    /// the amplitude waveform. AVAudioRecorder reports power in dB
    /// (typically -160...0); we map to a linear 0...1 scale.
    func normalizedAveragePower() -> Float {
        guard let recorder, isRecording else { return 0.0 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        // -50 dB to 0 dB → 0.0 to 1.0. Below -50 is treated as silent.
        let clamped = max(db, -50.0)
        return (clamped + 50.0) / 50.0
    }

    // MARK: - File location helpers

    /// `Documents/Pending/<uuid>.m4a` — survives app suspension, gets
    /// drained by `WatchSyncQueue` + `WatchConnectivityClient.transferQueuedFiles()`.
    /// Pure file-system helper — safe to call from any isolation context.
    nonisolated static func pendingFileURL(for uuid: String) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let pending = docs.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        return pending.appendingPathComponent("\(uuid).m4a")
    }

    nonisolated static var pendingDirectory: URL {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Pending", isDirectory: true)
    }

    // MARK: - WKExtendedRuntimeSessionDelegate
    //
    // WatchKit invokes delegate callbacks on an arbitrary queue.
    // `WatchRecorder` is `@MainActor`-isolated, so every callback must
    // hop back to MainActor before touching state. The `nonisolated`
    // attribute lets the delegate methods satisfy the protocol's
    // non-isolated requirement without bringing actor isolation to the
    // call site.

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // No-op — recorder is already started before session.start() returns.
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Session is about to expire (rare — we should hit 15-min cap
        // first). Stop the recording and IMMEDIATELY enqueue the saved
        // file into WatchSyncQueue so it doesn't orphan in Pending/.
        // (The view's stopAndSave path would also enqueue, but the
        // view may not be visible when the session expires.)
        Task { @MainActor in
            guard isRecording else { return }
            do {
                let file = try await stopAndSave()
                WatchSyncQueue.shared.enqueue(file)
                WatchConnectivityClient.shared.transferQueuedFiles()
            } catch {
                // Best-effort. Cancel to clean up the runtime session.
                cancelIfActive()
            }
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        let reasonRaw = reason.rawValue
        let errDesc = error?.localizedDescription ?? "<none>"
        recorderLog.error("extendedRuntimeSession didInvalidateWith reason=\(reasonRaw, privacy: .public) error=\(errDesc, privacy: .public)")
        Task { @MainActor in
            self.lastInvalidationAt = Date()
            self.lastInvalidationReason = reasonRaw
            self.lastInvalidationError = error?.localizedDescription
            // DO NOT stop the recorder here. Previously this called
            // `recorder?.stop()` which finalized the m4a at ~1s when the
            // session was invalidated early, leaving us with a truncated
            // file. Instead, just clear the runtimeSession reference.
            // The AVAudioRecorder may continue recording even without an
            // active extended runtime session — let the user's Stop tap
            // be the source of truth for "I'm done."
            self.runtimeSession = nil
        }
    }

    /// AVAudioRecorderDelegate — fires when iOS itself stops the
    /// recorder. `flag = false` means the recording was interrupted
    /// (audio session ended, hardware unavailable, etc.). Captured into
    /// diagnostic state so we can see if iOS killed our recorder before
    /// the user tapped Stop.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        recorderLog.error("audioRecorderDidFinishRecording flag=\(flag, privacy: .public)")
        Task { @MainActor in
            self.lastRecorderFinishAt = Date()
            self.lastRecorderFinishSuccess = flag
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        recorderLog.error("audioRecorderEncodeErrorDidOccur \(error?.localizedDescription ?? "<none>", privacy: .public)")
    }
}

struct RecordedFile {
    let uuid: String
    let url: URL
    let capturedAt: Date
    let durationSeconds: TimeInterval
}

enum RecorderError: LocalizedError {
    case notRecording
    case prepareFailed
    case startFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notRecording: return "No recording in progress."
        case .prepareFailed: return "Failed to prepare audio recorder."
        case .startFailed: return "Failed to start audio recorder."
        case .saveFailed: return "Recording stopped but no audio was saved."
        }
    }
}
