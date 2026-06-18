import SwiftUI
import UIKit

/// Compact Jot keyboard surface — Phase 2 of the UX overhaul.
///
/// Standard-mode keyboard with:
///   - Top strip: `RecentsStrip` (idle) / `StreamingStrip` (recording).
///     Recents shows top-5 with an optional "just now" marker for the
///     most recent successful paste (Mockup 01 / 02 / 03).
///   - Action row: Minimize + Dictate pill (red stop pill while
///     recording) + Actions (popover trigger). Punctuation row is
///     hidden while recording per Mockup 02.
///   - Bottom row: space + return (globe key removed 2026-05-11 — user
///     explicitly opted out per ux-overhaul-plan §4.1; system globe in
///     the iOS keyboard chrome is the path to switch input modes).
///   - Bottom-right Actions button toggles a 220pt-wide glass-heavy
///     popover anchored above it (Mockup 06).
///
/// All visual tokens go through `JotDesign` / `JotType` / Phase-1
/// components. The view stays stateless: every mutating action is a
/// controller callback. Backend invariant: zero changes to the
/// recording / transcription / Darwin-notification stack.
struct KeyboardView: View {
    let hasFullAccess: Bool
    let hasPasteboardContent: Bool
    let recordingState: KeyboardRecordingState
    let needsInputModeSwitchKey: Bool
    let returnKeyType: UIReturnKeyType
    let historyEntries: [TranscriptHistoryMirror.Entry]
    let canUndoLastInsertion: Bool
    let canRedoInsertion: Bool

    /// Source of truth for the just-now marker (plan §13 risk 7).
    /// Set by the keyboard controller at the moment a successful paste
    /// lands; `AppGroup.lastDictation` is NOT a valid source (consumed
    /// by the auto-paste pipeline).
    let lastPastedText: String?
    let lastPastedAt: Date?

    /// True from the moment the keyboard's controller posted `stopRequested`
    /// until the next `pipelinePhaseChanged` confirming a non-`.recording`
    /// phase. Used to disable the speak button so iOS suppresses taps while
    /// the stop is in flight.
    let isStopRequestPending: Bool

    /// Transient status banner text (e.g. "Rewrite timed out").
    let statusBanner: String?

    /// WS-F — when true, the keyboard renders the warm-hold switching nudge
    /// over the strip area (the app computes the streak math and sets the
    /// `warmHoldNudgeShouldShow` App-Group projection; the keyboard renders
    /// off this boolean and writes the two terminal actions back).
    let showWarmHoldNudge: Bool

    /// v2 retheme (2026-05-11) — host's `keyboardAppearance` hint
    /// (`UIKeyboardAppearance.default` / `.light` / `.dark`). Some
    /// hosts force `.dark` even when the system is in light mode; this
    /// signal is OR-ed with the SwiftUI `colorScheme` env to determine
    /// the effective scheme. Passed from the controller in
    /// `JotKeyboardViewController.makeKeyboardView` via
    /// `textDocumentProxy.keyboardAppearance`.
    let keyboardAppearance: UIKeyboardAppearance

    /// True iff the host's focused field currently has a non-empty
    /// selection. Drives the enabled state of the Actions popover's
    /// Copy row. The controller composes this from
    /// `hasFullAccess && (textDocumentProxy.selectedText is non-empty)`
    /// at every render — Copy is disabled when either condition fails.
    let hasSelection: Bool

    let onCopy: () -> Void
    let onPaste: () -> Void
    let onUndoLastInsertion: () -> Void
    let onRedoInsertion: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onTapToSpeak: () -> Void
    let onInsertHistoryEntry: (TranscriptHistoryMirror.Entry) -> Void
    let onInsertText: (String) -> Void
    let onKey: (KeyboardKeyDescriptor) -> Void
    let onKeyPressChange: (KeyboardKeyDescriptor, Bool) -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onOpenFullAccess: () -> Void
    let onStatusBannerRendered: () -> Void

    /// "See all" tap on the recents card header. Launches the containing
    /// app at the home view via `jot://history` (handled by `JotApp`'s
    /// `.onOpenURL`). Distinct from `onTapToSpeak` — this one does NOT
    /// auto-start a recording; it just opens the app.
    let onOpenHome: () -> Void

    /// Per-row trailing "open in app" tap on the recents card. Launches
    /// the containing app and pushes the transcript detail view via
    /// `jot://transcript?id=<uuid>`. Distinct from `onInsertHistoryEntry`
    /// (paste-at-cursor on the row body) — the row carries two zones.
    let onOpenHistoryEntryInApp: (TranscriptHistoryMirror.Entry) -> Void

    /// Fired when the user taps the Actions button to OPEN the popover.
    /// Lets the controller refresh state that's stale between keyboard
    /// presentations — currently the clipboard read in `refreshPasteState`,
    /// which only ran at `viewWillAppear` before, so the Paste row would
    /// reflect stale clipboard content on subsequent popover opens within
    /// the same keyboard session. Reading `UIPasteboard` triggers iOS's
    /// privacy toast, so this fires only on the explicit OPEN edge — not
    /// on close, not on every key tap.
    let onActionsTapped: () -> Void

