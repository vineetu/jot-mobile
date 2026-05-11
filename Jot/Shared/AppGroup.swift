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
        /// `LLMProvider` raw value. Currently the only valid value is
        /// `"phi4"` (Phi-4-mini-instruct-4bit via MLX). Read by the LLM
        /// factory in the main app to pick which `LLMClient`
        /// implementation to instantiate. Default (key missing) is
        /// `"phi4"`. Legacy values (`"qwen"`, `"gemma"`,
        /// `"appleIntelligence"`) are recognized but treated as `"phi4"`
        /// by the factory's fallback.
        static let aiRewriteProvider = "jot.ai.rewriteProvider"

        /// User-facing master toggle for the AI Rewrite feature. When `false`
        /// (default), the keyboard's Magic CTA stays hidden and no LLM weights
        /// are warmed. Flipping this ON in Settings is the single user gesture
        /// that opts the device in to the on-device LLM path.
        static let aiRewriteEnabled = "jot.ai.rewriteEnabled"

        /// JSON-encoded `[SavedPrompt]`, written by the AI Rewrite settings
        /// page (add/edit/delete/reorder) and read by the keyboard's Magic
        /// menu to populate the prompt picker. See `Shared/SavedPrompt.swift`
        /// for the encoded shape and `Shared/SavedPromptStore.swift` for the
        /// access pattern. Default (key missing) is treated as "empty list"
        /// by the store, which seeds the bundled `defaultRewrite` entry.
        static let savedPrompts = "jot.ai.savedPrompts"

        /// User-selected speech-model variant. Values are FluidAudio
        /// `Repo` raw values: `"parakeetV2"` (Parakeet TDT 0.6B v2 — the
        /// current accuracy default) or `"tdtCtc110m"` (the lighter 110M
        /// hybrid TDT-CTC variant). Read by `TranscriptionService` on
        /// every `ensurePreparing()` to resolve which model to download
        /// + load. Default (key missing) is `"parakeetV2"` to preserve
        /// existing-install behaviour.
        static let speechModelVariant = "jot.speech.modelVariant"
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

    /// Selected AI rewrite backend. Currently the only valid value is
    /// `"phi4"` (Phi-4-mini-instruct-4bit via MLX). Legacy values
    /// (`"qwen"`, `"gemma"`, `"appleIntelligence"`) are recognized but
    /// treated as `"phi4"` by the factory's fallback. Default (key
    /// missing) is `"phi4"`.
    static var aiRewriteProvider: String {
        get { defaults.string(forKey: Keys.aiRewriteProvider) ?? "phi4" }
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
        get { defaults.string(forKey: Keys.speechModelVariant) ?? "parakeetV2" }
        set { defaults.set(newValue, forKey: Keys.speechModelVariant) }
    }
}
