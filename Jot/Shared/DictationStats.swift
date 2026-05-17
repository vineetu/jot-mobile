import Foundation

/// Cross-process dictation usage counter.
///
/// Tracks total completed dictations and cumulative recording duration in
/// the shared App Group so the keyboard extension's dictations count toward
/// the same totals as in-app dictations — without ever having to open the
/// main app. Both processes write through this helper; the main app reads
/// it to display the "X dictations · ~Yh saved" line in Settings → About
/// and to decide whether to render the home donation card.
///
/// **Why the App Group, not main-app-local storage?** A user who only ever
/// dictates from the keyboard (in another app's text field) would otherwise
/// never accumulate any stats — opening Jot.app would always read zeros.
/// Putting the counter in the shared container means the keyboard's silent
/// writes are visible to the app next time it foregrounds, without any IPC.
///
/// **No SwiftUI dependency.** This file lives in `Shared/` and ships in
/// both the main app and the keyboard target. Keep it Foundation-only.
/// The main-app-only SwiftUI integration (Observable wrapper, View) lives
/// in the App layer.
enum DictationStats {
    // MARK: - Storage keys

    private static let countKey = "jot.stats.dictationCount"
    private static let secondsKey = "jot.stats.dictationSeconds"
    private static let firstStatDateKey = "jot.stats.firstStatDate"
    private static let donationStateKey = "jot.stats.donationCardState"
    private static let perDaySecondsKey = "jot.stats.perDaySeconds"
    private static let perDayCountKey = "jot.stats.perDayCount"

    // MARK: - Tuning constants

    private static let sparklineWindowDays: Int = 14

    /// Cumulative dictation duration required before the home donation card
    /// is allowed to render. Set at 2 hours — high enough that someone
    /// reaching it has clearly made Jot a habit (a moderate user takes
    /// ~2 weeks, a casual user ~1 month), low enough that the bulk of
    /// real users actually see the card instead of it being aspirational.
    /// The earlier 10-hour figure was tuned for power users only and
    /// would have hidden the card from the casual majority.
    static let donationThresholdSeconds: TimeInterval = 2 * 60 * 60

    /// "Time saved over typing" multiplier applied to recorded duration for
    /// the Settings stats row. Speaking is ~150 WPM and unassisted typing
    /// is ~40 WPM; 2.5× sits in the defensible middle of that ratio. May
    /// be revisited later once we count actual transcribed words rather
    /// than recorded duration.
    static let timeSavedMultiplier: Double = 2.5

    /// Minimum days since the first dictation before the donation card is
    /// allowed to fire. Asking a first-week user who hasn't decided whether
    /// they're keeping the app is the Wikipedia-banner anti-pattern.
    static let donationCardMinDaysSinceFirstStat: Int = 7

    /// Upper sanity bound on a single dictation's recorded duration. iOS
    /// audio sessions can't run forever and the post-recording pipeline
    /// has its own ceilings; anything beyond 6h is almost certainly a
    /// clock skew or a logic bug and shouldn't pollute the counter.
    static let singleSessionCeilingSeconds: TimeInterval = 6 * 60 * 60

    // MARK: - Donation card lifecycle

    enum DonationCardState: String {
        /// Default — the card is allowed to render once thresholds are met.
        case unseen
        /// User tapped "Maybe later". Terminal for the foreseeable future
        /// (no cooldown re-fire in v1 — the threshold is high enough that
        /// reaching it twice would feel like nagging).
        case dismissed
        /// User tapped "See donations" — assumed to have donated (or at
        /// least seriously considered it). Optimistic transition; an
        /// unconditional don't-re-ask is friendlier than a webhook-backed
        /// confirmation that we don't have infrastructure for anyway.
        case donated
    }

    // MARK: - Accessors

    static var totalCount: Int {
        AppGroup.defaults.integer(forKey: countKey)
    }

    static var totalSeconds: TimeInterval {
        AppGroup.defaults.double(forKey: secondsKey)
    }

    /// Date of the very first recorded dictation. Lazily stamped on the
    /// first call to `record(durationSeconds:)`. Returns `nil` if no
    /// dictation has ever been recorded — callers should treat that as
    /// "the user is fresh, gate the donation card off".
    static var firstStatDate: Date? {
        AppGroup.defaults.object(forKey: firstStatDateKey) as? Date
    }

    static var donationCardState: DonationCardState {
        get {
            guard let raw = AppGroup.defaults.string(forKey: donationStateKey),
                  let state = DonationCardState(rawValue: raw) else {
                return .unseen
            }
            return state
        }
        set {
            AppGroup.defaults.set(newValue.rawValue, forKey: donationStateKey)
        }
    }

    /// Estimated time saved vs typing, in seconds. Honest, conservative
    /// (see `timeSavedMultiplier`).
    static var estimatedTimeSavedSeconds: TimeInterval {
        totalSeconds * timeSavedMultiplier
    }

