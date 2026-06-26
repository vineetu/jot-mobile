import SwiftData
import SwiftUI
import UIKit
import os.log

private let homeLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "home")

/// Editorial home surface per Phase 3 of the UX overhaul.
///
/// ## What this screen is (vs. the old monolithic `ContentView`)
///
/// `HomeScreen` is the Recents home content extracted out of the former
/// `ContentView` god-view (Step 2 of the root-view decouple,
/// `docs/decouple-root-view/design.md`). It is now *just a screen* mounted as
/// the root of the `NavigationStack` that `AppRootView` owns — it holds only
/// home-local view-state (selection mode, the `copied!` flash, the
/// donation/warm-hold cards) and routes every transcript mutation through the
/// `TranscriptStore` repository. Navigation (sheets, the hero, the
/// `navigationDestination`s) lives on `AppRootView`; `HomeScreen` drives the
/// hero only by flipping the bindings `AppRootView` passes in.
///
/// The earlier home centered on an inline `RecorderBar` (big red mic button,
/// streaming preview, transcribing spinner) pinned to the bottom safe area.
/// Phase 3 (Mockup 07) replaced that with an editorial layout:
/// - SF Pro 38pt "Jot" headline + tiny daily-stat sub-line.
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
/// `RecordingHeroView` owns the start/stop pipeline now; this screen no
/// longer touches `RecordingService.start()` / `stop()` directly.
struct HomeScreen: View {
    /// True while the setup wizard's fullScreenCover is presenting on top
    /// of the home view. The wizard owns its own recording UX during its
    /// lifetime — W6's mic test surfaces the live transcript inside the
    /// wizard panel itself. We use it to suppress the live-recording return
    /// pill and to lock the keyboard-dictate observer install/teardown in
    /// step with the wizard's own observer.
    var isWizardPresented: Bool = false

    /// The shared nav stack path (owned by `AppRootView`). Recents row taps
    /// append a transcript UUID; keyboard-rewrite / open-transcript hand-offs
    /// append here too.
    @Binding var navPath: NavigationPath

    /// One-shot signal that the next recording-start was triggered by a
    /// `jot://dictate*` URL bounce from a third-party keyboard. Read here only
    /// to suppress the one-frame pill flash during the cold-start-about-to-
    /// present window (`isLiveRecordingInline`). `AppRootView` owns presenting
    /// the hero from it and clearing it.
    @Binding var pendingExternalKeyboardHero: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(RecordingService.self) private var recordingService
    @Environment(Router.self) private var router

    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    @State private var searchText = ""
    /// Semantic-search controller driving the "meaning" half of the
    /// hybrid Recents filter. Substring matching still happens inline
    /// in `filteredTranscripts`; this controller publishes the set of
    /// transcript IDs whose embedding cosine ≥ 0.50 to the query.
    @State private var semanticSearch = SemanticSearchController()

    /// Whether the Ask entry point (the sparkles pill) is shown. Gated on
    /// the on-board Qwen weights being *downloaded* (on disk) — not loaded
    /// into memory — so Ask only appears once the user has a capable
    /// on-device model. Re-evaluated on appear and whenever the Settings
    /// sheet (where the download happens) is dismissed.
    @State private var askAvailable = AskController.isAvailable
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
    /// Mirrors `DictationStats.shouldShowDonationCard` into a SwiftUI-watchable
    /// flag. Re-evaluated on `onAppear` and on every transition to `.active`
    /// scene phase — that covers (a) a fresh app launch, (b) returning to
    /// home after the recording hero pops, and (c) returning from background
    /// after the keyboard incremented the counter in another app. The
    /// `DictationStats` state machine itself stays the source of truth; this
    /// flag is just a cache that lets the body invalidate cleanly.
    @State private var donationCardVisible: Bool = false

