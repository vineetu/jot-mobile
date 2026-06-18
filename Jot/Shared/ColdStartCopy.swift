import Foundation

/// Copy + timing for the model **cold-start** affordance — the line shown
/// while the speech model is loading.
///
/// ## Why this exists
/// The speech model loads once per process. A **warm** load (already
/// specialised for the Neural Engine) finishes in ~1–2s and is normally
/// hidden entirely by the launch pre-warm, so the user never sees it. A
/// **cold** load — the first dictation after an App Store / TestFlight update,
/// when the ANE specialisation cache (keyed on the app's install path) is
/// invalidated — takes 30–40s.
///
/// We never want the brief warm load to flash an affordance. So the UI
/// **defers**: it shows the ordinary "Listening…" wait until a load has been
/// running past ``revealThreshold``; only a genuinely slow (cold) load crosses
/// it and reveals a line. Detection is purely "the load is taking long" — we
/// don't need to know the cause (update, eviction, low-power all qualify).
///
/// The line never names a model size/codename and never promises a duration
/// (a cold load can be 30s — "this is quick" would be a lie). It just states
/// what is happening right now.
///
/// ## Surfaces
/// The main app picks the line when a load begins (``beginningLine()``) and
/// writes it to `AppGroup.streamingLoadingVariantLabel`; the keyboard strip and
/// the recording hero both render that string. Only ``revealThreshold`` is read
/// cross-process by the keyboard — which is why this type lives in `Shared/`.
enum ColdStartCopy {

    /// Don't reveal the cold-start line until a load has run at least this long.
    /// A warm load resolves well before this, so it stays invisible — no flash.
    static let revealThreshold: TimeInterval = 2.5

    /// Shown the **first** time the model ever loads on this install — the
    /// genuine one-time setup, which coincides with the setup wizard. Single
    /// line, no rotation (you only ever see it once).
    static let firstEverLine = "This is the slow part. It’s the only slow part."

    /// Shown on every **later** cold load (post-update, eviction, low-power).
    /// Rotated so a returning user doesn't see the same line each time. Each one
    /// states what's happening right now — no promise of speed or accuracy.
    static let recurringLines = [
        "Just waking up the model — keep talking, I’m catching all of it.",
        "Spinning back up — your audio’s already recording.",
        "A moment to shake off the cobwebs.",
    ]

    private static let everLoadedKey = "jot.coldStart.modelEverLoaded"
    private static let rotationKey = "jot.coldStart.lineRotation"

    /// Pick the line for a cold load that is **beginning now**, advancing the
    /// rotation.
    ///
    /// The one-time **koan** (``firstEverLine`` — "This is the slow part. It's
    /// the only slow part.") is reserved EXCLUSIVELY for the setup wizard's W5
    /// step. It is returned ONLY when the wizard signals it is active via
    /// ``AppGroup/wizardActive``. The keyboard and the in-app recording hero —
    /// which also render the line this returns (written into
    /// `AppGroup.streamingLoadingVariantLabel`) — must NEVER show the koan, so
    /// outside the wizard this ALWAYS returns a rotating ``recurringLines``
    /// entry, regardless of whether the model has ever loaded before.
    ///
    /// The gate is `wizardActive`, NOT first-ever-load: a returning user who
    /// re-runs the wizard from Settings should see the koan again on W5, and a
    /// brand-new user whose very first load happens to be triggered outside the
    /// wizard (shouldn't normally happen, but defensively) must not see it.
    ///
    /// Called by the app only (not the keyboard). The `wizardActive` read uses
    /// the cross-process App-Group store so the same flag the wizard set is
    /// observed here.
    static func beginningLine(defaults: UserDefaults = .standard) -> String {
        if AppGroup.wizardActive {
            return firstEverLine
        }
        let index = defaults.integer(forKey: rotationKey)
        defaults.set(index + 1, forKey: rotationKey)
        return recurringLines[((index % recurringLines.count) + recurringLines.count) % recurringLines.count]
    }

    /// Mark that the model has now successfully loaded at least once, so future
    /// cold loads use the recurring (not first-ever) copy. Idempotent.
    static func markLoadedOnce(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: everLoadedKey)
    }
}
