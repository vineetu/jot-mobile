import SwiftData
import SwiftUI
import UIKit
import os.log

private let detailLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcript-detail")

/// Editorial transcript-detail surface (Phase 3 of the UX overhaul, Mockup 09
/// + Mockup 11).
///
/// ## What's shown
///
/// - **Top toolbar**: glass back chevron (left) + glass sparkle Rewrite
///   button (right). No native nav-bar chrome — the surface looks like the
///   mockup, not like a stock `NavigationStack` detail.
/// - **Subline**: "11 hours ago · 52 words · 0:21" derived from `Transcript`
///   fields (no semantic title field exists in v1 per plan §10.1, so the
///   editorial title slot is intentionally hidden).
/// - **Original / Rewrite tab**: 2-pill segmented control. Original reads
///   `transcript.disfluencyCleanedText ?? transcript.text` in Fraunces 24pt
///   regular roman — so the user sees the lightly-cleaned version (um/uh
///   removed) by default, with the raw audit text preserved underneath in
///   the model. Rewrite reads `transcript.cleanedText` in Fraunces 19pt
///   italic. If `cleanedText` is nil, the Rewrite tab shows a "Tap Rewrite
///   to generate" empty state with a blue CTA. `cleanedText` is reserved
///   for AI Rewrite output — disfluency cleanup never lands there.
/// - **Floating ActionBar**: Copy / Share / Rewrite (prominent blue pill) /
///   More — anchored to the bottom safe area, glass-heavy.
///
/// ## Tags / title intentionally absent
///
/// Per plan §10.1 and §10.2 the v1 defaults are HIDE-rather-than-shell:
/// `Transcript` has no `title` or `tags` field, so adding the visual slots
/// without backend persistence would be misleading. Leave them out entirely;
/// the body reads as a clean editorial surface without them.
///
/// ## AI rewrite (preserves the existing call site)
///
/// The manual Transform button on the floating ActionBar drives the same
/// in-process path the prior detail view used:
/// `LLMClientFactory.shared.client().rewrite(...)` (see plan §13 risk 8).
/// Keyboard-originated rewrites enter the same view with an explicit intent
/// and mirror only their terminal result back through App Group for pasteback.
/// Re-running rewrite overwrites `cleanedText` in place — there is no rewrite
/// history slot in the SwiftData model and the plan explicitly forbids growing
/// one (§6.2 / §14.4).
struct TranscriptDetailView: View {
    let transcript: Transcript
    let keyboardRewriteIntent: KeyboardRewriteRouter.KeyboardRewriteTarget?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(
        transcript: Transcript,
        keyboardRewriteIntent: KeyboardRewriteRouter.KeyboardRewriteTarget? = nil
    ) {
        self.transcript = transcript
        self.keyboardRewriteIntent = keyboardRewriteIntent
    }

    enum DetailTab: String, CaseIterable {
        case original
        case rewrite

        var label: String {
            switch self {
            case .original: return "Original"
            case .rewrite:  return "Rewrite"
            }
        }
    }

    @State private var selectedTab: DetailTab = .original
    @State private var pendingDeletion = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var showShareSheet = false

    // MARK: - Phase 4 sheet state
    //
    // The Rewrite button now branches on the adapter's status:
    //   - `.ready`     → present `RewritePickerSheet` (Mockup 10).
    //   - `.notReady`  → present `DownloadPitchSheet` (Mockup 12).
    //   - `.downloading` / `.loading` → the action-bar Rewrite pill is
    //     disabled (see `isMagicEnabled`). The legacy in-line "Rewriting…"
    //     card already covers the in-progress rewrite case; the new
    //     download / load progress is surfaced in `AIRewriteSettingsView`'s
    //     banner. No tiny status sheet here — disabling the button keeps
    //     the detail surface uncluttered and matches the action-bar's
    //     existing accessibility hint copy.
    //   - `.error` / `.evicted` → button stays disabled with a hint.
    //
    // Both sheets are independent of the existing `rewriteState` machine;
    // the picker fires `startRewrite(...)` which drives that state, and
    // the download sheet fires the adapter's `warm()` flow.
    @State private var showRewritePicker: Bool = false
    @State private var showDownloadPitch: Bool = false
    @State private var showNewPromptHint: Bool = false
    /// `nil` until `.onAppear` resolves the factory's client. Used to mirror
    /// `LLMClientStatus` synchronously so the Rewrite button can branch
    /// without a `await`.
    @State private var clientAdapter: LLMClientUIAdapter?

