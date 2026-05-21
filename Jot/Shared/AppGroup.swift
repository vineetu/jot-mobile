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

        /// Latest live partial-transcript text from the FluidAudio EOU
        /// streaming model. Written by `StreamingPartial` (main app) on every
        /// callback and finalize/reset; read by the keyboard extension to
        /// render the live caption strip above the mic CTA. Empty string when
        /// no recording is active or no partial has emitted yet.
        static let streamingPartialText = "jot.streaming.partialText"

        /// User-visible variant label (e.g. "Parakeet 110M",
        /// "Parakeet 600M") while `StreamingTranscriptionService` is
        /// inside the per-session `loadModels(from:)` window — i.e.
        /// the streaming CoreML graph is being loaded into ANE and is
        /// not yet ready to consume audio. Empty string when no load
        /// is in flight. Drives the "Loading [variant]…" placeholder
        /// rendered by the recording hero and the keyboard's streaming
        /// strip in place of the usual "Listening…" idle copy. We
        /// store the resolved display name (not a variant tag) so the
        /// keyboard extension can render the placeholder without
        /// linking `SpeechModelVariant` — the enum's owning file
        /// imports `FluidAudio`, which the 60 MB keyboard target must
        /// not link.
        static let streamingLoadingVariantLabel = "jot.streaming.loadingVariantLabel"

        /// Selected AI rewrite backend. String value matches an
        /// `LLMProvider` raw value. Currently the only valid value is
        /// `"qwen35"` (Qwen 3.5 4B 4-bit via MLX). Legacy values
        /// (`"phi4"`, `"gemma"`, `"appleIntelligence"`) are recognized
        /// but treated as `"qwen35"` by the factory's fallback. The key
        /// is preserved so the Switch Model picker UI has something to
        /// bind against when a second backend is added.
        static let aiRewriteProvider = "jot.ai.rewriteProvider"

        /// User-facing master toggle for the warm-hold feature. When `false`
        /// (default), Jot fully cools after each dictation. Users opt in via
        /// the wizard step (Phase 2) or Settings toggle (Phase 1). Duration
        /// is governed by `warmHoldDurationSeconds`.
        static let warmHoldEnabled = "jot.warmHold.enabled"
        static let warmHoldDurationSeconds = "jot.warmHold.durationSeconds"
        static let warmHoldExpiresAt = "jot.warmHold.expiresAt"
        static let warmHoldHeartbeat = "jot.warmHold.heartbeat"

        /// JSON-encoded `[SavedPrompt]`, written by the AI Rewrite settings
        /// page (add/edit/delete/reorder) and read by the keyboard's Magic
        /// menu to populate the prompt picker. See `Shared/SavedPrompt.swift`
        /// for the encoded shape and `Shared/SavedPromptStore.swift` for the
        /// access pattern. Default (key missing) is treated as "empty list"
        /// by the store, which seeds the bundled `SavedPrompt.allDefaults`.
        static let savedPrompts = "jot.ai.savedPrompts"

        /// User-selected speech-model variant. Supported values:
        /// - `"tdtCtc110m"` — Parakeet TDT-CTC 110M (bundled, default).
        /// - `"parakeetV2"` — Parakeet 0.6B v2 (downloadable opt-in,
        ///   ~440 MB). Shares the EOU 120M streaming graph with the
        ///   bundled 110M variant.
        ///
        /// Read by `TranscriptionService` and `StreamingTranscriptionService`
        /// at every session boundary to pick the right model. Unknown /
        /// legacy values (including `"nemotron0_6b"` from prior builds)
        /// fall back to the bundled TDT-CTC 110M (no in-place
        /// rewrite — see the `speechModelVariant` accessor below).
        static let speechModelVariant = "jot.speech.modelVariant"

        /// Wall-clock `Date` of the most recent main-app foreground
        /// heartbeat. Written by `JotApp` every ~1s while
        /// `scenePhase == .active`, cleared on `.background` /
        /// `.inactive`. Read by the keyboard extension to detect
        /// "host app is Jot itself" — used to short-circuit the mic
        /// CTA's URL bounce (`extensionContext.open(jot://dictate)`)
        /// in the setup wizard W5 case (keyboard try-it), where iOS
        /// refuses to re-launch the already-foreground app via URL
        /// scheme. See
        /// `AppGroup.isJotAppForeground()` for the read helper.
        static let appForegroundHeartbeat = "jot.app.foreground.heartbeat"
    }

    /// User-facing master toggle for the warm-hold feature. Default
    /// `false` (feature off), so users explicitly opt in via the wizard step
    /// (Phase 2) or Settings toggle (Phase 1).
    ///
    /// When enabled, the audio session stays active for the user-configured
    /// duration (see `warmHoldDurationSeconds`, default 60s) after each
    /// successful dictation so the next dictation skips cold-start latency.
    /// The iOS orange microphone indicator stays on during that window.
    ///
    /// Uses `bool(forKey:)` because the missing-key default is `false`,
    /// which `UserDefaults.bool(forKey:)` returns naturally.
    static var warmHoldEnabled: Bool {
        get { defaults.bool(forKey: Keys.warmHoldEnabled) }
        set { defaults.set(newValue, forKey: Keys.warmHoldEnabled) }
    }

    /// User-configurable warm-hold duration in seconds. Default `60` when
    /// unset; values are clamped to `[60, 300]` on both read and write.
    ///
    /// `RecordingService.enterWarmHold()` reads this once at warm-hold
    /// entry into a local; subsequent Settings changes do NOT resize an
    /// in-flight warm window — the new value takes effect on the next
    /// dictation's warm-hold.
    static var warmHoldDurationSeconds: TimeInterval {
        get {
            guard defaults.object(forKey: Keys.warmHoldDurationSeconds) != nil else {
                return 60
            }
            let raw = defaults.double(forKey: Keys.warmHoldDurationSeconds)
            return min(max(raw, 60), 300)
        }
        set {
            let clamped = min(max(newValue, 60), 300)
            defaults.set(clamped, forKey: Keys.warmHoldDurationSeconds)
        }
    }

    /// Wall-clock Date when the current warm-hold window will auto-cool.
    /// Set by RecordingService.enterWarmHold; cleared on warm exit.
    /// Read by the keyboard extension to decide between the warm fast-path
    /// (Darwin notification) and cold-launch (jot:// URL bounce).
    static var warmHoldExpiresAt: Date? {
        get { defaults.object(forKey: Keys.warmHoldExpiresAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.warmHoldExpiresAt)
            } else {
                defaults.removeObject(forKey: Keys.warmHoldExpiresAt)
            }
        }
    }

    /// Liveness heartbeat written by RecordingService every ~1s while
    /// warm-hold is active. The keyboard gates the warm-resume fast-path
    /// on this being fresh (≤2.5s old) — without it, a ghost expiry
    /// from a jetsammed main app would silently swallow Dictate taps
    /// because no listener exists for the warm-resume Darwin notification.
    /// Stale heartbeat → fall through to URL bounce.
    static var warmHoldHeartbeat: Date? {
        get { defaults.object(forKey: Keys.warmHoldHeartbeat) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.warmHoldHeartbeat)
            } else {
                defaults.removeObject(forKey: Keys.warmHoldHeartbeat)
            }
        }
    }

    /// Selected AI rewrite backend. Currently the only valid value is
    /// `"qwen35"` (Qwen 3.5 4B 4-bit via MLX). Legacy values (`"phi4"`,
    /// `"gemma"`, `"appleIntelligence"`) are recognized but treated as
    /// `"qwen35"` by `LLMClientFactory`. Default (key missing) is
    /// `"qwen35"`.
    static var aiRewriteProvider: String {
        get { defaults.string(forKey: Keys.aiRewriteProvider) ?? "qwen35" }
        set { defaults.set(newValue, forKey: Keys.aiRewriteProvider) }
    }

    /// Raw JSON `Data` blob backing the saved-prompts list. Prefer the
    /// `SavedPromptStore` API (encodes/decodes and seeds the default entry)
    /// over reading this accessor directly. Returns `nil` when no list has
    /// ever been written.
    static var savedPromptsJSON: Data? {
        get { defaults.data(forKey: Keys.savedPrompts) }
        set { defaults.set(newValue, forKey: Keys.savedPrompts) }
    }

    /// User-selected speech-model variant (raw `String`).
    /// Supported values:
    /// - `"tdtCtc110m"` (Parakeet TDT-CTC 110M, bundled default)
    /// - `"parakeetV2"` (Parakeet 0.6B v2, opt-in download)
    ///
    /// `TranscriptionService` and `StreamingTranscriptionService` resolve
    /// this string at every session boundary — flipping the variant in
    /// Settings only takes effect on the next dictation start, never
    /// mid-session.
    ///
    /// Truly unknown values (including stale `"nemotron0_6b"` tags from
    /// prior builds) fall back to the bundled `"tdtCtc110m"` default so
    /// a malformed write can't brick transcription. This is the
    /// auto-migration path for users who had Nemotron selected before
    /// the rip — first read after upgrade silently routes them back to
    /// the bundled variant.
    static var speechModelVariant: String {
        get {
            let stored = defaults.string(forKey: Keys.speechModelVariant)
            switch stored {
            case "tdtCtc110m", "parakeetV2":
                return stored!
            default:
                return "tdtCtc110m"
            }
        }
        set { defaults.set(newValue, forKey: Keys.speechModelVariant) }
    }

    /// See `Keys.streamingLoadingVariantLabel` for semantics. Written
    /// by the main app's `StreamingTranscriptionService` on every
    /// load-state transition (non-empty while loading, empty when
    /// idle/ready); read by the keyboard extension to mirror the
    /// "Loading [variant]…" placeholder.
    static var streamingLoadingVariantLabel: String {
        get { defaults.string(forKey: Keys.streamingLoadingVariantLabel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.streamingLoadingVariantLabel) }
    }

    /// Returns `true` when the main Jot app is currently foreground —
    /// inferred from the recency of `Keys.appForegroundHeartbeat`.
    ///
    /// The keyboard extension uses this to detect "host app == Jot"
    /// (typically: setup wizard W5 keyboard try-it). When `true`, the mic CTA tap is
    /// routed to a Darwin notification (`keyboardDictateTapped`) instead
    /// of the normal `jot://dictate` URL bounce, because iOS silently
    /// refuses to re-launch the already-foreground app via URL scheme
    /// and the tap would otherwise appear to do nothing.
    ///
    /// Freshness window: 2.5s. The main app refreshes the heartbeat
    /// every ~1s while foreground (see `JotApp.heartbeatTask`), so a
    /// 2.5s window tolerates one missed tick (Timer skew, brief task
    /// pause) without false-positive "Jot is foreground" reads after
    /// force-quit or backgrounding. Force-quit + immediate keyboard tap
    /// in another host within the 2.5s window is a known stale-read
    /// edge case — the worst-case fallout is the keyboard skipping the
    /// URL bounce and posting the Darwin notification, which the
    /// (now-suspended) main app simply doesn't observe; the user sees
    /// nothing happen and retries. Tolerable for the wizard W5 case.
    static func isJotAppForeground() -> Bool {
        guard let last = defaults.object(
            forKey: Keys.appForegroundHeartbeat
        ) as? Date else { return false }
        return Date().timeIntervalSince(last) < 2.5
    }

}
