import SwiftData
import SwiftUI
import UIKit
import os.log

private let rootLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "root")

/// The app shell — the thin root of the navigation tree (Step 2 of the
/// root-view decouple, `docs/decouple-root-view/design.md`).
///
/// `AppRootView` owns ONLY navigation: the `NavigationStack(path:)`, the
/// Router-driven modal sheets (Settings / Help / Ask), and the four
/// `navigationDestination` arms (hero, transcript-detail by UUID, the
/// keyboard-rewrite landing). The home content lives in `HomeScreen`, which is
/// just the stack's root view with no special privilege.
///
/// ## What stays here vs. moved to `HomeScreen`
///
/// The hero presentation machinery stays on the root: `heroIsPresented`, the
/// `pendingExternalKeyboardHero` binding, `reconcileHomeRecordingIndicator`, and
/// `presentExternalKeyboardHeroIfPending` — because the hero is presented via
/// `.navigationDestination(isPresented:)`, which must live on the view that owns
/// the `NavigationStack`. The hero presentation flag itself (`showRecordingHero`)
/// and its intent (`heroIntent`) now live on the `Router`; `HomeScreen` drives
/// the hero by flipping `router.showRecordingHero` / `router.heroIntent` (the FAB
/// / return-pill), and the root reads the same Router state here.
///
/// ## Single source of truth for the hero push
///
/// Both the FAB tap (in `HomeScreen`) and the URL-bounce auto-nav drive the
/// same `showRecordingHero` binding, which feeds the
/// `.navigationDestination(isPresented:)` modifier below. Routing both through
/// one binding makes a second push a no-op.
///
/// The auto-nav case fires when `JotApp.onOpenURL` handles
/// `jot://dictate?session=…` from the keyboard and starts the recording BEFORE
/// any in-app surface is presented.
///
/// ## Hero intent + binding (Bug E fix)
///
/// `@Environment(\.dismiss)` does not reliably pop a destination pushed via
/// `.navigationDestination(isPresented:)`; flipping the binding back to `false`
/// is what actually pops the stack. We pass a binding to `router.showRecordingHero`
/// into `RecordingHeroView` so it owns its own dismissal (stop, cancel, error,
/// stale-presentation pop) without relying on `dismiss()`. We also pass the
/// `router.heroIntent` so the hero can distinguish a *fresh* FAB tap (must call
/// `start()`) from an *adoption* (auto-nav: adopt a running session, or pop if
/// nothing is in flight).
struct ContentView: View {
    /// True while the setup wizard's fullScreenCover is presenting on top of the
    /// home view. Threaded down to `HomeScreen` (it owns the wizard-aware
    /// keyboard-dictate observer + suppresses the live-recording pill) and read
    /// here by the external-keyboard-hero present/reconcile guards.
    var isWizardPresented: Bool = false

    /// One-shot signal from `JotApp` that the next recording-start was
    /// triggered by a `jot://dictate*` URL bounce from a third-party keyboard.
    /// The root's auto-push reads + clears this so the Hero is presented with
    /// the `.openedFromExternalKeyboard` intent and the "Swipe back to your
    /// app" nudge overlay shows.
    @Binding var pendingExternalKeyboardHero: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(RecordingService.self) private var recordingService
    @Environment(KeyboardRewriteRouter.self) private var keyboardRewriteRouter
    /// App-owned navigation source of truth (Step 1 of the root-view decouple).
    /// Owns the three modal sheets (Settings / Help / Ask).
    @Environment(Router.self) private var router

    @State private var navPath = NavigationPath()

    /// "Ask Jot" sheet controller — natural-language Q&A over transcript history
    /// (Apple FM + MiniLM embeddings). Presentation lives on the Router
    /// (`router.showAskSheet`); the controller is held here because the Ask
    /// sheet is presented from the root.
    @State private var askController = AskController()
    /// Latched by Settings' "Re-run setup wizard" row before dismissing.
    /// We defer firing `SettingsRerunTrigger.requestRerun()` until SwiftUI
    /// reports the sheet has actually torn down (via `.sheet(onDismiss:)`),
    /// otherwise the wizard's fullScreenCover races the sheet dismiss
    /// animation and we hit the dual-modal "tried to present X on Y while Y
    /// is presenting Z" crash path.
    @State private var pendingRerunAfterDismiss = false

