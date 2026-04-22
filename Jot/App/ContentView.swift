import SwiftData
import SwiftUI
import UIKit
import os.log

private let lifecycleLog = Logger(subsystem: "com.jot.mobile.Jot", category: "app-lifecycle")

/// The Ledger — Jot's single app surface.
///
/// The design is a "NothingJot × Pulse hybrid": an instrument pill pinned
/// beneath the Dynamic Island hosts the record control, elapsed timer, VU
/// meter, and status chip. Below it, the rest of the screen is a chronological
/// log of every transcript (the "ledger"), persisted via SwiftData so it
/// survives relaunches and is shared with headless Shortcuts intents via
/// `JotModelContainer.shared`.
///
/// ## Why the pill is the only chrome
///
/// Every other state (errors, empty, settings) is either an inline card in
/// the log, or a small floating secondary. We deliberately avoid a nav bar
/// or tab bar — the app is a single instrument, not a multi-section utility.
/// See `docs/design/mockups/6_Ledger.swift` for the source design.
///
/// ## Dark-only by design
///
/// We force `.preferredColorScheme(.dark)` because the amber accent against
/// ink only reads correctly in dark. If we need a light variant later, it's
/// a redesign, not a theme flip. "Don't break light mode" is satisfied by
/// still functioning — we just override the appearance.
struct ContentView: View {
    // MARK: Environment

    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(\.modelContext) private var modelContext

