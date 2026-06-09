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
//   - **External-keyboard launch** (`.openedFromExternalKeyboard`): the keyboard
//     had to foreground Jot from another app to get the mic (iOS won't let the
//     keyboard start it) — cold OR warm process. This surface's job is to send
//     the user BACK to their app, not to keep them watching a stream. So we
//     WITHHOLD the live stream (and suppress the "Listening…/Loading…"
//     placeholder) and show the swipe-back cue instead. The stream reveals on
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

    /// Whether the swipe-back cue is shown. Pure derivation — no counter, no
    /// timer, no dismissal: the cue is visible for exactly the external-keyboard
    /// withhold window (we pulled the user in from another app) and loops until
    /// the live transcript reveals. `revealStream()` flips `streamRevealed`
    /// inside a 0.7s curve, so the cue fades out and the controls drop on that
    /// same animation. Fires for both cold- and warm-process keyboard opens —
    /// see `isExternalKeyboardLaunch`.
    private var showsSwipeCue: Bool {
        isExternalKeyboardLaunch && !streamRevealed
    }

    /// Bottom inset for the transport-control row. During the swipe-cue window
    /// the controls lift to lower-center, clearing the bottom-anchored cue band
    /// (the cue's cards top out ~135pt above the device bottom edge); otherwise
    /// they sit at the normal bottom. Animated via `streamRevealed`.
    private var controlsBottomInset: CGFloat {
        showsSwipeCue ? 196 : 36
    }

    /// True whenever the keyboard opened Jot from another app
    /// (`.openedFromExternalKeyboard`) — cold OR warm process; NOT a process-
    /// lifecycle distinction. Single source for the stream-withhold + swipe-cue
    /// branches: whenever this is true, the user has an app to swipe back to.
    private var isExternalKeyboardLaunch: Bool {
        if case .openedFromExternalKeyboard = intent { return true }
        return false
    }

    /// §9 hero top-space "story" messages (sequenced H1→H4). H5 is the pinned
    /// stream-arrival caption (rendered separately once the stream reveals, not
    /// folded into rotation so it's actually seen).
    // NOTE: the "head back — swipe right along the bottom" guidance is carried
    // wordlessly by the `SwipeBackCardCue` at the bottom, so these top lines
    // stay focused on value props rather than repeating the return instruction.
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
                    // Cold-start window: the controls lift to lower-center so the
                    // swipe-back cue owns the bottom band; on stream reveal they
                    // glide back to the bottom. The travel rides revealStream()'s
                    // 0.7s curve (both driven by `streamRevealed`) so it's smooth.
                    .padding(.bottom, controlsBottomInset)
            }

            if showsSwipeCue {
                // The looping two-card iOS app-switch demo. Non-interactive
                // decoration — `allowsHitTesting(false)` so it never swallows the
                // real home-indicator swipe. Bottom-anchored INTO the safe area
                // (`ignoresSafeArea`) so its gray home bar lands on the device's
                // real home indicator and the slide plays exactly where the user
                // must swipe. No counter, no auto-dismiss: it loops until the
                // transcript reveals (`showsSwipeCue` derives from `!streamRevealed`).
                SwipeBackCardCue(reduceMotion: reduceMotion)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityElement()
                    .accessibilityLabel("Swipe right along the bottom of the screen to head back to your app. Jot keeps listening; your text pastes when you stop.")
                    .zIndex(1)
            }

        }
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
            guard isExternalKeyboardLaunch, !streamRevealed, coachingBeatElapsed else { return }
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

    @ViewBuilder
    private var heroContentArea: some View {
        // §2a — on the cold-start path, while the stream is withheld, the freed
        // top space carries the sequenced rotating micro-messages and the live
        // stream + placeholder are fully suppressed (the recording indicator in
        // the top bar carries the "still listening" proof). Once revealed (or
        // on the App-Dictate path), the stream owns the space.
        if isExternalKeyboardLaunch && !streamRevealed {
            withheldTopSpace
        } else {
            streamingCard
        }
    }

    /// External-keyboard withhold window: the sequenced rotating micro-messages
    /// (`heroTopMessages`) occupying the freed top space, shown above the
    /// swipe-back cue. No live stream, no "Listening…/Loading…" placeholder.
    private var withheldTopSpace: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Rotating value-prop messages at the top. They coexist with the
            // swipe-back cue (which lives in its own band pinned to the bottom),
            // so there's nothing to hold back — text up top, gesture demo down low.
            RotatingMessageView(
                messages: Self.heroTopMessages,
                dwell: 5,
                sequenced: true,
                font: JotType.displaySerif(22),
                color: .jotPageInk,
                alignment: .leading
            )
            .transition(.opacity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var streamingCard: some View {
        let text = streamingPartial.streamingText
        let isLoadingModel = streamingService.sessionLoadState == .loading
        VStack(alignment: .leading, spacing: 0) {
            // Pinned caption — shown ABOVE the live text on EVERY recording.
            // One hero panel: it does NOT matter whether dictation started from
            // the keyboard (cold-start) or the in-app Dictate button.
            Text(Self.heroStreamCaption)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

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
                    StreamingDictationText(text: text)
                }
            }
            // Bottom-align so "Listening…" sits at the bottom — the same place the
            // first words appear — instead of floating in the middle.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        // The live-text area fills the whole panel (bottom-anchored, scrollable,
        // top-faded) — see `StreamingDictationText`.
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
        .opacity(streamRevealed || !isExternalKeyboardLaunch ? 1 : 0)
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
        case .adoptInFlight, .openedFromExternalKeyboard:
            // Same lifecycle for both — adopt the running session. The
            // external-keyboard case additionally surfaces the `SwipeBackCardCue`
            // (derived from `showsSwipeCue`) and withholds the stream (§2a).
            // NEVER call `start()` from this path.
            if recordingService.isRecording {
                adoptInFlightRecording()
            } else if case .openedFromExternalKeyboard = intent {
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
        guard isExternalKeyboardLaunch else {
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
        // Flipping `streamRevealed` inside this curve drives the whole reveal in
        // one coordinated motion: the stream fades in, the swipe cue fades out,
        // and the controls glide from lower-center back to the bottom — all
        // because `showsSwipeCue` / `controlsBottomInset` derive from this flag.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) {
            streamRevealed = true
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

/// Live transcript view: a bottom-anchored, scrollable text block that FILLS the
/// card. The newest text stays in view as it streams; the user can scroll up
/// through the whole recording; the top edge fades as older lines scroll off.
private struct StreamingDictationText: View {
    let text: String
    var body: some View {
        // FILL the card, and AUTO-FOLLOW: as new text streams in we scroll the
        // bottom sentinel back into view so the newest words stay pinned to the
        // bottom and older lines slide up and fade off the top.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .foregroundColor(Color.jotPageInk)
                        .font(.system(size: 26, weight: .regular, design: .serif).italic())
                        .tracking(-0.4)
                        .lineSpacing(8.3)
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 1)
                        .id("streamingBottom")
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.0), location: 0.0),
                        .init(color: .black, location: 0.10),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: text, initial: true) { _, _ in
                proxy.scrollTo("streamingBottom", anchor: .bottom)
            }
        }
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
    @State private var startedAt: Date = Date()

    /// How long THIS device's last comparable load took, used only to PACE the
    /// bar — never to fake completion. There is no real progress signal from
    /// CoreML; see `ModelLoadTimekeeper`.
    private var estimate: Double {
        ModelLoadTimekeeper.estimatedSeconds(variant: AppGroup.speechModelVariant)
    }

    /// Decelerating fill: `1 - e^(-t/τ)` with τ chosen so the bar reaches ~80%
    /// at the estimated duration, then crawls. It asymptotes below 100%, so an
    /// under-estimate (e.g. a cold ANE recompile) never completes early — the
    /// real `.ready` transition removes this whole view, which IS completion.
    private func fill(elapsed: Double) -> Double {
        // τ paces the fill. Divisor 0.8 (≈ half of the natural 1.6) deliberately
        // SLOWS the bar ~2×: it reads as steady progress the user can follow
        // while they keep speaking, rather than rushing to the cap and sitting.
        let tau = max(estimate, 0.5) / 0.8
        let raw = 1.0 - exp(-elapsed / tau)
        return min(raw, 0.94)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            TimelineView(.periodic(from: startedAt, by: 0.05)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                let value = fill(elapsed: elapsed)
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(Color.jotPageInkSecondary)
                    .frame(maxWidth: 240, alignment: .leading)
                    .animation(.easeOut(duration: 0.18), value: value)
                    .accessibilityValue("\(Int(value * 100)) percent")
            }

            // Reassurance: audio is captured into the streaming queue during the
            // load and drained the instant the model is ready, so nothing spoken
            // now is lost. Instructional, not a rhetorical nudge.
            Text("Keep speaking — your words are saved and appear the moment loading finishes.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.jotPageInkSecondary)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .onAppear {
            startedAt = Date()
            guard !reduceMotion else { return }
            dim = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading \(variantName)")
    }
}