    // MARK: - AI rewrite state
    //
    // The state machine mirrors the prior detail view: `idle` → user taps
    // Rewrite (with prompt) → `running` → either `idle` (on apply / success)
    // or `error`. The single-rewrite contract means there's no separate
    // "proposing" state — a successful rewrite is written into
    // `cleanedText` immediately and the Rewrite tab refreshes.

    enum RewriteState: Equatable {
        case idle
        case running
        case error(String)
    }

    @State private var rewriteState: RewriteState = .idle
    @State private var activeRewriteTask: Task<Void, Never>?
    @State private var savedPrompts: [SavedPrompt] = []
    @State private var didFireKeyboardIntent: Bool = false
    /// Explicit lockout for manual Transform while a keyboard-originated
    /// rewrite is mid-flight. `rewriteState == .running` already covers
    /// the common case, but this flag survives any state-machine glitches
    /// and is the durable answer to "no, the user can't preempt an
    /// auto-rewrite via the Transform button."
    @State private var keyboardRewriteInFlight: Bool = false
    /// Tracks the most recent rewrite time *for this session*. Set on a
    /// successful in-process rewrite so the attribution line can render
    /// "just now" semantics (plan §6.2). Remains nil when the Rewrite tab
    /// is showing a `cleanedText` written in a prior session — there's no
    /// `cleanedAt` on the SwiftData schema, so falling back to
    /// `transcript.createdAt` would lie. We drop the timestamp instead.
    @State private var lastRewriteAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            // Shared adaptive wallpaper — same one RecentsView uses, so the
            // app reads as one continuous surface across both screens and the
            // dark/light switch is handled in one place (WallpaperBackground).
            WallpaperBackground()