    // MARK: - Per-day duration rollups

    /// Per-day rollups live in `DictationStats` as the single source of truth
    /// for the hero stat card, and are stored in the App Group so keyboard
    /// contributions show up automatically in the main app. The 14-day window
    /// matches the sparkline; `last14DaysSeconds` returns oldest-first values
    /// because left-to-right chart code can consume that order directly.
    static var todaySeconds: TimeInterval {
        let calendar = Calendar.current
        let todayKey = dateKey(for: Date(), calendar: calendar)
        return perDaySeconds(from: AppGroup.defaults)[todayKey] ?? 0
    }

    static var todayCount: Int {
        let calendar = Calendar.current
        let todayKey = dateKey(for: Date(), calendar: calendar)
        return perDayCounts(from: AppGroup.defaults)[todayKey] ?? 0
    }

    static var last14DaysSeconds: [TimeInterval] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let secondsByDay = perDaySeconds(from: AppGroup.defaults)
        return dayKeysEndingToday(today, calendar: calendar).map { key in
            secondsByDay[key] ?? 0
        }
    }

    // MARK: - Mutations

    /// Record a successfully completed dictation. Fire-and-forget — no
    /// async, no return — to match the call site inside the post-recording
    /// pipeline. Safe to call from any thread (UserDefaults is documented
    /// thread-safe).
    static func record(durationSeconds: TimeInterval) {
        guard durationSeconds > 0, durationSeconds < singleSessionCeilingSeconds else {
            return
        }
        let defaults = AppGroup.defaults
        let now = Date()
        let newCount = defaults.integer(forKey: countKey) + 1
        let newSeconds = defaults.double(forKey: secondsKey) + durationSeconds
        defaults.set(newCount, forKey: countKey)
        defaults.set(newSeconds, forKey: secondsKey)
        // Stamp the first-stat date once, the first time we cross 0 → 1.
        // Used by the donation card's 7-day grace gate.
        if defaults.object(forKey: firstStatDateKey) == nil {
            defaults.set(now, forKey: firstStatDateKey)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let todayKey = dateKey(for: today, calendar: calendar)
        var secondsByDay = perDaySeconds(from: defaults)
        var countsByDay = perDayCounts(from: defaults)
        secondsByDay[todayKey, default: 0] += durationSeconds
        countsByDay[todayKey, default: 0] += 1

        let keysToKeep = Set(dayKeysEndingToday(today, calendar: calendar))
        secondsByDay = secondsByDay.filter { keysToKeep.contains($0.key) }
        countsByDay = countsByDay.filter { keysToKeep.contains($0.key) }
        defaults.set(secondsByDay, forKey: perDaySecondsKey)
        defaults.set(countsByDay, forKey: perDayCountKey)
    }

    // MARK: - Donation card gating

    /// True when the home donation card should render. Three gates:
    /// 1. Card hasn't already been dismissed or marked as donated.
    /// 2. Cumulative dictation duration ≥ `donationThresholdSeconds`.
    /// 3. ≥ `donationCardMinDaysSinceFirstStat` days since the first
    ///    recorded dictation (so a heavy-bursting first-day user doesn't
    ///    get asked on day one).
    static var shouldShowDonationCard: Bool {
        guard donationCardState == .unseen else { return false }
        guard totalSeconds >= donationThresholdSeconds else { return false }
        guard let firstStat = firstStatDate else { return false }
        let calendar = Calendar.current
        let daysSinceFirstStat = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstStat),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        return daysSinceFirstStat >= donationCardMinDaysSinceFirstStat
    }

    private static func perDaySeconds(from defaults: UserDefaults) -> [String: Double] {
        guard let dictionary = defaults.dictionary(forKey: perDaySecondsKey) else {
            return [:]
        }
        return dictionary.reduce(into: [String: Double]()) { result, element in
            if let seconds = element.value as? Double {
                result[element.key] = seconds
            } else if let seconds = element.value as? NSNumber {
                result[element.key] = seconds.doubleValue
            }
        }
    }

    private static func perDayCounts(from defaults: UserDefaults) -> [String: Int] {
        guard let dictionary = defaults.dictionary(forKey: perDayCountKey) else {
            return [:]
        }
        return dictionary.reduce(into: [String: Int]()) { result, element in
            if let count = element.value as? Int {
                result[element.key] = count
            } else if let count = element.value as? NSNumber {
                result[element.key] = count.intValue
            }
        }
    }

    private static func dayKeysEndingToday(_ today: Date, calendar: Calendar) -> [String] {
        (0..<sparklineWindowDays).reversed().map { dayOffset in
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) ?? today
            return dateKey(for: day, calendar: calendar)
        }
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        return String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
    }
}
