import Foundation

/// Cross-process diagnostic event log.
///
/// Records a small ring buffer of structured events from both the main app
/// and the keyboard extension into the shared App Group so a user
/// reproducing a bug (typically the keyboard-stop-no-paste regression) can
/// open Help → Diagnostics and copy the recent event stream back to support.
///
/// **Why the App Group, not main-app-local storage?** The most interesting
/// failure sites live inside the keyboard extension (the silent-skip
/// branches in `flushPendingAutoPasteIfPossible`). Those branches need to
/// be visible to the main app's Help UI without any IPC. Putting the log
/// in the shared container means keyboard writes show up automatically
/// the next time Help renders.
///
/// **No SwiftUI dependency.** This file lives in `Shared/` and ships in
/// both the main app and the keyboard target. Keep it Foundation-only —
/// the keyboard extension's 60 MB envelope can't afford to pull SwiftUI
/// into a helper that just reads/writes UserDefaults.
///
/// Mirrors the storage style of `DictationStats.swift`: a private key, an
/// enum of static helpers, and direct `AppGroup.defaults` reads/writes.
/// `UserDefaults` is documented thread-safe so the keyboard's off-MainActor
/// callers don't need to hop. The buffer is bounded at `maxEntries` to
/// keep the encoded JSON blob small (a runaway log would silently bloat
/// the App Group container indefinitely otherwise).
enum DiagnosticsCategory: String, Codable {
    /// Keyboard inserted text into the host app's text field.
    case pasteSuccess
    /// Flush ran but no fresh transcript payload was available.
    case pasteSkipNoPayload
    /// Payload's `sessionID` did not match the keyboard's pending session.
    case pasteSkipSessionMismatch
    /// Host `documentIdentifier` changed since the user tapped Stop.
    case pasteSkipDocumentMismatch
    /// Host `keyboardType` changed since the user tapped Stop.
    case pasteSkipKeyboardTypeMismatch
    /// Keyboard ran without Full Access; can't paste.
    case pasteSkipNoFullAccess
    /// Payload text was empty after trimming.
    case pasteSkipEmptyText
    /// Proxy was disconnected at paste time (`documentContextBeforeInput == nil`).
    /// Insert would no-op silently; we skip the call and fall back to writing
    /// the transcript to the system clipboard with a status banner so the user
    /// knows where to find it. See features.md §14.3.
    case pasteSkipProxyDisconnected
    /// Unclassified silent-skip branch.
    case pasteSkipOther
    /// Keyboard wrote a new pending paste session at recording start.
    case sessionStarted
    /// Keyboard wrote a new pending paste session at recording stop.
    case sessionStopRequested
    /// Main app resolved a session ID before publishing the transcript.
    case publishResolved
    /// Main app finished publishing the transcript handoff.
    case publishCompleted
    /// Streaming engine emitted a partial-transcript update from the
    /// FluidAudio manager. Diagnostic visibility into whether live
    /// partials are firing during a recording.
    case streamingPartialReceived
    /// One of the transcription services received a `didReceiveMemoryWarning`
    /// notification and ran its eviction hook. Surfacing this in the
    /// in-app diagnostics card lets a user attribute a stop-then-crash
    /// trail back to memory pressure.
    case memoryWarning
    /// Foreground "Classify now" run started — pre-evict + first item
    /// kicked off. Metadata carries the planned item count.
    case classifyStart
    /// Foreground classification run ended (cancelled OR completed).
    /// Metadata carries processed count + reason (completed / cancelled
    /// / memoryWarning).
    case classifyEnd
    /// Foreground classifier received a memory warning mid-run and is
    /// aborting + evicting Qwen. Distinct from the transcription-service
    /// `memoryWarning` so the user can see WHICH subsystem responded.
    case classifyMemoryWarning
    /// Keyboard tapped a recording control (Stop/Pause/Cancel/Resume) but the
    /// main app never refreshed the pipeline projection within the liveness
    /// ceiling — i.e. the app was jetsammed mid-recording. The keyboard
    /// recovered itself out of the zombie "recording" UI back to idle.
    case appUnresponsiveRecovery
    /// Vocabulary gate (v1a) decision trace: a rescore ran (proposal count),
    /// and per-term APPLY/BLOCK with the confidence + margin it fired at.
    /// Surfaced in the in-app card so a term that doesn't get corrected can be
    /// attributed to "the spotter never found it" (no record) vs "the gate
    /// blocked it" (BLOCK record + numbers to tune).
    case vocabularyGate
}

struct DiagnosticsEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    /// `"main-app"` or `"keyboard"`. Free-form string rather than an enum
    /// so future surfaces (Live Activity widget, Shortcuts extension) can
    /// emit without expanding the enum.
    let source: String
    let category: DiagnosticsCategory
    /// Single short human-readable line. Keep it under ~80 chars so the
    /// diagnostics row in Help renders cleanly without wrapping.
    let message: String
    /// Optional key/value pairs for IDs, document handles, character
    /// counts, etc. Nil when there's nothing structured to add.
    let metadata: [String: String]?
}

enum DiagnosticsLog {
    private static let key = "jot.diagnostics.entries"

    /// Ring buffer ceiling. 100 entries is enough to cover several
    /// reproduction cycles of the paste-regression workflow (start →
    /// stop → publish → flush per dictation) without bloating the
    /// App Group blob.
    static let maxEntries = 100

    /// Records one entry into the App Group log. Fire-and-forget: no
    /// throw, no return value, safe from any thread. Trims the buffer
    /// to `maxEntries` by dropping the oldest entries first.
    static func record(
        source: String,
        category: DiagnosticsCategory,
        message: String,
        metadata: [String: String]? = nil
    ) {
        let entry = DiagnosticsEntry(
            id: UUID(),
            timestamp: Date(),
            source: source,
            category: category,
            message: message,
            metadata: metadata
        )
        let defaults = AppGroup.defaults
        var entries = readAll(from: defaults)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    /// Returns the entries in chronological order (oldest first). Callers
    /// that want newest-first (e.g. the Help UI) should `.reversed()`.
    static func readAll() -> [DiagnosticsEntry] {
        readAll(from: AppGroup.defaults)
    }

    /// Drops the entire buffer. Used by the Help → Diagnostics "Clear"
    /// button after the user confirms.
    static func clear() {
        AppGroup.defaults.removeObject(forKey: key)
    }

    private static func readAll(from defaults: UserDefaults) -> [DiagnosticsEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DiagnosticsEntry].self, from: data)) ?? []
    }
}
