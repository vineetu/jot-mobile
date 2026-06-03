//
//  RecordingHeroView.swift
//  Jot
//
//  Phase 3 of the UX overhaul — full-screen recording hero surface.
//  See: Jot/tmp/ux-overhaul-plan.md §5.2 (Mockup 08) +
//       docs/plans/ux-overhaul-round2.md WS-C (§2a two-path, §10 Pause/Resume).
//
//  Reached two ways:
//  - **Manual entry** via the Dictate FAB on the editorial home: this view
//    auto-starts a recording on appear and runs the same stop-and-transcribe
//    pipeline as the prior in-app recorder.
//  - **Auto-nav entry** from `ContentView` when the URL-scheme handler
//    (`jot://dictate?session=…` from the keyboard) has already kicked
//    `RecordingService.start()` before this view exists. `ContentView`
//    observes `recordingService.isRecording` / `isPipelineInFlight` and
//    programmatically pushes the hero so the home surface never shows
//    no-indication while a recording is hot. In that case
//    `beginRecordingFlow` ADOPTS the in-flight session (no second `start()`,
//    no start haptic) — the timer reads `recordingService.currentRecordingStartedAt`
//    directly, the same observable the keyboard's strip-timer renders from.
//
//  On stop or cancel, pops back to the home stack.
//
//  ## §2a — two entry paths, two streaming behaviors (round-2 WS-C)
//
//  Recording (audio capture) starts immediately in BOTH paths — only the
//  *display* of the live stream differs:
//   - **App-Dictate** (`.startRecording` / `.adoptInFlight`): the user chose to
//     be here, so the live stream shows immediately (full WS-A treatment).
//   - **Cold-start keyboard** (`.coldStartFromExternalKeyboard`): Apple forces
//     the app to foreground to record; this surface's job is to send the user
//     BACK to their app, not to keep them watching a stream. So we WITHHOLD the
//     live stream (and suppress the "Listening…/Loading…" placeholder) and show
//     swipe-back coaching instead. The stream reveals on
//     `max(coaching beat, first real partial token)` — gated on real text so the
//     pane is never empty — then fades transparent → translucent. A recording
//     indicator (red dot + timer) stays visible the whole withhold window so
//     "Jot keeps listening" has on-screen proof.
//
//  ## §10 — Pause / Resume (round-2 WS-C)
//
//  A Pause/Resume control sits next to Stop/Cancel. Pause does NOT finalize —
//  `recordingService.pauseRecording()` keeps the engine + mic warm (Option A)
//  and gates the slice router; `resumeRecording()` concatenates onto the same
//  capture. The elapsed timer freezes (the service back-dates
//  `currentRecordingStartedAt` to the active-time total). The paused UI reads
//  "Paused · mic ready, not capturing".
//
//  ## Why `showRecordingHero` is a `@Binding`, not `@Environment(\.dismiss)`
//
//  `@Environment(\.dismiss)` is documented for *modal* dismissal. When this
//  view is pushed onto a `NavigationStack` via
//  `.navigationDestination(isPresented:)`, the destination's lifecycle is
//  driven entirely by that binding — `dismiss()` from a nested view doesn't
//  reliably pop it. On every exit path (stop success, cancel, error,
//  stale-mount auto-pop) we flip `showRecordingHero = false` ourselves;
//  `dismiss()` is kept only as belt-and-suspenders for legacy modal contexts.
//
//  ## `HeroIntent` and the stale-presentation pop
//
//  The view supports two lifecycles, picked by the caller via the `intent`
//  parameter:
//   - `.startRecording` (FAB): no recording is expected to be running.
//     Call `recordingService.start()`; on race (somehow already running),
//     adopt.
//   - `.adoptInFlight` (URL-bounce auto-nav, scene re-activation,
//     ContentView.onAppear with a hot mic): a recording is expected to be
//     running. Adopt it. If nothing is in flight, the presentation is
//     STALE (e.g. user backgrounded mid-recording, Live Activity stopped
//     the recording, app re-entered with `showRecordingHero == true`
//     leftover) — pop back to home immediately instead of calling
//     `start()`. Calling `start()` on the stale path would silently
//     create a recording the user never asked for.
//
//  ## Backend invariants
//  Nothing in this file mutates services beyond the documented control surface
//  (`start()`, `forceStop()`, `pauseRecording()`, `resumeRecording()`).
//  `DictationActivityCoordinator`, `DictationPipeline.completeEndOfRecording`,
//  and `StreamingPartial` are read/called exactly as `ContentView` already does.
//  The cancel-X uses `forceStop()` — which already discards captured samples
//  without invoking the publish pipeline — so no new "discard" entry point is
//  needed on `RecordingService`.
//

import SwiftUI
import UIKit
import os.log

private let recordingHeroLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "recording-hero"
)

/// Internal phase machine, scoped to this view. Mirrors the `RecordingPhase`
/// in `ContentView` but kept local because the hero surface drives the
/// auto-start / auto-pop lifecycle, which the home surface does not.
private enum HeroPhase: Equatable {
    case starting        // pre-`start()` race window
    case preparing       // cold-start hero shown; the recording is deferred behind a cold model load and hasn't begun yet
    case recording
    case transcribing
    case finished        // pipeline complete, ready to dismiss
    case cancelled       // user cancelled, ready to dismiss
}

struct RecordingHeroView: View {
    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @Environment(StreamingTranscriptionService.self) private var streamingService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Owned by the parent (`ContentView`). Flipping this to `false` is what
    /// actually pops the nav destination; `dismiss()` alone is unreliable
    /// for `.navigationDestination(isPresented:)`. See the file docblock.
    @Binding var showRecordingHero: Bool
    /// What this presentation is for — fresh FAB tap vs. adoption of an
    /// already-running session. Set by the caller before flipping the
    /// `showRecordingHero` binding; consumed once on `.onAppear` via
    /// `beginRecordingFlow`.
    let intent: HeroIntent