// MARK: - Swipe-back card cue

/// The looping, wordless "swipe back to your app" demonstration pinned to the
/// bottom of the cold-start recording surface. It reproduces the real iOS
/// app-switch edge gesture: a finger presses the home-indicator bar and drags
/// right; the current app (Jot) shrinks into a card and slides off to the right
/// while the previous app's card follows in from the left. The motion is the
/// whole message — there is no copy of its own (the reassurance text lives at
/// the top of the screen).
///
/// Pixel-ported from `design_handoff_swipe_back_cue/prototype/gestures.css`:
/// cards 122×104 r20, exactly 138pt apart; finger 40 + ripple ring; home bar
/// 138×5; stage 150 tall; one loop = 4.25s, every segment eased with
/// cubic-bezier(0.45, 0.02, 0.2, 1), repeating forever.
///
/// Non-interactive — the caller sets `allowsHitTesting(false)` so it never
/// captures the user's real swipe. Reduce Motion → a static end-frame (two
/// cards offset apart, finger centered, no ripple) per the handoff.
private struct SwipeBackCardCue: View {
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// One loop in seconds (handoff: 3.4s ÷ 0.8 speed ≈ 4.25s).
    private let period: Double = 4.25

    // Geometry is BOTTOM-anchored: the cue extends into the bottom safe area
    // (`ignoresSafeArea` at the call site) and the gray home-indicator bar is
    // drawn directly on top of the device's real home indicator, so the slide
    // demo plays exactly where the user must swipe. `homeBarInsetFromBottom` is
    // the system home-indicator metric (bar bottom ~8pt + half its 5pt height).
    private let homeBarInsetFromBottom: CGFloat = 11
    /// Gap between the bottom edge of the (entirely-above) cards and the bar.
    private let cardToHomeGap: CGFloat = 20
    private let cardHeight: CGFloat = 104
    /// Finger rides on the bar — pad sits ~12.5pt above its center (prototype),
    /// so the contact reads as pressing the indicator while it drags along it.
    private let fingerAboveBar: CGFloat = 12.5

