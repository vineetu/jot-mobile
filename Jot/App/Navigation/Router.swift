import Observation

/// Why the hero is being presented. Determined at push time by whoever flips
/// `Router.showRecordingHero`; consumed by `RecordingHeroView.beginRecordingFlow`
/// to decide whether to `start()` a fresh recording (FAB tap) or adopt an
/// in-flight session (auto-nav from URL bounce / scene re-activation).
///
/// Defined here rather than on `ContentView` because it is now Router state — the
/// hero presentation flag (`showRecordingHero`) and its intent travel together as
/// the hero's navigation state (Step 1 hero slice of the root-view decouple,
/// `docs/decouple-root-view/design.md`).
enum HeroIntent {
    /// User tapped the FAB. If no recording is in flight, `start()` one.
    /// If somehow one already started (race), adopt it.
    case startRecording
    /// Auto-nav. If a recording is in flight, adopt it. If not, the
    /// presentation is stale and the hero should pop immediately
    /// (NEVER call `start()` from this path).
    case adoptInFlight
    /// The keyboard pulled the user into Jot from ANOTHER app. iOS won't let a
    /// keyboard extension start the mic, so with no warm mic the keyboard
    /// `jot://dictate`-bounces to open the app — which yanks the user out of the
    /// app they were typing in. This fires for that open whether the Jot process
    /// was stone-cold OR already alive in the background (warm process, expired
    /// warm mic) — it is NOT a process-lifecycle distinction, it's "we had to
    /// bring you here." Same lifecycle as `.adoptInFlight` (adopt the running
    /// session), but the hero also surfaces the looping `SwipeBackCardCue` (a
    /// wordless two-card app-switch demo) so the user knows to swipe back to the
    /// host where the auto-paste will land. Shown for the whole withhold window
    /// and loops until the live transcript reveals. NOT set by in-Jot starts (the
    /// FAB) — there's no other app to return to there.
    case openedFromExternalKeyboard
}

/// App-owned navigation source of truth (Step 1 of the root-view decouple,
/// `docs/decouple-root-view/design.md`).
///
/// The Router holds **navigation state only** — what screen/sheet is shown.
/// No business logic, no persistence, no cross-process state lives here. It is
/// deliberately low-churn (changes on navigation, never per-frame), which is
/// why it can be a single shared `@Observable` without recreating the god-view
/// that mixed low-churn navigation with high-churn volatile reads.
///
/// ## Scope of this first slice
///
/// Only the three modal **sheets** are migrated here: Settings, Help, and Ask.
/// They were three loose `@State` Bools on `ContentView`; folding them into the
/// Router is the low-risk part of Step 1 (no `reconcileHomeRecordingIndicator`
/// entanglement). The hero / nav-stack routes stay on `ContentView` for now
/// and move in a later, device-gated slice (design N4).
///
/// The three sheets stay modelled as independent Bools (rather than a single
/// `enum Sheet?`) so each `.sheet(isPresented:)` call site — in particular the
/// Settings sheet's `onDismiss` rerun-flow — keeps its exact presentation
/// semantics.
@Observable
final class Router {
    /// Drives the modal Settings sheet (home header gear).
    var showSettings = false

    /// Drives the modal Help sheet (home header "?"). Help is also reachable
    /// via Settings → ABOUT → "Help & Support" (a nav-push, not this sheet).
    var showHelp = false

    /// Drives the "Ask Jot" sheet (the sparkles pill next to search).
    var showAskSheet = false

    /// Drives the programmatic push to `RecordingHeroView` (the return-to-app /
    /// recording hero). Set by the FAB tap, the return-pill tap, and the
    /// external-keyboard bounce (`presentExternalKeyboardHeroIfPending`); fed into
    /// `ContentView`'s `.navigationDestination(isPresented:)`. The hero view also
    /// writes it back (via a binding) to pop itself on stop / cancel / error /
    /// stale-mount. Previously a loose `@State` on `ContentView`; relocated here
    /// alongside its intent (Step 1 hero slice — see `HeroIntent`).
    var showRecordingHero = false

    /// What the hero should do on mount. `.startRecording` is set by the FAB
    /// (fresh user action — must call `start()`); `.adoptInFlight` is set by the
    /// return pill and scene re-activation paths; `.openedFromExternalKeyboard`
    /// by the keyboard bounce. Defaulting to `.adoptInFlight` is the safe failure
    /// mode: a stray hero push without a configured intent pops back rather than
    /// spuriously starting a recording.
    var heroIntent: HeroIntent = .adoptInFlight
}