    @State private var phase: HeroPhase = .starting
    // Anchor for the elapsed-time display is sourced from
    // `recordingService.currentRecordingStartedAt` — the same observable the
    // keyboard's strip timer reads. A local snapshot here would go stale
    // across warm-hold/warm-resume cycles while the view stayed mounted,
    // making the hero show a longer elapsed than the keyboard. The service
    // back-dates this anchor across pause (§10.4), so reading
    // `Date().timeIntervalSince(started)` naturally freezes while paused.
    @State private var elapsed: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var stopTask: Task<Void, Never>?
    @State private var pauseTask: Task<Void, Never>?
    /// Timeout while in `.preparing` — pops the hero if the model-load-deferred
    /// recording never starts within the launch window.
    @State private var preparingTask: Task<Void, Never>?
    @State private var errorMessage: String?
    /// Latched by the swipe-back / `backTapped()` path so the `.onDisappear` safety-net cancel
    /// doesn't fire when the user is INTENTIONALLY backgrounding the hero
    /// (recording must keep running). `cancelTapped()` and `stopTapped()`
    /// have already cleaned up by the time the view disappears via those
    /// paths, so they don't need the latch. Default `false` so the safety
    /// net stays armed for system-back gestures, scene transitions, etc.
    @State private var dismissingViaBack: Bool = false

    /// §2a — gates whether the live stream is shown. App-Dictate paths reveal
    /// immediately (`true` at appear); the cold-start keyboard path withholds
    /// (`false`) until `max(coaching beat, first real partial token)` and then
    /// fades the stream in (transparent → translucent). Once `true`, stays
    /// `true` for the rest of the session.
    @State private var streamRevealed: Bool = false
    /// True once the coaching-window beat has elapsed (cold-start path only).
    /// The stream reveal needs BOTH this AND a real partial token, so the pane
    /// is never empty (round-2 §2a review fix).
    @State private var coachingBeatElapsed: Bool = false
    /// Drives the cold-start stream reveal task so we can cancel it on teardown.
    @State private var revealTask: Task<Void, Never>?

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var cancelHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @State private var pauseHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var successHaptic = UINotificationFeedbackGenerator()

    // Programmatic VoiceOver focus: when the hero is auto-pushed from the
    // URL-bounce path, default focus would land on the back chevron (the
    // first focusable element). Per HIG, focus should land on the most
    // meaningful starting element — the recording status (red dot + timer).
    @AccessibilityFocusState private var recordingStatusFocused: Bool

    /// True while the cold-start swipe-back coaching overlay is visible.
    /// Driven by `.onAppear` (when `intent == .coldStartFromExternalKeyboard`
    /// AND show count is below the suppression limit). Auto-cleared by a timer
    /// (≥ the coaching animation length) or by user tap on the overlay itself.
    @State private var showColdStartNudge: Bool = false

    /// True on the cold-start keyboard path (`.coldStartFromExternalKeyboard`).
    /// Cached at body level so the stream-withhold + coaching branches read a
    /// single source.
    private var isColdStartPath: Bool {
        if case .coldStartFromExternalKeyboard = intent { return true }
        return false
    }

    /// §9 hero top-space "story" messages (sequenced H1→H4). H5 is the pinned
    /// stream-arrival caption (rendered separately once the stream reveals, not
    /// folded into rotation so it's actually seen).
    // NOTE: the "head back — swipe right along the bottom" line lives in the
    // dedicated `ColdStartNudgeOverlay` (shown first, at the bottom). It is
    // intentionally NOT repeated here, so once the nudge dismisses these rotate
    // through fresh value props rather than echoing what the user just read.
    private static let heroTopMessages: [String] = [
        "Recording stays on while you go. Your words land back in that field.",
        "You don't have to watch this — looking away helps you find the words.",
        "The thinking happens out loud, not on the screen."
    ]
    /// §9 H5 — pinned caption shown above the stream once it arrives.
    private static let heroStreamCaption =
        "A sharper transcriber takes a second pass when you stop and tidies the live text."

    var body: some View {
        ZStack {
            WallpaperBackground(tintOverlay: WallpaperBackground.recordingTint())

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                // §2a — the freed top space (waveform removed in round-2)
                // carries the rotating micro-messages on the cold-start path
                // while the stream is withheld. Once the stream reveals (or on
                // the App-Dictate path), the stream itself owns the space.
                heroContentArea
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)

                Spacer(minLength: 24)

                bottomControls
                    .padding(.bottom, 36)
            }

