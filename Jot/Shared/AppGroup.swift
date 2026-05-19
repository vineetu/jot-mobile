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

        /// Selected AI rewrite backend. String value matches an
        /// `LLMProvider` raw value. Valid values:
        ///   - `"qwen35"` — Qwen 3.5 4B (4-bit) via MLX. **Default** for
        ///     fresh installs.
        ///   - `"phi4"` — Phi-4-mini-instruct-4bit via MLX. Alternate /
        ///     legacy default; preserved for existing TestFlight users who
        ///     already have Phi-4 weights on-disk.
        ///
        /// Read by the LLM factory in the main app to pick which
        /// `LLMClient` implementation to instantiate. Default resolution
        /// (key missing) honors migration safety:
        ///   - If Phi-4 weights are already on-disk, default to `"phi4"`.
        ///   - Else, default to `"qwen35"`.
        ///
        /// Legacy values (`"gemma"`, `"appleIntelligence"`) are recognized
        /// but treated as the migration default by the factory's fallback.
        static let aiRewriteProvider = "jot.ai.rewriteProvider"

        /// User-facing master toggle for the AI Rewrite feature. When `false`
        /// (default), the keyboard's Magic CTA stays hidden and no LLM weights
        /// are warmed. Flipping this ON in Settings is the single user gesture
        /// that opts the device in to the on-device LLM path.
        static let aiRewriteEnabled = "jot.ai.rewriteEnabled"

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

        /// User-selected speech-model variant. Values are FluidAudio
        /// `Repo` raw values: `"parakeetV2"` (Parakeet TDT 0.6B v2 — the
        /// current accuracy default) or `"tdtCtc110m"` (the lighter 110M
        /// hybrid TDT-CTC variant). Read by `TranscriptionService` on
        /// every `ensurePreparing()` to resolve which model to download
        /// + load. Default (key missing) is `"parakeetV2"` to preserve
        /// existing-install behaviour.
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

    /// User-facing master toggle for AI Rewrite. Default `false` (feature
    /// off) so first-launch behavior matches the locked product default —
    /// users explicitly opt in via the AI Rewrite settings page.
    ///
    /// Uses `bool(forKey:)` because the missing-key default is `false`,
    /// which `UserDefaults.bool(forKey:)` returns naturally.
    static var aiRewriteEnabled: Bool {
        get { defaults.bool(forKey: Keys.aiRewriteEnabled) }
        set { defaults.set(newValue, forKey: Keys.aiRewriteEnabled) }
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

    /// Selected AI rewrite backend. Valid values: `"qwen35"` (Qwen 3.5 4B,
    /// 4-bit via MLX — the **default**) or `"phi4"` (Phi-4-mini-instruct-4bit
    /// via MLX — alternate/legacy). Legacy values (`"gemma"`,
    /// `"appleIntelligence"`) are recognized but treated as the migration
    /// default by `LLMClientFactory`. Default (key missing) is `"qwen35"`
    /// for fresh installs; `LLMClientFactory.currentProvider` additionally
    /// honors a Phi-4 on-disk snapshot to keep existing users on Phi-4.
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

    /// User-selected speech-model variant (raw `String`). `"parakeetV2"`
    /// is the current Parakeet 0.6B v2 default; `"tdtCtc110m"` is the
    /// lighter 110M hybrid TDT-CTC alternative.
    ///
    /// `TranscriptionService` resolves this string to an `AsrModelVersion`
    /// at every `ensurePreparing()` boundary — flipping the variant in
    /// Settings only takes effect on the next dictation start, never
    /// mid-session.
    static var speechModelVariant: String {
        get { defaults.string(forKey: Keys.speechModelVariant) ?? "tdtCtc110m" }
        set { defaults.set(newValue, forKey: Keys.speechModelVariant) }
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