            VStack(alignment: .leading, spacing: 14) {
                topToolbar
                    .padding(.top, 6)

                sublineRow

                tabSelector

                if rewriteState == .running {
                    runningRewriteCard
                } else if case .error(let message) = rewriteState {
                    errorCard(message: message)
                }

                transcriptCard
                    .frame(maxHeight: .infinity)

                if selectedTab == .rewrite, hasRewrite {
                    attributionLine
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, JotDesign.Spacing.pageMargin)
            .padding(.bottom, 100) // leave room for ActionBar

            actionBar
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.bottom, 14)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Re-apply AFTER the chrome-hiding modifiers above — iOS disables
        // the interactive pop gesture when the back button is hidden, and
        // a root-level NavigationStack modifier can be undone by that
        // disable. Putting the enable here ensures the gesture survives.
        .enableInteractivePopGesture()
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $pendingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete()
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = false
            }
        }
        .sheet(isPresented: $showRewritePicker) {
            // Mockup 10 / plan §6.1 — bottom-sheet picker for the user's
            // saved prompts. The "+ New prompt" affordance dismisses the
            // sheet and surfaces a follow-up alert that points the user
            // at Settings → AI Rewrite, since this surface intentionally
            // does NOT host inline prompt editing.
            RewritePickerSheet(
                wordCount: sourceWordCount,
                modelDisplayName: rewriteModelDisplayName,
                prompts: savedPrompts,
                onPick: { prompt in
                    startRewrite(with: prompt)
                },
                onNewPrompt: {
                    showNewPromptHint = true
                }
            )
        }
        .sheet(isPresented: $showDownloadPitch) {
            // Mockup 12 / plan §6.3 — opt-in pitch. Download tap forwards
            // to the adapter's `warm()` lifecycle; the in-flight banner
            // surfaces inside `AIRewriteSettingsView` (plan §10.6).
            DownloadPitchSheet(
                modelDisplayName: rewriteModelDisplayName,
                onDownload: {
                    clientAdapter?.warm()
                }
            )
        }
        .alert(
            "Create a new prompt in Settings",
            isPresented: $showNewPromptHint
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add and edit rewrite prompts in Settings → AI Rewrite.")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [bodyTextForActiveTab])
        }
        .onAppear {
            copyHaptic.prepare()
            refreshRewriteAvailability()
            // Default to Rewrite tab when a rewrite already exists — the
            // user almost always cares about their latest pass once they've
            // run one. Falls back to Original when no rewrite is saved.
            if hasRewrite {
                selectedTab = .rewrite
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            activeRewriteTask?.cancel()
            activeRewriteTask = nil
            // Stop the adapter's polling task so we don't keep reading
            // `client.status` while the detail surface is off-window.
            // Re-installed by the next `.onAppear` → `refreshRewriteAvailability`.
            clientAdapter?.stop()
        }
        .task {
            refreshRewriteAvailability()
            if let intent = keyboardRewriteIntent, !didFireKeyboardIntent {
                didFireKeyboardIntent = true
                autoFireKeyboardRewrite(intent: intent)
            }
        }
    }

    // MARK: - Top toolbar

    private var topToolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: "Back"
            ) {
                dismiss()
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func glassCircleButton(
        systemImage: String,
        accessibilityLabel: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.jotInk : Color.jotMuteWeak)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subline

    private var sublineRow: some View {
        HStack(spacing: 6) {
            Text(relativeDateText)
            Text("·")
                .foregroundStyle(Color.jotMuteWeak)
            Text(wordCountText)
            if let durationText {
                Text("·")
                    .foregroundStyle(Color.jotMuteWeak)
                Text(durationText)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.jotMute)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tab selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            selectedTab == tab ? Color.jotInk : Color.jotMute
                        )
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            ZStack {
                                if selectedTab == tab {
                                    // Active tab: lifted glass — adaptive
                                    // `.regularMaterial` over the rail, with
                                    // the same hairline as `LiquidGlassCard`.
                                    Capsule(style: .continuous)
                                        .fill(.regularMaterial)
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(activeTabHairline, lineWidth: 0.5)
                                        )
                                        .shadow(color: Color.black.opacity(activeTabShadowOpacity), radius: 4, x: 0, y: 2)
                                }
                            }
                            .padding(3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.label) tab")
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(
            // Rail: frosted glass — `.ultraThinMaterial` lets the wallpaper
            // bleed through so the pill reads as a chrome surface over the
            // page rather than as a separate floating card. Auto-adapts to
            // dark mode (iOS picks the dark blur tint over our navy wallpaper).
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(railHairline, lineWidth: 0.5)
        )
    }

    /// Adaptive hairline matching `LiquidGlassCard`: thin black in light,
    /// thin white in dark — reads as a rim on either material.
    private var railHairline: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.10)
                : UIColor(white: 0.0, alpha: 0.06)
        })
    }

    private var activeTabHairline: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.14)
                : UIColor(white: 0.0, alpha: 0.05)
        })
    }

    private var activeTabShadowOpacity: Double {
        // No shadow in dark — invisible on dark wallpaper, just adds murk.
        // Light keeps the subtle lift the prior pill had.
        colorScheme == .dark ? 0 : 0.07
    }

    // MARK: - Transcript card (fills remaining viewport between chrome and ActionBar)

    @ViewBuilder
    private var transcriptCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            Group {
                switch selectedTab {
                case .original:
                    // Disfluency cleanup is treated as part of the original
                    // transcript — show the cleaned version when present so
                    // the user sees um/uh removed in their default view.
                    // The truly-raw `transcript.text` remains in the model
                    // for future use; we just don't surface it here.
                    transcriptScrollContent(
                        text: transcript.disfluencyCleanedText ?? transcript.text
                    )
                case .rewrite:
                    if let cleaned = transcript.cleanedText, !cleaned.isEmpty {
                        transcriptScrollContent(text: cleaned)
                    } else if rewriteState == .running {
                        // A rewrite is mid-flight — the `runningRewriteCard`
                        // already surfaces a "Rewriting…" indicator above
                        // this card. Showing the "No rewrite yet · Tap
                        // Rewrite" empty state at the same time tells the
                        // user to do what they just did. Leave the card
                        // empty until the rewrite lands.
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        rewriteEmptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Scrollable body text styled to match Recents row typography (system
    /// sans-serif) but at a larger reading size. The card itself is fixed-height
    /// (fills the viewport between the tab pill and ActionBar); the ScrollView
    /// inside lets long transcripts scroll without growing the card.
    @ViewBuilder
    private func transcriptScrollContent(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 17, weight: .regular, design: .default))
                .tracking(-0.1)
                .lineSpacing(4)
                .foregroundStyle(Color.jotPageInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(selectedTab)
    }

    private var attributionLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.jotBlueTop)
            Text(attributionText)
                .font(.system(size: 12))
                .foregroundStyle(Color.jotMute)
        }
        .accessibilityElement(children: .combine)
    }

    /// Attribution copy for a freshly-rendered Rewrite tab. When this view
    /// has just produced a rewrite (`lastRewriteAt` set this session), uses
    /// "just now" semantics per plan §6.2. When the Rewrite tab is showing
    /// a `cleanedText` from a prior session, the schema has no `cleanedAt`
    /// to read from — so we drop the timestamp entirely rather than fall
    /// back to `transcript.createdAt`, which would lie.
    private var attributionText: String {
        let base = "Rewritten with \(rewriteModelDisplayName)"
        guard let lastRewriteAt else { return base }
        let relative = lastRewriteAt.formatted(.relative(presentation: .named))
        return "\(base) · \(relative)"
    }

    private var rewriteEmptyState: some View {
        VStack(spacing: 14) {
            IconBox(symbol: "sparkles", tint: Color.jotBlueTop, size: 44)

            VStack(spacing: 6) {
                Text("No rewrite yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                Text("Tap Rewrite to polish this transcript with \(rewriteModelDisplayName).")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.center)
            }

            Button(action: presentRewritePicker) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Rewrite")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.jotBlueTop)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isMagicEnabled)
            .opacity(isMagicEnabled ? 1.0 : 0.5)
            .accessibilityLabel("Generate rewrite")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Rewrite running / error cards

    private var runningRewriteCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Rewriting…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.jotInk)
            Spacer()
            Button("Cancel") {
                cancelActiveRewrite()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.jotBlueTop)
            .accessibilityLabel("Cancel rewrite")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.jotMuteWeak.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func errorCard(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.jotWarning)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                rewriteState = .idle
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.jotMute)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotWarning.opacity(0.10))
        )
    }

    // MARK: - ActionBar

    private var actionBar: some View {
        ActionBar(
            leading: [
                ActionBarItem(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    label: "Copy",
                    accessibilityLabel: didCopy ? "Copied to clipboard" : "Copy transcript"
                ) {
                    copy()
                },
                ActionBarItem(
                    systemImage: "square.and.arrow.up",
                    label: "Share",
                    accessibilityLabel: "Share transcript"
                ) {
                    showShareSheet = true
                }
            ],
            primary: ActionBarItem(
                systemImage: "sparkles",
                label: "Transform",
                accessibilityLabel: rewriteAccessibilityLabel
            ) {
                presentRewritePicker()
            },
            trailing: [
                ActionBarItem(
                    systemImage: "trash",
                    label: "Delete",
                    accessibilityLabel: "Delete transcript"
                ) {
                    pendingDeletion = true
                }
            ]
        )
    }

    // MARK: - Magic gate

    private var hasRewrite: Bool {
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty { return true }
        return false
    }

    /// Live LLM status mirrored from the adapter. Defaults to `.notReady`
    /// before the adapter has been resolved (or while the master toggle
    /// is OFF and no adapter has been built).
    private var llmStatus: LLMClientStatus {
        clientAdapter?.observableStatus ?? .notReady
    }

    /// The Rewrite button is interactive whenever the master toggle is
    /// ON and the LLM is either `.ready` (→ picker), `.notReady`
    /// (→ download pitch), or `.evicted` (→ kick `warm()` + open picker).
    /// `.evicted` means the weights are still on disk — just unloaded
    /// from memory — so the recovery is a fast in-process reload, NOT a
    /// 2.4 GB re-download. `.downloading` / `.loading` / `.error` stay
    /// disabled — those are transient or recoverable states with their
    /// own affordances in Settings. We also disable during an in-flight
    /// rewrite (`rewriteState == .running`) so the user can't fire a
    /// second request while one is mid-flight.
    private var isMagicEnabled: Bool {
        guard AppGroup.aiRewriteEnabled else { return false }
        guard !savedPrompts.isEmpty else { return false }
        guard rewriteState != .running else { return false }
        guard !keyboardRewriteInFlight else { return false }
        switch llmStatus {
        case .ready, .notReady, .evicted:
            return true
        case .downloading, .loading, .error:
            return false
        }
    }

    private var rewriteAccessibilityLabel: String {
        if rewriteState == .running { return "Rewriting" }
        if !AppGroup.aiRewriteEnabled {
            return "Rewrite unavailable — turn on AI rewrite in Settings"
        }
        if savedPrompts.isEmpty {
            return "Rewrite unavailable — no saved prompts"
        }
        switch llmStatus {
        case .ready:
            return "Rewrite with AI"
        case .notReady:
            return "Add AI to Jot"
        case .downloading:
            return "Rewrite unavailable — AI model is downloading"
        case .loading:
            return "Rewrite unavailable — AI model is loading"
        case .evicted:
            // Weights are still on disk; the next tap kicks a fast warm.
            return "Rewrite is loading the AI model — this should be quick"
        case .error:
            return "Rewrite unavailable — open Settings to retry"
        }
    }

    /// Called by the action-bar Rewrite pill + the top sparkle button +
    /// the empty-state CTA. Branches on the live LLM status:
    ///   - `.ready`    → present `RewritePickerSheet` (Mockup 10).
    ///   - `.evicted`  → kick `warm()` then present the picker. Weights
    ///                   are still on disk, so this is a fast in-process
    ///                   reload — NOT a 2.4 GB re-download. The picker
    ///                   itself is passive; the rewrite path inside
    ///                   `Phi4Client.rewrite` re-calls `warm()` so picking
    ///                   a prompt during the warm window is safe.
    ///   - `.notReady` → present `DownloadPitchSheet` (Mockup 12).
    /// Other states are pre-gated by `isMagicEnabled`, so this method
    /// becomes a no-op when the button shouldn't have fired.
    private func presentRewritePicker() {
        guard isMagicEnabled else { return }
        guard !savedPrompts.isEmpty else { return }
        switch llmStatus {
        case .ready:
            showRewritePicker = true
        case .evicted:
            // Kick the in-process reload so the model is warm by the time
            // the user finishes picking a prompt. `warm()` is idempotent
            // and the rewrite path warms again before generating, so the
            // worst case is a brief block on the first token — never a
            // re-download.
            clientAdapter?.warm()
            showRewritePicker = true
        case .notReady:
            showDownloadPitch = true
        case .downloading, .loading, .error:
            return
        }
    }

    /// Word count of the source transcript (Original tab). Surfaced in the
    /// rewrite picker's sub-line per Mockup 10. Reads the disfluency-cleaned
    /// text when present — the picker always rewrites what the user sees in
    /// the Original tab, which after disfluency cleanup is the lightly-edited
    /// version (um/uh removed). Truly-raw `transcript.text` remains in the
    /// model but is not surfaced to the rewrite path.
    private var sourceWordCount: Int {
        rewriteSourceText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    /// Text the rewrite path consumes — equals what the Original tab shows.
    /// Disfluency-cleaned when that pass ran and changed text, otherwise the
    /// raw transcript. Single source of truth for the AI Rewrite input across
    /// the manual Transform button and the keyboard-originated rewrite path.
    private var rewriteSourceText: String {
        transcript.disfluencyCleanedText ?? transcript.text
    }

    // MARK: - Derived strings

    private var relativeDateText: String {
        transcript.createdAt.formatted(.relative(presentation: .named))
    }

    private var wordCountText: String {
        let count = bodyTextForActiveTab
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        return count == 1 ? "1 word" : "\(count) words"
    }

    private var durationText: String? {
        guard let duration = transcript.durationSeconds else { return nil }
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Body text the share + word-count read from — follows the currently
    /// selected tab so "52 words" matches what the user is looking at.
    /// Original returns the disfluency-cleaned version when present (matches
    /// what the Original tab renders); Rewrite returns the AI Rewrite output,
    /// or — when no rewrite has been produced — falls back to the same
    /// disfluency-cleaned original so Share/Copy on an empty Rewrite tab
    /// still does something sensible.
    private var bodyTextForActiveTab: String {
        switch selectedTab {
        case .original:
            return transcript.disfluencyCleanedText ?? transcript.text
        case .rewrite:
            return transcript.cleanedText
                ?? transcript.disfluencyCleanedText
                ?? transcript.text
        }
    }

    /// Display name for the rewrite-model attribution line.
    ///
    /// Routes through `JotDesign.activeRewriteModelDisplayName`, which
    /// itself reads `LLMClientFactory.shared.currentProvider.displayName`.
    /// Single source of truth for the model brand string across the
    /// transcript-detail attribution, the rewrite-empty CTA copy, and
    /// the rewrite picker sheet's subline.
    private var rewriteModelDisplayName: String {
        JotDesign.activeRewriteModelDisplayName
    }

    // MARK: - Actions

    private func copy() {
        UIPasteboard.general.string = bodyTextForActiveTab
        copyHaptic.impactOccurred()
        copyHaptic.prepare()
        UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")

        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1_300))
            } catch {
                return
            }
            didCopy = false
        }
    }

    private func delete() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil

        dismiss()
        Task { @MainActor in
            modelContext.delete(transcript)
            do {
                try modelContext.save()
                TranscriptHistoryMirror.refresh(from: modelContext)
                // Wake the keyboard so its RecentsStrip drops the row
                // immediately rather than on next presentation.
                CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            } catch {
                modelContext.rollback()
                detailLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Rewrite lifecycle

    /// Re-syncs the saved-prompts list and the LLM client adapter.
    ///
    /// The adapter is built lazily on first use so a transcript-detail
    /// surface that never taps Rewrite never pays the cost of polling.
    /// When the master AI Rewrite toggle is off, we still resolve the
    /// adapter — the picker / pitch sheets are gated by `isMagicEnabled`,
    /// which respects the toggle — but we *don't* call `warm()` from
    /// here. Auto-warm on appear is owned by `AIRewriteSettingsView`
    /// (plan §6.4 / §10.6); the detail view stays passive.
    private func refreshRewriteAvailability() {
        savedPrompts = SavedPromptStore.all()
        if let adapter = clientAdapter {
            // Existing adapter — restart polling in case the previous
            // `.onDisappear` stopped it.
            adapter.start()
        } else {
            let client = LLMClientFactory.shared.client()
            let adapter = LLMClientUIAdapter(client: client)
            adapter.start()
            clientAdapter = adapter
        }
    }

    /// Kicks off an in-process rewrite. Mirrors the previous detail view's
    /// call site at the same `LLMClientFactory.shared.client().rewrite(...)`
    /// path so the backend boundary is preserved exactly (plan §13 risk 8).
    /// On success the rewrite is persisted to `cleanedText` immediately and
    /// the Rewrite tab refreshes — there is no separate "propose / apply"
    /// modal step in v1, per the single-rewrite contract (§6.2).
    private func startRewrite(with prompt: SavedPrompt) {
        // The user is "rewriting what they see" — feed the AI Rewrite the
        // same text the Original tab displays (disfluency-cleaned when that
        // pass ran). Sending the truly-raw text behind their back would
        // re-introduce um/uh into the rewrite input and confuse the output.
        let source = rewriteSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            rewriteState = .error("Transcript is empty.")
            return
        }
        guard isMagicEnabled else { return }

        activeRewriteTask?.cancel()
        rewriteState = .running
        selectedTab = .rewrite

        let promptText = prompt.systemPrompt
        let task = Task { @MainActor in
            do {
                let result = try await LLMClientFactory.shared.client().rewrite(
                    text: source,
                    systemPrompt: promptText
                )
                try Task.checkCancellation()
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    rewriteState = .error("Rewrite returned no text.")
                    return
                }
                transcript.cleanedText = trimmed
                do {
                    try modelContext.save()
                    TranscriptHistoryMirror.refresh(from: modelContext)
                    // The keyboard's RecentsStrip renders `cleaned ?? raw`;
                    // notify it that the mirror was rewritten so the new
                    // cleaned text shows up without a presentation cycle.
                    CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
                    lastRewriteAt = Date()
                    rewriteState = .idle
                    detailLog.info(
                        "Transcript rewrite SUCCESS prompt=\(prompt.id, privacy: .public) inputChars=\(source.count) outputChars=\(trimmed.count)"
                    )
                } catch {
                    modelContext.rollback()
                    rewriteState = .error("Couldn't save: \(error.localizedDescription)")
                    detailLog.error(
                        "Transcript rewrite save failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            } catch is CancellationError {
                rewriteState = .idle
                detailLog.info("Transcript rewrite cancelled prompt=\(prompt.id, privacy: .public)")
            } catch {
                rewriteState = .error(error.localizedDescription)
                detailLog.error(
                    "Transcript rewrite FAILED prompt=\(prompt.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        activeRewriteTask = task
    }

    private func autoFireKeyboardRewrite(intent: KeyboardRewriteRouter.KeyboardRewriteTarget) {
        // Preflight: if a NEWER job has already taken the slot (e.g.,
        // ContentView released a transient fetch miss and the user
        // re-tapped from the keyboard before this view's .task fired),
        // don't waste an MLX inference + a Transcript.cleanedText write.
        // Terminal delivery would be dropped downstream anyway, but the
        // compute and on-disk side effects are wasteful.
        guard AppGroup.rewriteJobID == intent.jobID else {
            detailLog.notice("autoFireKeyboardRewrite: jobID slot moved on; skipping")
            return
        }

        guard let prompt = SavedPromptStore.all().first(where: { $0.id == intent.promptID }) else {
            writeKeyboardError("Prompt not found", sessionID: intent.sessionID)
            return
        }

        startKeyboardOriginatedRewrite(with: prompt, intent: intent)
    }

    private func startKeyboardOriginatedRewrite(
        with prompt: SavedPrompt,
        intent: KeyboardRewriteRouter.KeyboardRewriteTarget
    ) {
        // Same "rewrite what the user sees" rule as the manual Transform
        // path — feed the disfluency-cleaned text when present so the AI
        // Rewrite input matches the Original tab.
        let source = rewriteSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            let message = "Transcript is empty."
            rewriteState = .error(message)
            if AppGroup.rewriteJobID == intent.jobID {
                writeKeyboardError(message, sessionID: intent.sessionID)
            }
            return
        }

        activeRewriteTask?.cancel()
        keyboardRewriteInFlight = true
        rewriteState = .running
        selectedTab = .rewrite

        let promptText = prompt.systemPrompt
        let jobID: UUID? = intent.jobID
        let task = Task { @MainActor in
            // Defer clears the lockout on every exit path — success,
            // .error, CancellationError, save failure, or any future
            // catch branch. No need to remember to nil it in each leg.
            defer { keyboardRewriteInFlight = false }
            do {
                try await Self.waitUntilForeground(timeout: 10)
                let result = try await LLMClientFactory.shared.client().rewrite(
                    text: source,
                    systemPrompt: promptText
                )
                try Task.checkCancellation()
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    let message = "Rewrite returned no text."
                    rewriteState = .error(message)
                    guard AppGroup.rewriteJobID == jobID else { return }
                    writeKeyboardError(message, sessionID: intent.sessionID)
                    return
                }
                transcript.cleanedText = trimmed
                do {
                    try modelContext.save()
                    TranscriptHistoryMirror.refresh(from: modelContext)
                    // The keyboard's RecentsStrip renders `cleaned ?? raw`;
                    // notify it that the mirror was rewritten so the new
                    // cleaned text shows up without a presentation cycle.
                    CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
                    guard AppGroup.rewriteJobID == jobID else {
                        detailLog.notice("Keyboard-originated rewrite finished but App Group job changed; dropping terminal write.")
                        return
                    }
                    AppGroup.rewriteResult = trimmed
                    AppGroup.rewriteError = nil
                    AppGroup.rewriteResultSessionID = intent.sessionID
                    AppGroup.rewriteJobID = nil
                    RewriteNotifications.postCompleted()
                    lastRewriteAt = Date()
                    rewriteState = .idle
                    detailLog.info(
                        "Keyboard-originated transcript rewrite SUCCESS prompt=\(prompt.id, privacy: .public) sessionID=\(intent.sessionID, privacy: .public) inputChars=\(source.count) outputChars=\(trimmed.count)"
                    )
                } catch {
                    modelContext.rollback()
                    let message = "Couldn't save: \(error.localizedDescription)"
                    rewriteState = .error(message)
                    guard AppGroup.rewriteJobID == jobID else { return }
                    writeKeyboardError(message, sessionID: intent.sessionID)
                    detailLog.error(
                        "Keyboard-originated transcript rewrite save failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            } catch is CancellationError {
                rewriteState = .idle
                guard AppGroup.rewriteJobID == jobID else { return }
                writeKeyboardError(RewriteNotifications.cancelledSentinel, sessionID: intent.sessionID)
                detailLog.info(
                    "Keyboard-originated transcript rewrite cancelled prompt=\(prompt.id, privacy: .public) sessionID=\(intent.sessionID, privacy: .public)"
                )
            } catch {
                let message = error.localizedDescription
                rewriteState = .error(message)
                guard AppGroup.rewriteJobID == jobID else { return }
                writeKeyboardError(message, sessionID: intent.sessionID)
                detailLog.error(
                    "Keyboard-originated transcript rewrite FAILED prompt=\(prompt.id, privacy: .public) sessionID=\(intent.sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        activeRewriteTask = task
    }

    private static func waitUntilForeground(timeout: TimeInterval) async throws {
        if UIApplication.shared.applicationState == .active { return }
        let deadline = Date().addingTimeInterval(timeout)
        while UIApplication.shared.applicationState != .active {
            if Date() >= deadline {
                throw NSError(
                    domain: "TranscriptDetailView",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Open Jot and try the rewrite again."]
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func writeKeyboardError(_ message: String, sessionID: UUID) {
        AppGroup.rewriteError = message
        AppGroup.rewriteResult = nil
        AppGroup.rewriteResultSessionID = sessionID
        AppGroup.rewriteJobID = nil
        RewriteNotifications.postCompleted()
    }

    private func cancelActiveRewrite() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil
        if case .running = rewriteState {
            rewriteState = .idle
        }
    }
}

// MARK: - Share sheet shim

/// Lightweight `UIActivityViewController` wrapper used by the ActionBar's
/// Share affordance. The system share sheet handles "copy", "save to files",
/// "share to messages", etc. — wiring it up here is the cheapest path to a
/// real Share button on a SwiftUI surface in iOS 26.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        TranscriptDetailView(
            transcript: Transcript(
                text: "This is the raw transcript that came straight out of Parakeet without any cleanup applied.",
                cleanedText: "This is the cleaned transcript with light edits applied.",
                ledgerIndex: 42
            )
        )
    }
    .modelContainer(for: Transcript.self, inMemory: true)
}
