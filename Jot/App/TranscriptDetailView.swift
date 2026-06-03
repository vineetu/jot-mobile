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
///   `transcript.text` in Fraunces 24pt regular roman — the published text
///   already has the always-on regex filler sweep (um/uh) baked in by the
///   dictation pipeline, so no separate render-time pass is needed here.
///   Rewrite reads `transcript.cleanedText` in Fraunces 19pt italic. If
///   `cleanedText` is nil, the Rewrite tab shows a "Tap Rewrite to
///   generate" empty state with a blue CTA. `cleanedText` is reserved
///   for AI Rewrite output.
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
    @State private var pendingDiscardRewrite = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Edit-mode state
    //
    // When `isEditing == true`, the currently-visible tab's transcript card
    // body becomes a `TextEditor` bound to `editorText`. The bottom
    // ActionBar swaps to an EditBar (Cancel / Save). The tab pill is
    // hidden — only one tab is editable at a time.
    //
    // `editTargetTab` is captured at edit-start so a user can't tab-switch
    // mid-edit; we re-enter via Cancel/Save first.
    //
    // `editError` surfaces inline copy when Save fails validation (Original
    // text can't be empty). The editor stays open so the user can fix it.
    @State private var isEditing = false
    @State private var editorText: String = ""
    @State private var editTargetTab: DetailTab = .original
    @State private var editError: String?
    // Plain @State (not @FocusState) so it can drive `InlineEditTextView`'s
    // first-responder via a Binding. The custom UITextView editor renders text
    // added/changed this session in italic; see `InlineEditTextView`.
    @State private var editorFocused: Bool = false
    /// Bumped on each `beginEdit` so the inline editor re-baselines the loaded
    /// text as "original" (regular) and clears its new-range (italic) tracking.
    @State private var editSessionToken: Int = 0

    /// The live caret/selection in the Edit editor, bound to `InlineEditTextView`
    /// so the italic-tracking editor can report and restore the caret.
    @State private var editorSelection: TextSelection?

    // MARK: - Phase 4 sheet state
    //
    // The Transform button now branches on the adapter's status:
    //   - `.ready`     → present `RewritePickerSheet`.
    //   - `.evicted`   → kick warm + present `RewritePickerSheet`.
    //   - `.notReady` / `.downloading` / `.loading` / `.error` OR empty
    //     prompts → present `AIRewriteSettingsView` as a sheet (single
    //     canonical setup surface — replaces the earlier
    //     `DownloadPitchSheet` upsell).
    //   - `.downloading` / `.loading` → the action-bar Transform pill is
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
    @State private var showAISettings: Bool = false
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

                if hasRewrite && !isEditing {
                    tabSelector
                }

                if let editError, isEditing {
                    editErrorCard(message: editError)
                } else if rewriteState == .running {
                    runningRewriteCard
                } else if case .error(let message) = rewriteState {
                    errorCard(message: message)
                }

                transcriptCard
                    .frame(maxHeight: .infinity)

                if selectedTab == .rewrite, hasRewrite, !isEditing {
                    attributionLine
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, JotDesign.Spacing.pageMargin)
            .padding(.bottom, 100) // leave room for ActionBar

            Group {
                if isEditing {
                    editBar
                } else {
                    actionBar
                }
            }
            .padding(.horizontal, JotDesign.Spacing.pageMargin)
            .padding(.bottom, 14)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Re-apply AFTER the chrome-hiding modifiers above — iOS disables
        // the interactive pop gesture when the back button is hidden, and
        // a root-level NavigationStack modifier can be undone by that
        // disable. Putting the enable here ensures the gesture survives.
        //
        // Gate on `!isEditing`: the back chevron and the SwiftUI
        // simultaneousGesture both refuse to dismiss during edit mode,
        // but UIKit's `interactivePopGestureRecognizer` lives one layer
        // below SwiftUI and isn't bound by either guard. Letting it fire
        // during edit mode would silently pop the view and discard the
        // user's unsaved TextEditor changes.
        .enableInteractivePopGesture(isEnabled: !isEditing)
        // Explicit left-edge swipe-to-back as a safety net. The system
        // `interactivePopGestureRecognizer` (re-enabled above) gets
        // swallowed on this view by the scrollable transcript card's
        // `.textSelection(.enabled)` — SwiftUI's text-selection touch
        // handler claims edge touches before the navigation controller
        // sees them. `simultaneousGesture` lets the drag fire alongside
        // selection without breaking copy/select. Trigger conditions:
        // - Drag starts within ~30pt of the screen's left edge
        // - Horizontal translation > 80pt to the right
        // - Movement is predominantly horizontal (|dx| > 1.5×|dy|) so a
        //   vertical scroll near the edge doesn't accidentally pop.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    let startX = value.startLocation.x
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let isEdgeStart = startX < 30
                    let isRightwardSwipe = dx > 80
                    let isMostlyHorizontal = abs(dx) > 1.5 * abs(dy)
                    if isEdgeStart && isRightwardSwipe && isMostlyHorizontal {
                        // Mirror the back-chevron's edit-mode lockout. A
                        // swipe-back while editing would silently destroy
                        // in-flight edits with no confirmation — refuse to
                        // dismiss, force the user through Cancel/Save.
                        guard !isEditing else { return }
                        dismiss()
                    }
                }
        )
        .confirmationDialog(
            hasRewrite
                ? "Delete this entry or just the rewrite?"
                : "Delete this entry?",
            isPresented: $pendingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete this entry", role: .destructive) {
                delete()
            }
            if hasRewrite {
                Button("Delete rewrite only", role: .destructive) {
                    discardRewrite()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = false
            }
        }
        .confirmationDialog(
            "Discard rewrite?",
            isPresented: $pendingDiscardRewrite,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                discardRewrite()
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardRewrite = false
            }
        } message: {
            Text("This removes the rewrite and restores the original. The rewrite cannot be recovered.")
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
        .sheet(isPresented: $showAISettings) {
            // Single canonical setup surface for AI Rewrite. Replaces the
            // earlier `DownloadPitchSheet` upsell — routing through
            // Settings means the user sees the same model strip /
            // progress UI no matter whether they tapped Transform from
            // the action bar or arrived from Settings directly. Tapping
            // Download inside the strip drives `LLMClientUIAdapter.warm()`.
            NavigationStack {
                AIRewriteSettingsView()
            }
        }
        .alert(
            "Create a new prompt in Settings",
            isPresented: $showNewPromptHint
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add and edit rewrite prompts in Settings → AI Rewrite.")
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
            // While editing, the back chevron is disabled so the user must
            // explicitly Cancel or Save — otherwise a swipe-back would
            // silently discard their in-flight edits with no confirmation.
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: isEditing ? "Back disabled while editing" : "Back",
                enabled: !isEditing
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

            Spacer(minLength: 0)
        }
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
                if isEditing {
                    transcriptEditor
                } else {
                    switch selectedTab {
                    case .original:
                        // The published text already has the always-on regex
                        // filler sweep baked in by the dictation pipeline, so
                        // just render `transcript.text` directly.
                        transcriptScrollContent(
                            text: transcript.text
                        )
                    case .rewrite:
                        // Display priority: user's edit > model's rewrite.
                        // `cleanedText` stays frozen as the training "before"
                        // while `rewriteUserEdit` is the user-visible "after".
                        if let displayed = displayedRewriteText, !displayed.isEmpty {
                            transcriptScrollContent(text: displayed)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the Rewrite tab renders. User's manual edit takes priority over
    /// the LLM's `cleanedText`. `nil` only when both are absent (or empty).
    private var displayedRewriteText: String? {
        if let edit = transcript.rewriteUserEdit, !edit.isEmpty { return edit }
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty { return cleaned }
        return nil
    }

    /// In-card `TextEditor` shown while `isEditing == true`. Bound to the
    /// local `editorText` `@State`; saves are gated through `saveEdit()`.
    /// Cancel discards local state.
    @ViewBuilder
    private var transcriptEditor: some View {
        // Custom UITextView-backed editor: text ADDED or CHANGED this edit
        // session renders italic; the original (loaded at edit-start) stays
        // regular; Save persists the plain `String` (italic is session-only).
        // Same editor for both Original and Rewrite tabs (they share
        // `editorText`). See `InlineEditTextView` + docs/plans/inline-edit-italics.md.
        // `isEditable: true` keeps the editor editable while the keyboard (and
        // its Stop control) drive an in-Jot dictation through the normal capture
        // path, which inserts the result via the keyboard on stop.
        InlineEditTextView(
            text: $editorText,
            selection: $editorSelection,
            sessionToken: editSessionToken,
            isEditable: true,
            baseFont: .systemFont(ofSize: 17, weight: .regular),
            textColor: UIColor(Color.jotPageInk),
            isFocused: $editorFocused
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(
            editTargetTab == .original
                ? "Edit original transcript"
                : "Edit rewrite"
        )
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
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            thumbButton(up: true)
            thumbButton(up: false)
            Button {
                pendingDiscardRewrite = true
            } label: {
                Text("Discard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(.systemRed))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard rewrite")
            .accessibilityHint("Removes the rewrite and shows the original text")
        }
    }

    /// Single thumbs-up or thumbs-down toggle. Tapping the active glyph
    /// clears the rating (back to nil); tapping the opposite glyph swaps
    /// the rating. Light haptic on every tap. Filled SF Symbol when
    /// active, outlined when inactive.
    @ViewBuilder
    private func thumbButton(up: Bool) -> some View {
        let isActive: Bool = {
            switch transcript.rewriteUpvoted {
            case .some(true):  return up
            case .some(false): return !up
            default:           return false
            }
        }()
        let symbol = up
            ? (isActive ? "hand.thumbsup.fill" : "hand.thumbsup")
            : (isActive ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        let activeTint: Color = up ? Color.jotBlueTop : Color(.systemRed)

        Button {
            toggleRewriteRating(up: up)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? activeTint : Color.jotMute)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(up ? "Rate rewrite good" : "Rate rewrite bad")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
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
                .fill(.ultraThinMaterial)
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
                    systemImage: "trash",
                    label: "Delete",
                    accessibilityLabel: hasRewrite
                        ? "Delete options"
                        : "Delete transcript"
                ) {
                    pendingDeletion = true
                },
                ActionBarItem(
                    systemImage: "pencil",
                    label: "Edit",
                    accessibilityLabel: editAccessibilityLabel,
                    isEnabled: isEditEnabled
                ) {
                    beginEdit()
                }
            ],
            primary: ActionBarItem(
                systemImage: "sparkles",
                label: "Articulate",
                accessibilityLabel: rewriteAccessibilityLabel,
                isEnabled: isMagicEnabled
            ) {
                presentRewritePicker()
            },
            trailing: [
                ActionBarItem(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    label: "Copy",
                    accessibilityLabel: didCopy ? "Copied to clipboard" : "Copy transcript"
                ) {
                    copy()
                }
            ]
        )
    }

    /// Edit pill is enabled when there's something on the active tab to
    /// edit AND no rewrite is mid-flight. Original tab always has `text`
    /// (empty input is rejected at append time); Rewrite tab requires
    /// `displayedRewriteText` to be non-nil.
    private var isEditEnabled: Bool {
        guard rewriteState != .running else { return false }
        guard !keyboardRewriteInFlight else { return false }
        switch selectedTab {
        case .original: return !transcript.text.isEmpty
        case .rewrite:  return displayedRewriteText != nil
        }
    }

    private var editAccessibilityLabel: String {
        switch selectedTab {
        case .original: return "Edit original transcript"
        case .rewrite:  return "Edit rewrite"
        }
    }

    // MARK: - Edit-mode bottom bar

    /// Bottom bar shown while `isEditing == true`. Cancel discards, Save
    /// commits. The active tab's label is centered so the user can see
    /// which side they're editing without context-switching to the
    /// (now-hidden) tab pill.
    private var editBar: some View {
        HStack(spacing: 12) {
            Button(action: cancelEdit) {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel edit")

            Spacer(minLength: 6)

            // Center label can shrink/disappear; the side buttons must not.
            Text(editBarCenterLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.jotMute)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
                .layoutPriority(-1)

            Spacer(minLength: 6)

            Button(action: saveEdit) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Save")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.jotBlueTop)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .frame(maxWidth: .infinity)
        .modifier(
            JotDesign.Surface.heavy.modifier(
                cornerRadius: JotDesign.Spacing.sheetRadius
            )
        )
    }

    /// Center label of the EditBar.
    private var editBarCenterLabel: String {
        editTargetTab == .original ? "Editing Original" : "Editing Rewrite"
    }

    // Dictation while editing is driven by the keyboard's own Dictate tap: the
    // keyboard posts `keyboardDictateTapped`, the app starts a normal background
    // capture (the same path used in any other app), and on Stop the keyboard
    // inserts the transcribed text into this focused field. No in-editor mic.

    /// Inline warning card shown when Save validation fails (e.g. Original
    /// text empty). Stays visible until the user types something valid or
    /// cancels — matches the existing `errorCard` styling.
    private func editErrorCard(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.jotWarning)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.jotMute)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss validation error")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotWarning.opacity(0.10))
        )
    }

    // MARK: - Magic gate

    private var hasRewrite: Bool {
        if let edit = transcript.rewriteUserEdit, !edit.isEmpty { return true }
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty { return true }
        return false
    }

    /// Live LLM status mirrored from the adapter. Defaults to `.notReady`
    /// before the adapter has been resolved (or while the master toggle
    /// is OFF and no adapter has been built).
    private var llmStatus: LLMClientStatus {
        clientAdapter?.observableStatus ?? .notReady
    }

    /// Transform tap is ALWAYS clickable now — what it does depends on
    /// state. The only hard-disabled cases are:
    /// 1. A rewrite is already running (don't fire a second request).
    /// 2. A keyboard-originated rewrite is in flight against this
    ///    transcript ([§7.x of features.md] explicit-lock).
    /// Everything else routes through `presentRewritePicker()` which
    /// branches on `llmStatus` + prompt availability and either opens
    /// the picker or pushes the user to AI Settings to finish setup.
    private var isMagicEnabled: Bool {
        guard rewriteState != .running else { return false }
        guard !keyboardRewriteInFlight else { return false }
        return true
    }

    private var rewriteAccessibilityLabel: String {
        if rewriteState == .running { return "Rewriting" }
        if savedPrompts.isEmpty {
            return "Set up AI Rewrite in Settings"
        }
        switch llmStatus {
        case .ready:
            return "Rewrite with AI"
        case .notReady:
            return "Download the AI model in Settings"
        case .downloading:
            return "AI model is downloading — open Settings to see progress"
        case .loading:
            return "AI model is loading — open Settings to see progress"
        case .evicted:
            // Weights are still on disk; the next tap kicks a fast warm.
            return "Rewrite is loading the AI model — this should be quick"
        case .error:
            return "AI model error — open Settings to retry"
        }
    }

    /// Called by the action-bar Transform + the top sparkle button + the
    /// empty-state Rewrite card. Branches on the live LLM status:
    ///   - `.ready`     → present `RewritePickerSheet` (Mockup 10).
    ///   - `.evicted`   → kick `warm()` then present the picker. Weights
    ///                    are still on disk, so this is a fast in-process
    ///                    reload — NOT a re-download. The picker itself
    ///                    is passive; the rewrite path inside
    ///                    the LLM client's `rewrite` re-calls `warm()`
    ///                    so picking a prompt during the warm window is
    ///                    safe.
    ///   - `.notReady` / `.downloading` / `.loading` / `.error` OR no
    ///     saved prompts → present `AIRewriteSettingsView` as a sheet.
    ///     Single canonical setup surface for everything from
    ///     downloading the weights to seeding prompts.
    private func presentRewritePicker() {
        guard isMagicEnabled else { return }
        if savedPrompts.isEmpty {
            showAISettings = true
            return
        }
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
        case .notReady, .downloading, .loading, .error:
            showAISettings = true
        }
    }

    /// Word count of the source transcript (Original tab). Surfaced in the
    /// rewrite picker's sub-line per Mockup 10. Reads `transcript.text`,
    /// which already has the always-on regex filler sweep baked in by the
    /// dictation pipeline — the picker always rewrites exactly what the user
    /// sees in the Original tab.
    private var sourceWordCount: Int {
        rewriteSourceText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    /// Text the rewrite path consumes — equals what the Original tab shows.
    /// Single source of truth for the AI Rewrite input across the manual
    /// Transform button and the keyboard-originated rewrite path.
    private var rewriteSourceText: String {
        transcript.text
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
    /// Original returns `transcript.text` (which already has the always-on
    /// regex filler sweep baked in by the pipeline). Rewrite returns the
    /// user's edit if present, else the AI Rewrite output, else — when no
    /// rewrite has been produced — falls back to the original so Share/Copy
    /// on an empty Rewrite tab still does something sensible.
    private var bodyTextForActiveTab: String {
        switch selectedTab {
        case .original:
            return transcript.text
        case .rewrite:
            return transcript.rewriteUserEdit
                ?? transcript.cleanedText
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

    // MARK: - Edit lifecycle

    /// Enters edit mode against the currently-selected tab. Captures the
    /// initial editor value from the tab's display text, hides the tab
    /// pill, swaps the ActionBar for the EditBar, and focuses the editor.
    ///
    /// Initial value source:
    ///   - Original tab → `transcript.text`.
    ///   - Rewrite tab  → `transcript.rewriteUserEdit ?? transcript.cleanedText ?? ""`.
    ///     (The user's prior edit wins; otherwise they start from the
    ///     model's current rewrite.)
    private func beginEdit() {
        guard !isEditing else { return }
        guard isEditEnabled else { return }
        editTargetTab = selectedTab
        switch selectedTab {
        case .original:
            editorText = transcript.text
        case .rewrite:
            editorText = transcript.rewriteUserEdit
                ?? transcript.cleanedText
                ?? ""
        }
        editError = nil
        isEditing = true
        // New edit session → the inline editor re-baselines the just-loaded text
        // as "original" (regular) and clears italic tracking.
        editSessionToken += 1
        // Focus on the next runloop so the TextEditor has installed its
        // text view by the time we ask for first responder. Without the
        // hop the keyboard occasionally doesn't pop on first tap.
        DispatchQueue.main.async {
            editorFocused = true
        }
    }

    /// Commits the current `editorText` to the appropriate transcript field
    /// and exits edit mode. Validation:
    ///   - Original: rejects empty/whitespace-only input (the user must
    ///     either type something valid or Cancel — `text` can't be nil and
    ///     a blank transcript is useless).
    ///   - Rewrite: empty/whitespace-only is treated as "clear my edit"
    ///     (set `rewriteUserEdit = nil`, fall back to `cleanedText`).
    ///
    /// After persistence, refreshes the keyboard's JSON mirror and posts a
    /// cross-process notification so a live keyboard re-renders its Recents
    /// strip immediately. Without these the keyboard shows pre-edit text
    /// until the next dictation refreshes the mirror.
    private func saveEdit() {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch editTargetTab {
        case .original:
            guard !trimmed.isEmpty else {
                editError = "Original text can't be empty."
                return
            }
            // No-op if the user hit Save without changing anything.
            // Skips the SwiftData write + mirror refresh — both are
            // idempotent but the cross-process notification would wake
            // the keyboard for nothing.
            if trimmed == transcript.text {
                exitEditMode()
                return
            }
            transcript.text = trimmed

        case .rewrite:
            // Rewrite-tab Save without a model rewrite to back it would
            // be writing a userEdit with no "before" — refuse and let
            // the UI direct the user through Transform first.
            guard transcript.cleanedText != nil else {
                editError = "Generate a rewrite first."
                return
            }
            if trimmed.isEmpty {
                // Empty = "clear my edit." Display falls back to cleanedText.
                if transcript.rewriteUserEdit == nil {
                    // Already cleared; skip the write.
                    exitEditMode()
                    return
                }
                transcript.rewriteUserEdit = nil
            } else {
                // Skip the write if the user typed nothing new vs. the
                // current display value (rewriteUserEdit ?? cleanedText).
                let current = transcript.rewriteUserEdit ?? transcript.cleanedText ?? ""
                if trimmed == current {
                    exitEditMode()
                    return
                }
                transcript.rewriteUserEdit = trimmed
            }
        }

        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
            detailLog.info(
                "Transcript edit SAVED tab=\(editTargetTab.rawValue, privacy: .public) chars=\(trimmed.count)"
            )
        } catch {
            modelContext.rollback()
            editError = "Couldn't save: \(error.localizedDescription)"
            detailLog.error(
                "Transcript edit save FAILED tab=\(editTargetTab.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        exitEditMode()
    }

    /// Discards local edit state without persisting. The transcript fields
    /// are untouched, so re-entering edit mode shows the unmodified text.
    private func cancelEdit() {
        exitEditMode()
    }

    /// Common exit path for both Save and Cancel. Drops the keyboard,
    /// clears local edit state, and brings the regular ActionBar back.
    private func exitEditMode() {
        editorSelection = nil
        editorFocused = false
        isEditing = false
        editError = nil
        editorText = ""
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

    /// Toggle the 👍 / 👎 rating on the current Rewrite. Tap the active
    /// glyph to clear; tap the opposite glyph to swap. Persists immediately,
    /// fires a light haptic, and skips the mirror refresh (ratings aren't
    /// displayed outside the Detail surface, so no cross-process work needed).
    ///
    /// Snapshots the prior value before mutation; if `save()` throws,
    /// explicitly restores the snapshot AFTER `rollback()` so the in-memory
    /// property doesn't drift from on-disk state. SwiftData's rollback
    /// usually reverts managed-object property values, but the contract isn't
    /// rock solid — belt-and-suspenders here is cheap.
    private func toggleRewriteRating(up: Bool) {
        let previous = transcript.rewriteUpvoted
        let next: Bool?
        switch (previous, up) {
        case (.some(true), true):   next = nil   // tap 👍 while up → clear
        case (.some(false), false): next = nil   // tap 👎 while down → clear
        case (_, true):             next = true  // any other tap on 👍 → up
        case (_, false):            next = false // any other tap on 👎 → down
        }

        transcript.rewriteUpvoted = next
        do {
            try modelContext.save()
            copyHaptic.impactOccurred()
            copyHaptic.prepare()
            detailLog.info(
                "Rewrite rating set up=\(up, privacy: .public) next=\(String(describing: next), privacy: .public) transcript=\(transcript.id, privacy: .public)"
            )
        } catch {
            modelContext.rollback()
            // Belt-and-suspenders: revert the in-memory mutation explicitly
            // so the thumb glyph re-renders the prior state immediately,
            // even if SwiftData's rollback didn't restore the managed-object
            // property.
            transcript.rewriteUpvoted = previous
            detailLog.error(
                "Rewrite rating save FAILED error=\(error.localizedDescription, privacy: .public)"
            )
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

    /// Restore the transcript to its pre-rewrite state. Used by both the
    /// floating X affordance on the Rewrite tab and the "Delete rewrite only"
    /// option in the trash menu. Cancels any in-flight rewrite, nils
    /// `cleanedText`, saves SwiftData, refreshes the App Group mirror so the
    /// keyboard's RecentsStrip reverts to raw text, and bounces the segmented
    /// control to Original (the tab row hides automatically because
    /// `hasRewrite` is now false).
    private func discardRewrite() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil
        rewriteState = .idle
        lastRewriteAt = nil

        transcript.cleanedText = nil
        // A user-edit OR rating against a discarded rewrite is meaningless
        // — the training "before" half is gone. Clear all three together.
        transcript.rewriteUserEdit = nil
        transcript.rewriteUpvoted = nil
        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            CrossProcessNotification.post(name: CrossProcessNotification.historyMirrorUpdated)
        } catch {
            modelContext.rollback()
            detailLog.error("Discard rewrite save failed: \(error.localizedDescription, privacy: .public)")
        }

        selectedTab = .original
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
        // same text the Original tab displays. The published text already
        // has the always-on regex filler sweep baked in by the pipeline.
        let source = rewriteSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            rewriteState = .error("Transcript is empty.")
            return
        }
        // Correctness-only guards. Do NOT re-check `isMagicEnabled` here:
        // the picker has already been presented (so the user clearly
        // intended a rewrite), and `isMagicEnabled` would falsely block
        // the very first run when `presentRewritePicker`'s own
        // `clientAdapter?.warm()` kick has flipped the live status to
        // `.loading` between picker-open and prompt-pick. The downstream
        // `LLMClient.rewrite(...)` call joins any in-flight warm, so a
        // mid-load status is fine — the request just blocks briefly on
        // the first token. (Without this fix the first tap after install
        // silently returned and the menu closed; only the second tap,
        // once `.ready` had been reached, would actually rewrite.)
        guard rewriteState != .running else { return }
        guard !keyboardRewriteInFlight else { return }

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
                // Stale userEdit OR rating against a fresh model output is
                // meaningless; clear both so the new cleanedText starts
                // unrated and any future correction pairs with this new
                // output (not the one against the prior output).
                transcript.rewriteUserEdit = nil
                transcript.rewriteUpvoted = nil
                do {
                    try modelContext.save()
                    TranscriptHistoryMirror.refresh(from: modelContext)
                    // The keyboard's RecentsStrip renders displayText;
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

        // If the user is mid-edit, kicking a rewrite would flip the tab
        // out from under them and clobber `cleanedText` while their local
        // `editorText` keeps stale. Refuse the intent, surface a keyboard
        // error so they can re-tap after Save/Cancel.
        guard !isEditing else {
            detailLog.notice("autoFireKeyboardRewrite: edit mode active; refusing intent")
            writeKeyboardError("Finish editing first, then try again", sessionID: intent.sessionID)
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
        // path — feed the published text so the AI Rewrite input matches
        // the Original tab.
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
                // Stale userEdit + rating against a fresh model output are
                // meaningless; see manual-rewrite branch above for rationale.
                transcript.rewriteUserEdit = nil
                transcript.rewriteUpvoted = nil
                do {
                    try modelContext.save()
                    TranscriptHistoryMirror.refresh(from: modelContext)
                    // The keyboard's RecentsStrip renders displayText;
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
