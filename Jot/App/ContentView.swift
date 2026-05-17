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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(RecordingService.self) private var recordingService
    @Environment(KeyboardRewriteRouter.self) private var keyboardRewriteRouter
    @Environment(StreamingPartial.self) private var streamingPartial

    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    @State private var navPath = NavigationPath()
    @State private var searchText = ""
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
    @State private var copiedTranscriptID: UUID?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
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

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .bottom) {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGapV09) {
                        RecentsNavBar(
                            onSettings: { showSettings = true },
                            onHelp: { showHelp = true }
                        )

                        heroTitle

                        searchBar

                        if donationCardVisible {
                            DonationCard(
                                onDismiss: handleDonationCardDismiss,
                                onSeeDonations: handleDonationCardOpen
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        RecentsListCard(
                            transcripts: transcripts,
                            groups: transcriptGroups,
                            isSearching: !searchText.isEmpty,
                            copiedTranscriptID: copiedTranscriptID,
                            isLiveRecording: isLiveRecordingInline,
                            liveStreamingText: streamingPartial.streamingText,
                            onCopy: copy,
                            onDelete: { pendingDeletion = $0 }
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

                // Bottom action zone: while a recording is running with the
                // hero dismissed, swap the FAB for a "return to recording"
                // pill. This is the only re-entry path for a user-backgrounded
                // recording, so it has to stay obvious. Suppressed while the
                // wizard is presenting — W6's in-wizard mic test sets
                // `isRecording == true` and we don't want a stray pill leaking
                // through the wizard overlay or driving a stale timer.
                //
                // Also gated on `userDismissedHeroDuringRecording` — the pill
                // is ONLY a re-entry affordance for an explicit back-out, not
                // a generic "recording is active" badge. On cold launch with
                // a URL-bounce recording, `isRecording` flips true before
                // `.onAppear` pushes the hero; without this gate the pill
                // would flash briefly in that gap. Auto-push paths cover the
                // "no flag set, recording active" case before any pixel ships.
                if isLiveRecordingInline {
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
            .animation(.easeInOut(duration: 0.25), value: recordingService.isRecording)
            .animation(.easeInOut(duration: 0.25), value: showRecordingHero)
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
        .onAppear {
            copyHaptic.prepare()
            refreshDonationCardVisibility()
            if let target = keyboardRewriteRouter.consumePending() {
                navPath.append(target)
            }
            // Cold-launch / first-appear adoption: if `JotApp.onOpenURL`
            // already kicked the recording before our nav stack rendered,
            // we land here with `isRecording == true`. Push the hero on
            // the next runloop so the recording surface owns the timer +
            // streaming preview from the user's POV. Tag the intent as
            // adoption — the hero must not call `start()` here.
            //
            // Suppress while the wizard is presenting — W6's mic test is
            // recording-driven and we don't want a zombie hero accumulating
            // on the nav stack behind the wizard. See `isWizardPresented`
            // doc above.
            if recordingService.isRecording,
               !isWizardPresented,
               !userDismissedHeroDuringRecording {
                heroIntent = .adoptInFlight
                showRecordingHero = true
            }
        }
        .onChange(of: keyboardRewriteRouter.pendingTarget) { _, newTarget in
            guard let newTarget else { return }
            navPath.append(newTarget)
            _ = keyboardRewriteRouter.consumePending()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
        // Auto-nav: any time recording comes alive outside our control
        // (URL bounce, future entry points), surface the hero. The hero's
        // own `beginRecordingFlow` adopts the in-flight session rather
        // than calling `start()` a second time. Pipeline-tail transitions
        // (`.transcribing` / `.cleaning`) deliberately do NOT trigger this
        // — see the docblock above for the reasoning.
        //
        // Suppressed while the wizard is presenting — W6's "Try it once"
        // step calls `recordingService.start()` to drive an in-wizard mic
        // test. Without this gate, that start fires this observer and a
        // hero gets pushed onto the home view's nav stack behind the
        // wizard. When the user taps stop inside W6 the recording cleanly
        // ends, but the hero on the home nav stack has no symmetric pop
        // path — it sits there frozen in `.recording` phase. The user
        // then dismisses the wizard and lands on a zombie "Listening"
        // surface with no underlying capture. See `isWizardPresented`
        // doc above.
        .onChange(of: recordingService.isRecording) { _, isRecording in
            if isRecording, !isWizardPresented, !userDismissedHeroDuringRecording {
                // Auto-nav adoption — never `start()` from this path.
                heroIntent = .adoptInFlight
                showRecordingHero = true
            } else if !isRecording {
                // Recording ended (user stopped, cancelled, errored, or the
                // pipeline finished). Reset the user-dismissal flag so the
                // NEXT recording auto-pushes the hero normally. Without this
                // the flag would stay armed and the user would have to tap
                // the FAB explicitly forever after one back-out.
                userDismissedHeroDuringRecording = false
                // A successful end-of-recording is also the moment the
                // donation card threshold could have just been crossed —
                // re-evaluate so the card can animate in for the user as
                // they land back on home.
                refreshDonationCardVisibility()
            }
        }
        // Keyboard dictations increment the stats counter from another
        // process without ever opening Jot.app. When the user returns to
        // the app, re-evaluate donation card visibility so the threshold
        // crossing is reflected.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshDonationCardVisibility()
            }
        }
    }

    // MARK: - Recording state

    /// True when a recording is hot AND the user has backed out of the hero
    /// — i.e. the moment to surface the live streaming preview inline at the
    /// top of the Recents list. Also drives the swap from FAB to blue
    /// "Return to recording" pill. Wizard-presented state stays suppressed:
    /// W6's in-wizard mic test runs `isRecording == true` and the wizard
    /// owns its own surface during its lifetime.
    private var isLiveRecordingInline: Bool {
        recordingService.isRecording
            && !showRecordingHero
            && !isWizardPresented
            && userDismissedHeroDuringRecording
    }

    // MARK: - Hero

    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recents.")
                .font(JotType.displaySerif(44))
                .tracking(-1.6)
                .foregroundStyle(Color.jotPageInk)
                .accessibilityAddTraits(.isHeader)

            Text(formattedDate)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
    }

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

    // MARK: - Grouping

    /// Source of truth for what gets rendered in the grouped list. When
    /// `searchText` is non-empty we filter case-insensitively across both
    /// the cleaned/displayed text and the raw transcript text.
    private var filteredTranscripts: [Transcript] {
        guard !searchText.isEmpty else { return transcripts }
        return transcripts.filter { transcript in
            transcript.displayText.localizedCaseInsensitiveContains(searchText)
                || transcript.text.localizedCaseInsensitiveContains(searchText)
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

    // MARK: - Actions

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
            pendingDeletion = nil
        } catch {
            modelContext.rollback()
            contentLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
            pendingDeletion = nil
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
    ContentView()
        .environment(RecordingService())
        .environment(KeyboardRewriteRouter())
        .environment(TranscriptionService())
        .environment(StreamingPartial())
        .modelContainer(for: Transcript.self, inMemory: true)
}
