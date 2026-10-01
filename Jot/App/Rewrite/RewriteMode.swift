import Foundation

/// The rewrite engine. There is exactly one: the user's saved prompts run on
/// Apple Intelligence (on-device Foundation Models; Private Cloud Compute as
/// the iOS 27 fallback once entitled) — see `RewriteClient`.
///
/// A second engine, "Writing Tools", used to sit beside it: it ran nothing in
/// Jot and instead taught the system selection-menu path ("select the text,
/// then Writing Tools"). Retired 2026-09-15 (owner direction: every Jot
/// control performs the rewrite itself). Installs that stored the old
/// `appleIntelligence` value simply resolve to `.jotAI`.
enum RewriteMode: String, CaseIterable, Sendable {
    case jotAI

    /// Always `.jotAI` — kept as a type so call sites read as "the engine".
    @MainActor
    static var current: RewriteMode { .jotAI }

    static func set(_ mode: RewriteMode) {
        AppGroup.defaults.set(mode.rawValue, forKey: AppGroup.Keys.rewriteMode)
    }
}
