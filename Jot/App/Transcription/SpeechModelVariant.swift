import Foundation

/// Canonical enumeration of the user-selectable speech-model variants.
///
/// The raw `String` value is the persisted tag in
/// `AppGroup.speechModelVariant`. The tag set is intentionally narrow —
/// `TranscriptionService` and `StreamingTranscriptionService` both branch
/// on this enum at every session boundary to pick the right model.
///
/// **Why an enum + accessor instead of scattered string-switch sites:**
/// the codebase had at least four near-identical `switch on String`
/// blocks (Settings picker, two TranscriptionService resolvers, the
/// disk-existence helpers). Each new variant multiplied the places
/// where a typo could silently fall through to the default. Routing
/// every resolver through this enum makes adding another variant a
/// single-file change.
///
/// Unknown / legacy values (including `"nemotron0_6b"` from prior
/// builds) resolve to `.tdtCtc110m` — the bundled default — so a
/// malformed AppGroup write or a stale persisted tag from before the
/// Nemotron rip can never brick transcription.
enum SpeechModelVariant: String, CaseIterable, Sendable {
    /// Parakeet TDT-CTC 110M — bundled inside the IPA, always available.
    /// The default variant for new installs.
    case tdtCtc110m = "tdtCtc110m"

    /// Parakeet 0.6B v2 — opt-in download (~440 MB on disk), more
    /// accurate than the bundled 110M variant. Uses the split path:
    /// TDT batch + EOU 120M streaming.
    case parakeetV2 = "parakeetV2"

    /// Resolve the variant tag stored in `AppGroup.speechModelVariant`,
    /// falling back to the bundled default for any unknown value.
    static func current() -> SpeechModelVariant {
        SpeechModelVariant(rawValue: AppGroup.speechModelVariant) ?? .tdtCtc110m
    }

    /// Compact user-facing label that matches the wording Settings
    /// shows in the speech-model picker. Used by the recording hero's
    /// "Loading [variant]…" overlay and the keyboard's loading strip.
    var displayName: String {
        switch self {
        case .tdtCtc110m: return "Parakeet 110M"
        case .parakeetV2: return "Parakeet 600M"
        }
    }
}