            if showColdStartNudge {
                ColdStartNudgeOverlay(
                    reduceMotion: reduceMotion,
                    onTap: { showColdStartNudge = false }
                )
                .padding(.horizontal, 24)
                // Anchored to the BOTTOM, just above the recording controls —
                // the coaching is about "swipe right along the bottom," so the
                // affordance belongs where the gesture happens. Shown first on
                // cold open; the top message space stays empty until it dismisses
                // (see `withheldTopSpace`) so the two never overlap.
                .padding(.bottom, 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showColdStartNudge)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // See TranscriptDetailView for rationale — re-apply AFTER hiding
        // chrome so the swipe-back gesture isn't disabled by iOS.
        .enableInteractivePopGesture()
        .onAppear {
            startHaptic.prepare()
            stopHaptic.prepare()
            cancelHaptic.prepare()
            pauseHaptic.prepare()
            successHaptic.prepare()
            beginRecordingFlow()
            maybeShowColdStartNudge()
            configureStreamReveal()
            beginTimerLoop()
            // Move VoiceOver focus to the live transcript card instead of
            // the default first-focusable back chevron, so an auto-pushed hero
            // immediately announces the active recording.
            recordingStatusFocused = true
        }
        .onDisappear {
            timerTask?.cancel()
            revealTask?.cancel()
            preparingTask?.cancel()
            // Intentional backgrounding via the visible back chevron calls
            // `backTapped()`, which sets `dismissingViaBack = true` before
            // this fires; keep the recording running and bail out before the
            // safety-net cancel.
            // (`cancelTapped` and `stopTapped` already cleaned up state
            // themselves and don't need this guard.)
            guard !dismissingViaBack else { return }
            // The iOS swipe-back gesture (`.enableInteractivePopGesture()`)
            // still backgrounds the hero through this safety net. When we
            // disappear while the recording is still alive and the user did
            // NOT explicitly cancel/stop, treat the pop as a backgrounding
            // intent rather than a cancel: hold the recording and latch the
            // flag so the home surface's return-pill flow takes over (the pill
            // shows for any live recording).
            if (phase == .recording || phase == .starting)
                && recordingService.isRecording {
                dismissingViaBack = true
                return
            }
            // Cold-start "Getting ready…" backgrounded before the mic actually
            // started (`.preparing`): the recording is about to begin but
            // `isRecording` is still false, so the branch above doesn't catch it.
            // Arm the same backgrounding latch anyway — when `isRecording` flips,
            // the home return-pill / live-preview adopts it instead of stranding
            // an invisible recording. (Source-based presentation removed the old
            // `isRecording`-adoption that used to self-heal this.)
            if phase == .preparing {
                dismissingViaBack = true
                return
            }
            // Defensive: if we somehow disappear mid-flight but the mic
            // is no longer live (race with external shutdown), reset
            // streaming state so the next hero starts blank.
            if phase == .recording || phase == .starting {
                streamingPartial.reset()
            }
        }
        // Catch the "user backgrounded mid-recording, recording was
        // terminated externally (Live Activity stop, system kill), user
        // returns" case. On `.active`, if we're presented but nothing is
        // running anywhere in the pipeline, pop back to home rather than
        // sitting on a hero with a Stop button that throws.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if showRecordingHero
                && !recordingService.isRecording
                && !recordingService.isPipelineInFlight
                && phase != .transcribing
                && phase != .finished
                && phase != .preparing
            {
                showRecordingHero = false
            }
        }
        .onChange(of: recordingService.isRecording) { _, isRecording in
            // Cold-start "getting ready" → live: the deferred recording (the
            // model finished loading) has begun, so adopt it.
            if phase == .preparing, isRecording {
                adoptInFlightRecording()
            }
        }
        // §2a — reveal the cold-start stream the instant the first real
        // partial token arrives AND the coaching beat has elapsed. Cheap:
        // streamingText only changes on a partial, and the guard short-circuits
        // once `streamRevealed` is true.
        .onChange(of: streamingPartial.streamingText) { _, newText in
            guard isColdStartPath, !streamRevealed, coachingBeatElapsed else { return }
            if !newText.isEmpty {
                revealStream()
            }
        }
        .alert(
            "Recording error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {
                errorMessage = nil
                // Flip the binding (pops the nav destination) and call
                // `dismiss()` as a fallback for any modal-context callers.
                showRecordingHero = false
                dismiss()
            }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Top bar

    private var backButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
                .frame(width: 36, height: 36)
                // Shared design-language chrome treatment (light glass / dark grey).
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to Recents. Recording continues in the background.")
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            backButton

            Spacer(minLength: 0)

            // Top center stays EMPTY during active recording / paused — the Stop
            // pill (dot + timer) and the paused caption already convey state, so
            // a "Recording" label here is redundant double-info (user feedback).
            // The ONLY thing shown here is the cold-start "Getting ready…" load
            // cue, since nothing else on screen says the model is still warming.
            if phase == .preparing {
                recordingIndicator
            }

            Spacer(minLength: 0)