    /// Fired when the user taps the Cancel button while a dictation is
    /// actively recording. During recording the trash-can Cancel control sits
    /// on the LEFT of the control cluster (WS-D / §2.6); once Stop is tapped
    /// (or cancel completes), the controls return to the idle Actions layout.
    /// Cancel discards the partial — no transcript saved, no auto-paste.
    let onCancelRecording: () -> Void

    /// WS-C / §10 — fired when the user taps Pause during an active (non-
    /// paused) dictation. Posts `pauseRequested` to the main app; the engine
    /// keeps running but the slice router drops buffers (mic stays warm,
    /// nothing captured). The app publishes `.paused`, flipping the control
    /// to Resume.
    let onPauseRecording: () -> Void

    /// WS-C / §10 — fired when the user taps Resume on a paused dictation.
    /// Posts `resumeRequested`; capture re-arms against the same slice so
    /// samples concatenate.
    let onResumeRecording: () -> Void

    /// WS-F / §4 — warm-hold nudge "Keep mic ready" (accept). One tap, no
    /// confirm: flips warm hold on for next time.
    let onWarmHoldNudgeKeepMicReady: () -> Void

    /// WS-F / §4 — warm-hold nudge "Don't show this again" (dismiss). One tap,
    /// no confirm: permanent suppression.
    let onWarmHoldNudgeDismiss: () -> Void

    /// Correction quick-review — when true, the keyboard renders the post-paste
    /// correction-review strip over the strip area (higher priority than the
    /// warm-hold nudge). The app publishes the asks keyed by sessionID; the
    /// keyboard reads them after a successful paste and shows this surface.
    let showCorrectionNudge: Bool

    /// The asks to adjudicate (already validated to match the just-pasted
    /// session). Non-nil whenever `showCorrectionNudge` is true.
    let correctionAsks: CorrectionBridge.Asks?

    /// (recordKey, verdict) — the owner picked a word; the controller enqueues
    /// a verdict event back to the app. verdict is "term" | "original".
    let onCorrectionVerdict: (String, String) -> Void

    /// The review flow finished (or was dismissed) — drop the strip slot back
    /// to recents and clear the published asks.
    let onCorrectionFinished: () -> Void

    let feedback: KeyboardFeedback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// v2 retheme — SwiftUI's own scheme. Used together with the host's
    /// `keyboardAppearance` to pick a final effective scheme (see
    /// `effectiveColorScheme`). Either signal saying "dark" wins.
    @Environment(\.colorScheme) private var systemColorScheme

    /// Whether the bottom-right Actions popover is currently shown. Local
    /// state — the controller doesn't need to know about popover visibility
    /// because the popover dismisses itself after every tap.
    @State private var showActionsPopover: Bool = false

    var body: some View {
        standardModeBody
        // v2 retheme: force the SwiftUI color-scheme env to the resolved
        // effective scheme so every adaptive `Color(uiColor: UIColor { ... })`
        // token below — chrome stops, glass fills, key faces — resolves
        // against the same source of truth. If the host says dark
        // (keyboardAppearance == .dark) but the system is in light, we
        // still want dark tokens; .environment(...) accomplishes that.
        .environment(\.colorScheme, effectiveColorScheme)
        // CRITICAL INVARIANT: this MUST equal
        // `JotKeyboardViewController.expandedHeight`. The keyboard's height is
        // pinned by a 999-priority `heightAnchor` constraint on `self.view`, but
        // the `UIHostingController` is edge-pinned to `self.view`, so this hosted
        // SwiftUI content's intrinsic height propagates UP and — when it exceeds
        // the 999 pin — can override it: the host then lays out a taller input
        // view and the bottom controls fall below the visible keyboard envelope
        // (the "I see the strip but the buttons are clipped / untappable" bug,
        // which was minHeight 310 vs a 204 pin). Keeping the two equal removes
        // the disagreement entirely. Derived from content, not guessed:
        //   top 8 + RecentsStrip 129 + spacing 6 + controls ~49 + bottom 4
        //   ≈ 196pt idle; recording is shorter (StreamingStrip 124 ⇒ ~191).
        //   Both fit a 200pt envelope; the Spacer absorbs the few-pt slack.
        .frame(minHeight: 200)
    }

