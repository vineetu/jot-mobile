import Foundation

/// Shared identifier and helpers for cross-target communication between the
/// Jot app, its keyboard extension, and its Live Activity widget.
///
/// Every target in `project.yml` must list this group under
/// `com.apple.security.application-groups`.
enum AppGroup {
    static let identifier = "group.com.vineetu.jot.mobile.shared"

    /// Root of the shared App Group container (visible to the app, keyboard,
    /// and Share Extension). `nil` only if entitlements are misconfigured.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Queue directory where the Share Extension stages audio shared into Jot
    /// (one file per shared item, named `<uuid>.<ext>`). The main app drains +
    /// transcribes it on the next foreground (Model B — the extension never
    /// opens the app). Creates the directory on first access. See
    /// `PendingShareDrainer` (app side) and `ShareViewController` (extension).
    static func pendingSharesDirectory() -> URL? {
        guard let dir = containerURL?.appendingPathComponent("PendingShares", isDirectory: true) else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

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

        /// Queue of words the keyboard staged for "Add to Vocabulary" (its
        /// "..." popover). The keyboard can't write the main-app-private
        /// vocabulary file, so it appends here and the main app drains via
        /// `VocabularyAddInbox` on its next foreground. JSON-encoded `[String]`.
        static let pendingVocabAdds = "jot.vocab.pendingAdds"

        /// Hidden "Text-to-Speech (Lab)" opt-in toggle (Settings → About reveal).
        /// Gates the experimental on-device Kokoro TTS + Apple-Translation
        /// transcript playback; default off, and turning it on is what triggers
        /// the model download. See `docs/tts-lab/design.md`.
        static let ttsLabEnabled = "jot.tts.labEnabled"
        /// PROTOTYPE A/B (model-instant-load): load the Parakeet encoder on CPU+GPU
        /// instead of the Neural Engine, to test whether it avoids the ~60s
        /// post-update ANE device-specialization. Default off (= Neural Engine).
        static let asrUseCPUGPU = "jot.asr.useCPUGPU"
        /// JSON-encoded registry of the user's cloned PocketTTS voices
        /// (`[{name, fileName}]`). The `.bin` conditioning files live in
        /// `ApplicationSupport/TTSVoices/<uuid>.bin`; this key holds only the
        /// display-name ⇄ file mapping. See `TTSService.clonedVoices`.
        static let ttsClonedVoices = "jot.tts.clonedVoices"
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

        /// Wall-clock `Date` the current streaming ANE load began, and the
        /// per-device estimated duration (seconds) the main app's
        /// `ModelLoadTimekeeper` chose for it. Written together with
        /// `streamingLoadingVariantLabel` at `sessionLoadState → .loading`
        /// (cleared on `.ready`/`.idle`); read by the keyboard extension to
        /// pace the SAME calibrated "Loading…" progress bar the hero shows,
        /// without linking `ModelLoadTimekeeper`/`FluidAudio` (60 MB ceiling).
        static let streamingLoadStartedAt = "jot.streaming.loadStartedAt"
        static let streamingLoadEstimateSeconds = "jot.streaming.loadEstimateSeconds"

        /// Selected AI rewrite backend. String value matches an
        /// `LLMProvider` raw value. Currently the only valid value is
        /// `"qwen35"` (Qwen 3.5 4B 4-bit via MLX). Legacy values
        /// (`"phi4"`, `"gemma"`, `"appleIntelligence"`) are recognized
        /// but treated as `"qwen35"` by the factory's fallback. The key
        /// is preserved so the Switch Model picker UI has something to
        /// bind against when a second backend is added.
        static let aiRewriteProvider = "jot.ai.rewriteProvider"

        /// Which rewrite ENGINE the user has chosen: Apple Intelligence (system
        /// Writing Tools, no Jot prompts) vs Jot's AI (Qwen + saved prompts).
        /// Absent ⇒ default to Apple Intelligence when the device has it.
        /// See `RewriteMode`. features.md §6.3 / §7.10.
        static let rewriteMode = "jot.ai.rewriteMode"

        /// User-facing master toggle for the warm-hold feature. When `false`
        /// (default), Jot fully cools after each dictation. Users opt in via
        /// the wizard step (Phase 2) or Settings toggle (Phase 1). Duration
        /// is governed by `warmHoldDurationSeconds`.
        static let warmHoldEnabled = "jot.warmHold.enabled"
        static let warmHoldDurationSeconds = "jot.warmHold.durationSeconds"

        /// `true` only while the setup wizard's W5 ("Now try the keyboard")
        /// step is on screen. Set by `SetupWizardView` on W5 entry and cleared
        /// on leave / wizard dismiss. Read cross-process: it gates the
        /// one-time "First-time setup" koan line (`ColdStartCopy.firstEverLine`)
        /// to the wizard ONLY — the keyboard and the in-app hero must NEVER
        /// show the koan, only the rotating lines. The keyboard reads it
        /// indirectly (the app writes the resolved line into
        /// `streamingLoadingVariantLabel`), but the flag itself lives here so
        /// the gate is the single cross-process source of truth.
        static let wizardActive = "jot.setupWizard.w5Active"

        /// Warm-hold switching-nudge state (UX-overhaul round 2 §4 / R10).
        /// All three live in App-Group `UserDefaults` (no schema bump) so the
        /// app's streak math and the keyboard's render of the nudge share one
        /// source of truth across processes.
        ///
        /// `captureStopRing`: JSON-encoded ring buffer of the last ~4
        /// `(startedAt, stoppedAt, sessionID)` clean-stop pairs. The app
        /// derives the qualifying-return streak from this (R16 — self-expiring
        /// across app kills because it's capped). Written ONLY at the clean
        /// `stop()` site by `RecordingService`. The keyboard never reads it.
        static let captureStopRing = "jot.warmHold.captureStopRing"
        /// `warmHoldNudgeShouldShow`: boolean projection the app sets when the
        /// streak crosses threshold; the keyboard (which can't run the math)
        /// renders the nudge off this and clears it via the two actions.
        /// Mirrors the `pipelinePhase` projection pattern.
        static let warmHoldNudgeShouldShow = "jot.warmHold.nudgeShouldShow"
        /// `warmHoldNudgeSuppressed`: permanent one-tap "Don't show again"
        /// flag (§4). Once true the nudge never re-shows; turning warm hold ON
        /// is the other terminal state. Passive ignore does NOT set this.
        static let warmHoldNudgeSuppressed = "jot.warmHold.nudgeSuppressed"

        /// Default-ON Lab kill-switch for the MiniLM embedding writer.
        /// Read by `TranscriptStore.append`, `PhoneSideWCSession.saveTranscript`,
        /// and `EmbeddingBackfillTask` before any encode work. Default `true`
        /// (treated as ON by `AppGroup.isEmbeddingsEnabled`). Stored here in
        /// `AppGroup.defaults` for symmetry with the prior classifier toggle.
        /// Surfaced in Settings → About as a one-row toggle. See
        /// `docs/plans/minilm-embeddings.md` §Lab kill-switch for rationale.
        static let embeddingsEnabled = "jot.embeddings.enabled"

        /// JSON-encoded `[SavedPrompt]`, written by the AI Rewrite settings
        /// page (add/edit/delete/reorder) and read by the keyboard's Magic
        /// menu to populate the prompt picker. See `Shared/SavedPrompt.swift`
        /// for the encoded shape and `Shared/SavedPromptStore.swift` for the
        /// access pattern. Default (key missing) is treated as "empty list"
        /// by the store, which seeds the bundled `SavedPrompt.allDefaults`.
        static let savedPrompts = "jot.ai.savedPrompts"

        /// Legacy persisted speech-model variant tag. Jot now ships a single
        /// bundled model (Parakeet 0.6B v2, English), so this key is no longer
        /// read for model selection — the `speechModelVariant` accessor below
        /// resolves every value (legacy `"tdtCtc110m"` / `"parakeetV2"` /
        /// `"nemotron0_6b"`, unset, or malformed) to the sole `"english"`
        /// model. Kept only for backward-compatible reads/writes.
        static let speechModelVariant = "jot.speech.modelVariant"
        /// "Live text while dictating" tri-state: "auto" | "on" | "off".
        static let liveTextSetting = "jot.preview.liveText"

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

        /// Wall-clock `Date` of the most recent keyboard-active heartbeat.
        /// Written by `JotKeyboardViewController` every ~1s while the Jot
        /// keyboard is on screen (`viewWillAppear` → repeating Timer →
        /// `viewWillDisappear` stop). The MIRROR of `appForegroundHeartbeat`
        /// — that one is app→keyboard, this one is keyboard→app. Read by the
        /// setup wizard W5 step (`TryKeyboardStep`) to detect "is the Jot
        /// keyboard the frontmost keyboard" and dismiss the globe-switch cue.
        /// See `AppGroup.isJotKeyboardActive()`. NOTE: iOS blocks App Group
        /// writes when Full Access is off, so the heartbeat only flows once
        /// Full Access is granted (W3 keyboard-install step) — acceptable,
        /// W5 dictation already requires it.
        static let keyboardActiveHeartbeat = "jot.keyboard.active.heartbeat"

        /// Which LLM answers Ask-mode questions. `"appleIntelligence"` (default —
        /// no download) or `"qwen"` (on-board, better answers, needs the 2.5 GB
        /// download). Read by `AskController.pickBackend()`; bound to the
        /// Settings → AI "Use on-board Qwen for Ask" toggle.
        static let askBackend = "jot.ask.backend"
    }

