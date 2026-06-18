import Foundation

/// Canonical enumeration of the speech-model "variant".
///
/// Jot now ships a **single bundled speech model** — Parakeet 0.6B v2,
/// vendored inside the IPA at
/// `Resources/Models/Parakeet/parakeet-tdt-0.6b-v2-coreml/`. There is no
/// model selector and no opt-in download anymore. The enum survives as a
/// thin "Language" concept (English-only today) so the resolver sites
/// (`TranscriptionService`, the loading affordance) keep a single typed
/// source of truth, and so future languages are a single-file change.
///
/// The raw `String` value is the persisted tag in
/// `AppGroup.speechModelVariant`. Any legacy tag from prior builds
/// (`"tdtCtc110m"`, `"parakeetV2"`, `"nemotron0_6b"`, unset, or anything
/// malformed) resolves to the sole `.english` case via `current()` — a
/// stale persisted tag can never brick transcription.
enum SpeechModelVariant: String, CaseIterable, Sendable {
    /// The sole speech model: Parakeet 0.6B v2, English, bundled in the IPA.
    case english = "english"

    /// Resolve the variant tag stored in `AppGroup.speechModelVariant`.
    /// There is only one model, so every value — legacy, unset, or
    /// malformed — resolves to `.english`.
    static func current() -> SpeechModelVariant {
        .english
    }

    /// User-facing name shown in the "Loading [name]…" affordance (the
    /// recording hero's overlay and the keyboard's loading strip — its only
    /// callers). Deliberately model-agnostic: we never surface model sizes or
    /// codenames ("600M", "Parakeet") to the user, so this reads "the English
    /// model". When other languages ship this becomes "the [Language] model".
    var displayName: String {
        switch self {
        case .english: return "the English model"
        }
    }
}