    /// All animated values for a single frame of the loop. Geometry/scale are
    /// CGFloat (for `.position`/`.scaleEffect`); opacities are Double.
    private struct CueFrame {
        var jotX, jotScale: CGFloat
        var jotOpacity: Double
        var prevX, prevScale: CGFloat
        var prevOpacity: Double
        var touchX, touchY, touchScale: CGFloat
        var touchOpacity: Double
        var rippleScale: CGFloat
        var rippleOpacity: Double
    }

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2
            // Anchor everything to the band's true bottom (= device bottom edge,
            // since the cue ignores the bottom safe area).
            let homeY = geo.size.height - homeBarInsetFromBottom
            let cardY = homeY - cardToHomeGap - cardHeight / 2   // cards float fully above the bar
            let fingerY = homeY - fingerAboveBar
            if reduceMotion {
                cueBody(Self.reducedMotionFrame, centerX: cx, homeY: homeY, cardY: cardY, fingerY: fingerY)
            } else {
                TimelineView(.animation) { tl in
                    cueBody(Self.frames(at: Self.loopPhase(tl.date, period: period)),
                            centerX: cx, homeY: homeY, cardY: cardY, fingerY: fingerY)
                }
            }
        }
    }

    private func cueBody(_ f: CueFrame, centerX cx: CGFloat,
                         homeY: CGFloat, cardY: CGFloat, fingerY: CGFloat) -> some View {
        ZStack {
            // Gray home-indicator bar (back layer) — sits on the device's real
            // home indicator; the finger slides right along it.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(railColor)
                .frame(width: 138, height: 5)
                .position(x: cx, y: homeY)

            // Previous app card — follows in from the left.
            previousAppCard
                .scaleEffect(f.prevScale)
                .opacity(f.prevOpacity)
                .position(x: cx + f.prevX, y: cardY)

            // Jot card — above the previous card in z so it slides over it.
            jotAppCard
                .scaleEffect(f.jotScale)
                .opacity(f.jotOpacity)
                .position(x: cx + f.jotX, y: cardY)

            // Finger contact + ripple (front layer) — drags right along the bar.
            ZStack {
                Circle()
                    .strokeBorder(rippleColor, lineWidth: 2)
                    .frame(width: 58, height: 58)
                    .scaleEffect(f.rippleScale)
                    .opacity(f.rippleOpacity)
                fingerContact
                    .scaleEffect(f.touchScale)
            }
            .opacity(f.touchOpacity)
            .position(x: cx + f.touchX, y: fingerY + f.touchY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: Cards

    private var jotAppCard: some View {
        cardContainer(border: cardBorder, background: { jotCardBackground }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    jotIcon
                    bar(width: 30, height: 7, radius: 4, color: inkSub.opacity(0.5))
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 9)
                // ac-head — 80% width header bar.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.102, green: 0.549, blue: 1.0).opacity(0.6), inkSub],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .opacity(0.5)
                    .frame(height: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 20)   // ≈ 80% of the 98pt inner width
                    .padding(.bottom, 9)
                fullRow(color: inkSub.opacity(0.32))
                    .padding(.bottom, 7)
                shortRow(color: inkSub.opacity(0.32))
                Spacer(minLength: 0)
            }
        }
    }

    private var previousAppCard: some View {
        cardContainer(border: prevBorder, background: { prevCardBackground }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.557, green: 0.592, blue: 0.651),
                                         Color(red: 0.431, green: 0.463, blue: 0.525)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 18, height: 18)
                    bar(width: 34, height: 7, radius: 4, color: Color(red: 0.078, green: 0.157, blue: 0.314).opacity(0.22))
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 9)
                fullRow(color: prevRowColor).padding(.bottom, 7)
                fullRow(color: prevRowColor).padding(.bottom, 7)
                shortRow(color: prevRowColor)
                Spacer(minLength: 0)
            }
        }
    }

    private func cardContainer<B: View, C: View>(
        border: Color,
        @ViewBuilder background: () -> B,
        @ViewBuilder content: () -> C
    ) -> some View {
        content()
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .frame(width: 122, height: 104, alignment: .topLeading)
            .background { background() }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 12)
    }

    // MARK: Card pieces

    private var jotIcon: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(blueGradient)
            .frame(width: 18, height: 18)
            .overlay(
                Text("j")
                    .font(Font.custom(JotType.frauncesItalic, size: 12))
                    .foregroundStyle(.white)
            )
            .shadow(color: Color(red: 0.102, green: 0.549, blue: 1.0).opacity(0.44), radius: 3, x: 0, y: 2)
    }

    private var fingerContact: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 0.227, green: 0.612, blue: 1.0), location: 0.0),
                        .init(color: Color(red: 0.102, green: 0.549, blue: 1.0), location: 0.58),
                        .init(color: Color(red: 0.0, green: 0.392, blue: 0.8), location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 20
                )
            )
            .frame(width: 40, height: 40)
            .overlay(
                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: 22, height: 6)
                    .blur(radius: 3)
                    .offset(y: -12)
            )
            .shadow(color: Color(red: 0.102, green: 0.549, blue: 1.0).opacity(0.44), radius: 11, x: 0, y: 8)
    }

    private func bar(width: CGFloat, height: CGFloat, radius: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }

    private func fullRow(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(height: 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortRow(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(height: 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 37)   // ≈ 62% of the 98pt inner width
    }

    // MARK: Backgrounds & colors (handoff hex is the source of truth)

    @ViewBuilder private var jotCardBackground: some View {
        let rr = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if colorScheme == .dark {
            rr.fill(
                LinearGradient(
                    colors: [Color(red: 0.106, green: 0.173, blue: 0.310),
                             Color(red: 0.075, green: 0.125, blue: 0.227)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RadialGradient(
                    colors: [Color(red: 0.180, green: 0.455, blue: 0.769).opacity(0.55), .clear],
                    center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 110
                )
            )
        } else {
            rr.fill(
                LinearGradient(
                    colors: [Color(red: 0.854, green: 0.918, blue: 0.990),
                             Color(red: 0.933, green: 0.949, blue: 0.976)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RadialGradient(
                    colors: [Color(red: 0.102, green: 0.549, blue: 1.0).opacity(0.26), .clear],
                    center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 110
                )
            )
        }
    }

    private var prevCardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.957, green: 0.965, blue: 0.980))
    }

    private var blueGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.180, green: 0.608, blue: 1.0),
                     Color(red: 0.055, green: 0.478, blue: 0.902),
                     Color(red: 0.0, green: 0.392, blue: 0.8)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var inkSub: Color {
        colorScheme == .dark
            ? Color(red: 0.914, green: 0.933, blue: 0.969).opacity(0.66)
            : Color(red: 0.086, green: 0.125, blue: 0.204).opacity(0.62)
    }
    private var railColor: Color {
        colorScheme == .dark
            ? Color(red: 0.914, green: 0.933, blue: 0.969).opacity(0.30)
            : Color(red: 0.086, green: 0.125, blue: 0.204).opacity(0.26)
    }
    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color(red: 0.078, green: 0.157, blue: 0.314).opacity(0.10)
    }
    private var prevBorder: Color { Color(red: 0.078, green: 0.157, blue: 0.314).opacity(0.10) }
    private var prevRowColor: Color { Color(red: 0.078, green: 0.157, blue: 0.314).opacity(0.13) }
    private var rippleColor: Color { Color(red: 0.102, green: 0.549, blue: 1.0).opacity(0.55) }

    // MARK: Keyframe sampling

    /// cubic-bezier(0.45, 0.02, 0.2, 1) — the shared per-segment easing.
    private static func ease(_ x: Double) -> Double {
        let x1 = 0.45, y1 = 0.02, x2 = 0.20, y2 = 1.0
        func curveX(_ t: Double) -> Double {
            let mt = 1 - t
            return 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t * t * t
        }
        func curveY(_ t: Double) -> Double {
            let mt = 1 - t
            return 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            let xe = curveX(t)
            if abs(xe - x) < 0.0004 { return curveY(t) }
            if xe < x { lo = t } else { hi = t }
            t = (lo + hi) * 0.5
        }
        return curveY(t)
    }

    /// Piecewise sample of a keyframe track, easing each segment.
    private static func sample(_ stops: [(Double, Double)], _ t: Double) -> Double {
        guard let first = stops.first else { return 0 }
        if t <= first.0 { return first.1 }
        for i in 1..<stops.count {
            let (t1, v1) = stops[i]
            if t <= t1 {
                let (t0, v0) = stops[i - 1]
                let span = t1 - t0
                let local = span > 0 ? (t - t0) / span : 1
                return v0 + (v1 - v0) * ease(local)
            }
        }
        return stops.last!.1
    }

    private static func loopPhase(_ date: Date, period: Double) -> Double {
        let s = date.timeIntervalSinceReferenceDate
        let m = s.truncatingRemainder(dividingBy: period)
        return (m < 0 ? m + period : m) / period
    }

    // Tracks (fractions of the loop) — transcribed straight from gestures.css.
    private static let jotXStops: [(Double, Double)]      = [(0, 0), (0.06, 0), (0.18, 0), (0.56, 138), (0.66, 180), (1, 180)]
    private static let jotScaleStops: [(Double, Double)]  = [(0, 0.97), (0.06, 1), (0.18, 0.93), (0.56, 0.93), (0.66, 0.9), (1, 0.9)]
    private static let jotOpacityStops: [(Double, Double)] = [(0, 0), (0.06, 1), (0.18, 1), (0.56, 1), (0.66, 0), (1, 0)]
    private static let prevXStops: [(Double, Double)]     = [(0, -138), (0.18, -138), (0.56, 0), (1, 0)]
    private static let prevScaleStops: [(Double, Double)] = [(0, 0.93), (0.18, 0.93), (0.56, 0.93), (0.70, 0.96), (0.82, 0.98), (1, 0.98)]
    private static let prevOpacityStops: [(Double, Double)] = [(0, 0), (0.18, 0), (0.25, 1), (0.56, 1), (0.70, 1), (0.82, 0), (1, 0)]
    private static let touchXStops: [(Double, Double)]    = [(0, -66), (0.06, -66), (0.18, -66), (0.56, 72), (0.66, 72), (1, 72)]
    private static let touchYStops: [(Double, Double)]    = [(0, 4), (0.06, 0), (0.18, -2), (0.56, -2), (0.66, 4), (1, 4)]
    private static let touchScaleStops: [(Double, Double)] = [(0, 0.6), (0.06, 1), (0.18, 1.05), (0.56, 1.05), (0.66, 0.62), (1, 0.6)]
    private static let touchOpacityStops: [(Double, Double)] = [(0, 0), (0.06, 1), (0.18, 1), (0.56, 1), (0.66, 0), (1, 0)]
    private static let rippleScaleStops: [(Double, Double)] = [(0, 0.5), (0.06, 0.5), (0.16, 1), (0.30, 1.5), (1, 1.5)]
    private static let rippleOpacityStops: [(Double, Double)] = [(0, 0), (0.06, 0), (0.16, 0.7), (0.30, 0), (1, 0)]

    private static func frames(at t: Double) -> CueFrame {
        CueFrame(
            jotX: CGFloat(sample(jotXStops, t)), jotScale: CGFloat(sample(jotScaleStops, t)), jotOpacity: sample(jotOpacityStops, t),
            prevX: CGFloat(sample(prevXStops, t)), prevScale: CGFloat(sample(prevScaleStops, t)), prevOpacity: sample(prevOpacityStops, t),
            touchX: CGFloat(sample(touchXStops, t)), touchY: CGFloat(sample(touchYStops, t)),
            touchScale: CGFloat(sample(touchScaleStops, t)), touchOpacity: sample(touchOpacityStops, t),
            rippleScale: CGFloat(sample(rippleScaleStops, t)), rippleOpacity: sample(rippleOpacityStops, t)
        )
    }

    /// Reduce Motion static end-frame (gestures.css `prefers-reduced-motion`).
    private static let reducedMotionFrame = CueFrame(
        jotX: 70, jotScale: 0.92, jotOpacity: 1,
        prevX: -70, prevScale: 0.92, prevOpacity: 1,
        touchX: 0, touchY: -2, touchScale: 1, touchOpacity: 1,
        rippleScale: 1, rippleOpacity: 0
    )
}