    /// True exactly while the recording hero is actually MOUNTED on screen,
    /// tracked by the hero's `.onAppear` / `.onDisappear` inside the
    /// `navigationDestination` closure below. `router.showRecordingHero` alone is
    /// NOT a reliable proxy for "the hero is on the nav stack": the iOS interactive
    /// swipe-back pops the hero via its `.onDisappear` safety net WITHOUT writing
    /// `router.showRecordingHero` back to `false` (it latches `dismissingViaBack`
    /// and bails to keep the recording alive — see `RecordingHeroView.onDisappear`).
    /// That leaves `router.showRecordingHero == true` while the hero is gone, which
    /// suppresses the home "Recording" return-pill (`isLiveRecordingInline`
    /// requires `!showRecordingHero`). The scenePhase reconciliation below uses
    /// THIS flag — the live mount truth — to detect and clear that desync.
    @State private var heroIsPresented = false

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeScreen(
                isWizardPresented: isWizardPresented,
                navPath: $navPath,
                pendingExternalKeyboardHero: $pendingExternalKeyboardHero
            )
            .navigationDestination(isPresented: Bindable(router).showRecordingHero) {
                RecordingHeroView(
                    showRecordingHero: Bindable(router).showRecordingHero,
                    intent: router.heroIntent
                )
                // Track the hero's true mount state so the scenePhase
                // reconciliation can tell a genuinely-presented hero from a
                // stuck `showRecordingHero` binding after a system swipe-back.
                .onAppear { heroIsPresented = true }
                .onDisappear { heroIsPresented = false }
            }
            .navigationDestination(for: UUID.self) { transcriptID in
                // Programmatic push for Recents row taps. We push the UUID rather
                // than the @Model object so navPath stays Hashable-safe and we
                // don't rely on SwiftData identity semantics inside NavigationPath.
                // Fetch the live model from the scene context at render time.
                if let transcript = fetchTranscript(byID: transcriptID) {
                    TranscriptDetailView(
                        transcript: transcript,
                        keyboardRewriteIntent: nil
                    )
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(for: KeyboardRewriteRouter.KeyboardRewriteTarget.self) { target in
                let fetched = fetchTranscript(byID: target.id)
                if let fetched {
                    TranscriptDetailView(
                        transcript: fetched,
                        keyboardRewriteIntent: target
                    )
                } else {
                    // Fetch miss: JotApp.handleRewriteURL already cleared
                    // pendingRewriteRequest and stamped rewriteJobID, so the
                    // keyboard's Darwin observer is waiting on a postCompleted
                    // that would otherwise never fire (60s timeout). Surface a
                    // terminal error so the keyboard unblocks immediately.
                    EmptyView()
                        .onAppear { releaseStrandedKeyboard(target: target) }
                }
            }
        }
        .enableInteractivePopGesture()
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: Bindable(router).showSettings, onDismiss: handleSettingsDismissed) {
            SettingsView(onRerunRequested: { pendingRerunAfterDismiss = true })
        }
        .sheet(isPresented: Bindable(router).showHelp) {
            // Wrapped in a NavigationStack so the editorial title bar has
            // a stack to attach to and future detail pushes (e.g. troubleshooting
            // → settings deeplinks) have somewhere to land.
            NavigationStack {
                HelpView(isModal: true)
            }
        }
        .sheet(isPresented: Bindable(router).showAskSheet) {
            // Ask-mode sheet — natural-language Q&A. Citation taps
            // dismiss this sheet and push into the same `navPath`
            // Recents uses, so Detail resolves through the existing
            // `.navigationDestination(for: UUID.self)` modifier above.
            //
            // The `askController` is intentionally PERSISTENT (not reset on
            // dismiss): closing Ask — e.g. tapping a source to read the note —
            // and reopening keeps the previous answer on screen, so the user can
            // pick up where they left off and tap "Ask another" when they want a
            // fresh session. Only the mic is released on close (AskView.onDisappear).
            AskView(controller: askController, navPath: $navPath)
        }
        .onAppear {
            // External-keyboard hero — FIRST-APPEAR re-check (cold process). The
            // keyboard's `jot://dictate` bounce set `pendingExternalKeyboardHero`
            // during launch, BEFORE this view's `.onChange` was installed, so a
            // freshly-launched process must re-check it here. The warm-process
            // case (app already alive in the background) is handled by the
            // `.onChange` below. Both call the SAME helper so cold and warm can
            // never diverge — see `presentExternalKeyboardHeroIfPending`.
            if let target = keyboardRewriteRouter.consumePending() {
                navPath.append(target)
            }
            presentExternalKeyboardHeroIfPending()
        }
        .onChange(of: keyboardRewriteRouter.pendingTarget) { _, newTarget in
            guard let newTarget else { return }
            navPath.append(newTarget)
            _ = keyboardRewriteRouter.consumePending()
        }
        .onChange(of: keyboardRewriteRouter.pendingOpenTranscriptID) { _, newID in
            guard let newID else { return }
            navPath.append(newID)
            _ = keyboardRewriteRouter.consumePendingOpenTranscript()
        }
        // External-keyboard hero — WARM-process path. The keyboard set the flag
        // via `jot://dictate` while Jot was already alive in the background (no
        // warm mic, so it had to open the app). Present the hero the instant the
        // URL signal lands, decoupled from whether the recording actually starts
        // (on a fresh install / update it can be deferred behind a cold speech-
        // model load). The hero enters its "getting ready" state and adopts once
        // recording begins, so the user is never stranded on home. Same helper as
        // the cold-process first-appear path — they must stay identical.
        .onChange(of: pendingExternalKeyboardHero) { _, _ in
            presentExternalKeyboardHeroIfPending()
        }
        // Hero reconciliation on scene re-activation. Surfaces an already-live
        // recording's return-pill when a stale UI flag stranded it (see
        // `reconcileHomeRecordingIndicator`). Donation-card / warm-hold-nudge
        // refreshes live in `HomeScreen` (their state is home-local).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Deferred one runloop hop: when the app foregrounds STRAIGHT
                // into a legitimately-presented hero (warm `jot://dictate`
                // resume, or a cold dictate that lands on the hero), SwiftUI
                // delivers this scenePhase `.active` change and the hero's
                // navigationDestination `.onAppear` in the same pass with no
                // guaranteed ordering. Running reconcile synchronously could see
                // `heroIsPresented == false` (onAppear pending) while
                // `showRecordingHero == true` and dismiss a hero the user is
                // actively viewing (clause (b)). Deferring lets the pending
                // `.onAppear` flip `heroIsPresented = true` first, so reconcile
                // only resets a GENUINELY desynced binding (swipe-back case).
                DispatchQueue.main.async { reconcileHomeRecordingIndicator() }
            }
        }
    }

    // MARK: - External-keyboard hero

    /// Presents the recording hero for a keyboard-originated launch — the ONLY
    /// way the keyboard pulls the user into Jot from another app. iOS won't let
    /// a keyboard extension start the mic, so when there's no warm mic the
    /// keyboard `jot://dictate`-bounces to open the app; that sets
    /// `pendingExternalKeyboardHero` (`JotApp.onOpenURL`). This presents the hero
    /// with `.openedFromExternalKeyboard`, which lights the swipe-back cue so the
    /// user knows to return to the app they were typing in.
    ///
    /// Single source of truth: BOTH the cold-process first-appear (`.onAppear`)
    /// and the warm-process flag flip (`.onChange`) call this, so the two process
    /// states can never diverge. Idempotent; guards are LIVE reads only (hero
    /// already up? wizard up?) — no provenance flags to keep in sync.
    private func presentExternalKeyboardHeroIfPending() {
        guard pendingExternalKeyboardHero,
              !router.showRecordingHero,
              !isWizardPresented else { return }
        pendingExternalKeyboardHero = false
        router.heroIntent = .openedFromExternalKeyboard
        router.showRecordingHero = true
    }

    /// Reconcile the home "Recording" return-pill against the live recording
    /// state when the scene becomes active. The pill (`isLiveRecordingInline`,
    /// in `HomeScreen`) is suppressed by two stale UI flags that a cold
    /// `jot://dictate` URL-bounce or a system swipe-back can strand, leaving an
    /// in-progress (keyboard-started) recording invisible on home:
    ///
    /// (a) `pendingExternalKeyboardHero` can stick `true`: it's cleared only in
    ///     the guarded present sites (`presentExternalKeyboardHeroIfPending`),
    ///     which early-return WITHOUT clearing if the hero/wizard is already up.
    ///     If neither a hero nor the wizard is presented, a still-pending flag is
    ///     stale — nothing will present from it — so clear it.
    ///
    /// (b) `showRecordingHero` can stay `true` after a system swipe-back: the
    ///     hero's `.onDisappear` safety net keeps the recording alive and latches
    ///     `dismissingViaBack` but never writes the binding back to `false`, so
    ///     the binding desyncs from the (now unmounted) hero. If we ARE recording
    ///     but the hero is genuinely NOT on screen (`!heroIsPresented`), reset the
    ///     desynced binding so the pill re-appears.
    ///
    /// This only SURFACES already-true `isRecording` state — it never presents the
    /// hero and never reintroduces the removed "adopt-unless-vetoed" model. The
    /// three source-based present triggers (FAB tap, cold `jot://dictate`,
    /// return-pill tap) are untouched.
    private func reconcileHomeRecordingIndicator() {
        // (a) Clear a stale external-keyboard-hero pending flag when nothing it
        // could present is on screen.
        if pendingExternalKeyboardHero, !router.showRecordingHero, !isWizardPresented {
            pendingExternalKeyboardHero = false
        }
        // (b) Reset a desynced hero binding so the pill re-surfaces for a live
        // recording whose hero was swipe-back-dismissed without writing back.
        if recordingService.isRecording, router.showRecordingHero, !heroIsPresented {
            router.showRecordingHero = false
        }
    }

    // MARK: - Settings sheet

    /// Fired by `.sheet(onDismiss:)` once SwiftUI has fully torn the
    /// Settings sheet down. Firing `requestRerun()` here (rather than from
    /// inside SettingsView after a `DispatchQueue.main.async`) is what
    /// prevents the wizard's fullScreenCover from racing the sheet
    /// dismiss animation.
    private func handleSettingsDismissed() {
        guard pendingRerunAfterDismiss else { return }
        pendingRerunAfterDismiss = false
        SettingsRerunTrigger.shared.requestRerun()
    }

    // MARK: - Transcript-detail fetch

    private func fetchTranscript(byID id: UUID) -> Transcript? {
        var descriptor = FetchDescriptor<Transcript>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Terminal-error write path for the keyboard-rewrite destination when
    /// the SwiftData fetch returns nil. Without this, the keyboard's Darwin
    /// observer waits up to `rewriteRoundTripTimeoutSeconds` (60s) before
    /// surfacing its own timeout. Guarded on `rewriteJobID == target.jobID`
    /// so a stale fetch-miss view doesn't clobber a newer job's slot.
    private func releaseStrandedKeyboard(target: KeyboardRewriteRouter.KeyboardRewriteTarget) {
        rootLog.error(
            "Keyboard rewrite target fetched nil transcript; releasing keyboard sessionID=\(target.sessionID, privacy: .public) jobID=\(target.jobID, privacy: .public) transcriptID=\(target.id, privacy: .public)"
        )
        // Whole terminal write must be guarded on jobID match — without
        // this, a stale `EmptyView().onAppear` from a transient fetch
        // miss can clobber the result slots of a NEWER job that's
        // already mid-flight. Drop silently when the slot has moved on.
        guard AppGroup.rewriteJobID == target.jobID else {
            rootLog.notice("releaseStrandedKeyboard: jobID slot moved on; skipping terminal write")
            return
        }
        AppGroup.rewriteError = "Couldn't open transcript."
        AppGroup.rewriteResult = nil
        AppGroup.rewriteResultSessionID = target.sessionID
        AppGroup.rewriteJobID = nil
        RewriteNotifications.postCompleted()
    }
}

#Preview {
    ContentView(pendingExternalKeyboardHero: .constant(false))
        .environment(RecordingService())
        .environment(KeyboardRewriteRouter())
        .environment(TranscriptionService())
        .environment(StreamingPartial())
        .environment(Router())
        .modelContainer(for: Transcript.self, inMemory: true)
}
