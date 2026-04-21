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

    /// Atomic handoff payload. Persisted as a single JSON blob under one key so
    /// a keyboard read can never observe a half-updated pair (new timestamp with
    /// stale preview). `UserDefaults` is atomic per-key, not across keys.
    struct FreshDictation: Codable, Sendable {
        let timestamp: Date
        let preview: String
    }

    /// Called by the main app after a successful dictation.
    /// Writes the transcript to the system clipboard and stamps App Group state.
    static func publish(transcript: String) {
        UIPasteboard.general.string = transcript
        let payload = FreshDictation(
            timestamp: Date(),
            preview: String(transcript.prefix(80))
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        AppGroup.defaults.set(data, forKey: AppGroup.Keys.lastDictation)
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

    /// Called by the keyboard after inserting the transcript, so it doesn't
    /// re-offer on subsequent keyboard appearances.
    static func markConsumed() {
        AppGroup.defaults.removeObject(forKey: AppGroup.Keys.lastDictation)
    }
}
