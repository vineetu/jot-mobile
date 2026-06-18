import Foundation

/// Measures how long the streaming ASR model actually takes to load on THIS
/// device, so the "Loading …" hero can pace a calibrated progress bar instead
/// of an indeterminate spinner.
///
/// There is no real progress signal to read: FluidAudio's
/// `StreamingEouAsrManager.loadModels(from:)` is three sequential, opaque
/// `MLModel.load(contentsOf:)` calls (encoder → decoder → joint), and CoreML
/// exposes neither a percentage nor a callback for a model load or its
/// first-run ANE compile. So we can't show a TRUE percentage. What we CAN do is
/// time each load and use the device's own prior measurement to pace a
/// determinate bar next time — the bar eases toward (but never reaches) 100% on
/// the estimate and is snapped to done by the real `.ready` transition, so an
/// under-estimate never lies by completing early.
///
/// Cold vs warm. The first load after launch / reinstall / iOS evicting the ANE
/// cache recompiles the graph (tens of seconds on older devices); subsequent
/// warm loads are ~hundreds of ms. We can't observe an iOS cache eviction, but
/// "first load since this process launched" is a good cold proxy — so we keep
/// separate cold and warm estimates and pick by that in-memory flag.
///
/// Stored in the App Group so the keyboard extension (same "Loading …"
/// placeholder) can reuse the calibration later without re-measuring.
enum ModelLoadTimekeeper {
    /// Flips true after the first recorded load of this process lifetime.
    /// In-memory only (never persisted) — a fresh process means we should
    /// expect a cold load and pace against the cold estimate.
    nonisolated(unsafe) private static var didLoadThisLaunch = false

    private static func warmKey(_ variant: String) -> String { "jot.modelLoad.warm.\(variant)" }
    private static func coldKey(_ variant: String) -> String { "jot.modelLoad.cold.\(variant)" }

    /// Seconds to pace the progress bar against for the upcoming load. Picks
    /// the cold estimate on the first load of the process lifetime, the warm
    /// estimate after. Clamped so a pathological sample can't freeze the bar
    /// (too long) or make it rush then stall (too short).
    static func estimatedSeconds(variant: String) -> Double {
        let d = AppGroup.defaults
        let warm = d.object(forKey: warmKey(variant)) as? Double
        let cold = d.object(forKey: coldKey(variant)) as? Double
        let value: Double
        if !didLoadThisLaunch {
            // No cold sample yet → guess generously off the warm one (cold is
            // typically several × warm), else a conservative default. The
            // default is deliberately LARGE (46 s): a post-update cold load is
            // an ANE respecialization that runs tens of seconds (often >45 s on
            // the first launch after an update — see model-load-caching.md), so
            // we pace SLOWLY rather than rush the bar to the cap and stall. The
            // bar never completes on the estimate; the real `.ready` transition
            // removes it, so an over-estimate just means a calmer crawl that
            // hands off the instant the model is actually ready.
            value = cold ?? warm.map { $0 * 6 } ?? 46
        } else {
            value = warm ?? cold ?? 3
        }
        // Ceiling raised to 75 s so the 46 s cold default — and genuinely slow
        // cold recompiles on older devices — aren't clamped down into a bar
        // that rushes ahead of the real load.
        return min(max(value, 1.0), 75.0)
    }

    /// Record a completed load's wall-clock duration. Routes to the cold or
    /// warm bucket based on whether this was the first load of the process
    /// lifetime; EMA-smooths the warm bucket against run-to-run jitter.
    static func record(variant: String, seconds: Double) {
        defer { didLoadThisLaunch = true }
        guard seconds.isFinite, seconds > 0 else { return }
        let d = AppGroup.defaults
        if !didLoadThisLaunch {
            d.set(seconds, forKey: coldKey(variant))
        } else {
            let prev = d.object(forKey: warmKey(variant)) as? Double ?? seconds
            d.set(prev * 0.6 + seconds * 0.4, forKey: warmKey(variant))
        }
    }
}
