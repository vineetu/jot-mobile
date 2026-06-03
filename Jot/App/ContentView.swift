import SwiftData
import SwiftUI
import UIKit
import os.log

private let contentLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "content")

/// Editorial home surface per Phase 3 of the UX overhaul.
///
/// ## What changed (vs. the prior `ContentView`)
///
/// The earlier home centered on an inline `RecorderBar` (big red mic button,
/// streaming preview, transcribing spinner) pinned to the bottom safe area.
/// Phase 3 (Mockup 07) replaces that with an editorial layout:
/// - Fraunces 38pt "Jot" headline + tiny daily-stat sub-line.
/// - Glass-circle Settings button top-right (modal `SettingsView`, unchanged).
/// - Search bar pill, UI-shell only (disabled in v1, see plan §5.1).
/// - Grouped transcript list (Today / Yesterday / Last 7 days / Older),
///   each row a mono timestamp + duration + body excerpt.
/// - Floating blue Dictate FAB centered above the safe area; tapping it
///   pushes `RecordingHeroView` onto the nav stack (the new full-screen
///   recording surface, Mockup 08), so recording happens off-home.
///
/// ## Why recording moved off-home
///
/// The prior surface had to host both the history list AND the recording
/// chrome, which forced compromises on both. The editorial mockup treats
/// home as a calm reading surface and recording as a dedicated focus state.
/// `RecordingHeroView` owns the start/stop pipeline now; this file no
/// longer touches `RecordingService.start()` / `stop()` directly.
///
/// ## Single source of truth for the hero push
///
/// Both the manual FAB tap and the URL-bounce auto-nav drive the same
/// `@State var showRecordingHero` binding, which feeds a
/// `.navigationDestination(isPresented:)` modifier on the nav stack.
/// The FAB was previously a `NavigationLink` that pushed independently;
/// keeping both paths active risked a double-push (FAB navigates, then
/// `isRecording` flips and the auto-nav binding pushes a second hero).
/// Routing both through one binding makes the second push a no-op.
///
/// The auto-nav case fires when `JotApp.onOpenURL` handles
/// `jot://dictate?session=…` from the keyboard and starts the recording
/// BEFORE any in-app surface is presented. Without the auto-nav, the user
/// would land on the home stack with the mic hot but no indicator, and a
/// FAB tap then would call `start()` a second time and throw
/// `.alreadyRunning`.
///
/// ## Why the auto-nav keys on `isRecording`, NOT `isPipelineInFlight`
///
/// `isPipelineInFlight` stays true through the post-stop tail
/// (`.transcribing` / `.cleaning`) — but that tail is a background
/// pipeline state, not a user-facing recording state. By the time the
/// pipeline is tailing, the user already pressed Stop in the hero
/// (which dismisses), so yanking them back to a "recording" UI mid-tail
/// would be confusing. The URL-bounce auto-start always transitions
/// through `.recording` first, so observing `isRecording` alone is
/// sufficient to catch every legitimate entry into a hot session.
///
/// ## Hero intent + binding (Bug E fix)
///
/// `@Environment(\.dismiss)` does not reliably pop a destination pushed via
/// `.navigationDestination(isPresented:)`; flipping the binding back to
/// `false` is what actually pops the stack. We pass `$showRecordingHero`
/// into `RecordingHeroView` so it owns its own dismissal (stop, cancel,
/// error, stale-presentation pop) without relying on `dismiss()`.
///
/// We also pass a `HeroIntent` so the hero can distinguish a *fresh* FAB
/// tap (must call `start()`) from an *adoption* (auto-nav: must adopt an
/// already-running session, or pop if nothing is in flight). Without this
/// distinction, an app re-entry that re-mounts the hero from a stale
/// `showRecordingHero == true` would either (a) start a brand-new
/// recording the user didn't ask for, or (b) leave the user stuck on the
/// hero with no live recording and a Stop button that throws.

/// Why the hero is being presented. Determined at push time by whoever
/// flips `showRecordingHero`; consumed by `RecordingHeroView.beginRecordingFlow`
/// to decide whether to call `start()` (fresh FAB tap) or adopt an
/// in-flight session (auto-nav from URL bounce / scene re-activation).
enum HeroIntent {
    /// User tapped the FAB. If no recording is in flight, `start()` one.
    /// If somehow one already started (race), adopt it.
    case startRecording
    /// Auto-nav. If a recording is in flight, adopt it. If not, the
    /// presentation is stale and the hero should pop immediately
    /// (NEVER call `start()` from this path).
    case adoptInFlight
    /// Auto-nav from a third-party keyboard URL bounce (cold-start path).
    /// Same lifecycle as `.adoptInFlight` — adopt the running session —
    /// but the hero also surfaces a temporary "Swipe back to your app"
    /// nudge overlay so the user knows to return to the host where the
    /// auto-paste will land. Suppressed after the user has seen it 7
    /// times via `jot.hero.coldStartNudgeShownCount`.
    case coldStartFromExternalKeyboard
}

struct ContentView: View {
    /// True while the setup wizard's fullScreenCover is presenting on top
    /// of the home view. The wizard owns its own recording UX during its
    /// lifetime — W6's mic test surfaces the live transcript inside the
    /// wizard panel itself. If we let the home view's `.onChange(of:
    /// recordingService.isRecording)` auto-push the hero while the
    /// wizard is up, we end up with a zombie hero sitting on the nav
    /// stack BEHIND the wizard: tap-stop in the wizard kills the
    /// recording but can't pop the hero (different nav scope), and the
    /// user lands on home post-dismissal with a "Listening" page that
    /// doesn't correspond to any actual capture.
    var isWizardPresented: Bool = false