            // Cancel moved OUT of the top bar to the bottom control row as a
            // circular trash button (see `cancelButton`), so the three
            // recording controls (Pause · Stop · Cancel) read as one set.
            // A zero-size spacer balances the two `Spacer`s so the cold-start
            // "Getting ready…" indicator stays centered (matching the back
            // chevron's leading inset) instead of drifting right.
            Color.clear
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
    }

    /// Compact red-dot + MM:SS indicator. Hollows + says nothing extra while
    /// paused beyond the static dot — the "Paused · mic ready, not capturing"
    /// copy lives in the content area / control. The dot pulses while actively
    /// recording, goes static (hollow) while paused.
    private var recordingIndicator: some View {
        let paused = recordingService.isPaused
        return HStack(spacing: 7) {
            Circle()
                .fill(paused ? Color.clear : Color.jotRecordingDot)
                .overlay {
                    Circle().strokeBorder(Color.jotRecordingDot, lineWidth: paused ? 1.5 : 0)
                }
                .frame(width: 9, height: 9)
                .opacity(paused ? 1 : (reduceMotion ? 1 : 0.9))

            // Status word, not a clock: the elapsed time already lives in the
            // Stop pill, so a second timer here was pure duplication. The dot +
            // word is the recording-status indicator §2.2 calls for.
            Text(phase == .preparing ? "Getting ready…" : (paused ? "Paused" : "Recording"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(phase == .preparing || paused ? Color.jotPageInkSecondary : Color.jotPageInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Paused. \(timeString) recorded." : "Recording. \(timeString).")
    }

    // MARK: - Hero content area (stream OR withheld-coaching top space)

    /// Vertical-line cap for the streaming text block before scrolling kicks in.
    /// Round-2 WS-A: ~3.5 lines of serif italic at ~28pt computed line height
    /// (down from ~14). Above this the block freezes at this height and scrolls
    /// internally with a top fade; below it the block grows naturally.
    // For now: effectively uncapped so the live text fills the WHOLE panel
    // (user request). It bottom-aligns and the card's `.clipShape` contains any
    // overflow at the top; the proper capped/faded scroll treatment is deferred.
    private static let streamingMaxBlockHeight: CGFloat = 150

    @ViewBuilder
    private var heroContentArea: some View {
        // §2a — on the cold-start path, while the stream is withheld, the freed
        // top space carries the sequenced rotating micro-messages and the live
        // stream + placeholder are fully suppressed (the recording indicator in
        // the top bar carries the "still listening" proof). Once revealed (or
        // on the App-Dictate path), the stream owns the space.
        if isColdStartPath && !streamRevealed {
            withheldTopSpace
        } else {
            streamingCard
        }
    }

    /// Cold-start withhold window: sequenced rotating micro-messages (H1→H4)
    /// occupying the freed top space, plus a soft instructional anchor. No live
    /// stream, no "Listening…/Loading…" placeholder.
    private var withheldTopSpace: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Held back while the bottom swipe-nudge is showing, so the two never
            // collide on cold open. The rotator mounts only once the nudge has
            // dismissed — it then starts fresh from the first message and fades in.
            if !showColdStartNudge {
                RotatingMessageView(
                    messages: Self.heroTopMessages,
                    dwell: 5,
                    sequenced: true,
                    font: JotType.displaySerif(22),
                    color: .jotPageInk,
                    alignment: .leading
                )
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: showColdStartNudge)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var streamingCard: some View {
        let text = streamingPartial.streamingText
        let isLoadingModel = streamingService.sessionLoadState == .loading
        VStack(alignment: .leading, spacing: 0) {
            // H5 — pinned stream-arrival caption (round-2 §9). Shown above the
            // live text once the stream has revealed via the cold-start path so
            // the "second pass tidies it up" promise is actually seen. Hidden on
            // the App-Dictate path (no coaching story) to keep that surface clean.
            if isColdStartPath {
                Text(Self.heroStreamCaption)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            Group {
                if text.isEmpty {
                    if isLoadingModel {
                        loadingPlaceholder
                    } else {
                        Text("Listening…")
                            .font(.system(size: 26, weight: .regular, design: .serif).italic())
                            .lineSpacing(8.3)
                            .tracking(-0.4)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                } else {
                    StreamingDictationText(
                        text: text,
                        maxBlockHeight: Self.streamingMaxBlockHeight,
                        reduceMotion: reduceMotion
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        // Live text + caption hug the BOTTOM of the panel (user request) — the
        // block sizes to content (StreamingDictationText self-caps + scrolls at
        // `streamingMaxBlockHeight`) and bottom-aligns inside the full-height card.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.jotPageInk.opacity(0.30), radius: 20, x: 0, y: 14)
        // §2a — when this card arrives via the cold-start reveal, fade it in
        // from transparent → translucent (rising out of the background, never
        // snapping on). On the App-Dictate path `streamRevealed` is already
        // true at appear, so this is a no-op (opacity 1, no transition fired).
        .opacity(streamRevealed || !isColdStartPath ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            text.isEmpty
                ? (isLoadingModel
                    ? "Recording in progress. Loading \(SpeechModelVariant.current().displayName)."
                    : "Recording in progress. Listening.")
                : "Recording in progress. \(text)"
        )
        .accessibilityFocused($recordingStatusFocused)
    }

    /// "Loading [variant]…" placeholder rendered in the streaming card
    /// while `streamingService.sessionLoadState == .loading` — i.e. the
    /// per-session ANE load of the streaming graph is in flight. Once
    /// the model lands and either the first partial arrives or
    /// `sessionLoadState` flips to `.ready`, this gives way to the
    /// usual "Listening…" / live transcript pair.
    ///
    /// Visual contract: identical typography to the "Listening…"
    /// placeholder (26pt serif italic, `jotPageInkSecondary`) so the
    /// swap reads as a copy change rather than a layout shift.
    @ViewBuilder
    private var loadingPlaceholder: some View {
        LoadingPlaceholderText(variantName: SpeechModelVariant.current().displayName,
                               reduceMotion: reduceMotion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    // MARK: - Bottom controls

    /// Pause/Resume + Stop + Cancel control set (round-2 WS-C §10.8). Cancel is
    /// the circular RED trash button at the trailing end of this row (it replaced
    /// the old top-bar "Cancel" label). When paused, a "Paused · mic ready, not
    /// capturing" caption sits above the controls so the held mic / orange
    /// indicator never reads as covert recording (§10.3).
    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 14) {
            if recordingService.isPaused {
                Text("Paused · mic ready, not capturing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 18) {
                pauseResumeButton
                stopButton
                cancelButton
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: recordingService.isPaused)
    }

    /// Pause ⇄ Resume circular glass control. Disabled outside the live
    /// recording window (starting / transcribing) so it can't race a teardown.
    private var pauseResumeButton: some View {
        let paused = recordingService.isPaused
        return Button(action: pauseResumeTapped) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
                .frame(width: 64, height: 64)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 32))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .disabled(phase != .recording)
        .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
    }

    /// Circular trash control — the cancel affordance, moved out of the top
    /// bar (row: "[Pause] [Stop · timer] [Trash]"). 64pt circle with the same
    /// adaptive `secondarySystemFill` background as `pauseResumeButton` (dark in
    /// dark mode), but a RED `trash` glyph to read as destructive. Wired to the
    /// SAME `cancelTapped` the old top-bar Cancel used — `forceStop()` + discard
    /// + dismiss, including the rigid cancel haptic.
    private var cancelButton: some View {
        Button(action: cancelTapped) {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .semibold))
                // Red trash, matching the keyboard's delete affordance — it's a
                // destructive action (discards the recording).
                .foregroundStyle(Color.jotRecord)
                .frame(width: 64, height: 64)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 32))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .accessibilityLabel("Cancel recording")
        .accessibilityHint("Discards this recording.")
    }

    private var stopButton: some View {
        Button(action: stopTapped) {
            HStack(spacing: 14) {
                if phase == .transcribing {
                    ProgressView()
                        .tint(Color.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 20, height: 20)

                    Text(timeString)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                }
            }
            .frame(height: 64)
            .padding(.horizontal, 24)
            .background(
                LinearGradient(
                    colors: [
                        Color.jotBlueTop,
                        Color.jotBlueBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            }
            // Stacked blue shadows — tight contact shadow + a soft ambient
            // bloom at a larger radius — so the button's blue bleeds into
            // the surrounding wallpaper the way a macOS Sequoia / iOS 26
            // glass control glows. Three layers (tight, mid, soft) give the
            // bloom a natural falloff without needing a separate radial halo
            // view behind the button.
            .shadow(color: Color.jotBlueTop.opacity(0.45), radius: 16, x: 0, y: 8)
            .shadow(color: Color.jotBlueTop.opacity(0.28), radius: 48, x: 0, y: 18)
            .shadow(color: Color.jotBlueTop.opacity(0.14), radius: 96, x: 0, y: 28)
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing || phase == .starting || phase == .preparing)
        .accessibilityLabel(phase == .transcribing ? "Transcribing" : "Stop recording")
    }

    // MARK: - Recording flow

    /// Single entry point fired by `.onAppear`. Routes to the correct
    /// lifecycle based on `intent`. The three observable outcomes are:
    ///  1. Start a brand-new recording (FAB tap, no in-flight).
    ///  2. Adopt an already-running recording (auto-nav, mic is hot).
    ///  3. Pop back immediately (auto-nav, but nothing is running — stale
    ///     presentation, e.g. app re-entry after Live Activity stop).
    private func beginRecordingFlow() {
        switch intent {
        case .startRecording:
            // FAB. In the happy path nothing is running and we call
            // `start()`. The race-window check (`isRecording` already
            // true) is defensive — should be rare since the FAB lives on
            // home and home auto-pushes the hero on `isRecording=true`.
            if recordingService.isRecording {
                adoptInFlightRecording()
            } else {
                startNewRecording()
            }
        case .adoptInFlight, .coldStartFromExternalKeyboard:
            // Same lifecycle for both — adopt the running session. The
            // cold-start case additionally surfaces the swipe-back coaching
            // overlay via `maybeShowColdStartNudge` (gated on the show-count
            // limit) and withholds the stream (§2a). NEVER call `start()` from
            // this path.
            if recordingService.isRecording {
                adoptInFlightRecording()
            } else if case .coldStartFromExternalKeyboard = intent {
                // The keyboard just initiated this recording, but on a fresh
                // install / update it can be DEFERRED behind a cold speech-model
                // load. Rather than treat "no recording yet" as stale and pop
                // (which strands the user on home — the "5–10 tries" weirdness),
                // show a "getting ready" hero NOW and adopt the moment the
                // recording actually begins (`onChange(of: isRecording)`). A
                // timeout pops if it never comes (cold launch failed).
                phase = .preparing
                armPreparingTimeout()
            } else {
                recordingHeroLog.info("Stale hero presentation — popping (no recording, no pipeline)")
                showRecordingHero = false
            }
        }
    }

    /// Pops the `.preparing` cold-start hero if the deferred recording never
    /// starts within the launch window (cold launch failed / cancelled). Mirrors
    /// the keyboard's 15s launch deadline.
    private func armPreparingTimeout() {
        preparingTask?.cancel()
        preparingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  phase == .preparing,
                  !recordingService.isRecording else { return }
            recordingHeroLog.info("Cold-start hero preparing timed out — recording never began; popping.")
            showRecordingHero = false
        }
    }

    /// §2a — configures the streaming-display reveal policy.
    ///  - App-Dictate paths: reveal immediately (the user chose to be here).
    ///  - Cold-start keyboard path: withhold; arm a coaching-beat timer
    ///    (~10s upper bound) so the stream reveals on
    ///    `max(coaching beat, first real partial)`. The `.onChange` of
    ///    `streamingText` handles the "first real partial" half; this method
    ///    owns the coaching-beat half (and, as a fallback, reveals on the
    ///    coaching beat if a partial already arrived).
    private func configureStreamReveal() {
        guard isColdStartPath else {
            // App-Dictate: stream is shown immediately, full treatment.
            streamRevealed = true
            coachingBeatElapsed = true
            return
        }

        // Cold-start: withhold. Arm the ~10s coaching upper bound.
        streamRevealed = false
        coachingBeatElapsed = false
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            coachingBeatElapsed = true
            // If a real partial has ALREADY arrived, reveal now (the
            // `.onChange` handler bailed earlier because the beat hadn't
            // elapsed yet). Otherwise the `.onChange` will reveal on the next
            // partial. As a hard upper bound, if there's already text, show it.
            if !streamingPartial.streamingText.isEmpty {
                revealStream()
            }
        }
    }

    /// Flip the cold-start stream into view with a slow transparent →
    /// translucent fade. Idempotent — guarded by `streamRevealed`.
    private func revealStream() {
        guard !streamRevealed else { return }
        revealTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) {
            streamRevealed = true
        }
        // The coaching overlay has done its job once the stream is up.
        showColdStartNudge = false
    }

    /// Decides whether the cold-start swipe-back coaching overlay should appear
    /// on this presentation. Conditions:
    ///   1. Intent is `.coldStartFromExternalKeyboard`.
    ///   2. The user has seen the overlay fewer than 7 times across the
    ///      app's lifetime (UserDefaults `jot.hero.coldStartNudgeShownCount`).
    /// When both hold, surfaces the overlay and increments the counter. The
    /// overlay self-dismisses after a window ≥ its ~5s animation (round-2 D1),
    /// or on user tap.
    private func maybeShowColdStartNudge() {
        guard case .coldStartFromExternalKeyboard = intent else { return }
        let key = "jot.hero.coldStartNudgeShownCount"
        let count = UserDefaults.standard.integer(forKey: key)
        // Raised 7 → 50 so the "head back to your app" coaching reliably appears
        // during early use / testing instead of self-suppressing after a week.
        guard count < 50 else { return }
        UserDefaults.standard.set(count + 1, forKey: key)
        showColdStartNudge = true
        // Auto-dismiss after 6s — raised from the prior 4s so the ~5s coaching
        // animation isn't truncated mid-demo (round-2 D1 / WCAG 2.2.2).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            showColdStartNudge = false
        }
    }

    /// FAB-fresh start. Owns the start haptic, coordinator handshake,
    /// and the `RecordingService.start()` call.
    private func startNewRecording() {
        startTask?.cancel()
        phase = .starting
        startTask = Task {
            let date = Date()
            await DictationActivityCoordinator.shared.start(startedAt: date)
            do {
                recordingHeroLog.notice("RECORDING START FROM: RecordingHeroView.startNewRecording (FAB tap)")
                try await recordingService.start()
                await MainActor.run {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                    elapsed = 0
                    phase = .recording
                }
            } catch {
                await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
                await MainActor.run {
                    recordingHeroLog.error(
                        "Recording start failed: \(error.localizedDescription, privacy: .public)"
                    )
                    errorMessage = "Could not start recording: \(error.localizedDescription)"
                    phase = .cancelled
                }
            }
        }
    }

    /// Auto-nav adoption. The URL handler (or some other caller) already
    /// kicked `recordingService.start()`; re-calling it would throw
    /// `.alreadyRunning`. Skip the start haptic (the recording was already
    /// going from the user's POV) and jump straight to `.recording` so the
    /// timer starts ticking — the timer reads its anchor off
    /// `recordingService.currentRecordingStartedAt` directly, so no local
    /// snapshot is needed here.
    private func adoptInFlightRecording() {
        preparingTask?.cancel()
        elapsed = 0
        phase = .recording
    }

    /// Pause ⇄ Resume. Pause does NOT finalize (§10): the engine + mic stay
    /// warm and the slice router is gated. Resume concatenates onto the same
    /// capture. Both are no-ops outside the `.recording` phase (the button is
    /// already disabled there, but guard defensively against a stale tap).
    private func pauseResumeTapped() {
        guard phase == .recording else { return }
        pauseHaptic.impactOccurred()
        pauseHaptic.prepare()
        if recordingService.isPaused {
            pauseTask?.cancel()
            pauseTask = Task {
                do {
                    try await recordingService.resumeRecording()
                } catch {
                    await MainActor.run {
                        recordingHeroLog.error(
                            "Resume failed: \(error.localizedDescription, privacy: .public)"
                        )
                        // A resume that throws means the engine went away under
                        // us (interruption raced the resume); the service has
                        // already routed to internalStop. Surface the standard
                        // error path so the user isn't stuck on a dead hero.
                        errorMessage = "Could not resume: \(error.localizedDescription)"
                        phase = .cancelled
                    }
                }
            }
        } else {
            // `pauseRecording()` is synchronous (gates the router, kicks an
            // async streaming-prefix snapshot internally). No await needed here.
            recordingService.pauseRecording()
        }
    }

    private func stopTapped() {
        guard phase == .recording else { return }
        let recordingStartedAt = recordingService.currentRecordingStartedAt ?? Date()
        recordingService.markStopInFlight()
        stopHaptic.impactOccurred()
        stopHaptic.prepare()
        phase = .transcribing

        stopTask?.cancel()
        stopTask = Task {
            let controller = DictationIntentBridge.shared.controller
            do {
                let result = try await controller.stopAndTranscribe()
                let outcome = try await DictationPipeline.completeEndOfRecording(
                    transcript: result.transcript,
                    startedAt: recordingStartedAt,
                    stoppedAt: result.stoppedAt,
                    controller: controller
                )
                _ = outcome
                await MainActor.run {
                    successHaptic.notificationOccurred(.success)
                    successHaptic.prepare()
                    phase = .finished
                    streamingPartial.reset()
                    // Pop the nav destination — flipping the binding is
                    // what actually pops it; `dismiss()` is a fallback.
                    showRecordingHero = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    recordingService.markPipelineFinished()
                    recordingHeroLog.error(
                        "Dictation failed: \(error.localizedDescription, privacy: .public)"
                    )
                    errorMessage = "Dictation failed: \(error.localizedDescription)"
                    streamingPartial.reset()
                    phase = .cancelled
                }
            }
        }
    }

    /// Back chevron — drops the user back to home WITHOUT cancelling the
    /// recording. The mic, transcription pipeline, and Live Activity all keep
    /// running. The user returns via the home-surface recording pill, which
    /// shows for any live recording.
    private func backTapped() {
        // Latch BEFORE flipping the binding so the `.onDisappear` safety-net
        // sees it and skips the cancel-on-disappear branch.
        dismissingViaBack = true
        // Flip the binding (pops the nav destination) and call `dismiss()` as
        // a fallback for any modal-context callers. No `forceStop`, no haptic,
        // no state mutation — the recording stays live behind us.
        showRecordingHero = false
        dismiss()
    }

    private func cancelTapped() {
        cancelHaptic.impactOccurred()
        cancelHaptic.prepare()
        // `forceStop()` discards the captured samples and publishes a
        // `.failed` pipeline phase. That's exactly the cancel semantics
        // we want — no transcript appended, no clipboard publish, no
        // history-mirror refresh. Works the same whether we're actively
        // recording or paused (forceStop tears the engine down regardless).
        // The streaming presenter is cleared here so the next hero surface
        // starts blank.
        recordingService.forceStop()
        streamingPartial.reset()
        phase = .cancelled
        // Pop the nav destination — flipping the binding is what
        // actually pops it; `dismiss()` is a fallback.
        showRecordingHero = false
        dismiss()
    }

    // MARK: - Timer

    private func beginTimerLoop() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            // ~10 Hz update for the elapsed timer. The anchor
            // (`currentRecordingStartedAt`) is back-dated by the service to the
            // active-time total at pause (§10.4). Back-dating alone does NOT
            // freeze a clock that keeps re-reading `now` — `now − anchor` would
            // keep growing through the pause. So we explicitly skip the update
            // while paused, leaving `elapsed` frozen at its last active value;
            // on resume the service re-anchors and the loop picks up exactly
            // where it froze.
            while !Task.isCancelled {
                if phase == .recording,
                   !recordingService.isPaused,
                   let started = recordingService.currentRecordingStartedAt {
                    elapsed = Date().timeIntervalSince(started)
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private var timeString: String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bottom-anchored streaming text block with two render modes:
///
/// 1. **Under-cap (natural growth).** While the text's natural rendered height
///    is below `maxBlockHeight`, the inner `ScrollView` is frame-locked to the
///    measured text height. The outer `streamingTextArea` then has two
///    `Spacer`s above and below it that expand evenly, keeping the block
///    vertically centered. Each new word makes the measured height grow → the
///    block expands in both directions out of the "Listening…" anchor. The
///    fade mask is suppressed here so there is no fade-out at the top of the
///    growing text — the user sees a clean centered block.
///
/// 2. **At-or-over cap (scroll mode).** Once the measured text height reaches
///    `maxBlockHeight` (round-2: ~3.5 lines), the inner ScrollView freezes at
///    that height, the top fade mask switches on, and `scrollTo` keeps the
///    newest line pinned to the bottom edge. Older lines slide up under the top
///    fade. The bottom edge stays sharp; no bottom fade.
///
/// Measurement is done with a hidden `GeometryReader` background on the text,
/// reporting its size through `StreamingTextHeightKey`. Because the text uses
/// `.fixedSize(horizontal: false, vertical: true)` it reports its natural
/// rendered height regardless of the surrounding ScrollView.
private struct StreamingDictationText: View {
    let text: String
    let maxBlockHeight: CGFloat
    let reduceMotion: Bool

    /// Last measured natural height of the text. Seeded with a single-line
    /// estimate so the first render doesn't briefly collapse the ScrollView
    /// to 0pt before the GeometryReader reports back.
    @State private var measuredTextHeight: CGFloat = 28

    var body: some View {
        let clamped = min(measuredTextHeight, maxBlockHeight)
        let isOverflowing = measuredTextHeight > maxBlockHeight

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Single bare Text node — no sibling cursor, no
                    // `.animation(...)` modifier. A sibling view with
                    // `.repeatForever` inside the same HStack as the
                    // frequently-changing Text causes SwiftUI to animate
                    // the text-content diff itself, smearing characters as
                    // partials arrive — so the streaming text is rendered
                    // standalone here with no trailing caret. Italic exclusively
                    // signals "live" (round-2 WS-A — final text renders roman).
                    Text(text)
                        .foregroundColor(Color.jotPageInk)
                        .font(.system(size: 26, weight: .regular, design: .serif).italic())
                        .tracking(-0.4)
                        .lineSpacing(8.3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: StreamingTextHeightKey.self,
                                        value: geo.size.height
                                    )
                            }
                        )
                    Color.clear
                        .frame(height: 1)
                        .id("streamingBottom")
                }
            }
            // Lock the ScrollView's outer height to min(measured, cap).
            // Under-cap: ScrollView is exactly the text's height ⇒ no scroll
            // possible, no clipping, content fully visible. At-or-over cap:
            // ScrollView is frozen at the cap and internal scrolling shows
            // the newest content while older content slides up.
            .frame(height: max(1, clamped))
            // Top fade is only meaningful in scroll mode; under cap the
            // `.black` mask is a no-op pass-through so the centered, growing
            // text doesn't have any phantom fade across the top.
            .mask(
                Group {
                    if isOverflowing {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.0), location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        Color.black
                    }
                }
            )
            .onChange(of: text, initial: false) { _, _ in
                // Only scroll when we're actually in scroll mode. Under cap
                // the ScrollView's frame already equals the text height, so
                // calling scrollTo would nudge the content up by 1pt (the
                // sentinel height) — a visible drift the user shouldn't see.
                //
                // The withAnimation here animates the SCROLL only (it wraps
                // `proxy.scrollTo`). It does NOT attach an `.animation`
                // modifier to the Text — that distinction is what keeps
                // the streaming text from inheriting an animation
                // transaction. Same shape as the keyboard's working
                // `StreamingPane.onChange(of: partialText)` handler.
                guard isOverflowing else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("streamingBottom", anchor: .bottom)
                }
            }
        }
        .onPreferenceChange(StreamingTextHeightKey.self) { newHeight in
            measuredTextHeight = newHeight
        }
    }
}

