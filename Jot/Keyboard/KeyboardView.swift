import SwiftUI
import UIKit
import OSLog

// [KB-COLLAPSE-DEBUG] File-scope logger used only by the diagnostic
// instrumentation in `collapseToggle`'s tap handler. Same subsystem /
// category as the controller's `keyboardLog` so Console.app filters
// see both streams together.
private let kbCollapseLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot.Keyboard",
    category: "keyboard"
)

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

    /// Phase 2.5 — when true, the keyboard renders the 58pt
    /// `CollapsedBarView` instead of the standard mode body. Driven by
    /// the controller's persisted `jot.keyboard.collapsed` flag.
    let isCollapsed: Bool

    /// v2 retheme (2026-05-11) — host's `keyboardAppearance` hint
    /// (`UIKeyboardAppearance.default` / `.light` / `.dark`). Some
    /// hosts force `.dark` even when the system is in light mode; this
    /// signal is OR-ed with the SwiftUI `colorScheme` env to determine
    /// the effective scheme. Passed from the controller in
    /// `JotKeyboardViewController.makeKeyboardView` via
    /// `textDocumentProxy.keyboardAppearance`.
    let keyboardAppearance: UIKeyboardAppearance

    let onCopy: () -> Void
    let onPaste: () -> Void
    let onCopyLastDictation: () -> Void
    let onUndoLastInsertion: () -> Void
    let onRedoInsertion: () -> Void
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

    /// Phase 2.5 — fired by the small chevron-down button in the
    /// standard-mode chrome (and by the collapsed bar's chevron-up).
    /// The controller flips `isCollapsed`, persists it, and mutates the
    /// host view's height constraint.
    let onToggleCollapsed: () -> Void

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

    private let punctuationKeys: [KeyboardKeyDescriptor] = [
        .literal("@"),
        .literal("."),
        .literal(","),
        .literal("?"),
        .literal("!"),
        .literal("'"),
        .backspace,
    ]

    var body: some View {
        ZStack {
            if isCollapsed {
                CollapsedBarView(
                    hasFullAccess: hasFullAccess,
                    recordingState: recordingState,
                    isStopRequestPending: isStopRequestPending,
                    keyboardAppearance: keyboardAppearance,
                    onTapToSpeak: onTapToSpeak,
                    onOpenFullAccess: onOpenFullAccess,
                    onToggleCollapsed: onToggleCollapsed,
                    feedback: feedback
                )
                .transition(.opacity)
            } else {
                standardModeBody
                    .transition(.opacity)
            }
        }
        // v2 retheme: force the SwiftUI color-scheme env to the resolved
        // effective scheme so every adaptive `Color(uiColor: UIColor { ... })`
        // token below — chrome stops, glass fills, key faces — resolves
        // against the same source of truth. If the host says dark
        // (keyboardAppearance == .dark) but the system is in light, we
        // still want dark tokens; .environment(...) accomplishes that.
        .environment(\.colorScheme, effectiveColorScheme)
        // The internal content cross-fade — UIKit owns the height
        // transition (an explicit NSLayoutConstraint on
        // `JotKeyboardViewController.view.heightAnchor`); SwiftUI only
        // animates the branch swap. We deliberately do NOT animate the
        // outer envelope here because `UIHostingController` on iOS 17+
        // mis-handles `withAnimation` on height-affecting state
        // (forum 776712).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                   value: isCollapsed)
        // Lower bound only — collapsed mode pins to 58pt; standard mode
        // matches the UIKit host height pin (310pt expanded, 58pt
        // collapsed — see `JotKeyboardViewController.expandedHeight` /
        // `collapsedHeight`) so SwiftUI and UIKit agree on the envelope.
        // The UIKit `heightConstraint` pins the host view regardless,
        // but SwiftUI's intrinsic-size machinery would otherwise emit
        // "Unable to simultaneously satisfy constraints" console spam.
        .frame(minHeight: isCollapsed ? CollapsedBarView.height : 310)
    }

    /// Standard-mode body — extracted so the top-level `body` can
    /// branch cleanly between collapsed and standard surfaces.
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
                    topStrip
                    actionAndMicRow
                    if !recordingState.isRecording {
                        punctuationRow(metrics: metrics)
                    }
                    bottomRow(metrics: metrics)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, metrics.sideInset)
                .padding(.vertical, 4)
                // Transparent chrome lets the native keyboard backdrop render
                // through in both idle and recording.
                .background(chromeBackground)
                .overlay(alignment: .top) {
                    statusBannerOverlay
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, 4)
                }

                if showActionsPopover {
                    // Dim catcher behind the popover so a tap outside dismisses.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showActionsPopover = false }
                        .accessibilityHidden(true)

                    ActionsPopover(
                        hasPasteboardContent: hasPasteboardContent,
                        hasLastDictation: !historyEntries.isEmpty,
                        canUndo: canUndoLastInsertion,
                        canRedo: canRedoInsertion,
                        onPaste: onPaste,
                        onCopyLast: onCopyLastDictation,
                        onUndo: onUndoLastInsertion,
                        onRedo: onRedoInsertion,
                        onDismiss: { showActionsPopover = false }
                    )
                    .padding(.trailing, 8)
                    // Position above the bottom row (~bottomRow height +
                    // action row height + spacing). 110pt clears the
                    // bottom row + the actions trigger without overlapping.
                    .padding(.bottom, 110)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.95, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                    )
                    .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                       value: showActionsPopover)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                       value: recordingState.isRecording)
        }
    }

    // MARK: - Top strip (recents / streaming)

    /// Idle vs streaming branch. In landscape (compact vertical size class)
    /// we still render the strip but at a smaller height — the keyboard
    /// envelope itself shrinks, but losing the strip would break the
    /// just-now feedback loop after auto-paste.
    @ViewBuilder
    private var topStrip: some View {
        if recordingState.isRecording {
            StreamingStrip(
                partialText: recordingState.streamingPartialText,
                startedAt: recordingState.startedAt
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

    /// Primary controls row — Minimize, Dictate (or red stop pill),
    /// and Actions popover trigger.
    ///
    /// Phase 2.5 added the leading `collapseToggle` so the user can
    /// minimize the keyboard into the 58pt low-profile bar. The
    /// chevron lives here (and not in the bottomRow) so the bottomRow
    /// stays a pure alpha-key surface — globe + space + return — and
    /// the chrome controls cluster together.
    private var actionAndMicRow: some View {
        HStack(spacing: 10) {
            collapseToggle
            speakButton
                .frame(maxWidth: .infinity)
            actionsButton
        }
        // Bug 8 (2026-05-11): action row trimmed from 52 → 48pt — pairs
        // with the dictate button's matching `minHeight: 48` change so
        // the row fits the tighter ~310pt envelope without clipping.
        .frame(minHeight: 48)
    }

    private var collapseToggle: some View {
        Button {
            // [KB-COLLAPSE-DEBUG] Tap-moment marker for Symptom 2 (partial
            // minimize — inner view collapses but outer envelope stays
            // expanded). Pair with the toggleCollapsed entry log in
            // JotKeyboardViewController to confirm the tap reached UIKit.
            kbCollapseLog.log("[KB-COLLAPSE-DEBUG] tap MINIMIZE")
            feedback.systemClick()
            feedback.selectionTick()
            onToggleCollapsed()
        } label: {
            secondaryControlLabel(
                title: "Minimize",
                systemImage: "chevron.compact.down",
                enabled: true,
                lit: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize keyboard")
        .accessibilityHint("Minimizes the Jot keyboard to a compact bar")
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
    private var speakButton: some View {
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
                } label: { speakLabel }
            } else {
                speakLabel
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
    private var speakLabel: some View {
            Group {
                if hasFullAccess, recordingState.isRecording {
                    let startedAt = recordingState.startedAt ?? Date()
                    TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                        // Spec stop pill: white stop square 12×12pt + timer
                        // + pulsing white dot. The square is a rounded
                        // rectangle (not `stop.fill`) so it matches the
                        // exact 3pt-radius square in the design reference.
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Text(elapsedText(now: context.date))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
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
                        Text(hasFullAccess ? "Dictate" : "Enable Full Access")
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
            showActionsPopover.toggle()
        } label: {
            secondaryControlLabel(
                title: "Actions",
                systemImage: "ellipsis",
                enabled: true,
                lit: showActionsPopover
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions")
        .accessibilityHint("Opens Paste, Copy last, Undo, and Redo actions")
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

    private func punctuationRow(metrics: KeyboardMetrics) -> some View {
        let keyWidth = max(
            32,
            (metrics.innerWidth - metrics.keySpacing * CGFloat(punctuationKeys.count - 1))
                / CGFloat(punctuationKeys.count)
        )

        return HStack(spacing: metrics.keySpacing) {
            ForEach(Array(punctuationKeys.enumerated()), id: \.offset) { _, key in
                KeyboardKey(
                    descriptor: key,
                    width: keyWidth,
                    height: metrics.keyHeight,
                    cornerRadius: metrics.buttonCornerRadius,
                    feedback: feedback,
                    onTap: onKey,
                    onPressChanged: onKeyPressChange
                )
            }
        }
    }

    private func bottomRow(metrics: KeyboardMetrics) -> some View {
        // Bug 11 (2026-05-11): globe key removed. User confirmed they
        // rely on the system globe (in iOS keyboard chrome below) to
        // switch input modes; the duplicate inside our keyboard was
        // wasted real-estate. HIG 4.4.1 deviation is documented in
        // ux-overhaul-plan §4.1; risk accepted (also §14.2). The
        // `needsInputModeSwitchKey` / `onAdvanceToNextInputMode` props
        // are retained on the view in case we ever need to re-add the
        // globe in a follow-up; they are currently unused by this row.
        let returnWidth = max(78, metrics.letterKeyWidth * 2.2)

        return HStack(spacing: metrics.keySpacing) {
            keyButton(
                metrics: metrics,
                style: .primary,
                accessibilityLabel: "space",
                action: { onKey(.space) }
            ) {
                Text("space")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            keyButton(
                width: returnWidth,
                metrics: metrics,
                style: .returnAccent,
                accessibilityLabel: returnTitle.lowercased(),
                action: { onKey(.returnKey) }
            ) {
                Text(returnTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .frame(height: metrics.keyHeight)
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
        return recordingState.isRecording ? "Stop recording" : "Tap to dictate"
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

    private var returnTitle: String {
        switch returnKeyType {
        case .default:        return "Return"
        case .go:             return "Go"
        case .google:         return "Search"
        case .join:           return "Join"
        case .next:           return "Next"
        case .route:          return "Route"
        case .search:         return "Search"
        case .send:           return "Send"
        case .yahoo:          return "Search"
        case .done:           return "Done"
        case .emergencyCall:  return "Emergency"
        case .continue:       return "Continue"
        @unknown default:     return "Return"
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
