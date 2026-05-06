import ActivityKit
import Foundation

/// `ActivityAttributes` describing the Jot dictation Live Activity.
///
/// Lives in `Jot/Shared/` because both the main app target and the `JotWidget`
/// extension need to reference the same type. `project.yml` lists `Shared` as a
/// source path on both targets, so adding the file here makes it available in
/// the intent (main app) code that calls `Activity.request(...)` and in the
/// widget code that renders `ActivityConfiguration<DictationAttributes>`.
///
/// The static attributes are intentionally empty: everything meaningful is in
/// `ContentState`, which is delivered via `Activity.update(_:)` as the
/// dictation moves through phases.
public struct DictationAttributes: ActivityAttributes {
    /// The phase the pill is currently displaying. The current state machine
    /// flows:
    ///
    ///     recording → transcribing → processing → cleaning? → followUp
    ///         where followUp auto-collapses back to no activity when the
    ///         freshness window expires
    ///
    /// `cleaning` is skipped when the user has cleanup disabled (and is also
    /// skipped for chained-follow-up command results — see the chained
    /// follow-up brief in `docs/design/voice-interaction-patterns.md` for
    /// why).
    ///
    /// `.finished` / `.finishedCommand` are retained for backwards
    /// compatibility with older activity payloads and switch sites, but the
    /// current pipeline now transitions straight into `.followUp` so the user
    /// sees the command window immediately after each dictation lands.
    public enum Phase: Codable, Hashable, Sendable {
        /// The mic is open and capturing. `startedAt` is the wall-clock time
        /// the first buffer was written so the widget can render elapsed time
        /// via a `Text(timerInterval:)` without sending an update per second.
        case recording(startedAt: Date)

        /// Audio capture has stopped; Parakeet is running on-device.
        case transcribing

        /// The raw transcript is being resolved as either a fresh dictation
        /// or a chained follow-up command.
        case processing

        /// The raw transcript is running through Foundation Models cleanup.
        case cleaning

        /// The dictation pipeline is chaining an LLM rewrite (v0.4) using a
        /// keyboard-mode-picker-selected saved prompt. UI mirrors the
        /// `.transcribing / .processing / .cleaning` shape (spinner +
        /// "Working on it…") plus a small "Rewriting with <promptName>…"
        /// caption so the user can see which mode is running and disambiguate
        /// from the v0.3 cleanup pass.
        ///
        /// `promptName` is the user-supplied name from `SavedPrompt`. Cap
        /// length at the call site if the name is unusually long — the
        /// widget renders single-line.
        case rewriting(promptName: String)

        /// The 30-second chained-follow-up window is active. The user can
        /// dictate again and have the next utterance resolved as a command
        /// against the just-finished transcript.
        case followUp(expiresAt: Date)

        /// Legacy terminal state for a plain dictation.
        ///
        /// Retained so older live-activity payloads still decode after app
        /// updates; the current pipeline now advances straight into
        /// `.followUp(expiresAt:)` instead.
        case finished(preview: String)

        /// Chained follow-up succeeded: the user's short utterance was
        /// classified as a command against the prior transcript, the
        /// transformed prior is now on the clipboard, and a new
        /// follow-up transcript has been appended to the ledger with the
        /// classified instruction attached.
        ///
        /// - `instruction`: the classifier's extraction of what the user
        ///   asked for (e.g. "make this more casual"). Shown in the
        ///   outcome pill as "Command: <instruction>" so the user sees
        ///   that their follow-up was recognised and applied, not
        ///   literally pasted.
        /// - `preview`: first ~60 chars of the transformed result (what
        ///   the clipboard now holds). Serves the same reassurance role
        ///   that `preview` plays on `.finished` — "this is the text you
        ///   can now paste".
        ///
        /// Retained for the same backwards-compatibility reason as
        /// `.finished(preview:)`. Kept as a separate case (rather than adding
        /// an optional `instruction` to `.finished`) so every `switch` on
        /// `Phase` forces a conscious choice about which outcome to render; an
        /// optional would silently default to "Copied to clipboard" for the
        /// command case if a site forgot to check it.
        case finishedCommand(instruction: String, preview: String)
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase

        /// Live partial-transcript preview shown in the expanded `.center`
        /// region and on the lock-screen banner's third row while
        /// `phase == .recording`. Populated by the streaming-writer at
        /// ≤1.3 Hz, gated by the `liveActivityTranscriptEnabled` settings
        /// toggle (see design.md §8). Compact and minimal closures do not
        /// reference this field — privacy is structural.
        ///
        /// Wire shape: the last 12 words of cumulative `streamingText`,
        /// word-aligned, capped at 60 chars total (truncate the leading edge
        /// if the 12-word tail exceeds 60 chars). `nil` or `""` when the
        /// toggle is off, when the user has not yet spoken, or when the
        /// phase is anything other than `.recording`. Renderer treats `nil`
        /// and `""` identically — empty is empty, no placeholder.
        ///
        /// Defaulted to `nil` in the initializer so in-flight ContentStates
        /// from prior app builds (encoded without this key) continue to
        /// decode cleanly. `Optional<String>` Codable handles missing-key
        /// decoding by yielding `nil` — no custom Decoder needed.
        public var lastWordsPreview: String?

        public init(phase: Phase, lastWordsPreview: String? = nil) {
            self.phase = phase
            self.lastWordsPreview = lastWordsPreview
        }
    }

    /// Attributes are static per-activity. We don't currently need any — the
    /// pill's identity is "the current Jot recording" and everything dynamic
    /// lives in `ContentState`. Kept as an explicit empty init so the type is
    /// stable if we later want to stamp e.g. an origin ("action button" vs
    /// "in-app button") without breaking existing activities.
    public init() {}
}
