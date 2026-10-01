import JotVocabCore
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
/// - **Top toolbar**: glass back chevron (left). No native nav-bar chrome — the
///   surface looks like the mockup, not like a stock `NavigationStack` detail.
///   (Rewrite lives on the bottom ActionBar, not up here.)
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
/// - **Floating ActionBar**: Delete / Edit / Rewrite (accent sparkle circle) /
///   Translate (globe) / Copy — anchored to the bottom safe area, glass-heavy.
///   The giant labelled Rewrite pill was retired for the icon-only circle.
///
/// ## Tags / title intentionally absent
///
/// Per plan §10.1 and §10.2 the v1 defaults are HIDE-rather-than-shell:
/// `Transcript` has no `title` or `tags` field, so adding the visual slots
/// without backend persistence would be misleading. Leave them out entirely;
/// the body reads as a clean editorial surface without them.
///
/// ## AI rewrite
///
/// The manual Transform button on the floating ActionBar runs the user's
/// saved prompt through `RewriteClient.shared.rewrite(...)` — Apple Foundation
/// Models on-device, with Private Cloud Compute as the iOS 27 fallback.
/// Re-running rewrite overwrites `cleanedText` in place — there is no rewrite
/// history slot in the SwiftData model and the plan explicitly forbids growing
/// one (§6.2 / §14.4).
struct TranscriptDetailView: View {
    let transcript: Transcript

    /// Arrived from the keyboard recents row's Apple Intelligence button
    /// (`jot://transcript?id=…&ai=1`). If the note has no rewrite yet, a rewrite
    /// with the Cleanup prompt starts on arrival; if it already has one, the
    /// Rewrite tab is shown (features.md §5.2). Nothing to tap either way.
    let autoRewrite: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(
        transcript: Transcript,
        autoRewrite: Bool = false
    ) {
        self.transcript = transcript
        self.autoRewrite = autoRewrite
    }

    enum DetailTab: String, CaseIterable {
        case original
        case rewrite
        case speakers

        var label: String {
            switch self {
            case .original: return "Original"
            case .rewrite:  return "Rewrite"
            case .speakers: return "Speakers"
            }
        }
    }

    /// The tabs currently offered, in fixed display order. `.original` is always
    /// present; `.rewrite` appears once a cleanup/rewrite exists; `.speakers`
    /// appears once a diarization result is persisted (`diarizationJSON != nil`).
    ///
    /// The tab bar's visibility keys off THIS (`visibleTabs.count > 1`), NOT off
    /// `hasRewrite` — a shared call recording with cleanup off has no rewrite but
    /// still gains a Speakers tab, and that tab must be reachable (the headline
    /// case: iOS call recordings shared into Jot). See
    /// `docs/plans/speaker-notes-productization.md`.
    private var visibleTabs: [DetailTab] {
        var tabs: [DetailTab] = [.original]
        if hasRewrite { tabs.append(.rewrite) }
        if transcript.diarizationJSON != nil { tabs.append(.speakers) }
        return tabs
    }

    /// Decoded persisted speaker turns for the Speakers tab, or `nil` when the
    /// transcript was never diarized / was single-speaker / the blob is stale.
    private var speakerRows: [PersistedSpeakerRow]? {
        PersistedSpeakerRow.decode(transcript.diarizationJSON)
    }

    @State private var selectedTab: DetailTab = .original
    @State private var pendingDeletion = false
    @State private var pendingDiscardRewrite = false
    /// Set when the back chevron is tapped mid-edit with unsaved changes;
    /// drives the Save / Discard / Keep Editing dialog.
    @State private var pendingEditExit = false
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
    /// True while the edit bar's AI button is rewriting the draft in place
    /// (features.md §3.7): the button shows a spinner, the center label reads
    /// "Rewriting…", and Save waits. Reset on each edit entry/exit.
    @State private var isRewritingDraft = false
    @State private var draftRewriteTask: Task<Void, Never>?
    @State private var editorText: String = ""
    @State private var editTargetTab: DetailTab = .original
    /// The edited field's text when Edit was pressed — the "before" side of
    /// learn-from-edits (`EditLearning`) on Save.
    @State private var editBaseline: String = ""

    /// Shared correction-review state (marks + accordion + bubble). Owned HERE,
    /// above the `transcriptScrollContent` `.id(selectedTab)` boundary, so it
    /// survives tab switches (plan §v2-F). Created in `.onAppear`.
    @State private var correctionModel: CorrectionReviewModel?
    /// The tap bubble anchored at a marked word (window-coord rect).
    @State private var correctionBubble: CorrectionBubbleAnchor?
    /// True while the bubble is dwelling on its resolved consequence line (1.3s).
    /// Keeps the verdict's text-edit from auto-dismissing the bubble early so the
    /// owner sees the consequence (handoff §word-bubble).
    @State private var correctionBubbleResolving = false

    /// Selection-menu "Add to Vocabulary": the selected (possibly MIS-transcribed)
    /// text + its range, pending the "what should this say?" prompt. The prompt's
    /// field is prefilled with the selection — confirm-as-is adds a correct word;
    /// typing the real form fixes the text AND teaches Jot the heard→meant pair.
    @State private var vocabAddSelection: VocabAddSelection?
    @State private var vocabAddText: String = ""

    struct VocabAddSelection: Identifiable {
        let id = UUID()
        let selected: String
        let range: NSRange
    }
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

    // MARK: - Find & Replace (edit-mode only, features.md §3.10)
    //
    // A find/replace bar above the EditBar that fixes a term the speech model
    // misheard several times in one shot. Whole-word + case-insensitive matching;
    // Replace All rewrites `editorText`, which the inline editor ingests as a
    // programmatic change (so the swapped words render italic like any edit).
    // On Save, a qualifying replace (term-like, 2+ matches, not a common word)
    // offers to learn it — reusing the exact term + heard→alias + correction-store
    // path that selection "Add to Vocabulary" already uses (see `confirmVocabAdd`).
    @State private var showFindReplace = false
    /// Proofread (iOS 27 system grammar checker — `GrammarCheckService`).
    /// Issues found for the CURRENT `editorText`; cleared on every text change
    /// because their offsets go stale. Never applied silently: the user accepts
    /// each fix from `ProofreadSheet`.
    @State private var grammarIssues: [GrammarIssue] = []
    @State private var isProofreading = false
    @State private var showProofread = false
    @State private var findText = ""
    @State private var replaceText = ""
    @FocusState private var findFieldFocused: Bool
    /// The last Replace All performed this edit session; consulted on Save to
    /// decide whether to offer the learn-it prompt. Cleared on exit.
    @State private var pendingReplaceLearn: ReplaceLearn?
    /// Non-nil after a qualifying Save → drives the gentle learn-it card.
    @State private var replaceVocabOffer: ReplaceVocabOffer?

    private struct ReplaceLearn { let find: String; let replace: String; let count: Int }
    private struct ReplaceVocabOffer: Identifiable {
        let id = UUID(); let term: String; let heard: String; let count: Int
    }

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
    @State private var showTranslateSheet: Bool = false
    /// Set by the picker's Translate row; consumed in the picker's `onDismiss`
    /// to present the Translate sheet without a sheet-over-sheet race.
    @State private var pendingTranslate: Bool = false