    /// One-shot signal from `JotApp` that the next recording-start was
    /// triggered by a `jot://dictate*` URL bounce from a third-party
    /// keyboard. ContentView's auto-push reads + clears this so the Hero
    /// is presented with the `.coldStartFromExternalKeyboard` intent and
    /// the "Swipe back to your app" nudge overlay shows.
    @Binding var pendingColdStartHeroNudge: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(RecordingService.self) private var recordingService
    @Environment(KeyboardRewriteRouter.self) private var keyboardRewriteRouter
    @Environment(StreamingPartial.self) private var streamingPartial

    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    @State private var navPath = NavigationPath()
    @State private var searchText = ""
    /// Semantic-search controller driving the "meaning" half of the
    /// hybrid Recents filter. Substring matching still happens inline
    /// in `filteredTranscripts`; this controller publishes the set of
    /// transcript IDs whose embedding cosine ≥ 0.50 to the query.
    @State private var semanticSearch = SemanticSearchController()

    /// "Ask Jot" sheet — natural-language Q&A over transcript history
    /// (Apple FM + MiniLM embeddings). See `docs/plans/ask-mode.md`.
    @State private var showAskSheet = false
    @State private var askController = AskController()
    /// Whether the Ask entry point (the sparkles pill) is shown. Gated on
    /// the on-board Qwen weights being *downloaded* (on disk) — not loaded
    /// into memory — so Ask only appears once the user has a capable
    /// on-device model. Re-evaluated on appear and whenever the Settings
    /// sheet (where the download happens) is dismissed.
    @State private var askAvailable = AskController.isAvailable
    @State private var showSettings = false
    /// Drives the modal Help sheet from the home header's "?" glass-circle
    /// button. Help is also reachable via Settings → ABOUT → "Help & Support"
    /// (nav-push); the sheet entry from home keeps the discovery cheap for
    /// new users who haven't opened Settings yet.
    @State private var showHelp = false
    /// Latched by Settings' "Re-run setup wizard" row before dismissing.
    /// We defer firing `SettingsRerunTrigger.requestRerun()` until SwiftUI
    /// reports the sheet has actually torn down (via `.sheet(onDismiss:)`),
    /// otherwise the wizard's fullScreenCover races the sheet dismiss
    /// animation and we hit the dual-modal "tried to present X on Y while Y
    /// is presenting Z" crash path.
    @State private var pendingRerunAfterDismiss = false
    @State private var pendingDeletion: Transcript?
    @State private var isSelectionMode = false
    @State private var selectedTranscriptIDs: Set<UUID> = []
    @State private var pendingBulkDeletionIDs: Set<UUID> = []
    /// Surfaces the "Combine N entries?" confirmation when the user taps
    /// Combine in the selection toolbar. Non-empty = sheet visible. Cleared
    /// when the user picks an option or cancels.
    @State private var pendingCombineIDs: Set<UUID> = []
    @State private var copiedTranscriptID: UUID?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var selectionHaptic = UISelectionFeedbackGenerator()
    /// Drives the programmatic push to `RecordingHeroView` when a recording
    /// is in flight that this surface didn't start (URL-bounce case). Bound
    /// via `.navigationDestination(isPresented:)`; cleared when recording
    /// AND the pipeline tail both fall idle so the next URL-bounce can fire
    /// it again. The hero view also writes to this binding (passed in as
    /// `@Binding`) to pop itself on stop / cancel / error / stale-mount.
    @State private var showRecordingHero = false
    /// Set to true when the user taps the back chevron on the hero while a
    /// recording is in progress. While this is true the auto-push observers
    /// (`onAppear` and `onChange(of: isRecording)`) skip pushing the hero
    /// even though `isRecording == true`, so the user can stay on home with
    /// the recording running. Cleared automatically when the recording ends,
    /// or when the user taps the home "return to recording" pill.
    /// Currently written by the hero back-out (`onBackgrounded`) and reset in
    /// the recording-teardown observers, but no longer READ — the home pill was
    /// rekeyed off `pendingColdStartHeroNudge` in unify-keyboard-dictation §5
    /// Stage 1. Retained pending Stage 4 cleanup; `@State` stored properties do
    /// not warn when written-but-unread, so this compiles clean.
    @State private var userDismissedHeroDuringRecording = false
    /// Mirrors `DictationStats.shouldShowDonationCard` into a SwiftUI-watchable
    /// flag. Re-evaluated on `onAppear` and on every transition to `.active`
    /// scene phase — that covers (a) a fresh app launch, (b) returning to
    /// home after the recording hero pops, and (c) returning from background
    /// after the keyboard incremented the counter in another app. The
    /// `DictationStats` state machine itself stays the source of truth; this
    /// flag is just a cache that lets the body invalidate cleanly.
    @State private var donationCardVisible: Bool = false
    /// What the hero should do on mount. `.startRecording` is set by the FAB
    /// (fresh user action — must call `start()`); `.adoptInFlight` is set by
    /// every auto-nav path (URL bounce, scene re-activation) and tells the
    /// hero to adopt any running session or pop back if nothing is running.
    /// Defaulting to `.adoptInFlight` is the safe failure mode: if some
    /// future code path pushes the hero without configuring `heroIntent`,
    /// we'd rather pop back than spuriously start a recording.
    @State private var heroIntent: HeroIntent = .adoptInFlight