/// Carries the natural rendered height of the streaming text out of the
/// hidden GeometryReader so the parent can decide whether to scroll.
private struct StreamingTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// "Loading [variant]…" placeholder with a subtle 1.5s opacity breathing
/// animation so the surface doesn't read as frozen during the in-session
/// ANE load. Lifted out as a separate view because the breathing
/// animation needs its own `@State` cycle that wouldn't survive being
/// inlined inside the parent's `streamingTextArea` `@ViewBuilder`.
///
/// `reduceMotion = true` snaps the opacity to full and skips the
/// animation entirely (still communicates "loading" via the text copy).
private struct LoadingPlaceholderText: View {
    let variantName: String
    let reduceMotion: Bool

    @State private var dim: Bool = false

    var body: some View {
        Text("Loading \(variantName)…")
            .font(.system(size: 26, weight: .regular, design: .serif).italic())
            .lineSpacing(8.3)
            .tracking(-0.4)
            .foregroundStyle(Color.jotPageInkSecondary)
            .opacity(reduceMotion ? 1.0 : (dim ? 0.55 : 1.0))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: dim
            )
            .onAppear {
                guard !reduceMotion else { return }
                dim = true
            }
            .accessibilityLabel("Loading \(variantName)")
    }
}

/// Cold-start "head back to your app" coaching overlay shown at the top of the
/// Recording Hero on cold-start auto-nav from a third-party keyboard (round-2
/// §2a / D1). Evolves the original glass-pill nudge into a finite, animated
/// demonstration of the RIGHTWARD home-indicator return gesture, alternating
/// (across the demo) with the "‹ Back to App" pill hint that iOS draws on this
/// inter-app path.
///
/// Behavior:
///   - Animates a rightward home-indicator drag (`Color.jotBlueTop` chevron +
///     ghost touch-point + comet trail dragging left→right along a dimmed
///     mini home-indicator pill). Finite — ~2 cycles, ≤5s total, clears
///     WCAG 2.2.2.
///   - Alternates with the "‹ Back to App" pill hint so both return methods
///     are coached (D1: "once this, once that").
///   - Reduce Motion → a STATIC end-frame (no perpetual motion).
///   - VoiceOver → `.announcement` (does NOT use `.screenChanged`, which would
///     fight the hero's `recordingStatusFocused`).
///   - Tap to dismiss; the parent also auto-dismisses after a window ≥ this
///     animation, and the 7-show suppression is enforced upstream
///     (`maybeShowColdStartNudge`).
private struct ColdStartNudgeOverlay: View {
    let reduceMotion: Bool
    let onTap: () -> Void