    /// Re-transcription (multilingual): whether this transcript still has its
    /// source audio retained (drives the "Re-transcribe" affordance), and the
    /// in-flight / error state of a re-transcribe run. `canRetranscribe` is
    /// refreshed on appear + after a run (a filesystem check, not in the body).
    @State private var canRetranscribe: Bool = false
    @State private var isRetranscribing: Bool = false
    @State private var retranscribeError: String? = nil

    /// Speaker Notes: "Detect speakers" runs the offline diarizer against the
    /// retained source audio. A multi-speaker result is PERSISTED on the
    /// transcript (`diarizationJSON`, schema V9) and surfaces as the Speakers
    /// tab; a single-speaker result stores nothing and shows a transient notice.
    /// Available on any transcript with retained audio — no lab flag.
    @State private var isDiarizing: Bool = false
    @State private var diarizeError: String? = nil
    /// Brief, auto-dismissing message (e.g. "Sounds like a single speaker") for
    /// results that store nothing but still warrant acknowledgement.
    @State private var transientNotice: String? = nil
    @State private var transientNoticeTask: Task<Void, Never>?

    /// One-shot guard for the `autoRewrite` arrival (the keyboard recents
    /// row's Apple Intelligence button). `.task` can re-run on this view.
    @State private var didAutoStartRewrite: Bool = false

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

                if visibleTabs.count > 1 && !isEditing {
                    tabSelector
                }

