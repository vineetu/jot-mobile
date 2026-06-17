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
    /// Deferred (~350ms) re-read of the host proxy after an insert that the
    /// IMMEDIATE read-back reported as landed. Log-only diagnostic that records
    /// whether the inserted suffix survived once the host's live document model
    /// settled (`settledLen` / `stillEndsWith` / `hasText`) vs the immediate
    /// post-insert length (`immediateLen`). Distinguishes a real landing from a
    /// proxy-cache false positive / host re-render revert (web/custom fields like
    /// Claude Code, Slack). See docs/plans/bug-keyboard-paste-fails-claude-code.md §5.
    case pasteVerifyDeferred
    /// The IMMEDIATE post-insert read-back said the text landed, but the SETTLED
    /// (~350ms) re-read shows it did NOT survive (suffix gone OR `hasText==false`).
    /// The proxy cache reflected the insert locally while the host's live document
    /// never committed it (stale/detached connection) or re-rendered it away. We
    /// reclassify away from `pasteSuccess`, CONSUME the payload (so a re-present
    /// can't re-insert it — no silent double-paste), and fall back to the
    /// clipboard with a visible banner as the no-loss floor. See §6 Option 1/3 of
    /// the same plan.
    case pasteRevertedAfterLanding
    /// Bounded reconnect-poll re-sync diagnostic (cure §4-A). Before inserting,
    /// the keyboard re-syncs the proxy (`adjustTextPosition(0)`) then polls
    /// `documentContextBeforeInput`/`hasText` every ~30ms up to a ~400ms ceiling
    /// until two consecutive reads are STABLE (host finished rehydrating its
    /// remote input session), only THEN inserting once. Records the poll
    /// `iterations` and `settleMs` so we can see whether a fast/native host
    /// settled on poll #1 (no added latency) or a heavy re-mounted web field
    /// (Claude Code WKWebView) needed the full window. Log-only; the insert
    /// outcome is logged separately. See docs/plans/reliable-web-field-paste.md §4-A.
    case pasteReconnectPoll
    /// The host's `textDidChange` input-delegate callback fired within the
    /// in-flight-paste window AND the inserted text is present in the proxy
    /// context — an authoritative "the host committed" signal that the proxy
    /// cache cannot fake on its own (cure §4-B). We short-circuit the deferred
    /// ~350ms settled-verify and classify success immediately. Its ABSENCE
    /// proves nothing (many hosts never fire it for proxy-originated inserts),
    /// so the deferred floor still runs as the fallback when it doesn't fire.
    /// See docs/plans/reliable-web-field-paste.md §3-#1 / §4-B.
    case pasteLandedViaTextDidChange
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
    /// DIAGNOSTIC (blank live-preview pane): `StreamingWordReveal` was
    /// constructed. Each instance carries a short incrementing id so multiple
    /// /ghost controller-or-view instances during a single dictation become
    /// visible (hypothesis C). Low volume — once per view mount.
    case streamRevealInit
    /// DIAGNOSTIC (blank live-preview pane): one record at the end of each
    /// `StreamingWordReveal.sync(...)` call recording which path it took and
    /// the resulting settled/arriving split + progress, so we can see whether
    /// the reveal controller is producing a non-empty split for non-empty text
    /// (refuting/confirming a stuck reveal). Bounded per dictation.
    case streamRevealSync
    /// DIAGNOSTIC (blank live-preview pane): one record per word the reveal
    /// loop advances. Bounded per dictation (word count). Lets us see the
    /// settled/arriving split actually progressing vs frozen near 0.
    case streamRevealAdvance
    /// DIAGNOSTIC (blank live-preview pane): the `run(...)` safety-net branch
    /// fired — the reveal had non-empty target text but an empty settled +
    /// arriving split, so the view fell back to drawing the full text. High
    /// signal for a stranded/stalled reveal (hypothesis A).
    case streamRenderSafetyNet
    /// DIAGNOSTIC (blank live-preview pane): `SettleRenderer.draw` was handed a
    /// layout with ZERO lines (a degenerate/empty cached `Text.Layout`,
    /// hypothesis B). Gated to log at most once per empty/non-empty transition
    /// so it doesn't spam the per-frame draw path.
    case streamRenderEmptyLayout
    /// DIAGNOSTIC (blank live-preview pane): a `TranscribingText` view actually
    /// MOUNTED (`onAppear`) or UNMOUNTED (`onDisappear`). The decisive signal for
    /// hypothesis C — tells us WHICH `instanceID` is the one on screen vs the
    /// throwaway/orphan instances that get constructed but never appear. Pair
    /// with `streamRevealSync` (which instance got the data) to see whether the
    /// VISIBLE instance is the one that was fed the text.
    case streamViewLifecycle
    /// DIAGNOSTIC (blank live-preview pane): `SettleRenderer.draw` painted —
    /// records WHICH `instanceID` owns the visible pixels and how many lines/runs
    /// it actually drew. Gated per (instance, line/run count) transition so the
    /// per-frame path stays quiet. If the mounted instance draws 0 runs while a
    /// sibling holds the text, that's the orphan-on-screen proof.
    case streamRenderDraw
    /// DIAGNOSTIC (blank live-preview pane): keyboard view-controller lifecycle —
    /// each `JotKeyboardViewController` gets a short id logged on construction and
    /// when it (re)installs / re-renders its root. More than one id alive during a
    /// single dictation = ghost controllers (hypothesis C at the controller layer).
    case keyboardControllerLifecycle
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

    /// Ring buffer ceiling. Temporarily raised 100 → 500 (2026-06-16) while
    /// chasing the keyboard blank-pane bug: the per-word `streamRevealAdvance`
    /// + per-instance draw/lifecycle probes generate many records per dictation,
    /// and a 100-entry buffer evicted the decisive early lifecycle/sync records
    /// before a repro could be copied out. 500 captures a full repro; drop back
    /// to 100 once the stream-render diagnostics are removed.
    static let maxEntries = 500

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