    /// WS-B unified receiver for the keyboard's Dictate-tap while Jot is
    /// foreground and the wizard is NOT presented (§9 R5). Routes the tap to an
    /// `InlineDictationSession` bound to whatever editable surface registered
    /// itself as the focused inline target (Edit). The wizard keeps its own
    /// observer + behavior; this receiver's observer bails while the wizard is
    /// up, so the two never double-fire on the same Darwin name. Constructed
    /// with the shared transcription service so inline dictation transcribes the
    /// same way the pipeline does (but saves no transcript).
    @State private var inlineReceiver = InlineDictationReceiver(
        transcribe: { samples in
            try await TranscriptionService.shared.transcribe(samples: samples)
        }
    )
    /// Darwin observer for the keyboard-dictate tap, installed only while the
    /// wizard is NOT presented (the wizard owns its own observer during its
    /// lifetime — see `SetupWizardView`). Re-installed / torn down by the
    /// `isWizardPresented`-aware `.onChange` + `.onAppear` below.
    @State private var dictateTapObserver: CrossProcessNotification.Observer?
    /// Sibling of `dictateTapObserver`: routes a keyboard `stopRequested` to the
    /// inline receiver so an inline dictation's STOP finalizes inline (no saved
    /// transcript) instead of falling through to the capture pipeline. Installed
    /// and torn down in lock-step with `dictateTapObserver`.
    @State private var inlineStopObserver: CrossProcessNotification.Observer?