    /// The ledger itself. SwiftData rebroadcasts changes from any writer on
    /// the same `ModelContainer`, so a headless intent's `TranscriptStore.append`
    /// lands here the moment the user foregrounds the app.
    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    // MARK: Phase

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case processing
        case cleaning
    }

    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var vuTimer: Timer?
    /// 12-sample waterfall of recent amplitudes, newest on the right.
    ///
    /// Initial + reset value is **0.14**, which is the idle floor of
    /// `RecordingService.currentAmplitude`'s compression curve: `sqrt(0.005 × 4)`
    /// where `0.005` is the typical linear-RMS of room tone on an iPhone
    /// mic. Matching that constant means the handoff from the pre-record
    /// flat line to the first live sample is imperceptible — without it,
    /// the waterfall would visibly step down from a placeholder 0.28 to
    /// the real ~0.14 ambient in the first ~80 ms, reading as "audio
    /// dropped" when in fact we just transitioned into real data.
    ///
    /// Per recording-engineer-3's endorsement: don't move this constant
    /// unless iPhone mic hardware characteristics change materially.
    @State private var vuBars: [CGFloat] = Array(repeating: 0.14, count: 12)
    @State private var errorMessage: String?
    @State private var showSettings: Bool = false
    @State private var activeTask: Task<Void, Never>?
    @State private var activityCoordinator = DictationActivityCoordinator.shared
    @State private var postProcessingCoordinator = DictationPostProcessingCoordinator.shared
    @State private var pendingDeletion: Transcript?
    @State private var expandedClusterIDs: Set<UUID> = []

    /// Per-transcript expansion for LONG individual transcripts. When a
    /// transcript's body exceeds `collapsedRowLineLimit` lines, it renders
    /// truncated with a "Show more" toggle. Tap expands to full text; tap
    /// again collapses. Separate from `expandedClusterIDs` which groups
    /// related transcripts — this is per-row body length.
    @State private var expandedTranscriptIDs: Set<UUID> = []

    /// Line budget before a long transcript auto-truncates. Tuned to the
    /// density of the Ledger type: ~5 lines keeps one transcript from
    /// dominating the screen when the user has been recording paragraphs.
    private let collapsedRowLineLimit = 5

    // Haptic generators live in `@State`, not `private let`. A SwiftUI
    // `View` is a value type SwiftUI reconstructs on every state change;
    // a `private let` would allocate a fresh generator (orphaning the
    // previous one) on each reconstruction. The orphaned generator's
    // prepared-but-never-fired `CHHapticPatternPlayer` then logs
    // `AVHapticClient.finish` error -4805 "Player was not running" on
    // dealloc. `@State` persists the reference across reconstructions.
    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var actionHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @State private var successHaptic = UINotificationFeedbackGenerator()

    // MARK: Palette

    private let ink = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
    /// Keep only the newest descendant-bearing cluster expanded by default.
    /// Older chains collapse into a summary row until the user explicitly
    /// opens them. This is count-based, not time-based, so dense rapid-fire
    /// follow-ups collapse predictably.
    private let autoExpandedClusterBudget = 1

    // MARK: Body

    var body: some View {
        // Pill is pinned at the BOTTOM so it's reachable one-handed (thumb
        // zone) — the top-mounted variant shipped in 6192 required a second
        // hand to tap the record control. Placing the pill at the bottom
        // also flips the reading order of the log above it (oldest at top,
        // newest adjacent to the pill), matching the "the row you're about
        // to append one more to" mental model used by Messages / any chat
        // surface. See the log `Spacer` math below and the `computeClusters`
        // sort for the two downstream consequences.
        ZStack(alignment: .bottom) {
            ink.ignoresSafeArea()
            ledgerRules.ignoresSafeArea()

            log

            VStack(spacing: 8) {
                if transcriptionService.modelState != .ready {
                    parakeetWarmupBanner
                }

                pill
            }
            .padding(.bottom, 10)
            .padding(.horizontal, 14)
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { target in
            Button("Delete", role: .destructive) { confirmDelete(target) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The transcript is removed from your ledger and cannot be recovered.")
        }
        .onAppear {
            startHaptic.prepare()
            stopHaptic.prepare()
            actionHaptic.prepare()
            successHaptic.prepare()
        }
        .onChange(of: errorMessage) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .onChange(of: postProcessingCoordinator.stage) { _, newStage in
            switch newStage {
            case .idle:
                if phase == .processing || phase == .cleaning {
                    phase = .idle
                }
            case .processing:
                if phase == .transcribing || phase == .cleaning || phase == .processing {
                    phase = .processing
                }
            case .cleaning:
                if phase == .transcribing || phase == .processing || phase == .cleaning {
                    phase = .cleaning
                }
            }
        }
        .onDisappear {
            vuTimer?.invalidate()
            vuTimer = nil
        }
    }

    // MARK: - Background

    /// Ruled-paper hairlines at 32pt cadence. 0.5pt lines at 3.5% white keep
    /// the page feeling "quiet" — visible enough to read as structure,
    /// subtle enough to vanish under a transcript.
    private var ledgerRules: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var y: CGFloat = step
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.035)))
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Pill (the instrument)

    private var pill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                recDot(now: context.date)
                timerLabel
                vuStrip
                    .frame(height: 20)
                    .layoutPriority(1)
                statusChip(now: context.date)
                settingsDivider
                settingsButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            .animation(.spring(response: 0.42, dampingFraction: 0.85), value: phase)
        }
    }

    private var parakeetWarmupBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(amber)

            Text("Warming up Parakeet model. First transcription may take up to 20 seconds.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warming up Parakeet model. First transcription may take up to 20 seconds.")
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.5, height: 22)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private func recDot(now: Date) -> some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(recDotFillColor(now: now))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .stroke(
                                isFollowUpActive(at: now) && phase == .idle
                                    ? amber.opacity(0.45)
                                    : .clear,
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isFollowUpActive(at: now) && phase == .idle
                            ? amber.opacity(0.25)
                            : .clear,
                        radius: 8
                    )
                Image(systemName: recDotIcon)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(phase == .recording ? ink : .white)
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing)
        .accessibilityLabel(recDotAccessibilityLabel(now: now))
    }

    private func recDotFillColor(now: Date) -> Color {
        if phase == .recording {
            return amber
        }

        if isFollowUpActive(at: now) {
            return amber.opacity(0.24)
        }

        return Color.white.opacity(0.12)
    }

    private var recDotIcon: String {
        switch phase {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "ellipsis"
        case .processing, .cleaning: return "xmark"
        }
    }

    private func recDotAccessibilityLabel(now: Date) -> String {
        switch phase {
        case .idle:
            if let deadline = followUpDeadline(at: now) {
                return "Start follow-up recording. \(followUpSecondsRemaining(until: deadline, now: now)) seconds remaining"
            }
            return "Start recording"
        case .recording:
            return "Stop recording"
        case .transcribing:
            return "Transcribing"
        case .processing, .cleaning:
            return "Cancel post-processing"
        }
    }

    private var timerLabel: some View {
        Text(timeString)
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.92))
            .contentTransition(.numericText())
            .animation(.linear(duration: 0.1), value: elapsed)
    }

    /// 12 monospaced bars. During `.recording` they animate via the
    /// `vuTimer` below; we fake amplitude for now (see TODO in start()).
    /// In other phases they sit flat at a low opacity to signal "instrument
    /// idle".
    private var vuStrip: some View {
        HStack(spacing: 2) {
            ForEach(Array(vuBars.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(vuBarColor)
                    .frame(width: 2, height: max(3, 20 * h))
            }
        }
    }

    private var vuBarColor: Color {
        switch phase {
        case .recording: return amber
        case .transcribing, .processing, .cleaning: return amber.opacity(0.45)
        case .idle: return Color.white.opacity(0.22)
        }
    }

    /// Status label, paired with an inline amber `ProgressView` during the
    /// `.transcribing` / `.cleaning` phases.
    ///
    /// The static `TRANS` / `CLEAN` chip in 6192 read as stalled to testers
    /// — a dictation that happened to hit a slow Parakeet decode (or a
    /// cleanup round-trip to a sluggish Ollama) looked indistinguishable
    /// from a hung pipeline. The `ProgressView` is pure reassurance that
    /// work is happening; the Text still carries the phase label for users
    /// who can read it.
    ///
    /// `.controlSize(.mini)` keeps the spinner subordinate to the pill
    /// layout — it's a detail on the status chip, not a primary progress
    /// bar. `.tint(amber)` aligns with the Ledger accent already used for
    /// `vuBarColor` and `statusChipColor` during these phases, so the
    /// whole right half of the pill pulses amber in sync.
    ///
    /// `minWidth: 72` (vs the pre-indicator `60`) reserves enough room for
    /// `spinner + text` so the chip width barely shifts when the indicator
    /// appears — the pill's existing phase-keyed spring animation
    /// (`body → pill → .animation`) handles the residual width delta.
    @ViewBuilder
    private func statusChip(now: Date) -> some View {
        let content = HStack(spacing: 6) {
            if phase == .transcribing || phase == .processing || phase == .cleaning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(amber)
            }
            Text(statusText(at: now))
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .tracking(2)
                .foregroundStyle(statusChipColor(now: now))

            if isFollowUpActive(at: now) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusChipColor(now: now))
            }
        }
        .frame(minWidth: isFollowUpActive(at: now) ? 104 : 72, alignment: .trailing)

        if isFollowUpActive(at: now) {
            Button(action: dismissFollowUpWindow) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss follow-up window")
        } else {
            content
        }
    }

    private func statusText(at now: Date) -> String {
        if let deadline = followUpDeadline(at: now) {
            return "FOLLOW \(followUpSecondsRemaining(until: deadline, now: now))s"
        }

        switch phase {
        case .idle: return "READY"
        case .recording: return "REC"
        case .transcribing: return "TRANS"
        case .processing: return "PROC"
        case .cleaning: return "CLEAN"
        }
    }

    private func statusChipColor(now: Date) -> Color {
        switch phase {
        case .recording: return amber
        case .transcribing, .processing, .cleaning: return amber.opacity(0.85)
        case .idle:
            return isFollowUpActive(at: now) ? amber.opacity(0.9) : .white.opacity(0.6)
        }
    }

    private func followUpDeadline(at now: Date) -> Date? {
        guard phase == .idle, activityCoordinator.isFollowUpActive,
              let deadline = activityCoordinator.followUpExpiresAt else { return nil }
        return deadline > now ? deadline : nil
    }

    private func isFollowUpActive(at now: Date) -> Bool {
        followUpDeadline(at: now) != nil
    }

    private func followUpSecondsRemaining(until deadline: Date, now: Date) -> Int {
        max(1, Int(ceil(deadline.timeIntervalSince(now))))
    }

    // MARK: - Log

    /// A parent transcript with its chained follow-ups. Clusters are the
    /// unit of scroll flow: the root renders at full width, descendants
    /// render indented beneath it in chronological order. See
    /// `computeClusters(from:)` for the derivation, and `Transcript.derivedFromID`
    /// for why chains exist at all.
    private struct Cluster: Identifiable {
        let root: Transcript
        let descendants: [Transcript]
        /// The latest timestamp in the cluster — either the root's or its
        /// newest follow-up's. Drives reverse-chronological cluster sort so
        /// an active chain floats to the top of the log even if the root is
        /// old.
        let effectiveTimestamp: Date

        var id: UUID { root.id }
        var isSuperseded: Bool { !descendants.isEmpty }
    }

    /// Group the flat reverse-chronological `@Query` result into parent /
    /// follow-up clusters.
    ///
    /// ## Contract
    ///
    /// - An entry with `derivedFromID == nil` is a root.
    /// - An entry whose `derivedFromID` points to an entry *in the current
    ///   query result* is a descendant of that entry. We BFS the full chain
    ///   so follow-ups-of-follow-ups (A → B → C) surface inside A's cluster.
    /// - An entry whose `derivedFromID` points to a transcript **not** in the
    ///   query result (e.g. parent was deleted) is treated as a top-level
    ///   root. That's intentional — the child is still real content, the
    ///   user just killed its ancestor. A cascade delete would be
    ///   user-hostile.
    ///
    /// Descendants within a cluster render oldest → newest so the chain
    /// reads as a conversation. Clusters themselves sort by
    /// `effectiveTimestamp` **ascending** so the newest cluster sits at
    /// the bottom of the log, adjacent to the pill — where the user's
    /// eye and thumb both land. A recent reply to an old transcript pulls
    /// the whole chain back to the bottom for the same reason.
    private func computeClusters(from entries: [Transcript]) -> [Cluster] {
        guard !entries.isEmpty else { return [] }

        let byID: [UUID: Transcript] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )

        var childrenByParent: [UUID: [Transcript]] = [:]
        var roots: [Transcript] = []

        for entry in entries {
            if let parentID = entry.derivedFromID, byID[parentID] != nil {
                childrenByParent[parentID, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }

        let clusters = roots.map { root -> Cluster in
            var collected: [Transcript] = []
            var queue: [UUID] = [root.id]
            while let current = queue.popLast() {
                let kids = (childrenByParent[current] ?? [])
                    .sorted { $0.createdAt < $1.createdAt }
                for kid in kids {
                    collected.append(kid)
                    queue.append(kid.id)
                }
            }
            let effective = collected.last?.createdAt ?? root.createdAt
            return Cluster(
                root: root,
                descendants: collected,
                effectiveTimestamp: effective
            )
        }

        return clusters.sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }
    }

    private var clusters: [Cluster] { computeClusters(from: transcripts) }

    private var log: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Top breathing room below the system safe area. The pill
                // lives at the bottom now (see `body`) so no pill clearance
                // is needed up here — this is purely "don't crash the first
                // eyebrow into the notch / Dynamic Island."
                Spacer().frame(height: 20)

                if transcripts.isEmpty && errorMessage == nil {
                    emptyState
                } else {
                    ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                        clusterBlock(cluster, at: index)
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                    }
                }

                // Error card sits *below* the clusters, immediately above
                // the pill. With `defaultScrollAnchor(.bottom)` the scroll
                // anchors here, so a freshly-surfaced error is visible
                // without the user having to scroll. See `errorCard` for the
                // rationale on inline-card-vs-toast.
                if let errorMessage {
                    errorCard(errorMessage)
                }

                // Bottom clearance for the pill. 76pt ≈ pill height (52pt) +
                // bottom padding (10pt) + breathing room (14pt). Keeps the
                // newest transcript from visually tucking under the pill's
                // blur.
                Spacer().frame(height: 76)
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        // Anchor the initial scroll position — and the anchor for newly
        // appended content — at the bottom. Clusters sort ascending
        // (see `computeClusters`), so bottom = newest. On cold launch the
        // user lands already looking at their most recent dictation,
        // adjacent to the pill they're about to press for the next one.
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private func clusterBlock(_ cluster: Cluster, at index: Int) -> some View {
        if isClusterCollapsed(cluster, at: index) {
            collapsedClusterRow(cluster)
        } else {
            VStack(spacing: 0) {
                rootRow(cluster.root, isSuperseded: cluster.isSuperseded)
                ForEach(cluster.descendants) { child in
                    descendantDivider
                    descendantRow(child)
                }
            }
        }
    }

    private func isClusterCollapsed(_ cluster: Cluster, at index: Int) -> Bool {
        guard cluster.isSuperseded else { return false }
        guard !expandedClusterIDs.contains(cluster.id) else { return false }
        let newerDescendantClusters = clusters[(index + 1)...].filter(\.isSuperseded).count
        return newerDescendantClusters >= autoExpandedClusterBudget
    }

    private func collapsedClusterRow(_ cluster: Cluster) -> some View {
        Button {
            expandedClusterIDs.insert(cluster.id)
            actionHaptic.impactOccurred()
            actionHaptic.prepare()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(String(format: "#%04d", cluster.root.ledgerIndex))
                        .foregroundStyle(amber)
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(cluster.effectiveTimestamp.formatted(.dateTime.hour().minute()))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(collapseCountLabel(for: cluster))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(amber.opacity(0.72))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(.footnote, design: .monospaced).weight(.bold))

                Text(cluster.descendants.last?.displayText ?? cluster.root.displayText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("TAP TO EXPAND")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.42))
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand conversation cluster")
        .accessibilityHint("Shows older follow-up entries in this cluster")
    }

    private func collapseCountLabel(for cluster: Cluster) -> String {
        let hiddenEntryCount = cluster.descendants.count
        return hiddenEntryCount == 1
            ? "1 FOLLOW-UP"
            : "\(hiddenEntryCount) FOLLOW-UPS"
    }

    /// Hairline that separates a parent from its first follow-up, or
    /// between follow-ups. Shorter and dimmer than the inter-cluster divider
    /// to signal "this is still inside the same chain."
    private var descendantDivider: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 32)
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 0.5)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("— no entries —")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            Text("Tap the mic below to start your ledger. Every dictation lands here and stays on this device.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Errors surface as an inline card in the log, not a system-style
    /// bottom toast. Design §4.d: "errors don't banner at bottom" — the
    /// user's attention is already on the log, not the system tray.
    ///
    /// Call-site (in `log`) positions the card immediately above the pill,
    /// which is where the user's eye lands by default (`defaultScrollAnchor(.bottom)`
    /// + pill-at-bottom layout). That reconciles with §4.d: the card is
    /// *inline content* adjacent to the pill, not a chrome overlay floating
    /// atop the scroll view.
    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(amber)
                .font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("SOMETHING BROKE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(amber)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(amber.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.vertical, 16)
    }

    /// Root transcript row — the one that anchors a cluster. When the
    /// cluster has descendants (`isSuperseded == true`) the body text
    /// renders dimmed to signal the user has already iterated past this
    /// draft. The eyebrow (`#NNNN · HH:MM · Mon DD`) stays at full
    /// intensity because the ledger index is still a valid reference.
    /// Body text for a transcript row. Long transcripts truncate to
    /// `collapsedRowLineLimit` lines with a "Show more" toggle underneath;
    /// tap expands to full text and swaps to "Show less." This is the
    /// per-transcript collapse the user asked for — distinct from
    /// `expandedClusterIDs` which groups related transcripts.
    ///
    /// Heuristic for "long enough to collapse": character count > ~180.
    /// That's roughly 5 wrapped lines at body font density; cheaper than
    /// measuring actual line count and robust enough for the common case.
    private func transcriptBody(_ entry: Transcript, isSuperseded: Bool) -> some View {
        let isLongEnoughToCollapse = entry.displayText.count > 180
        let isExpanded = expandedTranscriptIDs.contains(entry.id)
        let effectiveLineLimit: Int? = (isLongEnoughToCollapse && !isExpanded)
            ? collapsedRowLineLimit
            : nil

        return VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayText)
                .font(.body)
                .foregroundStyle(.white.opacity(isSuperseded ? 0.55 : 0.92))
                .lineSpacing(3)
                .textSelection(.enabled)
                .lineLimit(effectiveLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLongEnoughToCollapse {
                Button {
                    if isExpanded {
                        expandedTranscriptIDs.remove(entry.id)
                    } else {
                        expandedTranscriptIDs.insert(entry.id)
                    }
                } label: {
                    Text(isExpanded ? "SHOW LESS" : "SHOW MORE")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(amber.opacity(0.75))
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse transcript" : "Expand transcript")
            }
        }
    }

    private func rootRow(_ entry: Transcript, isSuperseded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(format: "#%04d", entry.ledgerIndex))
                    .foregroundStyle(amber)
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(entry.createdAt.formatted(.dateTime.hour().minute()))
                    .foregroundStyle(.white.opacity(0.45))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(entry.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if isSuperseded {
                    Text("SUPERSEDED")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(amber.opacity(0.55))
                }
            }
            .font(.system(.footnote, design: .monospaced).weight(.bold))

            transcriptBody(entry, isSuperseded: isSuperseded)

            actionRow(entry: entry)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Follow-up row. Indented, with an arrow + instruction-preview eyebrow
    /// in italic amber-dim to make the chain visually unambiguous. Body
    /// text renders at full intensity — this is the "live" content.
    private func descendantRow(_ entry: Transcript) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading rail — the indent + a faint vertical tick signals
            // "child of the entry above" without relying on color alone.
            VStack {
                Rectangle()
                    .fill(amber.opacity(0.35))
                    .frame(width: 2)
            }
            .frame(width: 32)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("↳")
                        .foregroundStyle(amber.opacity(0.8))
                    Text(entry.createdAt.formatted(.dateTime.hour().minute()))
                        .foregroundStyle(amber.opacity(0.65))
                    if let instruction = entry.instruction, !instruction.isEmpty {
                        Text("·").foregroundStyle(.white.opacity(0.3))
                        Text("\u{201C}\(instructionPreview(instruction))\u{201D}")
                            .italic()
                            .foregroundStyle(amber.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(String(format: "#%04d", entry.ledgerIndex))
                        .foregroundStyle(amber.opacity(0.55))
                }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))

                Text(entry.displayText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                actionRow(entry: entry)
            }
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(entry: Transcript) -> some View {
        HStack(spacing: 18) {
            actionButton("COPY") { copy(entry) }
            ShareLink(item: entry.displayText) {
                Text("SHARE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            actionButton("DELETE", destructive: true) {
                pendingDeletion = entry
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    /// Clamp instruction previews so a rambling command ("make this more
    /// casual and also translate it to spanish and add emojis") doesn't
    /// overflow the eyebrow line. Ellipsis on truncate.
    private func instructionPreview(_ instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 48
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    private func actionButton(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .tracking(2)
                .foregroundStyle(destructive ? Color.red.opacity(0.85) : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var timeString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    private func toggleRecording() {
        errorMessage = nil

        switch phase {
        case .idle:
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing, .cleaning:
            cancelPostProcessing()
        case .transcribing:
            lifecycleLog.info("Record button — tap ignored (phase: \(String(describing: phase), privacy: .public))")
        }
    }

    private func cancelPostProcessing() {
        lifecycleLog.info("cancelPostProcessing — forwarding cancel to shared coordinator")
        DictationPostProcessingCoordinator.shared.cancel()
    }

    private func dismissFollowUpWindow() {
        lifecycleLog.info("dismissFollowUpWindow — forwarding dismiss to activity coordinator")
        Task { @MainActor in
            await DictationActivityCoordinator.shared.dismissFollowUpWindow()
            phase = .idle
        }
    }

    private func startRecording() {
        lifecycleLog.info("startRecording — dispatching to RecordingService.start()")
        activeTask?.cancel()
        activeTask = Task {
            do {
                try await recordingService.start()
                await MainActor.run {
                    lifecycleLog.info("startRecording — service ready, phase → recording")
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                    let now = Date()
                    startedAt = now
                    elapsed = 0
                    phase = .recording
                    startVUTimer()
                }
            } catch {
                await MainActor.run {
                    lifecycleLog.error("startRecording — failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = "Could not start recording: \(error.localizedDescription)"
                    phase = .idle
                }
            }
        }
    }

    private func stopAndProcess() {
        lifecycleLog.info("stopAndProcess — dispatching to RecordingService.stop()")
        stopVUTimer()
        let recordingStartedAt = startedAt ?? Date()
        activeTask?.cancel()
        activeTask = Task {
            do {
                let samples = try await recordingService.stop()
                await MainActor.run {
                    lifecycleLog.info("stopAndProcess — got \(samples.count, privacy: .public) samples, phase → transcribing")
                    stopHaptic.impactOccurred()
                    stopHaptic.prepare()
                    phase = .transcribing
                }

                let raw = try await transcriptionService.transcribe(samples: samples)
                lifecycleLog.info("stopAndProcess — transcript length \(raw.count, privacy: .public)")

                // `DictationController` is @MainActor + AnyObject but not Sendable,
                // so we can't capture it across an actor boundary. Run the whole
                // pipeline call on MainActor via a detached @MainActor Task — the
                // controller is fetched and used entirely inside that isolation.
                try await Task { @MainActor in
                    try await DictationPipeline.completeEndOfRecording(
                        transcript: raw,
                        startedAt: recordingStartedAt,
                        controller: DictationIntentBridge.shared.controller
                    )
                }.value

                await MainActor.run {
                    lifecycleLog.info("stopAndProcess — complete via shared dictation pipeline")
                    successHaptic.notificationOccurred(.success)
                    successHaptic.prepare()
                    phase = .idle
                    startedAt = nil
                    elapsed = 0
                    vuBars = Array(repeating: 0.14, count: 12)
                }
            } catch {
                await MainActor.run {
                    lifecycleLog.error("stopAndProcess — failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = "Dictation failed: \(error.localizedDescription)"
                    phase = .idle
                    startedAt = nil
                    elapsed = 0
                    vuBars = Array(repeating: 0.14, count: 12)
                }
            }
        }
    }

    // MARK: - VU animation

    /// Drive the pill's VU waterfall from `RecordingService.currentAmplitude`.
    ///
    /// The strip is a 12-sample **waterfall** — each tick drops the oldest
    /// value on the left and appends the newest amplitude on the right, so
    /// the user reads a scrolling ~1 s history of their voice. This is NOT
    /// a spectrum analyzer; `currentAmplitude` is a single scalar per tick,
    /// already `[0, 1]`-normalized by `RecordingService` (sqrt-compressed
    /// RMS, tuned so ambient ≈ 0.14, quiet speech ≈ 0.35, normal ≈ 0.63,
    /// loud ≈ 0.89). Do NOT re-scale the value here or in `vuStrip`'s
    /// `frame(height:)` — the compression is already perceptually right.
    ///
    /// Sampling rate is 80 ms, not the raw ~30 Hz publication rate.
    /// Binding 1:1 to the observable at 30 Hz would spin the 12-bar
    /// waterfall through a full turnover in ~400 ms, which reads as
    /// frenetic jitter rather than "I can see my voice." At 80 ms the
    /// strip takes ~1 s to fully repopulate with live data after start.
    ///
    /// `currentAmplitude == nil` means the service is not recording
    /// (teardown happens before the `.idle` phase reset fires). The `?? 0`
    /// fall-through means any amplitude samples that race with teardown
    /// ebb the waterfall to silence rather than freezing it at a stale
    /// value.
    ///
    /// Contract lives with recording-engineer-3 in `RecordingService.swift`;
    /// the compression curve + publication gate are their lane.
    private func startVUTimer() {
        vuTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            Task { @MainActor in
                guard phase == .recording else { return }
                if let startedAt {
                    elapsed = Date().timeIntervalSince(startedAt)
                }
                let amp = CGFloat(recordingService.currentAmplitude ?? 0)
                var next = vuBars
                next.removeFirst()
                next.append(amp)
                vuBars = next
            }
        }
        vuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopVUTimer() {
        vuTimer?.invalidate()
        vuTimer = nil
    }

    // MARK: - Row actions

    private func copy(_ entry: Transcript) {
        UIPasteboard.general.string = entry.displayText
        actionHaptic.impactOccurred()
        actionHaptic.prepare()
    }

    private func confirmDelete(_ entry: Transcript) {
        actionHaptic.impactOccurred()
        actionHaptic.prepare()
        modelContext.delete(entry)
        try? modelContext.save()
        pendingDeletion = nil
    }
}

#Preview("Ledger — empty") {
    ContentView()
        .environment(RecordingService())
        .environment(TranscriptionService())
        .environment(CleanupService())
        .modelContainer(for: Transcript.self, inMemory: true)
}