    /// Standard-mode body. Collapsed/minimized mode was removed in the WS-D
    /// restructure — the keyboard is a single fixed-height surface now.
    private var standardModeBody: some View {
        GeometryReader { proxy in
            let metrics = KeyboardMetrics(availableWidth: proxy.size.width)
            ZStack(alignment: .bottomTrailing) {
                // Bug 8/spacing-tightening (2026-05-11): drop inter-row
                // spacing from `metrics.rowSpacing` (~9pt) to 6pt so the
                // keyboard reads dense like the native iOS surface.
                // Outer vertical padding tightened from `verticalInset`
                // (~4.5pt) to a flat 4pt for the same reason. Going to 0
                // was rejected — keys need breathing room.
                VStack(spacing: 6) {
                    // Actions panel REPLACES the recents strip while open — it
                    // lives in the top region as a sibling of the controls row,
                    // so it can never overlay/hide the dictate/controls row the
                    // way the old floating popover did (user fix). The "…" button
                    // toggles it; a row tap runs its action and dismisses.
                    if showActionsPopover {
                        actionsPanel(metrics: metrics)
                    } else {
                        topStrip(metrics: metrics)
                    }
                    // iOS won't let a custom keyboard shrink below its minimum
                    // height, and the system globe/mic row sits below this view.
                    // A short one-row layout therefore leaves the keyboard taller
                    // than its content — so PIN the controls to the bottom (the
                    // natural thumb position, just above the system row) with the
                    // strip filling the top. The unavoidable extra height becomes
                    // breathing room between them, not a dead gap under floating
                    // controls. Controls + adaptive Enter still share ONE row.
                    Spacer(minLength: 0)
                    controlAndEnterRow(metrics: metrics)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // WS-D: native ~0.4cm side margins so the surface doesn't span
                // full width. `metrics.sideInset` (3pt) is Apple's key-cap
                // inset; we add the extra inset here on the whole cluster.
                .padding(.horizontal, metrics.sideInset + Self.sideMargin)
                // Extra top inset so the strip isn't clipped against the keyboard
                // top edge / rounded corner.
                .padding(.top, 8)
                .padding(.bottom, 4)
                // Transparent chrome lets the native keyboard backdrop render
                // through in both idle and recording.
                .background(chromeBackground)
                .overlay(alignment: .top) {
                    statusBannerOverlay
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, 4)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                       value: showActionsPopover)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                       value: recordingState.isRecording)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: showWarmHoldNudge)
        }
    }

    /// WS-D — extra horizontal margin added on EACH side of the whole control
    /// cluster (on top of Apple's 3pt key-cap inset) so the keyboard surface
    /// doesn't span the full screen width. ~0.4cm ≈ 11pt at the standard
    /// 72ppi → pt mapping. Tunable per the plan (pixel sizes are adjustable).
    private static let sideMargin: CGFloat = 11

    // MARK: - Actions panel

    /// Actions menu shown in the TOP region (in place of the recents strip)
    /// while "…" is active — a sibling of the controls row, never an overlay, so
    /// it can't hide the dictate/controls row. Wrapped in a ScrollView so all
    /// four rows stay reachable even though the 200pt keyboard's top region is
    /// short; it never grows down into the controls row.
    private func actionsPanel(metrics: KeyboardMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            ActionsPopover(
                hasPasteboardContent: hasPasteboardContent,
                hasSelection: hasSelection,
                canUndo: canUndoLastInsertion,
                canRedo: canRedoInsertion,
                onPaste: onPaste,
                onCopy: onCopy,
                onUndo: onUndoLastInsertion,
                onRedo: onRedoInsertion,
                onJumpToStart: onJumpToStart,
                onJumpToEnd: onJumpToEnd,
                onDismiss: { showActionsPopover = false }
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(
            reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
        )
    }

    // MARK: - Top strip (recents / streaming)

    /// Idle vs streaming branch. In landscape (compact vertical size class)
    /// we still render the strip but at a smaller height — the keyboard
    /// envelope itself shrinks, but losing the strip would break the
    /// just-now feedback loop after auto-paste.
    @ViewBuilder
    private func topStrip(metrics: KeyboardMetrics) -> some View {
        // WS-F: the warm-hold switching nudge takes over the strip area when
        // the app flags it (it only fires post-stop, so the strip is showing
        // recents — never the live stream — at that moment). One-shot, off the
        // shared App-Group boolean.
        if showCorrectionNudge, !recordingState.isRecording, let asks = correctionAsks {
            CorrectionReviewStrip(
                asks: asks.asks,
                totalUnresolved: asks.totalUnresolved,
                reduceMotion: reduceMotion,
                feedback: feedback,
                onVerdict: onCorrectionVerdict,
                onFinished: onCorrectionFinished
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top))
            )
        } else if showWarmHoldNudge && !recordingState.isRecording {
            WarmHoldNudgeStrip(
                reduceMotion: reduceMotion,
                onKeepMicReady: onWarmHoldNudgeKeepMicReady,
                onDismiss: onWarmHoldNudgeDismiss,
                feedback: feedback
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top))
            )
        } else {
            topStripContent(metrics: metrics)
        }
    }

    @ViewBuilder
    private func topStripContent(metrics: KeyboardMetrics) -> some View {
        if recordingState.isRecording {
            StreamingStrip(
                partialText: recordingState.streamingPartialText,
                startedAt: recordingState.startedAt,
                isPaused: recordingState.isPaused,
                pausedElapsedSeconds: recordingState.pausedElapsedSeconds,
                // WS-D: when controls + Enter share one row (large widths) the
                // elapsed timer relocates from the Stop pill to the strip
                // header so the pill can shrink. Below 428 the pill keeps the
                // timer and the header omits it to avoid duplication.
                showsHeaderTimer: metrics.isLargeWidth,
                // The label is now a full editorial cold-start line
                // (`ColdStartCopy`), not a model name — no "Loading …" prefix.
                // The strip defers showing it until a load is genuinely slow.
                loadingLabel: recordingState.loadingVariantLabel.isEmpty
                    ? nil
                    : recordingState.loadingVariantLabel,
                // Short echo of the hero's "a sharper transcriber takes a second
                // pass when you stop" promise, sized for the header. Shown ONLY
                // once live text is streaming — never during the load/listen
                // window (there's nothing yet to tidy up).
                statusLine: recordingState.streamingPartialText.isEmpty
                    ? nil
                    : "We tidy this up when you stop"
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top))
            )
        } else if !hasFullAccess {
            // Replace the (would-be-empty) recents strip with a
            // breadcrumb that teaches the user how to enable Full Access
            // manually. We can't reliably open iOS Settings from a custom
            // keyboard extension on iOS 26, so this teaching surface is
            // the substitute. Height matches RecentsStrip so the layout
            // doesn't jump when FA gets turned on.
            fullAccessInstructions
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
        } else {
            RecentsStrip(
                entries: historyEntries,
                onInsertEntry: onInsertHistoryEntry,
                onOpenInApp: onOpenHistoryEntryInApp,
                onSeeAll: onOpenHome
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top))
            )
        }
    }

    /// Instructional surface shown in place of the recents strip when
    /// Full Access has not been granted. Walks the user through the
    /// Settings path to flip Allow Full Access. Visually mirrors the
    /// recents strip envelope (Liquid Glass card, ~129pt tall) so the
    /// keyboard chrome stays geometrically stable across the FA toggle.
    private var fullAccessInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                Text("ENABLE FULL ACCESS TO DICTATE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundStyle(Color.white.opacity(0.66))

            Text("iPhone Settings  →  General  →  Keyboard")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
            Text("Keyboards  →  Jot Keyboard  →  Allow Full Access")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 129) // matches RecentsStrip.stripHeight
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 4)
    }

    // MARK: - Action + mic row

    /// Primary controls row (below-428 widths, or as the shared row's control
    /// cluster on large widths via `controlAndEnterRow`).
    ///
    /// WS-D control set (§2.6 / §5.4):
    ///   - Idle:       `[ Dictate pill ............. ] [ Actions ]`
    ///   - Recording:  `[trash-Cancel] [Pause/Resume] [ Stop pill ......... ]`
    ///     — Cancel is a trash-can on the LEFT for reach; Pause/Resume sits
    ///       between it and the Stop pill. Once Stop is tapped
    ///       (`isStopRequestPending`) the cluster collapses back to the idle
    ///       Actions layout (Stop is the commit point — no Cancel/Pause after).
    /// The minimize/expand chevron was removed (WS-D); there is no collapsed
    /// surface to toggle into.
    private var actionAndMicRow: some View {
        // Below-428: Enter lives on its own row below, so the header omits the
        // timer and the Stop pill keeps it (`showsHeaderTimer: false`).
        controlCluster(showsHeaderTimer: false)
            // Bug 8 (2026-05-11): action row trimmed from 52 → 48pt — pairs
            // with the dictate button's matching `minHeight: 48` change so
            // the row fits the tighter ~310pt envelope without clipping.
            .frame(minHeight: 48)
    }

    /// WS-D large-width (≥428) single row: the control cluster + the adaptive
    /// Enter share one line (R8). The Enter takes a fixed trailing width; the
    /// cluster flexes to fill the rest.
    private func controlAndEnterRow(metrics: KeyboardMetrics) -> some View {
        let showsHeaderTimer = metrics.isLargeWidth
        let enterWidth = max(72, metrics.letterKeyWidth * 2.0)
        return Group {
            if recordingState.isRecording && !isStopRequestPending {
                // Recording: trash · pause · Stop (flex) · Enter.
                HStack(spacing: metrics.keySpacing) {
                    cancelButton
                    pauseResumeButton
                    speakButton(showsHeaderTimer: showsHeaderTimer)
                        .frame(maxWidth: .infinity)
                    enterKey(metrics: metrics, width: enterWidth)
                }
            } else {
                // Idle: Actions (…) on the LEFT, then Dictate (flex) · Enter ·
                // backspace. "…" is leftmost (user request) so the big flexible
                // Dictate pill is the easy central thumb target.
                HStack(spacing: metrics.keySpacing) {
                    actionsButton
                    speakButton(showsHeaderTimer: showsHeaderTimer)
                        .frame(maxWidth: .infinity)
                    enterKey(metrics: metrics, width: enterWidth)
                    backspaceKey(metrics: metrics)
                }
            }
        }
        .frame(minHeight: max(48, metrics.keyHeight))
    }

    /// The shared control cluster used by both the below-428 control row and
    /// the large-width combined row. `showsHeaderTimer` mirrors the
    /// StreamingStrip header's timer: when the header shows the elapsed clock
    /// (large widths), the Stop pill drops its inline timer so exactly one
    /// clock renders per width class.
    @ViewBuilder
    private func controlCluster(showsHeaderTimer: Bool) -> some View {
        if recordingState.isRecording && !isStopRequestPending {
            HStack(spacing: 10) {
                cancelButton
                pauseResumeButton
                speakButton(showsHeaderTimer: showsHeaderTimer)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                speakButton(showsHeaderTimer: showsHeaderTimer)
                    .frame(maxWidth: .infinity)
                actionsButton
            }
        }
    }

    /// Cancel button shown at the LEFT of the control cluster while a
    /// dictation is actively recording (WS-D / §2.6 — trash-can on the left
    /// for reach). Glass background + red `trash` icon. Dark-mode mitigations
    /// (bumped hairline + glass fill opacity) ensure the button reads cleanly
    /// on dark chrome.
    private var cancelButton: some View {
        Button {
            feedback.systemClick()
            feedback.selectionTick()
            onCancelRecording()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.jotRecord)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    // Bumped opacity vs. standard `jotKeyboardGlassHairline`
                    // so the Cancel button has a crisp edge against the
                    // dark recording chrome. Light: 8% black (vs. token's
                    // 4%). Dark: 14% white (vs. token's 6%). Per UX plan.
                    Circle()
                        .strokeBorder(
                            Color(uiColor: UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(white: 1.0, alpha: 0.14)
                                    : UIColor(white: 0.0, alpha: 0.08)
                            }),
                            lineWidth: 0.5
                        )
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel recording")
        .accessibilityHint("Discards what you've said so far")
        .accessibilityAddTraits(.isButton)
    }

    /// WS-C / §10 — Pause / Resume control, shown between trash-Cancel and the
    /// Stop pill while recording. Pause does NOT finalize: it posts
    /// `pauseRequested`, the app gates the slice router (mic stays warm, no
    /// capture) and publishes `.paused`, which flips this control to Resume.
    /// Resume posts `resumeRequested` and capture re-arms against the same
    /// slice so samples concatenate.
    private var pauseResumeButton: some View {
        Button {
            feedback.systemClick()
            feedback.selectionTick()
            if recordingState.isPaused {
                onResumeRecording()
            } else {
                onPauseRecording()
            }
        } label: {
            Image(systemName: recordingState.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color(uiColor: UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(white: 1.0, alpha: 0.14)
                                    : UIColor(white: 0.0, alpha: 0.08)
                            }),
                            lineWidth: 0.5
                        )
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recordingState.isPaused ? "Resume recording" : "Pause recording")
        .accessibilityHint(recordingState.isPaused
                           ? "Resumes capturing audio where it left off"
                           : "Keeps the mic ready but stops capturing until you resume")
        .accessibilityAddTraits(.isButton)
    }

    /// Primary dictation CTA.
    ///
    /// ## Bug A — wizard W7 "Dictate is greyed out / can't be tapped" (2026-05-11)
    ///
    /// Root cause: when the user reaches W7 (TryKeyboardStep) WITHOUT having
    /// actually enabled "Allow Full Access" in W4, the keyboard extension's
    /// inherited `UIInputViewController.hasFullAccess` resolves to `false`.
    /// W4 includes a manual bypass because the main-app process can't read the
    /// keyboard's `hasFullAccess` directly, so a user who taps through W4
    /// without flipping the switch lands on W7 with
    /// no Full Access.
    ///
    /// Pre-fix behavior: this branch (`!hasFullAccess`) used
    /// `Color(uiColor: .secondarySystemFill)` (a flat system grey) for the
    /// pill background and showed "Unlock" + `lock.shield`. The button was
    /// still tappable — it routed to `onOpenFullAccess()` → Settings — but
    /// it visually read as DISABLED. The user reported "greyed out, can't be
    /// tapped" because the visual treatment communicated "disabled" so
    /// strongly that they didn't try.
    ///
    /// Fix: the `!hasFullAccess` pill now uses the same iOS-system-blue
    /// surface as the active Dictate pill, with white ink and a clear
    /// "Enable Full Access" label. The lock.shield icon stays so the user
    /// knows the next step is Settings, not dictation. Tap still routes to
    /// `onOpenFullAccess()` → `extensionContext.open(openSettingsURLString)`
    /// — which deep-links to the app's settings page where the user can
    /// flip "Allow Full Access" on. Visually this reads as "this is the
    /// CTA, tap me", not "I am disabled".
    ///
    /// The `.disabled(...)` modifier below is unchanged — it still only
    /// fires for `hasFullAccess && (inflight || stop-pending)`. So the
    /// no-Full-Access branch was never *actually* disabled in code; it was
    /// only perceived as disabled. We are fixing the perception, not the
    /// gate logic.
    private func speakButton(showsHeaderTimer: Bool) -> some View {
        // No-FA branch is INERT (no Link, no Button) because nothing we
        // tried to launch from a custom keyboard extension actually opens
        // the containing app reliably on iOS 26 — `extensionContext.open`
        // silently no-ops, the responder-chain selector trick is banned
        // by Apple in iOS 18+, and SwiftUI `Link` was inconsistent in
        // testing. Instead, the recents strip area (see `topStrip`'s
        // `fullAccessInstructions` branch) carries the breadcrumb that
        // teaches the user how to enable Full Access manually. Keeping
        // the lock-shield + "Enable Full Access" label here gives them
        // the visual context for WHY the keyboard is in this state.
        Group {
            if hasFullAccess {
                Button {
                    feedback.longPressImpact()
                    onTapToSpeak()
                } label: { speakLabel(showsHeaderTimer: showsHeaderTimer) }
            } else {
                speakLabel(showsHeaderTimer: showsHeaderTimer)
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .disabled(hasFullAccess
                  && (recordingState.isInflightPostRecording
                      || isStopRequestPending))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: recordingState.isRecording)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: recordingState.isInflightPostRecording)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityAddTraits(recordingState.isRecording
                                ? [.isButton, .startsMediaSession]
                                : .isButton)
    }

    @ViewBuilder
    private func speakLabel(showsHeaderTimer: Bool) -> some View {
            Group {
                if hasFullAccess, recordingState.isPaused {
                    // WS-C / §10 paused stop pill: same white stop square (Stop
                    // still commits from paused), a FROZEN timer (the app pins
                    // a frozen elapsed value at pause), and a static (non-
                    // pulsing) hollow dot so the pill reads "paused, not
                    // capturing" rather than live. The header on large widths
                    // carries the "Paused" word; here the frozen clock + static
                    // dot are the cue. When the header already shows the timer
                    // (large widths, R8) the pill DROPS its frozen clock so the
                    // time renders once.
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                        if !showsHeaderTimer {
                            Text(pausedElapsedText)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                            .frame(width: 6, height: 6)
                    }
                } else if hasFullAccess, recordingState.isRecording {
                    let startedAt = recordingState.startedAt ?? Date()
                    TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                        // Spec stop pill: white stop square 12×12pt + timer
                        // + pulsing white dot. The square is a rounded
                        // rectangle (not `stop.fill`) so it matches the
                        // exact 3pt-radius square in the design reference.
                        // When the StreamingStrip header shows the elapsed
                        // clock (large widths, R8), the pill omits its inline
                        // timer so exactly one clock renders.
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            if !showsHeaderTimer {
                                Text(elapsedText(now: context.date))
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            PulsingDot(color: .white)
                        }
                    }
                } else if hasFullAccess, recordingState.isInflightPostRecording {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Working")
                            .font(JotType.chromeBold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: hasFullAccess ? "mic.fill" : "lock.shield")
                            .font(.system(size: 18, weight: .semibold))
                        // Bug A fix: prior copy was "Unlock" — too cryptic.
                        // "Enable Full Access" tells the user exactly what
                        // tapping the pill is going to do.
                        Text(hasFullAccess ? "Jot down" : "Enable Full Access")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            // White ink across all branches per spec.
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            // 42pt visual height per spec; outer min stays ≥44pt for HIG.
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(speakBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                // Inset top highlight on the pill — spec's
                // `rgba(255,255,255,0.4)` top inset.
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(Color.white.opacity(0.40), lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            // Primary drop shadow — heavier when recording (4×14×40%)
            // vs idle (4×12×32%) per spec.
            .shadow(color: speakShadow,
                    radius: recordingState.isRecording ? 14 : 12,
                    x: 0, y: 4)
            // Outer halo on the recording state only — second shadow at
            // a wider radius / lower opacity to match the spec's "4px
            // outer halo rgba(0,122,255,0.10)" treatment.
            .shadow(color: speakOuterHalo, radius: 4, x: 0, y: 0)
    }

    private var actionsButton: some View {
        Button {
            feedback.systemClick()
            feedback.selectionTick()
            // Explicit open/close branch (vs. `.toggle()`). The OPEN edge
            // fires `onActionsTapped` so the controller refreshes paste
            // state from the system clipboard — without this, the Paste
            // row was stuck on whatever clipboard content was present
            // at last `viewWillAppear`.
            if showActionsPopover {
                showActionsPopover = false
            } else {
                onActionsTapped()
                showActionsPopover = true
            }
        } label: {
            // Icon-only "…" (empty title) — the ellipsis glyph alone reads as
            // the overflow/Actions affordance; the accessibilityLabel below
            // still announces "Actions".
            secondaryControlLabel(
                title: "",
                systemImage: "ellipsis",
                enabled: true,
                lit: showActionsPopover
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions")
        .accessibilityHint("Opens Paste, Copy, Undo, Redo, and Move up/down actions")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBannerOverlay: some View {
        if let banner = statusBanner, !banner.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: bannerIsWarning(banner)
                      ? "exclamationmark.triangle.fill"
                      : "xmark.octagon.fill")
                    .imageScale(.small)
                Text(banner)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bannerIsWarning(banner)
                          ? Color.jotWarning
                          : Color.jotRecord)
            )
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel(banner)
            .accessibilityAddTraits(.isStaticText)
            .task(id: banner) {
                guard banner != "Rewriting…" else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                onStatusBannerRendered()
            }
        } else {
            EmptyView()
        }
    }

    private func bannerIsWarning(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timed") || lower.contains("timeout")
    }

    // MARK: - Key rows

    /// Below-428 separate Enter row (R8). The spacebar + punctuation/char-keys
    /// + the minimize/expand chevron were all removed in WS-D — the keyboard
    /// is recording-controls + Apple's system row only, with one adaptive
    /// Enter. The Enter spans the full inner width on its own row so it stays
    /// an easy target; Apple's globe / system row sits below in the iOS
    /// keyboard chrome. The `needsInputModeSwitchKey` /
    /// `onAdvanceToNextInputMode` props are retained on the view in case the
    /// globe is ever re-added; they are currently unused by this row.
    private func bottomRow(metrics: KeyboardMetrics) -> some View {
        enterKey(metrics: metrics, width: nil)
            .frame(height: metrics.keyHeight)
    }

    /// The single adaptive Enter key. Shared by the below-428 `bottomRow`
    /// (full inner width) and the large-width `controlAndEnterRow` (fixed
    /// trailing width). `width == nil` → flex to fill.
    private func enterKey(metrics: KeyboardMetrics, width: CGFloat?) -> some View {
        keyButton(
            width: width,
            metrics: metrics,
            style: .returnAccent,
            accessibilityLabel: returnAccessibilityLabel,
            action: { onKey(.returnKey) }
        ) {
            returnKeyLabel
        }
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    /// Backspace key (idle row, left of Actions). Single tap deletes one
    /// character — the controller's `handleKeyTap(.backspace)` runs
    /// `deleteBackward()`. (Press-and-hold repeat is already wired in the
    /// controller via `onKeyPressChange`; this button fires one delete per tap.)
    private func backspaceKey(metrics: KeyboardMetrics) -> some View {
        keyButton(
            width: max(46, metrics.letterKeyWidth),
            metrics: metrics,
            style: .action,
            accessibilityLabel: "delete",
            action: { onKey(.backspace) }
        ) {
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
        }
    }

    // MARK: - Components

    private func secondaryControlLabel(
        title: String,
        systemImage: String,
        enabled: Bool,
        lit: Bool
    ) -> some View {
        secondaryControlLabel(
            title: title,
            enabled: enabled,
            lit: lit
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        }
    }

    private func secondaryControlLabel<Icon: View>(
        title: String,
        enabled: Bool,
        lit: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        // Liquid Glass shell — same recipe as the recents / streaming
        // cards, just compact. Title ink is `#3a3a45` (jotKeyboardActionsInk)
        // at 14pt 500 weight per spec; icon ink follows the lit state so
        // active controls read iOS-blue when engaged.
        HStack(spacing: 4) {
            icon()
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .foregroundStyle(secondaryForeground(lit: lit))
        .padding(.horizontal, 14)
        // 42pt visual height per spec; outer frame stays ≥44pt for HIG.
        .frame(minWidth: 44, minHeight: 48)
        .background(
            ZStack {
                // Liquid Glass: `.ultraThinMaterial` for the live blur,
                // overlaid with the translucent-white gradient (0.78 →
                // 0.48) so the spec recipe lands without losing the
                // underlying chrome's color.
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotKeyboardGlassFill1,
                                Color.jotKeyboardGlassFill2,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                if lit {
                    // Subtle blue tint on the lit / popover-open state
                    // so the glass surface itself reads
                    // "this is engaged" without flipping to solid coral.
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.jotKeyboardAccent.opacity(0.12))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        // Drop shadow — uniform Liquid Glass recipe shared with the
        // Recents / Streaming / collapse-chevron surfaces.
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
        .opacity(enabled ? 1 : 0.32)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func keyButton<Content: View>(
        width: CGFloat? = nil,
        metrics: KeyboardMetrics,
        style: KeyboardKeyStyle,
        enabled: Bool = true,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            fireFeedback(for: style)
            action()
        } label: {
            content()
                .font(font(for: style))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(
            KeyButtonStyle(
                keyStyle: style,
                cornerRadius: metrics.buttonCornerRadius
            )
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .frame(width: width, height: metrics.keyHeight)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - Styling

    /// v2 retheme: effective color scheme is the OR of the SwiftUI env
    /// and the host-provided `keyboardAppearance`. If either says dark,
    /// we render dark — that way the keyboard adapts to dark hosts
    /// (Spotlight, dark Mail, dark Notes) even when the system itself
    /// is in light mode.
    private var effectiveColorScheme: ColorScheme {
        if keyboardAppearance == .dark { return .dark }
        return systemColorScheme
    }

    /// Chrome background — transparent over the native keyboard backdrop.
    ///
    /// Idle: parent `UIInputView(style: .keyboard)` supplies Apple's
    /// adaptive keyboard tray material.
    ///
    /// Recording: same transparent chrome; the stop pill and streaming text
    /// supply the visual recording cue.
    @ViewBuilder
    private var chromeBackground: some View {
        // Transparent — UIInputView(style: .keyboard) backdrop renders
        // through. No recording-state tint: the stop pill + streaming
        // text card supply the visual recording cue.
        Color.clear
    }

    /// Dictate pill background — STATIC blue gradient (`#007AFF → #0064CC`)
    /// in idle + recording states; dimmed during in-flight. Spec requires
    /// the pill to be the SAME pixel-for-pixel in light + dark (iOS blue
    /// reads well on both gray chromes). Hardcoding `#007AFF` as the top
    /// stop instead of `Color.jotKeyboardAccent` (which adapts to dark
    /// system blue `#0A84FF`) keeps the pill identical across modes. The
    /// recording state's HEAVIER halo is supplied at the `.shadow` call
    /// site, not here (callers compose shadow + halo separately).
    private static let pillTopBlue = Color(red: 0/255, green: 122/255, blue: 255/255)
    private var speakBackground: some ShapeStyle {
        if hasFullAccess, recordingState.isInflightPostRecording {
            return AnyShapeStyle(KeyboardView.pillTopBlue.opacity(0.65))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    KeyboardView.pillTopBlue,
                    Color.jotKeyboardAccentDeep,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Drop shadow color for the dictate pill. Heavier when recording
    /// (spec calls for a 4px×14px halo at 40% opacity + an outer 10%
    /// halo); idle gets a softer 4×12 / 32% halo.
    private var speakShadow: Color {
        if hasFullAccess, recordingState.isRecording {
            return Color.jotKeyboardAccent.opacity(0.40)
        }
        return Color.jotKeyboardAccent.opacity(0.32)
    }

    /// Outer halo radius for the dictate pill — used as a second shadow
    /// in the recording state to match the spec's "4px outer halo
    /// rgba(0,122,255,0.10)" treatment.
    private var speakOuterHalo: Color {
        recordingState.isRecording
            ? Color.jotKeyboardAccent.opacity(0.10)
            : .clear
    }

    private func secondaryBackground(lit: Bool) -> Color {
        lit ? Color.jotKeyboardAccent.opacity(0.18) : Color(uiColor: .secondarySystemFill)
    }

    private func secondaryForeground(lit: Bool) -> Color {
        lit ? Color.jotKeyboardAccent : Color.jotKeyboardActionsInk
    }

    private var micAccessibilityLabel: String {
        guard hasFullAccess else { return "Enable Full Access" }
        return recordingState.isRecording ? "Stop recording" : "Jot down"
    }

    private var micAccessibilityHint: String {
        guard hasFullAccess else { return "Opens the Jot settings page" }
        return recordingState.isRecording
            ? "Requests Jot to stop the active recording"
            : "Opens Jot and starts dictation"
    }

    private func elapsedText(now: Date) -> String {
        guard let startedAt = recordingState.startedAt else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Frozen MM:SS shown on the Stop pill while paused (§10.4). Uses the
    /// pause-time snapshot the app published (active-time total, pause gaps
    /// excluded) rather than live wall-clock, so the clock holds still.
    private var pausedElapsedText: String {
        let total = max(0, Int((recordingState.pausedElapsedSeconds ?? 0).rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Adaptive Enter label (WS-D): Apple's return-arrow glyph for plain
    /// fields, the magnifier glyph for search fields (design decision D3),
    /// and a word for every other semantic case — mirroring the system
    /// keyboard. `returnKeyType` is read from the host field's
    /// `textDocumentProxy` and threaded in by the controller.
    private enum ReturnLabel {
        case glyph(String, a11y: String)
        case word(String)
    }

    private var returnLabel: ReturnLabel {
        switch returnKeyType {
        case .default:                 return .glyph("arrow.turn.down.left", a11y: "return")
        case .go:                      return .word("Go")
        case .google, .search, .yahoo: return .glyph("magnifyingglass", a11y: "search")
        case .join:                    return .word("Join")
        case .next:                    return .word("Next")
        case .route:                   return .word("Route")
        case .send:                    return .word("Send")
        case .done:                    return .word("Done")
        case .emergencyCall:           return .word("Emergency")
        case .continue:                return .word("Continue")
        @unknown default:              return .glyph("arrow.turn.down.left", a11y: "return")
        }
    }

    private var returnAccessibilityLabel: String {
        switch returnLabel {
        case .glyph(_, let a11y): return a11y
        case .word(let text):     return text.lowercased()
        }
    }

    @ViewBuilder private var returnKeyLabel: some View {
        switch returnLabel {
        case .glyph(let name, _):
            Image(systemName: name)
        case .word(let text):
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
    }

    private func font(for style: KeyboardKeyStyle) -> Font {
        switch style {
        case .primary:
            return .system(size: 14, weight: .regular, design: .default)
        case .action:
            return .system(size: 15, weight: .regular, design: .default)
        case .returnAccent:
            return .system(size: 15, weight: .semibold, design: .default)
        }
    }

    private func fireFeedback(for style: KeyboardKeyStyle) {
        switch style {
        case .primary:
            feedback.inputClick()
        case .action, .returnAccent:
            feedback.systemClick()
        }
        feedback.selectionTick()
    }
}

private struct KeyButtonStyle: ButtonStyle {
    let keyStyle: KeyboardKeyStyle
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(
                background(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            // v2 retheme: drop the hard 28%-black 1pt shadow in light mode.
            // The new key faces are translucent over a known gray chrome —
            // a heavy under-shadow muddied the gray edge. Light mode keeps
            // a much softer 8% hint; dark stays shadowless (the chrome is
            // already dark).
            .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.08),
                    radius: 0, x: 0, y: 1)
    }

    private var foreground: Color {
        switch keyStyle {
        case .primary:
            // Space-bar label — softer than punctuation ink. The space
            // glyph reads as a hint, not a primary character.
            return Color.jotKeyboardSpaceLabel
        case .action:
            // Backspace symbol (delete.left). Adaptive: dark-chrome dark
            // mode needs near-white ink; light mode keeps deep charcoal.
            return Color.jotKeyboardKeyInk
        case .returnAccent:
            // Return key — adaptive ink. Light mode: deep charcoal on
            // soft blue. Dark mode: white on neutral gray.
            return Color.jotKeyboardReturnInk
        }
    }

    private func background(pressed: Bool) -> Color {
        switch keyStyle {
        case .primary:
            // Space + util key. v2 hand-rolled adaptive fill (white
            // light / translucent gray dark). Pressed state nudges
            // toward the backspace fill for the same "key flips to
            // the other tone on press" feedback iOS uses natively.
            return pressed ? Color.jotKeyboardBackspaceFill : Color.jotKeyboardKeyFill
        case .action:
            // Backspace — flips toward the lighter key fill on press
            // to match iOS-native press-inversion behavior.
            return pressed ? Color.jotKeyboardKeyFill : Color.jotKeyboardBackspaceFill
        case .returnAccent:
            // Return — soft blue-tinted in light, neutral gray-tinted
            // in dark. Pressed state darkens via 0.7 opacity so the
            // user still reads "I pressed it" without flipping to a
            // competing primary-blue (the Dictate pill owns that).
            return pressed
                ? Color.jotKeyboardReturnFill.opacity(0.7)
                : Color.jotKeyboardReturnFill
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (isLit ? 1 : 0.32))
            .onAppear {
                guard !reduceMotion else { return }
                isLit = true
            }
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isLit
            )
    }
}