                if let editError, isEditing {
                    editErrorCard(message: editError)
                } else if rewriteState == .running {
                    runningRewriteCard
                } else if CleanupActivity.shared.isCleaning(transcript.id) {
                    cleaningCard
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
                    VStack(spacing: 8) {
                        if showFindReplace { findReplaceBar }
                        editBar
                    }
                } else {
                    actionBar
                }
            }
            .padding(.horizontal, JotDesign.Spacing.pageMargin)
            .padding(.bottom, 14)

            // Gentle, non-blocking learn-it offer after a qualifying Replace All.
            if let offer = replaceVocabOffer, !isEditing {
                replaceVocabOfferCard(offer)
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.bottom, 84) // floats just above the ActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Transient acknowledgement for a store-nothing diarize result
            // (single speaker). Floats above the ActionBar and self-dismisses.
            if let notice = transientNotice, !isEditing {
                transientNoticeCard(notice)
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay { correctionBubbleOverlay }
        // Invisible host for Apple Translation's SwiftUI-bound session.
        // Mounting it always is harmless — it does nothing until
        // TranslationGateway sets a configuration.
        .background {
            // Serves the Translate sheet (features.md §3.9). Harmless when idle
            // — does nothing until TranslationGateway sets a config.
            TranslationTaskHost()
        }
        .onChange(of: transcript.text) {
            // Body text changed (a verdict edit, or a manual Edit-mode save) →
            // re-resolve marks/offsets and drop the now-detached bubble. `.task`
            // keys on transcript.id, which doesn't fire on a same-id mutation.
            // EXCEPTION: while the bubble is dwelling on its resolved line after a
            // pick that edited the text, keep it up — it dismisses itself on its
            // own 1.3s timer (handoff §word-bubble).
            if !correctionBubbleResolving { correctionBubble = nil }
            Task { await correctionModel?.reload() }
        }
        .onChange(of: transcript.diarizationJSON) {
            // The diarization result was persisted (Detect speakers) or
            // invalidated (retranscribe / Original edit changed the text). If the
            // Speakers tab just vanished out from under the selection, fall back
            // to Original so the card never renders a tab that no longer exists.
            if !visibleTabs.contains(selectedTab) { selectedTab = .original }
        }
        // Re-apply AFTER the chrome-hiding modifiers above — iOS disables
        // the interactive pop gesture when the back button is hidden, and
        // a root-level NavigationStack modifier can be undone by that
        // disable. Putting the enable here ensures the gesture survives.
        //
        // Gate on `!hasUnsavedEdits`: an untouched editor is safe to swipe
        // out of, but UIKit's `interactivePopGestureRecognizer` lives one
        // layer below SwiftUI and isn't bound by the chevron's guard.
        // Letting it fire with unsaved changes would silently pop the view
        // and discard them — and a pop gesture can't be interrupted by a
        // dialog, so the swipe is refused and the chevron carries the ask.
        .enableInteractivePopGesture(isEnabled: !hasUnsavedEdits)
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
                        // Mirror the back-chevron's edit-mode policy. An
                        // untouched editor swipes out like any read-mode
                        // page; unsaved changes refuse the swipe (there's
                        // no way to ask mid-gesture) and leave the user on
                        // the chevron, which does ask.
                        guard !hasUnsavedEdits else { return }
                        if isEditing { exitEditMode() }
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
            "Save your changes?",
            isPresented: $pendingEditExit,
            titleVisibility: .visible
        ) {
            Button("Save") {
                // `saveEdit()` exits edit mode on success, and leaves
                // `isEditing` true with an inline `editError` when it
                // rejects the text (empty Original) — only leave the
                // screen once the save actually took.
                saveEdit()
                if !isEditing { dismiss() }
            }
            Button("Discard Changes", role: .destructive) {
                exitEditMode()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {
                pendingEditExit = false
                // Presenting the sheet resigns the editor's first responder
                // (`textViewDidEndEditing` → `editorFocused = false`), so
                // without this the user is "still editing" but the keyboard is
                // gone until they tap the text again. Next-runloop hop so the
                // refocus lands after the dialog's dismissal settles — the
                // same pattern `beginEdit()` uses for its initial focus.
                DispatchQueue.main.async { editorFocused = true }
            }
        } message: {
            Text("Your edits haven't been saved yet.")
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
        .sheet(isPresented: $showRewritePicker, onDismiss: {
            // Translate is presented AFTER the picker fully dismisses (chained
            // via onDismiss) so two sheets never race. The picker's Translate
            // row sets `pendingTranslate`, then dismisses itself.
            if pendingTranslate {
                pendingTranslate = false
                showTranslateSheet = true
            }
        }) {
            // Mockup 10 / plan §6.1 — bottom-sheet picker for the user's
            // saved prompts. The "+ New prompt" affordance dismisses the
            // sheet and surfaces a follow-up alert that points the user
            // at Settings → AI Rewrite, since this surface intentionally
            // does NOT host inline prompt editing.
            // ONE picker for both modes (owner, 2026-09-27: the view pane and
            // the edit bar must offer the same prompts, not two features).
            // Viewing → the pick becomes the transcript's Rewrite. Editing →
            // it rewrites the draft in place (italic session edit; Save keeps
            // it, Cancel drops it).
            RewritePickerSheet(
                wordCount: isEditing ? draftWordCount : sourceWordCount,
                modelDisplayName: rewriteModelDisplayName,
                prompts: savedPrompts,
                onPick: { prompt in
                    if isEditing { rewriteDraft(with: prompt) } else { startRewrite(with: prompt) }
                },
                onVoicePrompt: { instruction in
                    guard let prompt = Self.voicePrompt(for: instruction) else { return }
                    detailLog.info("Voice-prompt rewrite — instructionChars=\(instruction.count) draft=\(isEditing)")
                    if isEditing { rewriteDraft(with: prompt) } else { startRewrite(with: prompt) }
                },
                onNewPrompt: {
                    showNewPromptHint = true
                },
                onTranslate: {
                    pendingTranslate = true
                }
            )
        }
        .sheet(isPresented: $showTranslateSheet) {
            // Ephemeral translate sheet (features.md §3.9) — Apple on-device
            // Translation via TranslationGateway; reads the active tab's text.
            // Nothing is saved. The TranslationTaskHost that fulfils the session
            // lives on this view (mounted unconditionally) and stays alive while
            // this sheet is up.
            TranslateSheet(
                text: isEditing ? editorText : activeTabText,
                // Exclude the transcript's own language from the targets and
                // pass it as the source hint. nil / unknown → English.
                sourceCode: LanguageChoice.fromStored(transcript.language).isoCode
            )
        }
        .sheet(isPresented: $showAISettings) {
            // Single canonical setup surface for AI Rewrite: engine choice,
            // Apple Intelligence status, and the saved prompts. Reached from
            // here when there are no prompts yet or Apple Intelligence is off.
            NavigationStack {
                AIRewriteSettingsView()
            }
        }
        .sheet(isPresented: $showProofread) {
            // Suggestions from the system grammar checker (features.md §3.7).
            // Accepting a fix edits `editorText` in place — italic like any
            // other session edit — then re-checks so the remaining offsets are
            // fresh. Ignoring just drops the row.
            ProofreadSheet(
                issues: grammarIssues,
                onApply: { issue, suggestion in
                    editorText = GrammarCheckService.apply(suggestion, for: issue, to: editorText)
                    runProofread(presentSheet: false)
                },
                onIgnore: { issue in
                    grammarIssues.removeAll { $0.id == issue.id }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: editorText) { _, _ in
            // Any edit invalidates the underline offsets. A proofread in flight
            // (including the re-check after an accepted fix) repopulates them.
            if !isProofreading { grammarIssues = [] }
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
            // Skipped in edit mode, which pins the tab it is editing.
            if hasRewrite, !isEditing {
                selectedTab = .rewrite
            }
            if correctionModel == nil {
                let m = CorrectionReviewModel(transcript: transcript, modelContext: modelContext)
                correctionModel = m
                Task { await m.reload() }
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            activeRewriteTask?.cancel()
            activeRewriteTask = nil
            draftRewriteTask?.cancel()
            draftRewriteTask = nil
        }
        .task {
            refreshRewriteAvailability()
            // Keyboard recents row → Apple Intelligence button (§5.2). Runs
            // AFTER `refreshRewriteAvailability()` so it reads fresh state. The
            // whole point of the tap is to rewrite the note, so do exactly that:
            // a note that already has a rewrite just shows it; otherwise the
            // Cleanup prompt runs now — the same prompt Automatic cleanup uses,
            // resolved the same way. Apple Intelligence off ⇒ the usual setup
            // routing (`presentRewritePicker` → AI settings sheet).
            if autoRewrite, !didAutoStartRewrite {
                didAutoStartRewrite = true
                if hasRewrite {
                    selectedTab = .rewrite
                } else if RewriteClient.isAvailable,
                          let prompt = CleanupSettings.resolvedPrompt(promptID: CleanupSettings.load().promptID) {
                    startRewrite(with: prompt)
                } else {
                    presentRewritePicker()
                }
            }
        }
    }

    // MARK: - Top toolbar

    private var topToolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            // Back stays live in edit mode — `back()` asks before it
            // leaves whenever the editor holds unsaved changes.
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: "Back"
            ) {
                back()
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }

    /// The text the active tab is showing — what Translate reads.
    private var activeTabText: String {
        if selectedTab == .rewrite, let displayed = displayedRewriteText, !displayed.isEmpty {
            return displayed
        }
        return transcript.text
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

            if let languageBadgeText {
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                        .font(.system(size: 10, weight: .semibold))
                    Text(languageBadgeText)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.ultraThinMaterial))
                .accessibilityLabel("Dictated in \(languageBadgeText)")
            }

            Spacer(minLength: 0)

            if canRetranscribe {
                // Detect speakers + Re-transcribe share ONE overflow menu (never
                // two full-width trailing controls on one line — those clipped
                // silently off-screen, a real bug found in-session). Standard on
                // any transcript with retained audio — no lab flag.
                Menu {
                    Button {
                        diarizeSpeakers()
                    } label: {
                        Label(diarizeError != nil ? "Retry detect speakers" : "Detect speakers",
                              systemImage: "person.wave.2")
                    }
                    Divider()
                    Text("Re-transcribe this audio in…")
                    ForEach(LanguageChoice.presentationOrder) { lang in
                        Button(lang.displayName) { retranscribe(in: lang) }
                    }
                } label: {
                    if isRetranscribing || isDiarizing {
                        ProgressView().controlSize(.mini)
                    } else if retranscribeError != nil || diarizeError != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.red)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                    }
                }
                .disabled(isRetranscribing || isDiarizing)
                .accessibilityLabel("More actions: re-transcribe or detect speakers")
            }
        }
        .onAppear {
            canRetranscribe = RetainedAudioStore.hasAudio(for: transcript.id)
        }
    }

    /// Re-run transcription on the **retained source audio** in a chosen
    /// language, then update the transcript's text + language stamp. The pick
    /// becomes the active dictation language (same as choosing it in Settings),
    /// downloading the model first if needed. No-op if the audio has expired.
    private func retranscribe(in lang: LanguageChoice) {
        guard !isRetranscribing,
              let url = RetainedAudioStore.url(for: transcript.id) else { return }
        isRetranscribing = true
        retranscribeError = nil
        // Switch the active language (persist + evict/reload the model so the
        // re-transcribe runs on the right weights + script hint).
        AppGroup.transcriptionLanguage = lang.rawValue
        TranscriptionService.shared.handleLanguageChange()
        Task {
            do {
                let text = try await TranscriptionService.shared.transcribe(audioFileURL: url)
                try TranscriptStore.update(id: transcript.id, text: text, language: lang.rawValue)
                // The text (and language) just changed, so any stored diarization
                // result — whose turns distribute the OLD text across segments —
                // no longer matches. Invalidate it; the user can re-run Detect
                // speakers while the audio is still retained.
                try? TranscriptStore.updateDiarization(id: transcript.id, json: nil)
                await MainActor.run {
                    isRetranscribing = false
                    canRetranscribe = RetainedAudioStore.hasAudio(for: transcript.id)
                }
            } catch {
                await MainActor.run {
                    isRetranscribing = false
                    retranscribeError = error.localizedDescription
                }
            }
        }
    }

    /// Runs the Nemotron 3 speaker diarizer against this transcript's
    /// retained source audio. A multi-speaker result is PERSISTED
    /// (`diarizationJSON`, schema V9) and the view switches to the Speakers tab;
    /// a single-speaker result stores nothing and shows a transient notice
    /// (`docs/plans/speaker-notes-productization.md`). Backs off if a live
    /// transcription is in flight rather than risking FluidAudio's shared
    /// CoreML/BNNS state under two concurrent graphs.
    private func diarizeSpeakers() {
        guard !isDiarizing, let url = RetainedAudioStore.url(for: transcript.id) else { return }
        isDiarizing = true
        diarizeError = nil
        Task {
            // Same two-signal guard as the auto-import path: `isBusy` covers a
            // transcription mid-inference, `isRecording` covers a capture that
            // hasn't reached the transcriber yet but is about to (FluidAudio's
            // shared CoreML/BNNS state is unsafe under two concurrent graphs).
            if TranscriptionService.shared.isBusy || RecordingService.shared.isRecording {
                await MainActor.run {
                    isDiarizing = false
                    diarizeError = "Busy transcribing — try again in a moment."
                }
                return
            }
            do {
                let result = try await DiarizerHolder.shared.diarize(audioFileURL: url)
                // Snapshot the display text on the main actor before building rows
                // (Transcript is @MainActor-bound SwiftData state).
                let displayText = await MainActor.run { transcript.displayText }
                await MainActor.run {
                    isDiarizing = false
                    guard let rows = DiarizationLabeling.persistedRows(
                        runs: result.runs,
                        duration: result.duration,
                        transcriptText: displayText
                    ), let json = PersistedSpeakerRow.encode(rows) else {
                        showTransientNotice("Sounds like a single speaker.")
                        return
                    }
                    do {
                        try TranscriptStore.updateDiarization(id: transcript.id, json: json)
                        // The Speakers tab appears once `diarizationJSON` merges
                        // back onto the observed transcript; jump to it now — the
                        // tab bar + card follow when the merge lands.
                        selectedTab = .speakers
                    } catch {
                        diarizeError = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isDiarizing = false
                    diarizeError = error.localizedDescription
                }
            }
        }
    }

    /// Show a brief, self-dismissing notice (e.g. a single-speaker result that
    /// stores nothing). Replaces any in-flight notice and clears after 2.5s.
    private func showTransientNotice(_ message: String) {
        transientNoticeTask?.cancel()
        withAnimation { transientNotice = message }
        transientNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { transientNotice = nil }
        }
    }

    // MARK: - Tab selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
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
                            text: transcript.text,
                            showReview: true
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
                    case .speakers:
                        // Persisted diarization turns. `speakerRows` is nil only
                        // for the brief window between a Detect-speakers save and
                        // the merge landing on the observed transcript, or right
                        // after an invalidation (the `.onChange` handler bounces
                        // the selection back to Original) — render empty, never
                        // crash, in that gap.
                        if let rows = speakerRows {
                            speakersTabContent(rows: rows)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Speakers tab

    /// The Speakers tab body — one block per diarized turn (label + timestamp +
    /// text), ported from the retired `DiarizationResultSheet`. Text is
    /// selectable. Labels are the display names frozen at diarization time
    /// ("Speaker N"); rows saved before the Nemotron switch may still say
    /// "You", which stays accented.
    @ViewBuilder
    private func speakersTabContent(rows: [PersistedSpeakerRow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(row.label == "You" ? Color.jotAccent : Color.jotPageInk)
                            Text(speakerTimeRange(row.start, row.end))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.jotPageInkSecondary)
                        }
                        if !row.text.isEmpty {
                            Text(row.text)
                                .font(.system(size: 17, weight: .regular))
                                .lineSpacing(4)
                                .foregroundStyle(Color.jotPageInk)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(selectedTab)
    }

    /// `m:ss–m:ss` label for a turn's start/end (mirrors the retired sheet).
    private func speakerTimeRange(_ start: Float, _ end: Float) -> String {
        func format(_ seconds: Float) -> String {
            let s = Int(seconds)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(format(start))\u{2013}\(format(end))"
    }

    /// Transient single-speaker (store-nothing) acknowledgement card. Same
    /// house chrome as the learn-it offer; content is a single line.
    private func transientNoticeCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotPageInkSecondary)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.jotInk)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .modifier(JotDesign.Surface.heavy.modifier(cornerRadius: JotDesign.Spacing.sheetRadius))
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
            isFocused: $editorFocused,
            highlightRanges: grammarIssues.map(\.range)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(
            editTargetTab == .original
                ? "Edit original transcript"
                : "Edit rewrite"
        )
    }

    /// Scrollable body text styled to match Recents row typography (system
    /// Confirm the selection-menu "Add to Vocabulary" prompt. Always applies the
    /// text fix (replace the selected span with what the owner typed); adds a
    /// vocabulary term ONLY when the typed word isn't just common words — that
    /// check is how Jot tells "this is a name/term/acronym worth learning" from
    /// ordinary rewording. For a real correction (typed ≠ selected) the heard
    /// form is also attached as a "sounds like" alias AND taught to the
    /// correction store (net +1), so the next dictation can fix it by itself.
    private func confirmVocabAdd() {
        guard let sel = vocabAddSelection else { return }
        vocabAddSelection = nil
        let replacement = vocabAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return }

        // 1. Fix the text in place (selected occurrence only). Defensive: the
        //    range must still hold the exact selection (the alert is modal, but
        //    a keyboard-verdict drain could have shifted the text underneath).
        //    Anchors of OTHER correction records shift via the model's
        //    reconcile-on-change diff, like any hand-edit.
        let ns = transcript.text as NSString
        let rangeStillValid = sel.range.location + sel.range.length <= ns.length
            && ns.substring(with: sel.range) == sel.selected
        var didFix = false
        if replacement != sel.selected, rangeStillValid {
            let newText = ns.replacingCharacters(in: sel.range, with: replacement)
            do {
                try TranscriptStore.setText(id: transcript.id, newText: newText)
                correctionModel?.flashSpan(
                    NSRange(location: sel.range.location, length: (replacement as NSString).length))
                didFix = true
            } catch {
                return
            }
        } else if rangeStillValid {
            correctionModel?.flashSpan(sel.range)
        }

        // 2. Vocabulary-worthy? Skip the vocab entry when EVERY word of the
        //    replacement is a common word — Jot already knows those; nothing to
        //    learn (owner-specified filter: this is the "what is this?" test).
        //    The text fix above still applied either way.
        let replacementWords = replacement.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let vocabWorthy = replacementWords.contains {
            !CommonWords.isCommon($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()")))
        }

        // 3. "When Jot hears the selection, write the replacement" — one
        //    correction through the one learning path (term + visible
        //    sounds-like; nothing auto-applies). The user typed the spelling,
        //    so its casing wins. A replacement equal to the selection (case
        //    aside) is a plain add.
        guard vocabWorthy else {
            if didFix { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return
        }
        let correction = Correction.correct(heard: sel.selected, term: replacement, userCasing: true)
        Task { @MainActor in
            let outcome = await VocabularyLearning.shared.apply(correction).outcome
            let didLearn: Bool = { if case .rejected = outcome { return false }; return true }()
            if didFix || didLearn {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// sans-serif) but at a larger reading size. The card itself is fixed-height
    /// (fills the viewport between the tab pill and ActionBar); the ScrollView
    /// inside lets long transcripts scroll without growing the card.
    @ViewBuilder
    private func transcriptScrollContent(text: String, showReview: Bool = false) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if showReview, let model = correctionModel {
                    // Original tab: render the body so gated words can be marked
                    // + tapped (read-only, still selectable). Tapping a mark opens
                    // the review bubble anchored at the word.
                    MarkedTranscriptText(
                        text: transcript.text,
                        marks: model.marks(),
                        flash: model.flash,
                        onTapMark: { key, rect in
                            if let r = model.record(forKey: key) {
                                correctionBubble = CorrectionBubbleAnchor(record: r, rect: rect)
                            }
                        },
                        onAddToVocabulary: { word, range in
                            // Open the "what should this say?" prompt. The
                            // selection may be a MIS-transcription Jot has no
                            // term for (so no underline) — the prompt lets the
                            // owner type the real word; confirm-as-is covers
                            // the already-correct case.
                            vocabAddText = word
                            vocabAddSelection = VocabAddSelection(selected: word, range: range)
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)

                    CorrectionReviewSection(model: model)
                        .padding(.bottom, 12)
                        .alert(
                            "Add to Vocabulary",
                            isPresented: Binding(
                                get: { vocabAddSelection != nil },
                                set: { if !$0 { vocabAddSelection = nil } }
                            )
                        ) {
                            TextField("Word", text: $vocabAddText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Add") { confirmVocabAdd() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Heard \u{201C}\(vocabAddSelection?.selected ?? "")\u{201D}. Type the word Jot should write — or Add as-is.")
                        }
                } else {
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
            }
        }
        // The correction bubble is anchored at the word's tap-time rect, so any
        // scroll detaches it from the word. Drop it the instant the content
        // offset moves. `onScrollGeometryChange` (iOS 18+) fires on every
        // offset change, including a small finger drag — unlike
        // `onScrollPhaseChange`, which only fires on phase transitions.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, _ in
            if correctionBubble != nil { correctionBubble = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(selectedTab)
    }

    // MARK: - Correction tap bubble

    struct CorrectionBubbleAnchor {
        let record: CorrectionProvenance.Record
        let rect: CGRect   // word frame in window coordinates
    }

    @ViewBuilder
    private var correctionBubbleOverlay: some View {
        if let b = correctionBubble {
            GeometryReader { geo in
                // The word rect is in WINDOW coordinates; map it into this
                // overlay's local space by subtracting the overlay's own global
                // origin (don't assume window == local — that put the bubble a
                // safe-area-inset too low).
                let origin = geo.frame(in: .global).origin
                let local = b.rect.offsetBy(dx: -origin.x, dy: -origin.y)
                // Tap-catcher: tap anywhere outside the bubble to dismiss.
                // Stop short of the bottom ActionBar zone (~110pt incl. the
                // home-indicator safe area this overlay ignores) so it doesn't
                // eat the first tap on the action bar / back chevron — those
                // controls dismiss the bubble themselves on the next tap.
                Color.black.opacity(0.0001)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, geo.size.height - 110))
                    .contentShape(Rectangle())
                    .onTapGesture { correctionBubble = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                let leftX = bubbleX(local, in: geo.size.width)
                let above = bubbleFlipsAbove(local, in: geo.size.height)
                CorrectionBubble(
                    record: b.record,
                    // Arrow points at the word's center, relative to the bubble's
                    // left edge.
                    arrowX: local.midX - leftX,
                    above: above,
                    onPick: { choice in
                        correctionBubbleResolving = true
                        if let model = correctionModel {
                            Task { await model.pick(b.record, choice: choice) }
                        }
                    },
                    onResolvedDismiss: {
                        correctionBubbleResolving = false
                        correctionBubble = nil
                    })
                    .offset(x: leftX, y: bubbleY(local, in: geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea()
            // Handoff: translateY rise over 0.28s, NO opacity fade. A move
            // transition gives the rise, animated by the 0.28s signature ease
            // driven off the bubble's presence.
            .transition(.move(edge: .top))
            .animation(.timingCurve(0.45, 0.02, 0.2, 1, duration: 0.28), value: correctionBubble != nil)
        }
    }

    /// Whether the bubble flips ABOVE the word (mirrors `bubbleY`'s flip test).
    private func bubbleFlipsAbove(_ rect: CGRect, in height: CGFloat) -> Bool {
        let estBubbleH: CGFloat = 120
        return !(rect.maxY + 8 + estBubbleH < height)
    }

    /// Bubble left edge — centered under the word, clamped on-screen (272 wide).
    private func bubbleX(_ rect: CGRect, in width: CGFloat) -> CGFloat {
        let bubbleW: CGFloat = 272
        return min(max(rect.midX - bubbleW / 2, 12), max(12, width - bubbleW - 12))
    }
    /// Bubble top — below the word, flipped above when near the bottom.
    private func bubbleY(_ rect: CGRect, in height: CGFloat) -> CGFloat {
        let estBubbleH: CGFloat = 120
        if rect.maxY + 8 + estBubbleH < height { return rect.maxY + 8 }
        return max(12, rect.minY - 8 - estBubbleH)
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
        // Provenance sidecar (features.md §3.4): names the prompt that ran and
        // whether it ran automatically (§7.14) or from a tap here. Older notes
        // without a record fall back to the engine name.
        let provenance = RewriteProvenance.lookup(transcript.id)
        let base: String
        if let provenance {
            base = provenance.automatic
                ? "Cleaned up automatically with \u{201C}\(provenance.promptName)\u{201D}"
                : "Rewritten with \u{201C}\(provenance.promptName)\u{201D}"
        } else {
            base = "Rewritten with \(rewriteModelDisplayName)"
        }
        guard let stamp = lastRewriteAt ?? provenance?.at else { return base }
        let relative = stamp.formatted(.relative(presentation: .named))
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

    /// Shown while Automatic cleanup (§7.14, paste-right-away mode) is still
    /// producing this note's cleaned text. Same card as a running rewrite,
    /// minus Cancel — it's the pipeline's pass, not a tap to undo.
    private var cleaningCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Cleaning up…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.jotInk)
            Spacer()
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
        .accessibilityElement(children: .combine)
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
                label: "Rewrite",
                accessibilityLabel: rewriteAccessibilityLabel,
                isEnabled: isMagicEnabled
            ) {
                presentRewritePicker()
            },
            trailing: [
                // Globe peer (features.md §3.9): opens the ephemeral Translate sheet
                // for the active tab directly — no longer buried inside the Rewrite
                // picker. Apple on-device translation, nothing saved.
                ActionBarItem(
                    systemImage: "globe",
                    label: "Translate",
                    accessibilityLabel: "Translate transcript"
                ) {
                    showTranslateSheet = true
                },
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
        switch selectedTab {
        case .original: return !transcript.text.isEmpty
        case .rewrite:  return displayedRewriteText != nil
        // Speakers is a read-only view of persisted turns — never editable.
        case .speakers: return false
        }
    }

    private var editAccessibilityLabel: String {
        switch selectedTab {
        case .original: return "Edit original transcript"
        case .rewrite:  return "Edit rewrite"
        case .speakers: return "Edit"
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

            Button(action: toggleFindReplace) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(showFindReplace ? Color.jotBlueTop : Color.jotInk)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showFindReplace ? "Hide find and replace" : "Find and replace")

            // Proofread (iOS 27): run the system grammar checker over the draft
            // and offer each fix. Orange once issues are pending.
            if GrammarCheckService.isAvailable {
                Button(action: { runProofread(presentSheet: true) }) {
                    ZStack {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(grammarIssues.isEmpty ? Color.jotInk : Color.orange)
                            .opacity(isProofreading ? 0 : 1)
                        if isProofreading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isProofreading)
                .accessibilityLabel(grammarIssues.isEmpty
                    ? "Proofread"
                    : "Proofread — \(grammarIssues.count) \(grammarIssues.count == 1 ? "suggestion" : "suggestions")")
            }

            // AI rewrite of the draft (features.md §3.7): opens the SAME prompt
            // picker as the view pane (saved prompts, Voice prompt, Translate);
            // the chosen prompt rewrites what's in the editor in place. The
            // result renders as a session edit (italic), like an accepted
            // Proofread fix; Save keeps it, Cancel discards it. Shown whenever
            // Apple Intelligence is ready.
            if RewriteClient.isAvailable {
                Button(action: presentRewritePicker) {
                    ZStack {
                        Image(systemName: "sparkles")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.jotBlueTop)
                            .opacity(isRewritingDraft ? 0 : 1)
                        if isRewritingDraft {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRewritingDraft)
                .accessibilityLabel("Rewrite draft with AI")
                .accessibilityHint("Choose a prompt; the draft is rewritten in place. Save keeps it, Cancel discards it.")
            }

            Spacer(minLength: 6)

            // Center label can shrink/disappear; the side buttons must not.
            editBarCenterLabel
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
            .disabled(isRewritingDraft)
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

    /// Center label of the EditBar. Reads "Rewriting…" while the AI button is
    /// rewriting the draft.
    @ViewBuilder
    private var editBarCenterLabel: some View {
        if isRewritingDraft {
            Text("Rewriting…")
        } else {
            Text(editTargetTab == .original ? "Editing Original" : "Editing Rewrite")
        }
    }

    /// Edit mode's pick from the shared prompt picker (features.md §3.7):
    /// rewrite the CURRENT DRAFT in place with `prompt`. The result is assigned
    /// to `editorText`, so `InlineEditTextView` renders it as a session edit
    /// (italic) exactly like an accepted Proofread fix; Save persists it,
    /// Cancel drops it. If the user kept typing while the model worked, the
    /// result is NOT applied over their keystrokes.
    private func rewriteDraft(with prompt: SavedPrompt) {
        guard isEditing, !isRewritingDraft else { return }
        let draft = editorText
        let source = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            editError = "Nothing to rewrite yet."
            return
        }
        editError = nil
        grammarIssues = []
        isRewritingDraft = true
        draftRewriteTask?.cancel()
        draftRewriteTask = Task { @MainActor in
            defer {
                isRewritingDraft = false
                draftRewriteTask = nil
            }
            do {
                let result = try await RewriteClient.shared.rewrite(
                    text: source,
                    systemPrompt: prompt.systemPrompt
                )
                try Task.checkCancellation()
                guard isEditing else { return }
                guard editorText == draft else {
                    editError = "The text changed while rewriting — try the prompt again."
                    return
                }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    editError = "Rewrite returned no text."
                    return
                }
                editorText = trimmed
                detailLog.info(
                    "Draft rewrite applied prompt=\(prompt.id, privacy: .public) inputChars=\(source.count) outputChars=\(trimmed.count)"
                )
            } catch is CancellationError {
                // Edit mode ended or the view went away — nothing to apply.
            } catch {
                editError = "Couldn't rewrite: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Find & Replace bar

    /// Whole-word, case-insensitive pattern for `findText`. Returns nil for an
    /// empty term or an un-compilable pattern (the escaped term is always valid,
    /// so this only nils on empty).
    private func wholeWordRegex(_ term: String) -> NSRegularExpression? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: t) + "\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Live count of whole-word matches of `findText` in the working text.
    private var findMatchCount: Int {
        guard let re = wholeWordRegex(findText) else { return 0 }
        let ns = editorText as NSString
        return re.numberOfMatches(in: editorText, range: NSRange(location: 0, length: ns.length))
    }

    /// Replaces every whole-word match of `findText` with `replaceText` in
    /// `editorText`. The inline editor ingests the new value as a programmatic
    /// change, so the swapped words render italic. Records the replace so Save
    /// can offer to learn it.
    private func performReplaceAll() {
        guard let re = wholeWordRegex(findText) else { return }
        let ns = editorText as NSString
        let full = NSRange(location: 0, length: ns.length)
        let count = re.numberOfMatches(in: editorText, range: full)
        guard count > 0 else { return }
        let template = NSRegularExpression.escapedTemplate(
            for: replaceText.trimmingCharacters(in: .whitespacesAndNewlines))
        let newText = re.stringByReplacingMatches(in: editorText, range: full, withTemplate: template)
        editorText = newText
        pendingReplaceLearn = ReplaceLearn(
            find: findText.trimmingCharacters(in: .whitespacesAndNewlines),
            replace: replaceText.trimmingCharacters(in: .whitespacesAndNewlines),
            count: count)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Toggles the find/replace bar, handing focus between the editor and the
    /// find field so the two text views don't fight over first responder.
    private func toggleFindReplace() {
        if showFindReplace {
            showFindReplace = false
            findFieldFocused = false
            editorFocused = true
        } else {
            // Just show the bar. Focus is taken in the find field's `.onAppear`
            // once it's actually mounted — setting it here raced the field's
            // mount (it didn't exist yet), so the first open landed focus nowhere
            // and typing only worked after manually tapping a field and back.
            showFindReplace = true
        }
    }

    private var findReplaceBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                fieldChrome {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                    TextField("Find", text: $findText)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($findFieldFocused)
                        .submitLabel(.search)
                        .onAppear {
                            // Take focus once the field is actually in the
                            // hierarchy. Grab first responder for the find field
                            // first (the editor yields it, so the system keyboard
                            // stays up — no flicker), THEN drop `editorFocused` so
                            // the inline editor can't reclaim it on the next pass.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                findFieldFocused = true
                                editorFocused = false
                            }
                        }
                }
                if !findText.isEmpty {
                    Text(findMatchCount == 1 ? "1 match" : "\(findMatchCount) matches")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(findMatchCount == 0 ? Color.jotMute : Color.jotInk)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 8) {
                fieldChrome {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                    TextField("Replace with", text: $replaceText)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                }
                Button(action: performReplaceAll) {
                    Text("Replace All")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
                }
                .buttonStyle(.plain)
                .disabled(findText.isEmpty || findMatchCount == 0)
                .opacity(findText.isEmpty || findMatchCount == 0 ? 0.45 : 1)
                .accessibilityLabel("Replace all \(findMatchCount) matches")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .modifier(JotDesign.Surface.heavy.modifier(cornerRadius: JotDesign.Spacing.sheetRadius))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Shared pill chrome for the find/replace text fields.
    @ViewBuilder
    private func fieldChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.jotInk.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.jotInk.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: - Learn-it offer (after a qualifying Replace All)

    /// True when a Replace All looks like a term correction worth learning:
    /// a real change (term ≠ heard), a 1–2 word term that isn't all common
    /// words, applied to 2+ occurrences (the user's "misheard several times").
    private func qualifiesForVocab(_ l: ReplaceLearn) -> Bool {
        guard l.count >= 2 else { return false }
        let term = l.replace.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = l.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !heard.isEmpty else { return false }
        guard term.compare(heard, options: .caseInsensitive) != .orderedSame else { return false }
        let words = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...2).contains(words.count) else { return false }
        return words.contains {
            !CommonWords.isCommon(
                $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()")))
        }
    }

    /// Learns the term: same correction as selection "Add to Vocabulary"
    /// (`confirmVocabAdd`) through the one path — the term, plus the misheard
    /// form as a visible sounds-like, so the next dictation can write it. The
    /// text fix already happened via Replace All.
    private func confirmReplaceVocab(_ offer: ReplaceVocabOffer) {
        replaceVocabOffer = nil
        let correction = Correction.correct(heard: offer.heard, term: offer.term, userCasing: true)
        Task { @MainActor in
            if case .rejected = await VocabularyLearning.shared.apply(correction).outcome { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func replaceVocabOfferCard(_ offer: ReplaceVocabOffer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBox(symbol: "character.book.closed", tint: Color(red: 0x1F/255, green: 0xCE/255, blue: 0xD1/255), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add “\(offer.term)” to your vocabulary?")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                Text("Jot heard it as “\(offer.heard)” \(offer.count) times. Learn it so the next dictation gets it right.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button { replaceVocabOffer = nil } label: {
                        Text("Not now")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.jotMute)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    Button { confirmReplaceVocab(offer) } label: {
                        Text("Add")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(height: 38)
                            .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .modifier(JotDesign.Surface.heavy.modifier(cornerRadius: JotDesign.Spacing.sheetRadius))
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

    /// Transform tap is ALWAYS clickable — what it does depends on state.
    /// The only hard-disabled case is a rewrite already running (don't fire
    /// a second request). Everything else routes through
    /// `presentRewritePicker()`, which branches on Apple Intelligence
    /// availability and prompt availability and either opens the picker or
    /// pushes the user to AI Settings.
    private var isMagicEnabled: Bool {
        rewriteState != .running
    }

    private var rewriteAccessibilityLabel: String {
        if rewriteState == .running { return "Rewriting" }
        if case .unavailable = RewriteClient.availability {
            return "Apple Intelligence is off — open Settings"
        }
        if savedPrompts.isEmpty {
            return "Set up AI Rewrite in Settings"
        }
        return "Rewrite with AI"
    }

    /// Called by the action-bar Transform + the top sparkle button + the
    /// empty-state Rewrite card:
    ///   - Apple Intelligence unavailable, or no saved prompts → present
    ///     `AIRewriteSettingsView` as a sheet (the single setup surface).
    ///   - Otherwise → present `RewritePickerSheet` (Mockup 10).
    private func presentRewritePicker() {
        guard isMagicEnabled else { return }
        guard RewriteClient.isAvailable else {
            showAISettings = true
            return
        }
        if savedPrompts.isEmpty {
            showAISettings = true
            return
        }
        showRewritePicker = true
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

    private var durationText: String? {
        guard let duration = transcript.durationSeconds else { return nil }
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Dictation-language badge text — the English name of the transcript's
    /// language (`Transcript.language`), resolving `nil`/unknown to English.
    /// Always shown (including English) so every transcript surfaces the
    /// language it was dictated in at a glance.
    private var languageBadgeText: String? {
        LanguageChoice.fromStored(transcript.language).englishName
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
        case .speakers:
            // Copy/Share on the Speakers tab yields the labeled turns; falls
            // back to the raw text if the rows somehow can't be decoded.
            guard let rows = speakerRows else { return transcript.text }
            return rows
                .map { "\($0.label): \($0.text)" }
                .joined(separator: "\n\n")
        }
    }

    /// Display name for the rewrite-engine attribution line.
    ///
    /// Routes through `JotDesign.activeRewriteModelDisplayName` — the single
    /// source of truth for the engine brand string across the
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
        // Unreachable — `isEditEnabled` is false on Speakers so `beginEdit`
        // returns above — but the switch must stay exhaustive.
        case .speakers:
            editorText = transcript.text
        }
        editBaseline = editorText
        editError = nil
        // Fresh edit session: dismiss any prior learn-it card and reset find state.
        replaceVocabOffer = nil
        draftRewriteTask?.cancel()
        draftRewriteTask = nil
        isRewritingDraft = false
        showFindReplace = false
        findText = ""
        replaceText = ""
        pendingReplaceLearn = nil
        grammarIssues = []
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

        // Resolve which field this save changes (or bail early on the no-op
        // cases) before handing the persistence to the Repository. Exactly
        // one of these is non-nil on a real change.
        var newText: String? = nil
        var newRewriteUserEdit: String?? = nil

        switch editTargetTab {
        // `editTargetTab` is captured from `selectedTab` at edit-start, and edit
        // mode is unreachable on Speakers (`isEditEnabled` is false there) — but
        // keep the switch exhaustive: bail cleanly if it's ever hit.
        case .speakers:
            exitEditMode()
            return
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
            newText = trimmed

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
                newRewriteUserEdit = .some(nil)
            } else {
                // Skip the write if the user typed nothing new vs. the
                // current display value (rewriteUserEdit ?? cleanedText).
                let current = transcript.rewriteUserEdit ?? transcript.cleanedText ?? ""
                if trimmed == current {
                    exitEditMode()
                    return
                }
                newRewriteUserEdit = .some(trimmed)
            }
        }

        do {
            try TranscriptStore.update(id: transcript.id, text: newText, rewriteUserEdit: newRewriteUserEdit)
            // An Original-tab edit that actually changed the text invalidates any
            // stored diarization result (its turns distribute the OLD text across
            // segments). Rewrite saves never touch Original, so they don't
            // invalidate — `newText != nil` is exactly the changed-Original case.
            if newText != nil {
                try? TranscriptStore.updateDiarization(id: transcript.id, json: nil)
            }
            detailLog.info(
                "Transcript edit SAVED tab=\(editTargetTab.rawValue, privacy: .public) chars=\(trimmed.count)"
            )
        } catch {
            editError = "Couldn't save: \(error.localizedDescription)"
            detailLog.error(
                "Transcript edit save FAILED tab=\(editTargetTab.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Capture a qualifying replace before exit clears the tracking, then
        // surface the gentle learn-it card once we're back in read mode.
        let offer: ReplaceVocabOffer? = {
            guard let l = pendingReplaceLearn, qualifiesForVocab(l) else { return nil }
            return ReplaceVocabOffer(term: l.replace, heard: l.find, count: l.count)
        }()

        // Learn from the edit (Learn from Corrections): the diff of what was on
        // screen at Edit vs. what was saved becomes corrections through the one
        // path. Captured now — exitEditMode clears the editor state.
        //   - Original tab: the field IS the model's text, so raw is empty
        //     (every replaced word counts as heard); review records live in
        //     this text, so the edit closes the pair's open ones.
        //   - Rewrite tab: teaches NOTHING (owner, 2026-09-30). That text was
        //     written by the AI, so an edit there fixes the AI's wording, not a
        //     word the speech model misheard.
        let learnBefore = editBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
        let learnAfter: String? = newText
        let learnRaw = ""
        let transcriptID = transcript.id
        exitEditMode()
        guard let learnAfter else {
            if let offer { withAnimation { replaceVocabOffer = offer } }
            return
        }
        Task { @MainActor in
            let lessons = await EditLearning.learn(
                transcriptID: transcriptID, before: learnBefore, after: learnAfter,
                raw: learnRaw, reviewText: newText)
            if newText != nil { await correctionModel?.reload() }
            // A Replace All the edit already taught needs no second offer.
            if let offer, !EditLearning.taught(lessons, heard: offer.heard, term: offer.term) {
                withAnimation { replaceVocabOffer = offer }
            }
        }
    }

    /// True while edit mode holds text that `saveEdit()` would actually
    /// persist. Mirrors `saveEdit()`'s trim + no-op rules, so a
    /// whitespace-only difference counts as "nothing changed" (Save would
    /// no-op on it too) and Back just leaves.
    ///
    /// One deliberate divergence: the STORED side is trimmed here too, which
    /// `saveEdit()` does not do. Some writers (`TranscriptStore.append` via the
    /// keyboard insert / combine / share paths) persist text with surrounding
    /// whitespace, and comparing untrimmed-stored vs trimmed-editor made such
    /// a transcript read "dirty" the instant edit mode opened — a false
    /// "Save your changes?" on an untouched editor. Saving such a transcript
    /// genuinely rewrites it (to the trimmed form), but that is not a change
    /// the USER made, and this predicate exists to protect user edits.
    /// `saveEdit()`'s own untrimmed comparison stays as is — it is
    /// load-bearing for the write/no-op decision.
    private var hasUnsavedEdits: Bool {
        guard isEditing else { return false }
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editTargetTab {
        // Unreachable (edit mode can't open on Speakers), and `saveEdit()`
        // writes nothing there either.
        case .speakers:
            return false
        case .original:
            return trimmed != transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .rewrite:
            // Empty means "clear my edit" — a change only if there is one.
            if trimmed.isEmpty { return transcript.rewriteUserEdit != nil }
            let stored = transcript.rewriteUserEdit ?? transcript.cleanedText ?? ""
            return trimmed != stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Back-chevron tap. Pops straight out from read mode and from an
    /// untouched editor; with unsaved changes it asks first (Save /
    /// Discard Changes / Keep Editing) and pops from the dialog instead.
    private func back() {
        guard isEditing else {
            dismiss()
            return
        }
        guard hasUnsavedEdits else {
            exitEditMode()
            dismiss()
            return
        }
        pendingEditExit = true
    }

    /// Discards local edit state without persisting. The transcript fields
    /// are untouched, so re-entering edit mode shows the unmodified text.
    private func cancelEdit() {
        exitEditMode()
    }

    /// Common exit path for both Save and Cancel. Drops the keyboard,
    /// clears local edit state, and brings the regular ActionBar back.
    private func exitEditMode() {
        draftRewriteTask?.cancel()
        draftRewriteTask = nil
        isRewritingDraft = false
        editorSelection = nil
        editorFocused = false
        isEditing = false
        editError = nil
        editorText = ""
        // Tear down find/replace; the post-save offer (`replaceVocabOffer`) is
        // intentionally left alone — it shows in read mode after we exit.
        showFindReplace = false
        findFieldFocused = false
        findText = ""
        replaceText = ""
        pendingReplaceLearn = nil
        grammarIssues = []
        showProofread = false
    }

    /// Run the system grammar checker over the current draft. Presents the
    /// suggestions sheet when asked (the edit-bar tap); the re-check after an
    /// accepted fix only refreshes the underlines behind the still-open sheet.
    private func runProofread(presentSheet: Bool) {
        guard GrammarCheckService.isAvailable, !isProofreading else { return }
        let draft = editorText
        isProofreading = true
        Task { @MainActor in
            let issues = await GrammarCheckService.check(draft)
            // Ignore a stale result if the user kept typing meanwhile.
            guard draft == editorText else { isProofreading = false; return }
            grammarIssues = issues
            isProofreading = false
            if presentSheet { showProofread = true }
        }
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

        // Optimistically reflect the new rating on the live (scene-context)
        // object so the thumb glyph updates immediately; the Repository
        // persists on its own context (save ONLY — no mirror/notify, ratings
        // aren't shown cross-process). On failure, revert the in-memory value
        // so the glyph snaps back to its prior state.
        transcript.rewriteUpvoted = next
        do {
            try TranscriptStore.setRewriteRating(id: transcript.id, rating: next)
            copyHaptic.impactOccurred()
            copyHaptic.prepare()
            detailLog.info(
                "Rewrite rating set up=\(up, privacy: .public) next=\(String(describing: next), privacy: .public) transcript=\(transcript.id, privacy: .public)"
            )
        } catch {
            transcript.rewriteUpvoted = previous
            detailLog.error(
                "Rewrite rating save FAILED error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func delete() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil

        let id = transcript.id
        dismiss()
        Task { @MainActor in
            do {
                try TranscriptStore.delete(id: id)
            } catch {
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

        // A user-edit OR rating against a discarded rewrite is meaningless
        // — the training "before" half is gone. The Repository clears all
        // three together (cleanedText, rewriteUserEdit, rewriteUpvoted).
        do {
            try TranscriptStore.discardRewrite(id: transcript.id)
        } catch {
            detailLog.error("Discard rewrite save failed: \(error.localizedDescription, privacy: .public)")
        }

        selectedTab = .original
    }

    // MARK: - Rewrite lifecycle

    /// Reloads the saved prompts so the Rewrite pill and picker reflect
    /// edits made in Settings. Engine availability is read live from
    /// `RewriteClient.availability` at tap time — nothing to poll.
    private func refreshRewriteAvailability() {
        savedPrompts = SavedPromptStore.all()
    }

    /// Kicks off an in-process rewrite via `RewriteClient`. On success the rewrite is persisted to `cleanedText` immediately and
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
        // Correctness-only guard. Do NOT re-check `isMagicEnabled` here: the
        // picker has already been presented, so the user clearly intended a
        // rewrite.
        guard rewriteState != .running else { return }

        activeRewriteTask?.cancel()
        rewriteState = .running
        selectedTab = .rewrite

        let promptText = prompt.systemPrompt
        let task = Task { @MainActor in
            do {
                let result = try await RewriteClient.shared.rewrite(
                    text: source,
                    systemPrompt: promptText
                )
                try Task.checkCancellation()
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    rewriteState = .error("Rewrite returned no text.")
                    return
                }
                do {
                    // Persistence core: set cleanedText + clear stale
                    // userEdit/rating (a fresh model output makes the prior
                    // user-edit and rating meaningless) + mirror + notify.
                    try TranscriptStore.setCleanedText(id: transcript.id, cleanedText: trimmed)
                    RewriteProvenance.record(transcriptID: transcript.id, promptName: prompt.name, automatic: false)
                    lastRewriteAt = Date()
                    rewriteState = .idle
                    detailLog.info(
                        "Transcript rewrite SUCCESS prompt=\(prompt.id, privacy: .public) inputChars=\(source.count) outputChars=\(trimmed.count)"
                    )
                } catch {
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

    /// Voice-prompt system prompt (picker row 2). Wraps the user's spoken
    /// instruction in a system prompt phrased like the bundled defaults
    /// (`SavedPrompt.defaultArticulate` et al. — imperative, with the
    /// "do not invent" guardrail and the "Return only the rewrite."
    /// output-format boilerplate) as an ephemeral `SavedPrompt` that either
    /// rewrite path runs. Nothing is persisted to `SavedPromptStore`.
    static func voicePrompt(for instruction: String) -> SavedPrompt? {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let systemPrompt =
            "Rewrite this dictation following the speaker's spoken instruction. " +
            "Instruction: \"\(trimmed)\". " +
            "Apply the instruction faithfully. " +
            "Do not invent new ideas or details beyond what the instruction asks for. " +
            "Fix obvious dictation errors. " +
            "Return only the rewrite."
        return SavedPrompt(
            id: UUID(),
            name: "Voice prompt",
            systemPrompt: systemPrompt,
            createdAt: Date(),
            sortOrder: .max
        )
    }

    /// Words in the edit draft — the picker's sub-line while editing.
    private var draftWordCount: Int {
        editorText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
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
