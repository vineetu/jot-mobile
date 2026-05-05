import Foundation

/// Shared identifier and helpers for cross-target communication between the
/// Jot app, its keyboard extension, and its Live Activity widget.
///
/// Every target in `project.yml` must list this group under
/// `com.apple.security.application-groups`.
enum AppGroup {
    static let identifier = "group.com.vineetu.jot.mobile.shared"

    /// `UserDefaults` is documented as thread-safe but does not conform to
    /// `Sendable`, so Swift 6 strict concurrency flags it in a `static let`.
    /// `nonisolated(unsafe)` is the right escape hatch here: the keyboard
    /// extension reads this off-MainActor (`viewWillAppear`, `textDidChange`)
    /// and the app reads it from MainActor — a `@MainActor` isolation would
    /// force the keyboard to hop just to resolve a clipboard handoff.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: identifier) else {
            fatalError("App Group \(identifier) is not configured. Check entitlements.")
        }
        return defaults
    }()

    enum Keys {
        // Single JSON-encoded FreshDictation payload. Consolidated from the old
        // two-key pair so the keyboard extension can't observe a torn write
        // (new timestamp + stale preview, or vice versa).
        static let lastDictation = "jot.lastDictation"
        static let lastAutoCopiedTranscript = "jot.lastAutoCopiedTranscript"

        // User-configurable cleanup behavior, shared between main app and keyboard.
        static let cleanupEnabled = "jot.cleanup.enabled"
        static let cleanupInstructions = "jot.cleanup.instructions"
        static let keyboardAutoPasteEnabled = "jot.keyboard.autoPaste"
        // v7: per-session pending paste record. Replaces the v6 pair
        // (pendingAutoPasteFlag + pendingAutoPasteCreatedAt). See
        // `Shared/PendingPasteSession.swift` for the encoded shape.
        static let pendingPasteSession = "jot.keyboard.pendingPasteSession"
        static let recordingAmplitude = "jot.recording.amplitude"
        // v7: pipeline phase projection (single source of truth for cross-
        // process observation of the pipeline's current state). See
        // `Shared/PipelinePhaseProjection.swift`.
        static let pipelinePhase = "jot.pipeline.phase"
        // v7: bounded log of recently-finished pipeline sessions. See
        // `Shared/TerminalSessionLog.swift`.
        static let terminalSessionLog = "jot.pipeline.terminalSessionLog"

        /// Cut C warm-hold opt-out. When `true` (default), `RecordingService.stop()`
        /// pauses the audio engine instead of tearing it down so the next
        /// `start()` resumes in ~10–50ms. Side effects are user-visible: orange
        /// recording indicator stays on, other apps' audio is muted, Live
        /// Activity / Dynamic Island chip remains during the warm window. The
        /// user can opt out from Settings → "Hold mic warm after stop."
        ///
        /// Both targets need to read it: the main app to gate the engine.pause
        /// path, the keyboard extension to render its mic CTA correctly during
        /// the warm phase (so the CTA doesn't show "ready to start" while the
        /// indicator is still on). The missing-key default is `true` — see
        /// `AppGroup.holdMicWarmAfterStop` accessor.
        ///
        /// **IMPORTANT: read via the `AppGroup.holdMicWarmAfterStop` accessor,
        /// NOT via `defaults.bool(forKey:)`.** `bool(forKey:)` returns `false`
        /// for both "never written" and "explicit false," which collapses the
        /// default-on semantics. The accessor uses `object(forKey:)` to
        /// preserve the distinction. We deliberately do NOT use
        /// `UserDefaults.register(defaults:)` to seed the default — it would
        /// require boot-time registration in every process (main app + keyboard
        /// + widget) and any miss would silently default to false. The
        /// accessor's missing-key default is the single, auditable source of
        /// truth.
        static let holdMicWarmAfterStop = "jot.recording.holdMicWarmAfterStop"

        /// Latest live partial-transcript text from the FluidAudio EOU
        /// streaming model. Written by `StreamingPartial` (main app) on every
        /// callback and finalize/reset; read by the keyboard extension to
        /// render the live caption strip above the mic CTA. Empty string when
        /// no recording is active or no partial has emitted yet.
        static let streamingPartialText = "jot.streaming.partialText"
    }

    /// Whether the warm-hold post-stop engine pause is enabled (Cut C). Default
    /// `true` — the missing-key case (fresh install, never-set, or removed by
    /// the user from a Settings toggle that writes via this same accessor)
    /// returns `true` so first-run behavior matches the user-locked default.
    /// Settings UI flips this; `RecordingService` reads it on every `stop()`
    /// to decide between warm-pause and full-teardown.
    ///
    /// Uses `object(forKey:)` rather than `bool(forKey:)` because the latter
    /// returns `false` for both "never written" and "written false," which
    /// collapses the default-on semantics. The accessor is nonisolated so the
    /// keyboard extension and the main app can both read it without an actor
    /// hop — the underlying `UserDefaults` is thread-safe per Apple's docs.
    static var holdMicWarmAfterStop: Bool {
        get {
            if let value = defaults.object(forKey: Keys.holdMicWarmAfterStop) as? Bool {
                return value
            }
            return true
        }
        set {
            defaults.set(newValue, forKey: Keys.holdMicWarmAfterStop)
        }
    }
}
