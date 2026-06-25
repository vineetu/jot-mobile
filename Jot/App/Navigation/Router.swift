import Observation

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
}