    /// Toggles between the swipe-demo variant and the back-pill hint variant
    /// (D1 — coach both return methods, alternating). Advanced on a slow timer
    /// while the overlay lives; frozen on the swipe variant under Reduce Motion.
    @State private var showPillVariant: Bool = false
    /// 0→1 drag progress of the ghost touch-point along the home-indicator
    /// pill, driving the rightward demo. Frozen at the end-frame under Reduce
    /// Motion.
    @State private var dragProgress: CGFloat = 0
    @State private var variantTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                headline

                if showPillVariant {
                    backPillHint
                        .transition(.opacity)
                } else {
                    swipeDemo
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                // Bumped opacity vs. the standard `jotKeyboardGlassHairline`
                // token so the pill reads crisply on the Recording Hero's
                // tinted wallpaper in both modes. Same mitigation pattern
                // as the keyboard Cancel button.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color(uiColor: UIColor { trait in
                            trait.userInterfaceStyle == .dark
                                ? UIColor(white: 1.0, alpha: 0.12)
                                : UIColor(white: 0.0, alpha: 0.08)
                        }),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // VoiceOver: announce without stealing focus from the hero's
        // recordingStatusFocused (round-2 D1 — `.announcement`, not
        // `.screenChanged`).
        .accessibilityAddTraits(.isButton)
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: accessibilityLabel)
            startAnimating()
        }
        .onDisappear { variantTask?.cancel() }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(showPillVariant ? "Tap “‹ Back” to return to your app" : "Head back to your app")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotInk)
            Text("Jot keeps listening — your text pastes when you stop.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.jotInk.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Animated rightward home-indicator drag demo. A ghost touch-point with a
    /// short comet trail rides a dimmed mini home-indicator pill from left to
    /// right, a `jotBlueTop` chevron pointing the way. Reduce Motion freezes
    /// the touch-point at the end-frame (right edge) with no trail motion.
    private var swipeDemo: some View {
        GeometryReader { geo in
            let pillWidth = geo.size.width
            let dotSize: CGFloat = 26
            let travel = max(0, pillWidth - dotSize)
            let x = reduceMotion ? travel : dragProgress * travel

            ZStack(alignment: .leading) {
                // Dimmed mini home-indicator pill.
                Capsule(style: .continuous)
                    .fill(Color.jotInk.opacity(0.12))
                    .frame(height: 5)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .center)

                // Comet trail behind the touch-point (suppressed under Reduce
                // Motion — it implies motion).
                if !reduceMotion {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.jotBlueTop.opacity(0.0), Color.jotBlueTop.opacity(0.35)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, x), height: 10)
                        .frame(maxHeight: .infinity, alignment: .center)
                }

                // Ghost touch-point + rightward chevron.
                ZStack {
                    Circle()
                        .fill(Color.jotBlueTop.opacity(0.18))
                        .frame(width: dotSize, height: dotSize)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.jotBlueTop)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .offset(x: x)
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }

    /// "‹ Back to App" pill hint — the breadcrumb iOS draws top-left on the
    /// inter-app cold-start path (D1). Static; coached alongside the swipe.
    private var backPillHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.jotBlueTop)
            Text("Back to App")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.jotInk.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(Color.jotInk.opacity(0.06))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "Head back to your app by swiping right along the bottom of the screen, or tap the Back button at the top left. Jot keeps listening; your text pastes when you stop. Tap to dismiss."
    }

    /// Drives the finite drag demo + variant alternation. Under Reduce Motion
    /// nothing animates — the swipe demo is shown as a static end-frame and the
    /// variant never flips (no perpetual motion, WCAG 2.2.2).
    private func startAnimating() {
        guard !reduceMotion else { return }
        variantTask?.cancel()
        variantTask = Task { @MainActor in
            // Two drag cycles on the swipe variant (~2.8s each — the slide is
            // slowed 50% for legibility), then a beat on the pill hint, then
            // back. Alternation continues until the parent's auto-dismiss.
            while !Task.isCancelled {
                // Swipe demo: two rightward drags.
                showPillVariant = false
                for _ in 0..<2 {
                    dragProgress = 0
                    withAnimation(.easeInOut(duration: 2.4)) { dragProgress = 1 }
                    try? await Task.sleep(for: .milliseconds(2800))
                    guard !Task.isCancelled else { return }
                }
                // Pill hint beat.
                withAnimation(.easeInOut(duration: 0.3)) { showPillVariant = true }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { showPillVariant = false }
            }
        }
    }
}