    /// MiniLM embedding writer toggle. **Default `true`** — users opt OUT
    /// rather than in, because embeddings are foundation work the rest of
    /// Jot will depend on. Surfaced in Settings → About as an emergency
    /// kill-switch if a field MLTensor OOM regression slips past the
    /// pre-merge memory gate.
    ///
    /// Custom getter (not `bool(forKey:)`) so the missing-key state reads
    /// as `true` (default-ON). Setter writes through to the underlying
    /// `Bool` so the SwiftUI `Toggle` binding works naturally.
    static var isEmbeddingsEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.embeddingsEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.embeddingsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.embeddingsEnabled) }
    }

    /// User-facing master toggle for the warm-hold feature. Default
    /// `false` (feature off), so users explicitly opt in via the wizard step
    /// (Phase 2) or Settings toggle (Phase 1).
    ///
    /// When enabled, the audio session stays active for the user-configured
    /// duration (see `warmHoldDurationSeconds`, default 120s (2 minutes)) after each
    /// successful dictation so the next dictation skips cold-start latency.
    /// The iOS orange microphone indicator stays on during that window.
    ///
    /// Uses `bool(forKey:)` because the missing-key default is `false`,
    /// which `UserDefaults.bool(forKey:)` returns naturally.
    static var warmHoldEnabled: Bool {
        get { defaults.bool(forKey: Keys.warmHoldEnabled) }
        set { defaults.set(newValue, forKey: Keys.warmHoldEnabled) }
    }

    /// PROTOTYPE A/B (model-instant-load): when true, load the Parakeet encoder on
    /// CPU+GPU instead of the Neural Engine. The ANE pays a ~60s device
    /// specialization on first load after an app update; CPU+GPU skips that (at a
    /// possible per-dictation speed cost). Default false (= Neural Engine).
    static var asrUseCPUGPU: Bool {
        get { defaults.bool(forKey: Keys.asrUseCPUGPU) }
        set { defaults.set(newValue, forKey: Keys.asrUseCPUGPU) }
    }

    /// See `Keys.wizardActive`. `true` only while the wizard's W5 step is on
    /// screen; gates the one-time "First-time setup" koan to the wizard so the
    /// keyboard / hero never render it. Missing-key default `false`.
    static var wizardActive: Bool {
        get { defaults.bool(forKey: Keys.wizardActive) }
        set { defaults.set(newValue, forKey: Keys.wizardActive) }
    }

    /// User-configurable warm-hold duration in seconds. Default `120` (2 minutes) when
    /// unset; values are clamped to `[60, 300]` on both read and write.
    ///
    /// `RecordingService.enterWarmHold()` reads this once at warm-hold
    /// entry into a local; subsequent Settings changes do NOT resize an
    /// in-flight warm window — the new value takes effect on the next
    /// dictation's warm-hold.
    static var warmHoldDurationSeconds: TimeInterval {
        get {
            guard defaults.object(forKey: Keys.warmHoldDurationSeconds) != nil else {
                return 120
            }
            let raw = defaults.double(forKey: Keys.warmHoldDurationSeconds)
            return min(max(raw, 60), 300)
        }
        set {
            let clamped = min(max(newValue, 60), 300)
            defaults.set(clamped, forKey: Keys.warmHoldDurationSeconds)
        }
    }

    // NOTE: the legacy `warmHoldExpiresAt` / `warmHoldHeartbeat` keys + accessors
    // were removed in B4 (docs/recording-coordination/design.md). Warm-vs-cold is
    // now read from the unified `RecordingRecord`'s `.warmIdle` state + `liveness`;
    // the keyboard no longer reads a separate warm window/heartbeat.

    /// Wall-clock `Date` of the most recent keyboard-active heartbeat,
    /// written by the keyboard extension every ~1s while it's on screen.
    /// Same accessor shape as the other heartbeat slots. Read by W5 to gate
    /// the globe-switch cue via `isJotKeyboardActive()`.
    static var keyboardActiveHeartbeat: Date? {
        get { defaults.object(forKey: Keys.keyboardActiveHeartbeat) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.keyboardActiveHeartbeat)
            } else {
                defaults.removeObject(forKey: Keys.keyboardActiveHeartbeat)
            }
        }
    }

    /// Freshness window for `keyboardActiveHeartbeat`. The keyboard refreshes
    /// every ~1s while presented, so a 3s window tolerates two missed ticks
    /// (Timer skew, brief suspension) without falsely reporting the keyboard
    /// active after it's been dismissed or swapped out.
    static let keyboardActiveStaleThreshold: TimeInterval = 3.0

    /// Returns `true` when the Jot keyboard is currently the frontmost
    /// keyboard — inferred from the recency of `keyboardActiveHeartbeat`.
    /// `false` when no heartbeat exists (keyboard never presented, or Full
    /// Access off so the write no-ops) or the last one is stale.
    static func isJotKeyboardActive(now: Date = Date()) -> Bool {
        guard let last = keyboardActiveHeartbeat else { return false }
        return now.timeIntervalSince(last) < keyboardActiveStaleThreshold
    }

    /// Ring buffer of recent clean-stop `(startedAt, stoppedAt, sessionID)`
    /// pairs backing the warm-hold switching-nudge streak math (§4 / R10 /
    /// R16). Stored as JSON `Data`; `RecordingService` owns the encode/decode
    /// (it owns the `CaptureStopEntry` shape and the iso8601 coder pair).
    /// Returns `nil` when no stop has ever been recorded — the app treats a
    /// `nil`/undecodable blob as an empty ring (self-healing).
    static var captureStopRing: Data? {
        get { defaults.data(forKey: Keys.captureStopRing) }
        set { defaults.set(newValue, forKey: Keys.captureStopRing) }
    }

    /// Boolean projection the app sets when the switching-nudge streak crosses
    /// threshold (§4 / R10). The keyboard process can't run the streak math,
    /// so it renders the nudge off this flag and clears it when the user acts.
    /// `bool(forKey:)` because the missing-key default is `false` (no nudge).
    static var warmHoldNudgeShouldShow: Bool {
        get { defaults.bool(forKey: Keys.warmHoldNudgeShouldShow) }
        set { defaults.set(newValue, forKey: Keys.warmHoldNudgeShouldShow) }
    }

    /// Permanent "Don't show this again" flag for the switching nudge (§4).
    /// Set by the nudge's dismiss action (one tap, no confirm); once `true`
    /// the nudge never re-shows. `bool(forKey:)` — missing-key default `false`.
    static var warmHoldNudgeSuppressed: Bool {
        get { defaults.bool(forKey: Keys.warmHoldNudgeSuppressed) }
        set { defaults.set(newValue, forKey: Keys.warmHoldNudgeSuppressed) }
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

    /// Ask-mode answer backend. The user-facing "Use on-board Qwen for Ask"
    /// toggle was removed (2026-06-16) — Ask now ALWAYS uses Apple Intelligence.
    /// The getter returns `"appleIntelligence"` UNCONDITIONALLY so a device that
    /// had previously persisted `"qwen"` isn't stranded on the on-board model
    /// with no UI left to turn it off. Setter retained (nothing writes it now);
    /// restore the stored read if the toggle is ever reintroduced.
    static var askBackend: String {
        get { "appleIntelligence" }
        set { defaults.set(newValue, forKey: Keys.askBackend) }
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
            // Jot ships a single bundled speech model. Every persisted tag —
            // legacy (`"tdtCtc110m"`, `"parakeetV2"`, `"nemotron0_6b"`),
            // unset, or malformed — resolves to the sole `"english"` model so
            // a stale write can never brick transcription.
            "english"
        }
        set { defaults.set(newValue, forKey: Keys.speechModelVariant) }
    }

    /// "Live text while dictating" tri-state (`"auto"` / `"on"` / `"off"`).
    /// `auto` resolves through `DeviceCapability.liveTextDefault` so a
    /// future capability-table revision reaches auto users while an
    /// explicit user choice is never clobbered (review #2 F8). Read at
    /// recording start; `off` means the preview consumer is never started
    /// and the slice queue is closed immediately (zero inference during
    /// dictation capture). Ask captures are exempt (their live text is the
    /// input mechanism).
    static var liveTextSetting: String {
        get {
            let stored = defaults.string(forKey: Keys.liveTextSetting)
            switch stored {
            case "auto", "on", "off": return stored!
            default: return "auto"
            }
        }
        set { defaults.set(newValue, forKey: Keys.liveTextSetting) }
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

    /// Start time of the in-flight streaming ANE load (`nil` when not
    /// loading). See `Keys.streamingLoadStartedAt`.
    static var streamingLoadStartedAt: Date? {
        get { defaults.object(forKey: Keys.streamingLoadStartedAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.streamingLoadStartedAt)
            } else {
                defaults.removeObject(forKey: Keys.streamingLoadStartedAt)
            }
        }
    }

    /// Per-device estimated load duration (seconds) for pacing the keyboard's
    /// "Loading…" bar; `0` when not loading. See `Keys.streamingLoadEstimateSeconds`.
    static var streamingLoadEstimateSeconds: Double {
        get { defaults.double(forKey: Keys.streamingLoadEstimateSeconds) }
        set { defaults.set(newValue, forKey: Keys.streamingLoadEstimateSeconds) }
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
