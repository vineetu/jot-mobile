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
/// - Floating coral Dictate FAB centered above the safe area; tapping it
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
    @Environment(\.modelContext) private var modelContext
    @Environment(RecordingService.self) private var recordingService
    @Environment(KeyboardRewriteRouter.self) private var keyboardRewriteRouter

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
                JotDesign.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        headerRow

                        searchBar

                        groupedTranscriptsList
                    }
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.top, 8)
                    // Leave room at the bottom so the FAB doesn't obscure the
                    // last row of transcripts. FAB pill height (64pt) + bottom
                    // safe-area margin + breathing room.
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)

                DictateFAB {
                    // Fresh user action: tell the hero to actually start a
                    // recording. Set intent BEFORE flipping the binding so
                    // the hero's `.onAppear` reads the right value.
                    heroIntent = .startRecording
                    showRecordingHero = true
                }
                .padding(.bottom, 16)
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showRecordingHero) {
                RecordingHeroView(
                    showRecordingHero: $showRecordingHero,
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
            if let target = keyboardRewriteRouter.consumePending() {
                navPath.append(target)
            }
            // Cold-launch / first-appear adoption: if `JotApp.onOpenURL`
            // already kicked the recording before our nav stack rendered,
            // we land here with `isRecording == true`. Push the hero on
            // the next runloop so the recording surface owns the timer +
            // streaming preview from the user's POV. Tag the intent as
            // adoption — the hero must not call `start()` here.
            if recordingService.isRecording {
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
        .onChange(of: recordingService.isRecording) { _, isRecording in
            if isRecording {
                // Auto-nav adoption — never `start()` from this path.
                heroIntent = .adoptInFlight
                showRecordingHero = true
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Jot")
                    .font(JotType.editorialDisplay)
                    .foregroundStyle(Color.jotInk)
                    .accessibilityAddTraits(.isHeader)

                Text(todayStatLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotMute)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                helpButton
                settingsButton
            }
        }
    }

    private var helpButton: some View {
        Button {
            showHelp = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .accessibilityHint("Opens the Help screen")
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
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
                .foregroundStyle(Color.jotMute)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search transcripts")
                    .foregroundStyle(Color.jotMute)
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.jotInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.jotMute)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        .accessibilityLabel("Search transcripts")
    }

    // MARK: - Grouped list

    private var groupedTranscriptsList: some View {
        VStack(alignment: .leading, spacing: 24) {
            if transcripts.isEmpty {
                emptyState
            } else if !searchText.isEmpty && filteredTranscripts.isEmpty {
                noMatchesState
            } else {
                ForEach(transcriptGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(group.title)
                        VStack(spacing: 0) {
                            ForEach(group.items) { transcript in
                                NavigationLink {
                                    TranscriptDetailView(
                                        transcript: transcript,
                                        keyboardRewriteIntent: nil
                                    )
                                } label: {
                                    TranscriptRow(
                                        transcript: transcript,
                                        isCopied: copiedTranscriptID == transcript.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        copy(transcript)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }

                                    Button(role: .destructive) {
                                        pendingDeletion = transcript
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDeletion = transcript
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }

                                if transcript.id != group.items.last?.id {
                                    Divider()
                                        .overlay(Color.jotMuteWeak.opacity(0.45))
                                        .padding(.leading, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.jotMute)
            Text("No transcripts yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)
            Text("Tap Dictate to record your first note.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.jotMute)
            Text("No matches")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)
            Text("Try a different search.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Grouping

    private struct TranscriptGroup {
        let title: String
        let items: [Transcript]
    }

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

    private var transcriptGroups: [TranscriptGroup] {
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

        var groups: [TranscriptGroup] = []
        if !today.isEmpty { groups.append(.init(title: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: "Yesterday", items: yesterday)) }
        if !lastWeek.isEmpty { groups.append(.init(title: "Last 7 days", items: lastWeek)) }
        if !older.isEmpty { groups.append(.init(title: "Earlier", items: older)) }
        return groups
    }

    // MARK: - Stat line

    /// "12 transcripts · 47 min today" — derived from `transcripts` in the
    /// current calendar day. Falls back to a short copy line when the day is
    /// still empty (the FAB carries the call to action visually).
    private var todayStatLine: String {
        let calendar = Calendar.current
        let now = Date()
        guard let startOfToday = calendar.dateInterval(of: .day, for: now)?.start
        else { return "Ready when you are" }
        let todays = transcripts.filter { $0.createdAt >= startOfToday }
        guard !todays.isEmpty else { return "Ready when you are" }
        let count = todays.count
        let totalSeconds = todays.reduce(0.0) { $0 + ($1.durationSeconds ?? 0) }
        let minutes = max(1, Int((totalSeconds / 60).rounded()))
        let noun = count == 1 ? "transcript" : "transcripts"
        return "\(count) \(noun) · \(minutes) min today"
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

// MARK: - Transcript row

private struct TranscriptRow: View {
    let transcript: Transcript
    let isCopied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(timeText)
                        .font(JotType.monoTimestamp)
                        .foregroundStyle(Color.jotMute)
                        .monospacedDigit()
                    if let duration = durationText {
                        Text("·")
                            .font(JotType.monoTimestamp)
                            .foregroundStyle(Color.jotMuteWeak)
                        Text(duration)
                            .font(JotType.monoTimestamp)
                            .foregroundStyle(Color.jotMute)
                            .monospacedDigit()
                    }
                    if isCopied {
                        Spacer(minLength: 6)
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Copied")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.jotSuccessInk)
                    }
                }

                Text(transcript.displayText)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        transcript.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private var durationText: String? {
        guard let duration = transcript.durationSeconds else { return nil }
        let total = max(0, Int(duration.rounded()))
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