    /// Darwin observer for the keyboard-dictate tap, installed only while the
    /// wizard is NOT presented (the wizard owns its own observer during its
    /// lifetime — see `SetupWizardView`). Re-installed / torn down by the
    /// `isWizardPresented`-aware `.onChange` + `.onAppear` below.
    @State private var dictateTapObserver: CrossProcessNotification.Observer?

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
        ZStack(alignment: .bottom) {
            WallpaperBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGapV09) {
                    RecentsNavBar(
                        isSelectionMode: isSelectionMode,
                        onSettings: { router.showSettings = true },
                        onHelp: { router.showHelp = true },
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
            // `pendingExternalKeyboardHero` is still pending the pill would
            // flash for one frame in that gap, so we suppress it there
            // (see `isLiveRecordingInline`).
            if isSelectionMode {
                recentsSelectionToolbar
                    .padding(.horizontal, JotDesign.Spacing.pageGutter)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isLiveRecordingInline {
                RecordingReturnPill {
                    // Re-enter the hero, adopting the running session rather
                    // than `start()`-ing a second one.
                    router.heroIntent = .adoptInFlight
                    router.showRecordingHero = true
                }
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                DictateFAB {
                    // Fresh user action: tell the hero to actually start a
                    // recording. Set intent BEFORE flipping the flag so
                    // the hero's `.onAppear` reads the right value.
                    router.heroIntent = .startRecording
                    router.showRecordingHero = true
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
        .animation(.easeInOut(duration: 0.25), value: router.showRecordingHero)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSelectionMode)
        .navigationBarHidden(true)
        // Install / tear down the keyboard-dictate observer in lockstep with the
        // wizard. While the wizard is up it owns the tap (W5); the moment it's
        // down the unified receiver takes over. Identity-checked Observer means
        // re-installing is idempotent.
        .onChange(of: isWizardPresented) { _, wizardUp in
            updateDictateTapObserver(wizardPresented: wizardUp)
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
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
        .onChange(of: recordingService.isRecording) { _, isRecording in
            guard !isRecording else { return }
            // Recording ended (stopped, cancelled, errored, or pipeline done).
            // Re-check the donation-card threshold for the user landing back
            // on home.
            refreshDonationCardVisibility()
        }
        // Keyboard dictations increment the stats counter from another
        // process without ever opening Jot.app. When the user returns to
        // the app, re-evaluate donation card + warm-hold-nudge visibility so
        // the threshold crossing is reflected. (Hero reconciliation stays on
        // `AppRootView`, which owns the hero presentation.)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshDonationCardVisibility()
                refreshWarmHoldNudge()
            }
        }
        .onChange(of: visibleTranscriptIDs) { _, visibleIDs in
            selectedTranscriptIDs.formIntersection(visibleIDs)
        }
        // Re-check Ask availability after Settings (where the Qwen weights are
        // downloaded) is dismissed.
        .onChange(of: router.showSettings) { _, isShown in
            if !isShown { askAvailable = AskController.isAvailable }
        }
    }

    // MARK: - Recording state

    /// True for ANY live recording while home is showing — the moment to swap
    /// the FAB for the blue "Return to recording" pill so the FAB never reads
    /// "Start" while something is recording. Tapping the pill opens the hero,
    /// which adopts whatever recording is in flight. We deliberately do NOT
    /// gate on how the recording started (the old narrow "backgrounded hero"
    /// key was dropped in unify-keyboard-dictation §5 Stage 1).
    ///
    /// One exception — the cold-start-about-to-present window: on a
    /// `jot://dictate` cold launch, `isRecording` flips true *before*
    /// `.onAppear` / `.onChange` pushes the hero. While
    /// `pendingExternalKeyboardHero` is still pending (not yet consumed) the
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
            && !router.showRecordingHero
            && !isWizardPresented
            && !pendingExternalKeyboardHero
    }

    // MARK: - WS-B unified keyboard-dictate receiver

    /// Install or tear down the `keyboardDictateTapped` observer so it is live
    /// exactly when the wizard is NOT presented. The wizard installs its OWN
    /// observer for its lifetime (W5); running both at once would double-handle
    /// a single tap. When the wizard is down we route the tap into a normal
    /// background capture (Stage 2 — same path the keyboard uses in any other
    /// app). When the wizard comes up we drop our observer.
    private func updateDictateTapObserver(wizardPresented: Bool) {
        if wizardPresented {
            dictateTapObserver = nil
        } else if dictateTapObserver == nil {
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
                        homeLog.notice("keyboardDictateTapped (in-Jot) while recorder busy; ignoring")
                        return
                    }
                    do {
                        homeLog.notice("RECORDING START FROM: HomeScreen.keyboardDictateTapped (in-Jot keyboard tap)")
                        let startedAt = Date()
                        // A capture must never inherit a stale inline-ownership
                        // flag. `ownsActiveRecording` is set ONLY by Ask's
                        // `InlineDictationSession`; if Ask ever leaves it true,
                        // a later capture that starts via `start()` directly would
                        // carry it, and the keyboard Stop would bail out of
                        // `handleStopRequested` BEFORE stopping the mic (the
                        // warm-resume "won't stop" regression). This is a normal
                        // capture, so clear it defensively before starting.
                        recording.ownsActiveRecording = false
                        try await recording.start()
                        // Seed the activity coordinator's start anchor so any
                        // later hero adoption reads THIS recording's start time
                        // (mirrors the warm-resume observer in JotApp.init).
                        await DictationActivityCoordinator.shared.start(startedAt: startedAt)
                    } catch {
                        homeLog.error("keyboardDictateTapped (in-Jot) start failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
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

    // MARK: - Hero title

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
                font: JotType.displayTitle(34),
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
            router.showAskSheet = true
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

    // MARK: - Selection toolbar

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
        if let url = URL(string: "https://jot-transcribe.com/donations/") {
            UIApplication.shared.open(url)
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            donationCardVisible = false
        }
    }

    // MARK: - Transcript actions

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
        let id = transcript.id
        do {
            try TranscriptStore.delete(id: id)
            selectedTranscriptIDs.remove(id)
            pendingDeletion = nil
        } catch {
            homeLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
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

        do {
            try TranscriptStore.delete(ids: Set(transcriptsToDelete.map { $0.id }))
            pendingBulkDeletionIDs = []
            selectedTranscriptIDs = []
            isSelectionMode = false
        } catch {
            homeLog.error("Transcript bulk delete save failed: \(error.localizedDescription, privacy: .public)")
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
                // One quadruplet for the whole batch — `delete(ids:)` fires
                // the mirror once, so combine no longer double-fires (append
                // mirrors, then a second manual delete-originals save used to
                // mirror again).
                try TranscriptStore.delete(ids: Set(sources.map { $0.id }))
            }
            selectedTranscriptIDs = []
            isSelectionMode = false
        } catch {
            homeLog.error("Transcript combine failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Floating pill shown in place of the Dictate FAB when a recording is
/// running but the user has backed out of the `RecordingHeroView`. Tap
/// returns to the hero. Blue gradient + pulsing white dot + live elapsed
/// timer + return arrow — chrome stays loud enough to be unmistakable
/// without overwhelming the editorial home. A soft outer blue halo (via
/// shadow) signals "live" without a hard ring.
struct RecordingReturnPill: View {
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
