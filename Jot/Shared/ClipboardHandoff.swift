import Foundation
import UIKit

/// Handoff protocol between the main app (which writes a fresh dictation to the
/// system clipboard) and the keyboard extension (which reads that signal and
/// offers a one-tap paste).
///
/// We deliberately stamp a timestamp in the App Group so the keyboard can tell
/// "this clipboard was written by Jot in the last 30s" vs "this is some other
/// unrelated clipboard content". The clipboard itself never carries metadata.
enum ClipboardHandoff {
    /// Freshness window. After this, the keyboard treats the clipboard as
    /// unrelated to Jot even if it still contains the transcript.
    static let freshnessWindow: TimeInterval = 30
    static let copyConfirmationWindow: TimeInterval = 1.3

    /// Atomic handoff payload. Persisted as a single JSON blob under one key so
    /// a keyboard read can never observe a half-updated pair (new timestamp with
    /// stale text). `UserDefaults` is atomic per-key, not across keys.
    /// Carries the FULL transcript so the keyboard can insert without reading
    /// `UIPasteboard.general` (which lags behind cross-process publishes and
    /// caused stale-paste bugs).
    struct FreshDictation: Codable, Sendable {
        let timestamp: Date
        let preview: String
        let text: String
    }

    /// Auto-copy confirmation payload for the main app ledger row.
    struct AutoCopyConfirmation: Codable, Sendable {
        let transcriptID: UUID
        let timestamp: Date
    }

    /// Called by the main app after a successful dictation.
    /// Writes the transcript to the system clipboard and stamps App Group state.
    static func publish(transcript: String, autoCopiedTranscriptID: UUID? = nil) {
        UIPasteboard.general.string = transcript
        let now = Date()
        let payload = FreshDictation(
            timestamp: now,
            preview: String(transcript.prefix(80)),
            text: transcript
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        AppGroup.defaults.set(data, forKey: AppGroup.Keys.lastDictation)

        if let autoCopiedTranscriptID {
            let confirmation = AutoCopyConfirmation(
                transcriptID: autoCopiedTranscriptID,
                timestamp: now
            )
            guard let confirmationData = try? JSONEncoder().encode(confirmation) else { return }
            AppGroup.defaults.set(
                confirmationData,
                forKey: AppGroup.Keys.lastAutoCopiedTranscript
            )
        }
    }

    /// Called by the keyboard extension on appearance.
    /// Returns a preview of the fresh transcript if one is available, else nil.
    static func pendingFreshTranscriptPreview() -> String? {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.lastDictation),
            let payload = try? JSONDecoder().decode(FreshDictation.self, from: data)
        else { return nil }

        let age = Date().timeIntervalSince(payload.timestamp)
        guard age >= 0, age < freshnessWindow else { return nil }

        return payload.preview
    }

    /// Returns the full transcript text from the pasteboard only when the
    /// App Group handoff metadata is fresh and, if supplied, newer than the
    /// caller's start timestamp. The metadata is the freshness gate; the
    /// pasteboard is the only place that carries the full transcript.
    static func pendingFreshTranscriptText(minimumTimestamp: Date? = nil) -> String? {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.lastDictation),
            let payload = try? JSONDecoder().decode(FreshDictation.self, from: data)
        else { return nil }

        let age = Date().timeIntervalSince(payload.timestamp)
        guard age >= 0, age < freshnessWindow else { return nil }

        if let minimumTimestamp, payload.timestamp < minimumTimestamp {
            return nil
        }

        // Read the FULL transcript directly from the App Group payload — never
        // from UIPasteboard.general. UIPasteboard updates can lag across
        // process boundaries, which previously caused the keyboard to insert
        // whatever was on the system clipboard before the new publish.
        guard !payload.text.isEmpty else { return nil }
        return payload.text
    }

    /// Called by the keyboard after inserting the transcript, so it doesn't
    /// re-offer on subsequent keyboard appearances.
    static func markConsumed() {
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.lastDictation)
    }

    static func clearPendingAutoPaste() {
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.pendingAutoPasteFlag)
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.pendingAutoPasteCreatedAt)
    }

    static func pendingAutoCopyConfirmation() -> AutoCopyConfirmation? {
        guard
            let data = AppGroup.defaults.data(forKey: AppGroup.Keys.lastAutoCopiedTranscript),
            let payload = try? JSONDecoder().decode(AutoCopyConfirmation.self, from: data)
        else { return nil }

        let age = Date().timeIntervalSince(payload.timestamp)
        guard age >= 0, age < copyConfirmationWindow else { return nil }

        return payload
    }
}