    /// WS-F: home-side mirror of `AppGroup.warmHoldNudgeShouldShow`. The app's
    /// streak math (RecordingService, at the clean `stop()` site) flips that
    /// projection and posts `warmHoldNudgeChanged`; we cache it into this
    /// SwiftUI-watchable flag so `WarmHoldNudgeView` can render after a
    /// qualifying record-and-bounce burst that ended on home. Re-read on appear,
    /// on `.active`, and on the cross-process notification.
    @State private var warmHoldNudgeVisible = false
    /// Darwin observer for the warm-hold switching-nudge projection flip.
    @State private var warmHoldNudgeObserver: CrossProcessNotification.Observer?

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .bottom) {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGapV09) {
                        RecentsNavBar(
                            isSelectionMode: isSelectionMode,
                            onSettings: { showSettings = true },
                            onHelp: { showHelp = true },
                            onCancelSelection: exitSelectionMode
                        )

                        heroTitle

                        HStack(spacing: 8) {
                            searchBar
                                .onChange(of: searchText) { _, new in
                                    semanticSearch.search(query: new)
                                }
                            if askAvailable {
                                askPill
                            }
                        }

                        if donationCardVisible {
                            DonationCard(
                                onDismiss: handleDonationCardDismiss,
                                onSeeDonations: handleDonationCardOpen
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // WS-F: the warm-hold switching nudge. Surfaces here when
                        // the record-and-bounce streak crossed threshold and the
                        // burst ended on home (the app set the projection). The
                        // view owns its own state writes + cross-process post; we
                        // just drop it from the tree on resolve.
                        if warmHoldNudgeVisible {
                            WarmHoldNudgeView(onResolve: { warmHoldNudgeVisible = false })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        RecentsListCard(
                            transcripts: transcripts,
                            groups: transcriptGroups,
                            isSearching: !searchText.isEmpty,
                            copiedTranscriptID: copiedTranscriptID,
                            isSelectionMode: $isSelectionMode,
                            selectedTranscriptIDs: $selectedTranscriptIDs,
                            navPath: $navPath,
                            onCopy: copy,
                            // Swipe-Delete deletes immediately — the swipe-reveal +
                            // tap is already deliberate, so the extra confirmation
                            // dialog was redundant (user request). Bulk delete and
                            // combine keep their confirmations.
                            onDelete: { delete($0) },
                            onEnterSelectionMode: { enterSelectionMode(selecting: $0) }
                        )
                    }
                    .padding(.horizontal, JotDesign.Spacing.pageGutter)
                    .padding(.top, 8)
                    // Leave room at the bottom so the FAB doesn't obscure the
                    // last row of transcripts. FAB pill height (64pt) + bottom
                    // safe-area margin + breathing room.
                    .padding(.bottom, 120)
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)

                // Bottom action zone: selection mode owns the toolbar. Otherwise,
                // while a recording is running with the hero dismissed, swap the
                // FAB for a "return to recording" pill. This is the only re-entry
                // path for a user-backgrounded recording, so it has to stay
                // obvious. Suppressed while the wizard is presenting — W6's mic
                // test sets `isRecording == true` and we don't want a stray pill
                // leaking through the wizard overlay or driving a stale timer.
                //
                // The pill now surfaces for ANY live recording while home is
                // showing (so the FAB never reads "Start" while something is
                // recording), EXCEPT the cold-start-about-to-present window:
                // on a `jot://dictate` cold launch, `isRecording` flips true
                // before `.onAppear` / `.onChange` pushes the hero; while
                // `pendingColdStartHeroNudge` is still pending the pill would
                // flash for one frame in that gap, so we suppress it there
                // (see `isLiveRecordingInline`).
                if isSelectionMode {
                    recentsSelectionToolbar
                        .padding(.horizontal, JotDesign.Spacing.pageGutter)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if isLiveRecordingInline {
                    RecordingReturnPill {
                        // Re-enter the hero. Clear the dismissal flag so the
                        // next back-tap arms it fresh, and adopt the running
                        // session rather than `start()`-ing a second one.
                        userDismissedHeroDuringRecording = false
                        heroIntent = .adoptInFlight
                        showRecordingHero = true
                    }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    DictateFAB {
                        // Fresh user action: tell the hero to actually start a
                        // recording. Set intent BEFORE flipping the binding so
                        // the hero's `.onAppear` reads the right value.
                        heroIntent = .startRecording
                        showRecordingHero = true
                    }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Floating selection-Cancel: pinned to the top so it's reachable
            // anywhere in a long list (the in-header Cancel scrolled away). Glass
            // so the list reads through it.
            .overlay(alignment: .topTrailing) {
                if isSelectionMode {
                    floatingCancelButton
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: recordingService.isRecording)
            .animation(.easeInOut(duration: 0.25), value: showRecordingHero)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSelectionMode)
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showRecordingHero) {
                RecordingHeroView(
                    showRecordingHero: $showRecordingHero,
                    onBackgrounded: {
                        userDismissedHeroDuringRecording = true
                    },
                    intent: heroIntent
                )
            }
            .navigationDestination(for: UUID.self) { transcriptID in
                // Programmatic push for Recents row taps. We push the UUID rather
                // than the @Model object so navPath stays Hashable-safe and we
                // don't rely on SwiftData identity semantics inside NavigationPath.
                // Fetch the live model from the @Query result at render time.
                if let transcript = transcripts.first(where: { $0.id == transcriptID }) {
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
        // WS-B: make the unified inline receiver reachable by any editable
        // surface (Edit) so it can register itself as the focused target.
        .environment(inlineReceiver)
        // Install / tear down the keyboard-dictate observer in lockstep with the
        // wizard. While the wizard is up it owns the tap (W5); the moment it's
        // down the unified receiver takes over. Identity-checked Observer means
        // re-installing is idempotent.
        .onChange(of: isWizardPresented) { _, wizardUp in
            updateDictateTapObserver(wizardPresented: wizardUp)
        }
        .sheet(isPresented: $showSettings, onDismiss: handleSettingsDismissed) {
            SettingsView(onRerunRequested: { pendingRerunAfterDismiss = true })
        }
        .sheet(isPresented: $showHelp) {
            // Wrapped in a NavigationStack so the editorial title bar has
            // a stack to attach to and future detail pushes (e.g. troubleshooting
            // → settings deeplinks) have somewhere to land.
            NavigationStack {
                HelpView(isModal: true)
            }
        }
        .sheet(isPresented: $showAskSheet) {
            // Ask-mode sheet — natural-language Q&A. Citation taps
            // dismiss this sheet and push into the same `navPath`
            // Recents uses, so Detail resolves through the existing
            // `.navigationDestination(for: UUID.self)` modifier above.
            AskView(controller: askController, navPath: $navPath)
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { transcript in
            Button("Delete", role: .destructive) {
                delete(transcript)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        }
        .alert(
            "Delete \(pendingBulkDeletionIDs.count) items?",
            isPresented: Binding(
                get: { !pendingBulkDeletionIDs.isEmpty },
                set: { if !$0 { pendingBulkDeletionIDs = [] } }
            )
        ) {
            Button("Delete \(pendingBulkDeletionIDs.count)", role: .destructive) {
                deleteSelectedTranscripts(ids: pendingBulkDeletionIDs)
            }
            Button("Cancel", role: .cancel) {
                pendingBulkDeletionIDs = []
            }
        }
        .confirmationDialog(
            "Combine \(pendingCombineIDs.count) entries?",
            isPresented: Binding(
                get: { !pendingCombineIDs.isEmpty },
                set: { if !$0 { pendingCombineIDs = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Combine and delete originals", role: .destructive) {
                let ids = pendingCombineIDs
                pendingCombineIDs = []
                combineSelectedTranscripts(ids: ids, deleteOriginals: true)
            }
            Button("Combine and keep originals") {
                let ids = pendingCombineIDs
                pendingCombineIDs = []
                combineSelectedTranscripts(ids: ids, deleteOriginals: false)
            }
            Button("Cancel", role: .cancel) {
                pendingCombineIDs = []
            }
        } message: {
            Text("Originals are joined in chronological order with paragraph breaks. Any prior rewrites are dropped.")
        }
        .onAppear {
            copyHaptic.prepare()
            selectionHaptic.prepare()
            refreshDonationCardVisibility()
            askAvailable = AskController.isAvailable
            // WS-B: arm the unified keyboard-dictate observer unless the wizard
            // is currently presenting (it owns the tap then).
            updateDictateTapObserver(wizardPresented: isWizardPresented)
            // WS-F: arm the warm-hold-nudge projection observer + read the
            // current state (a qualifying burst may have crossed threshold while
            // we were backgrounded).
            if warmHoldNudgeObserver == nil {
                warmHoldNudgeObserver = CrossProcessNotification.addObserver(
                    name: CrossProcessNotification.warmHoldNudgeChanged
                ) {
                    refreshWarmHoldNudge()
                }
            }
            refreshWarmHoldNudge()
            if let target = keyboardRewriteRouter.consumePending() {
                navPath.append(target)
            }
            // Cold-launch hero (SOURCE-BASED — the only first-appear hero path).
            // The keyboard's `jot://dictate` bounce set `pendingColdStartHeroNudge`
            // during launch, BEFORE this view's `.onChange` was installed, so a
            // freshly-launched process must re-check it here. The hero is presented
            // because a COLD keyboard dictate explicitly asked for it — NOT because
            // `isRecording` happened to flip. Inline / Ask / warm / Action-Button
            // recordings never set this flag, so they can never reach the hero.
            // Guards are LIVE reads only (is a hero already up? is the wizard up?) —
            // no provenance flags to keep in sync.
            if pendingColdStartHeroNudge,
               !showRecordingHero,
               !isWizardPresented {
                pendingColdStartHeroNudge = false
                userDismissedHeroDuringRecording = false
                heroIntent = .coldStartFromExternalKeyboard
                showRecordingHero = true
            }
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
        .onDisappear {
            copyResetTask?.cancel()
        }
        // Cold keyboard-dictate just initiated (the keyboard set this flag via
        // jot://dictate while Jot was already alive in the background). This is
        // the SOLE cold-hero trigger for a warm process — present the hero NOW,
        // the instant the URL signal lands, decoupled from whether the recording
        // actually starts (on a fresh install / update it can be deferred behind
        // a cold speech-model load). The hero enters its "getting ready" state
        // and adopts once recording begins, so the user is never stranded on home.
        // Guards are LIVE reads only — no provenance flags.
        .onChange(of: pendingColdStartHeroNudge) { _, pending in
            guard pending, !showRecordingHero, !isWizardPresented else { return }
            pendingColdStartHeroNudge = false
            userDismissedHeroDuringRecording = false
            heroIntent = .coldStartFromExternalKeyboard
            showRecordingHero = true
        }
        // Hero TEARDOWN only. The hero is never *pushed* from `isRecording`
        // anymore (source-based presentation lives at the FAB tap, the cold
        // `jot://dictate` URL, and the return-pill tap). This observer just
        // handles the end-of-recording reset: a recording that was *not* a hero
        // recording (inline edit, Ask, warm, Action Button, the wizard mic test)
        // simply never had a hero to begin with, so there is nothing to adopt
        // and nothing to suppress — the whole veto-flag stack is gone.
        .onChange(of: recordingService.isRecording) { _, isRecording in
            guard !isRecording else { return }
            // Recording ended (stopped, cancelled, errored, or pipeline done).
            // Re-arm the hero back-out flag so the next hero recording presents
            // cleanly, and re-check the donation-card threshold for the user
            // landing back on home.
            userDismissedHeroDuringRecording = false
            refreshDonationCardVisibility()
        }
        // Keyboard Dictate tapped inside Jot, but no editable field is a
        // registered inline target (Send Feedback, search, prompt editor, …).
        // Never leave it a silent dead tap — fall back to a hero recording. The
        // keyboard tap is the source/trigger (source-based, no flag mirroring).
        .onChange(of: inlineReceiver.heroFallbackRequest) { _, _ in
            guard !showRecordingHero, !isWizardPresented else { return }
            heroIntent = .startRecording
            showRecordingHero = true
        }
        // Keyboard dictations increment the stats counter from another
        // process without ever opening Jot.app. When the user returns to
        // the app, re-evaluate donation card visibility so the threshold
        // crossing is reflected.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshDonationCardVisibility()
                refreshWarmHoldNudge()
            } else if phase == .background {
                // WS-B R6: an inline session backgrounded mid-dictation must not
                // leak a live recording. Discard rather than finalize — home has
                // no "preserve my words" field of its own (Edit handles its own
                // app-background terminal). Wizard-presented state is irrelevant
                // here: our observer is already torn down then.
                inlineReceiver.discardActive()
            }
        }
        .onChange(of: visibleTranscriptIDs) { _, visibleIDs in
            selectedTranscriptIDs.formIntersection(visibleIDs)
        }
    }

    // MARK: - Recording state

    /// True for ANY live recording while home is showing — the moment to swap
    /// the FAB for the blue "Return to recording" pill so the FAB never reads
    /// "Start" while something is recording. Tapping the pill opens the hero,
    /// which adopts whatever recording is in flight. We deliberately do NOT
    /// gate on how the recording started (`userDismissedHeroDuringRecording`,
    /// the old narrow "backgrounded hero" key, was dropped in
    /// unify-keyboard-dictation §5 Stage 1).
    ///
    /// One exception — the cold-start-about-to-present window: on a
    /// `jot://dictate` cold launch, `isRecording` flips true *before*
    /// `.onAppear` / `.onChange` pushes the hero. While
    /// `pendingColdStartHeroNudge` is still pending (not yet consumed) the
    /// pill would flash for a single frame in that gap, so suppress it there.
    /// Wizard stays suppressed too (its mic test owns its own surface).
    ///
    /// Also excludes `ownsActiveRecording` recordings: Ask owns its own
    /// `InlineDictationSession` and has its own in-sheet UI, and its `discard()`
    /// teardown is async — without this guard, dismissing the Ask sheet leaves a
    /// brief window where home is visible with `isRecording` still true, flashing
    /// a stray pill. Normal in-Jot captures and warm-resume do NOT set this flag,
    /// so they still surface the pill as intended.
    private var isLiveRecordingInline: Bool {
        recordingService.isRecording
            && !recordingService.ownsActiveRecording
            && !showRecordingHero
            && !isWizardPresented
            && !pendingColdStartHeroNudge
    }

    // MARK: - WS-B unified keyboard-dictate receiver

    /// Install or tear down the `keyboardDictateTapped` observer so it is live
    /// exactly when the wizard is NOT presented. The wizard installs its OWN
    /// observer for its lifetime (W5); running both at once would double-handle
    /// a single tap. When the wizard is down we route the tap into the unified
    /// receiver (inline dictation into the focused field, §9 R5). When the
    /// wizard comes up we drop our observer AND discard any inline session in
    /// flight so it never leaks behind the wizard.
    private func updateDictateTapObserver(wizardPresented: Bool) {
        if wizardPresented {
            dictateTapObserver = nil
            inlineStopObserver = nil
            inlineReceiver.discardActive()
        } else if dictateTapObserver == nil {
            let receiver = inlineReceiver
            dictateTapObserver = CrossProcessNotification.addObserver(
                name: CrossProcessNotification.keyboardDictateTapped
            ) {
                // NEW MODEL (unify-keyboard-dictation §6 / Stage 2): an in-Jot
                // keyboard Dictate tap starts a NORMAL background capture — the
                // exact same path as dictation from any other app — instead of
                // routing to the custom inline session. No hero is presented
                // (nothing adopts `isRecording`; the hero presents only from the
                // FAB, a cold `jot://dictate`, or the return pill). The keyboard
                // shows its own streaming strip via the cross-process projection,
                // and on Stop the keyboard's pending-paste → `insertText`
                // mechanism lands the final text in the focused Jot field. Save /
                // no-save is decided at the STOP site (foreground → no save), not
                // here. Modeled on JotApp's warm-resume observer's `start()`.
                Task { @MainActor in
                    let recording = RecordingService.shared
                    // Don't start over a prior dictation's tail — a second tap
                    // arriving while the recorder is busy would either throw
                    // `.alreadyRunning` or stack a second capture.
                    guard !recording.isRecording, !recording.isPipelineInFlight else {
                        contentLog.notice("keyboardDictateTapped (in-Jot) while recorder busy; ignoring")
                        return
                    }
                    do {
                        contentLog.notice("RECORDING START FROM: ContentView.keyboardDictateTapped (in-Jot keyboard tap)")
                        let startedAt = Date()
                        try await recording.start()
                        // Seed the activity coordinator's start anchor so any
                        // later hero adoption reads THIS recording's start time
                        // (mirrors the warm-resume observer in JotApp.init).
                        await DictationActivityCoordinator.shared.start(startedAt: startedAt)
                    } catch {
                        contentLog.error("keyboardDictateTapped (in-Jot) start failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            // An inline session's STOP arrives as `stopRequested` (the keyboard
            // can't tell inline from capture). Finalize it inline here; JotApp's
            // own `stopRequested` handler bails when an inline session owns the
            // recording, so the two never both act on it.
            inlineStopObserver = CrossProcessNotification.addObserver(
                name: CrossProcessNotification.stopRequested
            ) {
                receiver.handleExternalStop()
            }
        }
    }

    // MARK: - WS-F warm-hold switching nudge

    /// Re-read the App-Group projection and update the SwiftUI-watchable flag.
    /// Shows only when the app set `warmHoldNudgeShouldShow` AND the user hasn't
    /// permanently suppressed it (`WarmHoldNudgeView` writes suppression on the
    /// "Don't show again" tap). Cheap UserDefaults reads — fine to call from
    /// every entry point. Animated so it eases in rather than snapping.
    private func refreshWarmHoldNudge() {
        let next = AppGroup.warmHoldNudgeShouldShow && !AppGroup.warmHoldNudgeSuppressed
        guard next != warmHoldNudgeVisible else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            warmHoldNudgeVisible = next
        }
    }

    // MARK: - Hero

    /// WS-E: the editorial "Recents." headline is replaced by a rotating CTA
    /// that doubles as the home micro-messaging surface (§9 home CTA pool, D2 —
    /// both `.anywhere` and `.universal` lines shown to everyone this cycle).
    /// "What do you want to dictate today?" is the anchor line; the rotator
    /// shuffles the full pool. The date sub-line is retained for context.
    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            RotatingMessageView(
                messages: Self.homeCTAPool,
                dwell: 14,
                sequenced: false,
                font: JotType.displaySerif(34),
                color: .jotPageInk,
                alignment: .leading
            )
            .tracking(-1.0)
            .accessibilityAddTraits(.isHeader)

            Text(formattedDate)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
    }

    /// Home CTA rotation pool (§9 — `.anywhere` + `.universal`, D2 resolved:
    /// show both buckets to everyone in v1). Line 6 is the anchor.
    private static let homeCTAPool: [String] = [
        "Speak it straight into your app.",
        "Your keyboard can talk — anywhere you type.",
        "Skip the typing. Dictate into any app you're in.",
        "A thought mid-run? Jot it on your watch.",
        "Dictate into Mail, Notes, Messages — anywhere a keyboard goes.",
        "What do you want to dictate today?",
        "Say it out loud and let your hands rest.",
        "Think out loud — no need to slow down.",
        "Talk faster than you type. Start here.",
        "Say the messy version — tidy the wording later."
    ]

    private var formattedDate: String {
        Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    // MARK: - Search

    /// Live local search over the transcript list. Filtering happens entirely
    /// in-memory against `transcripts` from the @Query — no SwiftData
    /// predicate work and no debounce needed at the typical history size.
    /// We match against `displayText` AND raw `text` so a query like
    /// "remember the milk" still hits an entry whose cleaned variant
    /// dropped the verb.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search transcripts")
                    .foregroundStyle(Color.jotPageInkSecondary)
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.jotPageInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .accessibilityLabel("Search transcripts")
    }

    /// Companion to the search bar — opens Ask mode (natural-language
    /// Q&A over transcript history via Apple Foundation Models +
    /// MiniLM embeddings). Single 44×44 glass-circle button with a
    /// sparkles glyph so the affordance reads as "AI-powered" without
    /// stealing visual weight from search.
    private var askPill: some View {
        Button {
            showAskSheet = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotBlueBottom)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Jot")
        .accessibilityHint("Ask a natural-language question about your transcript history.")
    }

    // MARK: - Grouping

    /// Source of truth for what gets rendered in the grouped list.
    /// Hybrid filter (build 53): a transcript matches if it's a literal
    /// substring hit OR if `SemanticSearchController` has classified it
    /// as semantically similar to the query (cosine ≥ 0.50).
    /// Substring hits surface immediately on keystroke; semantic hits
    /// fill in ~250-400ms later after the debounce + embed + cosine
    /// pass completes. Date-grouping downstream preserves chronological
    /// ordering regardless of match source.
    private var filteredTranscripts: [Transcript] {
        guard !searchText.isEmpty else { return transcripts }
        let semanticIDs = semanticSearch.semanticMatches
        return transcripts.filter { transcript in
            let substring = transcript.displayText.localizedCaseInsensitiveContains(searchText)
                || transcript.text.localizedCaseInsensitiveContains(searchText)
            return substring || semanticIDs.contains(transcript.id)
        }
    }

    private var transcriptGroups: [RecentsTranscriptGroup] {
        let calendar = Calendar.current
        let now = Date()
        guard let startOfToday = calendar.dateInterval(of: .day, for: now)?.start
        else { return [] }
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
        let startOfLast7 = calendar.date(byAdding: .day, value: -7, to: startOfToday)

        var today: [Transcript] = []
        var yesterday: [Transcript] = []
        var lastWeek: [Transcript] = []
        var older: [Transcript] = []

        for transcript in filteredTranscripts {
            let createdAt = transcript.createdAt
            if createdAt >= startOfToday {
                today.append(transcript)
            } else if let startOfYesterday, createdAt >= startOfYesterday {
                yesterday.append(transcript)
            } else if let startOfLast7, createdAt >= startOfLast7 {
                lastWeek.append(transcript)
            } else {
                older.append(transcript)
            }
        }

        var groups: [RecentsTranscriptGroup] = []
        if !today.isEmpty { groups.append(.init(title: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: "Yesterday", items: yesterday)) }
        if !lastWeek.isEmpty { groups.append(.init(title: "Last 7 days", items: lastWeek)) }
        if !older.isEmpty { groups.append(.init(title: "Earlier", items: older)) }
        return groups
    }

    private var visibleTranscriptIDs: Set<UUID> {
        Set(transcriptGroups.flatMap(\.items).map(\.id))
    }

    // MARK: - Actions

    /// Translucent floating "Cancel" pinned at the top during selection mode so
    /// the user can exit from anywhere in a long list (the header Cancel scrolled
    /// away). Glass capsule — the list reads through it.
    private var floatingCancelButton: some View {
        Button(action: exitSelectionMode) {
            Text("Cancel")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotBlueTop)
                .padding(.horizontal, 16)
                .frame(minHeight: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, JotDesign.Spacing.pageGutter)
        .padding(.top, 6)
        .accessibilityLabel("Cancel selection")
    }

    private var recentsSelectionToolbar: some View {
        HStack(spacing: 12) {
            Button("Select All") {
                selectAllVisibleTranscripts()
            }
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(Color.jotBlueTop)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(visibleTranscriptIDs.isEmpty)

            Spacer(minLength: 8)

            Button {
                prepareCombine()
            } label: {
                Label("Combine", systemImage: "rectangle.stack.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(
                isCombineEnabled
                    ? Color.jotBlueTop
                    : Color.jotPageInkSecondary
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(!isCombineEnabled)
            .accessibilityHint("Merge selected entries into one.")

            Button("Delete \(selectedTranscriptIDs.count)", role: .destructive) {
                prepareBulkDelete()
            }
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(
                selectedTranscriptIDs.isEmpty
                    ? Color.jotPageInkSecondary
                    : Color(.systemRed)
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(selectedTranscriptIDs.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .modifier(
            JotDesign.Surface.heavy.modifier(
                cornerRadius: JotDesign.Spacing.sheetRadius
            )
        )
    }

    private var isCombineEnabled: Bool {
        // No upper cap — combine as many as you've selected (hundreds is fine).
        // Just need ≥2 to have something to merge.
        selectedTranscriptIDs.count >= 2
    }

    private func enterSelectionMode(selecting transcript: Transcript) {
        selectedTranscriptIDs = [transcript.id]
        isSelectionMode = true
        selectionHaptic.selectionChanged()
        selectionHaptic.prepare()
    }

    private func exitSelectionMode() {
        selectedTranscriptIDs = []
        pendingBulkDeletionIDs = []
        pendingCombineIDs = []
        isSelectionMode = false
    }

    private func selectAllVisibleTranscripts() {
        selectedTranscriptIDs = visibleTranscriptIDs
    }

    private func prepareBulkDelete() {
        guard !selectedTranscriptIDs.isEmpty else { return }
        pendingBulkDeletionIDs = selectedTranscriptIDs
    }

    private func prepareCombine() {
        guard isCombineEnabled else { return }
        pendingCombineIDs = selectedTranscriptIDs
    }

    /// Fired by `.sheet(onDismiss:)` once SwiftUI has fully torn the
    /// Settings sheet down. Firing `requestRerun()` here (rather than from
    /// inside SettingsView after a `DispatchQueue.main.async`) is what
    /// prevents the wizard's fullScreenCover from racing the sheet
    /// dismiss animation.
    private func handleSettingsDismissed() {
        // Re-check Ask availability — the user may have just downloaded
        // the Qwen weights in the Settings sheet they're dismissing.
        askAvailable = AskController.isAvailable
        guard pendingRerunAfterDismiss else { return }
        pendingRerunAfterDismiss = false
        SettingsRerunTrigger.shared.requestRerun()
    }

    // MARK: - Donation card

    /// Re-reads `DictationStats.shouldShowDonationCard` and updates the local
    /// @State flag. Cheap (two UserDefaults reads + a date math step), so
    /// it's fine to call from every plausible entry point — onAppear,
    /// scenePhase active, post-stop hero pop. The animation block makes the
    /// card's transition feel intentional rather than a jump.
    private func refreshDonationCardVisibility() {
        let next = DictationStats.shouldShowDonationCard
        guard next != donationCardVisible else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            donationCardVisible = next
        }
    }

    /// "Maybe later" tapped. Mark the card as dismissed (terminal — see
    /// `DictationStats.DonationCardState` doc) and hide it. The threshold
    /// is high enough that re-asking after a soft-dismiss would feel like
    /// nagging.
    private func handleDonationCardDismiss() {
        DictationStats.donationCardState = .dismissed
        withAnimation(.easeInOut(duration: 0.3)) {
            donationCardVisible = false
        }
    }

    /// "See donations" tapped. Optimistic transition to `.donated` (see
    /// `DictationStats.DonationCardState` doc — same reasoning as the Mac
    /// app: a false-positive is better UX than re-asking an actual donor).
    /// Then open the donations page in Safari and hide the card.
    private func handleDonationCardOpen() {
        DictationStats.donationCardState = .donated
        if let url = URL(string: "https://jot.ideaflow.page/donations") {
            UIApplication.shared.open(url)
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            donationCardVisible = false
        }
    }

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
        contentLog.error(
            "Keyboard rewrite target fetched nil transcript; releasing keyboard sessionID=\(target.sessionID, privacy: .public) jobID=\(target.jobID, privacy: .public) transcriptID=\(target.id, privacy: .public)"
        )
        // Whole terminal write must be guarded on jobID match — without
        // this, a stale `EmptyView().onAppear` from a transient fetch
        // miss can clobber the result slots of a NEWER job that's
        // already mid-flight. Drop silently when the slot has moved on.
        guard AppGroup.rewriteJobID == target.jobID else {
            contentLog.notice("releaseStrandedKeyboard: jobID slot moved on; skipping terminal write")
            return
        }
        AppGroup.rewriteError = "Couldn't open transcript."
        AppGroup.rewriteResult = nil
        AppGroup.rewriteResultSessionID = target.sessionID
        AppGroup.rewriteJobID = nil
        RewriteNotifications.postCompleted()
    }

    private func copy(_ transcript: Transcript) {
        UIPasteboard.general.string = transcript.displayText
        copyHaptic.impactOccurred()
        copyHaptic.prepare()
        UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")
        showCopiedConfirmation(for: transcript.id)
    }

    private func showCopiedConfirmation(for id: UUID) {
        copiedTranscriptID = id
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1_300))
            } catch {
                return
            }
            copiedTranscriptID = nil
        }
    }

    private func delete(_ transcript: Transcript) {
        modelContext.delete(transcript)
        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            // Notify the keyboard extension that the mirror has been
            // rewritten so its RecentsStrip can drop the deleted row
            // without waiting for the next presentation.
            CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            selectedTranscriptIDs.remove(transcript.id)
            pendingDeletion = nil
        } catch {
            modelContext.rollback()
            contentLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
            pendingDeletion = nil
        }
    }

    private func deleteSelectedTranscripts(ids: Set<UUID>) {
        let transcriptsToDelete = transcripts.filter { ids.contains($0.id) }
        guard !transcriptsToDelete.isEmpty else {
            pendingBulkDeletionIDs = []
            selectedTranscriptIDs.subtract(ids)
            return
        }

        for transcript in transcriptsToDelete {
            modelContext.delete(transcript)
        }

        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            pendingBulkDeletionIDs = []
            selectedTranscriptIDs = []
            isSelectionMode = false
        } catch {
            modelContext.rollback()
            contentLog.error("Transcript bulk delete save failed: \(error.localizedDescription, privacy: .public)")
            pendingBulkDeletionIDs = []
        }
    }

    /// Merge the selected transcripts into a single new entry.
    ///
    /// Sources are joined in chronological order (oldest first). For each
    /// source we use `displayText` — i.e. the AI rewrite if one exists,
    /// otherwise the raw transcript. The intent: if the user took the time
    /// to rewrite a source, that polished version is the one worth carrying
    /// into the merged entry; un-rewritten sources contribute their original
    /// text. The result is written into the new transcript's `text` field
    /// (no rewrite of its own), so the combined entry surfaces as a clean
    /// Original with no Rewrite tab. `TranscriptStore.append` handles fresh
    /// id, ledger index, mirror refresh, and Darwin notification.
    ///
    /// When `deleteOriginals` is true, the source rows are then removed
    /// in the same SwiftData transaction; otherwise they remain alongside
    /// the new combined entry. Selection mode exits unconditionally on
    /// success.
    private func combineSelectedTranscripts(ids: Set<UUID>, deleteOriginals: Bool) {
        let sources = transcripts
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        guard sources.count >= 2 else {
            selectedTranscriptIDs.subtract(ids)
            return
        }

        let combinedText = sources
            .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !combinedText.isEmpty else {
            selectedTranscriptIDs = []
            isSelectionMode = false
            return
        }

        do {
            _ = try TranscriptStore.append(raw: combinedText)
            if deleteOriginals {
                for transcript in sources {
                    modelContext.delete(transcript)
                }
                try modelContext.save()
                TranscriptHistoryMirror.refresh(from: modelContext)
                CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            }
            selectedTranscriptIDs = []
            isSelectionMode = false
        } catch {
            if deleteOriginals { modelContext.rollback() }
            contentLog.error("Transcript combine failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Floating pill shown in place of the Dictate FAB when a recording is
/// running but the user has backed out of the `RecordingHeroView`. Tap
/// returns to the hero. Blue gradient + pulsing white dot + live elapsed
/// timer + return arrow — chrome stays loud enough to be unmistakable
/// without overwhelming the editorial home. A soft outer blue halo (via
/// shadow) signals "live" without a hard ring.
private struct RecordingReturnPill: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOn = false

    var body: some View {
        let startedAt = DictationActivityCoordinator.shared.recordingStartedAt
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.30), lineWidth: 4)
                    )
                    .opacity(pulseOn ? 0.55 : 1.0)
                    .accessibilityHidden(true)

                Text("Recording")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.white)

                Rectangle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)

                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsedString(from: startedAt, to: context.date))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                }

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 56)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            // Soft outer blue wash that reads as "live" — shadow with no
            // offset spreads evenly in every direction, mimicking the
            // `box-shadow: 0 0 0 6px blue22` halo in the design spec
            // without a hard ring.
            .shadow(color: Color.jotBlueTop.opacity(0.30), radius: 14, x: 0, y: 0)
            .shadow(color: Color.jotBlueBottom.opacity(0.25), radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseOn = true
            }
        }
        .accessibilityLabel("Return to recording")
        .accessibilityHint("Recording is still in progress. Double-tap to return to the recording surface.")
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView(pendingColdStartHeroNudge: .constant(false))
        .environment(RecordingService())
        .environment(KeyboardRewriteRouter())
        .environment(TranscriptionService())
        .environment(StreamingPartial())
        .modelContainer(for: Transcript.self, inMemory: true)
}
